import SwiftUI

// MARK: - CloudStoreVolumePickerSheet
// Connects to an SMB server using the credentials currently entered in the
// edit form and lists its disk shares, so the user can pick a volume name
// instead of typing it. A share can also be opened to browse into its
// folder tree and pick a nested folder as the volume target — the result
// is a path like "Share/Sub/Folder", which SMBService mounts directly via
// smb://ip/Share/Sub/Folder. Calls onSelect with the chosen path.

struct CloudStoreVolumePickerSheet: View {
    let ipAddress: String
    let username: String
    let password: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    // Share list (root level)
    @State private var shares: [String] = []
    @State private var isLoadingShares = true
    @State private var highlightedShare: String?

    // Folder browsing (once a share has been opened)
    @State private var currentShare: String?
    @State private var mountPath: String?
    @State private var mountError: String?
    @State private var isMounting = false
    @State private var navStack: [(name: String, url: URL)] = []
    @State private var items: [FolderItem] = []
    @State private var isLoadingItems = false
    @State private var highlightedItem: FolderItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.canopyRule).frame(height: 1)
            if currentShare != nil {
                breadcrumb
                Rectangle().fill(Color.canopyRule).frame(height: 1)
            }
            content
            Rectangle().fill(Color.canopyRule).frame(height: 1)
            footer
        }
        .frame(width: 480, height: 420)
        .background(Color.canopyPaper)
        .task { await loadShares() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "externaldrive.badge.wifi")
                .foregroundStyle(Color.canopySage)
            Text("Choose Volume")
                .font(.canopyTitle2).foregroundStyle(Color.canopyInk)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Breadcrumb (folder browsing)

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    goToShareList()
                } label: {
                    Label("Shares", systemImage: "server.rack")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)

                Button {
                    navStack = []
                    if let mountPath { Task { await loadItems(at: URL(fileURLWithPath: mountPath)) } }
                } label: {
                    Label(currentShare ?? "", systemImage: "externaldrive.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(navStack.isEmpty ? .primary : .secondary)

                ForEach(navStack.indices, id: \.self) { i in
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button {
                        let slice = Array(navStack.prefix(i + 1))
                        navStack = slice
                        Task { await loadItems(at: slice.last!.url) }
                    } label: {
                        Text(navStack[i].name).font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(i == navStack.count - 1 ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if currentShare == nil {
            shareListContent
        } else {
            folderBrowsingContent
        }
    }

    @ViewBuilder
    private var shareListContent: some View {
        if isLoadingShares {
            VStack { Spacer(); ProgressView("Connecting to \(ipAddress)…"); Spacer() }
        } else if shares.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "externaldrive")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text("No shares found")
                    .foregroundStyle(.secondary)
                Text("Check the IP address and credentials above.")
                    .font(.caption).foregroundStyle(.tertiary)
                Button("Retry") { Task { await loadShares() } }.buttonStyle(.bordered)
                Spacer()
            }
        } else {
            List(shares, id: \.self, selection: $highlightedShare) { share in
                Label(share, systemImage: "externaldrive.fill")
                    .tag(share)
                    .onTapGesture(count: 2) { openShare(share) }
                    .onTapGesture(count: 1) { highlightedShare = share }
                    .contextMenu {
                        Button("Open") { openShare(share) }
                        Button("Select This Volume") { select(share) }
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder
    private var folderBrowsingContent: some View {
        if isMounting {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("Connecting to \(currentShare ?? "")…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if let error = mountError {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36)).foregroundStyle(Color.canopyRust)
                Text("Could not connect").font(.headline)
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Spacer()
            }
        } else if isLoadingItems {
            VStack { Spacer(); ProgressView(); Spacer() }
        } else if items.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "folder").font(.system(size: 36)).foregroundStyle(.secondary)
                Text("Empty folder").foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            List(items, id: \.url, selection: $highlightedItem) { item in
                FolderItemRow(item: item)
                    .tag(item)
                    .onTapGesture(count: 2) { openFolder(item) }
                    .onTapGesture(count: 1) { highlightedItem = item }
                    .contextMenu {
                        Button("Open") { openFolder(item) }
                        Button("Select This Folder") { confirmFolder(item) }
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if currentShare == nil {
                Spacer()
                Button("Select") {
                    if let share = highlightedShare { select(share) }
                }
                .buttonStyle(.canopyPrimary)
                .disabled(highlightedShare == nil)
            } else {
                if let h = highlightedItem {
                    Label(h.name, systemImage: "folder.fill")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(currentFullPath)
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }

                Spacer()

                Button("Open") {
                    if let h = highlightedItem { openFolder(h) }
                }
                .disabled(highlightedItem == nil)

                Button("Select Here") {
                    if let h = highlightedItem {
                        confirmFolder(h)
                    } else {
                        select(currentFullPath)
                    }
                }
                .buttonStyle(.canopyPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private var currentFullPath: String {
        guard let currentShare else { return "" }
        let sub = navStack.map(\.name).joined(separator: "/")
        return sub.isEmpty ? currentShare : "\(currentShare)/\(sub)"
    }

    // MARK: - Actions

    private func select(_ path: String) {
        onSelect(path)
        dismiss()
    }

    private func openFolder(_ item: FolderItem) {
        navStack.append((name: item.name, url: item.url))
        highlightedItem = nil
        Task { await loadItems(at: item.url) }
    }

    private func confirmFolder(_ item: FolderItem) {
        select((navStack.map(\.name) + [item.name]).reduce(currentShare ?? "") { path, name in
            path.isEmpty ? name : "\(path)/\(name)"
        })
    }

    private func goToShareList() {
        currentShare = nil
        mountPath = nil
        mountError = nil
        navStack = []
        items = []
        highlightedItem = nil
    }

    private func openShare(_ share: String) {
        currentShare = share
        navStack = []
        items = []
        highlightedItem = nil
        Task { await mountAndBrowse(share: share) }
    }

    // MARK: - Loading

    private func loadShares() async {
        isLoadingShares = true
        shares = await SMBService.listShares(ip: ipAddress, username: username, password: password)
        isLoadingShares = false
    }

    private func mountAndBrowse(share: String) async {
        isMounting = true
        mountError = nil
        do {
            let path = try await SMBService.mountAndResolve(
                ip: ipAddress, volume: share, username: username, password: password
            )
            mountPath = path
            await loadItems(at: URL(fileURLWithPath: path))
        } catch {
            mountError = error.localizedDescription
        }
        isMounting = false
    }

    private func loadItems(at url: URL) async {
        isLoadingItems = true
        items = []
        highlightedItem = nil
        let loaded = await Task.detached(priority: .userInitiated) {
            await Self.listFolders(at: url)
        }.value
        items = loaded
        isLoadingItems = false
    }

    private static func listFolders(at url: URL) -> [FolderItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .localizedNameKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .compactMap { child -> FolderItem? in
                let res = try? child.resourceValues(forKeys: Set(keys))
                guard res?.isDirectory == true else { return nil }
                return FolderItem(
                    name: res?.localizedName ?? child.lastPathComponent,
                    url: child
                )
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}
