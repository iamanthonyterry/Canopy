import ChurchKitAuth
import Foundation
import Combine

// MARK: - Runs on the person's other computers
// Every computer signed in as this person writes its runs to `workflow_runs`
// (see WorkflowRunPublisher). This reads them back so the Workflows page can
// show what's running elsewhere, which computer it's on, and how far along it
// is. It only polls while a screen that shows it is open.

nonisolated struct RemoteRun: Decodable, Identifiable, Sendable {
    nonisolated struct Step: Decodable, Sendable {
        var title: String
        var status: String
        var progress: Double?
        var detail: String?
        var errors: Int?
    }

    var id: String
    var computer: String
    var deviceId: String?
    var workflow: String
    var devices: [String]?
    var status: String
    var steps: [Step]?
    var filesTotal: Int?
    var filesDone: Int?
    var errors: Int?
    var remainingSeconds: Double?
    var remainingIsMinimum: Bool?
    var lastLine: String?
    var startedAt: String?
    var finishedAt: String?
    var updatedAt: String?

    static let staleAfter: TimeInterval = 120

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    var isFinished: Bool { finishedAt != nil }
    var lastUpdate: Date? { updatedAt.flatMap(Self.date) }
    var started: Date? { startedAt.flatMap(Self.date) }
    var finished: Date? { finishedAt.flatMap(Self.date) }

    /// A run that says it's going but hasn't reported for a while: the computer slept, quit or lost its connection.
    var isStale: Bool {
        guard !isFinished, let last = lastUpdate else { return false }
        return Date().timeIntervalSince(last) > Self.staleAfter
    }

    var currentStepIndex: Int? {
        steps?.firstIndex { $0.status == "running" || $0.status == "waiting" }
    }
}

@MainActor
final class RemoteRunsService: ObservableObject {
    static let shared = RemoteRunsService()

    /// Runs on this person's other computers: in progress, or finished within the last few minutes.
    @Published private(set) var runs: [RemoteRun] = []

    private static let interval: Duration = .seconds(5)
    private static let recentlyFinished: TimeInterval = 10 * 60

    private var watchers = 0
    private var loop: Task<Void, Never>?
    private var retryAfter = Date.distantPast

    private init() {}

    func beginWatching() {
        watchers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { loop?.cancel(); loop = nil }
    }

    private func refresh() async {
        guard let db = SiteAccount.shared.client else { runs = []; return }
        guard Date() >= retryAfter else { return }
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Self.recentlyFinished))
        let columns = "id,computer,device_id,workflow,devices,status,steps,files_total,files_done,errors,remaining_seconds,remaining_is_minimum,last_line,started_at,finished_at,updated_at"
        do {
            let rows = try await db.select("workflow_runs", columns, [
                .eq("user_id", db.session.userID),
                Filter(name: "or", value: "(finished_at.is.null,finished_at.gt.\(cutoff))"),
                .order("started_at.desc"),
            ], as: RemoteRun.self)
            let me = WorkflowRunPublisher.deviceID
            let myName = WorkflowRunPublisher.computerName
            runs = rows.filter { $0.deviceId.map { $0 != me } ?? ($0.computer != myName) }
        } catch {
            if let e = error as? SupabaseError, e.status == 401 { SiteAccount.shared.sessionExpired(); return }
            retryAfter = Date().addingTimeInterval(30)
        }
    }
}
