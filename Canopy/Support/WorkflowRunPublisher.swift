import Foundation
import Combine

// MARK: - Workflow progress on the website
// While this Mac is signed in with the church's website (see SiteAccount),
// each workflow run is written to the church's `workflow_runs` table so the
// website's Workflows page can show it live: every step's state and
// progress, files done, and time left. A run's row is written when it
// starts, again whenever something about it changes (checked every few
// seconds), at least every 30 seconds so the website can tell a long step
// from a Mac that went to sleep, and once more when it finishes. Nothing is
// read back: runs are still started, paused and stopped here.

@MainActor
final class WorkflowRunPublisher: ObservableObject {
    static let shared = WorkflowRunPublisher()

    @Published var isEnabled: Bool = UserDefaults.standard.object(forKey: "workflowRuns.shareOnWebsite") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "workflowRuns.shareOnWebsite") }
    }

    private static let interval: Duration = .seconds(4)
    private static let heartbeat: TimeInterval = 30
    /// After a failed write (no network, or the table isn't set up yet), wait this long before trying again.
    private static let backoff: TimeInterval = 60
    /// Finished runs older than this are cleared from the table (only this person's own).
    private static let keepFor: TimeInterval = 30 * 24 * 3600

    private var loop: Task<Void, Never>?
    private var isTicking = false
    private var membership: (userID: String, churchID: String)?
    private var lastSent: [UUID: (snapshot: Snapshot, at: Date)] = [:]
    /// Runs that just finished, kept until their final state is written, since a clean run leaves `activeRuns` at once.
    private var finished: [UUID: WorkflowRunSession] = [:]
    private var retryAfter = Date.distantPast
    private var tidiedFor: String?

    static let computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    /// Tells this Mac's runs apart from another computer's, even if both have the same name.
    static let deviceID: String = {
        let key = "workflowRuns.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private var computer: String { Self.computerName }
    /// Cleared if the database has no `device_id` column yet, so runs still show up on the website.
    private var sendsDeviceID = true

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

    /// Called as a run finishes, before it may be removed from `activeRuns`.
    func runFinished(_ session: WorkflowRunSession) {
        guard lastSent[session.id] != nil || isEnabled else { return }
        finished[session.id] = session
        Task { await tick() }
    }

    // MARK: Snapshot

    /// What the website shows for one run. Equatable so unchanged runs aren't rewritten every few seconds.
    private struct Snapshot: Equatable {
        struct Step: Equatable { var title: String; var status: String; var progress: Double?; var detail: String; var errors: Int }
        var workflow: String
        var devices: [String]
        var status: String
        var steps: [Step]
        var filesTotal: Int
        var filesDone: Int
        var errors: Int
        var remaining: Double?
        var remainingIsMinimum: Bool
        var lastLine: String
        var startedAt: Date
        var finishedAt: Date?
    }

    private static func snapshot(_ session: WorkflowRunSession) -> Snapshot {
        let status: String
        if session.isFinished { status = session.isCancelled ? "stopped" : session.mountError != nil ? "failed" : "done" }
        else if session.pendingConfirmationStep != nil { status = "waiting" }
        else if session.isPaused { status = "paused" }
        else { status = "running" }

        let steps = session.stepRuns.map { run -> Snapshot.Step in
            let state: String = switch run.status {
            case .pending: "pending"
            case .awaitingConfirmation: "waiting"
            case .running: "running"
            case .done: "done"
            case .skipped: "skipped"
            case .cancelled: "cancelled"
            }
            // Two decimal places is plenty for a progress bar, and keeps tiny changes from counting as news.
            let progress = run.status == .running ? session.progress(for: run).map { ($0 * 100).rounded() / 100 } : nil
            return .init(title: run.step.action.shortLabel, status: state, progress: progress,
                         detail: run.status == .running ? session.detail(for: run) ?? "" : "", errors: run.errors)
        }
        let estimate = session.estimate()
        let last = session.lines.last.map { $0.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression) } ?? ""
        return Snapshot(
            workflow: session.workflow.name, devices: session.deckNames.sorted(), status: status, steps: steps,
            filesTotal: session.tasks.count, filesDone: session.tasks.filter { $0.phase == .done || $0.phase == .error }.count,
            errors: session.errors, remaining: estimate.map { $0.remaining(at: Date()) }, remainingIsMinimum: estimate?.isLowerBound ?? false,
            lastLine: String(last.prefix(300)), startedAt: session.startedAt, finishedAt: session.isFinished ? Date() : nil
        )
    }

    /// Whether `now` is worth writing, given what was written last. The website counts the
    /// estimate down on its own, so only a real change in it counts.
    private static func isNews(_ now: Snapshot, since last: (snapshot: Snapshot, at: Date)?) -> Bool {
        guard let last else { return true }
        let elapsed = Date().timeIntervalSince(last.at)
        if elapsed >= heartbeat || now.finishedAt != nil { return true }
        var a = now, b = last.snapshot
        switch (a.remaining, b.remaining) {
        case let (x?, y?):
            let expected = b.status == "running" ? y - elapsed : y
            if abs(x - expected) > max(15, expected * 0.1) { return true }
        case (nil, nil): break
        default: return true
        }
        a.remaining = nil; b.remaining = nil
        return a != b
    }

    // MARK: Writing

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private func row(_ s: Snapshot, id: UUID, churchID: String, userID: String) -> [String: Any?] {
        func finite(_ v: Double?) -> Any { v.flatMap { $0.isFinite ? $0 : nil } ?? NSNull() }
        var row: [String: Any?] = [
            "id": id.uuidString.lowercased(), "church_id": churchID, "user_id": userID, "computer": computer,
            "workflow": s.workflow, "devices": s.devices, "status": s.status,
            "steps": s.steps.map { ["title": $0.title, "status": $0.status, "progress": finite($0.progress), "detail": $0.detail, "errors": $0.errors] as [String: Any] },
            "files_total": s.filesTotal, "files_done": s.filesDone, "errors": s.errors,
            "remaining_seconds": finite(s.remaining), "remaining_is_minimum": s.remainingIsMinimum, "last_line": s.lastLine,
            "started_at": Self.iso.string(from: s.startedAt), "finished_at": s.finishedAt.map(Self.iso.string(from:)),
        ]
        if sendsDeviceID { row["device_id"] = Self.deviceID }
        return row
    }

    private func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        guard let db = SiteAccount.shared.client else { membership = nil; lastSent = [:]; finished = [:]; return }
        // Turning sharing off still lets a run that was already on the website show how it ended.
        let live = AppState.shared.activeRuns.filter { !$0.isFinished && (isEnabled || lastSent[$0.id] != nil) }
        let ending = Array(finished.values)
        guard !live.isEmpty || !ending.isEmpty || (isEnabled && tidiedFor != db.session.userID) else { return }
        guard Date() >= retryAfter else { return }

        do {
            let (userID, churchID) = try await church(db)
            if tidiedFor != userID { try await tidy(db, userID: userID, keeping: Set(live.map(\.id))); tidiedFor = userID }
            for session in live + ending {
                let snap = Self.snapshot(session)
                guard Self.isNews(snap, since: lastSent[session.id]) else { continue }
                _ = try await db.upsert("workflow_runs", row(snap, id: session.id, churchID: churchID, userID: userID), onConflict: "id")
                if snap.finishedAt != nil {
                    lastSent[session.id] = nil
                    finished[session.id] = nil
                } else {
                    lastSent[session.id] = (snap, Date())
                }
            }
            // Forget runs that ended without passing through `runFinished` (dismissed, say).
            let known = Set(live.map(\.id)).union(finished.keys)
            lastSent = lastSent.filter { known.contains($0.key) }
        } catch {
            if let e = error as? SupabaseError, e.status == 401 { SiteAccount.shared.sessionExpired(); return }
            if let e = error as? SupabaseError, e.code == "PGRST204", e.message.contains("device_id") { sendsDeviceID = false; return }
            retryAfter = Date().addingTimeInterval(Self.backoff)
        }
    }

    private func church(_ db: SupabaseClient) async throws -> (String, String) {
        let uid = db.session.userID
        if let m = membership, m.userID == uid { return (m.userID, m.churchID) }
        nonisolated struct Member: Decodable { var churchId: String }
        guard let me = try await db.select("church_members", "church_id", [.eq("user_id", uid)], as: Member.self).first else {
            throw SupabaseError(message: "\(db.session.email) isn't part of a church yet.")
        }
        membership = (uid, me.churchId)
        return (uid, me.churchId)
    }

    /// Once per sign-in: runs this Mac left unfinished on the website (the app quit mid-run, say) are marked
    /// stopped unless they're running again or waiting to be resumed, and old finished runs are cleared out.
    private func tidy(_ db: SupabaseClient, userID: String, keeping running: Set<UUID>) async throws {
        let keep = running.union(WorkflowCheckpointStore.shared.interrupted.map(\.id)).map { $0.uuidString.lowercased() }
        var orphans: [Filter] = [.eq("user_id", userID), .eq("computer", computer), .isNull("finished_at")]
        if !keep.isEmpty { orphans.append(.notIn("id", keep)) }
        try await db.update("workflow_runs", ["status": "stopped", "finished_at": Self.iso.string(from: Date())], orphans)
        let cutoff = Self.iso.string(from: Date().addingTimeInterval(-Self.keepFor))
        try await db.delete("workflow_runs", [.eq("user_id", userID), .lt("finished_at", cutoff)])
    }
}
