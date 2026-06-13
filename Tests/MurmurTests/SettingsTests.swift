import Foundation
import Testing
@testable import Murmur

@Suite struct SettingsTests {
    private func freshSettings(suite: String) -> Settings {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Settings(defaults: defaults)
    }

    @Test func registeredDefaults() {
        let settings = freshSettings(suite: "dev.martin.murmur.tests.defaults")
        #expect(settings.formatText)
        #expect(settings.sttModel == "gpt-4o-mini-transcribe")
        #expect(settings.formatModel == "gpt-4o-mini")
        #expect(settings.language == "auto")
        #expect(settings.maxRecordingSeconds == 600)
        #expect(settings.playSounds)
        #expect(settings.pasteRestoreDelayMs == 300)
        #expect(settings.hotkey == "ctrl+alt+space")
        #expect(settings.keepHistory)
    }

    @Test func writesPersist() {
        let settings = freshSettings(suite: "dev.martin.murmur.tests.writes")
        settings.formatText = false
        settings.language = "da"
        settings.sttModel = "whisper-1"
        #expect(!settings.formatText)
        #expect(settings.language == "da")
        #expect(settings.sttModel == "whisper-1")
        UserDefaults(suiteName: "dev.martin.murmur.tests.writes")?
            .removePersistentDomain(forName: "dev.martin.murmur.tests.writes")
    }

    // Deliberately NO test that calls settings.apiKey: it reads the user's real
    // Keychain item, and the test binary's ad-hoc signature differs from the
    // app's, so macOS blocks the suite on a GUI password prompt.
}
