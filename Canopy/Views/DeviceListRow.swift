import SwiftUI

// MARK: - Status Dot
// A compact stand-in for StatusBadge, sized for a single list row.
struct StatusDot: View {
    let status: DeckStatus

    private var color: Color {
        switch status {
        case .online:                          .green
        case .offline, .noMedia:               .red
        case .unauthorized, .pathNotFound,
             .transcoding:                     .orange
        case .syncing:                         .blue
        case .unknown:                         .gray
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

// MARK: - HyperDeck Row

struct DeckListRow: View {
    let deck: HyperDeck
    @EnvironmentObject var appState: AppState
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @State private var showingSettings = false

    private var status: DeckStatus { monitor.status(for: deck.ipAddress) }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(deck.name).font(.body)
                Text(deck.ipAddress).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Device Settings")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                Task { await monitor.pingNow(deck: deck) }
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                appState.deleteDeck(id: deck.id)
            } label: {
                Label("Delete Device", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showingSettings) {
            DeckEditSheet(deck: deck)
        }
    }
}

// MARK: - Cloud Store Row

struct CloudStoreListRow: View {
    let store: CloudStore
    @EnvironmentObject var appState: AppState
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @State private var showingSettings = false

    private var status: DeckStatus { monitor.status(for: store.ipAddress) }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.name).font(.body)
                Text(store.ipAddress).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Device Settings")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                Task { await monitor.pingNow(store: store) }
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                appState.deleteCloudStore(id: store.id)
            } label: {
                Label("Delete Device", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showingSettings) {
            CloudStoreEditSheet(store: store)
        }
    }
}

// MARK: - Local Folder Row
// No network status to poll — a folder is either there or it isn't, checked
// straight off the filesystem.

struct LocalFolderListRow: View {
    let folder: LocalFolder
    @EnvironmentObject var appState: AppState
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(folder.exists ? Color.green : Color.red).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.body)
                Text(folder.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Device Settings")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(role: .destructive) {
                appState.deleteLocalFolder(id: folder.id)
            } label: {
                Label("Delete Device", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showingSettings) {
            LocalFolderEditSheet(folder: folder)
        }
    }
}
