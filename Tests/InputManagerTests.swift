import AppKit

// Compiled in the same file as InputManager by run-input-tests.sh. No events are
// posted to macOS and no network connections or Accessibility prompts are made.
extension InputManager {
    func attachTestTransport(_ client: GLKVMClient) {
        glkvmClient = client
        glkvmWebSocketClient = client.socket
        isKeyboardCaptureEnabled = true
    }

    func feedTestKey(_ code: UInt16, type: CGEventType, flags: UInt64 = 0) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown)!
        event.type = type
        event.flags = CGEventFlags(rawValue: flags)
        handleKeyEvent(NSEvent(cgEvent: event)!)
    }

    func drainTestInput() async { await inputSendTask?.value }
    func drainTestMouseModeRefresh() async { await mouseModeRefreshTask?.value }
    func testReleaseKeys() { releaseRemoteKeys() }
}

@main
struct InputTests {
    @MainActor static func main() async throws {
        UserDefaults.standard.set(true, forKey: "overlook.forwardMacShortcuts")
        defer {
            UserDefaults.standard.removeObject(forKey: "overlook.forwardMacShortcuts")
            UserDefaults.standard.removeObject(forKey: "overlook.invertScrolling")
        }
        let client = GLKVMClient()
        let manager = InputManager()
        manager.attachTestTransport(client)

        let command = CGEventFlags.maskCommand.rawValue
        let option = CGEventFlags.maskAlternate.rawValue
        let control = CGEventFlags.maskControl.rawValue
        let shift = CGEventFlags.maskShift.rawValue

        // Command+C/V stay remote, and Command+Tab uses the same modifier sequence.
        for code: UInt16 in [8, 9, 48] {
            manager.feedTestKey(55, type: .flagsChanged, flags: command | 0x8)
            manager.feedTestKey(code, type: .keyDown, flags: command)
            manager.feedTestKey(code, type: .keyUp, flags: command)
            manager.feedTestKey(55, type: .flagsChanged)
        }
        manager.feedTestKey(58, type: .flagsChanged, flags: option | 0x20)
        manager.feedTestKey(123, type: .keyDown, flags: option)
        manager.feedTestKey(123, type: .keyUp, flags: option)
        manager.feedTestKey(58, type: .flagsChanged)
        manager.feedTestKey(59, type: .flagsChanged, flags: control | 0x1)
        manager.feedTestKey(124, type: .keyDown, flags: control)
        manager.feedTestKey(124, type: .keyUp, flags: control)
        manager.feedTestKey(59, type: .flagsChanged)
        await manager.drainTestInput()
        let expected = ["MetaLeft:down", "KeyC:down", "KeyC:up", "MetaLeft:up",
                        "MetaLeft:down", "KeyV:down", "KeyV:up", "MetaLeft:up",
                        "MetaLeft:down", "Tab:down", "Tab:up", "MetaLeft:up",
                        "AltLeft:down", "ArrowLeft:down", "ArrowLeft:up", "AltLeft:up",
                        "ControlLeft:down", "ArrowRight:down", "ArrowRight:up", "ControlLeft:up"]
        let chords = await client.socket.takeKeys()
        precondition(chords == expected, "Incorrect Mac shortcut mapping/order: \(chords)")
        precondition(manager.capturedKeyEventCount == expected.count)
        precondition(manager.heldCapturedKeys == "—")
        precondition(manager.lastCaptureSource == "App")

        // Releasing one side must not get confused by the other side remaining held.
        manager.feedTestKey(56, type: .flagsChanged, flags: shift | 0x2)
        manager.feedTestKey(60, type: .flagsChanged, flags: shift | 0x6)
        manager.feedTestKey(56, type: .flagsChanged, flags: shift | 0x4)
        manager.feedTestKey(60, type: .flagsChanged)
        await manager.drainTestInput()
        let shifts = await client.socket.takeKeys()
        precondition(shifts == ["ShiftLeft:down", "ShiftRight:down", "ShiftLeft:up", "ShiftRight:up"])

        // Losing focus/pausing capture must release held keys, in the correct order.
        manager.feedTestKey(55, type: .flagsChanged, flags: command | 0x8)
        manager.feedTestKey(0, type: .keyDown, flags: command)
        precondition(manager.heldCapturedKeys == "⌘ A")
        precondition(manager.lastCapturedKeyEvent == "⌘ A ↓")
        manager.testReleaseKeys()
        precondition(manager.heldCapturedKeys == "—")
        await manager.drainTestInput()
        let releases = await client.socket.takeKeys()
        precondition(releases == ["MetaLeft:down", "KeyA:down", "KeyA:up", "MetaLeft:up"])

        client.activeMouseMode = false
        manager.refreshGLKVMMouseMode(for: client, savedMode: true)
        await manager.drainTestMouseModeRefresh()
        precondition(!manager.isGLKVMAbsoluteMouseMode, "Active relative HID mode must take precedence")
        client.activeMouseMode = nil
        manager.refreshGLKVMMouseMode(for: client)
        await manager.drainTestMouseModeRefresh()
        precondition(manager.isGLKVMAbsoluteMouseMode, "Use the saved mode when HID mode is unavailable")

        manager.isMouseCaptureEnabled = true
        manager.invertScrolling = false
        manager.handleVideoMouseScroll(deltaX: 3, deltaY: -5)
        await manager.drainTestInput()
        manager.invertScrolling = true
        manager.handleVideoMouseScroll(deltaX: 3, deltaY: -5)
        await manager.drainTestInput()
        manager.isMouseCaptureEnabled = false
        manager.handleVideoMouseScroll(deltaX: 3, deltaY: -5)
        let wheels = await client.socket.takeWheelEvents()
        precondition(wheels == [[3, -5], [-3, 5]], "Scroll inversion or capture gating failed")

        // Wake does not depend on a video manager, input capture, or a HID WebSocket.
        manager.stopKeyboardCapture()
        try await manager.wakeHost()
        precondition(client.httpKeys == ["ShiftLeft:down", "ShiftLeft:up"])

        // Input errors must be visible rather than silently dropped.
        manager.isKeyboardCaptureEnabled = true
        await client.socket.setFailSending(true)
        manager.feedTestKey(0, type: .keyDown)
        await manager.drainTestInput()
        precondition(manager.lastInputError != nil)
        manager.testReleaseKeys()
        await manager.drainTestInput()
        await client.socket.setFailSending(false)
        _ = await client.socket.takeKeys()
        manager.feedTestKey(59, type: .flagsChanged, flags: control | 0x1)
        manager.feedTestKey(58, type: .flagsChanged, flags: control | option | 0x21)
        manager.feedTestKey(53, type: .keyDown, flags: control | option)
        await manager.drainTestInput()
        precondition(!manager.forwardMacShortcuts)
        let escape = await client.socket.takeKeys()
        precondition(escape == ["ControlLeft:down", "AltLeft:down", "AltLeft:up", "ControlLeft:up"])
        print("PASS: Mac shortcut mapping/order, left/right modifiers, key release, wake without video, visible input errors, escape shortcut")
    }
}
