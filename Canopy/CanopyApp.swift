import SwiftUI

@main
struct CanopyApp: App {
    @StateObject private var appState  = AppState.shared
    @StateObject private var scheduler = SchedulerService.shared

    var body: some Scene {
        Window("Canopy by Roses as Humans", id: "main") {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
                .environmentObject(appState)
                .onAppear {
                    NotificationService.requestPermission()
                    // Load any runs a previous launch left unfinished before
                    // anything (e.g. the scheduler) can start a new one.
                    _ = WorkflowCheckpointStore.shared
                    scheduler.sync()
                    ConnectionMonitor.shared.start()
                    AlertingService.shared.start()
                    PeerPresenceService.shared.start()
                    RemoteControlEngine.shared.applySettings()
                    WorkflowConfirmationPanelController.shared.start(appState: appState)
                }
                .onOpenURL { url in
                    GmailAuthService.shared.handleRedirect(url: url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdateService.shared.checkForUpdates()
                }
                .disabled(!UpdateService.shared.canCheckForUpdates)
            }
            if appState.isAdmin {
                CommandGroup(after: .appInfo) {
                    let runnable = appState.workflows.filter { !$0.steps.isEmpty }

                    Menu("Run Workflow") {
                        ForEach(runnable.sorted { $0.sortOrder < $1.sortOrder }) { workflow in
                            Button(workflow.name) {
                                Task { await WorkflowEngine.shared.runFromUI(workflow) }
                            }
                            .disabled(!appState.canRun(workflow))
                        }
                    }
                    .disabled(runnable.isEmpty)

                    if appState.isRunning {
                        Button("Stop All Workflows") {
                            WorkflowEngine.shared.stop()
                        }
                        .keyboardShortcut(".", modifiers: .command)
                    }
                }
            }
        }

        MenuBarExtra("Canopy", systemImage: menuBarIcon) {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarIcon: String {
        appState.isRunning
            ? "arrow.triangle.2.circlepath"
            : "externaldrive.connected.to.line.below"
    }
}
