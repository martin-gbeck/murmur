# Architecture

The design Murmur is built on: what each piece does, how audio flows from the
mic to pasted text, and the decisions that shaped it. Read this before changing
the core loop.

## Design priorities

1. **Just works, zero involvement.** Sensible defaults everywhere. The only
   mandatory setup is pasting an OpenAI API key on first launch.
2. **Lightweight and native.** Pure Swift + AppKit, built with Swift Package
   Manager, no Xcode project, no third-party dependencies. The binary is about
   half a megabyte. Foundation's `URLSession` talks to OpenAI directly.
3. **Bring your own key, nothing else leaves the machine.** No account, no
   server, no telemetry. Audio goes from the mic to OpenAI and the text lands at
   the cursor. The API key lives in the macOS Keychain, never on disk.
4. **The menu bar is the entire UI.** No Dock icon, no settings window. Small
   non-activating overlays are allowed; a focus-stealing window is not.

## The core loop

1. Global hotkey (default `ctrl+option+space`) toggles recording on.
2. The mic is captured. While the user speaks, audio is transcribed
   incrementally at natural pauses (see *Incremental transcription*), so most of
   the work is already done before they stop.
3. The hotkey toggles recording off. Only the final chunk still needs
   transcribing.
4. The assembled transcript is optionally cleaned up by a small LLM (fillers
   removed, self-corrections applied, punctuation added).
5. The text is pasted into the focused app via a synthetic Cmd+V; the previous
   clipboard contents are restored afterward.

## State machine (`StateMachine.swift`)

Three states — `idle`, `recording`, `processing` — and a pure transition
function with no I/O, exhaustively unit-tested. The whole app's control flow is
this table:

| State | Event | → State | Action |
|---|---|---|---|
| idle | hotkey | recording | startRecording |
| recording | hotkey | processing | stopAndProcess |
| recording | escape | idle | cancelRecording |
| recording | recordingCap | processing | stopAndProcess |
| processing | done | idle | (none) |

Anything not listed is a no-op. Because hotkeys are ignored during `processing`,
there is exactly one transcription pipeline running at a time.

## Module map

| Module | Responsibility |
|---|---|
| `main.swift` | Entry point; menu-bar app, or one of the `--cli*` dev modes |
| `AppDelegate.swift` | Owns all state; wires modules; runs the pipeline |
| `StateMachine.swift` | Pure transition logic |
| `StatusBarController.swift` | `NSStatusItem`, menu construction, icon states |
| `HotkeyManager.swift` | Carbon global hotkeys (main, Esc, format-toggle) + chord parsing |
| `HotkeyCapturePanel.swift` | In-app "press the new shortcut" recorder |
| `Recorder.swift` | Plain `AVAudioRecorder` → 16 kHz mono WAV (fallback path) |
| `ChunkedRecorder.swift` | `AVAudioEngine` tap → silence-cut chunks + master WAV |
| `Chunking.swift` | `SilenceChunker` (adaptive pause detection) + WAV encoding |
| `OpenAIClient.swift` | Multipart STT upload + chat completion, behind a protocol |
| `TranscriptFormatter.swift` | LLM cleanup pass, with raw-text fallback |
| `Paster.swift` | Clipboard swap + synthetic Cmd+V |
| `Overlay.swift` | Non-activating floating pills (recording indicator, paste hint) |
| `Settings.swift` | Typed `UserDefaults` wrapper + Keychain-backed API key |
| `Permissions.swift` | Microphone / Accessibility checks and deep links |
| `History.swift` | Last-N transcripts as JSONL |
| `Sounds.swift` | System sound cues |
| `Notifier.swift` | User notifications (the only error-reporting channel) |

## The pipeline (`AppDelegate`)

One async function per recording. On stop:

- **Incremental path:** await the per-chunk transcription tasks in the recorder's
  authoritative spoken order, join them, then run the optional formatting pass.
- **Whole-file path** (incremental off, or any chunk fails): transcribe the
  master WAV in one call.

Either way the result goes through a shared tail: empty-speech check → optional
formatting → history append → paste. Every failure ends in exactly one
notification, and the audio file is kept so "Retry last recording" can re-run.

## Incremental transcription (`ChunkedRecorder` + `SilenceChunker`)

The latency win. Transcription runs at roughly 0.12× realtime, so transcribing a
five-minute recording only after the user stops would mean a ~35 s wait. Instead:

- An `AVAudioEngine` tap delivers ~100 ms buffers, converted to 16 kHz mono
  Int16, while recording continues.
- `SilenceChunker` cuts a chunk when speech has paused (`silenceMinSeconds`)
  *and* the chunk is at least `chunkMinSeconds` long. Each cut chunk is
  transcribed immediately in its own task.
- On stop, only the tail since the last cut remains — bounded by
  `chunkMinSeconds` (default 45 s), so the wait is ~5 s regardless of total
  length.

**Correctness guarantees:**

- The whole recording is also written continuously to one master WAV. If any
  chunk transcription fails, the pipeline discards the chunks and transcribes the
  master whole — never worse than the non-incremental path.
- The recorder returns the **authoritative ordered list** of chunk URLs at stop.
  Assembly indexes tasks by URL and joins strictly in that order, so a chunk cut
  in the instant before stop can never be lost to callback timing.

**Adaptive silence detection:** "silence" is measured relative to the room's
noise floor (a tracked minimum), with anything within `silenceMarginDb` of the
floor counted as silence. This is what lets quiet or whispered speech still
register — it is loud relative to the floor even when quiet in absolute terms. A
chunk that contained no speech is never uploaded (STT models hallucinate filler
on silent audio), and trailing silence is trimmed before upload since the API
bills per audio second.

## Why Carbon hotkeys (`HotkeyManager`)

`RegisterEventHotKey` delivers the hotkey to the app directly and consumes the
keystroke, so the chord never leaks into the focused app — and crucially, the app
needs **no Input Monitoring permission and no event tap**. Esc is registered as a
second hotkey only while recording, and unregistered the moment recording ends; a
leaked Esc registration would make Esc dead system-wide, so it is torn down on
every path back to idle.

## Permissions (`Permissions`)

Only two, thanks to the Carbon approach:

| Permission | For | Prompt |
|---|---|---|
| Microphone | Recording | OS auto-prompts on first recording |
| Accessibility | Synthetic Cmd+V paste | Requested right after first-launch key entry |

Ad-hoc code signing means the Accessibility grant is invalidated on every
rebuild; the app detects this ("was trusted, now isn't") and tells the user to
remove and re-add it. A packaged, stably-signed build does not have this issue.

## Settings & secrets (`Settings`)

All preferences are typed accessors over `UserDefaults` with registered
defaults, so reads never need fallbacks and every knob is overridable via
`defaults write`. The API key is the one exception: it lives only in the
Keychain (`SecItem*`), never in `UserDefaults` and never in a file. A
`MURMUR_OPENAI_API_KEY` environment variable overrides it for development.

## Extensibility

`OpenAIClient` sits behind a `TranscriptionClient` protocol, so additional STT
providers are an addition rather than a refactor. The formatter and tests mock
that protocol.

## Testing

`swift test` (or `./test.sh` on a Command Line Tools-only machine) covers the
pure logic: the state-machine table exhaustively, the hotkey-chord parser, the
silence chunker and WAV encoding, settings defaults, and the formatter's
prompt + raw-fallback. OS-level behavior (Carbon, TCC, pasteboard, mic) is
verified manually and via the `--cli`, `--cli-chunked`, and `--overlay-test`
harnesses described in the README.
