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

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    func start() {
        guard !running, let recognizer, recognizer.isAvailable else { return }
        running = true

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { running = false; return }

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

    func stop() {
        guard running else { return }   // idempotent
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
