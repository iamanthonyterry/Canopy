import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var workflowEngine = WorkflowEngine.shared

    private var inProgress: [WorkflowRunSession] {
        appState.activeRuns.filter { !$0.isFinished }
    }

    var body: some View {
        // Status — one line per run currently in progress, since several
        // can be going at once.
        if inProgress.isEmpty {
            let last = appState.workflowRunHistory.first
            if let errored = appState.activeRuns.first(where: { $0.mountError != nil }) {
                Label(errored.mountError ?? "Mount error", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if let last {
                Text("Last run: \(last.workflowName) · \(last.finishedAt.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(.secondary)
            } else {
                Text("No runs yet").foregroundStyle(.secondary)
            }
        } else {
            ForEach(inProgress) { session in
                let active = session.tasks.filter { $0.phase != .done && $0.phase != .error }.count
                let done   = session.tasks.filter { $0.phase == .done }.count
                Text("\(session.workflow.name) — \(done) done, \(active) active")
                    .foregroundStyle(.secondary)
            }
            if let earliest = inProgress.map(\.startedAt).min() {
                ElapsedTimeView(startTime: earliest, compact: true)
                    .padding(.horizontal, 8)
            }
        }

        if appState.isAdmin {
            Divider()

            if !inProgress.isEmpty {
                Button(role: .destructive) {
                    workflowEngine.stop()
                } label: {
                    Label("Stop All Workflows", systemImage: "stop.fill")
                }
            }

            let runnable = appState.workflows.filter { !$0.steps.isEmpty }
            if runnable.isEmpty {
                if inProgress.isEmpty {
                    Text("No workflows — create one in the app")
                        .foregroundStyle(.secondary)
                }
            } else {
                Menu("Run Workflow") {
                    ForEach(runnable.sorted { $0.sortOrder < $1.sortOrder }) { workflow in
                        Button(workflow.name) {
                            Task { await workflowEngine.run(workflow) }
                        }
                        .disabled(!appState.canRun(workflow))
                    }
                }
            }

            Divider()

            // Schedule status
            let scheduled = appState.workflows.filter { $0.isScheduled }
            if !scheduled.isEmpty {
                ForEach(scheduled) { workflow in
                    ForEach(workflow.activeTriggers) { trigger in
                        Label(
                            "\(workflow.name) at \(trigger.mode == .oneTime ? trigger.displayOneTimeDate : trigger.displayTime)",
                            systemImage: "clock"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }

        Divider()

        Button("Show App") {
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
