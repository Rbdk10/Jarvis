import Foundation
import AVFoundation
import Speech

/// Records a voice note to m4a and publishes a normalised input level (0...1) for the orb.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?

    var fileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-input.m4a")
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let rec = try AVAudioRecorder(url: fileURL, settings: settings)
        rec.isMeteringEnabled = true
        rec.record()
        recorder = rec

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            r.updateMeters()
            self.level = AudioLevel.normalize(r.averagePower(forChannel: 0))
        }
    }

    @discardableResult
    func stop() -> URL? {
        guard recorder != nil else { return nil }   // idempotent: a 2nd stop must not re-publish level
        meterTimer?.invalidate(); meterTimer = nil
        recorder?.stop()
        recorder = nil
        if level != 0 { level = 0 }                  // avoid a redundant publish that could feed a loop
        return fileURL
    }
}

enum AudioLevel {
    /// Map dBFS (-50...0) to 0...1.
    static func normalize(_ db: Float) -> Float {
        let minDb: Float = -50
        if db < minDb { return 0 }
        if db >= 0 { return 1 }
        return (db - minDb) / (0 - minDb)
    }
}

/// Continuously listens on-device for the wake word "Jarvis" using the Speech
/// framework, and fires `onWake` the moment it hears it. Used to gate listening so
/// Jarvis only starts capturing a command when called by name (not on any sound).
@MainActor
final class WakeWordListener: ObservableObject {
    var onWake: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var retryWork: DispatchWorkItem?
    private var retryCount = 0

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    func start() {
        guard !running, let recognizer, recognizer.isAvailable else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { retryStart(); return }

        let input = engine.inputNode
        input.removeTap(onBus: 0)                 // never install over an existing tap

        // installTap throws an UNCATCHABLE Obj-C exception if the format is invalid
        // (0 Hz / 0 channels) — which happens when the mic isn't input-ready yet, e.g.
        // right after TTS playback. Guard the precondition and retry rather than crash.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { retryStart(); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do { try engine.start() }
        catch { input.removeTap(onBus: 0); request = nil; retryStart(); return }

        running = true
        retryCount = 0
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let result,
               result.bestTranscription.formattedString.lowercased().contains("jarvis") {
                Task { @MainActor in self?.fire() }
            }
            if error != nil {
                Task { @MainActor in self?.bounce() }
            }
        }
    }

    /// The mic can take a moment to become input-ready after the player releases the
    /// session. Retry shortly (bounded) instead of installing a tap with a bad format.
    private func retryStart() {
        retryWork?.cancel()
        guard retryCount < 10 else { retryCount = 0; return }
        retryCount += 1
        let work = DispatchWorkItem { [weak self] in self?.start() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func stop() {
        retryWork?.cancel(); retryWork = nil
        retryCount = 0
        running = false
        task?.cancel(); task = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio(); request = nil
    }

    private func fire() {
        guard running else { return }
        stop()
        onWake?()
    }

    /// Recognition sessions are time-limited; if one ends on its own, start a fresh one.
    private func bounce() {
        guard running else { return }
        stop()
        start()
    }
}

/// The result of an on-device transcription: the text plus the recogniser's average
/// per-word confidence. `confidence` is `-1` when the recogniser reports no confidence
/// scores (so callers know to skip confidence gating rather than treat it as "low").
struct STTResult {
    let text: String
    let confidence: Float   // 0...1, or -1 if unavailable
}

/// Transcribes a recorded audio file ON-DEVICE via the Speech framework — no network
/// round-trip, so your command becomes text almost instantly. Returns nil if on-device
/// recognition is unavailable or yields nothing, so the caller can fall back to cloud STT.
@MainActor
final class OnDeviceSTT {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func transcribe(fileURL: URL) async -> STTResult? {
        guard let recognizer, recognizer.isAvailable else { return nil }
        let req = SFSpeechURLRecognitionRequest(url: fileURL)
        req.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        return await withCheckedContinuation { (cont: CheckedContinuation<STTResult?, Never>) in
            let once = ResumeOnce(cont)
            // Safety net: never hang the conversation if recognition never completes.
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { once.fire(nil) }
            recognizer.recognitionTask(with: req) { result, error in
                if let result, result.isFinal {
                    let t = result.bestTranscription
                    // Average confidence over the segments that carry a score. Background
                    // noise / footsteps that slip past the recogniser come back as a few
                    // stray words with near-zero confidence; real speech scores much higher.
                    let scored = t.segments.filter { $0.confidence > 0 }
                    let conf = scored.isEmpty
                        ? -1
                        : scored.map { $0.confidence }.reduce(0, +) / Float(scored.count)
                    once.fire(STTResult(text: t.formattedString, confidence: conf))
                } else if error != nil {
                    once.fire(nil)
                }
            }
        }
    }
}

/// Resumes a continuation at most once, thread-safely (the recognition callback and the
/// timeout can race).
private final class ResumeOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    private let cont: CheckedContinuation<STTResult?, Never>
    init(_ c: CheckedContinuation<STTResult?, Never>) { cont = c }
    func fire(_ value: STTResult?) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        cont.resume(returning: value)
    }
}
