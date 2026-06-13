import AppKit
import Carbon.HIToolbox

/// Small modal-ish panel that captures the next key chord pressed.
///
/// Used by "Change dictation hotkey…" and "Format-toggle hotkey…". The caller
/// pauses global hotkey registrations first so the chord being replaced can be
/// re-assigned. Esc (bare) cancels; chords need at least one modifier, except
/// function keys which may stand alone.
@MainActor
final class HotkeyCapturePanel {
    enum Outcome {
        case chord(String)
        case cleared
        case cancelled
    }

    private var panel: NSPanel?
    private var monitor: Any?
    private var completion: ((Outcome) -> Void)?

    var isActive: Bool { panel != nil }

    func begin(prompt: String, allowClear: Bool, completion: @escaping (Outcome) -> Void) {
        guard panel == nil else {
            completion(.cancelled)
            return
        }
        self.completion = completion

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Murmur"
        panel.level = .floating
        panel.isReleasedWhenClosed = false

        let promptLabel = NSTextField(labelWithString: prompt)
        promptLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let hintLabel = NSTextField(labelWithString: "Press the new shortcut now. Esc cancels.")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        var buttons: [NSView] = [cancelButton]
        if allowClear {
            buttons.insert(NSButton(title: "Remove shortcut", target: self, action: #selector(clearTapped)), at: 0)
        }
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [promptLabel, hintLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        panel.center()

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil  // swallow the keystroke
        }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])

        if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            finish(.cancelled)
            return
        }
        guard let keyName = HotkeyManager.keyName(forKeyCode: UInt32(event.keyCode)) else {
            NSSound.beep()
            return
        }
        let isFunctionKey = keyName.first == "f" && keyName.count > 1
        guard !modifiers.isEmpty || isFunctionKey else {
            NSSound.beep()
            return
        }

        var tokens: [String] = []
        if modifiers.contains(.control) { tokens.append("ctrl") }
        if modifiers.contains(.option) { tokens.append("alt") }
        if modifiers.contains(.shift) { tokens.append("shift") }
        if modifiers.contains(.command) { tokens.append("cmd") }
        tokens.append(keyName)
        finish(.chord(tokens.joined(separator: "+")))
    }

    @objc private func cancelTapped() {
        finish(.cancelled)
    }

    @objc private func clearTapped() {
        finish(.cleared)
    }

    private func finish(_ outcome: Outcome) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        let callback = completion
        completion = nil
        callback?(outcome)
    }
}
