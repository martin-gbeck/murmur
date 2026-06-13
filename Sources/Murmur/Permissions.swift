import AVFoundation
import AppKit
import ApplicationServices

/// Only two permissions, thanks to the Carbon hotkey approach:
/// Microphone (recording) and Accessibility (CGEvent paste).
enum Permission: String, CaseIterable {
    case microphone = "Microphone"
    case accessibility = "Accessibility"
}

enum Permissions {
    static func microphoneGranted() -> Bool {
        // .notDetermined is not "missing" — the OS auto-prompts on first recording.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .authorized || status == .notDetermined
    }

    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    static func missing() -> [Permission] {
        var result: [Permission] = []
        if !microphoneGranted() { result.append(.microphone) }
        if !accessibilityGranted() { result.append(.accessibility) }
        return result
    }

    /// Shows the system Accessibility prompt (used right after first-launch key entry).
    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings(for permission: Permission) {
        let pane: String
        switch permission {
        case .microphone: pane = "Privacy_Microphone"
        case .accessibility: pane = "Privacy_Accessibility"
        }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}
