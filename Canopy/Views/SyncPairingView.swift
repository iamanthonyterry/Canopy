import SwiftUI
import Combine

// MARK: - SyncPairingView
// Side-by-side panel: HyperDeck drives (left) ↔ Cloud Store folders (right)
// with a dropdown to pick the destination folder for each drive.

struct SyncPairingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left — Record Drives
            DriveListPanel()
                .frame(maxWidth: .infinity)

            Divider()

            // Right — Cloud Store
            CloudStorePanel()
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - DriveListPanel

private struct DriveListPanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(
                title: "Record Drives",
                icon: "externaldrive.fill",
                count: appState.hyperDecks.count,
                tint: .blue
            )
            Divider()

            if appState.hyperDecks.isEmpty {
                emptyNotice("No HyperDecks configured", icon: "externaldrive")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(appState.hyperDecks) { deck in
                            DriveRow(deck: deck)
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

// MARK: - CloudStorePanel

private struct CloudStorePanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(
                title: "Cloud Store",
                icon: "server.rack",
                count: appState.cloudStores.count,
                tint: .purple
            )
            Divider()

            if appState.cloudStores.isEmpty {
                emptyNotice("No Cloud Stores configured", icon: "server.rack")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(appState.cloudStores) { store in
                            CloudStorePairingRow(store: store)
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

// MARK: - DriveRow

private struct DriveRow: View {
    let deck: HyperDeck
    @EnvironmentObject var appState: AppState
    @ObservedObject private var monitor = ConnectionMonitor.shared

    private var pingStatus: DeckStatus { monitor.status(for: deck.ipAddress) }
    @State private var selectedStoreID: UUID? = nil
    @State private var rootNodes: [FolderNode] = []
    @State private var isLoadingFolders = false
    @State private var selectedNode: FolderNode? = nil
    @State private var folderLoadError: String? = nil

    private var selectedStore: CloudStore? {
        appState.cloudStores.first { $0.id == selectedStoreID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Drive identity
            HStack(spacing: 10) {
                driveIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.name).font(.headline)
                    Text(deck.ipAddress).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(pingStatus)
            }

            if !appState.cloudStores.isEmpty {
                Divider()
                destinationPicker
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onAppear { monitor.start() }
        .onChange(of: selectedStoreID) { _, _ in loadFolders() }
    }

    // MARK: Drive icon
    private var driveIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.12))
                .frame(width: 42, height: 42)
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 18))
                .foregroundStyle(.blue)
        }
    }

    // MARK: Destination picker
    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sync to", systemImage: "arrow.right.circle")
                .font(.caption).foregroundStyle(.secondary)

            // Cloud store selector
            Picker("Cloud Store", selection: $selectedStoreID) {
                Text("Choose a Cloud Store…").tag(UUID?.none)
                ForEach(appState.cloudStores) { store in
                    Text(store.name).tag(UUID?.some(store.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            // Folder tree (appears once a store is chosen)
            if selectedStoreID != nil {
                if isLoadingFolders {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Loading folders…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let error = folderLoadError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                } else if rootNodes.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.questionmark").foregroundStyle(.secondary)
                        Text("No folders found").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        SelectableFolderTreeView(
                            nodes: rootNodes,
                            depth: 0,
                            selectedNode: $selectedNode
                        )
                    }
                    .padding(6)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    .frame(maxHeight: 200)
                }

                // Selection confirmation
                if let node = selectedNode, let store = selectedStore {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("→ \(store.name) / \(node.name)")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: Helpers
    private func loadFolders() {
        rootNodes = []
        selectedNode = nil
        folderLoadError = nil
        guard let store = selectedStore else { return }
        isLoadingFolders = true
        Task {
            do {
                let mountPath = try await SMBService.mount(store: store)
                let mountURL = URL(fileURLWithPath: mountPath)
                let items = (try? FileManager.default.contentsOfDirectory(
                    at: mountURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                let folderURLs = items
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending }
                await MainActor.run {
                    self.rootNodes = folderURLs.map { FolderNode(url: $0) }
                    self.isLoadingFolders = false
                }
            } catch {
                await MainActor.run {
                    self.folderLoadError = error.localizedDescription
                    self.isLoadingFolders = false
                }
            }
        }
    }
}

// MARK: - FolderNode (recursive tree)

private final class FolderNode: Identifiable, ObservableObject {
    let id: String          // full path on disk
    let name: String
    let url: URL
    @Published var children: [FolderNode]?  // nil = not yet loaded
    @Published var isExpanded = false
    @Published var isLoading = false

    init(url: URL) {
        self.url  = url
        self.name = url.lastPathComponent
        self.id   = url.path
    }

    func loadChildrenIfNeeded() {
        guard children == nil, !isLoading else { return }
        isLoading = true
        let fm = FileManager.default
        let url = self.url
        Task.detached(priority: .userInitiated) {
            let items = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let folderURLs = items
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending }
            await MainActor.run {
                self.children = folderURLs.map { FolderNode(url: $0) }
                self.isLoading = false
            }
        }
    }
}

// MARK: - FolderTreeView

private struct FolderTreeView: View {
    let nodes: [FolderNode]
    let depth: Int

    var body: some View {
        ForEach(nodes) { node in
            FolderTreeRow(node: node, depth: depth)
        }
    }
}

private struct FolderTreeRow: View {
    @ObservedObject var node: FolderNode
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Row
            HStack(spacing: 4) {
                // Indent
                Spacer().frame(width: CGFloat(depth) * 14)

                // Chevron / spinner
                Group {
                    if node.isLoading {
                        ProgressView().controlSize(.mini).frame(width: 12)
                    } else if node.children?.isEmpty == false || node.children == nil {
                        Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                    } else {
                        Spacer().frame(width: 12)
                    }
                }

                Image(systemName: node.isExpanded ? "folder.fill" : "folder")
                    .font(.caption)
                    .foregroundStyle(.purple)

                Text(node.name)
                    .font(.caption)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                node.loadChildrenIfNeeded()
                withAnimation(.easeInOut(duration: 0.15)) {
                    node.isExpanded.toggle()
                }
            }

            // Children
            if node.isExpanded, let children = node.children {
                FolderTreeView(nodes: children, depth: depth + 1)
            }
        }
    }
}

// MARK: - SelectableFolderTreeView (for DriveRow destination picking)

private struct SelectableFolderTreeView: View {
    let nodes: [FolderNode]
    let depth: Int
    @Binding var selectedNode: FolderNode?

    var body: some View {
        ForEach(nodes) { node in
            SelectableFolderTreeRow(node: node, depth: depth, selectedNode: $selectedNode)
        }
    }
}

private struct SelectableFolderTreeRow: View {
    @ObservedObject var node: FolderNode
    let depth: Int
    @Binding var selectedNode: FolderNode?

    private var isSelected: Bool { selectedNode?.id == node.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Spacer().frame(width: CGFloat(depth) * 14)

                // Chevron / spinner
                Group {
                    if node.isLoading {
                        ProgressView().controlSize(.mini).frame(width: 12)
                    } else if node.children?.isEmpty == false || node.children == nil {
                        Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                            .onTapGesture {
                                node.loadChildrenIfNeeded()
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    node.isExpanded.toggle()
                                }
                            }
                    } else {
                        Spacer().frame(width: 12)
                    }
                }

                Image(systemName: node.isExpanded ? "folder.fill" : "folder")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white : .blue)

                Text(node.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(isSelected ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture {
                // Single tap selects; also expand if it has children
                selectedNode = node
                node.loadChildrenIfNeeded()
                if node.children?.isEmpty == false || node.children == nil {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        node.isExpanded = true
                    }
                }
            }

            if node.isExpanded, let children = node.children {
                SelectableFolderTreeView(nodes: children, depth: depth + 1, selectedNode: $selectedNode)
            }
        }
    }
}

// MARK: - CloudStorePairingRow

private struct CloudStorePairingRow: View {
    let store: CloudStore
    @EnvironmentObject var appState: AppState
    @ObservedObject private var monitor = ConnectionMonitor.shared

    private var pingStatus: DeckStatus { monitor.status(for: store.ipAddress) }
    @State private var rootNodes: [FolderNode] = []
    @State private var isLoading = false
    @State private var isExpanded = false
    @State private var loadError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                storeIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.name).font(.headline)
                    Text(store.ipAddress).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(pingStatus)
            }

            Divider()

            DisclosureGroup(isExpanded: $isExpanded) {
                if isLoading {
                    HStack {
                        ProgressView().controlSize(.mini)
                        Text("Mounting…").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                } else if let error = loadError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }.padding(.vertical, 4)
                } else if rootNodes.isEmpty {
                    Text("No folders found").font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    FolderTreeView(nodes: rootNodes, depth: 0)
                        .padding(.top, 2)
                }
            } label: {
                Label("Folders", systemImage: "folder")
                    .font(.subheadline).bold()
            }
            .onChange(of: isExpanded) { _, expanded in
                if expanded && rootNodes.isEmpty { loadRootFolders() }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onAppear { monitor.start() }
    }

    private var storeIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.purple.opacity(0.12))
                .frame(width: 42, height: 42)
            Image(systemName: "server.rack")
                .font(.system(size: 18))
                .foregroundStyle(.purple)
        }
    }

    private func loadRootFolders() {
        isLoading = true
        loadError = nil
        Task {
            do {
                let mountPath = try await SMBService.mount(store: store)
                let mountURL = URL(fileURLWithPath: mountPath)
                let fm = FileManager.default
                let items = (try? fm.contentsOfDirectory(
                    at: mountURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                rootNodes = items
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending }
                    .map { FolderNode(url: $0) }
            } catch {
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Shared helpers

private func panelHeader(title: String, icon: String, count: Int, tint: Color) -> some View {
    HStack(spacing: 8) {
        Image(systemName: icon).foregroundStyle(tint)
        Text(title).font(.title3).bold()
        Spacer()
        Text("\(count)").font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.12)).foregroundStyle(tint).clipShape(Capsule())
    }
    .padding(.horizontal).padding(.vertical, 12)
}

private func emptyNotice(_ message: String, icon: String) -> some View {
    VStack(spacing: 10) {
        Spacer()
        Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.secondary)
        Text(message).foregroundStyle(.secondary)
        Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding()
}

@ViewBuilder
private func statusBadge(_ status: DeckStatus) -> some View {
    let (label, color): (String, Color) = switch status {
    case .unknown:      ("Checking", .gray)
    case .online:       ("Online", .green)
    case .offline:      ("Offline", .red)
    case .unauthorized: ("Login Failed", .orange)
    case .pathNotFound: ("Wrong Path", .orange)
    case .noMedia:      ("No Drive", .red)
    case .syncing:      ("Syncing", .blue)
    case .transcoding:  ("Converting", .orange)
    }

    Text(label)
        .font(.system(size: 10, weight: .bold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
}

