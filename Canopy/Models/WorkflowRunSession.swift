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

    /// Set by the user's Pause button for *this* run only. Checked between
    /// steps in the run loop (same boundary as `requiresConfirmation`), so
    /// pausing never interrupts a step partway through — the current step
    /// finishes for every device, then the run holds until resumed.
    @Published var isPaused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    var converted = 0
    var skipped = 0
    var errors = 0

    /// One entry per workflow step, in run order, so the UI can show every
    /// step's state at a glance — not just whichever one is active.
    @Published private(set) var stepRuns: [StepRun]

    init(workflow: Workflow, deckNames: Set<String>) {
        self.workflow = workflow
        self.deckNames = deckNames
        self.stepRuns = workflow.steps.map { StepRun(step: $0) }
    }

    // MARK: - Step tracking

    struct StepRun: Identifiable {
        enum Status { case pending, awaitingConfirmation, running, done, skipped, cancelled }

        let step: WorkflowStep
        var status: Status = .pending
        var startedAt: Date? = nil
        var finishedAt: Date? = nil
        /// Errors logged while this step was the active one.
        var errors = 0
        fileprivate var errorsAtStart = 0

        var id: UUID { step.id }
    }

    var currentStepIndex: Int? {
        stepRuns.firstIndex { $0.status == .running || $0.status == .awaitingConfirmation }
    }

    var completedStepCount: Int {
        stepRuns.filter { $0.status == .done || $0.status == .skipped }.count
    }

    private func updateStep(_ id: UUID, _ change: (inout StepRun) -> Void) {
        guard let i = stepRuns.firstIndex(where: { $0.id == id }) else { return }
        change(&stepRuns[i])
    }

    func markAwaitingConfirmation(_ id: UUID) {
        updateStep(id) { $0.status = .awaitingConfirmation }
    }

    func beginStep(_ id: UUID) {
        let errorsNow = errors
        updateStep(id) {
            $0.status = .running
            $0.startedAt = Date()
            $0.errorsAtStart = errorsNow
        }
    }

    func endStep(_ id: UUID) {
        let errorsNow = errors
        updateStep(id) {
            $0.status = .done
            $0.finishedAt = Date()
            $0.errors = errorsNow - $0.errorsAtStart
        }
    }

    /// Called once the run is over: anything that never got to run is
    /// either skipped (per-drive notify handled elsewhere) or cancelled.
    func finalizeSteps() {
        let now = Date()
        for i in stepRuns.indices {
            switch stepRuns[i].status {
            case .pending:
                stepRuns[i].status = isCancelled ? .cancelled : .skipped
            case .running, .awaitingConfirmation:
                stepRuns[i].status = .cancelled
                stepRuns[i].finishedAt = now
            default: break
            }
        }
    }

    /// Fraction complete (0...1) for a step, or nil when the step has no
    /// measurable progress (it's shown as indeterminate while running).
    func progress(for run: StepRun) -> Double? {
        switch run.step.action {
        case .sync:
            guard !tasks.isEmpty else { return nil }
            let total = tasks.reduce(0.0) { sum, t in
                switch t.phase {
                case .queued:                       return sum
                case .downloading:                  return sum + t.syncProgress
                case .converting, .done, .error:    return sum + 1
                }
            }
            return total / Double(tasks.count)
        case .convert:
            guard !tasks.isEmpty else { return nil }
            let total = tasks.reduce(0.0) { sum, t in
                switch t.phase {
                case .converting:       return sum + t.convertProgress
                case .done, .error:     return sum + 1
                default:                return sum
                }
            }
            return total / Double(tasks.count)
        case .wait(let minutes):
            guard let start = run.startedAt, minutes > 0 else { return nil }
            return min(1, Date().timeIntervalSince(start) / Double(minutes * 60))
        default:
            return nil
        }
    }

    /// Short live description of what a step is doing right now.
    func detail(for run: StepRun) -> String? {
        switch run.step.action {
        case .sync, .convert:
            guard !tasks.isEmpty else { return nil }
            let isSync: Bool = { if case .sync = run.step.action { return true } else { return false } }()
            let finished = tasks.filter {
                isSync ? ($0.phase == .converting || $0.phase == .done || $0.phase == .error)
                       : ($0.phase == .done || $0.phase == .error)
            }.count
            var text = "\(finished) of \(tasks.count) files"
            if run.status == .running, isSync, let eta = estimatedSecondsRemaining {
                text += " · \(Int(eta.rounded(.up)) / 60)m \(Int(eta.rounded(.up)) % 60)s left"
            }
            return text
        default:
            return nil
        }
    }

    var failedTasks: [SyncTask] { tasks.filter { $0.phase == .error } }

    /// Estimated seconds remaining for this run's sync work, based on files
    /// still queued or downloading and the current transfer speed. Files are
    /// downloaded one at a time, so this is normally just "time left on the
    /// current file" plus "size of everything still queued behind it" at
    /// that same speed. Nil until we have both a known size and a speed
    /// sample to work from.
    var estimatedSecondsRemaining: Double? {
        let pending = tasks.filter { $0.phase == .queued || $0.phase == .downloading }
        guard !pending.isEmpty else { return nil }

        let remainingBytes = pending.reduce(0.0) { total, task in
            guard task.fileSizeBytes > 0 else { return total }
            let doneFraction = task.phase == .downloading ? task.syncProgress : 0
            return total + Double(task.fileSizeBytes) * (1 - doneFraction)
        }

        let speeds = pending.map(\.bytesPerSecond).filter { $0 > 0 }
        guard !speeds.isEmpty else { return nil }
        let avgSpeed = speeds.reduce(0, +) / Double(speeds.count)
        guard avgSpeed > 0 else { return nil }

        return remainingBytes / avgSpeed
    }

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

    // MARK: - Pause / Resume

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        log("⏸ Paused by user")
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        log("▶️ Resumed by user")
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    /// Suspends the caller while `isPaused` is true — called between steps
    /// in the run loop, mirroring `waitForConfirmation`.
    func waitWhilePaused() async {
        guard isPaused else { return }
        await withCheckedContinuation { continuation in
            pauseContinuation = continuation
        }
    }

    /// Releases a suspended pause without logging "Resumed" — used when a
    /// paused run is stopped outright, so it doesn't hang forever waiting
    /// for a resume that will never come.
    func releasePause() {
        isPaused = false
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}
