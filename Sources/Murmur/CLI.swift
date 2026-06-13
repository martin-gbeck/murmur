import AppKit
import Foundation

/// CLI modes (Milestone 0/1). The fastest way to test the API half without
/// OS permissions: `swift run Murmur --cli`. `--file` skips the mic and
/// transcribes an existing audio file.
func runCLI(paste: Bool, audioFile: URL?) {
    let settings = Settings()

    if settings.apiKey == nil {
        print("No OpenAI API key found in the Keychain.")
        print("Enter your OpenAI API key (sk-…): ", terminator: "")
        guard let key = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            fputs("No key entered, exiting.\n", stderr)
            exit(1)
        }
        if settings.saveAPIKey(key) {
            print("Key saved to Keychain (service \(Keychain.service)).")
        } else {
            fputs("Could not save to Keychain, using the key for this run only.\n", stderr)
            setenv("MURMUR_OPENAI_API_KEY", key, 1)
        }
    }

    let audio: URL
    if let provided = audioFile {
        guard FileManager.default.fileExists(atPath: provided.path) else {
            fputs("File not found: \(provided.path)\n", stderr)
            exit(1)
        }
        audio = provided
        print("Using audio file: \(provided.path)")
    } else {
        let recorder = Recorder()
        do {
            try recorder.start()
        } catch {
            fputs("\(error.shortMessage)\n", stderr)
            exit(1)
        }
        print("Recording… press Enter to stop.")
        _ = readLine()
        guard let url = recorder.stop() else {
            fputs("Recording produced no file.\n", stderr)
            exit(1)
        }
        audio = url
        print("Saved \(url.lastPathComponent)")
    }

    let client = OpenAIClient(settings: settings)
    let formatter = TranscriptFormatter(client: client, settings: settings)

    let (raw, formatted) = awaitBlocking {
        let raw = try await client.transcribe(audio)
        let formatted = settings.formatText ? await formatter.format(raw) : raw
        return (raw, formatted)
    }

    print("\n--- raw ---")
    print(raw)
    print("\n--- formatted ---")
    print(formatted)

    if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        print("\n(no speech detected — nothing to paste)")
        return
    }

    if paste {
        print("\nPasting in 3…", terminator: "")
        fflush(stdout)
        for n in [2, 1] {
            Thread.sleep(forTimeInterval: 1)
            print(" \(n)…", terminator: "")
            fflush(stdout)
        }
        Thread.sleep(forTimeInterval: 1)
        print()
        let paster = Paster(settings: settings)
        let result = paster.paste(formatted)
        switch result {
        case .pasted:
            // Keep the process alive long enough for the delayed clipboard restore.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: Double(settings.pasteRestoreDelayMs) / 1000 + 0.5))
            print("Pasted. Previous clipboard string restored.")
        case .pastedNoRestore:
            print("Pasted. Previous clipboard had non-text content — not restored.")
        case .noAccessibility:
            print("No Accessibility permission — transcript left on the clipboard instead.")
        }
    }
}

/// Dev harness for incremental transcription: runs an existing 16 kHz mono
/// 16-bit WAV through the silence chunker exactly like a live recording,
/// transcribes each chunk, and prints the per-chunk and joined results.
func runChunkedCLI(file: URL) {
    let settings = Settings()
    guard settings.apiKey != nil else {
        fputs("No API key (Keychain or MURMUR_OPENAI_API_KEY).\n", stderr)
        exit(1)
    }
    guard let data = try? Data(contentsOf: file), data.count > WAV.headerSize else {
        fputs("Cannot read \(file.path)\n", stderr)
        exit(1)
    }

    let pcm = data.dropFirst(WAV.headerSize)
    let samples: [Int16] = pcm.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Int16.self))
    }
    print("Loaded \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16_000))s)")

    var chunker = SilenceChunker(
        sampleRate: 16_000,
        silenceMarginDb: settings.silenceMarginDb,
        minSilenceSeconds: settings.silenceMinSeconds,
        minChunkSeconds: settings.chunkMinSeconds
    )

    var chunks: [[Int16]] = []
    let blockSize = 1_600  // 100 ms blocks, like the live tap
    var index = 0
    while index < samples.count {
        let block = Array(samples[index..<min(index + blockSize, samples.count)])
        index += blockSize
        if let cut = chunker.append(block), cut.hasSpeech {
            chunks.append(cut.samples)
        }
    }
    let tail = chunker.flush()
    if tail.hasSpeech {
        chunks.append(tail.samples)
    }
    print("Cut into \(chunks.count) chunk(s): \(chunks.map { String(format: "%.1fs", Double($0.count) / 16_000) }.joined(separator: ", "))")

    let client = OpenAIClient(settings: settings)
    let formatter = TranscriptFormatter(client: client, settings: settings)
    let tempDir = FileManager.default.temporaryDirectory

    let joined = awaitBlocking {
        var parts: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let url = tempDir.appendingPathComponent("murmur-cli-chunk-\(i).wav")
            try WAV.data(samples: chunk, sampleRate: 16_000).write(to: url)
            let text = try await client.transcribe(url)
            try? FileManager.default.removeItem(at: url)
            print("--- chunk \(i + 1) ---\n\(text)")
            parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    print("\n--- joined raw ---\n\(joined)")
    let formatted = awaitBlocking { await formatter.format(joined) }
    print("\n--- formatted ---\n\(formatted)")
}

/// Bridge async work into the synchronous CLI path.
func awaitBlocking<T>(_ operation: @escaping () async throws -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    Task {
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    switch result! {
    case .success(let value):
        return value
    case .failure(let error):
        fputs("\(error.shortMessage)\n", stderr)
        exit(1)
    }
}
