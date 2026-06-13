import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon RegisterEventHotKey. The decisive reason this app
/// needs no Input Monitoring permission and no event tap: the system delivers
/// the hotkey directly and the keystroke never reaches the focused app.
///
/// Esc is registered as a second hot key only while recording, and unregistered
/// the moment recording ends — a leaked Esc registration makes Esc dead
/// system-wide, the single worst failure mode in the app.
final class HotkeyManager {
    struct HotkeySpec: Equatable {
        let keyCode: UInt32
        let carbonModifiers: UInt32
    }

    enum ParseError: LocalizedError {
        case emptyChord
        case unknownToken(String)
        case noKey
        case multipleKeys

        var errorDescription: String? {
            switch self {
            case .emptyChord: return "Hotkey string is empty"
            case .unknownToken(let t): return "Unknown key or modifier: \"\(t)\""
            case .noKey: return "Hotkey has modifiers but no key"
            case .multipleKeys: return "Hotkey has more than one non-modifier key"
            }
        }
    }

    var onHotkey: () -> Void = {}
    var onEscape: () -> Void = {}
    var onFormatToggle: () -> Void = {}

    private var mainHotKeyRef: EventHotKeyRef?
    private var escHotKeyRef: EventHotKeyRef?
    private var formatHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private static let mainHotkeyID: UInt32 = 1
    private static let escHotkeyID: UInt32 = 2
    private static let formatHotkeyID: UInt32 = 3
    private static let signature: OSType = {
        var result: OSType = 0
        for byte in "MRMR".utf8 { result = (result << 8) + OSType(byte) }
        return result
    }()

    // MARK: - Parsing

    static let modifierMap: [String: UInt32] = [
        "ctrl": UInt32(controlKey), "control": UInt32(controlKey),
        "alt": UInt32(optionKey), "option": UInt32(optionKey), "opt": UInt32(optionKey),
        "cmd": UInt32(cmdKey), "command": UInt32(cmdKey),
        "shift": UInt32(shiftKey),
    ]

    static let keyMap: [String: UInt32] = {
        var map: [String: UInt32] = [
            "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
            "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
            "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
            "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
            "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
            "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
            "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
            "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
            "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
            "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
            "9": UInt32(kVK_ANSI_9),
            "space": UInt32(kVK_Space),
        ]
        let fKeys: [UInt32] = [
            UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
            UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
            UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
            UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
            UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19),
        ]
        for (index, code) in fKeys.enumerated() { map["f\(index + 1)"] = code }
        return map
    }()

    /// "ctrl+alt+space" → Carbon modifier mask + virtual keycode.
    static func parse(_ chord: String) throws -> HotkeySpec {
        let tokens = chord.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !tokens.isEmpty else { throw ParseError.emptyChord }

        var modifiers: UInt32 = 0
        var keyCode: UInt32?
        for token in tokens {
            if let modifier = modifierMap[token] {
                modifiers |= modifier
            } else if let code = keyMap[token] {
                guard keyCode == nil else { throw ParseError.multipleKeys }
                keyCode = code
            } else {
                throw ParseError.unknownToken(token)
            }
        }
        guard let key = keyCode else { throw ParseError.noKey }
        return HotkeySpec(keyCode: key, carbonModifiers: modifiers)
    }

    // MARK: - Display

    /// Reverse lookup for chord capture: virtual keycode → canonical key name.
    private static let keyNames: [UInt32: String] = {
        var reversed: [UInt32: String] = [:]
        for (name, code) in keyMap { reversed[code] = name }
        return reversed
    }()

    static func keyName(forKeyCode code: UInt32) -> String? {
        keyNames[code]
    }

    /// "ctrl+alt+space" → "⌃⌥Space" for menu display. Unparseable chords are
    /// shown as-is rather than crashing the menu.
    static func displayString(_ chord: String) -> String {
        let tokens = chord.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var hasCtrl = false, hasAlt = false, hasShift = false, hasCmd = false
        var key = ""
        for token in tokens {
            switch token {
            case "ctrl", "control": hasCtrl = true
            case "alt", "option", "opt": hasAlt = true
            case "shift": hasShift = true
            case "cmd", "command": hasCmd = true
            default: key = token
            }
        }
        guard !key.isEmpty else { return chord }
        // Canonical macOS modifier order: ⌃⌥⇧⌘, regardless of input order.
        var symbols = ""
        if hasCtrl { symbols += "⌃" }
        if hasAlt { symbols += "⌥" }
        if hasShift { symbols += "⇧" }
        if hasCmd { symbols += "⌘" }
        let keyLabel = key == "space" ? "Space" : key.uppercased()
        return symbols + keyLabel
    }

    // MARK: - Registration

    /// (Re-)register the main dictation hotkey and the optional format-toggle
    /// hotkey, replacing whatever was registered before. Esc is independent.
    func applyChords(main: String, formatToggle: String?) throws {
        installHandlerIfNeeded()
        pauseChords()

        let spec = try Self.parse(main)
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.mainHotkeyID)
        let status = RegisterEventHotKey(
            spec.keyCode, spec.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &mainHotKeyRef
        )
        guard status == noErr else {
            throw APIError("Could not register hotkey \"\(main)\" (error \(status)) — is it taken by another app?")
        }

        if let formatToggle, !formatToggle.isEmpty {
            let formatSpec = try Self.parse(formatToggle)
            let formatID = EventHotKeyID(signature: Self.signature, id: Self.formatHotkeyID)
            let formatStatus = RegisterEventHotKey(
                formatSpec.keyCode, formatSpec.carbonModifiers, formatID,
                GetApplicationEventTarget(), 0, &formatHotKeyRef
            )
            guard formatStatus == noErr else {
                throw APIError("Could not register format-toggle hotkey \"\(formatToggle)\" (error \(formatStatus))")
            }
        }
    }

    /// Unregister main + format-toggle (used while the capture panel is open,
    /// so the user can re-assign the same chord). Esc is untouched.
    func pauseChords() {
        if let ref = mainHotKeyRef {
            UnregisterEventHotKey(ref)
            mainHotKeyRef = nil
        }
        if let ref = formatHotKeyRef {
            UnregisterEventHotKey(ref)
            formatHotKeyRef = nil
        }
    }

    /// Register Esc (no modifiers) only while recording.
    func registerEscape() {
        guard escHotKeyRef == nil else { return }
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.escHotkeyID)
        RegisterEventHotKey(
            UInt32(kVK_Escape), 0, hotKeyID,
            GetApplicationEventTarget(), 0, &escHotKeyRef
        )
    }

    func unregisterEscape() {
        guard let ref = escHotKeyRef else { return }
        UnregisterEventHotKey(ref)
        escHotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handle(id: hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }

    // Carbon event handlers arrive on the main thread.
    private func handle(id: UInt32) {
        switch id {
        case Self.mainHotkeyID: onHotkey()
        case Self.escHotkeyID: onEscape()
        case Self.formatHotkeyID: onFormatToggle()
        default: break
        }
    }
}
