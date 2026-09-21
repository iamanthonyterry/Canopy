import Foundation
import Network
import Combine

// MARK: - Wire format
// What one Canopy instance tells another about itself. Kept small and
// self-contained — it's a single JSON document sent over a short-lived
// TCP connection.

nonisolated struct PeerRun: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var workflowName: String
    /// Display names of the devices this run touches (as named on the
    /// *sending* computer).
    var deviceNames: [String]
    /// Machine-independent identifiers for those devices (IP address, share
    /// path, folder path) — device names are chosen per computer, so these
    /// are what actually get compared to detect a clash.
    var resourceKeys: [String]
    var startedAt: Date
    var isPaused: Bool
    var completedSteps: Int
    var totalSteps: Int
}

nonisolated struct PeerSnapshot: Codable, Equatable, Identifiable, Sendable {
    var instanceID: String
    var computerName: String
    var runs: [PeerRun]

    var id: String { instanceID }
}

// MARK: - Peer Presence Service
// Finds other Canopy instances on the local network over Bonjour and keeps
// an up-to-date picture of which workflows they're running, so two people
// on two computers don't process the same content at the same time.
//
// Every instance both advertises (`_canopy._tcp`, answering each connection
// with its current snapshot) and browses. Peers are polled rather than
// pushed to: a poll every few seconds is plenty for this, and a peer that
// quits or loses the network simply stops answering and drops off the list.

@MainActor
final class PeerPresenceService: ObservableObject {
    static let shared = PeerPresenceService()

    static let serviceType = "_canopy._tcp"

    /// Other Canopy instances currently reachable, most recently seen state.
    @Published private(set) var peers: [PeerSnapshot] = []
    @Published private(set) var lastError: String? = nil

    private let instanceID = UUID().uuidString
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]   // keyed by peer instanceID
    private var missedPolls: [String: Int] = [:]
    private var pollTask: Task<Void, Never>?

    private let queue = DispatchQueue(label: "com.canopy.peers", qos: .utility)
    private let pollInterval: Duration = .seconds(4)
    /// A peer must miss this many polls in a row before it's considered
    /// gone — one dropped connection shouldn't briefly un-block a workflow.
    private let missThreshold = 3

    // MARK: - Lifecycle

    /// Safe to call more than once.
    func start() {
        guard listener == nil else { return }
        startListener()
        startBrowser()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollPeers()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(4))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        endpoints.removeAll()
        missedPolls.removeAll()
        publish([])
    }

    // MARK: - Advertising

    private func startListener() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: instanceID, type: Self.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.answer(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Task { @MainActor in self?.lastError = error.localizedDescription }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Replies to one inbound poll with our current snapshot, then closes.
    private func answer(_ connection: NWConnection) {
        connection.start(queue: queue)
        guard let data = try? Self.encoder.encode(localSnapshot()) else {
            connection.cancel()
            return
        }
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    /// This computer's own state — what workflows are running here, right now.
    func localSnapshot() -> PeerSnapshot {
        let runs = AppState.shared.activeRuns.filter { !$0.isFinished }.map { session in
            PeerRun(
                id: session.id,
                workflowName: session.workflow.name,
                deviceNames: session.deckNames.sorted(),
                resourceKeys: session.resourceKeys.sorted(),
                startedAt: session.startedAt,
                isPaused: session.isPaused,
                completedSteps: session.completedStepCount,
                totalSteps: session.stepRuns.count
            )
        }
        return PeerSnapshot(
            instanceID: instanceID,
            computerName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            runs: runs
        )
    }

    // MARK: - Discovery

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [String: NWEndpoint] = [:]
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint {
                    found[name] = result.endpoint
                }
            }
            Task { @MainActor in self?.updateEndpoints(found) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func updateEndpoints(_ found: [String: NWEndpoint]) {
        // The service name *is* the peer's instance ID, so filtering out
        // ourselves is just a name comparison.
        endpoints = found.filter { $0.key != instanceID }
    }

    // MARK: - Polling

    private func pollPeers() async {
        let targets = endpoints
        var results: [String: PeerSnapshot] = [:]

        await withTaskGroup(of: (String, PeerSnapshot?).self) { group in
            for (name, endpoint) in targets {
                group.addTask { (name, await Self.fetchSnapshot(from: endpoint)) }
            }
            for await (name, snapshot) in group {
                if let snapshot { results[name] = snapshot }
            }
        }

        var current = Dictionary(uniqueKeysWithValues: peers.map { ($0.instanceID, $0) })
        for (name, _) in targets {
            if let snapshot = results[name] {
                current[snapshot.instanceID] = snapshot
                missedPolls[name] = 0
            } else {
                missedPolls[name, default: 0] += 1
            }
        }

        // Drop peers that are no longer advertised, or that have stopped
        // answering for several polls in a row.
        let live = Set(targets.keys)
        current = current.filter { _, snapshot in
            live.contains(snapshot.instanceID) && (missedPolls[snapshot.instanceID] ?? 0) < missThreshold
        }

        publish(current.values.sorted { $0.computerName.localizedCaseInsensitiveCompare($1.computerName) == .orderedAscending })
    }

    private func publish(_ snapshots: [PeerSnapshot]) {
        guard snapshots != peers else { return }
        peers = snapshots
        AppState.shared.peerSnapshots = snapshots
    }

    private nonisolated static func fetchSnapshot(from endpoint: NWEndpoint) async -> PeerSnapshot? {
        await withCheckedContinuation { continuation in
            SnapshotFetch(endpoint: endpoint, continuation: continuation).start()
        }
    }

    // MARK: - Coding

    private nonisolated static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    nonisolated static func decode(_ data: Data) throws -> PeerSnapshot {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(PeerSnapshot.self, from: data)
    }
}

// MARK: - One poll of one peer
// Serialized on its own queue, which is why it can be @unchecked Sendable.

private nonisolated final class SnapshotFetch: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.canopy.peers.fetch")
    private var continuation: CheckedContinuation<PeerSnapshot?, Never>?
    private var buffer = Data()

    init(endpoint: NWEndpoint, continuation: CheckedContinuation<PeerSnapshot?, Never>) {
        connection = NWConnection(to: endpoint, using: .tcp)
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:              receive()
            case .failed, .cancelled: finish(nil)
            default:                  break
            }
        }
        connection.start(queue: queue)
        // A peer that accepts the connection but never replies shouldn't
        // stall the poll loop.
        queue.asyncAfter(deadline: .now() + 3) { [self] in finish(nil) }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if buffer.count > 256 * 1024 || error != nil {
                finish(nil)
            } else if isComplete {
                finish(try? PeerPresenceService.decode(buffer))
            } else {
                receive()
            }
        }
    }

    private func finish(_ snapshot: PeerSnapshot?) {
        guard let continuation else { return }
        self.continuation = nil
        connection.cancel()
        continuation.resume(returning: snapshot)
    }
}
