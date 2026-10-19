import SwiftUI
import Network

// MARK: - Status Badge

struct StatusBadge: View {
    let status: DeckStatus

    var body: some View {
        let color: Color = switch status {
            case .online: .canopySage
            case .offline: .canopyRust
            case .unauthorized: .orange
            case .pathNotFound: .orange
            case .noMedia: .canopyRust
            case .syncing: .accentColor
            case .transcoding: .orange
            case .unknown: .gray
        }
        let label: String = switch status {
            case .online: "Online"
            case .offline: "Offline"
            case .unauthorized: "Login Failed"
            case .pathNotFound: "Wrong Path"
            case .noMedia: "No Drive"
            case .syncing: "Syncing"
            case .transcoding: "Converting"
            case .unknown: "Checking…"
        }

        Text(label)
            .font(.canopyCaption).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Cloud Store Content Pane
// The right-hand content for a selected cloud store: live status and its
// file browser. Device settings (name, IP, volume, credentials) live in
// the gear-button sheet on the device row instead of here.

struct CloudStoreContentPane: View {
    let store: CloudStore
    @EnvironmentObject var appState: AppState
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @StateObject private var workflowEngine = WorkflowEngine.shared

    private var liveStatus: DeckStatus { monitor.status(for: store.ipAddress) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DeviceFilesBrowser(device: .cloudStore(store))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.name).font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                    .lineLimit(1).truncationMode(.tail)
                Text(store.ipAddress).font(.canopyCaption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            StatusBadge(status: liveStatus)
            Button {
                Task { await monitor.pingNow(store: store) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            if appState.isAdmin {
                runWorkflowMenu
            }
        }
        .padding()
    }

    /// Runs the chosen workflow against this store's volume root — a
    /// subfolder is run from its own Run Workflow menu in the file browser.
    @ViewBuilder
    private var runWorkflowMenu: some View {
        if !appState.workflows.isEmpty {
            Menu {
                ForEach(appState.workflows.sorted { $0.sortOrder < $1.sortOrder }) { workflow in
                    Button(workflow.name) {
                        Task { await workflowEngine.runDevice(workflow, target: .cloudStore(store, path: "")) }
                    }
                    .disabled(workflow.steps.isEmpty)
                }
            } label: {
                Label("Run Workflow", systemImage: "flowchart")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .buttonStyle(.canopyPrimary)
            .disabled(appState.busyDeckNames.contains(store.name))
        }
    }
}

// MARK: - Local Folder Content Pane
// Same shape as the Cloud Store pane, minus anything network-related — a
// local folder is either there or it isn't, no ping/mount step needed.

struct LocalFolderContentPane: View {
    let folder: LocalFolder
    @EnvironmentObject var appState: AppState
    @StateObject private var workflowEngine = WorkflowEngine.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DeviceFilesBrowser(device: .localFolder(folder))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name).font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                    .lineLimit(1).truncationMode(.tail)
                Text(folder.path).font(.canopyCaption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Label(folder.exists ? "Available" : "Not Found", systemImage: folder.exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.canopyCaption).bold()
                .foregroundStyle(folder.exists ? Color.canopySage : Color.canopyRust)
                .lineLimit(1).fixedSize()
            if appState.isAdmin {
                runWorkflowMenu
            }
        }
        .padding()
    }

    @ViewBuilder
    private var runWorkflowMenu: some View {
        if !appState.workflows.isEmpty {
            Menu {
                ForEach(appState.workflows.sorted { $0.sortOrder < $1.sortOrder }) { workflow in
                    Button(workflow.name) {
                        Task { await workflowEngine.runDevice(workflow, target: .localFolder(folder)) }
                    }
                    .disabled(workflow.steps.isEmpty)
                }
            } label: {
                Label("Run Workflow", systemImage: "flowchart")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .buttonStyle(.canopyPrimary)
            .disabled(!folder.exists || appState.busyDeckNames.contains(folder.name))
        }
    }
}

// MARK: - Discovered Device Row
// Shown in a lightweight list style rather than a card, since these are
// transient, one-tap-to-add entries rather than configured devices.

struct DiscoveredDeviceRow: View {
    let name: String
    let ip: String
    let icon: String
    let onAdd: () -> Void
    /// Existing inventory items this could be, and what to do when one is picked. Omitted for things that can't be linked.
    var linkChoices: [(id: String, name: String)] = []
    var onLink: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.canopyHeadline)
                Text(ip).font(.canopyCaption).foregroundStyle(.secondary)
            }
            Spacer()
            if let onLink, !linkChoices.isEmpty {
                Menu("Link to…") {
                    ForEach(linkChoices, id: \.id) { c in Button(c.name) { onLink(c.id) } }
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                .help("Use an item already in the inventory instead of adding a new one")
            }
            Button("Add") { onAdd() }.buttonStyle(.canopySecondary).controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
