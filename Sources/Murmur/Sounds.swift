import AppKit

/// System sound cues, no bundled audio. Fire-and-forget.
final class Sounds {
    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
    }

    func playStart() { play("Pop") }
    func playStop() { play("Morse") }
    func playCancel() { play("Basso") }
    func playError() { play("Basso") }

    private func play(_ name: String) {
        guard settings.playSounds else { return }
        NSSound(named: name)?.play()
    }
}
