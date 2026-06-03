import Foundation
import AVFoundation

/// On-device speech: ElevenLabs STT (scribe_v1) + STREAMING TTS over the WebSocket
/// (Flash v2.5) with the Jarvis voice. Audio chunks play in order as they arrive, so
/// the first sound lands a fraction of a second after we send the text — no waiting
/// for the whole clip. Publishes a playback level (0...1) for the orb while speaking.
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

    // MARK: Streaming TTS state
    private let engine = AVAudioEngine()
    private var node: AVAudioPlayerNode?
    private var ws: URLSessionWebSocketTask?
    private var format: AVAudioFormat?
    /// Bumped on every stop/new playback. Any in-flight stream whose token is stale
    /// tears itself down silently — guarantees Jarvis never talks over himself.
    private var playToken = 0
    private var outstanding = 0          // PCM buffers scheduled but not yet played
    private var receivedFinal = false    // server signalled end-of-stream (or socket closed)
    private var finishCont: CheckedContinuation<Void, Never>?

    private let streamSampleRate: Double = 22050
    private let streamModel = "eleven_flash_v2_5"
    // Latency-vs-prosody dial: small first value → first audio fires fast; larger later
    // values → smoother prosody on the rest of the reply.
    private let chunkSchedule = [50, 120, 200, 290]

    /// Immediately stop any current stream/playback and release a waiting `speak`.
    func stop() {
        playToken &+= 1
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        node?.stop(); node = nil
        if engine.isRunning { engine.stop() }
        outstanding = 0
        receivedFinal = false
        playbackLevel = 0
        let c = finishCont; finishCont = nil; c?.resume()
    }

    // MARK: Speech-to-text (unchanged)
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

    // MARK: Streaming text-to-speech
    func speak(text: String) async throws {
        guard !AppConfig.elevenLabsAPIKey.isEmpty else { throw ELError.noKey }
        stop()                       // supersede anything in flight, claim a token
        let token = playToken

        // Audio engine: a player node feeding the mixer with PCM float buffers.
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: streamSampleRate, channels: 1) else {
            throw ELError.decode
        }
        let pn = AVAudioPlayerNode()
        engine.attach(pn)
        engine.connect(pn, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try engine.start()
        pn.play()
        node = pn
        format = fmt
        outstanding = 0
        receivedFinal = false

        // Open the stream-input WebSocket (PCM 22 kHz, Flash v2.5).
        let urlStr = "wss://api.elevenlabs.io/v1/text-to-speech/\(AppConfig.voiceID)/stream-input" +
            "?model_id=\(streamModel)&output_format=pcm_\(Int(streamSampleRate))"
        guard let url = URL(string: urlStr) else { throw ELError.decode }
        var req = URLRequest(url: url)
        req.setValue(AppConfig.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        let task = URLSession.shared.webSocketTask(with: req)
        ws = task
        task.resume()

        // 1) BOS — voice settings + the latency dial. 2) the reply text. 3) "" to flush+close.
        sendJSON([
            "text": " ",
            "voice_settings": [
                "stability": AppConfig.stability,
                "similarity_boost": AppConfig.similarity,
                "style": AppConfig.style,
                "use_speaker_boost": AppConfig.speakerBoost,
                "speed": AppConfig.speed
            ],
            "generation_config": ["chunk_length_schedule": chunkSchedule]
        ], on: task)
        sendJSON(["text": text + " "], on: task)
        sendJSON(["text": ""], on: task)

        receive(token: token, task: task)

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            guard token == playToken else { c.resume(); return }
            finishCont = c
        }
    }

    private func sendJSON(_ obj: [String: Any], on task: URLSessionWebSocketTask) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        task.send(.string(s)) { _ in }
    }

    private func receive(token: Int, task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, token == self.playToken else { return }
                switch result {
                case .failure:
                    // Socket closed/errored — no more audio is coming. Don't cut off
                    // buffers still queued; just mark final and let them finish.
                    self.receivedFinal = true
                    self.maybeFinish()
                case .success(let msg):
                    var raw: Data?
                    switch msg {
                    case .string(let s): raw = s.data(using: .utf8)
                    case .data(let d): raw = d
                    @unknown default: break
                    }
                    if let raw, let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                        if let b64 = obj["audio"] as? String, !b64.isEmpty,
                           let pcm = Data(base64Encoded: b64), !pcm.isEmpty {
                            self.schedule(pcm: pcm, token: token)
                        }
                        if (obj["isFinal"] as? Bool) == true { self.receivedFinal = true }
                    }
                    self.receive(token: token, task: task)   // keep listening
                    self.maybeFinish()
                }
            }
        }
    }

    /// Convert a PCM16 mono chunk to a float buffer and queue it on the player node.
    private func schedule(pcm: Data, token: Int) {
        guard token == playToken, let node, let fmt = format else { return }
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        pcm.withUnsafeBytes { rawBuf in
            let ints = rawBuf.bindMemory(to: Int16.self)
            guard let out = buf.floatChannelData?[0] else { return }
            var sumSq: Float = 0
            for i in 0..<Int(frames) {
                let v = Float(ints[i]) / 32768.0
                out[i] = v
                sumSq += v * v
            }
            let rms = sqrt(sumSq / Float(frames))
            playbackLevel = min(1, rms * 3.0)
        }
        outstanding += 1
        node.scheduleBuffer(buf, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, token == self.playToken else { return }
                self.outstanding -= 1
                self.maybeFinish()
            }
        })
    }

    /// Finish once the server has signalled the end AND every queued buffer has played.
    private func maybeFinish() {
        guard receivedFinal, outstanding <= 0 else { return }
        playbackLevel = 0
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        node?.stop(); node = nil
        if engine.isRunning { engine.stop() }
        let c = finishCont; finishCont = nil; c?.resume()
    }
}
