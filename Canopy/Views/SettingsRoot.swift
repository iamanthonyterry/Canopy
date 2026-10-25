import SwiftUI

/// The pages of the Settings window. The menu bar opens the window on a chosen page by setting `selected`.
enum SettingsTab: String, CaseIterable {
    case transcription, workflows, devices, more

    static let storageKey = "settings.tab"

    /// Opens the Settings window on this page.
    @MainActor func open(with openWindow: OpenWindowAction) {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Settings: transcription and the website connection, the workflow builder, the devices workflows run on, and
/// the rest of Canopy's options.
struct SettingsRoot: View {
    @ObservedObject var model: AppModel
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.transcription.rawValue

    var body: some View {
        TabView(selection: $tab) {
            Tab("Transcription", systemImage: "waveform", value: SettingsTab.transcription.rawValue) {
                ScrollView { TranscriberSettingsView(model: model) }
            }
            Tab("Workflows", systemImage: "flowchart", value: SettingsTab.workflows.rawValue) {
                WorkflowsPage()
            }
            Tab("Devices", systemImage: "externaldrive.connected.to.line.below", value: SettingsTab.devices.rawValue) {
                DevicesSettingsView()
            }
            Tab("More", systemImage: "slider.horizontal.3", value: SettingsTab.more.rawValue) {
                MoreSettingsView()
            }
        }
        .environmentObject(AppState.shared)
        .frame(minWidth: 860, minHeight: 600)
    }
}

/// The workflow list and builder, with the run history beside it.
struct WorkflowsPage: View {
    private enum Section: String, CaseIterable { case workflows = "Workflows", history = "History" }
    @State private var section = Section.workflows

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 10)
            switch section {
            case .workflows: WorkflowsView()
            case .history: HistoryView()
            }
        }
        .background(Color.canopyPaper)
    }
}

/// Canopy's other options: what the website connection covers, shoot tokens, email, alerts, AI, performance and OSC/MIDI.
struct MoreSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WebsiteCard()
                ShootSettingsView()
                EmailNotificationsView()
                AlertSettingsView()
                PerformanceSettingsView()
                AIModelSettingsView()
                RemoteControlSettingsView()
                Spacer(minLength: 24)
            }
            .padding(.vertical)
        }
        .background(Color.canopyPaper)
    }
}
