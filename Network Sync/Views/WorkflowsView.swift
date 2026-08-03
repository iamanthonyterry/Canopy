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
            Divider()

            if !inProgress.isEmpty {
                ForEach(inProgress) { session in
                    runningBanner(session)
                }
                Divider()
            }

            if appState.workflows.isEmpty {
                emptyState
            } else {
                workflowList
            }
        }
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
                Text("Workflows").font(.title2).bold()
                Text("\(appState.workflows.count) workflow\(appState.workflows.count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isCreating = true
            } label: {
                Label("New Workflow", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Running banner (one per active run, live log + its own Stop)

    private func runningBanner(_ session: WorkflowRunSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Running \"\(session.workflow.name)\"...").font(.subheadline).bold()
                Spacer()
                Button(role: .destructive) { engine.stop(session) } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered).tint(.red).controlSize(.small)
            }
            if let lastLine = session.lines.last {
                Text(lastLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding()
    }


    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "flowchart").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No Workflows Yet").font(.title3).bold()
            Text("Build a workflow from steps like Record, Sync, Convert, Rename, Format, and Cleanup — then run it manually or on a schedule.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                isCreating = true
            } label: {
                Label("Create a Workflow", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
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
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
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

            Divider()

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
                        .foregroundStyle(.blue)
                } else {
                    Button {
                        Task { await engine.run(workflow) }
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.canRun(workflow) || workflow.steps.isEmpty)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Helpers

    private func targetDeviceLabel(_ workflow: Workflow) -> String {
        if workflow.targetDeckIDs.isEmpty { return "All devices" }
        let names = appState.hyperDecks
            .filter { workflow.targetDeckIDs.contains($0.id) }
            .map(\.name)
        return names.isEmpty ? "No devices selected" : names.joined(separator: ", ")
    }

    private func lastRun(for workflow: Workflow) -> WorkflowRun? {
        appState.workflowRunHistory.first { $0.workflowName == workflow.name }
    }
}
