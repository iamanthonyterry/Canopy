import SwiftUI
import Network

// MARK: - Status Badge

struct StatusBadge: View {
    let status: DeckStatus

    var body: some View {
        let color: Color = switch status {
            case .online: .green
            case .offline: .red
            case .unauthorized: .orange
            case .pathNotFound: .orange
            case .noMedia: .red
            case .syncing: .blue
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
            .font(.caption).bold()
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
    @ObservedObject private var monitor = ConnectionMonitor.shared

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
                Text(store.name).font(.title3).bold()
                Text(store.ipAddress).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: liveStatus)
            Button {
                Task { await monitor.pingNow(store: store) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding()
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
                Text(folder.name).font(.title3).bold()
                Text(folder.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Label(folder.exists ? "Available" : "Not Found", systemImage: folder.exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption).bold()
                .foregroundStyle(folder.exists ? .green : .red)
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
            .buttonStyle(.borderedProminent)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(ip).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add") { onAdd() }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
