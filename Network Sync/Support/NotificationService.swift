import Foundation
import UserNotifications

struct NotificationService {

    // Call once at app launch
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // Fired when a pipeline run finishes
    static func sendCompletion(converted: Int, errors: Int) {
        let content = UNMutableNotificationContent()
        content.title = errors == 0
            ? "✅ Sync & Transcode Complete"
            : "⚠️ Sync Complete with Errors"
        content.body = errors == 0
            ? "\(converted) file\(converted == 1 ? "" : "s") converted successfully."
            : "\(converted) converted · \(errors) error\(errors == 1 ? "" : "s") — check the log."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "run-complete-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Fired by AlertingService when a device that's actively recording (or
    // mid-workflow) drops offline, loses auth, runs out of media, or is
    // about to run out of storage. Marked time-sensitive so it stands a
    // better chance of cutting through Focus modes during a live service —
    // this is the one notification in the app where that matters.
    static func sendDeviceAlert(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "device-alert-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Fired when a scheduled run is about to start (one-minute warning)
    static func sendScheduledWarning(at date: Date) {
        let content = UNMutableNotificationContent()
        content.title  = "Network Sync Starting Soon"
        content.body   = "Scheduled sync will begin in 1 minute."
        content.sound  = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.hour, .minute], from: date),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "scheduled-warning",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Cancel any pending scheduled warning
    static func cancelScheduledWarning() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["scheduled-warning"])
    }
}
