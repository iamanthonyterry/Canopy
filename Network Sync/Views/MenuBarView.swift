import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var workflowEngine = WorkflowEngine.shared

    var body: some View {
        // Status
        if appState.isRunning {
            let active  = appState.activeTasks.filter { $0.phase != .done && $0.phase != .error }.count
            let done    = appState.activeTasks.filter { $0.phase == .done }.count
            Text("Running — \(done) done, \(active) active")
                .foregroundStyle(.secondary)

            if let start = appState.runStartTime {
                ElapsedTimeView(startTime: start, compact: true)
                    .padding(.horizontal, 8)
            }
        } else {
            let last = appState.workflowRunHistory.first
            if let error = appState.mountError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if let last {
                Text("Last run: \(last.workflowName) · \(last.finishedAt.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(.secondary)
            } else {
                Text("No runs yet").foregroundStyle(.secondary)
            }
        }

        Divider()

        if appState.isRunning {
            Button(role: .destructive) {
                workflowEngine.stop()
            } label: {
                Label("Stop Workflow", systemImage: "stop.fill")
            }
        } else {
            let runnable = appState.workflows.filter { !$0.steps.isEmpty }
            if runnable.isEmpty {
                Text("No workflows — create one in the app")
                    .foregroundStyle(.secondary)
            } else {
                Menu("Run Workflow") {
                    ForEach(runnable.sorted { $0.sortOrder < $1.sortOrder }) { workflow in
                        Button(workflow.name) {
                            Task { await workflowEngine.run(workflow) }
                        }
                    }
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

        Divider()

        Button("Show App") {
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
