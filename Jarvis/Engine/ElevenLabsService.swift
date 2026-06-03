import Foundation
import AVFoundation

/// On-device speech: ElevenLabs STT (scribe_v1) + TTS with the Jarvis voice.
/// Publishes a playback level (0...1) for the orb while Jarvis speaks.
///
/// Also caches a few short "filler" phrases (rendered once in the Jarvis voice) so the
/// app can speak an *instant* acknowledgement the moment you finish talking — covering
/// the dead air while the real reply is computed. See `prewarmFillers` / `playFiller`.
@MainActor
final class ElevenLabsService: NSObject, ObservableObject {
    @Published var playbackLevel: Float = 0

    enum ELError: LocalizedError {
        case noKey, http(Int), decode
        var errorDescription: String? {
            switch self {
            case .noKey: return "Missing ElevenLabs API key"
            case .http(let c): return "ElevenLabs HTTP \(c)"
            case .decode: return "Unexpected ElevenLabs response"
            }
        }
    }

    private var player: AVAudioPlayer?
    private var meterTimer: Timer?
    private var onFinish: (() -> Void)?
    /// Bumped on every stop/new playback. Guards against two utterances overlapping:
    /// any in-flight playback whose token is stale tears itself down silently.
    private var playToken = 0

    // Instant acknowledgement — short clips cached on-device in the Jarvis voice.
    private var fillerPlayer: AVAudioPlayer?
    private var fillerURLs: [URL] = []
    private let fillerPhrases = [
        "One moment.", "Let me check.", "On it.",
        "Give me a second.", "Mm, let me see.", "Right, let me look."
    ]

    private func activatePlayback() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: Stop

    /// Stop everything (real reply + filler) and release a waiting `speak`. Used for
    /// interrupt / barge-in.
    func stop() {
        stopMain()
        stopFiller()
    }

    private func stopMain() {
        playToken &+= 1
        meterTimer?.invalidate(); meterTimer = nil
        player?.stop(); player = nil
        playbackLevel = 0
        let finish = onFinish; onFinish = nil
        finish?()
    }

    private func stopFiller() {
        fillerPlayer?.stop(); fillerPlayer = nil
    }

    // MARK: Instant acknowledgement ("filler")

    /// Render the filler phrases once (in the Jarvis voice) and cache them on disk so
    /// `playFiller` is instant. Idempotent; safe to call on launch. Keyed by voice ID,
    /// so changing the voice regenerates them.
    func prewarmFillers() async {
        guard !AppConfig.elevenLabsAPIKey.isEmpty, fillerURLs.isEmpty else { return }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fillers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ready: [URL] = []
        for phrase in fillerPhrases {
            let slug = phrase.lowercased().filter { $0.isLetter }
            let file = dir.appendingPathComponent("\(AppConfig.voiceID)-\(slug).mp3")
            if !FileManager.default.fileExists(atPath: file.path) {
                if let data = try? await renderTTS(text: phrase) { try? data.write(to: file) }
            }
            if FileManager.default.fileExists(atPath: file.path) { ready.append(file) }
        }
        fillerURLs = ready
    }

    /// Speak a short acknowledgement instantly from cache (no network). Best-effort:
    /// a no-op if the fillers aren't cached yet. The real reply takes over when ready.
    func playFiller() {
        guard let url = fillerURLs.randomElement() else { return }
        do {
            try activatePlayback()
            let p = try AVAudioPlayer(contentsOf: url)
            p.play()
            fillerPlayer = p
        } catch { /* best-effort; never block the real flow on a filler */ }
    }

    // MARK: Speech-to-text
    func transcribe(fileURL: URL) async throws -> String {
        guard !AppConfig.elevenLabsAPIKey.isEmpty else { throw ELError.noKey }
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.setValue(AppConfig.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(AppConfig.sttModel)\r\n".data(using: .utf8)!)

        let audio = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ELError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else { throw ELError.decode }
        return text
    }

    // MARK: Text-to-speech

    /// One TTS request → audio bytes. Shared by `speak` and the filler prewarm.
    private func renderTTS(text: String) async throws -> Data {
        guard !AppConfig.elevenLabsAPIKey.isEmpty else { throw ELError.noKey }
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(AppConfig.voiceID)")!)
        req.httpMethod = "POST"
        req.setValue(AppConfig.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let bodyObj: [String: Any] = [
            "text": text,
            "model_id": AppConfig.ttsModel,
            "voice_settings": [
                "stability": AppConfig.stability,
                "similarity_boost": AppConfig.similarity,
                "style": AppConfig.style,
                "use_speaker_boost": AppConfig.speakerBoost,
                "speed": AppConfig.speed
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyObj)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ELError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    func speak(text: String) async throws {
        // Supersede a previous reply, but leave any filler playing to cover the fetch.
        stopMain()
        let token = playToken
        let data = try await renderTTS(text: text)
        try await play(data: data, token: token)
    }

    private func play(data: Data, token: Int) async throws {
        // Superseded while the TTS was downloading — don't start a second voice.
        guard token == playToken else { return }
        try activatePlayback()
        let p = try AVAudioPlayer(data: data)
        p.isMeteringEnabled = true
        p.delegate = self
        player = p
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            guard token == playToken else { cont.resume(); return }
            self.onFinish = { cont.resume() }
            self.stopFiller()          // seamless hand-off: filler out, real reply in
            p.play()
            self.meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, self.playToken == token, let pl = self.player else { return }
                pl.updateMeters()
                self.playbackLevel = AudioLevel.normalize(pl.averagePower(forChannel: 0))
            }
        }
    }
}

extension ElevenLabsService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.meterTimer?.invalidate(); self.meterTimer = nil
            self.playbackLevel = 0
            self.player = nil
            let finish = self.onFinish; self.onFinish = nil
            finish?()
        }
    }
}
