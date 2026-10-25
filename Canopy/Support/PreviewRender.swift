import AppKit
import SwiftUI

/// Dev tool, used with `--ui-preview --render=<dir>`: draws the Settings pages and the Workflows part of the
/// menu to PNG files and quits, so they can be looked at without a screen, the menu bar or any permissions.
/// Fills in a few made-up devices and workflows first, in the preview copy's own settings.
@MainActor
enum PreviewRender {
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        seed()
        let model = AppModel()

        let only = CommandLine.arguments.compactMap { $0.hasPrefix("--only=") ? String($0.dropFirst(7)) : nil }.first
        let size = CGSize(width: 920, height: 640)
        let pages: [(String, AnyView)] = [
            ("transcription", AnyView(ScrollView { TranscriberSettingsView(model: model) })),
            ("workflows", AnyView(WorkflowsView())),
            ("history", AnyView(HistoryView())),
            ("devices", AnyView(DevicesSettingsView())),
            ("more", AnyView(MoreSettingsView())),
            ("tabs", AnyView(SettingsRoot(model: model))),
            // The menu itself is drawn by macOS, so this shows its contents in a plain column.
            ("menu", AnyView(VStack(alignment: .leading, spacing: 6) { WorkflowMenuSection() }.padding(14).frame(width: 340).background(Color(nsColor: .windowBackgroundColor)))),
        ]
        for (name, view) in pages where only == nil || only == name {
            snapshot(view, size: name == "menu" ? CGSize(width: 340, height: 360) : size, to: directory.appendingPathComponent("\(name).png"))
        }
        print("rendered to \(directory.path)")
        exit(0)
    }

    private static func seed() {
        let state = AppState.shared
        if state.hyperDecks.isEmpty {
            state.addDeck(HyperDeck(name: "Studio A", ipAddress: "192.168.1.51", remotePath: ""))
            state.addDeck(HyperDeck(name: "Studio B", ipAddress: "192.168.1.52", remotePath: ""))
            state.addCloudStore(CloudStore(name: "Cloud Store", ipAddress: "192.168.1.60", volumeName: "Media"))
            state.addLocalFolder(LocalFolder(name: "Sunday Archive", path: "/Users/Shared"))
        }
        if state.workflows.isEmpty {
            let kinds: [StepKind] = [.sync, .convert, .transcribe, .findClips, .copyTo]
            state.addWorkflow(Workflow(name: "Sunday offload", steps: kinds.map { WorkflowStep(action: StepAction.defaultAction(for: $0)) }))
            state.addWorkflow(Workflow(name: "Shorts from the message", steps: [.transcribe, .findClips, .exportPosts].map { WorkflowStep(action: StepAction.defaultAction(for: $0)) }))
        }
    }

    private static func snapshot<V: View>(_ view: V, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view.environmentObject(AppState.shared))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI finish its first pass (lists and tab content load lazily).
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
