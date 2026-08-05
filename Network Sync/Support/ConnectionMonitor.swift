import Foundation
import Network
import Combine

/// Continuously polls every added device's reachability *and* login/
/// permission status, so status badges stay live and automatically recover
/// when a device drops, reconnects, or has its credentials fixed.
/// One instance for the whole app — start it once at launch.
@MainActor
final class ConnectionMonitor: ObservableObject {
    static let shared = ConnectionMonitor()

    @Published private(set) var statuses: [String: DeckStatus] = [:]

    /// IP addresses of HyperDecks that were recording as of the last poll.
    /// Tracked continuously (not just while a deck's detail pane is open)
    /// so AlertingService can tell a routine "deck's off the network" from
    /// "deck went dark mid-recording" — the latter is the one that's
    /// actually urgent.
    @Published private(set) var recordingHosts: Set<String> = []

    private var monitorTask: Task<Void, Never>?
    private let pollInterval: Duration = .seconds(5)

    /// Consecutive failed polls per host. A single dropped packet (common
    /// with the UDP-based ATEM probe, but possible on any flaky network)
    /// shouldn't flash a badge to "Offline" and back — we only commit to
    /// offline once a device fails this many polls in a row. Recovery to
    /// online is always immediate, since a real response is unambiguous.
    private var consecutiveFailures: [String: Int] = [:]
    private let offlineThreshold = 2

    func status(for host: String) -> DeckStatus {
        statuses[host] ?? .unknown
    }

    func isRecording(host: String) -> Bool {
        recordingHosts.contains(host)
    }

    /// Starts the continuous polling loop. Safe to call more than once.
    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAllDevices()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(5))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Forces an immediate re-check of a HyperDeck, including its login,
    /// e.g. from a manual "Refresh" button, without waiting for the next
    /// poll cycle.
    func pingNow(deck: HyperDeck) async {
        let (status, isRecording) = await Self.checkDeck(deck)
        apply(status, for: deck.ipAddress)
        if isRecording {
            recordingHosts.insert(deck.ipAddress)
        } else {
            recordingHosts.remove(deck.ipAddress)
        }
    }

    func pingNow(store: CloudStore) async {
        apply(await Self.checkCloudStore(store), for: store.ipAddress)
    }

    func pingNow(switcher: BlackmagicSwitcher) async {
        apply(await ATEMProbe.ping(host: switcher.ipAddress), for: switcher.ipAddress)
    }

    /// Commits a poll result for a host, debouncing transient offline blips.
    private func apply(_ result: DeckStatus, for host: String) {
        guard result == .offline else {
            consecutiveFailures[host] = 0
            statuses[host] = result
            return
        }

        let failures = (consecutiveFailures[host] ?? 0) + 1
        consecutiveFailures[host] = failures
        guard failures >= offlineThreshold else { return }
        statuses[host] = .offline
    }

    // MARK: - Polling

    private func pollAllDevices() async {
        let appState = AppState.shared
        let decks     = appState.hyperDecks
        let switchers = appState.switchers
        let stores    = appState.cloudStores

        guard !(decks.isEmpty && switchers.isEmpty && stores.isEmpty) else {
            if !statuses.isEmpty { statuses.removeAll() }
            if !consecutiveFailures.isEmpty { consecutiveFailures.removeAll() }
            if !recordingHosts.isEmpty { recordingHosts.removeAll() }
            return
        }

        // HyperDecks report recording state alongside reachability (both
        // come from the same "transport info" round trip), so they're
        // gathered separately from switchers/stores rather than folded into
        // one shared (host, DeckStatus) task group.
        async let deckResults: [(host: String, status: DeckStatus, isRecording: Bool)] =
            withTaskGroup(of: (String, DeckStatus, Bool).self) { group in
                for deck in decks {
                    group.addTask {
                        let (status, recording) = await Self.checkDeck(deck)
                        return (deck.ipAddress, status, recording)
                    }
                }
                var collected: [(String, DeckStatus, Bool)] = []
                for await result in group { collected.append(result) }
                return collected
            }

        await withTaskGroup(of: (String, DeckStatus).self) { group in
            for switcher in switchers {
                group.addTask { (switcher.ipAddress, await ATEMProbe.ping(host: switcher.ipAddress)) }
            }
            for store in stores {
                group.addTask { (store.ipAddress, await Self.checkCloudStore(store)) }
            }
            for await (host, status) in group {
                apply(status, for: host)
            }
        }

        var stillRecording: Set<String> = []
        for (host, status, isRecording) in await deckResults {
            apply(status, for: host)
            if isRecording { stillRecording.insert(host) }
        }
        recordingHosts = stillRecording

        // Drop entries for devices that were removed since the last poll.
        // Only touches the dictionaries when there's actually something
        // stale, so an unchanged device list never triggers a redundant
        // @Published update (and the redraw that comes with it).
        let liveHosts = Set(decks.map(\.ipAddress) + switchers.map(\.ipAddress) + stores.map(\.ipAddress))
        let staleHosts = Set(statuses.keys).subtracting(liveHosts)
        if !staleHosts.isEmpty {
            for host in staleHosts {
                statuses.removeValue(forKey: host)
                consecutiveFailures.removeValue(forKey: host)
            }
        }
    }

    // MARK: - Per-device checks

    /// Reachability first, then — only if reachable — confirms the stored
    /// login can actually list the deck's remote path, and finally that a
    /// disk/SSD is actually installed. Each of these fails in a different,
    /// user-actionable way, so they're kept as distinct statuses rather than
    /// being collapsed into one generic error.
    private static func checkDeck(_ deck: HyperDeck) async -> (status: DeckStatus, isRecording: Bool) {
        let reachable = await ping(host: deck.ipAddress, port: 9993)
        guard reachable == .online else { return (reachable, false) }

        switch await FTPService.probeAuth(on: deck) {
        case .unauthorized: return (.unauthorized, false)
        case .pathNotFound: return (.pathNotFound, false)
        case .authorized, .inconclusive: break
        }

        async let mediaPresent = HyperDeckService.checkMediaPresent(host: deck.ipAddress)
        async let recording = HyperDeckService.isRecording(host: deck.ipAddress)

        if await mediaPresent == false {
            return (.noMedia, await recording)
        }
        return (.online, await recording)
    }

    /// Reachability first, then — only if reachable — confirms the stored
    /// login can actually authenticate against the SMB share.
    private static func checkCloudStore(_ store: CloudStore) async -> DeckStatus {
        let reachable = await ping(host: store.ipAddress, port: 445)
        guard reachable == .online else { return reachable }

        let auth = await SMBService.probeAuth(
            ip: store.ipAddress, username: store.username, password: store.password
        )
        if case .unauthorized = auth { return .unauthorized }
        return .online
    }

    private static func ping(host: String, port: UInt16) async -> DeckStatus {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .offline }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        conn.start(queue: .global())
        return await resolveConnectionStatus(conn)
    }
}
