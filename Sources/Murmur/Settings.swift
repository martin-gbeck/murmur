import Foundation
import Security

/// Typed wrapper over UserDefaults plus the Keychain-backed API key.
/// All keys are registered with defaults at init so reads never need fallbacks.
final class Settings {
    enum Keys {
        static let formatText = "formatText"
        static let sttModel = "sttModel"
        static let formatModel = "formatModel"
        static let language = "language"
        static let maxRecordingSeconds = "maxRecordingSeconds"
        static let playSounds = "playSounds"
        static let pasteRestoreDelayMs = "pasteRestoreDelayMs"
        static let hotkey = "hotkey"
        static let formatToggleHotkey = "formatToggleHotkey"
        static let keepHistory = "keepHistory"
        static let everTrusted = "everTrusted"
        static let incrementalTranscription = "incrementalTranscription"
        static let showRecordingIndicator = "showRecordingIndicator"
        static let silenceMarginDb = "silenceMarginDb"
        static let silenceMinSeconds = "silenceMinSeconds"
        static let chunkMinSeconds = "chunkMinSeconds"
    }

    static let registrationDefaults: [String: Any] = [
        Keys.formatText: true,
        Keys.sttModel: "gpt-4o-mini-transcribe",
        Keys.formatModel: "gpt-4o-mini",
        Keys.language: "auto",
        Keys.maxRecordingSeconds: 600,
        Keys.playSounds: true,
        Keys.pasteRestoreDelayMs: 300,
        Keys.hotkey: "ctrl+alt+space",
        Keys.formatToggleHotkey: "",
        Keys.keepHistory: true,
        Keys.incrementalTranscription: true,
        Keys.showRecordingIndicator: true,
        Keys.silenceMarginDb: 8.0,
        Keys.silenceMinSeconds: 0.7,
        Keys.chunkMinSeconds: 45.0,
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.registrationDefaults)
    }

    var formatText: Bool {
        get { defaults.bool(forKey: Keys.formatText) }
        set { defaults.set(newValue, forKey: Keys.formatText) }
    }

    var sttModel: String {
        get { defaults.string(forKey: Keys.sttModel) ?? "gpt-4o-mini-transcribe" }
        set { defaults.set(newValue, forKey: Keys.sttModel) }
    }

    var formatModel: String {
        get { defaults.string(forKey: Keys.formatModel) ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: Keys.formatModel) }
    }

    /// "auto" or an ISO 639-1 code ("en", "da", ...).
    var language: String {
        get { defaults.string(forKey: Keys.language) ?? "auto" }
        set { defaults.set(newValue, forKey: Keys.language) }
    }

    var maxRecordingSeconds: Int {
        get { defaults.integer(forKey: Keys.maxRecordingSeconds) }
        set { defaults.set(newValue, forKey: Keys.maxRecordingSeconds) }
    }

    var playSounds: Bool {
        get { defaults.bool(forKey: Keys.playSounds) }
        set { defaults.set(newValue, forKey: Keys.playSounds) }
    }

    var pasteRestoreDelayMs: Int {
        get { defaults.integer(forKey: Keys.pasteRestoreDelayMs) }
        set { defaults.set(newValue, forKey: Keys.pasteRestoreDelayMs) }
    }

    var hotkey: String {
        get { defaults.string(forKey: Keys.hotkey) ?? "ctrl+alt+space" }
        set { defaults.set(newValue, forKey: Keys.hotkey) }
    }

    /// Optional second global hotkey toggling "Format text". Empty = off.
    var formatToggleHotkey: String {
        get { defaults.string(forKey: Keys.formatToggleHotkey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.formatToggleHotkey) }
    }

    var keepHistory: Bool {
        get { defaults.bool(forKey: Keys.keepHistory) }
        set { defaults.set(newValue, forKey: Keys.keepHistory) }
    }

    /// Set once AXIsProcessTrusted() has ever returned true. Lets the app
    /// distinguish "never granted" from "grant went stale after an update"
    /// (ad-hoc re-signing invalidates the TCC entry; it must be removed and
    /// re-added, not toggled).
    var everTrusted: Bool {
        get { defaults.bool(forKey: Keys.everTrusted) }
        set { defaults.set(newValue, forKey: Keys.everTrusted) }
    }

    /// Transcribe chunks at speech pauses during recording, so only the tail
    /// remains when the user stops. Falls back to whole-file transcription on
    /// any chunk failure.
    var incrementalTranscription: Bool {
        get { defaults.bool(forKey: Keys.incrementalTranscription) }
        set { defaults.set(newValue, forKey: Keys.incrementalTranscription) }
    }

    /// Floating on-screen pill while recording/transcribing.
    var showRecordingIndicator: Bool {
        get { defaults.bool(forKey: Keys.showRecordingIndicator) }
        set { defaults.set(newValue, forKey: Keys.showRecordingIndicator) }
    }

    /// Hidden tuning knobs for the silence detector (`defaults write`).
    /// How far above the tracked noise floor (in dB) still counts as silence.
    /// Larger = more tolerant of background noise; whispering needs this small.
    var silenceMarginDb: Double {
        get { defaults.double(forKey: Keys.silenceMarginDb) }
        set { defaults.set(newValue, forKey: Keys.silenceMarginDb) }
    }

    var silenceMinSeconds: Double {
        get { defaults.double(forKey: Keys.silenceMinSeconds) }
        set { defaults.set(newValue, forKey: Keys.silenceMinSeconds) }
    }

    var chunkMinSeconds: Double {
        get { defaults.double(forKey: Keys.chunkMinSeconds) }
        set { defaults.set(newValue, forKey: Keys.chunkMinSeconds) }
    }

    // MARK: - API key

    /// MURMUR_OPENAI_API_KEY env var overrides the Keychain (dev/CI use); Keychain is the real store.
    var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["MURMUR_OPENAI_API_KEY"],
           !env.isEmpty {
            return env
        }
        return Keychain.load()
    }

    @discardableResult
    func saveAPIKey(_ key: String) -> Bool {
        Keychain.save(key)
    }
}

/// API key storage. Keychain only — never UserDefaults, never a file.
enum Keychain {
    static let service = "dev.martin.murmur"
    static let account = "openai_api_key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess
        }
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
