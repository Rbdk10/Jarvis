import Foundation

/// An artifact pushed from the Jarvis backend (jarvis_artifact tool): text, html or
/// a base64 image. Shown in the swipe-up artifacts panel.
struct JarvisArtifact: Identifiable, Equatable {
    let id = UUID()
    let kind: String        // "text" | "html" | "image"
    let name: String
    let data: String        // text/html string, or base64 image data
    let timestamp: Date
}

/// WebSocket client to the Jarvis bridge. Text-only protocol:
///   send:    {"type":"message","text": "..."}
///   receive: {"type":"reply","text": "..."} / "status" / "error" / "artifact"
@MainActor
final class JarvisSocket: NSObject, ObservableObject {
    enum Status { case disconnected, connecting, connected }
    @Published var status: Status = .disconnected

    var onReply: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onArtifact: ((JarvisArtifact) -> Void)?
    /// Agent asks the app to open the projector on a URL: {"type":"open_url","url":"https://…"}
    var onOpenURL: ((String) -> Void)?

    private lazy var session: URLSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectAttempt = 0
    private var shouldRun = false

    /// True only once the WebSocket handshake has actually completed (set by the delegate),
    /// so callers never send into a socket that isn't really up. `status` mirrors this for the UI.
    private(set) var isConnected = false

    func connect() {
        shouldRun = true
        guard let url = AppConfig.socketURL else { onError?("Bad socket URL"); return }
        status = .connecting
        isConnected = false
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
        startPing()
        // NOTE: do NOT mark .connected here — the task has only been *started*. We flip to
        // .connected from urlSession(_:webSocketTask:didOpenWithProtocol:) once the handshake
        // genuinely succeeds, so a dead bridge or a rejected token no longer shows as "Ready".
    }

    func disconnect() {
        shouldRun = false
        isConnected = false
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        status = .disconnected
    }

    func send(text: String) {
        let payload: [String: Any] = ["type": "message", "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        // If the socket isn't actually up, `task?.send` would silently no-op and the agent
        // would just never reply. Surface it instead so the caller can recover (and try to
        // reconnect so the next turn has a chance).
        guard let task, isConnected else {
            onError?("Not connected to the agent. Reconnecting…")
            if shouldRun { connect() }
            return
        }
        task.send(.string(str)) { [weak self] err in
            if let err { Task { @MainActor in self?.onError?(err.localizedDescription) } }
        }
    }

    /// Send a photo to Jarvis. The bridge decodes `base64` (a JPEG), saves it, and hands
    /// the file path (plus the optional caption) to the agent.
    func sendImage(base64: String, caption: String?) {
        var payload: [String: Any] = ["type": "image_message", "data": base64]
        if let caption, !caption.isEmpty { payload["caption"] = caption }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        guard let task, isConnected else {
            onError?("Not connected to the agent. Reconnecting…")
            if shouldRun { connect() }
            return
        }
        task.send(.string(str)) { [weak self] err in
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
        case "open_url": if let url = obj["url"] as? String { onOpenURL?(url) }
        case "artifact":
            onArtifact?(JarvisArtifact(
                kind: (obj["artifact_type"] as? String) ?? (obj["kind"] as? String) ?? "text",
                name: (obj["name"] as? String) ?? "Untitled",
                data: (obj["data"] as? String) ?? "",
                timestamp: Date()
            ))
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
        isConnected = false
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

// MARK: - Real connection state

/// The handshake-level open/close signals. Without these the task reports "started" as
/// "connected"; with them, `status`/`isConnected` reflect whether the bridge is genuinely up.
extension JarvisSocket: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                               didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            self.isConnected = true
            self.reconnectAttempt = 0
            self.status = .connected
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                               didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                               reason: Data?) {
        // The outstanding receive() will also fail and drive the reconnect; here we just make
        // sure the connected flag/status drop immediately so no send slips through a dead socket.
        Task { @MainActor in
            self.isConnected = false
            if self.status == .connected { self.status = .disconnected }
        }
    }
}
