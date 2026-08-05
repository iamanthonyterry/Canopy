import Foundation

/// Settings for real-time alerts, fired by AlertingService the moment a
/// device that's actively recording or mid-workflow drops offline, loses
/// auth, runs out of media, or is about to run out of storage — the
/// failures that matter most because they can silently kill a live
/// recording while no one's watching the dashboard.
struct AlertSettings: Codable {
    var isEnabled: Bool = true

    /// Always shown as a macOS notification. Also emailed to these
    /// recipients if the list isn't empty and Gmail is connected.
    var emailRecipients: [NotificationRecipient] = []

    /// Warn once a recording deck's used capacity crosses this percentage
    /// of its configured total. Only applies to decks with a capacity
    /// entered in their device settings — others can't be checked.
    var lowStorageThresholdPercent: Int = 90
}
