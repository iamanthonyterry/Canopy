import Foundation

/// Watches for the failures that matter most during a live service: a
/// HyperDeck that's actively recording (or mid-workflow) going offline,
/// losing its login, losing its drive, or running low on storage. Unlike
/// the dashboard's status badges — which only help if someone's looking at
/// them — this fires an immediate, time-sensitive notification (and,
/// optionally, an email) the moment it happens.
///
/// A singleton like ConnectionMonitor and WorkflowEngine: there's only ever
/// one live set of alert state for the app. Runs its own lightweight timer
/// rather than subscribing to ConnectionMonitor's @Published properties, so
/// connectivity and recording state are always read together as one
/// consistent snapshot instead of reacting to two publishers that update
/// independently.
@MainActor
final class AlertingService {
    static let shared = AlertingService()

    private let appState = AppState.shared
    private let monitor = ConnectionMonitor.shared

    private var pollTask: Task<Void, Never>?
    private var storageTask: Task<Void, Never>?

    private init() {}

    // MARK: - Per-host tracking state

    /// Status seen on the previous tick, per device — a change from this is
    /// what actually triggers an alert (rather than re-firing every tick a
    /// device happens to still be offline).
    private var lastStatus: [String: DeckStatus] = [:]

    /// Sticky "was this device live (recording, or part of an active
    /// workflow run) as of its last successful poll." Kept as-is while a
    /// device is unreachable — that's the whole point, since a dropped
    /// device can no longer report its own recording state — and only
    /// refreshed once the device is confirmed back online.
    private var lastKnownLive: [String: Bool] = [:]

    /// Devices already alerted for their *current* bad status, so one that
    /// stays offline for the rest of the service doesn't re-fire every
    /// five seconds. Cleared once the device recovers.
    private var activeConnectivityAlerts: Set<String> = []

    /// Devices already warned about low storage during their *current*
    /// recording session. Cleared once that device stops recording, so a
    /// later recording gets its own warning.
    private var storageWarned: Set<String> = []

    /// Starts both background loops. Safe to call more than once.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkConnectivity()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        storageTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkStorage()
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        storageTask?.cancel(); storageTask = nil
    }

    // MARK: - Connectivity alerts

    private func checkConnectivity() {
        guard appState.alertSettings.isEnabled else { return }

        for deck in appState.hyperDecks {
            let host = deck.ipAddress
            let status = monitor.status(for: host)

            if status == .online {
                lastKnownLive[host] = monitor.isRecording(host: host) || appState.busyDeckNames.contains(deck.name)
            }
            let wasLive = lastKnownLive[host] ?? false

            let previousStatus = lastStatus[host]
            lastStatus[host] = status
            guard status != previousStatus else { continue }

            if isAlarming(status) {
                guard wasLive, !activeConnectivityAlerts.contains(host) else { continue }
                activeConnectivityAlerts.insert(host)
                fire(
                    title: "⚠️ \(deck.name) dropped during recording",
                    body: alarmMessage(for: status, deckName: deck.name)
                )
            } else if status == .online {
                activeConnectivityAlerts.remove(host)
                storageWarned.remove(host) // a fresh recording deserves its own warning
            }
        }
    }

    private func isAlarming(_ status: DeckStatus) -> Bool {
        switch status {
        case .offline, .unauthorized, .pathNotFound, .noMedia: return true
        case .online, .unknown, .syncing, .transcoding: return false
        }
    }

    private func alarmMessage(for status: DeckStatus, deckName: String) -> String {
        switch status {
        case .offline:      return "\(deckName) went offline while recording or running a workflow."
        case .unauthorized: return "\(deckName) lost its login while recording or running a workflow."
        case .pathNotFound: return "\(deckName)'s remote folder can no longer be found."
        case .noMedia:      return "\(deckName) has no drive installed — recording may have stopped."
        default:            return "\(deckName) needs attention."
        }
    }

    // MARK: - Storage alerts

    /// Checked on its own, slower cadence (see `start()`) — this walks each
    /// deck's file list over FTP to total up used space, which is far
    /// heavier than a connectivity ping and shouldn't compete with an
    /// in-progress sync for bandwidth every 5 seconds.
    private func checkStorage() async {
        guard appState.alertSettings.isEnabled else { return }
        let threshold = Double(appState.alertSettings.lowStorageThresholdPercent) / 100

        for deck in appState.hyperDecks {
            guard monitor.isRecording(host: deck.ipAddress),
                  deck.capacityGB != nil,
                  !storageWarned.contains(deck.ipAddress) else { continue }

            let info = await StorageCapacityService.capacity(for: deck)
            guard let fraction = info.fraction, fraction >= threshold else { continue }

            storageWarned.insert(deck.ipAddress)
            fire(
                title: "⚠️ \(deck.name) is low on storage",
                body: "\(deck.name) is at \(Int(fraction * 100))% capacity (\(info.summary)) while still recording."
            )
        }
    }

    // MARK: - Delivery

    /// Always shows a local notification; also emails every configured
    /// recipient, best-effort, if any are set and Gmail is connected.
    private func fire(title: String, body: String) {
        appState.log(title)
        NotificationService.sendDeviceAlert(title: title, body: body)

        let recipients = appState.alertSettings.emailRecipients
        guard !recipients.isEmpty, GmailAuthService.shared.isConnected else { return }

        Task {
            _ = await GmailSendService.sendIndividually(
                to: recipients.map(\.email), subject: title, body: body
            )
        }
    }
}
