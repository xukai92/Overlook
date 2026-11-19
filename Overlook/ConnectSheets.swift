import SwiftUI

struct ManualConnectSheet: View {
    @Binding var isPresented: Bool
    @Binding var hostPort: String
    @Binding var port: String
    @Binding var password: String

    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manual Connect")
                .font(.headline)

            TextField("Host or IP (optionally host:port)", text: $hostPort)
                .textFieldStyle(.roundedBorder)

            TextField("Port", text: $port)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            DeviceCertificateToggle(host: hostPort)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button("Connect") {
                    onConnect()
                    isPresented = false
                }
                .disabled(hostPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

struct PasswordPromptSheet: View {
    var host: String = ""
    @Binding var isPresented: Bool
    @Binding var password: String

    let onCancel: () -> Void
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password Required")
                .font(.headline)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            DeviceCertificateToggle(host: host)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    isPresented = false
                }
                Button("Connect") {
                    onConnect()
                    isPresented = false
                }
                .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

struct DeviceCertificateToggle: View {
    let host: String
    @AppStorage(DeviceTLSPolicy.defaultsKey) private var allowedHostsData = Data()

    var body: some View {
        let normalizedHost = DeviceTLSPolicy.normalizedHost(host)
        Toggle("Allow self-signed device certificates", isOn: Binding(
            get: { DeviceTLSPolicy.allowedHosts(from: allowedHostsData).contains(normalizedHost) },
            set: { enabled in
                guard !normalizedHost.isEmpty else { return }
                var hosts = DeviceTLSPolicy.allowedHosts(from: allowedHostsData)
                if enabled { hosts.insert(normalizedHost) } else { hosts.remove(normalizedHost) }
                allowedHostsData = (try? JSONEncoder().encode(hosts.sorted())) ?? Data()
            }
        ))
        .toggleStyle(.checkbox)
        .disabled(normalizedHost.isEmpty)
        .help("For this host only. Also accepts expired or mismatched certificates. Use on a trusted network or VPN. Reconnect after changing.")
    }
}

struct MacShortcutControls: View {
    var showsCaptureToggle = true
    @EnvironmentObject var inputManager: InputManager
    @AppStorage("overlook.showCapturedKeys") private var showCapturedKeys = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsCaptureToggle {
                Toggle("Forward macOS shortcuts", isOn: $inputManager.forwardMacShortcuts)
                    .toggleStyle(.checkbox)
            }
            Toggle("Show captured keys", isOn: $showCapturedKeys)
                .toggleStyle(.checkbox)
            Text("While Overlook is active. Release with ⌃⌥Esc.")
                .font(.caption)
                .foregroundColor(.secondary)
            if let status = inputManager.shortcutCaptureStatus {
                Text(status).font(.caption)
                    .foregroundColor(inputManager.systemShortcutCaptureReady ? .secondary : .orange)
            }
            if inputManager.forwardMacShortcuts && !inputManager.systemShortcutCaptureReady {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Keyboard access settings") { inputManager.openAccessibilitySettings() }
                    Button("Check access") { inputManager.recheckShortcutAccess() }
                }
            }
            if let error = inputManager.lastInputError {
                Text(error).font(.caption).foregroundColor(.orange)
            }
        }
    }
}

struct WakeHostButton: View {
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager
    @State private var isWaking = false
    @State private var wakeError: String?

    var body: some View {
        Button(isWaking ? "Waking…" : "Wake display") {
            isWaking = true
            Task { @MainActor in
                defer { isWaking = false }
                do { try await inputManager.wakeHost() }
                catch { wakeError = error.localizedDescription }
            }
        }
        .disabled(isWaking || kvmDeviceManager.glkvmClient == nil)
        .help("Send a brief Shift press to wake the remote Mac. Works without video.")
        .alert("Could not wake display", isPresented: Binding(
            get: { wakeError != nil }, set: { if !$0 { wakeError = nil } }
        )) {
            Button("OK") { wakeError = nil }
        } message: {
            Text(wakeError ?? "")
        }
    }
}

struct CaptureSidebarView: View {
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager
    @AppStorage("overlook.showCapturedKeys") private var showCapturedKeys = true
    @AppStorage("overlook.hideLocalPointer") private var hideLocalPointer = false

    let onConnections: () -> Void
    let onSettings: () -> Void
    let onHide: () -> Void
    let onNativeSize: () -> Void
    let onFitDisplay: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Remote control").font(.headline)
                        Spacer()
                        Button(action: onHide) { Image(systemName: "sidebar.right") }
                            .buttonStyle(.borderless)
                            .help("Hide sidebar")
                    }
                    Text(kvmDeviceManager.connectedDevice?.name ?? "No device connected")
                        .font(.caption).foregroundColor(.secondary)
                        .textSelection(.disabled)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Forward macOS shortcuts", isOn: $inputManager.forwardMacShortcuts)
                        .toggleStyle(.switch)
                    Text(inputManager.keyboardCaptureLabel)
                        .font(.caption).fontWeight(.medium)
                    Toggle("Hide local pointer", isOn: $hideLocalPointer)
                        .toggleStyle(.checkbox)
                        .help("Hide this Mac’s pointer while controlling the video. Leave it visible to see when it moves outside the video.")
                    Toggle("Invert scrolling", isOn: $inputManager.invertScrolling)
                        .toggleStyle(.checkbox)
                        .help("Reverse horizontal and vertical scrolling sent from this Mac. Remote settings stay unchanged.")
                    MacShortcutControls(showsCaptureToggle: false)
                }

                if showCapturedKeys {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Captured keys").font(.subheadline).fontWeight(.semibold)
                        Text(inputManager.heldCapturedKeys)
                            .font(.system(.title3, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            .padding(.horizontal, 10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                        Text(inputManager.lastCapturedKeyEvent)
                            .font(.system(.caption, design: .monospaced))
                        Text("\(inputManager.capturedKeyEventCount) events · \(inputManager.lastCaptureSource)")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Button("Native size", action: onNativeSize)
                        .disabled(webRTCManager.videoSize == nil)
                        .help("Use the remote resolution as the video area's size in macOS points.")
                    Button("Fit to screen", action: onFitDisplay)
                        .disabled(webRTCManager.videoSize == nil)
                    WakeHostButton()
                    Button("Connections…", action: onConnections)
                    Button("Device settings…", action: onSettings)
                        .disabled(kvmDeviceManager.glkvmClient == nil)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
