import Foundation
import UserNotifications

/// Notifications are the app's only error-reporting channel — every failure
/// path in the pipeline ends in exactly one notification.
final class Notifier {
    // UNUserNotificationCenter crashes in unbundled processes (swift run / --cli),
    // so fall back to stderr there.
    private let bundled = Bundle.main.bundleIdentifier != nil
    private var authorizationRequested = false

    func notify(_ title: String, body: String = "") {
        guard bundled else {
            fputs("[Murmur] \(title)\(body.isEmpty ? "" : " — \(body)")\n", stderr)
            return
        }
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            if !body.isEmpty { content.body = body }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
        if authorizationRequested {
            deliver()
        } else {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in deliver() }
        }
    }
}
