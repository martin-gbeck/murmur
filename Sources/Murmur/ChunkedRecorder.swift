import AVFoundation
import Foundation

/// AVAudioEngine-based recorder that emits transcription-ready WAV chunks at
/// speech pauses while continuously writing the full recording to a master WAV.
///
/// Used when `incrementalTranscription` is on: chunks are transcribed in the
/// background during recording, so on stop only the tail remains. The master
/// file backs "Retry last recording" and the whole-file fallback if any chunk
/// transcription fails.
final class ChunkedRecorder {
    struct StopResult {
        let master: URL
        /// Every speech chunk of the recording, in spoken order, including the
        /// final tail. This is the authoritative assembly order — the pipeline
        /// joins exactly these, so no chunk can be lost to callback timing.
        let orderedChunks: [URL]
    }

    /// Called on the main thread when a chunk is cut at a speech pause, so its
    /// transcription can start early. Delivery is best-effort for speed only;
    /// `StopResult.orderedChunks` is what the pipeline actually assembles.
    var onChunk: ((URL) -> Void)?

    /// Every speech chunk URL emitted so far, in order (serial-queue guarded).
    private var emittedChunks: [URL] = []

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "dev.martin.murmur.chunker")
    private let settings: Settings

    private var chunker: SilenceChunker
    private var master: WavFileWriter?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var baseName = ""
    private var chunkIndex = 0
    private var startTime: Date?

    private static let sampleRate = 16_000

    init(settings: Settings) {
        self.settings = settings
        self.chunker = SilenceChunker(
            sampleRate: Double(Self.sampleRate),
            silenceMarginDb: settings.silenceMarginDb,
            minSilenceSeconds: settings.silenceMinSeconds,
            minChunkSeconds: settings.chunkMinSeconds
        )
    }

    var elapsedSeconds: Double {
        guard let startTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }

    func start() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Recorder.recordingsDir, withIntermediateDirectories: true)
        // Same retention rule as Recorder: previous recording survives until
        // the next one starts.
        if let existing = try? fm.contentsOfDirectory(at: Recorder.recordingsDir, includingPropertiesForKeys: nil) {
            for url in existing { try? fm.removeItem(at: url) }
        }

        baseName = "rec-" + ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        chunkIndex = 0
        emittedChunks = []
        master = try WavFileWriter(
            url: Recorder.recordingsDir.appendingPathComponent("\(baseName).wav"),
            sampleRate: Self.sampleRate
        )

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw Recorder.RecorderError.couldNotStart
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw Recorder.RecorderError.couldNotStart
        }
        self.targetFormat = target
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            master?.discard()
            master = nil
            throw error
        }
        startTime = Date()
    }

    /// Stops the engine, flushes the tail chunk, finalizes the master file.
    func stop() -> StopResult? {
        guard let master else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        startTime = nil

        var ordered: [URL] = []
        queue.sync {
            let remaining = chunker.flush()
            // Only a tail that actually contained speech is uploaded: STT models
            // hallucinate filler ("Thank you.") on silent audio. The flag is the
            // per-block adaptive decision, not a whole-chunk average — so a quiet
            // final word still counts as speech and is never dropped.
            if remaining.hasSpeech, let url = writeChunk(remaining.samples) {
                emittedChunks.append(url)
            }
            master.finalize()
            ordered = emittedChunks
        }
        let result = StopResult(master: master.url, orderedChunks: ordered)
        self.master = nil
        return result
    }

    /// Cancel path (Esc): stop everything and delete all files of this recording.
    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        startTime = nil
        queue.sync {
            _ = chunker.flush()
            master?.discard()
            master = nil
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: Recorder.recordingsDir, includingPropertiesForKeys: nil) {
                for url in files where url.lastPathComponent.hasPrefix(baseName) {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - Audio path

    /// Tap callback (audio thread): convert to 16 kHz mono Int16, then hand the
    /// samples to the serial queue for chunking and file writes.
    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = out.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        guard !samples.isEmpty else { return }

        queue.async { [weak self] in
            self?.process(samples)
        }
    }

    /// Serial queue: master write, silence-cut decision, chunk emission.
    private func process(_ samples: [Int16]) {
        master?.append(samples)
        guard let cut = chunker.append(samples) else { return }
        // Silent chunks are written to the master only, never transcribed.
        guard cut.hasSpeech, let url = writeChunk(cut.samples) else { return }
        emittedChunks.append(url)
        if let onChunk {
            DispatchQueue.main.async { onChunk(url) }
        }
    }

    private func writeChunk(_ samples: [Int16]) -> URL? {
        guard !samples.isEmpty else { return nil }
        chunkIndex += 1
        let url = Recorder.recordingsDir
            .appendingPathComponent(String(format: "%@-chunk-%03d.wav", baseName, chunkIndex))
        do {
            try WAV.data(samples: samples, sampleRate: Self.sampleRate).write(to: url)
            return url
        } catch {
            NSLog("Murmur chunker: failed to write chunk %d: %@", chunkIndex, error.localizedDescription)
            return nil
        }
    }
}
