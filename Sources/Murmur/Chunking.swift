import Foundation

/// Pure sample-domain logic for silence-aware chunking. No I/O, unit-testable.
///
/// Feed blocks of 16 kHz mono Int16 samples; when a pause in speech is detected
/// and the accumulated chunk is at least `minChunkSeconds` long, the chunk is
/// cut and returned so it can be transcribed while the user keeps talking.
///
/// "Silence" is adaptive, not a fixed level: the chunker tracks the quietest
/// recent block as the room's noise floor and classifies a block as silent when
/// it is within `silenceMarginDb` of that floor. This is what makes whispering
/// work — a whisper is quiet in absolute terms but well above the noise floor.
struct SilenceChunker {
    /// A finished chunk. `hasSpeech == false` means every block was classified
    /// silent — callers must not upload such chunks (STT hallucinates on them).
    struct Chunk {
        let samples: [Int16]
        let hasSpeech: Bool
    }

    let sampleRate: Double
    let silenceMarginDb: Double
    let minSilenceSeconds: Double
    let minChunkSeconds: Double

    private var current: [Int16] = []
    private var silentSamples = 0
    private var currentHasSpeech = false
    private var noiseFloorDb = -120.0

    /// Padding of trailing silence kept on a trimmed chunk, so words are never
    /// clipped mid-decay.
    static let trailingPadSeconds = 0.25

    /// The adaptive threshold never leaves this range: below -65 everything
    /// would count as speech in a dead-quiet room; above -30 normal speech
    /// would start counting as silence in a very noisy one.
    static let thresholdRangeDb = (-65.0)...(-30.0)

    /// How fast the tracked floor is allowed to rise, per block (~100 ms).
    /// Rising slowly means a long loud stretch can't fake a higher floor;
    /// dropping is instant on the first quiet block.
    private static let floorRisePerBlockDb = 0.05

    init(
        sampleRate: Double = 16_000,
        silenceMarginDb: Double = 8.0,
        minSilenceSeconds: Double = 0.7,
        minChunkSeconds: Double = 45.0
    ) {
        self.sampleRate = sampleRate
        self.silenceMarginDb = silenceMarginDb
        self.minSilenceSeconds = minSilenceSeconds
        self.minChunkSeconds = minChunkSeconds
    }

    /// Current block-level silence threshold in dBFS.
    var currentThresholdDb: Double {
        min(max(noiseFloorDb + silenceMarginDb, Self.thresholdRangeDb.lowerBound),
            Self.thresholdRangeDb.upperBound)
    }

    /// Append a block of samples. Returns a finished chunk when a cut happens.
    mutating func append(_ samples: [Int16]) -> Chunk? {
        guard !samples.isEmpty else { return nil }
        current.append(contentsOf: samples)

        let db = Self.dbFS(samples)
        noiseFloorDb = min(db, noiseFloorDb + Self.floorRisePerBlockDb)

        if db < currentThresholdDb {
            silentSamples += samples.count
        } else {
            silentSamples = 0
            currentHasSpeech = true
        }

        let chunkSeconds = Double(current.count) / sampleRate
        let silentSeconds = Double(silentSamples) / sampleRate
        guard silentSeconds >= minSilenceSeconds, chunkSeconds >= minChunkSeconds else {
            return nil
        }
        return takeChunk()
    }

    /// Returns whatever is buffered (the tail after the last cut) and resets.
    mutating func flush() -> Chunk {
        takeChunk()
    }

    /// Cut the current buffer into a Chunk: trailing silence is dropped (the
    /// API bills per audio second, so uploaded silence is pure cost; the master
    /// file keeps everything), a short pad is kept so the last word's decay
    /// survives, and the speech flag is reported for the upload decision.
    private mutating func takeChunk() -> Chunk {
        let pad = Int(Self.trailingPadSeconds * sampleRate)
        let samples = silentSamples > pad
            ? Array(current.dropLast(silentSamples - pad))
            : current
        let chunk = Chunk(samples: samples, hasSpeech: currentHasSpeech)
        current = []
        silentSamples = 0
        currentHasSpeech = false
        return chunk
    }

    /// RMS level in dBFS. Silence (all zeros / empty) floors at -120.
    static func dbFS(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return -120 }
        let sumOfSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot()
        guard rms > 0 else { return -120 }
        return 20 * log10(rms / 32_768.0)
    }
}

/// Minimal PCM WAV encoding (16-bit little-endian mono).
enum WAV {
    static let headerSize = 44

    static func data(samples: [Int16], sampleRate: Int) -> Data {
        var data = header(dataBytes: samples.count * 2, sampleRate: sampleRate)
        data.append(samplesData(samples))
        return data
    }

    static func samplesData(_ samples: [Int16]) -> Data {
        // arm64 is little-endian, matching the WAV byte order.
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func header(dataBytes: Int, sampleRate: Int) -> Data {
        var data = Data(capacity: headerSize)
        func u32(_ value: Int) {
            var v = UInt32(value).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func u16(_ value: Int) {
            var v = UInt16(value).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataBytes)                  // RIFF chunk size
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16)                              // fmt chunk size
        u16(1)                               // PCM
        u16(1)                               // mono
        u32(sampleRate)
        u32(sampleRate * 2)                  // byte rate
        u16(2)                               // block align
        u16(16)                              // bits per sample
        data.append(contentsOf: Array("data".utf8))
        u32(dataBytes)
        return data
    }
}

/// Incrementally writes a WAV file as samples arrive; the header is patched
/// with the real sizes on finalize.
final class WavFileWriter {
    let url: URL
    private let sampleRate: Int
    private let handle: FileHandle
    private var samplesWritten = 0
    private var finalized = false

    init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: WAV.header(dataBytes: 0, sampleRate: sampleRate))
    }

    func append(_ samples: [Int16]) {
        guard !finalized, !samples.isEmpty else { return }
        try? handle.write(contentsOf: WAV.samplesData(samples))
        samplesWritten += samples.count
    }

    func finalize() {
        guard !finalized else { return }
        finalized = true
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: WAV.header(dataBytes: samplesWritten * 2, sampleRate: sampleRate))
        try? handle.close()
    }

    /// Cancel path: close and remove the file.
    func discard() {
        finalized = true
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}
