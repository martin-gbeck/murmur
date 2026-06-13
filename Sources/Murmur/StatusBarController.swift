import AppKit
import ServiceManagement

/// Everything the menu needs to read or trigger. AppDelegate implements this.
@MainActor
protocol MenuHandler: AnyObject {
    var statusLineText: String { get }
    var canRetry: Bool { get }
    var hasLastTranscript: Bool { get }
    var historyForMenu: [History.Entry] { get }

    func toggleFormat()
    func selectLanguage(_ code: String)
    func retryLast()
    func copyLastTranscript()
    func copyHistoryEntry(_ text: String)
    func clearHistory()
    func setAPIKey()
    func togglePlaySounds()
    func toggleRecordingIndicator()
    func toggleLaunchAtLogin()
    func changeHotkey()
    func changeFormatToggleHotkey()
    func fixPermission(_ permission: Permission)
}

/// NSStatusItem + menu. The menu is the entire UI — no settings window, no Dock icon.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    static let languages: [(name: String, code: String)] = [
        ("Auto", "auto"), ("English", "en"), ("Spanish", "es"), ("German", "de"),
        ("French", "fr"), ("Danish", "da"), ("Italian", "it"), ("Portuguese", "pt"),
        ("Dutch", "nl"), ("Japanese", "ja"), ("Chinese", "zh"),
    ]

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let settings: Settings
    private weak var handler: MenuHandler?
    private var statusLineItem: NSMenuItem?

    /// SMAppService only works from a bundle; disable the toggle for dev runs.
    static var runningFromBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    init(settings: Settings, handler: MenuHandler) {
        self.settings = settings
        self.handler = handler
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        setIdle()
    }

    // MARK: - Icon states

    func setIdle() {
        setSymbol("mic", template: true, description: "Murmur idle")
    }

    func setRecording() {
        setSymbol("mic.fill", template: false, tint: .systemRed, description: "Murmur recording")
    }

    func setProcessing() {
        setSymbol("ellipsis.circle", template: true, description: "Murmur processing")
    }

    private func setSymbol(_ name: String, template: Bool, tint: NSColor? = nil, description: String) {
        guard let button = statusItem.button else { return }
        var image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        if let tint {
            image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
        }
        image?.isTemplate = template
        button.image = image
    }

    /// Live "Recording… M:SS" updates while the menu is open.
    func updateStatusLine(_ text: String) {
        statusLineItem?.title = text
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        guard let handler else { return }
        menu.removeAllItems()

        let status = NSMenuItem(title: handler.statusLineText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusLineItem = status

        let format = item("Format text", #selector(toggleFormat))
        format.state = settings.formatText ? .on : .off
        menu.addItem(format)

        let languageRoot = item("Language", nil)
        let languageMenu = NSMenu()
        for (name, code) in Self.languages {
            let entry = item(name, #selector(selectLanguage(_:)))
            entry.representedObject = code
            entry.state = settings.language == code ? .on : .off
            languageMenu.addItem(entry)
        }
        languageRoot.submenu = languageMenu
        menu.addItem(languageRoot)

        menu.addItem(.separator())

        let retry = item("Retry last recording", #selector(retryLast))
        retry.isEnabled = handler.canRetry
        menu.addItem(retry)

        let copyLast = item("Copy last transcript", #selector(copyLastTranscript))
        copyLast.isEnabled = handler.hasLastTranscript
        menu.addItem(copyLast)

        let historyRoot = item("History", nil)
        let historyMenu = NSMenu()
        let entries = handler.historyForMenu
        if entries.isEmpty {
            let empty = item("No transcripts yet", nil)
            empty.isEnabled = false
            historyMenu.addItem(empty)
        } else {
            for entry in entries.reversed() {
                let text = entry.formatted ?? entry.raw
                let title = text.count > 60 ? String(text.prefix(60)) + "…" : text
                let menuItem = item(title, #selector(copyHistoryEntry(_:)))
                menuItem.representedObject = text
                historyMenu.addItem(menuItem)
            }
            historyMenu.addItem(.separator())
            historyMenu.addItem(item("Clear history", #selector(clearHistory)))
        }
        historyRoot.submenu = historyMenu
        menu.addItem(historyRoot)

        menu.addItem(.separator())

        menu.addItem(item("Set API key…", #selector(setAPIKey)))

        let hotkeyTitle = "Change dictation hotkey…  (\(HotkeyManager.displayString(settings.hotkey)))"
        menu.addItem(item(hotkeyTitle, #selector(changeHotkey)))

        let formatChord = settings.formatToggleHotkey
        let formatTitle = formatChord.isEmpty
            ? "Format-toggle hotkey…  (none)"
            : "Format-toggle hotkey…  (\(HotkeyManager.displayString(formatChord)))"
        menu.addItem(item(formatTitle, #selector(changeFormatToggleHotkey)))

        let soundsItem = item("Play sounds", #selector(togglePlaySounds))
        soundsItem.state = settings.playSounds ? .on : .off
        menu.addItem(soundsItem)

        let indicatorItem = item("Show recording indicator", #selector(toggleRecordingIndicator))
        indicatorItem.state = settings.showRecordingIndicator ? .on : .off
        menu.addItem(indicatorItem)

        let launch = item("Launch at login", #selector(toggleLaunchAtLogin))
        if Self.runningFromBundle {
            launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            launch.isEnabled = false
            launch.toolTip = "Only available from the packaged Murmur.app"
        }
        menu.addItem(launch)

        let missing = Permissions.missing()
        if !missing.isEmpty {
            for permission in missing {
                let fix = item("Fix permissions… (\(permission.rawValue))", #selector(fixPermission(_:)))
                fix.representedObject = permission.rawValue
                menu.addItem(fix)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector?) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    // MARK: - Actions (forwarded to the handler)

    @objc private func toggleFormat() { handler?.toggleFormat() }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        handler?.selectLanguage(code)
    }

    @objc private func retryLast() { handler?.retryLast() }
    @objc private func copyLastTranscript() { handler?.copyLastTranscript() }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        handler?.copyHistoryEntry(text)
    }

    @objc private func clearHistory() { handler?.clearHistory() }
    @objc private func setAPIKey() { handler?.setAPIKey() }
    @objc private func togglePlaySounds() { handler?.togglePlaySounds() }
    @objc private func toggleRecordingIndicator() { handler?.toggleRecordingIndicator() }
    @objc private func changeHotkey() { handler?.changeHotkey() }
    @objc private func changeFormatToggleHotkey() { handler?.changeFormatToggleHotkey() }
    @objc private func toggleLaunchAtLogin() { handler?.toggleLaunchAtLogin() }

    @objc private func fixPermission(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let permission = Permission.allCases.first(where: { $0.rawValue == raw })
        else { return }
        handler?.fixPermission(permission)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
