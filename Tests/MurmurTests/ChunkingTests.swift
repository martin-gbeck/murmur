import Foundation
import Testing
@testable import Murmur

@Suite struct SilenceChunkerTests {
    private let rate = 16_000.0
    private let blockSamples = 1_600  // 100 ms, like the live tap

    /// Loud block: near-full-scale signal (~0 dBFS).
    private func speech(seconds: Double) -> [Int16] {
        let count = Int(seconds * rate)
        return (0..<count).map { $0 % 2 == 0 ? 20_000 : -20_000 }
    }

    /// Quiet speech (~-40 dBFS): well above a quiet room's floor, but far below
    /// the old fixed -42 threshold that wrongly classified it as silence.
    private func quietSpeech(seconds: Double) -> [Int16] {
        let count = Int(seconds * rate)
        return (0..<count).map { $0 % 2 == 0 ? 300 : -300 }
    }

    private func silence(seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * rate))
    }

    private func makeChunker() -> SilenceChunker {
        SilenceChunker(
            sampleRate: rate,
            silenceMarginDb: 8.0,
            minSilenceSeconds: 0.5,
            minChunkSeconds: 2.0
        )
    }

    /// Feed a long signal block by block (100 ms), as the live tap does, so the
    /// adaptive noise floor sees realistic granularity. Returns any single cut.
    @discardableResult
    private func feed(_ chunker: inout SilenceChunker, _ samples: [Int16]) -> SilenceChunker.Chunk? {
        var result: SilenceChunker.Chunk?
        var i = 0
        while i < samples.count {
            let block = Array(samples[i..<min(i + blockSamples, samples.count)])
            i += blockSamples
            if let cut = chunker.append(block) { result = cut }
        }
        return result
    }

    @Test func cutsAtPauseAfterSpeech() {
        var chunker = makeChunker()
        #expect(feed(&chunker, speech(seconds: 3)) == nil)
        let cut = feed(&chunker, silence(seconds: 0.6))
        #expect(cut != nil)
        #expect(cut!.hasSpeech)
        #expect(Double(cut!.samples.count) / rate >= 3.0)
    }

    @Test func noCutBeforeMinChunkLength() {
        var chunker = makeChunker()
        #expect(feed(&chunker, speech(seconds: 1)) == nil)
        // Pause is long enough, but the chunk is shorter than minChunkSeconds.
        #expect(feed(&chunker, silence(seconds: 0.6)) == nil)
    }

    @Test func noCutWhileSpeaking() {
        var chunker = makeChunker()
        for _ in 0..<10 {
            #expect(feed(&chunker, speech(seconds: 1)) == nil)
        }
    }

    /// The regression that dropped real speech: quiet talking in a quiet room
    /// must be flagged as speech, not trimmed away as silence.
    @Test func quietSpeechCountsAsSpeech() {
        var chunker = makeChunker()
        feed(&chunker, quietSpeech(seconds: 3))
        let tail = chunker.flush()
        #expect(tail.hasSpeech)
        #expect(Double(tail.samples.count) / rate >= 2.5)
    }

    /// A chunk that was only silence must report hasSpeech == false, so the
    /// recorder never uploads it (STT hallucinates on silent audio).
    @Test func pureSilenceHasNoSpeech() {
        var chunker = makeChunker()
        feed(&chunker, silence(seconds: 3))
        let tail = chunker.flush()
        #expect(!tail.hasSpeech)
    }

    @Test func flushReturnsTailAndResets() {
        var chunker = makeChunker()
        feed(&chunker, speech(seconds: 1))
        let tail = chunker.flush()
        #expect(Double(tail.samples.count) / rate == 1.0)
        #expect(chunker.flush().samples.isEmpty)
    }

    /// Uploaded silence is billed audio: cuts drop the trailing pause, keeping
    /// only the 0.25s pad — both at a cut and at flush.
    @Test func cutTrimsTrailingSilence() {
        var chunker = makeChunker()
        #expect(feed(&chunker, speech(seconds: 3)) == nil)
        let cut = feed(&chunker, silence(seconds: 2.0))
        let seconds = Double(cut!.samples.count) / rate
        #expect(seconds >= 3.0 && seconds <= 3.0 + SilenceChunker.trailingPadSeconds + 0.2)
    }

    @Test func flushTrimsTrailingSilence() {
        var chunker = makeChunker()
        feed(&chunker, speech(seconds: 1))
        feed(&chunker, silence(seconds: 0.4))  // below minSilence, no cut
        let tail = chunker.flush()
        let seconds = Double(tail.samples.count) / rate
        #expect(seconds >= 1.0 && seconds <= 1.0 + SilenceChunker.trailingPadSeconds + 0.2)
    }

    @Test func dbfsLevels() {
        #expect(SilenceChunker.dbFS([]) == -120)
        #expect(SilenceChunker.dbFS(silence(seconds: 0.1)) == -120)
        let loud = SilenceChunker.dbFS(speech(seconds: 0.1))
        #expect(loud > -10 && loud <= 0)
    }
}

@Suite struct WAVTests {
    @Test func headerLayout() {
        let samples: [Int16] = [0, 1, -1, 32_767]
        let data = WAV.data(samples: samples, sampleRate: 16_000)
        #expect(data.count == WAV.headerSize + samples.count * 2)
        #expect(String(data: data[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        #expect(String(data: data[12..<16], encoding: .ascii) == "fmt ")
        #expect(String(data: data[36..<40], encoding: .ascii) == "data")
        // data chunk size, little endian
        let dataSize = data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(dataSize == UInt32(samples.count * 2))
        // sample rate field
        let rateField = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(rateField == 16_000)
    }

    @Test func incrementalWriterMatchesOneShotEncoding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-wav-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let a: [Int16] = Array(repeating: 1_000, count: 100)
        let b: [Int16] = Array(repeating: -1_000, count: 50)

        let writer = try WavFileWriter(url: url, sampleRate: 16_000)
        writer.append(a)
        writer.append(b)
        writer.finalize()

        let written = try Data(contentsOf: url)
        let oneShot = WAV.data(samples: a + b, sampleRate: 16_000)
        #expect(written == oneShot)
    }

    @Test func discardRemovesFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-wav-discard-\(UUID().uuidString).wav")
        let writer = try WavFileWriter(url: url, sampleRate: 16_000)
        writer.append([1, 2, 3])
        writer.discard()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
