import Foundation
import Combine

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
    /// When true (default), Jarvis listens automatically. The button toggles this.
    @Published var handsFree: Bool = true

    let socket = JarvisSocket()
    private let recorder = AudioRecorder()
    private let voice = ElevenLabsService()
    private let wake = WakeWordListener()
    private var bag = Set<AnyCancellable>()
    private var speechAuthRequested = false

    // MARK: Voice-activity detection
    private var armed = false               // mic is open, waiting for / capturing speech
    private var heardSpeech = false         // speech has begun within this capture
    private var voiceRunUp = 0              // consecutive over-threshold meter samples
    private var silenceTicks = 0            // consecutive below-threshold samples after speech
    private let speechOn: Float = 0.16      // level to count as voice (with hysteresis)
    private let speechOff: Float = 0.09
    private let runUpToStart = 3            // ~0.15s of voice to begin capture
    private let silenceToEnd = 20           // ~1.0s of trailing silence to end (×0.05s)

    // Speech serialisation — guarantees Jarvis never talks over himself.
    private var speechGen = 0               // bumped per reply / interrupt; stale tasks no-op
    private var speakingText = ""           // currently-spoken text, for duplicate suppression

    init() {
        wake.onWake = { [weak self] in self?.onWake() }
        socket.onReply = { [weak self] text in self?.handleReply(text) }
        socket.onError = { [weak self] msg in self?.setError(msg) }
        socket.onStatus = { [weak self] label in
            // Live "what I'm doing" feed — only meaningful while thinking.
            if self?.state == .thinking { self?.statusText = label }
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
                    if self.state == .idle {
                        self.statusText = "Ready"
                        self.beginIdleListening()
                    }
                case .connecting:   self.statusText = "Connecting…"
                case .disconnected: self.statusText = "Offline"
                }
            }.store(in: &bag)

        socket.connect()
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

    /// Wake word heard — hand off to command capture.
    private func onWake() {
        guard handsFree, state == .idle else { return }
        statusText = "Listening…"
        armListening()
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
                level = 0
                if state == .idle { statusText = "Listening…" }
            } catch { setError(error.localizedDescription) }
        }
    }

    private func handleMicLevel(_ lvl: Float) {
        guard armed else { return }

        if !heardSpeech {
            // Waiting for you to start speaking.
            voiceRunUp = lvl > speechOn ? voiceRunUp + 1 : 0
            if voiceRunUp >= runUpToStart {
                heardSpeech = true
                silenceTicks = 0
                state = .listening
                statusText = "Listening…"
            }
        } else {
            // Capturing — watch for a trailing silence to end the utterance.
            silenceTicks = lvl < speechOff ? silenceTicks + 1 : 0
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
        guard armed, let file = recorder.stop() else { return }
        armed = false
        let captured = heardSpeech
        heardSpeech = false
        guard captured else { state = .idle; beginIdleListening(); return }

        state = .thinking
        statusText = "Thinking…"
        level = 0
        Task {
            do {
                let text = try await voice.transcribe(fileURL: file)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    state = .idle; statusText = "Ready"; beginIdleListening(); return
                }
                socket.send(text: text)
            } catch { setError(humanReadable(error)) }
        }
    }

    private func handleReply(_ text: String) {
        // Ignore an exact duplicate of what we're already saying (the bridge can echo
        // a reply twice) — this is what caused two overlapping voices.
        if state == .speaking, text == speakingText { return }

        speechGen &+= 1
        let gen = speechGen
        speakingText = text

        // Close the mic while speaking so it can't capture Jarvis's own voice.
        armed = false; heardSpeech = false; recorder.stop()

        state = .speaking
        statusText = "Speaking…"
        Task {
            do {
                try await voice.speak(text: text)
                guard gen == speechGen else { return }   // superseded by a newer reply / interrupt
                state = .idle; statusText = "Ready"; level = 0
                // Back to wake-word listening after a short beat so the tail of
                // Jarvis's voice doesn't get mistaken for the wake word.
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard gen == speechGen else { return }
                beginIdleListening()
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
        level = 0
        state = .idle
        statusText = "Ready"
        armListening()             // immediately ready to hear you
    }

    private func setError(_ msg: String) {
        armed = false; heardSpeech = false
        state = .error(msg); statusText = msg; level = 0
    }

    private func humanReadable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
