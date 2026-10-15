import SwiftUI

struct WorkflowsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var engine = WorkflowEngine.shared

    /// What the full-screen builder is showing, or nil for the workflow list.
    private enum BuilderRoute: Identifiable {
        case new
        case draft(Workflow)
        case edit(Workflow)

        var id: String {
            switch self {
            case .new:            return "new"
            case .draft(let w):   return "draft-\(w.id)"
            case .edit(let w):    return "edit-\(w.id)"
            }
        }
    }

    @State private var builder: BuilderRoute? = nil
    @State private var isDescribing = false
    /// A draft from the assistant sheet waiting to be opened in the builder
    /// once the sheet has finished dismissing.
    @State private var pendingDraft: Workflow? = nil
    @State private var workflowPendingDelete: Workflow? = nil

    private var inProgress: [WorkflowRunSession] {
        appState.activeRuns.filter { !$0.isFinished }
    }

    var body: some View {
        if let route = builder {
            builderView(for: route)
        } else {
            listBody
        }
    }

    @ViewBuilder
    private func builderView(for route: BuilderRoute) -> some View {
        let close = { builder = nil }
        Group {
            switch route {
            case .new:
                WorkflowBuilderView(workflow: nil, onClose: close)
            case .draft(let draft):
                WorkflowBuilderView(workflow: nil, prefill: draft, onClose: close)
            case .edit(let workflow):
                WorkflowBuilderView(workflow: workflow, onClose: close)
            }
        }
        .id(route.id)
    }

    private var listBody: some View {
        VStack(spacing: 0) {
            header
            rule

            RemoteRunsBanner()

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
        .sheet(isPresented: $isDescribing, onDismiss: {
            if let draft = pendingDraft { builder = .draft(draft) }
            pendingDraft = nil
        }) {
            WorkflowAssistantSheet { pendingDraft = $0 }
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
                    .font(.canopySubheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                headerButtons(iconOnly: false)
                headerButtons(iconOnly: true)
            }
        }
        .padding()
    }

    private func headerButtons(iconOnly: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                isDescribing = true
            } label: {
                AdaptiveLabel(title: "Describe It", icon: "sparkles", iconOnly: iconOnly)
            }
            .help("Describe a workflow in plain language")
            Button {
                builder = .new
            } label: {
                AdaptiveLabel(title: "New Workflow", icon: "plus", iconOnly: iconOnly)
            }
            .buttonStyle(.canopyPrimary)
            .help("New Workflow")
        }
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
                builder = .new
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))], spacing: 16) {
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
                    Text(workflow.name).font(.canopyHeadline).lineLimit(2)
                    Text(targetDeviceLabel(workflow))
                        .font(.canopyCaption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if workflow.isScheduled {
                    let active = workflow.activeTriggers
                    let scheduleLabel: String = active.count == 1
                        ? active[0].displaySummary
                        : "\(active.count) triggers"
                    let scheduleIcon = active.count == 1 ? active[0].mode.icon : "bolt"
                    Label(scheduleLabel, systemImage: scheduleIcon)
                        .font(.canopySans(10, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.canopySage.opacity(0.18))
                        .foregroundStyle(Color.canopySage)
                        .clipShape(Capsule())
                }
            }

            Text(workflow.stepsSummary)
                .font(.canopyCaption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let last = lastRun(for: workflow) {
                Text("Last run: \(last.finishedAt.formatted(.relative(presentation: .named))) · \(last.processed) processed, \(last.errors) errors")
                    .font(.canopyCaption2).foregroundStyle(.secondary)
            }

            rule

            HStack {
                Button {
                    builder = .edit(workflow)
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
                        .font(.canopyCaption2).bold()
                        .foregroundStyle(Color.accentColor)
                } else {
                    Button {
                        Task { await engine.runFromUI(workflow) }
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.canopyPrimary)
                    .disabled(!appState.canRun(workflow) || workflow.steps.isEmpty)
                    .help(runBlockedReason(for: workflow) ?? "")
                }
            }
        }
        .canopyCard(cornerRadius: 10)
    }

    // MARK: - Helpers

    /// Tooltip explaining a disabled Run button when the cause is another computer.
    private func runBlockedReason(for workflow: Workflow) -> String? {
        guard let conflict = appState.remoteConflicts(for: workflow).first else { return nil }
        return "\"\(conflict.run.workflowName)\" is already running on \(conflict.computer) using the same devices"
    }

    private func targetDeviceLabel(_ workflow: Workflow) -> String {
        if workflow.choosesFolderAtRun { return "Asks for a folder when run" }
        var names: [String] = []
        let deckSteps = workflow.steps.filter { $0.kind.usesHyperDeck && !$0.decks.isNone }
        if deckSteps.contains(where: { $0.decks == .all }) {
            names.append("All HyperDecks")
        } else {
            names += appState.hyperDecks(for: workflow).map(\.name)
        }
        names += workflow.targets.compactMap { target -> String? in
            switch target {
            case .hyperDeck(let id):   return appState.hyperDecks.first { $0.id == id }?.name
            case .localFolder(let id): return appState.localFolders.first { $0.id == id }?.name
            case .cloudStore(let id, let path):
                guard let store = appState.cloudStores.first(where: { $0.id == id }) else { return nil }
                return path.isEmpty ? store.name : "\(store.name)/\(path)"
            case .folder(_, let name): return name
            }
        }
        return names.isEmpty ? "No device needed" : names.joined(separator: ", ")
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
/// Lists workflows running on other Canopy computers on the network, so it's
/// clear why a Run button is disabled and who to talk to. Hidden when
/// nothing is running elsewhere.
private struct RemoteRunsBanner: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let runs = appState.remoteRuns
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(runs, id: \.run.id) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\"\(item.run.workflowName)\" \(item.run.isPaused ? "paused" : "running") on \(item.computer)")
                                .font(.canopySubheadline).bold()
                            Text("\(item.run.deviceNames.joined(separator: ", ")) · step \(min(item.run.completedSteps + 1, item.run.totalSteps)) of \(item.run.totalSteps)")
                                .font(.canopyCaption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.canopyRust.opacity(0.08))
            Rectangle().fill(Color.canopyRule).frame(height: 1)
        }
    }
}

private struct RunningWorkflowBanner: View {
    @ObservedObject var session: WorkflowRunSession
    let engine: WorkflowEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.isPaused ? "Paused \"\(session.workflow.name)\"" : "Running \"\(session.workflow.name)\"...")
                        .font(.canopySubheadline).bold()
                    Text(summary)
                        .font(.canopyCaption).foregroundStyle(.secondary)
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
                    .font(.canopyMono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // The confirmation prompt itself is shown by the global
            // `WorkflowConfirmationBanner` in ContentView, above the page
            // content — that way it's visible (and answerable) from every
            // tab, not just this one. This banner's own step list still
            // marks the paused step `.awaitingConfirmation` below.
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
                        .font(.canopyCaption)
                        .foregroundStyle(run.step.kind.color)
                    Text("\(index). \(run.step.action.shortLabel)")
                        .font(.canopySubheadline.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(isDimmed ? .secondary : Color.canopyInk)
                    Spacer()
                    Text(trailingText)
                        .font(.canopyCaption.monospacedDigit())
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
                        .font(.canopyCaption).foregroundStyle(.orange)
                } else if isActive, let detail {
                    Text(detail).font(.canopyCaption).foregroundStyle(.secondary)
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
