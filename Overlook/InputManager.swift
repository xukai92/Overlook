import Foundation
import Cocoa
import CoreGraphics
import Combine
import SwiftUI

extension Notification.Name {
    static let overlookToggleCopyMode = Notification.Name("overlook.toggleCopyMode")
}

@MainActor
class InputManager: ObservableObject {
    private var webRTCManager: WebRTCManager?
    private var glkvmClient: GLKVMClient?
    private var glkvmWebSocketClient: GLKVMClient.WebSocketClient?
    private var keyEventMonitor: Any?
    private var mouseEventMonitor: Any?
    private var shortcutEventTap: CFMachPort?
    private var shortcutRunLoopSource: CFRunLoopSource?
    private var shortcutTapLocation: CGEventTapLocation?
    @Published private(set) var systemShortcutCaptureReady = false
    private var permissionRetryTimer: Timer?
    private var appFocusObserver: Any?
    private var inputSendTask: Task<Void, Never>?
    private var pressedRemoteKeys: Set<String> = []
    private var releaseShortcutKeyUp: UInt16?
    @Published private(set) var heldCapturedKeys = "—"
    @Published private(set) var lastCapturedKeyEvent = "No keys captured yet"
    @Published private(set) var capturedKeyEventCount = 0
    @Published private(set) var lastCaptureSource = "None"
    private var capturedKeyCodes: Set<UInt16> = []
    @Published var lastInputError: String?
    @Published var shortcutCaptureStatus: String?
    @Published var forwardMacShortcuts = UserDefaults.standard.bool(forKey: "overlook.forwardMacShortcuts") {
        didSet {
            UserDefaults.standard.set(forwardMacShortcuts, forKey: "overlook.forwardMacShortcuts")
            releaseRemoteKeys()
            if forwardMacShortcuts { installShortcutCapture() } else { removeShortcutCapture() }
        }
    }
    @Published var invertScrolling = UserDefaults.standard.bool(forKey: "overlook.invertScrolling") {
        didSet { UserDefaults.standard.set(invertScrolling, forKey: "overlook.invertScrolling") }
    }
    private var isCapturing = false
    private var mouseModeRefreshTask: Task<Void, Never>?

    private struct PendingAbsoluteMouseMove {
        let toX: Int
        let toY: Int
    }

    private struct PendingRelativeMouseMove {
        var deltaX: Int
        var deltaY: Int
    }

    private var pendingAbsoluteMouseMove: PendingAbsoluteMouseMove?
    private var pendingRelativeMouseMove: PendingRelativeMouseMove?
    private var mouseMoveSenderTask: Task<Void, Never>?
    private static let mouseMoveSendIntervalNs: UInt64 = 8_333_333

    private var pendingCommandKeyCode: UInt16?
    private var activeCommandKeyCode: UInt16?
    private var commandKeySentToRemote: Bool = false
    private var suppressedKeyUps: Set<UInt16> = []
    
    @Published var isKeyboardCaptureEnabled = false
    @Published var isMouseCaptureEnabled = false

    enum TransportMode: String, CaseIterable {
        case webRTC
        case glkvmWebSocket
    }

    @Published var transportMode: TransportMode = .glkvmWebSocket
    @Published private(set) var isGLKVMAbsoluteMouseMode = true
    
    func setup(with webRTCManager: WebRTCManager) {
        self.webRTCManager = webRTCManager
        if appFocusObserver == nil {
            appFocusObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseRemoteKeys() }
            }
        }
    }

    func setGLKVMClient(_ client: GLKVMClient?) {
        mouseModeRefreshTask?.cancel()
        mouseModeRefreshTask = nil
        if glkvmClient !== client { releaseRemoteKeys() }
        glkvmClient = client
        isGLKVMAbsoluteMouseMode = true
        pendingAbsoluteMouseMove = nil
        pendingRelativeMouseMove = nil
        if client == nil {
            disconnectGLKVMWebSocket()
            return
        }
        Task { [weak self] in
            await self?.reconnectGLKVMWebSocketIfNeeded()
        }
        mouseModeRefreshTask = Task { [weak self, weak client] in
            guard let client else { return }
            do {
                let config = try await client.getSystemConfig()
                await MainActor.run {
                    guard let self, self.glkvmClient === client else { return }
                    self.setGLKVMAbsoluteMouseMode(config.isAbsoluteMouse)
                }
            } catch {
                // Keep the default absolute-mode behavior if settings cannot be loaded.
            }
        }
    }

    func setGLKVMAbsoluteMouseMode(_ isAbsolute: Bool) {
        guard isGLKVMAbsoluteMouseMode != isAbsolute else { return }
        isGLKVMAbsoluteMouseMode = isAbsolute
        pendingAbsoluteMouseMove = nil
        pendingRelativeMouseMove = nil
    }

    func handleVideoMouseMove(pointInView: CGPoint, deltaInView: CGSize = .zero, viewSize: CGSize, videoSize: CGSize?) {
        guard isMouseCaptureEnabled else { return }
        let normalized = normalizePointInViewToVideo(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize)
        let moveEvent = MouseMoveEvent(position: normalized, delta: deltaInView, timestamp: CACurrentMediaTime())
        if transportMode == .glkvmWebSocket {
            if isGLKVMAbsoluteMouseMode {
                enqueueAbsoluteMouseMoveEvent(moveEvent)
            } else {
                enqueueRelativeMouseMoveEvent(moveEvent)
            }
        } else {
            sendMouseMoveEvent(moveEvent)
        }
    }

    private func enqueueAbsoluteMouseMoveEvent(_ event: MouseMoveEvent) {
        guard isNormalized(event.position) else { return }
        let (toX, toY) = glkvmAbsolutePoint(fromNormalized: event.position)
        pendingAbsoluteMouseMove = PendingAbsoluteMouseMove(toX: toX, toY: toY)
        if mouseMoveSenderTask == nil {
            startMouseMoveSender()
        }
    }

    private func enqueueRelativeMouseMoveEvent(_ event: MouseMoveEvent) {
        let deltaX = Int(event.delta.width.rounded())
        let deltaY = Int(event.delta.height.rounded())
        guard deltaX != 0 || deltaY != 0 else { return }

        if var pending = pendingRelativeMouseMove {
            pending.deltaX += deltaX
            pending.deltaY += deltaY
            pendingRelativeMouseMove = pending
        } else {
            pendingRelativeMouseMove = PendingRelativeMouseMove(deltaX: deltaX, deltaY: deltaY)
        }

        if mouseMoveSenderTask == nil {
            startMouseMoveSender()
        }
    }

    private func startMouseMoveSender() {
        guard mouseMoveSenderTask == nil else { return }

        let sendIntervalNs = Self.mouseMoveSendIntervalNs

        mouseMoveSenderTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let snapshot: (
                    absoluteMove: PendingAbsoluteMouseMove?,
                    relativeMove: PendingRelativeMouseMove?,
                    isAbsoluteMouseMode: Bool,
                    mode: TransportMode,
                    ws: GLKVMClient.WebSocketClient?
                ) = await MainActor.run {
                    let absoluteMove = self.pendingAbsoluteMouseMove
                    let relativeMove = self.pendingRelativeMouseMove
                    self.pendingAbsoluteMouseMove = nil
                    self.pendingRelativeMouseMove = nil
                    return (
                        absoluteMove,
                        relativeMove,
                        self.isGLKVMAbsoluteMouseMode,
                        self.transportMode,
                        self.glkvmWebSocketClient
                    )
                }

                let hasMove = snapshot.isAbsoluteMouseMode ? snapshot.absoluteMove != nil : snapshot.relativeMove != nil
                guard hasMove else {
                    await MainActor.run {
                        self.mouseMoveSenderTask = nil
                    }
                    return
                }

                if snapshot.mode == .glkvmWebSocket, let ws = snapshot.ws {
                    if snapshot.isAbsoluteMouseMode, let move = snapshot.absoluteMove {
                        try? await ws.sendHidMouseMove(toX: move.toX, toY: move.toY)
                    } else if let move = snapshot.relativeMove {
                        await Self.sendRelativeMouseMove(move, through: ws)
                    }
                }

                try? await Task.sleep(nanoseconds: sendIntervalNs)
            }
        }
    }

    private func stopMouseMoveSender() {
        pendingAbsoluteMouseMove = nil
        pendingRelativeMouseMove = nil
        mouseMoveSenderTask?.cancel()
        mouseMoveSenderTask = nil
    }

    func handleVideoMouseButton(button: MouseButton, isDown: Bool, pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?) {
        guard isMouseCaptureEnabled else { return }
        let normalized = normalizePointInViewToVideo(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize)
        let buttonEvent = MouseButtonEvent(button: button, isDown: isDown, position: normalized, timestamp: CACurrentMediaTime())
        sendMouseButtonEvent(buttonEvent)
    }

    func handleVideoMouseScroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard isMouseCaptureEnabled else { return }
        let direction: CGFloat = invertScrolling ? -1 : 1
        let scrollEvent = MouseScrollEvent(deltaX: deltaX * direction, deltaY: deltaY * direction, timestamp: CACurrentMediaTime())
        sendMouseScrollEvent(scrollEvent)
    }

    func setTransportMode(_ mode: TransportMode) {
        transportMode = mode
        switch mode {
        case .webRTC:
            stopMouseMoveSender()
            disconnectGLKVMWebSocket()
        case .glkvmWebSocket:
            Task { [weak self] in
                await self?.reconnectGLKVMWebSocketIfNeeded()
            }
        }
    }

    func disconnectGLKVMWebSocket() {
        releaseRemoteKeys()
        stopMouseMoveSender()
        let ws = glkvmWebSocketClient
        glkvmWebSocketClient = nil
        let previous = inputSendTask
        inputSendTask = Task {
            await previous?.value
            await ws?.disconnect()
        }
    }
    
    func startKeyboardCapture() {
        if forwardMacShortcuts { installShortcutCapture() }
        guard keyEventMonitor == nil else {
            isCapturing = true
            isKeyboardCaptureEnabled = true
            return
        }
        
        isCapturing = true
        isKeyboardCaptureEnabled = true
        
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.isKeyboardCaptureEnabled,
                  NSApp.keyWindow?.attachedSheet == nil else { return event }
            self.handleKeyEvent(event)
            return nil
        }
    }
    
    func stopKeyboardCapture() {
        releaseRemoteKeys()
        isKeyboardCaptureEnabled = false
        
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        
        if !isMouseCaptureEnabled {
            isCapturing = false
        }
    }
    
    func startMouseCapture() {
        isCapturing = true
        isMouseCaptureEnabled = true
    }
    
    func stopMouseCapture() {
        isMouseCaptureEnabled = false
        
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
        
        if !isKeyboardCaptureEnabled {
            isCapturing = false
        }
    }
    
    // Runs on the main run loop so deciding whether to swallow an event is synchronous.
    private func installShortcutCapture(requestPermission: Bool = true) {
        if let tap = shortcutEventTap {
            systemShortcutCaptureReady = CGEvent.tapIsEnabled(tap: tap)
            return
        }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let manager = Unmanaged<InputManager>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    manager.releaseRemoteKeys()
                    if let tap = manager.shortcutEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard manager.forwardMacShortcuts, manager.isKeyboardCaptureEnabled,
                      NSApp.isActive, NSApp.keyWindow?.attachedSheet == nil,
                      manager.glkvmClient != nil,
                      let keyEvent = NSEvent(cgEvent: event) else {
                    return Unmanaged.passUnretained(event)
                }
                manager.handleKeyEvent(keyEvent, fromSystemTap: true)
                return nil
            }
        }
        // Prefer the earliest supported event stream, before system shortcuts.
        // Some configurations permit only a session tap, so keep that fallback.
        var createdTap: CFMachPort?
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            if let tap = CGEvent.tapCreate(tap: location, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                createdTap = tap
                shortcutTapLocation = location
                break
            }
        }
        guard let tap = createdTap else {
            systemShortcutCaptureReady = false
            shortcutCaptureStatus = "System capture blocked. Open Privacy & Security → Device Control and Data Access (Accessibility on older macOS). Remove the old Overlook entry and add /Applications/Overlook.app again."
            if requestPermission { requestAccessibilityPermissions() }
            if permissionRetryTimer == nil {
                permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.forwardMacShortcuts else { return }
                        self.installShortcutCapture(requestPermission: false)
                    }
                }
            }
            return
        }
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        shortcutEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        shortcutRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        systemShortcutCaptureReady = CGEvent.tapIsEnabled(tap: tap)
        shortcutCaptureStatus = systemShortcutCaptureReady ? "System keyboard capture ready." : "System keyboard capture could not be enabled."
    }

    private func removeShortcutCapture() {
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        if let source = shortcutRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = shortcutEventTap { CFMachPortInvalidate(tap) }
        shortcutEventTap = nil
        shortcutRunLoopSource = nil
        shortcutTapLocation = nil
        systemShortcutCaptureReady = false
        shortcutCaptureStatus = nil
    }

    func recheckShortcutAccess() {
        removeShortcutCapture()
        if forwardMacShortcuts { installShortcutCapture() }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    var keyboardCaptureLabel: String {
        guard isKeyboardCaptureEnabled else { return "Keyboard paused" }
        if forwardMacShortcuts {
            return systemShortcutCaptureReady ? "System capture ready" : "App-only capture · system access blocked"
        }
        return "App-only capture"
    }

    private func noteCapturedKey(_ event: NSEvent, fromSystemTap: Bool) {
        guard [.keyDown, .keyUp, .flagsChanged].contains(event.type) else { return }
        let code = event.keyCode
        let isDown: Bool
        if event.type == .flagsChanged {
            let masks: [UInt16: UInt] = [59: 0x1, 56: 0x2, 60: 0x4, 55: 0x8,
                                          54: 0x10, 58: 0x20, 61: 0x40, 62: 0x2000]
            if code == 57 { isDown = event.modifierFlags.contains(.capsLock) }
            else if let mask = masks[code] { isDown = event.modifierFlags.rawValue & mask != 0 }
            else { return }
        } else { isDown = event.type == .keyDown }
        if isDown { capturedKeyCodes.insert(code) }
        let chord = capturedChord(capturedKeyCodes.union([code]))
        if !isDown { capturedKeyCodes.remove(code) }
        heldCapturedKeys = capturedChord(capturedKeyCodes)
        lastCapturedKeyEvent = chord + (isDown ? " ↓" : " ↑")
        lastCaptureSource = fromSystemTap ? "System" : "App"
        capturedKeyEventCount += 1
    }

    private func capturedChord(_ codes: Set<UInt16>) -> String {
        guard !codes.isEmpty else { return "—" }
        let order: [UInt16] = [59, 62, 58, 61, 56, 60, 55, 54]
        let symbols: [UInt16: String] = [59: "⌃", 62: "⌃R", 58: "⌥", 61: "⌥R",
                                         56: "⇧", 60: "⇧R", 55: "⌘", 54: "⌘R", 57: "⇪",
                                         48: "Tab", 49: "Space", 53: "Esc", 36: "Return",
                                         123: "←", 124: "→", 125: "↓", 126: "↑"]
        return codes.sorted {
            let left = order.firstIndex(of: $0) ?? 100 + Int($0)
            let right = order.firstIndex(of: $1) ?? 100 + Int($1)
            return left < right
        }.map { code in
            if let symbol = symbols[code] { return symbol }
            guard let key = glkvmKeyForMacKeyCode(code) else { return "Key \(code)" }
            if key.hasPrefix("Key") { return String(key.dropFirst(3)) }
            if key.hasPrefix("Digit") { return String(key.dropFirst(5)) }
            return key
        }.joined(separator: " ")
    }

    private func forwardCapturedKey(_ event: NSEvent) {
        // Control+Option+Escape is always local and releases every remote key.
        if event.type == .keyUp, releaseShortcutKeyUp == event.keyCode {
            releaseShortcutKeyUp = nil
            return
        }
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.contains([.control, .option]) {
            releaseShortcutKeyUp = event.keyCode
            forwardMacShortcuts = false
            return
        }
        let isDown: Bool
        switch event.type {
        case .keyDown: isDown = true
        case .keyUp: isDown = false
        case .flagsChanged:
            if event.keyCode == 57 { // Caps Lock is a toggle, rather than a held modifier.
                sendKeyEvent(KeyEvent(keyCode: 57, isKeyDown: true, modifiers: [], timestamp: event.timestamp))
                sendKeyEvent(KeyEvent(keyCode: 57, isKeyDown: false, modifiers: [], timestamp: event.timestamp))
                return
            }
            // Device-specific modifier bits preserve left/right key releases even
            // when both sides of a modifier are held (IOKit/IOLLEvent.h).
            let masks: [UInt16: UInt] = [59: 0x1, 56: 0x2, 60: 0x4, 55: 0x8,
                                          54: 0x10, 58: 0x20, 61: 0x40, 62: 0x2000]
            guard let mask = masks[event.keyCode] else { return }
            isDown = event.modifierFlags.rawValue & mask != 0
        default: return
        }
        sendKeyEvent(KeyEvent(keyCode: event.keyCode, isKeyDown: isDown,
                              modifiers: event.modifierFlags, timestamp: event.timestamp))
    }

    private func queueHidKey(_ key: String, isDown: Bool, through ws: GLKVMClient.WebSocketClient) {
        if isDown { pressedRemoteKeys.insert(key) } else { pressedRemoteKeys.remove(key) }
        let previous = inputSendTask
        inputSendTask = Task { [weak self] in
            await previous?.value
            do { try await ws.sendHidKey(key: key, state: isDown) }
            catch { self?.lastInputError = "Keyboard input failed: \(error.localizedDescription)" }
        }
    }

    private func releaseRemoteKeys() {
        if let ws = glkvmWebSocketClient {
            // Release ordinary keys first, then modifiers.
            let modifiers: Set<String> = ["MetaLeft", "MetaRight", "AltLeft", "AltRight", "ControlLeft", "ControlRight", "ShiftLeft", "ShiftRight"]
            let keys = pressedRemoteKeys.sorted { modifiers.contains($0) == modifiers.contains($1) ? $0 < $1 : !modifiers.contains($0) }
            for key in keys { queueHidKey(key, isDown: false, through: ws) }
        }
        pressedRemoteKeys.removeAll()
        capturedKeyCodes.removeAll()
        heldCapturedKeys = "—"
        clearPendingCommandKey()
    }

    func wakeHost() async throws {
        guard let client = glkvmClient else { throw GLKVMClient.WebSocketClient.WebSocketError.notConnected }
        // Use the authenticated HTTP HID API, independently of video and keyboard capture.
        try await client.sendHidKey(key: "ShiftLeft", state: true)
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch {
            try? await client.sendHidKey(key: "ShiftLeft", state: false)
            throw error
        }
        try await client.sendHidKey(key: "ShiftLeft", state: false)
    }

    private func handleKeyEvent(_ event: NSEvent, fromSystemTap: Bool = false) {
        guard isKeyboardCaptureEnabled else { return }
        noteCapturedKey(event, fromSystemTap: fromSystemTap)
        if forwardMacShortcuts {
            forwardCapturedKey(event)
            return
        }

        switch event.type {
        case .keyDown, .keyUp:
            let keyCode = event.keyCode
            let isKeyDown = event.type == .keyDown
            let modifiers = event.modifierFlags

            if !isKeyDown, suppressedKeyUps.contains(keyCode) {
                suppressedKeyUps.remove(keyCode)
                return
            }

            if isKeyDown, modifiers.contains(.command) {
                if keyCode == 8 {
                    prepareForLocalCommandShortcut()
                    suppressedKeyUps.insert(keyCode)
                    NotificationCenter.default.post(name: .overlookToggleCopyMode, object: nil)
                    return
                }
                if keyCode == 9 {
                    prepareForLocalCommandShortcut()
                    suppressedKeyUps.insert(keyCode)
                    pasteClipboardToRemote()
                    return
                }

                if let pending = pendingCommandKeyCode,
                   commandKeySentToRemote == false,
                   transportMode == .glkvmWebSocket,
                   let ws = glkvmWebSocketClient,
                   let metaKey = glkvmKeyForMacKeyCode(pending),
                   let keyName = glkvmKeyForMacKeyCode(keyCode) {
                    activeCommandKeyCode = pending
                    pendingCommandKeyCode = nil
                    commandKeySentToRemote = true

                    queueHidKey(metaKey, isDown: true, through: ws)
                    queueHidKey(keyName, isDown: true, through: ws)
                    return
                }

                flushPendingCommandKeyIfNeeded(timestamp: event.timestamp, modifiers: modifiers)
            }

            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: isKeyDown,
                modifiers: modifiers,
                timestamp: event.timestamp
            )

            sendKeyEvent(keyEvent)

        case .flagsChanged:
            let keyCode = event.keyCode
            guard let keyName = glkvmKeyForMacKeyCode(keyCode) else { return }

            let flags = event.modifierFlags
            let isDown: Bool
            switch keyName {
            case "ShiftLeft", "ShiftRight":
                isDown = flags.contains(.shift)
            case "ControlLeft", "ControlRight":
                isDown = flags.contains(.control)
            case "AltLeft", "AltRight":
                isDown = flags.contains(.option)
            case "MetaLeft", "MetaRight":
                isDown = flags.contains(.command)
                if isDown {
                    pendingCommandKeyCode = keyCode
                    activeCommandKeyCode = nil
                    commandKeySentToRemote = false
                    return
                }

                if commandKeySentToRemote {
                    let keyEvent = KeyEvent(
                        keyCode: activeCommandKeyCode ?? keyCode,
                        isKeyDown: false,
                        modifiers: flags,
                        timestamp: event.timestamp
                    )
                    sendKeyEvent(keyEvent)
                }

                clearPendingCommandKey()
                return
            case "CapsLock":
                isDown = flags.contains(.capsLock)
            default:
                return
            }

            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: isDown,
                modifiers: flags,
                timestamp: event.timestamp
            )
            sendKeyEvent(keyEvent)

        default:
            break
        }
    }

    private func prepareForLocalCommandShortcut() {
        if commandKeySentToRemote,
           transportMode == .glkvmWebSocket,
           let ws = glkvmWebSocketClient,
           let code = activeCommandKeyCode,
           let metaKey = glkvmKeyForMacKeyCode(code) {
            queueHidKey(metaKey, isDown: false, through: ws)
        }

        pendingCommandKeyCode = activeCommandKeyCode ?? pendingCommandKeyCode
        activeCommandKeyCode = nil
        commandKeySentToRemote = false
    }

    private func clearPendingCommandKey() {
        pendingCommandKeyCode = nil
        activeCommandKeyCode = nil
        commandKeySentToRemote = false
    }

    private func flushPendingCommandKeyIfNeeded(timestamp: TimeInterval, modifiers: NSEvent.ModifierFlags) {
        guard let pendingCommandKeyCode, commandKeySentToRemote == false else { return }
        activeCommandKeyCode = pendingCommandKeyCode
        self.pendingCommandKeyCode = nil
        commandKeySentToRemote = true

        let keyEvent = KeyEvent(
            keyCode: activeCommandKeyCode ?? pendingCommandKeyCode,
            isKeyDown: true,
            modifiers: modifiers,
            timestamp: timestamp
        )
        sendKeyEvent(keyEvent)
    }

    private func pasteClipboardToRemote() {
        guard let client = glkvmClient else { return }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            do {
                let keymap: String? = try? await client.getSystemConfig().keymap
                try await client.hidPrint(text: trimmed, keymap: keymap)
            } catch {
                print("Paste to remote failed: \(error)")
            }
        }
    }
    
    private func handleMouseEvent(_ event: NSEvent) {
        guard isMouseCaptureEnabled else { return }
        
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            let mouseEvent = MouseButtonEvent(
                button: event.type == .leftMouseDown || event.type == .leftMouseUp ? .left : .right,
                isDown: event.type == .leftMouseDown || event.type == .rightMouseDown,
                position: CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y),
                timestamp: event.timestamp
            )
            sendMouseButtonEvent(mouseEvent)
            
        case .mouseMoved:
            let mouseEvent = MouseMoveEvent(
                position: CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y),
                delta: CGSize(width: event.deltaX, height: -event.deltaY),
                timestamp: event.timestamp
            )
            sendMouseMoveEvent(mouseEvent)
            
        case .scrollWheel:
            let scrollEvent = MouseScrollEvent(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                timestamp: event.timestamp
            )
            sendMouseScrollEvent(scrollEvent)
            
        default:
            break
        }
    }
    
    func sendClick(at location: CGPoint, in geometry: GeometryProxy, videoSize: CGSize? = nil) {
        let normalizedPosition = normalizePointInViewToVideo(
            pointInView: location,
            viewSize: geometry.size,
            videoSize: videoSize
        )
        
        let clickEvent = MouseButtonEvent(
            button: .left,
            isDown: true,
            position: normalizedPosition,
            timestamp: CACurrentMediaTime()
        )
        
        sendMouseButtonEvent(clickEvent)
        
        // Send release event after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let releaseEvent = MouseButtonEvent(
                button: .left,
                isDown: false,
                position: normalizedPosition,
                timestamp: CACurrentMediaTime()
            )
            self.sendMouseButtonEvent(releaseEvent)
        }
    }
    
    private func sendKeyEvent(_ event: KeyEvent) {
        if transportMode == .glkvmWebSocket {
            guard let key = glkvmKeyForMacKeyCode(event.keyCode) else { return }
            guard let ws = glkvmWebSocketClient else {
                lastInputError = "Keyboard connection is not ready. Try reconnecting."
                return
            }
            queueHidKey(key, isDown: event.isKeyDown, through: ws)
            return
        }

        let inputEvent = InputEvent(
            type: "keyboard",
            data: [
                "keyCode": .int(Int(event.keyCode)),
                "isKeyDown": .bool(event.isKeyDown),
                "modifiers": .int(Int(event.modifiers.rawValue)),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseButtonEvent(_ event: MouseButtonEvent) {
        if transportMode == .glkvmWebSocket,
           let button = glkvmMouseButtonName(event.button),
           let ws = glkvmWebSocketClient {
            let shouldMove = isGLKVMAbsoluteMouseMode && isNormalized(event.position)
            let absolutePoint = shouldMove ? glkvmAbsolutePoint(fromNormalized: event.position) : nil
            Task {
                if let absolutePoint {
                    try? await ws.sendHidMouseMove(toX: absolutePoint.0, toY: absolutePoint.1)
                }
                try? await ws.sendHidMouseButton(button: button, state: event.isDown)
            }
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-button",
            data: [
                "button": .int(event.button.rawValue),
                "isDown": .bool(event.isDown),
                "x": .double(event.position.x),
                "y": .double(event.position.y),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseMoveEvent(_ event: MouseMoveEvent) {
        if transportMode == .glkvmWebSocket, isGLKVMAbsoluteMouseMode, isNormalized(event.position), let ws = glkvmWebSocketClient {
            let (toX, toY) = glkvmAbsolutePoint(fromNormalized: event.position)
            Task {
                try? await ws.sendHidMouseMove(toX: toX, toY: toY)
            }
            return
        }

        if transportMode == .glkvmWebSocket, !isGLKVMAbsoluteMouseMode, let ws = glkvmWebSocketClient {
            let move = PendingRelativeMouseMove(
                deltaX: Int(event.delta.width.rounded()),
                deltaY: Int(event.delta.height.rounded())
            )
            guard move.deltaX != 0 || move.deltaY != 0 else { return }
            Task {
                await Self.sendRelativeMouseMove(move, through: ws)
            }
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-move",
            data: [
                "x": .double(event.position.x),
                "y": .double(event.position.y),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseScrollEvent(_ event: MouseScrollEvent) {
        if transportMode == .glkvmWebSocket, let ws = glkvmWebSocketClient {
            let dx = Self.clampInt(Int(event.deltaX.rounded()), min: -127, max: 127)
            let dy = Self.clampInt(Int(event.deltaY.rounded()), min: -127, max: 127)
            let previous = inputSendTask
            inputSendTask = Task { [weak self] in
                await previous?.value
                do { try await ws.sendHidMouseWheel(deltaX: dx, deltaY: dy) }
                catch { self?.lastInputError = "Scroll input failed: \(error.localizedDescription)" }
            }
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-scroll",
            data: [
                "deltaX": .double(event.deltaX),
                "deltaY": .double(event.deltaY),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    func sendKeyCombination(_ keys: [UInt16], modifiers: NSEvent.ModifierFlags) {
        for keyCode in keys {
            let keyDownEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: true,
                modifiers: modifiers,
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyDownEvent)
        }
        
        // Send key up events after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for keyCode in keys.reversed() {
                let keyUpEvent = KeyEvent(
                    keyCode: keyCode,
                    isKeyDown: false,
                    modifiers: modifiers,
                    timestamp: CACurrentMediaTime()
                )
                self.sendKeyEvent(keyUpEvent)
            }
        }
    }
    
    func sendText(_ text: String) {
        for character in text {
            let keyCode = self.keyCodeForCharacter(character)
            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: true,
                modifiers: [],
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyEvent)
            
            // Send key up event
            let keyUpEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: false,
                modifiers: [],
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyUpEvent)
        }
    }
    
    private func keyCodeForCharacter(_ character: Character) -> UInt16 {
        // Basic mapping for common characters
        // In a real implementation, you'd want a more comprehensive mapping
        switch character {
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6
        case " ": return 49
        case "\n": return 36
        case ",": return 43
        case ".": return 47
        case "/": return 44
        case ";": return 41
        case "'": return 39
        case "[": return 33
        case "]": return 30
        case "\\": return 42
        case "`": return 50
        case "-": return 27
        case "=": return 24
        default: return 0
        }
    }
    
    deinit {
        permissionRetryTimer?.invalidate()
        if let observer = appFocusObserver { NotificationCenter.default.removeObserver(observer) }
        if let source = shortcutRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = shortcutEventTap { CFMachPortInvalidate(tap) }
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }

        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }

        mouseModeRefreshTask?.cancel()
        mouseModeRefreshTask = nil
    }

    private func reconnectGLKVMWebSocketIfNeeded() async {
        if transportMode != .glkvmWebSocket {
            return
        }
        guard let client = glkvmClient else {
            return
        }

        if glkvmWebSocketClient == nil {
            let ws = try? client.makeWebSocketClient(stream: false)
            glkvmWebSocketClient = ws
            await ws?.connect()
        }
    }

    private func isNormalized(_ point: CGPoint) -> Bool {
        point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1
    }

    private func glkvmAbsolutePoint(fromNormalized point: CGPoint) -> (Int, Int) {
        let clampedX = max(0, min(1, point.x))
        let clampedY = max(0, min(1, point.y))
        let maxAxis = 32767.0

        let signedX = (clampedX * 2.0 - 1.0) * maxAxis
        let signedY = (clampedY * 2.0 - 1.0) * maxAxis

        return (Int(signedX.rounded()), Int(signedY.rounded()))
    }

    func normalizePointInViewToVideo(pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }

        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            let clampedX = max(0, min(1, pointInView.x / viewSize.width))
            let clampedY = max(0, min(1, pointInView.y / viewSize.height))
            return CGPoint(x: clampedX, y: clampedY)
        }

        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = videoSize.width / videoSize.height

        var contentRect = CGRect(origin: .zero, size: viewSize)

        if viewAspect > videoAspect {
            let contentWidth = viewSize.height * videoAspect
            let xOffset = (viewSize.width - contentWidth) / 2.0
            contentRect = CGRect(x: xOffset, y: 0, width: contentWidth, height: viewSize.height)
        } else {
            let contentHeight = viewSize.width / videoAspect
            let yOffset = (viewSize.height - contentHeight) / 2.0
            contentRect = CGRect(x: 0, y: yOffset, width: viewSize.width, height: contentHeight)
        }

        let clampedX = max(contentRect.minX, min(contentRect.maxX, pointInView.x))
        let clampedY = max(contentRect.minY, min(contentRect.maxY, pointInView.y))

        let normalizedX = (clampedX - contentRect.minX) / contentRect.width
        let normalizedY = (clampedY - contentRect.minY) / contentRect.height

        return CGPoint(x: max(0, min(1, normalizedX)), y: max(0, min(1, normalizedY)))
    }

    private func glkvmMouseButtonName(_ button: MouseButton) -> String? {
        switch button {
        case .left:
            return "left"
        case .right:
            return "right"
        case .middle:
            return "middle"
        }
    }

    private func glkvmKeyForMacKeyCode(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 0: return "KeyA"
        case 11: return "KeyB"
        case 8: return "KeyC"
        case 2: return "KeyD"
        case 14: return "KeyE"
        case 3: return "KeyF"
        case 5: return "KeyG"
        case 4: return "KeyH"
        case 34: return "KeyI"
        case 38: return "KeyJ"
        case 40: return "KeyK"
        case 37: return "KeyL"
        case 46: return "KeyM"
        case 45: return "KeyN"
        case 31: return "KeyO"
        case 35: return "KeyP"
        case 12: return "KeyQ"
        case 15: return "KeyR"
        case 1: return "KeyS"
        case 17: return "KeyT"
        case 32: return "KeyU"
        case 9: return "KeyV"
        case 13: return "KeyW"
        case 7: return "KeyX"
        case 16: return "KeyY"
        case 6: return "KeyZ"

        case 18: return "Digit1"
        case 19: return "Digit2"
        case 20: return "Digit3"
        case 21: return "Digit4"
        case 23: return "Digit5"
        case 22: return "Digit6"
        case 26: return "Digit7"
        case 28: return "Digit8"
        case 25: return "Digit9"
        case 29: return "Digit0"

        case 50: return "Backquote"
        case 27: return "Minus"
        case 24: return "Equal"
        case 33: return "BracketLeft"
        case 30: return "BracketRight"
        case 41: return "Semicolon"
        case 39: return "Quote"
        case 42: return "Backslash"
        case 43: return "Comma"
        case 47: return "Period"
        case 44: return "Slash"

        case 49: return "Space"
        case 48: return "Tab"
        case 36: return "Enter"
        case 51: return "Backspace"
        case 53: return "Escape"

        case 82: return "Numpad0"
        case 83: return "Numpad1"
        case 84: return "Numpad2"
        case 85: return "Numpad3"
        case 86: return "Numpad4"
        case 87: return "Numpad5"
        case 88: return "Numpad6"
        case 89: return "Numpad7"
        case 91: return "Numpad8"
        case 92: return "Numpad9"
        case 65: return "NumpadDecimal"
        case 67: return "NumpadMultiply"
        case 69: return "NumpadAdd"
        case 78: return "NumpadSubtract"
        case 75: return "NumpadDivide"
        case 76: return "NumpadEnter"
        case 81: return "NumpadEqual"

        case 114: return "Help"

        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 117: return "Delete"

        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"

        case 55: return "MetaLeft"
        case 54: return "MetaRight"
        case 56: return "ShiftLeft"
        case 60: return "ShiftRight"
        case 58: return "AltLeft"
        case 61: return "AltRight"
        case 59: return "ControlLeft"
        case 62: return "ControlRight"
        case 57: return "CapsLock"

        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"

        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"

        default:
            return nil
        }
    }

    private static func sendRelativeMouseMove(_ move: PendingRelativeMouseMove, through ws: GLKVMClient.WebSocketClient) async {
        var remainingX = move.deltaX
        var remainingY = move.deltaY

        while remainingX != 0 || remainingY != 0 {
            let dx = clampInt(remainingX, min: -127, max: 127)
            let dy = clampInt(remainingY, min: -127, max: 127)
            try? await ws.sendHidMouseRelative(deltaX: dx, deltaY: dy)
            remainingX -= dx
            remainingY -= dy
        }
    }

    private static func clampInt(_ value: Int, min: Int, max: Int) -> Int {
        if value < min { return min }
        if value > max { return max }
        return value
    }
}

// MARK: - Input Event Types
struct KeyEvent {
    let keyCode: UInt16
    let isKeyDown: Bool
    let modifiers: NSEvent.ModifierFlags
    let timestamp: CFTimeInterval
}

struct MouseButtonEvent {
    let button: MouseButton
    let isDown: Bool
    let position: CGPoint
    let timestamp: CFTimeInterval
}

struct MouseMoveEvent {
    let position: CGPoint
    let delta: CGSize
    let timestamp: CFTimeInterval
}

struct MouseScrollEvent {
    let deltaX: CGFloat
    let deltaY: CGFloat
    let timestamp: CFTimeInterval
}

enum MouseButton: Int, Codable {
    case left = 0
    case right = 1
    case middle = 2
}

// MARK: - Input Capture Extensions
extension InputManager {
    func toggleKeyboardCapture() {
        if isKeyboardCaptureEnabled {
            stopKeyboardCapture()
        } else {
            startKeyboardCapture()
        }
    }
    
    func toggleMouseCapture() {
        if isMouseCaptureEnabled {
            stopMouseCapture()
        } else {
            startMouseCapture()
        }
    }
    
    func startFullInputCapture() {
        startKeyboardCapture()
        startMouseCapture()
    }
    
    func stopFullInputCapture() {
        stopKeyboardCapture()
        stopMouseCapture()
    }
}

// MARK: - Accessibility Permissions Helper
extension InputManager {
    func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }
    
    func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func showAccessibilityPermissionDialog() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permissions Required"
        alert.informativeText = "Overlook needs accessibility permissions to capture keyboard and mouse input for remote control. Please grant permissions in System Preferences > Security & Privacy > Privacy > Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open System Preferences to Accessibility section
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Input Validation and Filtering
extension InputManager {
    private func shouldCaptureKeyEvent(_ event: NSEvent) -> Bool {
        // Filter out system key combinations that should remain local
        let systemKeyCombinations: [UInt16] = [
            55, // Command
            56, // Shift
            57, // Option
            58, // Control
            59, // Caps Lock
            60, // Function
        ]
        
        return !systemKeyCombinations.contains(event.keyCode)
    }
    
    private func shouldCaptureMouseEvent(_ event: NSEvent) -> Bool {
        // Filter out mouse events that should remain local
        // This is a basic implementation - you might want to add more sophisticated filtering
        return true
    }
}

