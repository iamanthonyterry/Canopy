import Foundation

/// A single email recipient — used both by the (legacy) global settings
/// and by per-workflow Notification steps.
struct NotificationRecipient: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var email: String
}

/// Settings scoped to just the email *integration* itself (which Gmail
/// account sends the mail). Who gets notified, and with what message, is
/// now configured per-workflow via a Notification step — see
/// `StepAction.notify` in Workflow.swift.
struct EmailNotificationSettings: Codable {
    var isEnabled: Bool = true
}
