import SwiftUI

/// The Workflows part of the menu bar: what is running (with a Stop for each), what ran last, a way to run any
/// workflow, and a way to the full list in Settings.
struct WorkflowMenuSection: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var engine = WorkflowEngine.shared
    @ObservedObject private var checkpoints = WorkflowCheckpointStore.shared
    @Environment(\.openWindow) private var openWindow

    private var inProgress: [WorkflowRunSession] {
        appState.activeRuns.filter { !$0.isFinished }
    }

    private var runnable: [Workflow] {
        appState.workflows.filter { !$0.steps.isEmpty }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        // One line per run in progress, since several can be going at once.
        if inProgress.isEmpty {
            if let errored = appState.activeRuns.first(where: { $0.mountError != nil }) {
                Label(errored.mountError ?? "Couldn't reach storage", systemImage: "exclamationmark.triangle.fill")
            } else if let last = appState.workflowRunHistory.first {
                Text("Last workflow: \(last.workflowName) · \(last.finishedAt.formatted(.relative(presentation: .named)))")
            } else {
                Text("No workflows have run yet")
            }
        } else {
            ForEach(inProgress) { session in
                let active = session.tasks.filter { $0.phase != .done && $0.phase != .error }.count
                let done = session.tasks.filter { $0.phase == .done }.count
                let percent = session.tasks.isEmpty ? 0 : Int((Double(done) / Double(session.tasks.count) * 100).rounded())
                Text("\(session.workflow.name) — \(percent)% · \(done) done, \(active) active")
                Button("Stop “\(session.workflow.name)”", systemImage: "stop.fill", role: .destructive) { engine.stop(session) }
            }
            if inProgress.count > 1 {
                Button("Stop All Workflows", systemImage: "stop.fill", role: .destructive) { engine.stop() }
            }
        }

        // A run a crash or power cut cut short. Never resumed automatically: a deck may have been recording or
        // reconnected differently since, and re-running steps like Format or Control HyperDeck is a person's call.
        ForEach(checkpoints.interrupted) { checkpoint in
            let total = checkpoint.workflow.steps.count
            Label("“\(checkpoint.workflow.name)” was interrupted at step \(checkpoint.nextStepIndex + 1) of \(total)", systemImage: "exclamationmark.arrow.circlepath")
            Button("Resume “\(checkpoint.workflow.name)”", systemImage: "arrow.counterclockwise") { Task { await engine.resume(checkpoint) } }
                .disabled(!engine.canResume(checkpoint))
            Button("Discard It", systemImage: "trash") { checkpoints.discard(id: checkpoint.id) }
        }

        if !appState.failedTasks.isEmpty {
            Button("Retry \(appState.failedTasks.count) Failed", systemImage: "arrow.counterclockwise") {
                Task { await engine.retryFailed() }
            }
        }

        Menu("Run Workflow") {
            ForEach(runnable) { workflow in
                Button(workflow.name) { Task { await engine.runFromUI(workflow) } }
                    .disabled(!appState.canRun(workflow))
            }
        }
        .disabled(runnable.isEmpty)

        ForEach(appState.workflows.filter { $0.isScheduled }) { workflow in
            ForEach(workflow.activeTriggers) { trigger in
                Label("\(workflow.name) · \(trigger.displaySummary)", systemImage: trigger.mode.icon)
            }
        }

        Button(appState.workflows.isEmpty ? "Create a Workflow…" : "Workflows…") {
            SettingsTab.workflows.open(with: openWindow)
        }
    }
}
