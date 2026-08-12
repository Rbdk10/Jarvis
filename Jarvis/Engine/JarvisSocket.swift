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
///
/// Reliability contract (why this class looks the way it does):
///  • `status` is HONEST — it flips to `.connected` only when the socket truly opens
///    (the `didOpenWithProtocol` delegate callback), never just because we called
///    `resume()`. The UI and routing trust this, so it must not lie.
///  • A dead tunnel FAILS FAST — a connect that doesn't open within `connectTimeout`
///    is torn down and retried, instead of hanging on URLSession's minute-long default.
///  • Nothing you say is lost while reconnecting — user messages queue in `outbox`
///    (capped) and flush the moment the socket reopens.
///  • Reconnect backoff actually backs off (reset only on a real open) and self-heals
///    from send failures, ping failures, and app foregrounding.
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
    /// Jarvis's context-window fullness, 0–100%. The bridge derives it from the session's
    /// live token usage and pushes {"type":"context","pct":N}. Drives the on-screen gauge;
    /// when it climbs, he slows down and it's time to clear him (see `reset()`).
    var onContext: ((Int) -> Void)?
    /// Agent-directed narration (companion Phase B): the agent pushes a precise, first-person
    /// progress line to speak *now* while it keeps working — {"type":"say","text":"…"}. Unlike
    /// `reply` (the final answer, which ends the turn), a `say` is an interim update.
    var onSay: ((String) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var openWatchdog: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var pendingReconnect = false
    private var shouldRun = false

    /// User messages awaiting delivery (queued while disconnected, flushed on open).
    /// Capped so a long outage can't build an unbounded backlog of stale utterances.
    private var outbox: [String] = []
    private let outboxCap = 20

    private let connectTimeout: TimeInterval = 12

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = connectTimeout
        cfg.waitsForConnectivity = false     // fail fast + reconnect ourselves, don't silently wait
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    // MARK: Lifecycle

    func connect() {
        shouldRun = true
        guard let url = AppConfig.socketURL else { onError?("Bad socket URL"); return }
        // Tear down anything half-open before starting fresh.
        openWatchdog?.cancel(); openWatchdog = nil
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)

        status = .connecting
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
        startOpenWatchdog()
        // IMPORTANT: do NOT set `.connected` here — wait for `didOpenWithProtocol`.
    }

    func disconnect() {
        shouldRun = false
        pendingReconnect = false
        openWatchdog?.cancel(); openWatchdog = nil
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        status = .disconnected
    }

    /// App returned to the foreground. iOS suspends the socket while backgrounded, so the
    /// connection is often silently dead on return even though `status` still reads
    /// `.connected`. Re-establish immediately if not connected; otherwise probe liveness
    /// with a ping and reconnect if it fails. This is a top cause of "I open it and he's dead".
    func foreground() {
        guard shouldRun else { return }
        if status != .connected {
            reconnectAttempt = 0        // user is back — retry now, not on a long backoff
            pendingReconnect = false
            connect()
        } else {
            task?.sendPing { [weak self] err in
                guard err != nil else { return }
                Task { @MainActor in self?.handleDrop("stale connection after foreground") }
            }
        }
    }

    // MARK: Sending

    func send(text: String) {
        enqueueUserFrame(jsonString(["type": "message", "text": text]))
    }

    /// Send a photo to Jarvis. The bridge decodes `base64` (a JPEG), saves it, and hands
    /// the file path (plus the optional caption) to the agent.
    func sendImage(base64: String, caption: String?) {
        var payload: [String: Any] = ["type": "image_message", "data": base64]
        if let caption, !caption.isEmpty { payload["caption"] = caption }
        enqueueUserFrame(jsonString(payload))
    }

    /// Queue-and-send a user-visible frame: delivered now if connected, otherwise buffered
    /// and flushed on reconnect so a message spoken during a blip is never silently dropped.
    private func enqueueUserFrame(_ str: String?) {
        guard let str else { return }
        guard status == .connected, let task else {
            queue(str)
            ensureConnecting()
            return
        }
        task.send(.string(str)) { [weak self] err in
            guard let err else { return }
            Task { @MainActor in
                guard let self else { return }
                self.queue(str)                       // put it back; deliver on reconnect
                self.onError?(err.localizedDescription)
                self.handleDrop("send failed")
            }
        }
    }

    private func queue(_ str: String) {
        outbox.append(str)
        if outbox.count > outboxCap { outbox.removeFirst(outbox.count - outboxCap) }
    }

    private func flushOutbox() {
        guard status == .connected, let task, !outbox.isEmpty else { return }
        let pending = outbox
        outbox.removeAll()
        for str in pending {
            task.send(.string(str)) { [weak self] err in
                guard let err else { return }
                Task { @MainActor in
                    self?.queue(str)
                    self?.handleDrop(err.localizedDescription)
                }
            }
        }
    }

    /// Best-effort control frames — NOT queued (replaying a stale pong/reset is meaningless).
    private func sendControl(_ str: String) { task?.send(.string(str)) { _ in } }

    /// Reply to the bridge's application-level heartbeat so it keeps the socket open.
    private func sendPong() { sendControl(#"{"type":"pong"}"#) }

    /// Ask the bridge to clear Jarvis's working memory — it runs `/clear` on the session
    /// (instant, keeps him warm), so he's fast again once his context has filled up.
    func reset() { sendControl(#"{"type":"reset"}"#) }

    // MARK: Receiving

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
        // Interim agent-directed narration (companion) — speak now, keep working.
        case "say":    if let text = obj["text"] as? String { onSay?(text) }
        // The bridge sends application-level {"type":"ping"} heartbeats every ~10s and
        // closes the socket ("no pong") if it doesn't get a {"type":"pong"} back within
        // ~30s. (These are JSON frames, distinct from the WS control-frame ping in
        // startPing().) Without this the connection drops every ~30s mid-conversation.
        case "ping":   sendPong()
        case "status": if let label = obj["label"] as? String { onStatus?(label) }
        case "error":  onError?(obj["message"] as? String ?? "error")
        case "open_url": if let url = obj["url"] as? String { onOpenURL?(url) }
        case "context": if let n = obj["pct"] as? NSNumber { onContext?(n.intValue) }
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

    // MARK: Keep-alive + reconnect

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.task?.sendPing { err in
                    guard err != nil else { return }
                    Task { @MainActor in self.handleDrop("keep-alive ping failed") }
                }
            }
        }
    }

    /// If a connect attempt doesn't actually open within `connectTimeout`, treat it as a
    /// failed attempt and back off — instead of sitting in `.connecting` forever.
    private func startOpenWatchdog() {
        openWatchdog?.cancel()
        let timeout = connectTimeout
        openWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.status == .connecting else { return }
            self.task?.cancel(with: .goingAway, reason: nil)
            self.handleDrop("connect timed out")
        }
    }

    private func handleOpen() {
        openWatchdog?.cancel(); openWatchdog = nil
        reconnectAttempt = 0        // real open — only NOW is it safe to reset the backoff
        pendingReconnect = false
        status = .connected
        startPing()
        flushOutbox()               // deliver anything said during the outage
    }

    private func handleDrop(_ reason: String) {
        openWatchdog?.cancel(); openWatchdog = nil
        pingTimer?.invalidate(); pingTimer = nil
        task = nil
        status = .disconnected
        guard shouldRun else { return }
        scheduleReconnect()
    }

    /// Kick a reconnect if we're meant to be running but aren't connected and none is pending.
    private func ensureConnecting() {
        guard shouldRun, status == .disconnected else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldRun, !pendingReconnect else { return }
        pendingReconnect = true
        reconnectAttempt += 1
        let base = min(pow(2.0, Double(reconnectAttempt)), 15)   // 2,4,8,15,15… seconds
        let delay = min(base + Double.random(in: 0...0.4) * base, 20)   // + jitter to avoid lockstep
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.pendingReconnect = false
            guard self.shouldRun, self.status != .connected else { return }
            self.connect()
        }
    }

    // MARK: Helpers

    private func jsonString(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - URLSessionWebSocketDelegate (honest connected/disconnected signals)

extension JarvisSocket: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol proto: String?) {
        Task { @MainActor [weak self] in
            guard let self, webSocketTask === self.task else { return }
            self.handleOpen()
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        Task { @MainActor [weak self] in
            guard let self, webSocketTask === self.task else { return }
            self.handleDrop("socket closed (\(closeCode.rawValue))")
        }
    }
}
