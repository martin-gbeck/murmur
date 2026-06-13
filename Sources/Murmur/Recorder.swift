import AVFoundation
import Foundation

/// AVAudioRecorder straight to 16 kHz mono 16-bit WAV — what STT models want;
/// higher rates only slow the upload.
final class Recorder {
    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "Could not start recording — check microphone access" }
    }

    static let recordingsDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur/recordings", isDirectory: true)

    // All five PCM keys are required; missing AVLinearPCMIsFloatKey yields a file the API rejects.
    static let wavSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?

    /// Keep the most recent file until the next recording starts (enables
    /// "Retry last recording"); older files are deleted here.
    func start() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.recordingsDir, withIntermediateDirectories: true)
        if let existing = try? fm.contentsOfDirectory(at: Self.recordingsDir, includingPropertiesForKeys: nil) {
            for url in existing { try? fm.removeItem(at: url) }
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = Self.recordingsDir.appendingPathComponent("rec-\(stamp).wav")
        let rec = try AVAudioRecorder(url: url, settings: Self.wavSettings)
        guard rec.record() else { throw RecorderError.couldNotStart }
        recorder = rec
        currentURL = url
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        return currentURL
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentURL = nil
    }

    var elapsedSeconds: Double {
        recorder?.currentTime ?? 0
    }

    var isRecording: Bool {
        recorder?.isRecording ?? false
    }
}
