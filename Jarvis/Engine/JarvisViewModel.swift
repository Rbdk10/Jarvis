import Foundation
import Combine

/// Orchestrates: idle → listening → thinking → speaking → idle.
/// Publishes `level` (0...1) for the orb and `state`/`statusText` for the UI.
@MainActor
final class JarvisViewModel: ObservableObject {
    enum State: Equatable { case idle, listening, thinking, speaking, error(String) }

    @Published var state: State = .idle
    @Published var level: Float = 0
    @Published var statusText: String = "Connecting…"

    let socket = JarvisSocket()
    private let recorder = AudioRecorder()
    private let voice = ElevenLabsService()
    private var bag = Set<AnyCancellable>()

    init() {
        socket.onReply = { [weak self] text in self?.handleReply(text) }
        socket.onError = { [weak self] msg in self?.setError(msg) }
        socket.onStatus = { [weak self] label in
            if self?.state == .thinking { self?.statusText = label }
        }

        recorder.$level
            .sink { [weak self] lvl in
                guard let self, self.state == .listening else { return }
                self.level = lvl
            }.store(in: &bag)

        voice.$playbackLevel
            .sink { [weak self] lvl in
                guard let self, self.state == .speaking else { return }
                self.level = lvl
            }.store(in: &bag)

        socket.$status
            .sink { [weak self] st in
                guard let self else { return }
                switch st {
                case .connected:   if self.state == .idle { self.statusText = "Ready" }
                case .connecting:  self.statusText = "Connecting…"
                case .disconnected: self.statusText = "Offline"
                }
            }.store(in: &bag)

        socket.connect()
    }

    func startTalking() {
        guard state == .idle else { return }
        Task {
            guard await recorder.requestPermission() else { setError("Microphone denied"); return }
            do {
                try recorder.start()
                state = .listening
                statusText = "Listening…"
            } catch { setError(error.localizedDescription) }
        }
    }

    func stopTalking() {
        guard state == .listening, let file = recorder.stop() else { return }
        state = .thinking
        statusText = "Thinking…"
        level = 0
        Task {
            do {
                let text = try await voice.transcribe(fileURL: file)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    state = .idle; statusText = "Ready"; return
                }
                socket.send(text: text)
            } catch { setError(humanReadable(error)) }
        }
    }

    private func handleReply(_ text: String) {
        state = .speaking
        statusText = "Speaking…"
        Task {
            do {
                try await voice.speak(text: text)
                state = .idle; statusText = "Ready"; level = 0
            } catch { setError(humanReadable(error)) }
        }
    }

    private func setError(_ msg: String) {
        state = .error(msg); statusText = msg; level = 0
    }

    private func humanReadable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
