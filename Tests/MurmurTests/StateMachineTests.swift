import Testing
@testable import Murmur

@Suite struct StateMachineTests {
    @Test func idleHotkeyStartsRecording() {
        let (state, action) = transition(.idle, .hotkey)
        #expect(state == .recording)
        #expect(action == .startRecording)
    }

    @Test func recordingHotkeyStopsAndProcesses() {
        let (state, action) = transition(.recording, .hotkey)
        #expect(state == .processing)
        #expect(action == .stopAndProcess)
    }

    @Test func recordingEscapeCancels() {
        let (state, action) = transition(.recording, .escape)
        #expect(state == .idle)
        #expect(action == .cancelRecording)
    }

    @Test func recordingCapStopsAndProcesses() {
        let (state, action) = transition(.recording, .recordingCap)
        #expect(state == .processing)
        #expect(action == .stopAndProcess)
    }

    @Test func processingHotkeyIgnored() {
        let (state, action) = transition(.processing, .hotkey)
        #expect(state == .processing)
        #expect(action == .none)
    }

    @Test func processingDoneReturnsToIdle() {
        let (state, action) = transition(.processing, .done)
        #expect(state == .idle)
        #expect(action == .none)
    }

    /// Everything not in the transition table: same state, no action.
    @Test func allUnlistedTransitionsAreNoOps() {
        let listed: Set<String> = [
            "idle-hotkey", "recording-hotkey", "recording-escape",
            "recording-recordingCap", "processing-done", "processing-hotkey",
        ]
        let states: [State] = [.idle, .recording, .processing]
        let events: [Event] = [.hotkey, .escape, .done, .recordingCap]
        for state in states {
            for event in events {
                guard !listed.contains("\(state)-\(event)") else { continue }
                let (newState, action) = transition(state, event)
                #expect(newState == state, "\(state) + \(event) must not change state")
                #expect(action == .none, "\(state) + \(event) must not act")
            }
        }
    }
}
