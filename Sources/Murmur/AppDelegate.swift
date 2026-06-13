import AppKit
import Foundation
import ServiceManagement

/// Wires everything together and owns all state. Everything runs on the main
/// actor; the pipeline is the only async work and there is exactly one pipeline
/// Task at a time — guaranteed by the state machine ignoring hotkeys during
/// .processing.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MenuHandler {
    private let settings = Settings()
    private let notifier = Notifier()
    private let recorder = Recorder()
    private let hotkeys = HotkeyManager()
    private var client: OpenAIClient!
    private var formatter: TranscriptFormatter!
    private var paster: Paster!
    private var sounds: Sounds!
    private var history: History!
    private var statusBar: StatusBarController!

    private var state: State = .idle
    private var recordingTimer: Timer?
    private var lastFailedRecording: URL?
    private var lastTranscript: String?
    private var notifiedNonStringClipboard = false

    // Incremental transcription: one in-flight Task per chunk, keyed by the
    // chunk's file URL. The recorder hands back the authoritative spoken order
    // at stop; assembly indexes into this map, so a chunk started early during
    // recording and the tail started at stop both join in the right place.
    private var chunkedRecorder: ChunkedRecorder?
    private var chunkTasks: [URL: Task<String, Error>] = [:]

    // On-screen pills: a persistent one for recording/processing state and a
    // transient one for the "⌘V to paste" hint.
    private lazy var indicator = OverlayPanel()
    private lazy var pasteHint = OverlayPanel()

    private let hotkeyCapture = HotkeyCapturePanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        client = OpenAIClient(settings: settings)
        formatter = TranscriptFormatter(client: client, settings: settings)
        paster = Paster(settings: settings)
        sounds = Sounds(settings: settings)
        history = History(settings: settings)
        statusBar = StatusBarController(settings: settings, handler: self)

        hotkeys.onHotkey = { [weak self] in
            MainActor.assumeIsolated { self?.dispatch(.hotkey) }
        }
        hotkeys.onEscape = { [weak self] in
            MainActor.assumeIsolated { self?.dispatch(.escape) }
        }
        hotkeys.onFormatToggle = { [weak self] in
            MainActor.assumeIsolated { self?.formatToggleHotkeyPressed() }
        }
        applyHotkeys()

        if settings.apiKey == nil {
            runFirstLaunchOnboarding()
        }

        checkForStaleAccessibilityGrant()
    }

    /// Ad-hoc re-signing invalidates the Accessibility TCC entry on every
    /// rebuild. System Settings still shows Murmur as enabled, but the check
    /// fails — the entry must be removed (−) and the app re-added. Detect the
    /// situation and say so, instead of failing silently at paste time.
    private func checkForStaleAccessibilityGrant() {
        if Permissions.accessibilityGranted() {
            settings.everTrusted = true
        } else if settings.everTrusted {
            notifier.notify(
                "Accessibility grant went stale",
                body: "Murmur was updated. In System Settings → Privacy & Security → Accessibility, remove Murmur (−), re-add it, then relaunch."
            )
        }
    }

    /// Register (or re-register) both global hotkeys from settings.
    private func applyHotkeys() {
        do {
            try hotkeys.applyChords(
                main: settings.hotkey,
                formatToggle: settings.formatToggleHotkey.isEmpty ? nil : settings.formatToggleHotkey
            )
        } catch {
            notifier.notify("Hotkey registration failed", body: error.shortMessage)
        }
    }

    /// Global format-toggle hotkey: flip the setting and flash the new state.
    private func formatToggleHotkeyPressed() {
        settings.formatText.toggle()
        pasteHint.showTransient(
            text: settings.formatText ? "Format text: ON" : "Format text: OFF",
            seconds: 1.5
        )
    }

    /// Cmd+V/C/X/A are routed through the main menu, which a menu-bar-only app
    /// doesn't have — without this, paste is dead in the API-key dialog.
    /// The menu is never visible; it exists only to route key equivalents.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = edit
        NSApp.mainMenu = mainMenu
    }

    // MARK: - State machine

    private func dispatch(_ event: Event) {
        let (newState, action) = transition(state, event)
        state = newState

        switch action {
        case .startRecording: startRecording()
        case .stopAndProcess: stopAndProcess()
        case .cancelRecording: cancelRecording()
        case .none: break
        }

        // Belt and suspenders: whatever path led back to idle, Esc must be free
        // again — a leaked Esc registration is the worst failure mode in the app.
        if state == .idle {
            hotkeys.unregisterEscape()
            statusBar.setIdle()
            indicator.hide()
        }
    }

    private func startRecording() {
        lastFailedRecording = nil
        chunkTasks = [:]
        chunkedRecorder = nil

        if settings.incrementalTranscription {
            let chunked = ChunkedRecorder(settings: settings)
            chunked.onChunk = { [weak self] url in
                self?.transcribeChunk(url)
            }
            do {
                try chunked.start()
                chunkedRecorder = chunked
            } catch {
                NSLog("Murmur: chunked recorder failed to start (%@) — falling back to plain recording",
                      error.shortMessage)
            }
        }
        if chunkedRecorder == nil {
            do {
                try recorder.start()
            } catch {
                state = .idle
                sounds.playError()
                notifier.notify("Recording failed", body: error.shortMessage)
                return
            }
        }
        // Cue only after record() succeeded, so the user never speaks into a dead mic.
        sounds.playStart()
        hotkeys.registerEscape()
        statusBar.setRecording()
        if settings.showRecordingIndicator {
            indicator.show(text: "Recording 0:00", dotColor: .systemRed, pulse: true)
        }

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordingTick() }
        }
    }

    private func recordingTick() {
        let elapsed = Int(chunkedRecorder?.elapsedSeconds ?? recorder.elapsedSeconds)
        let stamp = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        statusBar.updateStatusLine("Recording… \(stamp)")
        indicator.update(text: "Recording \(stamp)")
        if elapsed >= settings.maxRecordingSeconds {
            dispatch(.recordingCap)
        }
    }

    private func stopAndProcess() {
        stopRecordingTimer()
        hotkeys.unregisterEscape()
        sounds.playStop()
        statusBar.setProcessing()
        if settings.showRecordingIndicator {
            indicator.show(text: "Transcribing…", dotColor: .systemOrange)
        }

        if let chunked = chunkedRecorder {
            chunkedRecorder = nil
            guard let result = chunked.stop() else {
                notifier.notify("Recording failed", body: "No audio file was produced")
                dispatch(.done)
                return
            }
            // Start any chunk not already in flight (the tail, plus any cut that
            // raced the stop and never got its onChunk callback).
            for url in result.orderedChunks where chunkTasks[url] == nil {
                transcribeChunk(url)
            }
            Task { await runChunkedPipeline(order: result.orderedChunks, master: result.master) }
            return
        }

        guard let audio = recorder.stop() else {
            notifier.notify("Recording failed", body: "No audio file was produced")
            dispatch(.done)
            return
        }
        Task { await runPipeline(audio: audio) }
    }

    private func cancelRecording() {
        stopRecordingTimer()
        hotkeys.unregisterEscape()
        if let chunked = chunkedRecorder {
            chunkedRecorder = nil
            chunked.cancel()
        } else {
            recorder.cancel()
        }
        for task in chunkTasks.values { task.cancel() }
        chunkTasks = [:]
        sounds.playCancel()
    }

    /// Kick off transcription of one chunk while recording continues.
    private func transcribeChunk(_ url: URL) {
        guard chunkTasks[url] == nil else { return }
        let client = self.client!
        chunkTasks[url] = Task { try await client.transcribe(url) }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - Pipeline

    /// Whole-file path (incremental transcription off, or its fallback).
    private func runPipeline(audio: URL) async {
        defer { dispatch(.done) }
        do {
            let raw = try await client.transcribe(audio)
            await deliver(raw: raw, audio: audio)
        } catch {
            failTranscription(audio: audio, error: error)
        }
    }

    /// Incremental path: await each chunk in the recorder's authoritative spoken
    /// order and join. Any chunk failure (or a missing task) falls back to
    /// transcribing the master file whole — never worse than the
    /// non-incremental path, and the master always holds the full recording.
    private func runChunkedPipeline(order: [URL], master: URL) async {
        defer { dispatch(.done) }
        let tasks = chunkTasks
        chunkTasks = [:]

        var parts: [String] = []
        var chunkError: Error?
        for url in order {
            guard let task = tasks[url] else {
                chunkError = APIError("missing chunk task for \(url.lastPathComponent)")
                break
            }
            do {
                parts.append(try await task.value)
            } catch {
                chunkError = error
                break
            }
        }

        if let chunkError {
            NSLog("Murmur pipeline: chunk assembly failed (%@) — falling back to whole file",
                  chunkError.shortMessage)
            for task in tasks.values { task.cancel() }
            do {
                let raw = try await client.transcribe(master)
                await deliver(raw: raw, audio: master)
            } catch {
                failTranscription(audio: master, error: error)
            }
            return
        }

        let raw = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        NSLog("Murmur pipeline: %d chunks joined (%d chars)", parts.count, raw.count)
        await deliver(raw: raw, audio: master)
    }

    /// Shared tail of both pipelines: empty check, formatting, history, paste.
    private func deliver(raw: String, audio: URL) async {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notifier.notify("No speech detected")
            return
        }
        let final = settings.formatText ? await formatter.format(raw) : raw
        lastTranscript = final
        history.append(raw: raw, formatted: settings.formatText ? final : nil)

        NSLog("Murmur pipeline: transcript ready (%d chars), attempting paste", final.count)
        await paster.waitForModifiersReleased()
        switch paster.paste(final) {
        case .pasted:
            break
        case .pastedNoRestore:
            if !notifiedNonStringClipboard {
                notifiedNonStringClipboard = true
                notifier.notify("Pasted", body: "Previous clipboard had non-text content, so it was not restored")
            }
        case .noAccessibility:
            pasteHint.showTransient(text: "⌘V to insert text — transcript is on your clipboard", seconds: 5)
            if settings.everTrusted {
                notifier.notify(
                    "Couldn't paste — transcript is on your clipboard",
                    body: "The Accessibility grant went stale after an update: remove Murmur (−) and re-add it in System Settings → Accessibility, then relaunch."
                )
            } else {
                notifier.notify("Couldn't paste — transcript is on your clipboard")
            }
        }
    }

    private func failTranscription(audio: URL, error: Error) {
        lastFailedRecording = audio
        sounds.playError()
        notifier.notify("Transcription failed — kept the recording", body: error.shortMessage)
    }

    // MARK: - MenuHandler

    var statusLineText: String {
        switch state {
        case .idle: return "Ready"
        case .recording:
            let elapsed = Int(recorder.elapsedSeconds)
            return String(format: "Recording… %d:%02d", elapsed / 60, elapsed % 60)
        case .processing: return "Transcribing…"
        }
    }

    var canRetry: Bool { lastFailedRecording != nil && state == .idle }
    var hasLastTranscript: Bool { lastTranscript != nil }
    var historyForMenu: [History.Entry] { history.last(10) }

    func toggleFormat() {
        settings.formatText.toggle()
    }

    func selectLanguage(_ code: String) {
        settings.language = code
    }

    func retryLast() {
        // Enters .processing directly rather than via the transition table:
        // retry is a menu action, not a keyboard event, and must not be
        // reachable from the hotkey path.
        guard let audio = lastFailedRecording, state == .idle else { return }
        state = .processing
        lastFailedRecording = nil
        statusBar.setProcessing()
        Task { await runPipeline(audio: audio) }
    }

    func copyLastTranscript() {
        guard let text = lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyHistoryEntry(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clearHistory() {
        history.clear()
    }

    func setAPIKey() {
        promptForAPIKey()
    }

    func togglePlaySounds() {
        settings.playSounds.toggle()
    }

    func toggleRecordingIndicator() {
        settings.showRecordingIndicator.toggle()
        if !settings.showRecordingIndicator {
            indicator.hide()
        }
    }

    func changeHotkey() {
        guard state == .idle, !hotkeyCapture.isActive else { return }
        // Pause registrations so the current chord can be re-assigned.
        hotkeys.pauseChords()
        hotkeyCapture.begin(prompt: "Press the new dictation hotkey", allowClear: false) { [weak self] outcome in
            guard let self else { return }
            if case .chord(let chord) = outcome {
                self.settings.hotkey = chord
                self.pasteHint.showTransient(
                    text: "Dictation hotkey: \(HotkeyManager.displayString(chord))",
                    seconds: 2.5
                )
            }
            self.applyHotkeys()
        }
    }

    func changeFormatToggleHotkey() {
        guard state == .idle, !hotkeyCapture.isActive else { return }
        hotkeys.pauseChords()
        hotkeyCapture.begin(prompt: "Press the format-toggle shortcut", allowClear: true) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .chord(let chord):
                self.settings.formatToggleHotkey = chord
                self.pasteHint.showTransient(
                    text: "Format-toggle hotkey: \(HotkeyManager.displayString(chord))",
                    seconds: 2.5
                )
            case .cleared:
                self.settings.formatToggleHotkey = ""
            case .cancelled:
                break
            }
            self.applyHotkeys()
        }
    }

    func toggleLaunchAtLogin() {
        guard StatusBarController.runningFromBundle else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notifier.notify("Launch at login failed", body: error.localizedDescription)
        }
    }

    func fixPermission(_ permission: Permission) {
        Permissions.openSystemSettings(for: permission)
    }

    // MARK: - API key dialog / onboarding

    private func runFirstLaunchOnboarding() {
        let saved = promptForAPIKey(
            message: "Murmur needs your OpenAI API key to transcribe speech. It is stored in the macOS Keychain, never on disk."
        )
        if saved {
            // Trigger the Accessibility prompt right after key entry; mic is
            // requested by the OS automatically on first recording.
            Permissions.promptAccessibility()
        }
    }

    @discardableResult
    private func promptForAPIKey(message: String = "Stored in the macOS Keychain, never on disk.") -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set OpenAI API key"
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "sk-…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }

        if settings.saveAPIKey(key) {
            let confirmation = NSAlert()
            confirmation.messageText = "API key saved"
            confirmation.informativeText = "sk-…\(String(key.suffix(4))) saved to the Keychain."
            confirmation.runModal()
            return true
        }
        notifier.notify("Could not save the API key to the Keychain")
        return false
    }
}
