import SwiftUI
import QuickLookThumbnailing

// MARK: - Device Source
// Identifies which underlying device a browsable file tree belongs to, so
// download/mount and video preview logic can pick the right protocol.
enum DeviceSource: Identifiable, Hashable, Equatable {
    case hyperDeck(HyperDeck)
    case cloudStore(CloudStore)
    case localFolder(LocalFolder)

    var id: String {
        switch self {
        case .hyperDeck(let d):    return "deck-\(d.id)"
        case .cloudStore(let s):   return "store-\(s.id)"
        case .localFolder(let f):  return "folder-\(f.id)"
        }
    }

    var supportsFileBrowsing: Bool {
        switch self {
        case .hyperDeck, .cloudStore, .localFolder: return true
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

    @EnvironmentObject private var appState: AppState

    @State private var rootNodes: [FileNode] = []
    @State private var isLoadingFiles = false
    @State private var loadError: String?
    @State private var selectedFile: FileNode?
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name
    @AppStorage("dashboardFilesViewMode") private var viewMode: ViewMode = .list
    @State private var galleryPathIDs: [String] = []
    @State private var playbackTarget: PlaybackTarget?
    @State private var storageInfo: StorageInfo?
    @State private var isLoadingStorage = false

    @StateObject private var exportQueue = ExportQueueManager.shared
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showExportQueue = false

    @State private var deletePending: [FileNode]?
    @State private var showMoveSheet = false
    @State private var moveNodes: [FileNode] = []
    @State private var isProcessingOperation = false
    @State private var operationError: String?

    enum SortOrder: String, CaseIterable {
        case name = "Name", size = "Size", modified = "Modified"
    }

    enum ViewMode: String {
        case list, gallery
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
        .sheet(isPresented: $showExportQueue) {
            ExportQueueView()
        }
        .sheet(isPresented: $showMoveSheet) {
            DeviceFolderPickerSheet(device: device) { destination in
                moveSelection(moveNodes, to: destination)
            }
        }
        .alert(
            deletePending.map { "Delete \($0.count) item\($0.count == 1 ? "" : "s")?" } ?? "",
            isPresented: Binding(get: { deletePending != nil }, set: { if !$0 { deletePending = nil } })
        ) {
            Button("Cancel", role: .cancel) { deletePending = nil }
            Button("Delete", role: .destructive) {
                if let nodes = deletePending { deleteSelection(nodes) }
                deletePending = nil
            }
        } message: {
            Text("This can't be undone.")
        }
        .alert(
            "Couldn't complete operation",
            isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })
        ) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "")
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
                if isSelecting {
                    Text(selectedIDs.isEmpty ? "Select files…" : "\(selectedIDs.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                    if isProcessingOperation {
                        ProgressView().controlSize(.small)
                    }
                    if appState.isAdmin {
                        Button("Move…") {
                            moveNodes = selectedNodes()
                            showMoveSheet = true
                        }
                        .controlSize(.small)
                        .disabled(selectedIDs.isEmpty || isProcessingOperation)
                        Button("Delete", role: .destructive) {
                            deletePending = selectedNodes()
                        }
                        .controlSize(.small)
                        .tint(.red)
                        .disabled(selectedIDs.isEmpty || isProcessingOperation)
                    }
                    Button("Add to Queue") { addSelectionToQueue() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(selectedIDs.isEmpty)
                    Button("Cancel") { isSelecting = false; selectedIDs.removeAll() }
                        .controlSize(.small)
                } else {
                    HStack(spacing: 0) {
                        ViewModeButton(icon: "list.bullet", selected: viewMode == .list) {
                            viewMode = .list
                        }
                        ViewModeButton(icon: "square.grid.2x2", selected: viewMode == .gallery) {
                            viewMode = .gallery
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            SortOrderButton(order: order, selected: sortOrder == order) {
                                sortOrder = order
                            }
                        }
                    }
                    Button("Select") { isSelecting = true }
                        .buttonStyle(.borderless)
                    Button {
                        loadFiles()
                        refreshStorageInfo()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoadingFiles)
                }

                Button {
                    showExportQueue = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "square.and.arrow.up.on.square")
                        if exportQueue.activeCount > 0 {
                            Text("\(exportQueue.activeCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Color.accentColor, in: Circle())
                                .offset(x: 8, y: -8)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .help("Export Queue")
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
            switch viewMode {
            case .list: listContent
            case .gallery: galleryContent
            }
        }
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredNodes) { node in
                    FileNodeView(
                        node: node, depth: 0, selectedFile: $selectedFile,
                        onToggle: toggleNode,
                        onPlay: { selected in
                            playbackTarget = PlaybackTarget(node: selected, device: device)
                        },
                        isSelecting: isSelecting,
                        selectedIDs: $selectedIDs,
                        canManage: appState.isAdmin,
                        onDeleteRequest: { deletePending = [$0] },
                        onMoveRequest: { target in
                            moveNodes = [target]
                            showMoveSheet = true
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Gallery view
    // A grid of thumbnails scoped to one folder at a time (rather than the
    // list's inline tree), with a breadcrumb bar for drilling in and out.

    private var galleryNodes: [FileNode] {
        guard searchText.isEmpty else { return filteredNodes }
        if let current = galleryCurrentNode {
            return sortedNodes(current.children ?? [])
        }
        return sortedNodes(rootNodes)
    }

    private var galleryCurrentNode: FileNode? {
        guard let id = galleryPathIDs.last else { return nil }
        return findNode(id: id, in: rootNodes)
    }

    private func findNode(id: String, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children, let found = findNode(id: id, in: children) { return found }
        }
        return nil
    }

    private func navigateGallery(into node: FileNode) {
        guard node.isDirectory else { return }
        galleryPathIDs.append(node.id)
        guard node.children == nil else { return }
        Task {
            let children = await loadChildren(for: node)
            await MainActor.run {
                _ = toggleInTree(&rootNodes, id: node.id, setChildren: children)
            }
        }
    }

    private var galleryContent: some View {
        VStack(spacing: 0) {
            if searchText.isEmpty {
                galleryBreadcrumbBar
                Divider()
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 16)], spacing: 20) {
                    ForEach(galleryNodes) { node in
                        FileGalleryTile(
                            node: node,
                            isSelected: selectedFile?.id == node.id,
                            isSelecting: isSelecting,
                            isChecked: selectedIDs.contains(node.id),
                            canManage: appState.isAdmin,
                            onOpen: {
                                if isSelecting {
                                    if selectedIDs.contains(node.id) { selectedIDs.remove(node.id) }
                                    else { selectedIDs.insert(node.id) }
                                } else if node.isDirectory {
                                    navigateGallery(into: node)
                                } else {
                                    selectedFile = node
                                    if node.isVideo {
                                        playbackTarget = PlaybackTarget(node: node, device: device)
                                    }
                                }
                            },
                            onPlay: { playbackTarget = PlaybackTarget(node: node, device: device) },
                            onDeleteRequest: { target in deletePending = [target] },
                            onMoveRequest: { target in moveNodes = [target]; showMoveSheet = true }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private var galleryBreadcrumbBar: some View {
        HStack(spacing: 4) {
            Button {
                galleryPathIDs.removeAll()
            } label: {
                Image(systemName: "house")
            }
            .buttonStyle(.borderless)
            .disabled(galleryPathIDs.isEmpty)

            ForEach(Array(galleryPathIDs.enumerated()), id: \.offset) { index, id in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                if let node = findNode(id: id, in: rootNodes) {
                    Button(node.name) {
                        galleryPathIDs = Array(galleryPathIDs.prefix(index + 1))
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == galleryPathIDs.count - 1)
                }
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
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

    // MARK: - Export Queue

    private func addSelectionToQueue() {
        let nodes = selectedNodes().filter(\.isVideo)
        exportQueue.addMultiple(nodes, device: device)
        isSelecting = false
        selectedIDs.removeAll()
        showExportQueue = true
    }

    private func selectedNodes() -> [FileNode] {
        flatten(rootNodes).filter { selectedIDs.contains($0.id) }
    }

    private func flatten(_ nodes: [FileNode]) -> [FileNode] {
        var result: [FileNode] = []
        for node in nodes {
            result.append(node)
            if let children = node.children { result += flatten(children) }
        }
        return result
    }

    // MARK: - Delete

    private func deleteSelection(_ nodes: [FileNode]) {
        isProcessingOperation = true
        Task {
            var failures: [String] = []
            for node in nodes {
                let success: Bool
                switch device {
                case .hyperDeck(let deck):
                    guard let path = node.ftpPath else { success = false; break }
                    success = await FTPService.deleteEntry(atRelativePath: path, isDirectory: node.isDirectory, on: deck)
                case .cloudStore, .localFolder:
                    guard let url = node.url else { success = false; break }
                    success = (try? FileManager.default.removeItem(at: url)) != nil
                }
                if !success { failures.append(node.name) }
            }
            await MainActor.run {
                isProcessingOperation = false
                isSelecting = false
                selectedIDs.removeAll()
                if !failures.isEmpty {
                    operationError = "Couldn't delete: \(failures.joined(separator: ", "))"
                }
                loadFiles()
                refreshStorageInfo()
            }
        }
    }

    // MARK: - Move

    private func moveSelection(_ nodes: [FileNode], to destination: MoveDestination) {
        isProcessingOperation = true
        Task {
            var failures: [String] = []
            var conflicts: [String] = []
            for node in nodes {
                switch (device, destination) {
                case (.hyperDeck(let deck), .ftpPath(let destPath)):
                    guard let fromPath = node.ftpPath else { failures.append(node.name); continue }
                    let toPath = destPath.isEmpty ? node.name : "\(destPath)/\(node.name)"
                    let existing = await FTPService.listAllFiles(on: deck, path: deck.remotePath.isEmpty ? destPath : "\(deck.remotePath)/\(destPath)")
                    if existing.contains(where: { $0.name == node.name }) {
                        conflicts.append(node.name)
                        continue
                    }
                    let success = await FTPService.moveEntry(fromRelativePath: fromPath, toRelativePath: toPath, on: deck)
                    if !success { failures.append(node.name) }
                case (.cloudStore, .localURL(let destURL)), (.localFolder, .localURL(let destURL)):
                    guard let fromURL = node.url else { failures.append(node.name); continue }
                    let toURL = destURL.appendingPathComponent(node.name)
                    if FileManager.default.fileExists(atPath: toURL.path) {
                        conflicts.append(node.name)
                        continue
                    }
                    do {
                        try FileManager.default.moveItem(at: fromURL, to: toURL)
                    } catch {
                        failures.append(node.name)
                    }
                default:
                    failures.append(node.name)
                }
            }
            await MainActor.run {
                isProcessingOperation = false
                isSelecting = false
                selectedIDs.removeAll()
                moveNodes = []
                var messages: [String] = []
                if !conflicts.isEmpty {
                    messages.append("Already exists at destination, skipped: \(conflicts.joined(separator: ", "))")
                }
                if !failures.isEmpty {
                    messages.append("Couldn't move: \(failures.joined(separator: ", "))")
                }
                if !messages.isEmpty {
                    operationError = messages.joined(separator: "\n")
                }
                loadFiles()
            }
        }
    }

    // MARK: - Load Files

    private func loadFiles() {
        guard device.supportsFileBrowsing else { return }
        isLoadingFiles = true
        loadError = nil
        rootNodes = []
        selectedFile = nil
        galleryPathIDs = []

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
            return try await fetchFTPNodes(deck: deck, relativePath: "")
        case .cloudStore(let store):
            let mountPath = try await SMBService.mountAndResolve(
                ip: store.ipAddress,
                volume: store.volumeName,
                username: store.username,
                password: store.password
            )
            return try fetchLocalNodes(at: URL(fileURLWithPath: mountPath))
        case .localFolder(let folder):
            return try fetchLocalNodes(at: URL(fileURLWithPath: folder.path))
        }
    }

    // MARK: - FTP (HyperDeck)

    /// `relativePath` is the path from `deck.remotePath` down to the directory
    /// being listed ("" at the root). Each returned node's `ftpPath` is the full
    /// relative path from `deck.remotePath` (not just the bare entry name), so
    /// delete/move can target the right file regardless of how deep it is nested.
    private func fetchFTPNodes(deck: HyperDeck, relativePath: String) async throws -> [FileNode] {
        let listPath = relativePath.isEmpty ? deck.remotePath : "\(deck.remotePath)/\(relativePath)"
        let listing = await FTPService.listAllFiles(on: deck, path: listPath)
        return listing.map { entry in
            let entryPath = relativePath.isEmpty ? entry.name : "\(relativePath)/\(entry.name)"
            return FileNode(
                id: "\(deck.id)-\(entryPath)",
                name: entry.name,
                url: nil,
                ftpPath: entryPath,
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
            return (try? await fetchFTPNodes(deck: deck, relativePath: path)) ?? []
        case .cloudStore, .localFolder:
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
        case .hyperDeck(let deck):    return await StorageCapacityService.capacity(for: deck)
        case .cloudStore(let store):  return try? await StorageCapacityService.capacity(for: store)
        case .localFolder(let folder): return try? StorageCapacityService.capacity(forPath: folder.path)
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
    var isSelecting: Bool = false
    var selectedIDs: Binding<Set<String>> = .constant([])
    var canManage: Bool = false
    var onDeleteRequest: (FileNode) -> Void = { _ in }
    var onMoveRequest: (FileNode) -> Void = { _ in }

    private var isSelected: Bool { selectedFile?.id == node.id }
    private var isCheckedForQueue: Bool { selectedIDs.wrappedValue.contains(node.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if depth > 0 {
                    Rectangle().fill(Color.clear).frame(width: CGFloat(depth) * 16)
                }
                if isSelecting {
                    Image(systemName: isCheckedForQueue ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isCheckedForQueue ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                } else if node.isDirectory {
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
                if node.isVideo && !isSelecting {
                    Button { onPlay(node) } label: {
                        Image(systemName: "play.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
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
                if isSelecting {
                    if isCheckedForQueue { selectedIDs.wrappedValue.remove(node.id) }
                    else { selectedIDs.wrappedValue.insert(node.id) }
                } else if node.isDirectory {
                    onToggle(node.id)
                } else {
                    selectedFile = node
                    if node.isVideo { onPlay(node) }
                }
            }
            .contextMenu {
                if !isSelecting && canManage {
                    Button("Move…") { onMoveRequest(node) }
                    Button("Delete", role: .destructive) { onDeleteRequest(node) }
                }
            }
            Divider().padding(.leading, CGFloat(depth) * 16 + 38)
        }
        if node.isExpanded, let children = node.children {
            ForEach(children) { child in
                FileNodeView(
                    node: child, depth: depth + 1, selectedFile: $selectedFile,
                    onToggle: onToggle, onPlay: onPlay,
                    isSelecting: isSelecting, selectedIDs: selectedIDs,
                    canManage: canManage, onDeleteRequest: onDeleteRequest, onMoveRequest: onMoveRequest
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


// MARK: - View Mode Button

private struct ViewModeButton: View {
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Gallery Tile

struct FileGalleryTile: View {
    let node: FileNode
    let isSelected: Bool
    var isSelecting: Bool = false
    var isChecked: Bool = false
    var canManage: Bool = false
    let onOpen: () -> Void
    let onPlay: () -> Void
    var onDeleteRequest: (FileNode) -> Void = { _ in }
    var onMoveRequest: (FileNode) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                FileThumbnailView(node: node)
                    .frame(width: 96, height: 96)

                if isSelecting {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                        .background(Circle().fill(.background))
                        .padding(4)
                } else if node.isVideo {
                    Button(action: onPlay) {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                    .buttonStyle(.borderless)
                    .padding(4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            Text(node.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            if !node.sizeFormatted.isEmpty {
                Text(node.sizeFormatted)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 110)
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            if !isSelecting && canManage {
                Button("Move…") { onMoveRequest(node) }
                Button("Delete", role: .destructive) { onDeleteRequest(node) }
            }
        }
    }
}

// MARK: - File Thumbnail
// Real thumbnails for local files (Cloud Store / Local Folder) via
// QuickLook; HyperDeck (FTP) files have no local URL, so they always
// fall back to the type icon.

struct FileThumbnailView: View {
    let node: FileNode
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: node.icon)
                    .font(.system(size: 32))
                    .foregroundStyle(node.iconColor)
            }
        }
        .task(id: node.id) {
            await loadThumbnail()
        }
    }

    private static let thumbnailableExtensions: Set<String> = [
        "mp4", "mov", "mxf", "m2ts", "jpg", "jpeg", "png", "tiff", "pdf"
    ]

    private func loadThumbnail() async {
        image = nil
        guard !node.isDirectory, let url = node.url else { return }
        guard Self.thumbnailableExtensions.contains(url.pathExtension.lowercased()) else { return }

        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 96, height: 96),
            scale: scale,
            representationTypes: .thumbnail
        )
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            await MainActor.run { image = representation.nsImage }
        }
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
