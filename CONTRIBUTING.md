# Contributing

PRs welcome.

```bash
swift build       # build
./test.sh         # run tests (plain `swift test` if you have full Xcode)
```

Ground rules:

- **Zero dependencies.** Foundation's URLSession talks to OpenAI directly. PRs adding packages will be declined.
- New STT providers go behind the existing `TranscriptionClient` protocol.
- OS-level behavior (Carbon hotkeys, TCC, pasteboard, mic) is verified manually; unit tests cover the pure logic (state machine, parser, settings, formatter).
- Keep the menu the entire UI. No settings window.
