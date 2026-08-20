import SwiftUI

// MARK: - FolderPickerSheet
// Mounts a CloudStore via SMB and lets the user navigate its folder tree
// to pick a sync destination. Calls onSelect with the relative path
// (relative to the volume root) so it can be stored on HyperDeck.

struct FolderPickerSheet: View {
    let store: CloudStore
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    // Mount state
    @State private var mountPath: String? = nil
    @State private var mountError: String? = nil
    @State private var isMounting = true

    // Navigation stack — each entry is (name, url)
    @State private var navStack: [(name: String, url: URL)] = []

    // Current directory contents
    @State private var items: [FolderItem] = []
    @State private var isLoading = false

    // The folder the user has highlighted (not yet confirmed)
    @State private var highlighted: FolderItem? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            breadcrumb
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 420)
        .task { await mount() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "externaldrive.badge.wifi")
                .foregroundStyle(.purple)
            Text("Choose Folder — \(store.name)")
                .font(.title3).bold()
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Breadcrumb

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Root crumb
                Button {
                    navStack = []
                    Task { await loadItems(at: URL(fileURLWithPath: mountPath ?? "/")) }
                } label: {
                    Label(store.volumeName.isEmpty ? store.name : store.volumeName,
                          systemImage: "externaldrive.fill")
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
        if isMounting {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("Connecting to \(store.name)…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if let error = mountError {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36)).foregroundStyle(.red)
                Text("Could not connect").font(.headline)
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Spacer()
            }
        } else if isLoading {
            VStack { Spacer(); ProgressView(); Spacer() }
        } else if items.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "folder").font(.system(size: 36)).foregroundStyle(.secondary)
                Text("Empty folder").foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            List(items, id: \.url, selection: $highlighted) { item in
                FolderItemRow(item: item)
                    .tag(item)
                    .onTapGesture(count: 2) { open(item) }
                    .onTapGesture(count: 1) { highlighted = item }
                    .contextMenu {
                        Button("Open") { open(item) }
                        Button("Select This Folder") { confirm(item) }
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            // Current selection label
            if let h = highlighted {
                Label(h.name, systemImage: "folder.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text(navStack.isEmpty ? "Volume root" : currentRelativePath)
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Spacer()

            // Open selected folder
            Button("Open") {
                if let h = highlighted { open(h) }
            }
            .disabled(highlighted == nil)

            // Select current folder (whatever the browser is showing)
            Button("Select Here") {
                if let h = highlighted {
                    confirm(h)
                } else {
                    // Select the current directory level
                    onSelect(currentRelativePath)
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private var currentRelativePath: String {
        navStack.map(\.name).joined(separator: "/")
    }

    private func open(_ item: FolderItem) {
        navStack.append((name: item.name, url: item.url))
        highlighted = nil
        Task { await loadItems(at: item.url) }
    }

    private func confirm(_ item: FolderItem) {
        let path = (navStack.map(\.name) + [item.name]).joined(separator: "/")
        onSelect(path)
        dismiss()
    }

    // MARK: - Mount

    private func mount() async {
        isMounting = true
        mountError = nil
        do {
            let path = try await SMBService.mountAndResolve(
                ip:       store.ipAddress,
                volume:   store.volumeName,
                username: store.username,
                password: store.password
            )
            mountPath = path
            await loadItems(at: URL(fileURLWithPath: path))
        } catch {
            mountError = error.localizedDescription
        }
        isMounting = false
    }

    // MARK: - Directory Loading

    private func loadItems(at url: URL) async {
        isLoading = true
        items = []
        highlighted = nil
        let loaded = await Task.detached(priority: .userInitiated) {
            await Self.listFolders(at: url)
        }.value
        items = loaded
        isLoading = false
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

// MARK: - Supporting types

struct FolderItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
    static func == (lhs: FolderItem, rhs: FolderItem) -> Bool { lhs.url == rhs.url }
}

struct FolderItemRow: View {
    let item: FolderItem
    var body: some View {
        Label(item.name, systemImage: "folder.fill")
            .foregroundStyle(.primary)
            .padding(.vertical, 2)
    }
}
