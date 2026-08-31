import SwiftUI

// MARK: - Move Destination
// Where a "Move…" action should land the selected files. Only ever a folder
// on the *same* device the files already live on — Canopy doesn't move files
// between devices, just reorganizes them within one.
enum MoveDestination {
    case ftpPath(String)   // relative to deck.remotePath
    case localURL(URL)     // Cloud Store (mounted) or Local Folder
}

// MARK: - DeviceFolderPickerSheet
// Lets the user browse a device's own folder tree and pick a destination
// folder for a move. Generalizes DeckPathPickerSheet (which is FTP/HyperDeck
// only) to also browse Cloud Store and Local Folder paths via FileManager.

struct DeviceFolderPickerSheet: View {
    let device: DeviceSource
    let onSelect: (MoveDestination) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var navStack: [String] = []
    @State private var folders: [String] = []
    @State private var isLoading = true
    @State private var highlighted: String?
    @State private var loadError: String?

    // Resolved once for Cloud Store (mounted SMB volume path) / Local Folder.
    @State private var rootPath: String?

    private var currentRelativePath: String { navStack.joined(separator: "/") }

    private var rootLabel: String {
        switch device {
        case .hyperDeck(let deck): return deck.name.isEmpty ? deck.ipAddress : deck.name
        case .cloudStore(let store): return store.name
        case .localFolder(let folder): return folder.name
        }
    }

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
        .frame(width: 480, height: 380)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "folder.badge.gearshape")
                .foregroundStyle(.tint)
            Text("Move To…")
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
                Button {
                    navStack = []
                    Task { await load() }
                } label: {
                    Label(rootLabel, systemImage: "externaldrive.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(navStack.isEmpty ? .primary : .secondary)

                ForEach(navStack.indices, id: \.self) { i in
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button {
                        navStack = Array(navStack.prefix(i + 1))
                        Task { await load() }
                    } label: {
                        Text(navStack[i]).font(.caption)
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
        if isLoading {
            VStack { Spacer(); ProgressView("Loading…"); Spacer() }
        } else if let loadError {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.red)
                Text(loadError).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Spacer()
            }
        } else if folders.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "folder").font(.system(size: 36)).foregroundStyle(.secondary)
                Text(navStack.isEmpty ? "No folders found" : "Empty folder")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            List(folders, id: \.self, selection: $highlighted) { name in
                Label(name, systemImage: "folder.fill")
                    .tag(name)
                    .onTapGesture(count: 2) { open(name) }
                    .onTapGesture(count: 1) { highlighted = name }
                    .contextMenu {
                        Button("Open") { open(name) }
                        Button("Select This Folder") { select(name) }
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let h = highlighted {
                Label(h, systemImage: "folder.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text(navStack.isEmpty ? "Device root" : currentRelativePath)
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }

            Spacer()

            Button("Open") {
                if let h = highlighted { open(h) }
            }
            .disabled(highlighted == nil)

            Button("Select Here") {
                if let h = highlighted {
                    select(h)
                } else {
                    finish(relativePath: currentRelativePath)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func open(_ name: String) {
        navStack.append(name)
        highlighted = nil
        Task { await load() }
    }

    private func select(_ name: String) {
        finish(relativePath: (navStack + [name]).joined(separator: "/"))
    }

    private func finish(relativePath: String) {
        switch device {
        case .hyperDeck:
            onSelect(.ftpPath(relativePath))
        case .cloudStore, .localFolder:
            guard let rootPath else { return }
            let url = relativePath.isEmpty
                ? URL(fileURLWithPath: rootPath)
                : URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath)
            onSelect(.localURL(url))
        }
        dismiss()
    }

    private func load() async {
        isLoading = true
        highlighted = nil
        loadError = nil

        switch device {
        case .hyperDeck(let deck):
            let listPath = currentRelativePath.isEmpty
                ? deck.remotePath
                : "\(deck.remotePath)/\(currentRelativePath)"
            let entries = await FTPService.listAllFiles(on: deck, path: listPath)
            folders = entries.filter(\.isDirectory).map(\.name)
                .sorted { $0.localizedCompare($1) == .orderedAscending }

        case .cloudStore(let store):
            do {
                if rootPath == nil {
                    rootPath = try await SMBService.mountAndResolve(
                        ip: store.ipAddress, volume: store.volumeName,
                        username: store.username, password: store.password
                    )
                }
                folders = try listLocalFolders()
            } catch {
                loadError = error.localizedDescription
                folders = []
            }

        case .localFolder(let folder):
            rootPath = folder.path
            do {
                folders = try listLocalFolders()
            } catch {
                loadError = error.localizedDescription
                folders = []
            }
        }

        isLoading = false
    }

    private func listLocalFolders() throws -> [String] {
        guard let rootPath else { return [] }
        let base = currentRelativePath.isEmpty
            ? URL(fileURLWithPath: rootPath)
            : URL(fileURLWithPath: rootPath).appendingPathComponent(currentRelativePath)
        let contents = try FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey]
        )
        return contents.compactMap { url -> String? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
            guard values?.isDirectory == true, values?.isHidden != true else { return nil }
            return url.lastPathComponent
        }
        .sorted { $0.localizedCompare($1) == .orderedAscending }
    }
}
