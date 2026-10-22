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

    var name: String {
        switch self {
        case .hyperDeck(let d):   return d.name
        case .cloudStore(let s):  return s.name
        case .localFolder(let f): return f.name
        }
    }

    /// Looks up the live device matching a `DeviceSource.id` string
    /// ("deck-<uuid>" / "store-<uuid>" / "folder-<uuid>") in `appState` —
    /// used to reopen a clip (e.g. from the Starred view) without having
    /// carried the original `DeviceSource` value around.
    static func resolve(id: String, in appState: AppState) -> DeviceSource? {
        if let uuidString = id.dropPrefix("deck-"), let uuid = UUID(uuidString: uuidString) {
            return appState.hyperDecks.first { $0.id == uuid }.map { .hyperDeck($0) }
        }
        if let uuidString = id.dropPrefix("store-"), let uuid = UUID(uuidString: uuidString) {
            return appState.cloudStores.first { $0.id == uuid }.map { .cloudStore($0) }
        }
        if let uuidString = id.dropPrefix("folder-"), let uuid = UUID(uuidString: uuidString) {
            return appState.localFolders.first { $0.id == uuid }.map { .localFolder($0) }
        }
        return nil
    }

    static func == (lhs: DeviceSource, rhs: DeviceSource) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private extension String {
    /// Returns the remainder of the string if it starts with `prefix`, else nil.
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
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

    var isImage: Bool {
        guard !isDirectory else { return false }
        let ext = (ftpPath ?? url?.lastPathComponent ?? name)
            .components(separatedBy: ".").last?.lowercased() ?? ""
        return ["jpg", "jpeg", "png", "tiff", "gif", "heic", "bmp"].contains(ext)
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
    @State private var starredOnly = false
    @ObservedObject private var clipMetadata = ClipMetadataStore.shared
    @AppStorage("dashboardFilesViewMode") private var viewMode: ViewMode = .list
    @State private var galleryPathIDs: [String] = []
    @AppStorage("galleryTileSize") private var tileSize: Double = 96
    @AppStorage("galleryGroupByDay") private var groupByDay = false
    @State private var labelFilter: ClipLabel?
    @State private var keywordTarget: FileNode?
    @State private var keywordDraft = ""
    @State private var playbackTarget: PlaybackTarget?
    @State private var imagePreviewTarget: PlaybackTarget?
    @State private var storageInfo: StorageInfo?
    @State private var isLoadingStorage = false

    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []

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
            Rectangle().fill(Color.canopyRule).frame(height: 1)
            if device.supportsFileBrowsing {
                searchBar
                Rectangle().fill(Color.canopyRule).frame(height: 1)
            }
            content
        }
        .task(id: device.id) {
            async let storage: () = loadStorageInfo()
            loadFiles()
            await storage
        }
        .sheet(item: $playbackTarget) { target in
            VideoPlayerSheet(node: target.node, device: target.device,
                             onNavigate: { stepPreview(from: target.node, by: $0) })
                .id(target.id)
        }
        .sheet(item: $imagePreviewTarget) { target in
            ImagePreviewSheet(node: target.node, device: target.device,
                              onNavigate: { stepPreview(from: target.node, by: $0) })
                .id(target.id)
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
        .alert(
            "Keywords",
            isPresented: Binding(get: { keywordTarget != nil }, set: { if !$0 { keywordTarget = nil } })
        ) {
            TextField("interview, b-roll, hero", text: $keywordDraft)
            Button("Cancel", role: .cancel) { keywordTarget = nil }
            Button("Save") {
                if let target = keywordTarget {
                    clipMetadata.setKeywords(keywordDraft, node: target, device: device)
                }
                keywordTarget = nil
            }
        } message: {
            Text("Comma-separated. Keywords are searchable.")
        }
    }

    private func editKeywords(_ node: FileNode) {
        keywordDraft = clipMetadata.keywords(for: node.id).joined(separator: ", ")
        keywordTarget = node
    }

    // MARK: - Toolbar

    /// How much of the toolbar fits. `ViewThatFits` picks the first tier whose
    /// natural width fits the pane, so controls collapse into icons and menus
    /// instead of wrapping letter-by-letter when the window gets narrow.
    private enum ToolbarDensity { case regular, compact, minimal }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(.regular)
            toolbarRow(.compact)
            toolbarRow(.minimal)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func toolbarRow(_ density: ToolbarDensity) -> some View {
        HStack(spacing: density == .regular ? 12 : 8) {
            if density != .minimal {
                Text("Files").font(.canopyHeadline).lineLimit(1).fixedSize()
            }
            if device.supportsFileBrowsing && density != .minimal {
                StorageSummaryView(info: storageInfo, isLoading: isLoadingStorage,
                                   showsText: density == .regular)
            }
            Spacer(minLength: 0)
            if device.supportsFileBrowsing {
                if isSelecting {
                    selectionControls(density)
                } else {
                    browseControls(density)
                }
            }
        }
    }

    @ViewBuilder
    private func selectionControls(_ density: ToolbarDensity) -> some View {
        let iconOnly = density != .regular
        let count = selectedIDs.count
        if density == .regular {
            Text(count == 0 ? "Select files…" : "\(count) selected")
                .font(.canopyCaption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        } else if count > 0 {
            Text("\(count)").font(.canopyCaption).foregroundStyle(.secondary).fixedSize()
        }
        if isProcessingOperation {
            ProgressView().controlSize(.small)
        }
        if appState.isAdmin {
            Button {
                moveNodes = selectedNodes()
                showMoveSheet = true
            } label: {
                AdaptiveLabel(title: "Move…", icon: "folder", iconOnly: iconOnly)
            }
            .controlSize(.small)
            .disabled(selectedIDs.isEmpty || isProcessingOperation)
            .help("Move Selected")
            Button(role: .destructive) {
                deletePending = selectedNodes()
            } label: {
                AdaptiveLabel(title: "Delete", icon: "trash", iconOnly: iconOnly)
            }
            .controlSize(.small)
            .tint(Color.canopyRust)
            .disabled(selectedIDs.isEmpty || isProcessingOperation)
            .help("Delete Selected")
        }
        Button { isSelecting = false; selectedIDs.removeAll() } label: {
            AdaptiveLabel(title: "Cancel", icon: "xmark", iconOnly: iconOnly)
        }
        .controlSize(.small)
        .help("Cancel Selection")
    }

    @ViewBuilder
    private func browseControls(_ density: ToolbarDensity) -> some View {
        ViewModeButton(icon: starredOnly ? "star.fill" : "star", selected: starredOnly) {
            starredOnly.toggle()
        }
        .help("Starred Only")

        Menu {
            Button {
                labelFilter = nil
            } label: {
                Label("All Labels", systemImage: labelFilter == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(ClipLabel.allCases) { label in
                Button {
                    labelFilter = label
                } label: {
                    Label(label.title, systemImage: labelFilter == label ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(label.color)
                }
            }
        } label: {
            Image(systemName: "tag.fill")
                .foregroundStyle(labelFilter?.color ?? Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by Label")

        HStack(spacing: 0) {
            ViewModeButton(icon: "list.bullet", selected: viewMode == .list) {
                viewMode = .list
            }
            ViewModeButton(icon: "square.grid.2x2", selected: viewMode == .gallery) {
                viewMode = .gallery
            }
        }
        if viewMode == .gallery {
            if density != .minimal {
                ViewModeButton(icon: "calendar", selected: groupByDay) { groupByDay.toggle() }
                    .help("Group by Day")
            }
            if density == .regular {
                Slider(value: $tileSize, in: 80...220)
                    .frame(width: 80)
                    .controlSize(.mini)
                    .help("Thumbnail Size")
            }
        }

        if density == .regular {
            HStack(spacing: 0) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    SortOrderButton(order: order, selected: sortOrder == order) {
                        sortOrder = order
                    }
                }
            }
            Button("Select") { isSelecting = true }
                .buttonStyle(.borderless)
                .lineLimit(1).fixedSize()
        } else {
            Menu {
                Picker("Sort By", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                if viewMode == .gallery {
                    Divider()
                    if density == .minimal {
                        Toggle("Group by Day", isOn: $groupByDay)
                    }
                    Picker("Thumbnail Size", selection: $tileSize) {
                        Text("Small").tag(96.0)
                        Text("Medium").tag(140.0)
                        Text("Large").tag(200.0)
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort & Thumbnail Size")
            Button { isSelecting = true } label: {
                Image(systemName: "checkmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Select Files")
        }
        Button {
            loadFiles()
            refreshStorageInfo()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(isLoadingFiles)
        .help("Refresh")
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
                Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(Color.canopySage)
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
                        node: node, device: device, depth: 0, selectedFile: $selectedFile,
                        onToggle: toggleNode,
                        onPlay: { selected in
                            playbackTarget = PlaybackTarget(node: selected, device: device)
                        },
                        onPreviewImage: { selected in
                            imagePreviewTarget = PlaybackTarget(node: selected, device: device)
                        },
                        isSelecting: isSelecting,
                        selectedIDs: $selectedIDs,
                        canManage: appState.isAdmin,
                        onDeleteRequest: { deletePending = [$0] },
                        onMoveRequest: { target in
                            moveNodes = [target]
                            showMoveSheet = true
                        },
                        onEditKeywords: { editKeywords($0) },
                        runTarget: runTarget(for:)
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
        guard !starredOnly, labelFilter == nil, searchText.isEmpty else { return filteredNodes }
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
                let columns = [GridItem(.adaptive(minimum: tileSize + 14, maximum: tileSize + 44), spacing: 16)]
                if groupByDay {
                    LazyVGrid(columns: columns, spacing: 20, pinnedViews: [.sectionHeaders]) {
                        ForEach(ClipGrouping.groups(for: galleryNodes)) { group in
                            Section {
                                ForEach(group.nodes) { tile(for: $0) }
                            } header: {
                                Text(group.title)
                                    .font(.canopyTitle2)
                                    .foregroundStyle(Color.canopyInk)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .background(Color.canopyPaper)
                            }
                        }
                    }
                    .padding(16)
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(galleryNodes) { tile(for: $0) }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func tile(for node: FileNode) -> some View {
        FileGalleryTile(
            node: node,
            device: device,
            isSelected: selectedFile?.id == node.id,
            isSelecting: isSelecting,
            isChecked: selectedIDs.contains(node.id),
            canManage: appState.isAdmin,
            tileSize: tileSize,
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
                    } else if node.isImage {
                        imagePreviewTarget = PlaybackTarget(node: node, device: device)
                    }
                }
            },
            onPlay: { playbackTarget = PlaybackTarget(node: node, device: device) },
            onPreviewImage: { imagePreviewTarget = PlaybackTarget(node: node, device: device) },
            onDeleteRequest: { target in deletePending = [target] },
            onMoveRequest: { target in moveNodes = [target]; showMoveSheet = true },
            onEditKeywords: { editKeywords($0) },
            runTarget: runTarget(for:)
        )
    }

    // MARK: - Run a workflow on a folder

    /// What a workflow started from `folder` runs on: that exact folder,
    /// processed in place. Nil for a HyperDeck's folders — those aren't on
    /// this Mac's filesystem, so a workflow can only run on the deck as a
    /// whole (from the Run Workflow button above the browser).
    private func runTarget(for folder: FileNode) -> WorkflowEngine.WorkflowTargetDevice? {
        guard folder.isDirectory, let url = folder.url else { return nil }
        switch device {
        case .hyperDeck:
            return nil
        case .localFolder:
            return .folder(at: url)
        case .cloudStore(let store):
            // Root nodes sit directly in the mounted volume.
            guard let root = rootNodes.first?.url?.deletingLastPathComponent().path,
                  url.path.hasPrefix(root + "/") else { return nil }
            return .cloudStore(store, path: String(url.path.dropFirst(root.count + 1)))
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
                Image(systemName: "chevron.right").font(.canopyCaption2).foregroundStyle(.secondary)
                if let node = findNode(id: id, in: rootNodes) {
                    Button(node.name) {
                        galleryPathIDs = Array(galleryPathIDs.prefix(index + 1))
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == galleryPathIDs.count - 1)
                }
            }
            Spacer()
            if appState.isAdmin, let current = galleryCurrentNode, let target = runTarget(for: current) {
                RunWorkflowHereMenu(target: target, title: "Run Workflow Here")
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
        }
        .font(.canopyCaption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var noFilesState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "externaldrive").font(.system(size: 40)).foregroundStyle(Color.canopySage)
            Text("This device type doesn't expose a file system.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(Color.canopyRust)
            Text("Could not load files").font(.canopyHeadline)
            Text(message).font(.canopyCaption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Retry", action: loadFiles).buttonStyle(.canopySecondary)
            Spacer()
        }
    }

    // MARK: - Filtering / Sorting

    /// "Starred Only" narrows to a flat list of starred clips found among
    /// whatever's already loaded (expanded folders in list mode, browsed
    /// folders in gallery mode) — it doesn't eagerly load the whole tree.
    /// The Starred tab (StarredView) is the reliable, complete cross-device
    /// view; this is a lightweight "narrow what I'm looking at" filter.
    private var filteredNodes: [FileNode] {
        if starredOnly || labelFilter != nil {
            let clips = flatten(rootNodes).filter { node in
                !node.isDirectory
                    && (!starredOnly || clipMetadata.isStarred(node.id))
                    && (labelFilter == nil || clipMetadata.label(for: node.id) == labelFilter)
            }
            let matching = searchText.isEmpty ? clips : clips.filter { matchesSearch($0, query: searchText.lowercased()) }
            return sortedNodes(matching)
        }
        guard !searchText.isEmpty else { return sortedNodes(rootNodes) }
        return flatFilter(rootNodes, query: searchText.lowercased())
    }

    private func matchesSearch(_ node: FileNode, query: String) -> Bool {
        node.name.lowercased().contains(query)
            || clipMetadata.note(for: node.id).lowercased().contains(query)
            || clipMetadata.keywords(for: node.id).contains { $0.lowercased().contains(query) }
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
            if matchesSearch(node, query: query) { result.append(node) }
            if let children = node.children { result += flatFilter(children, query: query) }
        }
        return result
    }

    private func selectedNodes() -> [FileNode] {
        flatten(rootNodes).filter { selectedIDs.contains($0.id) }
    }

    /// Clips (videos and images) in the same folder as `node`, in display order.
    private func siblingClips(of node: FileNode) -> [FileNode] {
        func parentChildren(of id: String, in nodes: [FileNode]) -> [FileNode]? {
            if nodes.contains(where: { $0.id == id }) { return nodes }
            for n in nodes {
                if let found = parentChildren(of: id, in: n.children ?? []) { return found }
            }
            return nil
        }
        let siblings = parentChildren(of: node.id, in: rootNodes) ?? [node]
        return sortedNodes(siblings).filter { !$0.isDirectory && ($0.isVideo || $0.isImage) }
    }

    /// Moves the open preview to the previous (-1) / next (+1) clip in its folder.
    private func stepPreview(from node: FileNode, by offset: Int) {
        let clips = siblingClips(of: node)
        guard let index = clips.firstIndex(where: { $0.id == node.id }) else { return }
        let next = index + offset
        guard clips.indices.contains(next) else { return }
        let target = PlaybackTarget(node: clips[next], device: device)
        selectedFile = clips[next]
        if clips[next].isVideo {
            imagePreviewTarget = nil
            playbackTarget = target
        } else {
            playbackTarget = nil
            imagePreviewTarget = target
        }
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
        selectedFile = nil
        let previouslyExpandedIDs = expandedNodeIDs(in: rootNodes)
        let previousGalleryPathIDs = galleryPathIDs

        Task {
            do {
                let freshNodes = try await fetchNodes(for: device)
                let nodes = previouslyExpandedIDs.isEmpty
                    ? freshNodes
                    : await restoringExpansion(freshNodes, expandedIDs: previouslyExpandedIDs)
                await MainActor.run {
                    rootNodes = nodes
                    galleryPathIDs = validGalleryPath(previousGalleryPathIDs, in: nodes)
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

    /// IDs of every directory currently expanded (list mode) or open (gallery
    /// mode — navigating into a folder marks it expanded too), so a reload can
    /// restore the user's place instead of snapping back to the collapsed root.
    private func expandedNodeIDs(in nodes: [FileNode]) -> Set<String> {
        var result: Set<String> = []
        for node in nodes {
            if node.isExpanded {
                result.insert(node.id)
            }
            if let children = node.children {
                result.formUnion(expandedNodeIDs(in: children))
            }
        }
        return result
    }

    /// Re-fetches children for every directory whose id is in `expandedIDs` so
    /// a freshly-loaded root listing ends up with the same folders open as
    /// before. Node ids are stable (derived from path), so ids from the old
    /// tree line up with the same folders in the new one; a folder that was
    /// deleted simply won't be present to match against.
    private func restoringExpansion(_ nodes: [FileNode], expandedIDs: Set<String>) async -> [FileNode] {
        var result: [FileNode] = []
        for var node in nodes {
            if node.isDirectory, expandedIDs.contains(node.id) {
                let children = await loadChildren(for: node)
                node.children = await restoringExpansion(children, expandedIDs: expandedIDs)
                node.isExpanded = true
            }
            result.append(node)
        }
        return result
    }

    /// Trims a gallery breadcrumb path down to the deepest ancestor that still
    /// exists in `nodes`, so deleting the folder currently open in gallery
    /// mode falls back to its nearest surviving parent instead of the root.
    private func validGalleryPath(_ ids: [String], in nodes: [FileNode]) -> [String] {
        var result: [String] = []
        for id in ids {
            guard findNode(id: id, in: nodes) != nil else { break }
            result.append(id)
        }
        return result
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
    let device: DeviceSource
    let depth: Int
    @Binding var selectedFile: FileNode?
    let onToggle: (String) -> Void
    let onPlay: (FileNode) -> Void
    var onPreviewImage: (FileNode) -> Void = { _ in }
    var isSelecting: Bool = false
    var selectedIDs: Binding<Set<String>> = .constant([])
    var canManage: Bool = false
    var onDeleteRequest: (FileNode) -> Void = { _ in }
    var onMoveRequest: (FileNode) -> Void = { _ in }
    var onEditKeywords: (FileNode) -> Void = { _ in }
    var runTarget: (FileNode) -> WorkflowEngine.WorkflowTargetDevice? = { _ in nil }

    @ObservedObject private var clipStore = ClipMetadataStore.shared

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
                        .font(.canopyCaption2)
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
                if !isSelecting && (node.isVideo || node.isImage) {
                    if let label = clipStore.label(for: node.id) {
                        Circle().fill(label.color).frame(width: 8, height: 8)
                    }
                    ClipNoteButton(node: node, device: device, size: .callout)
                    ClipStarButton(node: node, device: device, size: .callout)
                }
                if node.isVideo && !isSelecting {
                    Button { onPlay(node) } label: {
                        Image(systemName: "play.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .help("Play")
                } else if node.isImage && !isSelecting {
                    Button { onPreviewImage(node) } label: {
                        Image(systemName: "eye.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .help("Preview")
                }
                if !node.sizeFormatted.isEmpty {
                    Text(node.sizeFormatted)
                        .font(.canopyCaption)
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
                    else if node.isImage { onPreviewImage(node) }
                }
            }
            .clipDragSource(node)
            .contextMenu {
                if !isSelecting && (node.isVideo || node.isImage) {
                    clipContextItems(node: node, device: device, onEditKeywords: onEditKeywords)
                }
                if !isSelecting && canManage {
                    if let target = runTarget(node) { RunWorkflowHereMenu(target: target) }
                    Button("Move…") { onMoveRequest(node) }
                    Button("Delete", role: .destructive) { onDeleteRequest(node) }
                }
            }
            Divider().padding(.leading, CGFloat(depth) * 16 + 38)
        }
        if node.isExpanded, let children = node.children {
            ForEach(children) { child in
                FileNodeView(
                    node: child, device: device, depth: depth + 1, selectedFile: $selectedFile,
                    onToggle: onToggle, onPlay: onPlay, onPreviewImage: onPreviewImage,
                    isSelecting: isSelecting, selectedIDs: selectedIDs,
                    canManage: canManage, onDeleteRequest: onDeleteRequest, onMoveRequest: onMoveRequest,
                    onEditKeywords: onEditKeywords, runTarget: runTarget
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
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}


// MARK: - Adaptive Label
// Text at regular widths, just the icon once the toolbar tightens.

struct AdaptiveLabel: View {
    let title: String
    let icon: String
    let iconOnly: Bool

    var body: some View {
        if iconOnly {
            Image(systemName: icon)
        } else {
            Text(title).lineLimit(1).fixedSize()
        }
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
    let device: DeviceSource
    let isSelected: Bool
    var isSelecting: Bool = false
    var isChecked: Bool = false
    var canManage: Bool = false
    var tileSize: Double = 96
    let onOpen: () -> Void
    let onPlay: () -> Void
    var onPreviewImage: () -> Void = {}
    var onDeleteRequest: (FileNode) -> Void = { _ in }
    var onMoveRequest: (FileNode) -> Void = { _ in }
    var onEditKeywords: (FileNode) -> Void = { _ in }
    var runTarget: (FileNode) -> WorkflowEngine.WorkflowTargetDevice? = { _ in nil }

    @ObservedObject private var clipStore = ClipMetadataStore.shared
    @State private var info: ClipInfo?

    private var isClip: Bool { !node.isDirectory && (node.isVideo || node.isImage) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                FileThumbnailView(node: node, size: tileSize)
                    .frame(width: tileSize, height: tileSize)
                    .hoverScrub(node: node, size: tileSize)

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
                } else if node.isImage {
                    Button(action: onPreviewImage) {
                        Image(systemName: "eye.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                    .buttonStyle(.borderless)
                    .padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                if isClip && !isSelecting {
                    ClipStarButton(node: node, device: device, size: .caption)
                        .padding(4)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(4)
                }
            }
            .overlay(alignment: .bottom) {
                if let label = clipStore.label(for: node.id) {
                    Rectangle().fill(label.color).frame(height: 4)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let info, node.isVideo {
                    Text(info.durationLabel)
                        .font(.canopySans(10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isClip && !isSelecting {
                    ClipNoteButton(node: node, device: device, size: .caption)
                        .padding(4)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            Text(node.name)
                .font(.canopyCaption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            if let info, !info.summary.isEmpty {
                Text(info.summary)
                    .font(.canopySans(9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            if !node.sizeFormatted.isEmpty {
                Text(node.sizeFormatted)
                    .font(.canopyCaption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: tileSize + 14)
        .task(id: node.id) {
            guard node.isVideo, let url = node.url else { info = nil; return }
            info = await ClipInfoService.shared.info(for: url)
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .clipDragSource(node)
        .contextMenu {
            if !isSelecting && isClip {
                clipContextItems(node: node, device: device, onEditKeywords: onEditKeywords)
            }
            if !isSelecting && canManage {
                if let target = runTarget(node) { RunWorkflowHereMenu(target: target) }
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
    var size: CGFloat = 96
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: node.icon)
                    .font(.system(size: 32))
                    .foregroundStyle(node.iconColor)
            }
        }
        .task(id: "\(node.id)-\(Int(size))") {
            await loadThumbnail()
        }
    }

    private static let thumbnailableExtensions: Set<String> = [
        "mp4", "mov", "mxf", "m2ts", "jpg", "jpeg", "png", "tiff", "gif", "heic", "bmp", "pdf"
    ]

    private func loadThumbnail() async {
        guard !node.isDirectory, let url = node.url else { image = nil; return }
        guard Self.thumbnailableExtensions.contains(url.pathExtension.lowercased()) else { image = nil; return }

        // Quantize so dragging the size slider doesn't regenerate every step.
        let bucket = max(96, Int((size / 32).rounded(.up)) * 32)
        let cacheKey = "\(node.id)|\(bucket)|\(node.modified.timeIntervalSince1970)"
        if let cached = ThumbnailCache.shared.image(forKey: cacheKey) { image = cached; return }
        image = nil

        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: CGFloat(bucket), height: CGFloat(bucket)),
            scale: scale,
            representationTypes: .thumbnail
        )
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            let thumb = representation.nsImage
            ThumbnailCache.shared.set(thumb, forKey: cacheKey)
            await MainActor.run { image = thumb }
        }
    }
}

// MARK: - Storage Summary (compact, used in the files browser toolbar)

struct StorageSummaryView: View {
    let info: StorageInfo?
    var isLoading: Bool = false
    /// Drop the text and keep just the gauge when space is tight.
    var showsText: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            if let info {
                if let fraction = info.fraction {
                    Gauge(value: fraction) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .frame(width: 60)
                        .help(info.summary)
                }
                if showsText || info.fraction == nil {
                    Text(info.summary)
                        .font(.canopyCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            } else if isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }
}

// MARK: - Drag-out
// Lets a clip on a mounted volume (Cloud Store / Local Folder) be dragged
// straight into Finder or an NLE bin. HyperDeck clips only exist over FTP,
// so they have no file to hand over and aren't draggable.
extension View {
    @ViewBuilder
    func clipDragSource(_ node: FileNode) -> some View {
        if !node.isDirectory, let url = node.url {
            onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        } else {
            self
        }
    }
}

// MARK: - Clip context menu items
// Label and keyword actions shared by list rows and gallery tiles.
@ViewBuilder
func clipContextItems(node: FileNode, device: DeviceSource,
                      onEditKeywords: @escaping (FileNode) -> Void) -> some View {
    Menu("Label") {
        ForEach(ClipLabel.allCases) { label in
            Button {
                let store = ClipMetadataStore.shared
                store.setLabel(store.label(for: node.id) == label ? nil : label, node: node, device: device)
            } label: {
                Label(label.title, systemImage: "circle.fill").foregroundStyle(label.color)
            }
        }
        Button("Clear Label") { ClipMetadataStore.shared.setLabel(nil, node: node, device: device) }
    }
    Button("Keywords…") { onEditKeywords(node) }
    Divider()
}
