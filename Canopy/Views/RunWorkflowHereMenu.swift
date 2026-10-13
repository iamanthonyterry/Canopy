import SwiftUI
import AppKit

// MARK: - Run Workflow Here
// Lists every workflow and runs the chosen one against `target` alone —
// whatever devices that workflow is normally set to run on. Used for a
// folder in the file browser, where the folder being looked at is the
// thing to run on.

struct RunWorkflowHereMenu: View {
    let target: WorkflowEngine.WorkflowTargetDevice
    var title = "Run Workflow"

    @ObservedObject private var appState = AppState.shared

    var body: some View {
        Menu {
            ForEach(appState.workflows.sorted { $0.sortOrder < $1.sortOrder }) { workflow in
                Button(workflow.name) {
                    Task { await WorkflowEngine.shared.runDevice(workflow, target: target) }
                }
                .disabled(workflow.steps.isEmpty)
            }
        } label: {
            Label(title, systemImage: "flowchart")
        }
        .disabled(appState.workflows.isEmpty || appState.busyDeckNames.contains(target.name))
    }
}

extension WorkflowEngine {
    /// Run from a button or menu. A workflow with no fixed devices has
    /// nowhere to run until someone says where, so it asks for a folder
    /// first; any other workflow runs on its own devices as usual.
    func runFromUI(_ workflow: Workflow) async {
        guard workflow.choosesFolderAtRun else {
            await run(workflow)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Run Here"
        panel.message = "Choose the folder to run \"\(workflow.name)\" on."
        // The menu bar item can start a run while another app is in front.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await runFolder(workflow, at: url)
    }
}
