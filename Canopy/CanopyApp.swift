import ChurchKitCore
import SwiftUI

@main
struct CanopyApp: App {
    @StateObject private var appState  = AppState.shared
    @StateObject private var scheduler = SchedulerService.shared

    init() {
        // Canopy was com.ROSESASHUMANS.Canopy before it joined the Church Landing Page apps. Bring its settings and
        // sign-ins along, before anything reads them.
        LegacyMigration.run(fromBundleID: "com.ROSESASHUMANS.Canopy",
                            keychainServices: [(KeychainStore.legacyService, KeychainStore.service)])
        CanopyFonts.register()
    }

    var body: some Scene {
        Window("Canopy by Roses as Humans", id: "main") {
            ContentView()
                .font(.canopyBody)
                .frame(minWidth: 760, minHeight: 480)
                .environmentObject(appState)
                .onAppear {
                    NotificationService.requestPermission()
                    NotificationMailer.removeLegacyGmailCredentials()
                    // Load any runs a previous launch left unfinished before
                    // anything (e.g. the scheduler) can start a new one.
                    _ = WorkflowCheckpointStore.shared
                    scheduler.sync()
                    ConnectionMonitor.shared.start()
                    AlertingService.shared.start()
                    PeerPresenceService.shared.start()
                    WorkflowRunPublisher.shared.start()
                    WorkflowSyncService.shared.start()
                    RemoteComputersService.shared.start()
                    RemoteControlEngine.shared.applySettings()
                    WorkflowConfirmationPanelController.shared.start(appState: appState)
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

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            MenuBarIcon(isRunning: appState.isRunning)
        }
        .menuBarExtraStyle(.menu)
    }
}
