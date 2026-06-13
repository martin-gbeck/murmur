import AppKit
import ApplicationServices
import Foundation

/// Puts text on the clipboard and synthesizes Cmd+V into the focused app,
/// then restores the previous clipboard string after a short delay.
final class Paster {
    enum PasteResult {
        case pasted             // keystroke sent, clipboard string will be restored
        case pastedNoRestore    // keystroke sent, prior clipboard was non-string content
        case noAccessibility    // keystroke NOT sent; text stays on the clipboard
    }

    /// Left/right modifier virtual keycodes, used to wait for the user to
    /// physically release the hotkey chord before posting Cmd+V. If ctrl+option
    /// are still down, the system merges them into the synthetic event and the
    /// focused app receives Cmd+Ctrl+Option+V instead of a paste.
    private static let modifierKeyCodes: [CGKeyCode] = [
        54, 55,  // right cmd, cmd
        56, 60,  // shift, right shift
        58, 61,  // option, right option
        59, 62,  // ctrl, right ctrl
    ]

    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
    }

    func paste(_ text: String) -> PasteResult {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        let hadContent = !(pasteboard.pasteboardItems ?? []).isEmpty
        // Restoring rich/file content is out of scope; only a plain string comes back.
        let canRestore = savedString != nil || !hadContent

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let trusted = AXIsProcessTrusted()
        NSLog("Murmur paste: AXIsProcessTrusted=%d textLength=%d", trusted ? 1 : 0, text.count)
        if trusted { settings.everTrusted = true }
        guard trusted else {
            // Never restore here — the text must stay on the clipboard.
            return .noAccessibility
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)  // 9 = 'v'
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        // Exactly Cmd and nothing else — overwrite, never merge.
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        NSLog("Murmur paste: posting Cmd+V (events created: down=%d up=%d)",
              keyDown != nil ? 1 : 0, keyUp != nil ? 1 : 0)
        // Session tap: injected after low-level HID processing, so the live
        // hardware modifier state cannot contaminate the event.
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)

        guard canRestore else { return .pastedNoRestore }

        if let saved = savedString {
            let delay = Double(settings.pasteRestoreDelayMs) / 1000
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }
        return .pasted
    }

    /// Wait (without blocking the main actor) until every physical modifier
    /// key is up — call before `paste(_:)`. The common case returns
    /// immediately: transcription took long enough for the user to let go of
    /// the hotkey chord. Worst case is the timeout.
    func waitForModifiersReleased(timeout: TimeInterval = 1.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let anyDown = Self.modifierKeyCodes.contains {
                CGEventSource.keyState(.combinedSessionState, key: $0)
            }
            if !anyDown { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        NSLog("Murmur paste: modifier keys still down after %.1fs — posting anyway", timeout)
    }
}
