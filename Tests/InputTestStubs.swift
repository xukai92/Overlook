import Foundation

struct InputEvent { let type: String; let data: [String: JSONValue] }
@MainActor final class WebRTCManager { func sendInputEvent(_ event: InputEvent) {} }

final class GLKVMClient {
    struct Config { let isAbsoluteMouse = true; let keymap = "en-us" }
    let socket = WebSocketClient()
    var httpKeys: [String] = []
    func getSystemConfig() async throws -> Config { Config() }
    func hidPrint(text: String, keymap: String?) async throws { fatalError("Clipboard paste must not intercept forwarded shortcuts") }
    func sendHidKey(key: String, state: Bool) async throws { httpKeys.append("\(key):\(state ? "down" : "up")") }
    func makeWebSocketClient(stream: Bool) throws -> WebSocketClient { socket }
    actor WebSocketClient {
        enum WebSocketError: Error { case notConnected }
        var keys: [String] = []
        var wheelEvents: [[Int]] = []
        func takeWheelEvents() -> [[Int]] { defer { wheelEvents.removeAll() }; return wheelEvents }
        var failSending = false
        func setFailSending(_ enabled: Bool) { failSending = enabled }
        func takeKeys() -> [String] { defer { keys.removeAll() }; return keys }
        func connect() {}
        func disconnect() {}
        func sendHidKey(key: String, state: Bool) throws {
            if failSending { throw WebSocketError.notConnected }
            keys.append("\(key):\(state ? "down" : "up")")
        }
        func sendHidMouseMove(toX: Int, toY: Int) throws {}
        func sendHidMouseRelative(deltaX: Int, deltaY: Int) throws {}
        func sendHidMouseButton(button: String, state: Bool) throws {}
        func sendHidMouseWheel(deltaX: Int, deltaY: Int) throws { wheelEvents.append([deltaX, deltaY]) }
    }
}
