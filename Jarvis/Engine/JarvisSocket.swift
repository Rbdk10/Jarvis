import Foundation

/// WebSocket client to the Jarvis bridge. Text-only protocol:
///   send:    {"type":"message","text": "..."}
///   receive: {"type":"reply","text": "..."} / "status" / "error"
@MainActor
final class JarvisSocket: NSObject, ObservableObject {
    enum Status { case disconnected, connecting, connected }
    @Published var status: Status = .disconnected

    var onReply: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectAttempt = 0
    private var shouldRun = false

    func connect() {
        shouldRun = true
        guard let url = AppConfig.socketURL else { onError?("Bad socket URL"); return }
        status = .connecting
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
        startPing()
        status = .connected
        reconnectAttempt = 0
    }

    func disconnect() {
        shouldRun = false
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        status = .disconnected
    }

    func send(text: String) {
        let payload: [String: Any] = ["type": "message", "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { [weak self] err in
            if let err { Task { @MainActor in self?.onError?(err.localizedDescription) } }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                Task { @MainActor in self.handleDrop(err.localizedDescription) }
            case .success(let msg):
                Task { @MainActor in
                    switch msg {
                    case .string(let s): self.handle(s)
                    case .data(let d): if let s = String(data: d, encoding: .utf8) { self.handle(s) }
                    @unknown default: break
                    }
                    self.receive()
                }
            }
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "reply":  if let text = obj["text"] as? String { onReply?(text) }
        case "status": if let label = obj["label"] as? String { onStatus?(label) }
        case "error":  onError?(obj["message"] as? String ?? "error")
        default: break
        }
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.task?.sendPing { _ in }
        }
    }

    private func handleDrop(_ reason: String) {
        status = .disconnected
        pingTimer?.invalidate(); pingTimer = nil
        guard shouldRun else { return }
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt)), 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.shouldRun else { return }
            self.connect()
        }
    }
}
