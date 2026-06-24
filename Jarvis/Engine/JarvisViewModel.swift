import Foundation
import Combine

/// One step in the activity trace (swipe-right log).
struct ActivityEntry: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
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

    /// Manual routing override — the two top buttons. `.auto` is the normal smart routing;
    /// `.chatbot` forces the fast brain to answer; `.agent` sends everything to the agent.
    /// Starts on `.chatbot` so a fresh conversation talks to the instant on-device brain.
    enum RouteMode { case auto, chatbot, agent }
    @Published var routeMode: RouteMode = .chatbot

    /// Who is actually handling the current turn (working/talking) — drives the live button
    /// highlight. `.chatbot` or `.agent` while a turn is in flight; nil when idle (then the
    /// highlight falls back to the locked `routeMode`).
    @Published var activeHandler: RouteMode?

    /// Set by the agent (over the socket) to open the projector on a public URL — e.g. when
    /// you say "show me the page of project X". ContentView observes this and opens the panel.
    @Published var previewRequest: String?

    func setMode(_ m: RouteMode) {
        routeMode = m
        switch m {
        case .auto:    log("🔀 Auto-routing")
        case .chatbot: log("🔵 Locked to Chatbot")
        case .agent:   log("🟠 Locked to Agent")
        }
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
    private let silenceToEnd = 8            // ~0.4s of trailing silence to end (×0.05s) — snappier turn-taking
    private var noSpeechTicks = 0           // ticks listening-but-silent after the wake word
    private let noSpeechTimeout = 160       // ~8s of no speech → drop back to wake word
    private var recentPeak: Float = 0       // decaying peak of your speaking volume (adaptive endpointing)

    // Speech serialisation — guarantees Jarvis never talks over himself.
    private var speechGen = 0               // bumped per reply / interrupt; stale tasks no-op
    private var speakingText = ""           // currently-spoken text, for duplicate suppression

    init() {
        wake.onWake = { [weak self] in self?.onWake() }
        socket.onReply = { [weak self] text in self?.handleReply(text) }
        socket.onError = { [weak self] msg in self?.setError(msg) }
        socket.onArtifact = { [weak self] art in self?.artifacts.append(art) }
        socket.onOpenURL = { [weak self] url in self?.previewRequest = url }
        socket.onStatus = { [weak self] label in
            // Live "what I'm doing" feed — only meaningful while thinking.
            if self?.state == .thinking { self?.statusText = label }
            self?.log(label)
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
    }

    // MARK: Hands-free listening

    /// Idle behaviour: listen on-device for the wake word "Jarvis". Only once it's
    /// heard do we open the mic to capture a command (see `onWake`). This is why
    /// background chatter no longer triggers Jarvis.
    func beginIdleListening() {
        guard handsFree, state == .idle else { return }
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
        socket.sendImage(base64: cap.isEmpty ? base64 : base64, caption: cap.isEmpty ? nil : cap)
    }

    // MARK: Manual drain — type "drain jarvis" in the text box

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

    /// Open the mic and wait for speech. Capture begins automatically when you start
    /// talking and ends after a short trailing silence.
    func armListening() {
        guard handsFree, state == .idle, !armed else { return }
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
                    armed = false
                    recorder.stop()
                    state = .idle
                    beginIdleListening()   // back to waiting for "Jarvis"
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
        guard captured, let file else { state = .idle; statusText = "Ready"; beginIdleListening(); return }

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
                        state = .idle; statusText = "Ready"; beginIdleListening(); return
                    }
                    text = stt.text
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    log("↩︎ on-device STT empty — using cloud")
                    text = try await voice.transcribe(fileURL: file)
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    log("(no speech heard)")
                    state = .idle; statusText = "Ready"; beginIdleListening(); return
                }
                route(text)
            } catch { setError(humanReadable(error)) }
        }
    }

    // MARK: Two-speed routing

    /// The fork: every utterance (spoken or typed) goes to the fast brain first. Chit-chat
    /// is answered here instantly; real work is handed to the agent over the socket (with a
    /// spoken "one moment" filler to cover the longer round-trip). With no Anthropic key the
    /// fast brain returns `.delegate`, so this collapses to the old "always ask the agent".
    private func route(_ text: String) {
        speechGen &+= 1              // this is now the live intent; supersede any stale speak
        let gen = speechGen
        state = .thinking
        statusText = "Thinking…"
        level = 0
        log("➡️ You: \(text)")

        switch routeMode {
        case .agent:
            // Locked to the agent — skip the fast brain entirely (also free: no API call).
            activeHandler = .agent
            log("🟠 → Agent (locked)")
            statusText = "Working…"
            voice.playFiller()
            socket.send(text: text)

        case .chatbot:
            // Locked to the chatbot — make the fast brain answer directly.
            activeHandler = .chatbot
            Task {
                let say = await fastBrain.answer(text)
                if fastBrain.isEnabled {
                    log("💰 \(costMeter.lastCallText) this turn · \(costMeter.totalText) total")
                }
                guard gen == speechGen else { return }
                if let say {
                    log("🔵 Chatbot (locked)")
                    deliver(say)
                } else {
                    // No key / over cap / call failed → fall back to the agent so you're never stuck.
                    activeHandler = .agent
                    log("→ Agent (chatbot unavailable)")
                    statusText = "Working…"
                    voice.playFiller()
                    socket.send(text: text)
                }
            }

        case .auto:
            // If the spend cap has tripped, say so once — then everything quietly goes to the
            // agent (chit-chat is no longer instant, but voice still works and no more spend).
            if fastBrain.isOverSpendCap, !capNoticeLogged {
                capNoticeLogged = true
                log("⚠️ Fast-brain spend cap (\(CostMeter.money(AppConfig.fastBrainSpendCapUSD))) reached — chit-chat now routes to the agent. Voice still works; reset the meter to re-enable.")
            }
            Task {
                let decision = await fastBrain.decide(text)
                // Surface the spend so you can watch it against your credit (the fast brain is
                // the only thing on the Anthropic key). No-op line when the brain is disabled.
                if fastBrain.isEnabled {
                    log("💰 \(costMeter.lastCallText) this turn · \(costMeter.totalText) total")
                }
                guard gen == speechGen else { return }   // interrupted/superseded while deciding
                switch decision {
                case .reply(let say):
                    activeHandler = .chatbot
                    log("⚡ Fast reply")
                    deliver(say)
                case .delegate:
                    activeHandler = .agent
                    log("→ Handing to the agent")
                    statusText = "Working…"
                    voice.playFiller()   // instant acknowledgement → covers the agent round-trip
                    socket.send(text: text)
                }
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
        log("💬 Reply received: \(text)")
        deliver(text)
    }

    /// Speak a reply we already have in hand — from the agent (handleReply) or the fast
    /// brain (route) — then drop back into conversation mode. Bumping `speechGen` makes
    /// this the live utterance, so an earlier in-flight speak/filler tears itself down.
    private func deliver(_ text: String) {
        speechGen &+= 1
        let gen = speechGen
        speakingText = text

        // Close the mic while speaking so it can't capture Jarvis's own voice.
        armed = false; heardSpeech = false; recorder.stop()

        state = .speaking
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
