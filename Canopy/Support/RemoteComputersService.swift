import ChurchKitAuth
import Foundation
import Combine

// MARK: - Other computers, and running workflows on them
// Every computer signed in as this person keeps a row in `canopy_computers`
// (its name, the workflows it has, whether it accepts runs from the others,
// and when it was last seen). To run a workflow on another computer, this Mac
// adds a row to `canopy_commands`; the target polls for its pending commands,
// claims one (a conditional update, so only one claim wins), checks it can
// run it, and starts it with its own devices. Progress comes back through the
// ordinary run sharing (see RemoteRunsService). A computer only accepts these
// when the person turned that on there; it's off by default.

nonisolated struct RemoteComputer: Decodable, Identifiable, Sendable {
    nonisolated struct Entry: Decodable, Identifiable, Sendable { var id: String; var name: String }
    var deviceId: String
    var name: String
    var acceptsRemote: Bool
    var workflows: [Entry]
    var lastSeen: String

    var id: String { deviceId }
    var seen: Date? { RemoteRun.date(lastSeen) }
    var isOnline: Bool { seen.map { Date().timeIntervalSince($0) < RemoteComputersService.onlineWithin } ?? false }
}

@MainActor
final class RemoteComputersService: ObservableObject {
    static let shared = RemoteComputersService()

    /// Whether other computers may start workflows on this one.
    @Published var acceptsRemote: Bool = UserDefaults.standard.bool(forKey: "remoteComputers.accepts") {
        didSet {
            UserDefaults.standard.set(acceptsRemote, forKey: "remoteComputers.accepts")
            lastPublished = nil
            Task { await tick() }
        }
    }
    @Published private(set) var computers: [RemoteComputer] = []
    /// The latest answer to a request made from this Mac, by target computer, so the screen can say why it didn't start.
    @Published private(set) var outcomes: [String: String] = [:]

    nonisolated static let onlineWithin: TimeInterval = 90
    private static let interval: Duration = .seconds(5)
    private static let heartbeat: TimeInterval = 30
    private static let expireAfter: TimeInterval = 120

    private struct Published_: Equatable { var name: String; var accepts: Bool; var workflows: [String] }

    nonisolated private struct Command: Decodable {
        var id: String
        var workflowId: String
        var workflowName: String
        var targetDeviceId: String
        var status: String
        var detail: String?
        var createdAt: String
    }

    private var watchers = 0
    private var loop: Task<Void, Never>?
    private var lastPublished: Published_?
    private var lastBeat = Date.distantPast
    private var retryAfter = Date.distantPast
    private var isTicking = false
    private var asked: [String: String] = [:]   // command id -> target device id

    private init() {}

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func beginWatching() { watchers += 1; Task { await tick() } }
    func endWatching() { watchers = max(0, watchers - 1) }

    // MARK: Asking another computer

    /// Asks `computer` to run its copy of the workflow. Returns an error to show, if the request couldn't be made.
    func request(_ workflow: RemoteComputer.Entry, on computer: RemoteComputer) async -> String? {
        guard let db = SiteAccount.shared.client else { return "Sign in first." }
        guard computer.acceptsRemote else { return "Turn on “Let my other computers run workflows here” on \(computer.name) first." }
        do {
            let ids = try await db.insertIDs("canopy_commands", [[
                "user_id": db.session.userID,
                "from_device_id": WorkflowRunPublisher.deviceID,
                "target_device_id": computer.deviceId,
                "workflow_id": workflow.id,
                "workflow_name": workflow.name,
            ]])
            if let id = ids.first { asked[id] = computer.deviceId }
            outcomes[computer.deviceId] = "Asked \(computer.name) to run “\(workflow.name)”…"
            return nil
        } catch {
            if let e = error as? SupabaseError, e.status == 401 { SiteAccount.shared.sessionExpired() }
            return error.localizedDescription
        }
    }

    // MARK: Pass

    private func tick() async {
        guard !isTicking, let db = SiteAccount.shared.client, Date() >= retryAfter else { return }
        isTicking = true
        defer { isTicking = false }
        do {
            try await publish(db)
            try await answerCommands(db)
            if watchers > 0 {
                try await loadComputers(db)
                try await checkAsked(db)
            }
        } catch {
            if let e = error as? SupabaseError, e.status == 401 { SiteAccount.shared.sessionExpired(); return }
            retryAfter = Date().addingTimeInterval(60)
        }
    }

    /// Tells the others this computer is here and what it has.
    private func publish(_ db: SupabaseClient) async throws {
        let list = AppState.shared.workflows.filter { !$0.steps.isEmpty }.sorted { $0.sortOrder < $1.sortOrder }
        let now = Published_(name: WorkflowRunPublisher.computerName, accepts: acceptsRemote,
                             workflows: list.map { "\($0.id.uuidString.lowercased())|\($0.name)" })
        guard now != lastPublished || Date().timeIntervalSince(lastBeat) >= Self.heartbeat else { return }
        let row: [String: Any?] = [
            "user_id": db.session.userID, "device_id": WorkflowRunPublisher.deviceID, "name": now.name,
            "accepts_remote": now.accepts,
            "workflows": list.map { ["id": $0.id.uuidString.lowercased(), "name": $0.name] },
        ]
        _ = try await db.upsert("canopy_computers", row, onConflict: "user_id,device_id")
        lastPublished = now
        lastBeat = Date()
    }

    private func loadComputers(_ db: SupabaseClient) async throws {
        let rows = try await db.select("canopy_computers", "device_id,name,accepts_remote,workflows,last_seen",
                                       [.eq("user_id", db.session.userID), .order("name.asc")], as: RemoteComputer.self)
        computers = rows.filter { $0.deviceId != WorkflowRunPublisher.deviceID }
    }

    /// Picks up requests made to this computer.
    private func answerCommands(_ db: SupabaseClient) async throws {
        let mine = WorkflowRunPublisher.deviceID
        let pending = try await db.select("canopy_commands", "id,workflow_id,workflow_name,target_device_id,status,detail,created_at",
                                          [.eq("user_id", db.session.userID), .eq("target_device_id", mine), .eq("status", "pending")],
                                          as: Command.self)
        for c in pending {
            // Whoever updates it from "pending" first owns it.
            let won = try await db.updateReturningIDs("canopy_commands", ["status": "started"],
                                                      [.eq("id", c.id), .eq("status", "pending")])
            guard !won.isEmpty else { continue }
            if let why = refusal(for: c) {
                try await db.update("canopy_commands", ["status": "refused", "detail": why], [.eq("id", c.id)])
                continue
            }
            guard let workflow = AppState.shared.workflows.first(where: { $0.id.uuidString.caseInsensitiveCompare(c.workflowId) == .orderedSame }) else { continue }
            Task { await WorkflowEngine.shared.run(workflow) }
        }
    }

    private func refusal(for c: Command) -> String? {
        if let at = RemoteRun.date(c.createdAt), Date().timeIntervalSince(at) > Self.expireAfter {
            return "The request was too old to run."
        }
        guard acceptsRemote else { return "\(WorkflowRunPublisher.computerName) isn't set to accept runs from other computers." }
        guard let workflow = AppState.shared.workflows.first(where: { $0.id.uuidString.caseInsensitiveCompare(c.workflowId) == .orderedSame }),
              !workflow.steps.isEmpty else { return "\(WorkflowRunPublisher.computerName) doesn't have that workflow." }
        guard AppState.shared.canRun(workflow) else { return "Its devices are busy on \(WorkflowRunPublisher.computerName)." }
        return nil
    }

    /// Reports how this Mac's own requests were answered.
    private func checkAsked(_ db: SupabaseClient) async throws {
        guard !asked.isEmpty else { return }
        let rows = try await db.select("canopy_commands", "id,workflow_id,workflow_name,target_device_id,status,detail,created_at",
                                       [.in("id", Array(asked.keys))], as: Command.self)
        for c in rows where c.status != "pending" {
            let name = computers.first { $0.deviceId == c.targetDeviceId }?.name ?? "that computer"
            outcomes[c.targetDeviceId] = c.status == "started"
                ? "“\(c.workflowName)” started on \(name)."
                : (c.detail ?? "\(name) couldn't run “\(c.workflowName)”.")
            asked[c.id] = nil
        }
    }
}
