import AppKit

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
