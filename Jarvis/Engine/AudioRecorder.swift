import Foundation
import AVFoundation

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
        meterTimer?.invalidate(); meterTimer = nil
        recorder?.stop()
        recorder = nil
        level = 0
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
