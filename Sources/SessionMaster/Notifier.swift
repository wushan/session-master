import AppKit
import UserNotifications

/// Sound + Notification Center alerts when a session starts needing the user.
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func fire(title: String, body: String, soundName: String, withSound: Bool) {
        if withSound { NSSound(named: soundName)?.play() }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if withSound { content.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
