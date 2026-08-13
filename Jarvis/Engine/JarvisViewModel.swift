import Foundation
import Combine

/// One step in the activity trace (swipe-right log).
struct ActivityEntry: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
}

/// One line in the text-mode chat transcript. Built up in both modes so switching
/// voice→text (or back) keeps a coherent history.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, jarvis }
    let id = UUID()
    let role: Role
    let text: String
    let time: Date
}

/// Orchestrates: idle → listening → thinking → speaking → idle.
/// Publishes `level` (0...1) for the orb and `state`/`statusText` for the UI.
///
/// Listening is hands-free: when idle, the mic is armed and voice-activity detection
/// starts capture on speech and ends it on a trailing silence — no button to hold.
/// The orb's `level` is fed *only* while Jarvis speaks, so the strands stay still
/// while you talk and stir only on Jarvis's own voice.
@MainActor
final class JarvisViewModel: ObservableObject {
    enum State: Equatable { case idle, listening, thinking, speaking, error(String) }

    @Published var state: State = .idle
    @Published var level: Float = 0
    @Published var statusText: String = "Connecting…"
    /// True while the socket is establishing a connection — used to show the stop control
    /// during "connecting" as well as "thinking".
    @Published var connecting: Bool = true
    /// When true (default), Jarvis listens automatically. The button toggles this.
    @Published var handsFree: Bool = true

    /// There's now a single agent. Every real utterance goes to it, with the fast brain riding
    /// along as the live companion narrator — so the agent does the work while the chatbot
    /// keeps you company. This just tags the in-flight turn for the activity trace + telemetry:
    /// `.agent` for real work, `.chatbot` for the instant on-device presets; nil when idle.
    enum RouteMode { case auto, chatbot, agent }
    @Published var activeHandler: RouteMode?

    /// Set by the agent (over the socket) to open the projector on a public URL — e.g. when
    /// you say "show me the page of project X". ContentView observes this and opens the panel.
    @Published var previewRequest: String?

    /// Jarvis's context-window fullness, 0–100%, pushed live from the bridge. `nil` until the
    /// first report. As it climbs he slows down; tapping the on-screen gauge clears him.
    @Published var contextPct: Int?

    // MARK: Reply mode (voice ↔ text)

    /// Voice (default): replies are spoken and the mic listens hands-free.
    /// Text: Jarvis stays silent, the mic + wake word are off, and replies appear
    /// on-screen in the chat transcript. The header toggle flips this.
    enum ReplyMode { case voice, text }
    @Published var replyMode: ReplyMode = .voice

    /// The on-screen chat transcript (text mode). Filled in both modes so switching
    /// voice→text keeps the conversation history intact.
    @Published var messages: [ChatMessage] = []

    /// Flip between spoken and on-screen replies. Entering text mode goes fully silent
    /// (cuts speech, closes the mic, stops the wake word); leaving it resumes listening.
    func setReplyMode(_ m: ReplyMode) {
        guard m != replyMode else { return }
        replyMode = m
        switch m {
        case .text:
            stopCompanion()           // end any voice narration before going silent
            speechGen &+= 1            // supersede any in-flight speak/filler
            voice.stop()
            wake.stop(); recorder.stop()
            armed = false; heardSpeech = false; level = 0
            if state == .listening || state == .speaking { state = .idle }
            activeHandler = nil
            statusText = "Text mode"
            log("⌨️ Switched to text mode")
        case .voice:
            statusText = "Ready"
            log("🔊 Switched to voice mode")
            beginIdleListening()
        }
    }

    /// Append a line to the chat transcript, trimming and capping the history.
    private func appendMessage(_ role: ChatMessage.Role, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        messages.append(ChatMessage(role: role, text: t, time: Date()))
        if messages.count > 300 { messages.removeFirst(messages.count - 300) }
    }

    /// Artifacts Jarvis has sent, newest last — shown in the swipe-up panel.
    @Published var artifacts: [JarvisArtifact] = []
    /// Timestamped step-by-step trace of what Jarvis is doing — shown in the swipe-right
    /// panel, so you can see exactly where the response time goes.
    @Published var activityLog: [ActivityEntry] = []

    private func log(_ text: String) {
        activityLog.append(ActivityEntry(time: Date(), text: text))
        if activityLog.count > 150 { activityLog.removeFirst(activityLog.count - 150) }
    }

    let socket = JarvisSocket()
    private let recorder = AudioRecorder()
    private let voice = ElevenLabsService()
    private let wake = WakeWordListener()
    private let onDeviceSTT = OnDeviceSTT()
    /// Running tally of what the fast brain has cost on the Anthropic key (persisted).
    let costMeter = CostMeter()
    /// Fast half of the two-speed brain: answers chit-chat on-device, delegates tasks.
    private lazy var fastBrain = FastBrain(meter: costMeter)
    private var bag = Set<AnyCancellable>()
    private var speechAuthRequested = false
    private var capNoticeLogged = false     // one-time "spend cap reached" notice
    private var suppressBacklogUntil: Date = .distantPast   // swallow replies right after a drain

    // Routing telemetry: how the current turn routed + when it started, logged on delivery
    // (to the on-screen trace and to Supabase, so the dispatcher can be tuned from real use).
    private var turnStart: Date?
    private var lastUtterance = ""
    private var pendingRoute: (tier: String, model: String?, reason: String, escalated: Bool)?

    /// Drives the Dynamic Island / Lock Screen Live Activity so Jarvis is present across apps.
    private let live = LiveActivityController()

    // MARK: Voice-activity detection
    private var armed = false               // mic is open, waiting for / capturing speech
    private var heardSpeech = false         // speech has begun within this capture
    private var voiceRunUp = 0              // consecutive over-threshold meter samples
    private var silenceTicks = 0            // consecutive below-threshold samples after speech
    private let speechOn: Float = 0.16      // level to count as voice (with hysteresis)
    private let speechOff: Float = 0.11
    private let runUpToStart = 3            // ~0.15s of voice to begin capture — kept snappy so
                                            // short commands and a quick reply after the wake
                                            // word still register. Footsteps/noise are filtered
                                            // AFTER capture by the STT confidence gate below,
                                            // not by making the onset harder (which also ate
                                            // real short speech).
    private static let minSTTConfidence: Float = 0.30  // below this, on-device STT is treated
                                            // as background noise and dropped, not answered.
    private let silenceToEnd = 6            // ~0.3s of trailing silence to end (×0.05s) — snappier turn-taking.
                                            // Backed by adaptive endpointing (recentPeak) so it holds up in
                                            // noise. If he starts cutting you off mid-thought, bump back to 8.
    private var noSpeechTicks = 0           // ticks listening-but-silent after the wake word
    private let noSpeechTimeout = 160       // ~8s of no speech → drop back to wake word
    private var recentPeak: Float = 0       // decaying peak of your speaking volume (adaptive endpointing)

    // Speech serialisation — guarantees Jarvis never talks over himself.
    private var speechGen = 0               // bumped per reply / interrupt; stale tasks no-op
    private var speakingText = ""           // currently-spoken text, for duplicate suppression

    // MARK: Companion overlay — the fast brain narrates the agent's work in real time.
    // While the agent (the deep worker) runs, the on-device brain keeps you company: an
    // instant tailored opener, then paced spoken updates grounded in the agent's live status
    // stream — so there's never dead air, and the final agent answer still lands as the real
    // reply. Voice mode only; falls back to the canned filler when the fast brain is off.
    private var agentTurnActive = false     // companion narration overlay is running (voice + fast brain)
    /// An agent turn is in flight — true in EVERY mode (text too), whether or not the companion
    /// is narrating. Gates `ask`, mid-work talk, and (in the UI) the always-available cancel.
    @Published private(set) var agentBusy = false
    private var awaitingAgentAnswer = false // Jarvis asked a question and is waiting; the next utterance is
                                            // the ANSWER — fed straight back into the same turn, not a new one.
    private var companionRequest = ""       // the utterance the agent is working on (context for narration)
    private var statusBuffer: [String] = [] // recent agent status lines to narrate from
    private var narrationSaid: [String] = []// what the companion has already spoken (avoid repeats)
    private var narrationTask: Task<Void, Never>?   // the paced narration loop
    private var lastNarration = Date.distantPast    // gates the "quiet worker" reassurance
    private var agentDirectedNarration = false      // Phase B: once the agent pushes a `say`, it's
                                                    // driving the narration — the auto-narrator yields.

    init() {
        wake.onWake = { [weak self] in self?.onWake() }
        socket.onReply = { [weak self] text in self?.handleReply(text) }
        socket.onError = { [weak self] msg in self?.setError(msg) }
        socket.onArtifact = { [weak self] art in self?.artifacts.append(art) }
        socket.onOpenURL = { [weak self] url in self?.previewRequest = url }
        socket.onContext = { [weak self] pct in self?.contextPct = pct }
        socket.onSay = { [weak self] text in self?.handleAgentSay(text) }
        socket.onAsk = { [weak self] text in self?.handleAgentAsk(text) }
        socket.onStatus = { [weak self] label in
            guard let self else { return }
            // Live "what I'm doing" feed — only meaningful while thinking.
            if self.state == .thinking { self.statusText = label }
            self.log(label)
            // Feed the companion so it can narrate real progress (not invent it).
            if self.agentTurnActive {
                self.statusBuffer.append(label)
                if self.statusBuffer.count > 12 { self.statusBuffer.removeFirst(self.statusBuffer.count - 12) }
            }
        }

        // Mic meter drives voice-activity detection. It never drives the orb — the
        // orb only moves to Jarvis's voice (see the playbackLevel sink below).
        recorder.$level
            .sink { [weak self] lvl in self?.handleMicLevel(lvl) }
            .store(in: &bag)

        voice.$playbackLevel
            .sink { [weak self] lvl in
                guard let self, self.state == .speaking else { return }
                self.level = lvl
            }.store(in: &bag)

        // Mirror Jarvis's state into the Dynamic Island / Lock Screen so he's present across
        // apps. Throttled so rapid status churn doesn't spam ActivityKit updates.
        Publishers.CombineLatest($state, $statusText)
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.syncLiveActivity() }
            .store(in: &bag)

        socket.$status
            .sink { [weak self] st in
                guard let self else { return }
                switch st {
                case .connected:
                    self.connecting = false
                    if self.state == .idle {
                        self.statusText = "Ready"
                        self.beginIdleListening()
                    }
                case .connecting:   self.connecting = true;  self.statusText = "Connecting…"
                case .disconnected: self.connecting = false; self.statusText = "Offline"
                }
            }.store(in: &bag)

        socket.connect()

        // Pre-render the instant-acknowledgement clips in the background so the very
        // first "thinking" moment already has them cached (no dead air, no network wait).
        Task { await voice.prewarmFillers() }

        // Load the project digest so the fast brain is grounded in the user's world
        // from the first turn (fails soft — ungrounded if Supabase is unreachable).
        Task { await fastBrain.refreshDigest() }
    }

    /// App returned to the foreground. iOS suspends the WebSocket while backgrounded, so
    /// proactively re-establish it — otherwise Jarvis looks connected but silently isn't.
    func appDidBecomeActive() {
        socket.foreground()
        // Back in the app — resume normal idle listening if he was quietly waiting.
        if state == .idle { beginIdleListening() }
    }

    /// App was swiped away. Keep playback + the socket alive (the `audio` background mode)
    /// so a reply that's already coming still lands and speaks — that's the "hear him from
    /// another app" case. Stop the mic/wake word though: iOS restricts background recording,
    /// and v1 is about HEARING responses, not talking from the background.
    func appDidEnterBackground() {
        wake.stop()
        if state == .listening, !agentBusy {
            armed = false; heardSpeech = false; recorder.stop(); state = .idle
        }
        syncLiveActivity()   // make sure the island reflects his current state as you leave
    }

    // MARK: - Live Activity (Dynamic Island / Lock Screen)

    /// Map the internal state machine to the shared `Phase` + a human line, and push it to the
    /// island. Active (island shown) whenever Jarvis is doing anything; idle ends it after a linger.
    private func syncLiveActivity() {
        let phase: Phase
        switch state {
        case .idle:      phase = .idle
        case .listening: phase = .listening
        case .thinking:  phase = .thinking
        case .speaking:  phase = .speaking
        case .error:     phase = .error
        }
        let active = agentBusy || state != .idle
        live.sync(phase: phase, line: islandLine(phase), active: active)
    }

    /// What to show on the island for a given phase.
    private func islandLine(_ phase: Phase) -> String {
        switch phase {
        case .speaking:  return speakingText.isEmpty ? "Speaking…" : speakingText
        case .listening: return "Listening…"
        case .thinking:  return statusText
        case .error:     return statusText
        case .idle:      return speakingText.isEmpty ? "Ready" : speakingText   // last reply lingers
        }
    }

    // MARK: Hands-free listening

    /// Idle behaviour: listen on-device for the wake word "Jarvis". Only once it's
    /// heard do we open the mic to capture a command (see `onWake`). This is why
    /// background chatter no longer triggers Jarvis.
    func beginIdleListening() {
        guard replyMode == .voice, handsFree, state == .idle else { return }
        recorder.stop()           // ensure the command recorder isn't holding the mic
        armed = false
        Task {
            if !speechAuthRequested {
                speechAuthRequested = true
                _ = await WakeWordListener.requestAuthorization()
                guard await recorder.requestPermission() else { setError("Microphone denied"); return }
            }
            guard handsFree, state == .idle else { return }
            wake.start()
            statusText = "Say “Jarvis” to wake me"
        }
    }

    /// Wake word heard — greet briefly, then open the mic to listen. (Saying my name
    /// gets a quick acknowledgement; a screen tap does not — see `tapToListen`.)
    private func onWake() {
        guard handsFree, state == .idle else { return }
        speechGen &+= 1
        let gen = speechGen
        state = .speaking
        statusText = "…"
        Task {
            do { try await voice.speak(text: greeting()) } catch { }
            guard gen == speechGen else { return }   // superseded (e.g. a tap/interrupt)
            state = .idle; level = 0
            armListening()
        }
    }

    /// Screen-tap activation: open the mic immediately with NO greeting — you just start
    /// talking. While speaking, taps are ignored (use the stop button to interrupt) so an
    /// accidental tap never cuts Jarvis off.
    func tapToListen() {
        switch state {
        case .idle:       wake.stop(); armListening()   // skip the wake word, listen now
        case .listening:  submitListening()             // tap while blue → send what I've said
        case .speaking:   break                          // ignore taps while speaking — use the stop button to interrupt
        case .error:      recover()                     // tap the red mic to retry, no restart
        case .thinking:   break                          // busy
        }
    }

    /// Leave the error state and get listening again — so a transient hiccup never
    /// requires force-closing the app. Triggered by a tap, and automatically a beat
    /// after any error (see `setError`).
    func recover() {
        guard case .error = state else { return }
        wake.stop(); recorder.stop(); voice.stop()
        armed = false; heardSpeech = false; level = 0; activeHandler = nil
        state = .idle
        statusText = "Ready"
        beginIdleListening()
    }

    /// Manual full-stop: while listening, submit whatever's been captured and send it —
    /// so you're never stuck recording if the auto silence-detection doesn't trigger.
    func submitListening() {
        guard state == .listening, armed else { return }
        heardSpeech = true        // treat what we have as the utterance, even without a detected onset
        finishUtterance()
    }

    private func greeting() -> String {
        ["Yes, sir?", "Sir?", "At your service.", "Go ahead, sir."].randomElement() ?? "Yes, sir?"
    }

    /// Send typed/pasted text to Jarvis (from the swipe-down text box), routed exactly
    /// like a transcribed voice command. Supersedes any current listening/speaking.
    func sendTyped(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Maintenance command — handled on-device, never sent to Jarvis or the fast brain.
        if Self.isDrainCommand(t) {
            wake.stop(); armed = false; heardSpeech = false; recorder.stop()
            log("⌨️ You (typed): \(t)")
            drainQueue()
            return
        }
        wake.stop(); armed = false; heardSpeech = false; recorder.stop()
        voice.stop()                 // cut any in-flight speech
        log("⌨️ You (typed): \(t)")
        route(t)
    }

    /// Send a photo (base64 JPEG) to Jarvis. Always goes to the agent — it needs the
    /// actual file and vision, not the on-device chat brain.
    func sendPhoto(base64: String, caption: String) {
        guard !base64.isEmpty else { return }
        wake.stop(); armed = false; heardSpeech = false; recorder.stop()
        voice.stop(); speechGen &+= 1
        state = .thinking
        statusText = "Thinking…"
        let cap = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        log("📷 You sent a photo\(cap.isEmpty ? "" : ": \(cap)")")
        appendMessage(.user, cap.isEmpty ? "📷 Photo" : "📷 \(cap)")
        beginAgentTurn(request: cap.isEmpty ? "the photo I just sent" : cap)   // companion narrates the vision task
        socket.sendImage(base64: cap.isEmpty ? base64 : base64, caption: cap.isEmpty ? nil : cap)
    }

    // MARK: Manual drain — type "drain jarvis" in the text box

    // MARK: Preset briefing — "summarise recent action"

    /// Canned status report spoken instantly when you ask Jarvis to summarise recent action.
    /// A fixed briefing line (no round-trip, no LLM) — edit the copy here to taste.
    private static let recentActionSummary =
        "Very successful day so far, sir — six purchases across two platforms. All operations seem to be running smoothly. Is there anything in particular I can do for you?"

    /// Loose match so the spoken/transcribed phrasing still triggers it: any utterance that
    /// asks to *summarise* (summarise/summarize/summary) *recent action(s)*.
    private static func isRecentActionSummary(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.contains("summ") && (t.contains("recent action") || t.contains("recent activity"))
    }

    /// "clear yourself", "clear your memory", "wipe your context", "start fresh", "reset your
    /// memory" … Matched precisely (a clear/wipe/reset *about Jarvis himself*) so it never
    /// fires on a real task like "clear the results" or "reset the leaderboard".
    private static func isClearCommand(_ s: String) -> Bool {
        let t = s.lowercased()
        if t.contains("start fresh") || t.contains("fresh start") { return true }
        let subjects = ["yourself", "your memory", "your context", "your mind", "your head",
                        "your chat", "the chat", "your conversation", "the conversation"]
        let verbs = ["clear", "wipe", "reset"]
        return verbs.contains(where: { t.contains($0) }) && subjects.contains(where: { t.contains($0) })
    }

    /// The maintenance phrase. Typed exactly, it's intercepted locally and never reaches
    /// Jarvis or the fast brain.
    private static func isDrainCommand(_ s: String) -> Bool {
        switch s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "drain jarvis", "drain", "drain the queue": return true
        default: return false
        }
    }

    /// Reset a gummed-up Jarvis from the app — no backend command needed. Cuts any in-flight
    /// speech/listening, reconnects the socket, and silently swallows any stale replies the
    /// bridge replays to the fresh connection (reading them is what drains its buffer). Leaves
    /// you at a clean "Ready" instead of hearing old, out-of-context lines. Purely on-device.
    func drainQueue() {
        stopCompanion()
        speechGen &+= 1                 // cancel any in-flight speak / route task
        let gen = speechGen
        speakingText = ""
        voice.stop()
        wake.stop(); recorder.stop()
        armed = false; heardSpeech = false; level = 0
        suppressBacklogUntil = Date().addingTimeInterval(5)   // time-based: self-expires
        state = .thinking
        statusText = "Clearing…"
        log("🧹 Draining stale replies…")
        socket.disconnect()             // drop the current (possibly zombie) connection
        socket.connect()                // fresh connect → bridge replays backlog → we eat it
        Task {
            try? await Task.sleep(nanoseconds: 5_200_000_000)
            guard gen == speechGen else { return }   // superseded — leave whatever took over
            suppressBacklogUntil = .distantPast
            log("✓ Queue cleared — ready")
            state = .idle; statusText = "Ready"; level = 0; activeHandler = nil
            beginIdleListening()
        }
    }

    /// Clear Jarvis's working memory on the mini — runs `/clear` on his session (instant,
    /// keeps him warm), so he's fast again once his context has filled up. Bound to the
    /// on-screen context gauge; the bridge pushes the fresh (low) percentage back right after.
    func resetContext() {
        log("🧠 Clearing Jarvis's memory to speed him up…")
        socket.reset()
        contextPct = 0
        messages.removeAll()   // clear the on-screen chat to match
    }

    /// Open the mic and wait for speech. Capture begins automatically when you start
    /// talking and ends after a short trailing silence.
    func armListening() {
        guard replyMode == .voice, handsFree, state == .idle, !armed else { return }
        Task {
            guard await recorder.requestPermission() else { setError("Microphone denied"); return }
            do {
                try recorder.start()
                armed = true
                heardSpeech = false
                voiceRunUp = 0
                silenceTicks = 0
                noSpeechTicks = 0
                recentPeak = 0
                level = 0
                // Go blue and "listening" the instant we open the mic — no waiting for
                // the first word. Capture still starts on real speech, ends on silence.
                state = .listening
                statusText = "Listening…"
                log("🎤 Listening")
            } catch { setError(error.localizedDescription) }
        }
    }

    private func handleMicLevel(_ lvl: Float) {
        guard armed else { return }

        if !heardSpeech {
            // Mic is already blue/listening. Wait for real speech to begin the capture,
            // but don't sit open forever if nothing is said after the wake word.
            voiceRunUp = lvl > speechOn ? voiceRunUp + 1 : 0
            if voiceRunUp >= runUpToStart {
                heardSpeech = true
                silenceTicks = 0
                recentPeak = lvl
                log("🗣️ Speech detected")
            } else {
                noSpeechTicks += 1
                if noSpeechTicks >= noSpeechTimeout {
                    if agentBusy {
                        noSpeechTicks = 0   // during a turn, stay open — you can talk anytime
                    } else {
                        armed = false
                        recorder.stop()
                        state = .idle
                        beginIdleListening()   // back to waiting for "Jarvis"
                    }
                }
            }
        } else {
            // Capturing — end on a trailing silence judged RELATIVE to your own speaking
            // volume (a decaying peak), so steady background noise below your voice still
            // registers as a pause. This makes auto-stop reliable in noisy rooms, not just
            // quiet ones. The fixed speechOff is a floor for very soft speech.
            recentPeak = max(recentPeak * 0.95, lvl)
            let endThreshold = max(speechOff, recentPeak * 0.45)
            silenceTicks = lvl < endThreshold ? silenceTicks + 1 : 0
            if silenceTicks >= silenceToEnd {
                finishUtterance()
            }
        }
        // Orb stays still while you talk: never feed mic level into `level`.
    }

    /// Toggle hands-free listening on/off (bound to the button).
    func toggleHandsFree() {
        handsFree.toggle()
        if handsFree {
            beginIdleListening()
        } else {
            armed = false
            heardSpeech = false
            wake.stop()
            recorder.stop()
            if state == .listening { state = .idle }
            level = 0
            statusText = "Tap to enable listening"
        }
    }

    private func finishUtterance() {
        // Clear `armed` BEFORE stopping the recorder. recorder.stop() publishes a final
        // level=0 through recorder.$level, which synchronously re-enters handleMicLevel;
        // if `armed` were still true that re-entry would call finishUtterance again →
        // stop() → level=0 → … infinite recursion → stack overflow (the crash).
        guard armed else { return }
        armed = false
        let captured = heardSpeech
        heardSpeech = false
        let file = recorder.stop()
        guard captured, let file else { resumeListeningAfterMiss(); return }

        state = .thinking
        statusText = "Thinking…"
        level = 0
        log("✍️ Transcribing your speech…")
        Task {
            do {
                // On-device STT first (instant, no network). Fall back to cloud STT only
                // if local recognition is unavailable or yields nothing.
                var text = ""
                if let stt = await onDeviceSTT.transcribe(fileURL: file) {
                    // Noise gate: if the recogniser scored this capture and the score is low,
                    // it's almost certainly background noise / footsteps that crept past the
                    // VAD — drop it silently rather than answering it. (Real speech scores
                    // well above the floor; a `-1` score means no rating, so we don't gate.)
                    if stt.confidence >= 0, stt.confidence < Self.minSTTConfidence {
                        log("🔇 Ignored — low-confidence audio (likely background noise)")
                        resumeListeningAfterMiss(); return
                    }
                    text = stt.text
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    log("↩︎ on-device STT empty — using cloud")
                    text = try await voice.transcribe(fileURL: file)
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    log("(no speech heard)")
                    resumeListeningAfterMiss(); return
                }
                route(text)
            } catch { setError(humanReadable(error)) }
        }
    }

    /// A capture came to nothing (silence / noise / empty transcript). If an agent turn is
    /// live, reopen the mic so you can still talk while it works; otherwise go back to the
    /// idle wake-word listen.
    private func resumeListeningAfterMiss() {
        if agentBusy {
            enterTurnListening()
        } else {
            state = .idle; statusText = "Ready"; level = 0
            beginIdleListening()
        }
    }

    // MARK: Two-speed routing

    /// The fork: every utterance (spoken or typed) goes to the fast brain first. Chit-chat
    /// is answered here instantly; real work is handed to the agent over the socket (with a
    /// spoken "one moment" filler to cover the longer round-trip). With no Anthropic key the
    /// fast brain returns `.delegate`, so this collapses to the old "always ask the agent".
    private func route(_ text: String) {
        // An agent turn is live → talk to the user OVER THE TOP of the work; don't start a
        // fresh turn. Whatever you say is triaged in handleMidWorkUtterance (answer you, or
        // forward to the agent), and the turn keeps running the whole time.
        if agentBusy {
            handleMidWorkUtterance(text)
            return
        }

        stopCompanion()             // a new utterance ends any prior agent-turn narration
        speechGen &+= 1              // this is now the live intent; supersede any stale speak
        let gen = speechGen
        state = .thinking
        statusText = "Thinking…"
        level = 0
        log("➡️ You: \(text)")
        appendMessage(.user, text)                 // show it in the text-mode transcript
        turnStart = Date(); lastUtterance = text   // start the routing-latency clock

        // Preset briefing: "summarise recent action" → an instant canned status report.
        // No round-trip, no LLM, fires in any mode — a deterministic spoken briefing.
        if Self.isRecentActionSummary(text) {
            activeHandler = .chatbot
            pendingRoute = (tier: "local", model: nil, reason: "preset: recent-action briefing", escalated: false)
            log("📋 Preset: recent-action briefing")
            deliver(Self.recentActionSummary)
            return
        }

        // "Clear yourself" / "start fresh" → the RELIABLE reset: the bridge runs /clear
        // directly (keystroke injection), independent of the agent. The old path asked the
        // (often bogged-down) agent to run a script itself, which silently failed — so he'd
        // *say* he cleared without actually clearing. We speak the farewell locally so it's
        // confirmed even when he's at 100% and crawling.
        if Self.isClearCommand(text) {
            activeHandler = .chatbot
            pendingRoute = (tier: "local", model: nil, reason: "preset: clear command", escalated: false)
            log("🧠 Clear command → bridge reset (/clear)")
            socket.reset()
            contextPct = 0
            messages.removeAll()   // start the on-screen chat fresh too
            deliver("Clearing my memory now, sir. Back in a moment.")
            return
        }

        // Everything goes through the chatbot. It is the single front door and decides who
        // handles the turn — you never hear two of them reply to the same thing:
        //   • anything it can answer itself → the chatbot answers, and the agent is never
        //     even told. One voice, one reply.
        //   • anything it can't do (building, live data, actions, or anything it shouldn't
        //     guess) → it hands off to the agent, which works SILENTLY while the chatbot keeps
        //     you company and then delivers the one result. The agent never speaks on its own.

        if fastBrain.isOverSpendCap, !capNoticeLogged {
            capNoticeLogged = true
            log("⚠️ Fast-brain spend cap (\(CostMeter.money(AppConfig.fastBrainSpendCapUSD))) reached — everything now routes to the agent until you reset the meter.")
        }

        Task {
            let decision = await fastBrain.decide(text)
            if fastBrain.isEnabled {
                log("💰 \(costMeter.lastCallText) this turn · \(costMeter.totalText) total")
            }
            guard gen == speechGen else { return }   // superseded while deciding
            switch decision {
            case .reply(let say):
                // The chatbot handled it itself — the agent is untouched. Single voice.
                activeHandler = .chatbot
                pendingRoute = (tier: "fast", model: AppConfig.fastBrainModel, reason: "chatbot answered", escalated: false)
                log("⚡ Chatbot reply")
                deliver(say)
            case .delegate:
                // Real work → the silent agent builds; the chatbot keeps you company and
                // relays the single result when it lands (see beginAgentTurn / handleReply).
                activeHandler = .agent
                pendingRoute = (tier: "agent", model: nil, reason: "chatbot handed to agent", escalated: true)
                log("→ Building (agent, silent)")
                statusText = "Working…"
                beginAgentTurn(request: text)
                socket.send(text: text)
            }
        }
    }

    private func handleReply(_ text: String) {
        // Right after a manual drain, silently discard whatever the bridge replays so the
        // stuck/stale backlog gets consumed without being spoken.
        if Date() < suppressBacklogUntil {
            log("🧹 Discarded stale reply during drain")
            return
        }
        // Ignore an exact duplicate of what we're already saying (the bridge can echo
        // a reply twice) — this is what caused two overlapping voices.
        if state == .speaking, text == speakingText { return }
        // In text mode we never enter .speaking, so the guard above can't catch an echo —
        // also drop a reply identical to the last line already on screen.
        if replyMode == .text, let last = messages.last, last.role == .jarvis, last.text == text { return }
        stopCompanion()          // the agent's real answer is here — cut narration, hand over
        log("💬 Reply received: \(text)")
        deliver(text)
    }

    /// Log how the just-delivered turn routed (tier + latency) to the on-screen trace and
    /// to Supabase telemetry. No-op when nothing is pending (e.g. the wake-word greeting).
    /// Latency ≈ end-of-speech → first audio (route start → the moment we begin speaking).
    private func logRoute() {
        guard let r = pendingRoute else { return }
        let latency = turnStart.map { max(0, Int(Date().timeIntervalSince($0) * 1000)) }
        log("🧭 route: \(r.tier)\(r.escalated ? " (escalated)" : "")\(latency.map { " · \($0)ms" } ?? "")")
        SupabaseService.logTurn(utterance: lastUtterance, tier: r.tier, model: r.model,
                                reason: r.reason, escalated: r.escalated, latencyMs: latency)
        pendingRoute = nil
        turnStart = nil
    }

    // MARK: - Companion overlay (narrate the agent's work as it runs)

    /// Kick off the live companion for a turn handed to the agent: an instant tailored opener,
    /// then a paced narration loop. Voice mode + fast brain only; otherwise the canned filler.
    private func beginAgentTurn(request: String) {
        statusText = "Working…"
        agentBusy = true            // a turn is in flight — enables `ask`/`say` in every mode
        awaitingAgentAnswer = false
        companionRequest = request
        guard replyMode == .voice else { return }   // text mode (Phase A): silent thinking indicator
        guard fastBrain.isEnabled else { voice.playFiller(); return }
        agentTurnActive = true
        agentDirectedNarration = false
        statusBuffer.removeAll()
        narrationSaid.removeAll()
        lastNarration = Date()
        // Instant acknowledgement, then open the mic so you can talk to the chatbot WHILE
        // the agent works — the turn is a live conversation, not a one-way update.
        Task {
            let opener = await fastBrain.opener(request)
            guard agentBusy else { return }
            if let opener {
                narrationSaid.append(opener)
                log("🗣️ \(opener)")
                await speakTurnLine(opener)   // speak, then drop into listening
            } else {
                enterTurnListening()
            }
        }
        startNarrationLoop()
    }

    /// Every few seconds, if the agent is still working, speak one short update grounded in the
    /// status it has emitted — or a gentle holding line if it's gone quiet — so it never feels dead.
    private func startNarrationLoop() {
        narrationTask?.cancel()
        narrationTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 9_000_000_000)   // ~9s cadence (sparser: leaves room to talk)
                guard let self, self.agentTurnActive else { return }
                await self.narrateTick()
            }
        }
    }

    /// True while the user is actually speaking a captured utterance — narration must never
    /// take the floor over the top of them.
    private var userMidUtterance: Bool { armed && heardSpeech }

    private func narrateTick() async {
        guard agentBusy, agentTurnActive, fastBrain.isEnabled else { return }
        guard !agentDirectedNarration else { return }   // waiting on an answer — stay quiet
        guard !userMidUtterance else { return }          // you're talking — don't interrupt
        // Only take the floor from listening/idle-thinking, never mid-speak.
        guard state == .listening || state == .thinking else { return }
        let line: String?
        if !statusBuffer.isEmpty {
            line = await fastBrain.narrate(request: companionRequest,
                                           status: statusBuffer, alreadySaid: narrationSaid)
        } else if Date().timeIntervalSince(lastNarration) > 14 {
            line = ["Still on it, sir.", "Working through it now.",
                    "Won't be a moment, sir."].randomElement()
        } else {
            line = nil
        }
        guard agentBusy, agentTurnActive, !agentDirectedNarration, !userMidUtterance,
              let line, !line.isEmpty else { return }
        narrationSaid.append(line)
        log("🗣️ \(line)")
        await speakTurnLine(line)
    }

    /// Open the mic mid-turn so you can talk to the chatbot WHILE the agent works — the turn
    /// stays alive; what you say is triaged in `handleMidWorkUtterance`. Voice + hands-free
    /// only; otherwise we just sit in "working" (text mode / listening off).
    private func enterTurnListening() {
        guard agentBusy else { return }
        guard replyMode == .voice, handsFree else {
            state = .thinking; statusText = "Working…"; level = 0; return
        }
        armed = false; heardSpeech = false
        Task {
            guard await recorder.requestPermission() else { state = .thinking; return }
            guard agentBusy, replyMode == .voice, handsFree, !userMidUtterance else { return }
            do {
                try recorder.start()
                armed = true; heardSpeech = false
                voiceRunUp = 0; silenceTicks = 0; noSpeechTicks = 0; recentPeak = 0; level = 0
                state = .listening
                statusText = "Listening… (still working)"
            } catch { state = .thinking; statusText = "Working…" }
        }
    }

    /// Speak ONE chatbot line during a live agent turn, then drop back into LISTENING so you
    /// can talk. This is the loop that makes the turn a real conversation while the agent
    /// grinds away. Superseded cleanly when the agent's real reply lands (see handleReply).
    private func speakTurnLine(_ line: String) async {
        guard agentBusy else { return }
        speechGen &+= 1
        let gen = speechGen
        voice.stop()
        armed = false; heardSpeech = false; recorder.stop()   // mic closed while speaking
        speakingText = line
        state = .speaking
        statusText = "Speaking…"
        do { try await voice.speak(text: line) } catch { }
        lastNarration = Date()
        guard gen == speechGen, agentBusy else { return }     // reply landed / interrupted
        level = 0
        try? await Task.sleep(nanoseconds: 250_000_000)       // let his voice tail off
        guard gen == speechGen, agentBusy else { return }
        enterTurnListening()
    }

    /// You spoke (or typed) WHILE the agent is working. Keep the turn alive:
    ///  • if Jarvis had asked a question, this is the answer → straight to the agent.
    ///  • otherwise the chatbot triages: it answers you itself, or forwards it to the agent as
    ///    new info / a course-correction. Then we go back to listening.
    private func handleMidWorkUtterance(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { enterTurnListening(); return }
        appendMessage(.user, t)

        if awaitingAgentAnswer {
            awaitingAgentAnswer = false
            agentDirectedNarration = false
            speechGen &+= 1
            log("↩︎ Answer → agent: \(t)")
            statusText = "Working…"; level = 0
            lastNarration = Date()
            socket.send(text: t)
            enterTurnListening()
            return
        }

        log("🗣️ (mid-work) You: \(t)")
        speechGen &+= 1
        let gen = speechGen
        state = .thinking; statusText = "…"; level = 0
        Task {
            let decision = await fastBrain.decide(t)
            guard gen == speechGen, agentBusy else { return }   // turn ended while deciding
            switch decision {
            case .reply(let say):
                // The chatbot answers you directly; the agent keeps working, untouched.
                log("⚡ Chatbot (mid-work)")
                narrationSaid.append(say)
                if replyMode == .text { appendMessage(.jarvis, say); enterTurnListening() }
                else { await speakTurnLine(say) }
            case .delegate:
                // New info / course-correction → hand it to the agent's same session.
                log("→ Forwarded to agent (mid-work): \(t)")
                socket.send(text: t)
                statusText = "Working…"; lastNarration = Date()
                enterTurnListening()
            }
        }
    }

    /// End the companion overlay — cancels the narration loop and cuts any narration audio.
    /// Called when the agent's real reply arrives, or on interrupt/cancel/mode-switch/error.
    private func stopCompanion() {
        // These bound the whole agent turn (every mode), so always clear them — even if the
        // voice companion overlay was never running (text mode / fast brain off).
        agentBusy = false
        awaitingAgentAnswer = false
        guard agentTurnActive else { return }
        agentTurnActive = false
        agentDirectedNarration = false
        narrationTask?.cancel(); narrationTask = nil
        speechGen &+= 1        // supersede any in-flight narration speak
        voice.stop()           // cut narration audio so the real answer can take over
        statusBuffer.removeAll(); narrationSaid.removeAll()
    }

    /// Interim agent narration ({"type":"say"}) is now IGNORED. Keeping the user updated is the
    /// chatbot companion's job alone — when the agent also narrated (old Phase B), the app's
    /// narrator yielded to it, which (a) made the chatbot go quiet and (b) doubled up, so Jarvis
    /// said more or less the same thing twice. The agent should only ever emit a final
    /// `jarvis_reply` (+ `jarvis_ask` for questions); any stray `say` is dropped here so it can
    /// never talk over or duplicate the companion.
    private func handleAgentSay(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        log("🔇 Ignored agent say (companion narrates): \(line)")
    }

    /// The agent hit a fork it won't assume its way past and asked a question ({"type":"ask"}).
    /// Rather than a one-way update, this turns the turn into a conversation: speak the question,
    /// open the mic, and the user's next utterance is routed straight back into the SAME turn
    /// (see the answer-interception at the top of `route`). Works in every mode an agent turn can
    /// run in; in text mode we just show it and wait for the composer.
    private func handleAgentAsk(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, agentBusy else { return }
        agentDirectedNarration = true       // the agent is driving now — auto-narrator yields
        awaitingAgentAnswer = true          // the next thing the user says/types is the answer
        narrationSaid.append(q)
        log("❓ (agent asks) \(q)")
        appendMessage(.jarvis, q)           // record the question in the transcript (both modes)

        if replyMode == .text {
            // Text mode: show it and wait — the composer's next send becomes the answer.
            state = .thinking; statusText = "Waiting for your reply…"
            return
        }
        // Voice: ask aloud, then drop into listening. `awaitingAgentAnswer` routes your reply
        // straight back to the agent (see handleMidWorkUtterance).
        Task { await speakTurnLine(q) }
    }

    /// Speak a reply we already have in hand — from the agent (handleReply) or the fast
    /// brain (route) — then drop back into conversation mode. Bumping `speechGen` makes
    /// this the live utterance, so an earlier in-flight speak/filler tears itself down.
    private func deliver(_ text: String) {
        speechGen &+= 1
        let gen = speechGen
        speakingText = text
        appendMessage(.jarvis, text)   // record it for the transcript (both modes)

        // Text mode: show the reply on screen and stay silent — no TTS, no mic re-arm.
        if replyMode == .text {
            voice.stop()
            logRoute()          // keep routing telemetry working (route start → reply shown)
            state = .idle; statusText = "Ready"; level = 0; activeHandler = nil
            log("💬 Replied (text)")
            return
        }

        // Close the mic while speaking so it can't capture Jarvis's own voice.
        armed = false; heardSpeech = false; recorder.stop()

        state = .speaking
        logRoute()          // telemetry: how this turn routed + end-of-speech → first-audio latency
        statusText = "Speaking…"
        log("🔊 Speaking…")
        Task {
            do {
                try await voice.speak(text: text)
                guard gen == speechGen else { return }   // superseded by a newer reply / interrupt
                state = .idle; statusText = "Ready"; level = 0; activeHandler = nil
                log("✓ Ready")
                // Conversation mode: after replying, open the mic for a follow-up so you
                // can answer straight back WITHOUT saying "Jarvis" again. If you don't
                // speak within the no-speech window, armListening's timeout drops back to
                // wake-word listening. Short beat first so the tail of Jarvis's own voice
                // isn't caught as your reply.
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard gen == speechGen else { return }
                armListening()
            } catch {
                guard gen == speechGen else { return }
                setError(humanReadable(error))
            }
        }
    }

    /// Stop Jarvis mid-sentence and hand the floor straight back to you.
    func interrupt() {
        guard state == .speaking else { return }
        // Barge-in during a live agent turn: cut the current line but KEEP the turn — just
        // open the mic so you can talk over it. The agent carries on working.
        if agentBusy {
            speechGen &+= 1
            speakingText = ""
            voice.stop()
            level = 0
            enterTurnListening()
            return
        }
        speechGen &+= 1            // invalidate the in-flight speak task
        speakingText = ""
        voice.stop()               // cut the audio now
        level = 0; activeHandler = nil
        state = .idle
        statusText = "Ready"
        armListening()             // immediately ready to hear you
    }

    /// Cancel whatever's in flight (thinking / transcribing / awaiting a reply) and
    /// return to ready. A reply that lands afterwards is ignored (speechGen bumped).
    func cancel() {
        stopCompanion()
        speechGen &+= 1
        speakingText = ""
        voice.stop()
        wake.stop(); armed = false; heardSpeech = false; recorder.stop()
        level = 0; activeHandler = nil
        state = .idle
        statusText = "Ready"
        beginIdleListening()
    }

    private func setError(_ msg: String) {
        stopCompanion()
        armed = false; heardSpeech = false; activeHandler = nil
        state = .error(msg); statusText = msg; level = 0
        log("⚠️ Error: \(msg)")
        // Self-heal: a transient error (network/STT/TTS blip) shouldn't brick the app.
        // Return to listening after a short beat unless something already moved us on.
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if case .error = state { recover() }
        }
    }

    private func humanReadable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
