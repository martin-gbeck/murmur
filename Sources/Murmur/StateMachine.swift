// Pure transition logic. No I/O, fully unit-testable.

enum State {
    case idle, recording, processing
}

enum Event {
    case hotkey, escape, done, recordingCap
}

enum Action {
    case startRecording, stopAndProcess, cancelRecording, none
}

/// The complete behavior table. Anything not listed: same state, no action.
/// `done` fires on pipeline completion, success or handled failure.
func transition(_ state: State, _ event: Event) -> (State, Action) {
    switch (state, event) {
    case (.idle, .hotkey):
        return (.recording, .startRecording)
    case (.recording, .hotkey):
        return (.processing, .stopAndProcess)
    case (.recording, .escape):
        return (.idle, .cancelRecording)
    case (.recording, .recordingCap):
        return (.processing, .stopAndProcess)
    case (.processing, .done):
        return (.idle, .none)
    default:
        return (state, .none)
    }
}
