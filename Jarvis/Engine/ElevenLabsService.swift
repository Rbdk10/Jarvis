import Foundation
import AVFoundation

/// On-device speech: ElevenLabs STT (scribe_v1) + TTS (multilingual_v2) with the Jarvis voice.
/// Publishes a playback level (0...1) for the orb while Jarvis speaks.
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

    // MARK: Text-to-speech + playback
    func speak(text: String) async throws {
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
        try await play(data: data)
    }

    private func play(data: Data) async throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        let p = try AVAudioPlayer(data: data)
        p.isMeteringEnabled = true
        p.delegate = self
        player = p
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.onFinish = { cont.resume() }
            p.play()
            self.meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let pl = self.player else { return }
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
            self.onFinish?(); self.onFinish = nil
        }
    }
}
