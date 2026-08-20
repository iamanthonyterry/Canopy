import SwiftUI

// MARK: - DeckPathPickerSheet
// Connects to a HyperDeck over FTP using the credentials currently entered in
// the edit form and lets the user browse its volumes/folders instead of
// typing the remote path by hand. Calls onSelect with the path relative to
// the FTP root (e.g. "usb1/My Drive").

struct DeckPathPickerSheet: View {
    let ipAddress: String
    let username: String
    let password: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var navStack: [String] = []
    @State private var items: [FTPService.FTPEntry] = []
    @State private var isLoading = true
    @State private var highlighted: FTPService.FTPEntry?

    private var probeDeck: HyperDeck {
        HyperDeck(name: "", ipAddress: ipAddress, remotePath: "", username: username, password: password)
    }

    private var currentPath: String { navStack.joined(separator: "/") }

    private var folders: [FTPService.FTPEntry] {
        items.filter(\.isDirectory)
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
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
            Image(systemName: "server.rack")
                .foregroundStyle(.blue)
            Text("Choose Remote Path")
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
                    Label(ipAddress, systemImage: "externaldrive.fill")
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
            VStack { Spacer(); ProgressView("Connecting…"); Spacer() }
        } else if folders.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "folder")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text(navStack.isEmpty ? "No folders found" : "Empty folder")
                    .foregroundStyle(.secondary)
                if navStack.isEmpty {
                    Text("Check the IP address and credentials above.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        } else {
            List(folders, id: \.self, selection: $highlighted) { entry in
                Label(entry.name, systemImage: "folder.fill")
                    .tag(entry)
                    .onTapGesture(count: 2) { open(entry) }
                    .onTapGesture(count: 1) { highlighted = entry }
                    .contextMenu {
                        Button("Open") { open(entry) }
                        Button("Select This Folder") { select(entry) }
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let h = highlighted {
                Label(h.name, systemImage: "folder.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text(navStack.isEmpty ? "Volume root" : currentPath)
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
                    onSelect(currentPath)
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func open(_ entry: FTPService.FTPEntry) {
        navStack.append(entry.name)
        highlighted = nil
        Task { await load() }
    }

    private func select(_ entry: FTPService.FTPEntry) {
        onSelect((navStack + [entry.name]).joined(separator: "/"))
        dismiss()
    }

    private func load() async {
        isLoading = true
        highlighted = nil
        items = await FTPService.listAllFiles(on: probeDeck, path: currentPath)
        isLoading = false
    }
}
