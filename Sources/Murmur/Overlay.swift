import AppKit

/// Small floating pill near the bottom of the screen.
///
/// Critically non-intrusive: a borderless non-activating panel that ignores
/// the mouse and never becomes key, so focus stays in the text field the user
/// is dictating into. Joins all Spaces and full-screen apps.
@MainActor
final class OverlayPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var hideTimer: Timer?

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor

        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        panel.contentView = effect
    }

    /// Show (or restyle) the pill. `dotColor: nil` hides the dot;
    /// `pulse` adds a slow opacity blink (used while recording).
    func show(text: String, dotColor: NSColor? = nil, pulse: Bool = false) {
        hideTimer?.invalidate()
        hideTimer = nil
        label.stringValue = text
        dot.isHidden = dotColor == nil
        dot.layer?.backgroundColor = dotColor?.cgColor
        dot.layer?.removeAllAnimations()
        if pulse {
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1.0
            blink.toValue = 0.25
            blink.duration = 0.8
            blink.autoreverses = true
            blink.repeatCount = .infinity
            dot.layer?.add(blink, forKey: "pulse")
        }
        layoutAtBottomCenter()
        panel.orderFrontRegardless()
    }

    /// Update the text without re-showing (e.g. the elapsed-time counter).
    func update(text: String) {
        guard panel.isVisible else { return }
        label.stringValue = text
        layoutAtBottomCenter()
    }

    /// Show for a few seconds, then hide (the "⌘V to paste" hint).
    func showTransient(text: String, dotColor: NSColor? = nil, seconds: TimeInterval = 4) {
        show(text: text, dotColor: dotColor)
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        dot.layer?.removeAllAnimations()
        panel.orderOut(nil)
    }

    private func layoutAtBottomCenter() {
        guard let contentView = panel.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let size = contentView.fittingSize
        let screen = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.minY + 64
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
