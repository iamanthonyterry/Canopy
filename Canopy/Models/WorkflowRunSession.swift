import Foundation
import Combine

/// One workflow run in progress (or just finished). Each run gets its own
/// session — its own task list, log, and counters — instead of sharing a
/// single global set of "current run" properties. That's what lets two
/// unrelated workflows (e.g. one on Deck 1+2, another on Deck 3+4) run at
/// the same time without their progress getting mixed together.
@MainActor
final class WorkflowRunSession: ObservableObject, Identifiable {
    let id = UUID()
    let workflow: Workflow
    /// Names of every device this run touches — used both for display and
    /// to detect conflicts with other runs that want the same device.
    let deckNames: Set<String>
    let startedAt = Date()

    @Published var tasks: [SyncTask] = []
    @Published var lines: [String] = []
    @Published var mountError: String? = nil
    @Published var isFinished = false
    /// Set by the Stop button for *this* run only — other concurrent runs
    /// are unaffected.
    @Published var isCancelled = false

    /// The step currently paused and waiting on a confirmation response —
    /// non-nil only while a `.requiresConfirmation` step is holding the
    /// run. Drives the confirmation prompt in the UI.
    @Published var pendingConfirmationStep: WorkflowStep? = nil
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?

    var converted = 0
    var skipped = 0
    var errors = 0

    init(workflow: Workflow, deckNames: Set<String>) {
        self.workflow = workflow
        self.deckNames = deckNames
    }

    var failedTasks: [SyncTask] { tasks.filter { $0.phase == .error } }

    func log(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lines.append("[\(ts)] \(message)")
    }

    // MARK: - Step confirmation

    /// Suspends the run until the user responds to this step's
    /// confirmation prompt. Returns `true` to proceed, `false` to stop.
    func waitForConfirmation(on step: WorkflowStep) async -> Bool {
        await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
            pendingConfirmationStep = step
        }
    }

    /// Resolves a pending confirmation, if any. Also called when the run
    /// is stopped outright so a paused run doesn't hang forever.
    func resolveConfirmation(proceed: Bool) {
        guard let continuation = confirmationContinuation else { return }
        confirmationContinuation = nil
        pendingConfirmationStep = nil
        continuation.resume(returning: proceed)
    }
}
