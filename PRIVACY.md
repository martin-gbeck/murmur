# Privacy

Murmur is designed so there is nothing to trust us with. There is no server, no account, no telemetry, no analytics, no crash reporting, and no auto-update phone-home.

## What is recorded

Microphone audio, only between the moment you press the hotkey and the moment you press it again (or Esc, which discards it). The menu-bar icon is red the entire time the mic is open.

## Where it goes

1. **Your disk**: the recording is written to `~/Library/Application Support/Murmur/recordings/` and kept only until your next recording starts (so a failed transcription can be retried).
2. **OpenAI** (`api.openai.com`): the audio is sent to OpenAI's transcription API, and the resulting text to OpenAI's chat API for cleanup (if "Format text" is on). Per [OpenAI's API data usage policy](https://openai.com/policies/api-data-usage-policies), API data is not used for training by default.
3. **Your disk again**: transcripts are appended to `~/Library/Application Support/Murmur/history.jsonl` for the History menu. Toggleable (`defaults write dev.martin.murmur keepHistory -bool false`) and clearable from the menu.

Your OpenAI API key is stored in the macOS Keychain, never on disk and never sent anywhere except `api.openai.com`.

## What is never collected

Everything else. Murmur has no knowledge of what app you paste into, no keystroke access (the Carbon hotkey API delivers only the registered chord), and no network traffic other than the two OpenAI API calls above.
