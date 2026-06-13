# Murmur

A lightweight, open-source, pay-as-you-go alternative to premium dictation services. Hold a hotkey, speak, and polished text lands in whatever app you're typing in.

The entire app is about half a megabyte of native Swift. Bring your own OpenAI API key and pay for what you actually dictate: $15, the price of one month's subscription elsewhere, buys roughly 75 hours or 600,000 words of dictation here. Typical use lands near $1/month. No account, no server, no telemetry: your audio goes from your mic to OpenAI and the text lands at your cursor.

> Hero GIF placeholder: record `ctrl+option+space` → speak → text appears in the focused app.

## How it works

1. Press `ctrl+option+space` anywhere. The menu-bar mic turns red, a small pill appears at the bottom of the screen, and a cue plays.
2. Speak. While you talk, Murmur already transcribes the parts you've finished saying (it cuts at your natural pauses), so there's almost nothing left to do when you stop. Press the hotkey again when done (`Esc` cancels).
3. The transcript is cleaned up by a small LLM (fillers removed, self-corrections applied, punctuation added) and pasted at your cursor. Your previous clipboard is restored. If pasting isn't possible, an on-screen hint says so and the text waits on your clipboard.

The menu bar is the entire UI. No Dock icon, no settings window.

## Install

**Requirements:** Apple Silicon Mac, macOS 14+, an [OpenAI API key](https://platform.openai.com/api-keys).

### Option 1: download a release

1. Download `Murmur.zip` from [Releases](../../releases), unzip, drag `Murmur.app` to `/Applications`.
2. macOS will block the first launch because the app is not notarized. Either:
   - System Settings → Privacy & Security → scroll down → **Open Anyway**, or
   - `xattr -dr com.apple.quarantine /Applications/Murmur.app`
3. Launch. This is normal for small open-source Mac tools; build from source if you prefer.

### Option 2: build from source (always clean, no Gatekeeper friction)

Requires only the Xcode Command Line Tools (`xcode-select --install`).

Clone the repo (or download the ZIP via the green **Code** button and unzip it), then from the project folder:

```bash
./packaging/build.sh
cp -r dist/Murmur.app /Applications/
```

`build.sh` compiles a release build and assembles `dist/Murmur.app`. Because you built it locally there's no quarantine flag, so it launches with no Gatekeeper prompt.

## First launch

1. **API key**: Murmur immediately asks for your OpenAI API key. It is stored in the macOS Keychain, never on disk, never sent anywhere except `api.openai.com`.
2. **Accessibility**: macOS then prompts for Accessibility access (needed to paste text at your cursor). Grant it in System Settings, then **relaunch Murmur** (a macOS quirk: the grant only takes effect on relaunch).
3. **Microphone**: macOS asks automatically the first time you record.

That's the whole setup. If something is missing later, a "Fix permissions…" item appears in the menu.

## Costs

| Usage | STT (gpt-4o-mini-transcribe, $0.003/min) | Formatting | Monthly |
|---|---|---|---|
| 10 min/day | $0.90 | ~$0.20 | **~$1.10** |
| 60 min/day | $5.40 | ~$1.00 | **~$6.40** |

What the $15 a subscription charges per month buys you here:

| Mode | Minutes | Hours | Words (~140 wpm) |
|---|---|---|---|
| With AI cleanup (default) | ~4,500 | ~75 | ~600,000 |
| Raw transcription (Format text off) | ~5,000 | ~83 | ~700,000 |

A quiet month costs cents.

## Configuration

Everything has a sensible default. The menu covers day-to-day options: format toggle, language, sounds, the recording indicator, launch at login, and both hotkeys — "Change dictation hotkey…" captures whatever chord you press next, and "Format-toggle hotkey…" sets an optional second shortcut that flips Format text on/off from anywhere.

Hidden knobs via `defaults write` (restart Murmur after changing):

```bash
# Hotkeys can also be set textually (modifiers: ctrl, alt/option, cmd, shift; keys: a-z, 0-9, space, f1-f19)
defaults write dev.martin.murmur hotkey "ctrl+alt+d"
defaults write dev.martin.murmur formatToggleHotkey "ctrl+alt+f"

# Clipboard restore delay in ms (increase if some app pastes the OLD clipboard)
defaults write dev.martin.murmur pasteRestoreDelayMs 500

# Models, if you want different ones
defaults write dev.martin.murmur sttModel "whisper-1"
defaults write dev.martin.murmur formatModel "gpt-4o-mini"

# Incremental transcription (on by default): transcribe at speech pauses while
# you're still talking, so the wait when you stop is only the final chunk
# (~5s at most), no matter how long you spoke. Tuning, if ever needed:
defaults write dev.martin.murmur incrementalTranscription -bool false
defaults write dev.martin.murmur silenceMarginDb 8      # dB above the room's noise floor still counted as silence; lower it if whispering reads as silence
defaults write dev.martin.murmur silenceMinSeconds 0.7  # pause length that triggers a cut
defaults write dev.martin.murmur chunkMinSeconds 45     # min audio per chunk; larger = fewer API calls, slightly longer tail wait
```

Silence is detected relative to your room's noise floor, not a fixed level, so quiet or whispered speech still transcribes. Trailing silence is trimmed from each chunk before upload (you are billed per audio second), and stretches of pure silence are never sent at all.

## FAQ

**Why does Murmur need Accessibility access?**
To synthesize the Cmd+V keystroke that pastes the transcript into the focused app. Murmur uses a Carbon global hotkey, so it needs no Input Monitoring permission and never sees your other keystrokes.

**Where is my API key stored?**
In the macOS Keychain (service `dev.martin.murmur`). Never in a file, never in UserDefaults.

**Pasting does nothing in password fields or some terminals.**
Secure input fields silently swallow synthetic keystrokes and there is no reliable way to detect them. Your transcript is never lost: it stays on the clipboard and in History (menu bar → History).

**The transcription failed. Is my dictation gone?**
No. The recording is kept and the menu gets a "Retry last recording" item. The transcript history also lives in `~/Library/Application Support/Murmur/history.jsonl` (toggleable).

**Nothing pastes after I granted Accessibility.**
Relaunch Murmur. macOS applies the grant only to newly launched processes. During development the grant attaches to whatever launches the binary (your terminal); the packaged .app gets its own grant.

## Development

```bash
swift build              # debug build
./test.sh                # unit tests (wraps `swift test`; needed for CLT-only machines)
swift run Murmur --cli   # record, transcribe, format, print to stdout. No permissions needed
swift run Murmur --cli --file some.wav   # same, from a file
swift run Murmur --cli-paste             # plus a 3-second countdown, then paste
swift run Murmur --cli-chunked --file some-16k-mono.wav  # exercise the silence-cut pipeline
swift run Murmur --overlay-test          # cycle the on-screen pills for 10 seconds
./packaging/build.sh     # release build → dist/Murmur.app (ad-hoc signed)
```

Zero dependencies: Foundation's URLSession talks to OpenAI directly. See [CONTRIBUTING.md](CONTRIBUTING.md) for contributing and [ARCHITECTURE.md](ARCHITECTURE.md) for how the app is structured and the design it's built on.

## Roadmap

- Personal dictionary (names and jargon, biased into transcription)
- Snippet library (voice cue → expanded text)
- Optional app-aware tone for the cleanup pass
- Other STT providers (Groq, Deepgram, local whisper.cpp) behind the existing client protocol
- Push-to-talk mode (hold instead of toggle)
- Notarized releases, then a Homebrew cask

## License

[MIT](LICENSE). Privacy details in [PRIVACY.md](PRIVACY.md).
