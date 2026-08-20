import SwiftUI

@main
struct CanopyApp: App {
    @StateObject private var appState  = AppState.shared
    @StateObject private var scheduler = SchedulerService.shared

    var body: some Scene {
        Window("Canopy by Roses as Humans", id: "main") {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    NotificationService.requestPermission()
                    scheduler.sync()
                    ConnectionMonitor.shared.start()
                    AlertingService.shared.start()
                    RemoteControlEngine.shared.applySettings()
                }
                .onOpenURL { url in
                    GmailAuthService.shared.handleRedirect(url: url)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
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
                                Task { await WorkflowEngine.shared.run(workflow) }
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
