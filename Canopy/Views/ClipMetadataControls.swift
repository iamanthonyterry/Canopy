import SwiftUI

// MARK: - Clip Metadata Controls
// Star and note buttons shared by every place a clip is shown: the file
// browser's list rows and gallery tiles, the video/image preview sheets,
// and the Starred view. Both only make sense for actual clips, not folders.

struct ClipStarButton: View {
    let node: FileNode
    let device: DeviceSource
    var size: Font = .body

    @ObservedObject private var store = ClipMetadataStore.shared

    private var isStarred: Bool { store.isStarred(node.id) }

    var body: some View {
        Button {
            store.toggleStar(node: node, device: device)
        } label: {
            Image(systemName: isStarred ? "star.fill" : "star")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isStarred ? Color.yellow : Color.secondary)
        .font(size)
        .help(isStarred ? "Unstar" : "Star")
    }
}

struct ClipNoteButton: View {
    let node: FileNode
    let device: DeviceSource
    var size: Font = .body

    @ObservedObject private var store = ClipMetadataStore.shared
    @State private var isEditing = false
    @State private var draft = ""

    private var hasNote: Bool { !store.note(for: node.id).isEmpty }

    var body: some View {
        Button {
            draft = store.note(for: node.id)
            isEditing = true
        } label: {
            Image(systemName: hasNote ? "note.text" : "note")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(hasNote ? Color.accentColor : Color.secondary)
        .font(size)
        .help(hasNote ? "Edit Note" : "Add Note")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            ClipNoteEditor(text: $draft, onCommit: {
                store.setNote(draft, node: node, device: device)
                isEditing = false
            })
        }
    }
}

private struct ClipNoteEditor: View {
    @Binding var text: String
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 260, height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.canopyRule, lineWidth: 1))
            HStack {
                Spacer()
                Button("Done", action: onCommit)
                    .buttonStyle(.canopyPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}
