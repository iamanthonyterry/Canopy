import SwiftUI

// MARK: - Device Source
// Identifies which underlying device a browsable file tree belongs to, so
// download/mount and video preview logic can pick the right protocol.
enum DeviceSource: Identifiable, Hashable, Equatable {
    case hyperDeck(HyperDeck)
    case cloudStore(CloudStore)

    var id: String {
        switch self {
        case .hyperDeck(let d):  return "deck-\(d.id)"
        case .cloudStore(let s): return "store-\(s.id)"
        }
    }

    var supportsFileBrowsing: Bool {
        switch self {
        case .hyperDeck, .cloudStore: return true
        }
    }

    static func == (lhs: DeviceSource, rhs: DeviceSource) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - File Node

struct FileNode: Identifiable {
    let id: String
    let name: String
    let url: URL?           // local URL (Cloud Store); nil for FTP nodes
    let ftpPath: String?    // relative FTP path; nil for local nodes
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    var children: [FileNode]?
    var isExpanded: Bool = false

    var sizeFormatted: String {
        isDirectory ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var icon: String {
        if isDirectory { return "folder.fill" }
        let ext = (ftpPath ?? url?.lastPathComponent ?? name)
            .components(separatedBy: ".").last?.lowercased() ?? ""
        switch ext {
        case "mp4", "mov", "mxf", "m2ts": return "film.fill"
        case "mp3", "wav", "aac", "aif":  return "music.note"
        case "pdf":                        return "doc.fill"
        case "jpg", "jpeg", "png", "tiff": return "photo.fill"
        default:                           return "doc"
        }
    }

    var iconColor: Color {
        if isDirectory { return .blue }
        let ext = (ftpPath ?? url?.lastPathComponent ?? name)
            .components(separatedBy: ".").last?.lowercased() ?? ""
        switch ext {
        case "mp4", "mov", "mxf", "m2ts": return .purple
        case "mp3", "wav", "aac", "aif":  return .pink
        case "pdf":                        return .red
        case "jpg", "jpeg", "png", "tiff": return .green
        default:                           return .secondary
        }
    }

    var isVideo: Bool {
        guard !isDirectory else { return false }
        let ext = (ftpPath ?? url?.lastPathComponent ?? name)
            .components(separatedBy: ".").last?.lowercased() ?? ""
        return ["mp4", "mov", "mxf", "m2ts"].contains(ext)
    }
}

// Identifiable wrapper so the video player can be driven by .sheet(item:) —
// it needs both the file and which device it came from (local vs. FTP).
struct PlaybackTarget: Identifiable {
    let node: FileNode
    let device: DeviceSource
    var id: String { node.id }
}

// MARK: - Device Files Browser
// The file content + controls for a single device: shown on the right side
// of the dashboard for whichever HyperDeck or Cloud Store is selected.
// Search, sort, expand folders, and preview video — all scoped to `device`.

struct DeviceFilesBrowser: View {
    let device: DeviceSource

    @State private var rootNodes: [FileNode] = []
    @State private var isLoadingFiles = false
    @State private var loadError: String?
    @State private var selectedFile: FileNode?
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name
    @State private var playbackTarget: PlaybackTarget?
    @State private var storageInfo: StorageInfo?
    @State private var isLoadingStorage = false

    enum SortOrder: String, CaseIterable {
        case name = "Name", size = "Size", modified = "Modified"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if device.supportsFileBrowsing {
                searchBar
                Divider()
            }
            content
        }
        .task(id: device.id) {
            async let storage: () = loadStorageInfo()
            loadFiles()
            await storage
        }
        .sheet(item: $playbackTarget) { target in
            VideoPlayerSheet(node: target.node, device: target.device)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Files").font(.headline)
            if device.supportsFileBrowsing {
                StorageSummaryView(info: storageInfo, isLoading: isLoadingStorage)
            }
            Spacer()
            if device.supportsFileBrowsing {
                HStack(spacing: 0) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        SortOrderButton(order: order, selected: sortOrder == order) {
                            sortOrder = order
                        }
                    }
                }
                Button {
                    loadFiles()
                    refreshStorageInfo()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoadingFiles)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search files…", text: $searchText).textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if !device.supportsFileBrowsing {
            noFilesState
        } else if isLoadingFiles {
            VStack { Spacer(); ProgressView("Loading files…"); Spacer() }
        } else if let error = loadError {
            errorState(message: error)
        } else if rootNodes.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.secondary)
                Text("No files found").foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredNodes) { node in
                        FileNodeView(
                            node: node, depth: 0, selectedFile: $selectedFile,
                            onToggle: toggleNode,
                            onPlay: { selected in
                                playbackTarget = PlaybackTarget(node: selected, device: device)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var noFilesState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "externaldrive").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("This device type doesn't expose a file system.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.red)
            Text("Could not load files").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Retry", action: loadFiles).buttonStyle(.bordered)
            Spacer()
        }
    }

    // MARK: - Filtering / Sorting

    private var filteredNodes: [FileNode] {
        guard !searchText.isEmpty else { return sortedNodes(rootNodes) }
        return flatFilter(rootNodes, query: searchText.lowercased())
    }

    private func sortedNodes(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sortOrder {
            case .name:     return a.name.localizedCompare(b.name) == .orderedAscending
            case .size:     return a.size > b.size
            case .modified: return a.modified > b.modified
            }
        }
    }

    private func flatFilter(_ nodes: [FileNode], query: String) -> [FileNode] {
        var result: [FileNode] = []
        for node in nodes {
            if node.name.lowercased().contains(query) { result.append(node) }
            if let children = node.children { result += flatFilter(children, query: query) }
        }
        return result
    }

    // MARK: - Load Files

    private func loadFiles() {
        guard device.supportsFileBrowsing else { return }
        isLoadingFiles = true
        loadError = nil
        rootNodes = []
        selectedFile = nil

        Task {
            do {
                let nodes = try await fetchNodes(for: device)
                await MainActor.run {
                    rootNodes = nodes
                    isLoadingFiles = false
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoadingFiles = false
                }
            }
        }
    }

    private func fetchNodes(for device: DeviceSource) async throws -> [FileNode] {
        switch device {
        case .hyperDeck(let deck):
            return try await fetchFTPNodes(deck: deck, path: deck.remotePath)
        case .cloudStore(let store):
            let mountPath = try await SMBService.mountAndResolve(
                ip: store.ipAddress,
                volume: store.volumeName,
                username: store.username,
                password: store.password
            )
            return try fetchLocalNodes(at: URL(fileURLWithPath: mountPath))
        }
    }

    // MARK: - FTP (HyperDeck)

    private func fetchFTPNodes(deck: HyperDeck, path: String) async throws -> [FileNode] {
        let listing = await FTPService.listAllFiles(on: deck, path: path)
        return listing.map { entry in
            FileNode(
                id: "\(deck.id)-\(entry.name)",
                name: entry.name,
                url: nil,
                ftpPath: entry.name,
                isDirectory: entry.isDirectory,
                size: entry.size,
                modified: entry.modified,
                children: entry.isDirectory ? nil : []
            )
        }
    }

    // MARK: - Local / SMB (Cloud Store)

    private func fetchLocalNodes(at url: URL) throws -> [FileNode] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        return contents.compactMap { child -> FileNode? in
            let res = try? child.resourceValues(forKeys: Set(keys))
            guard !(res?.isHidden ?? false) else { return nil }
            let isDir = res?.isDirectory ?? false
            return FileNode(
                id: child.path,
                name: child.lastPathComponent,
                url: child,
                ftpPath: nil,
                isDirectory: isDir,
                size: Int64(res?.fileSize ?? 0),
                modified: res?.contentModificationDate ?? .distantPast,
                children: isDir ? nil : []
            )
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Toggle Node (expand/collapse directories)

    private func toggleNode(_ nodeID: String) {
        toggleInTree(&rootNodes, id: nodeID)
    }

    @discardableResult
    private func toggleInTree(_ nodes: inout [FileNode], id: String) -> Bool {
        for i in nodes.indices {
            if nodes[i].id == id {
                if nodes[i].isExpanded {
                    nodes[i].isExpanded = false
                } else {
                    if nodes[i].children == nil {
                        let node = nodes[i]
                        Task {
                            let children = await loadChildren(for: node)
                            await MainActor.run {
                                _ = toggleInTree(&rootNodes, id: id, setChildren: children)
                            }
                        }
                        return true
                    }
                    nodes[i].isExpanded = true
                }
                return true
            }
            if var children = nodes[i].children, toggleInTree(&children, id: id) {
                nodes[i].children = children
                return true
            }
        }
        return false
    }

    @discardableResult
    private func toggleInTree(_ nodes: inout [FileNode], id: String, setChildren: [FileNode]) -> Bool {
        for i in nodes.indices {
            if nodes[i].id == id {
                nodes[i].children = setChildren
                nodes[i].isExpanded = true
                return true
            }
            if var children = nodes[i].children,
               toggleInTree(&children, id: id, setChildren: setChildren) {
                nodes[i].children = children
                return true
            }
        }
        return false
    }

    private func loadChildren(for node: FileNode) async -> [FileNode] {
        switch device {
        case .hyperDeck(let deck):
            guard let path = node.ftpPath else { return [] }
            return (try? await fetchFTPNodes(deck: deck, path: path)) ?? []
        case .cloudStore:
            guard let url = node.url else { return [] }
            return (try? fetchLocalNodes(at: url)) ?? []
        }
    }

    // MARK: - Storage Info

    private func loadStorageInfo() async {
        guard device.supportsFileBrowsing else { return }
        isLoadingStorage = true
        let info = await fetchStorageInfo()
        await MainActor.run {
            isLoadingStorage = false
            storageInfo = info
        }
    }

    private func refreshStorageInfo() {
        storageInfo = nil
        isLoadingStorage = true
        Task {
            let info = await fetchStorageInfo()
            await MainActor.run {
                isLoadingStorage = false
                storageInfo = info
            }
        }
    }

    private func fetchStorageInfo() async -> StorageInfo? {
        switch device {
        case .hyperDeck(let deck):  return await StorageCapacityService.capacity(for: deck)
        case .cloudStore(let store): return try? await StorageCapacityService.capacity(for: store)
        }
    }
}

// MARK: - File Node Row

struct FileNodeView: View {
    let node: FileNode
    let depth: Int
    @Binding var selectedFile: FileNode?
    let onToggle: (String) -> Void
    let onPlay: (FileNode) -> Void

    private var isSelected: Bool { selectedFile?.id == node.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if depth > 0 {
                    Rectangle().fill(Color.clear).frame(width: CGFloat(depth) * 16)
                }
                if node.isDirectory {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                } else {
                    Spacer().frame(width: 12)
                }
                Image(systemName: node.icon)
                    .foregroundStyle(node.iconColor)
                    .frame(width: 18)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if node.isVideo {
                    Button { onPlay(node) } label: {
                        Image(systemName: "play.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.purple)
                    .help("Play")
                }
                if !node.sizeFormatted.isEmpty {
                    Text(node.sizeFormatted)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if node.isDirectory {
                    onToggle(node.id)
                } else {
                    selectedFile = node
                    if node.isVideo { onPlay(node) }
                }
            }
            Divider().padding(.leading, CGFloat(depth) * 16 + 38)
        }
        if node.isExpanded, let children = node.children {
            ForEach(children) { child in
                FileNodeView(
                    node: child, depth: depth + 1, selectedFile: $selectedFile,
                    onToggle: onToggle, onPlay: onPlay
                )
            }
        }
    }
}

// MARK: - Sort Order Button

private struct SortOrderButton: View {
    let order: DeviceFilesBrowser.SortOrder
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(order.rawValue, action: action)
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}


// MARK: - Storage Summary (compact, used in the files browser toolbar)

struct StorageSummaryView: View {
    let info: StorageInfo?
    var isLoading: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if let info {
                if let fraction = info.fraction {
                    Gauge(value: fraction) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .frame(width: 60)
                }
                Text(info.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }
}
