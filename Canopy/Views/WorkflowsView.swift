import SwiftUI

struct WorkflowsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var engine = WorkflowEngine.shared

    @State private var editingWorkflow: Workflow? = nil
    @State private var isCreating = false
    @State private var workflowPendingDelete: Workflow? = nil

    private var inProgress: [WorkflowRunSession] {
        appState.activeRuns.filter { !$0.isFinished }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            rule

            if !inProgress.isEmpty {
                ForEach(inProgress) { session in
                    RunningWorkflowBanner(session: session, engine: engine)
                }
                rule
            }

            if appState.workflows.isEmpty {
                emptyState
            } else {
                workflowList
            }
        }
        .background(Color.canopyPaper)
        .sheet(isPresented: $isCreating) {
            WorkflowEditorSheet(workflow: nil).environmentObject(appState)
        }
        .sheet(item: $editingWorkflow) { workflow in
            WorkflowEditorSheet(workflow: workflow).environmentObject(appState)
        }
        .alert(
            "Delete \"\(workflowPendingDelete?.name ?? "")\"?",
            isPresented: Binding(get: { workflowPendingDelete != nil }, set: { if !$0 { workflowPendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) { workflowPendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let w = workflowPendingDelete { appState.deleteWorkflow(id: w.id) }
                workflowPendingDelete = nil
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workflows").font(.canopyTitle).foregroundStyle(Color.canopyInk)
                Text("\(appState.workflows.count) workflow\(appState.workflows.count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isCreating = true
            } label: {
                Label("New Workflow", systemImage: "plus")
            }
            .buttonStyle(.canopyPrimary)
        }
        .padding()
    }

    // MARK: - Hairline rule
    private var rule: some View {
        Rectangle().fill(Color.canopyRule).frame(height: 1)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "flowchart").font(.system(size: 48)).foregroundStyle(Color.canopySage)
            Text("No Workflows Yet").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
            Text("Build a workflow from steps like Record, Sync, Convert, Rename, Format, and Cleanup — then run it manually or on a schedule.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                isCreating = true
            } label: {
                Label("Create a Workflow", systemImage: "plus")
            }
            .buttonStyle(.canopyPrimary)
            Spacer()
        }
        .padding()
    }

    // MARK: - Workflow List

    private var workflowList: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320))], spacing: 16) {
                ForEach(appState.workflows.sorted { $0.sortOrder < $1.sortOrder }) { workflow in
                    workflowCard(workflow)
                }
            }
            .padding()
        }
    }

    private func workflowCard(_ workflow: Workflow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(workflow.name).font(.headline)
                    Text(targetDeviceLabel(workflow))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if workflow.isScheduled {
                    let active = workflow.activeTriggers
                    let scheduleLabel: String = {
                        guard active.count == 1, let trigger = active.first else {
                            return "\(active.count) triggers"
                        }
                        if trigger.mode == .oneTime {
                            return trigger.displayOneTimeDate
                        }
                        let time = trigger.displayTime
                        return trigger.repeatDaily
                            ? "\(time) · \(trigger.displayWeekdays)"
                            : time
                    }()
                    Label(scheduleLabel, systemImage: "clock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.canopySage.opacity(0.18))
                        .foregroundStyle(Color.canopySage)
                        .clipShape(Capsule())
                }
            }

            Text(workflow.stepsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let last = lastRun(for: workflow) {
                Text("Last run: \(last.finishedAt.formatted(.relative(presentation: .named))) · \(last.processed) processed, \(last.errors) errors")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            rule

            HStack {
                Button {
                    editingWorkflow = workflow
                } label: {
                    Image(systemName: "pencil")
                }.buttonStyle(.borderless)

                Button {
                    appState.duplicateWorkflow(id: workflow.id)
                } label: {
                    Image(systemName: "doc.on.doc")
                }.buttonStyle(.borderless)

                Button(role: .destructive) {
                    workflowPendingDelete = workflow
                } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless)

                Spacer()

                if inProgress.contains(where: { $0.workflow.id == workflow.id }) {
                    Label("Running", systemImage: "circle.fill")
                        .font(.caption2).bold()
                        .foregroundStyle(Color.accentColor)
                } else {
                    Button {
                        Task { await engine.run(workflow) }
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.canopyPrimary)
                    .disabled(!appState.canRun(workflow) || workflow.steps.isEmpty)
                }
            }
        }
        .canopyCard(cornerRadius: 10)
    }

    // MARK: - Helpers

    private func targetDeviceLabel(_ workflow: Workflow) -> String {
        if workflow.targets.isEmpty { return "All devices" }
        let names = workflow.targets.compactMap { target -> String? in
            switch target {
            case .hyperDeck(let id):   return appState.hyperDecks.first { $0.id == id }?.name
            case .localFolder(let id): return appState.localFolders.first { $0.id == id }?.name
            case .cloudStore(let id, let path):
                guard let store = appState.cloudStores.first(where: { $0.id == id }) else { return nil }
                return path.isEmpty ? store.name : "\(store.name)/\(path)"
            }
        }
        return names.isEmpty ? "No devices selected" : names.joined(separator: ", ")
    }

    private func lastRun(for workflow: Workflow) -> WorkflowRun? {
        appState.workflowRunHistory.first { $0.workflowName == workflow.name }
    }
}

// MARK: - Running Workflow Banner

/// Live status + controls for one in-progress run. Kept as its own view
/// (rather than a helper inside WorkflowsView) so it can observe the
/// session directly — that's what lets the confirmation prompt below
/// appear the instant a step pauses, without waiting on some unrelated
/// redraw elsewhere in the app.
private struct RunningWorkflowBanner: View {
    @ObservedObject var session: WorkflowRunSession
    let engine: WorkflowEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.isPaused ? "Paused \"\(session.workflow.name)\"" : "Running \"\(session.workflow.name)\"...")
                        .font(.subheadline).bold()
                    Text(summary)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    session.isPaused ? session.resume() : session.pause()
                } label: {
                    Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered).controlSize(.small)
                Button(role: .destructive) { engine.stop(session) } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered).tint(Color.canopyRust).controlSize(.small)
            }

            ProgressView(value: Double(session.completedStepCount), total: Double(max(session.stepRuns.count, 1)))
                .tint(Color.canopySage)

            // Re-evaluated every second so elapsed times and Wait-step
            // progress keep moving even when no other state changes.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.stepRuns.enumerated()), id: \.element.id) { index, run in
                        StepRunRow(
                            index: index + 1,
                            run: run,
                            isLast: index == session.stepRuns.count - 1,
                            progress: session.progress(for: run),
                            detail: session.detail(for: run),
                            isPaused: session.isPaused,
                            now: timeline.date
                        )
                    }
                }
            }

            if let lastLine = session.lines.last {
                Text(lastLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let step = session.pendingConfirmationStep {
                confirmationPrompt(for: step)
            }
        }
        .padding()
    }

    private var summary: String {
        let total = session.stepRuns.count
        guard let current = session.currentStepIndex else {
            return "\(session.completedStepCount) of \(total) steps complete"
        }
        return "Step \(current + 1) of \(total) · \(session.stepRuns[current].step.action.shortLabel)"
    }

    private func confirmationPrompt(for step: WorkflowStep) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Confirm \"\(step.kind.title)\"?").font(.subheadline).bold()
                Text(step.action.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Stop") { session.resolveConfirmation(proceed: false) }
                .buttonStyle(.canopySecondary).controlSize(.small)
            Button("Continue") { session.resolveConfirmation(proceed: true) }
                .buttonStyle(.canopyPrimary).controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Step Run Row

/// One step in the running-workflow timeline: status marker on a connecting
/// line, the step's name, and — while active — a progress bar and detail.
private struct StepRunRow: View {
    let index: Int
    let run: WorkflowRunSession.StepRun
    let isLast: Bool
    let progress: Double?
    let detail: String?
    let isPaused: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                marker.frame(width: 22, height: 22)
                if !isLast {
                    Rectangle()
                        .fill(run.status == .done ? Color.canopySage.opacity(0.5) : Color.canopyRule)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: run.step.kind.icon)
                        .font(.caption)
                        .foregroundStyle(run.step.kind.color)
                    Text("\(index). \(run.step.action.shortLabel)")
                        .font(.subheadline.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(isDimmed ? .secondary : Color.canopyInk)
                    Spacer()
                    Text(trailingText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(run.errors > 0 ? Color.canopyRust : .secondary)
                }

                if run.status == .running {
                    if let progress {
                        ProgressView(value: progress).tint(Color.canopySage)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                if run.status == .awaitingConfirmation {
                    Text("Waiting for your confirmation")
                        .font(.caption).foregroundStyle(.orange)
                } else if isActive, let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
    }

    private var isActive: Bool { run.status == .running || run.status == .awaitingConfirmation }
    private var isDimmed: Bool { run.status == .pending || run.status == .skipped || run.status == .cancelled }

    @ViewBuilder private var marker: some View {
        switch run.status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .awaitingConfirmation:
            Image(systemName: "hand.raised.circle.fill").foregroundStyle(.orange)
        case .running:
            Image(systemName: isPaused ? "pause.circle.fill" : "circle.dotted.circle")
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, isActive: !isPaused)
        case .done:
            Image(systemName: run.errors > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(run.errors > 0 ? Color.canopyRust : Color.canopySage)
        case .skipped:
            Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.tertiary)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.tertiary)
        }
    }

    private var trailingText: String {
        switch run.status {
        case .pending:  return "Queued"
        case .skipped:  return "Skipped"
        case .cancelled: return "Stopped"
        case .awaitingConfirmation: return "Paused"
        case .running:
            let elapsed = Self.format(now.timeIntervalSince(run.startedAt ?? now))
            if let progress { return "\(Int(progress * 100))% · \(elapsed)" }
            return elapsed
        case .done:
            let elapsed = Self.format((run.finishedAt ?? now).timeIntervalSince(run.startedAt ?? now))
            return run.errors > 0 ? "\(run.errors) error\(run.errors == 1 ? "" : "s") · \(elapsed)" : elapsed
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
