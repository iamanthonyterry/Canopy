import AppKit
import ChurchKitCore
import SwiftUI

/// Canopy is a menu bar app: it listens to the sound board and sends the transcript to the website, runs voice
/// cues, carries out "apply to device" jobs, and (as the merge goes on) runs workflows in the background.
/// It was two apps; this is the Transcriber's app with Canopy's workflow services started beside it.
@main
struct CanopyApp: App {
    @StateObject private var model = AppModel()

    init() {
        let args = CommandLine.arguments
        if FileTest.isCLITest {
            // Dev/testing: print the phrases in an audio file, or judge its level, then exit. Nothing else starts.
            if let i = args.firstIndex(of: "--transcribe-file"), i + 1 < args.count {
                let v = args.firstIndex(of: "--vocabulary").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                FileTest.run(path: args[i + 1], vocabulary: v ?? "", commands: args.contains("--commands"),
                             model: args.firstIndex(of: "--model").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil })
            }
            if let i = args.firstIndex(of: "--level-check"), i + 1 < args.count {
                FileTest.levelCheck(path: args[i + 1])
            }
            return
        }
        if FileTest.isPreview {
            CanopyFonts.register()
            if let dir = args.compactMap({ $0.hasPrefix("--render=") ? String($0.dropFirst(9)) : nil }).first {
                DispatchQueue.main.async { PreviewRender.run(into: URL(fileURLWithPath: dir, isDirectory: true)) }
            }
            return
        }  // windows and menu only: no migration, no services
        // This app was church.lifepoint.transcriber before it joined the Church Landing Page apps; bring its settings and key along.
        // TODO(merge): Canopy's own settings (workflows, devices) come across from com.rosesashumans.churchlandingpage.canopy
        // on first launch; see the migration step in docs/canopy-merge-plan.md (the marker LegacyMigration writes is per app, not per source).
        LegacyMigration.run(fromBundleID: "church.lifepoint.transcriber", keychainServices: [(Keychain.legacyService, Keychain.currentService)])
        KeychainStore.migrateRenamedService()
        CanopyFonts.register()
        Self.startWorkflowServices()
    }

    /// What Canopy's window used to start when it opened. Now that there is no window, it starts with the app.
    /// Left out on purpose: the peer-presence and other-computers services, which go away in this merge.
    private static func startWorkflowServices() {
        NotificationService.requestPermission()
        // Load any runs a previous launch left unfinished before anything (e.g. the scheduler) can start a new one.
        _ = WorkflowCheckpointStore.shared
        SchedulerService.shared.sync()
        ConnectionMonitor.shared.start()
        AlertingService.shared.start()
        WorkflowRunPublisher.shared.start()
        WorkflowSyncService.shared.start()
        RemoteControlEngine.shared.applySettings()
        WorkflowConfirmationPanelController.shared.start(appState: AppState.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuLabel(tint: model.statusTint)
        }
        .menuBarExtraStyle(.menu)

        Window("Live transcript", id: "transcript") {
            TranscriptView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 380, height: 260)

        Window("Settings", id: "settings") {
            SettingsRoot(model: model)
        }
        .defaultSize(width: 920, height: 680)
    }
}
