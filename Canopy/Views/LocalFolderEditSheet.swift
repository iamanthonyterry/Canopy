import SwiftUI
import AppKit

// MARK: - Local Folder Edit Sheet
// Adds a folder or drive already reachable on this Mac's filesystem — no
// network address, credentials, or mount step needed, unlike a Cloud Store.
struct LocalFolderEditSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let existingFolder: LocalFolder?

    @State private var name = ""
    @State private var path = ""

    init(folder: LocalFolder?) {
        existingFolder = folder
        _name = State(initialValue: folder?.name ?? "")
        _path = State(initialValue: folder?.path ?? "")
    }

    var canSave: Bool { !name.isEmpty && !path.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existingFolder == nil ? "Add Local Folder" : "Edit Local Folder")
                    .font(.title2).bold()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existingFolder == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.borderedProminent).disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            Form {
                Section("Folder") {
                    LabeledContent("Name") {
                        TextField("e.g. Archive Drive", text: $name).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Location") {
                        HStack(spacing: 8) {
                            Text(path.isEmpty ? "No folder chosen" : path)
                                .font(.caption)
                                .foregroundStyle(path.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                choosePath()
                            } label: {
                                Label("Choose…", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 440)
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder or Drive"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
        if name.isEmpty { name = url.lastPathComponent }
    }

    private func save() {
        if var f = existingFolder {
            f.name = name; f.path = path
            appState.updateLocalFolder(f)
        } else {
            appState.addLocalFolder(LocalFolder(name: name, path: path))
        }
        dismiss()
    }
}
