import AppKit
import UserNotifications

/// Sound + Notification Center alerts when a session starts needing the user.
enum Notifier {
    private static var supportsNotificationCenter: Bool {
        let bundlePath = Bundle.main.bundlePath
        guard !bundlePath.isEmpty else { return false }
        return bundlePath.hasSuffix(".app") || bundlePath.hasSuffix(".app/") &&
            FileManager.default.fileExists(atPath: bundlePath)
    }

    static func requestAuthorization() {
        guard supportsNotificationCenter else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func fire(title: String, body: String, soundName: String, withSound: Bool) {
        guard supportsNotificationCenter else {
            if withSound { NSSound(named: soundName)?.play() }
            return
        }
        if withSound { NSSound(named: soundName)?.play() }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if withSound { content.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
