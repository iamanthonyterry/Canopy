import SwiftUI

// MARK: - Starred View
// Every starred clip across every device in one place, for triaging what to
// pull without hunting back through each device's file browser. Rows are
// built straight from the denormalized snapshot in ClipMetadata, so this
// doesn't need to re-browse any device's file tree to render.
struct StarredView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = ClipMetadataStore.shared
    @ObservedObject private var palette = CommandPaletteModel.shared

    @State private var playbackTarget: PlaybackTarget?
    @State private var imagePreviewTarget: PlaybackTarget?
    @State private var showExportQueue = false
    @State private var isExportingNLE = false
    @State private var nleMessage: String?

    private typealias Entry = (id: String, metadata: ClipMetadata)

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.canopyRule).frame(height: 1)
            if store.starredEntries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Color.canopyPaper)
        .onAppear(perform: consumePaletteClip)
        .onChange(of: palette.pendingClipID) { consumePaletteClip() }
        .sheet(item: $playbackTarget) { target in
            VideoPlayerSheet(node: target.node, device: target.device,
                             onNavigate: { stepPreview(from: target.node.id, by: $0) })
                .id(target.id)
        }
        .sheet(item: $imagePreviewTarget) { target in
            ImagePreviewSheet(node: target.node, device: target.device,
                              onNavigate: { stepPreview(from: target.node.id, by: $0) })
                .id(target.id)
        }
        .sheet(isPresented: $showExportQueue) {
            ExportQueueView()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Starred").font(.canopyTitle).foregroundStyle(Color.canopyInk)
                Text("\(store.starredEntries.count) clip\(store.starredEntries.count == 1 ? "" : "s") across every device")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if isExportingNLE {
                ProgressView().controlSize(.small)
            } else if !store.starredEntries.isEmpty {
                Menu {
                    Button("Final Cut Pro XML (.fcpxml)") { exportToResolve(.fcpxml) }
                    Button("EDL (.edl)") { exportToResolve(.edl) }
                } label: {
                    Label("Export for Resolve", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Send starred clips to DaVinci Resolve with their markers, notes and keywords")
            }
        }
        .padding()
        .alert("Export for Resolve", isPresented: Binding(get: { nleMessage != nil }, set: { if !$0 { nleMessage = nil } })) {
            Button("OK") { nleMessage = nil }
        } message: {
            Text(nleMessage ?? "")
        }
    }

    private enum NLEFormat { case fcpxml, edl }

    /// Exports every starred clip on mounted storage as a timeline Resolve
    /// can import (File ▸ Import ▸ Timeline), carrying markers, keywords,
    /// notes and color labels along.
    private func exportToResolve(_ format: NLEFormat) {
        isExportingNLE = true
        Task {
            let gathered = await NLEExportService.gather(store.starredEntries)
            isExportingNLE = false
            guard !gathered.clips.isEmpty else {
                nleMessage = "None of the starred clips are on mounted storage, so there's nothing to export. HyperDeck clips need to be offloaded first."
                return
            }
            let panel = NSSavePanel()
            panel.title = "Export for DaVinci Resolve"
            panel.nameFieldStringValue = "Canopy Selects.\(format == .fcpxml ? "fcpxml" : "edl")"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            let text = format == .fcpxml
                ? FCPXMLBuilder.xml(projectName: "Canopy Selects", clips: gathered.clips)
                : EDLBuilder.edl(title: "Canopy Selects", clips: gathered.clips)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                if !gathered.skipped.isEmpty {
                    nleMessage = "Exported \(gathered.clips.count) clip\(gathered.clips.count == 1 ? "" : "s"). Left out (not on mounted storage): \(gathered.skipped.joined(separator: ", "))."
                }
            } catch {
                nleMessage = "Couldn't save the file: \(error.localizedDescription)"
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "star").font(.system(size: 36)).foregroundStyle(Color.canopySage)
            Text("No starred clips yet").foregroundStyle(.secondary)
            Text("Star a clip while browsing a device to see it here.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(store.starredEntries, id: \.id) { entry in
                    StarredClipCard(
                        id: entry.id,
                        metadata: entry.metadata,
                        deviceAvailable: DeviceSource.resolve(id: entry.metadata.deviceID, in: appState) != nil,
                        onPlay: { open(entry) },
                        onQueue: { queue(entry) }
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - Actions

    private func node(for entry: Entry) -> FileNode {
        FileNode(
            id: entry.id,
            name: entry.metadata.clipName,
            url: entry.metadata.localURL,
            ftpPath: entry.metadata.ftpPath,
            isDirectory: false,
            size: entry.metadata.size,
            modified: entry.metadata.modified,
            children: []
        )
    }

    private func open(_ entry: Entry) {
        guard let device = DeviceSource.resolve(id: entry.metadata.deviceID, in: appState) else { return }
        let target = PlaybackTarget(node: node(for: entry), device: device)
        if entry.metadata.isVideo {
            imagePreviewTarget = nil
            playbackTarget = target
        } else if entry.metadata.isImage {
            playbackTarget = nil
            imagePreviewTarget = target
        }
    }

    /// Opens a clip picked in the command palette, then clears the request.
    private func consumePaletteClip() {
        guard let id = palette.pendingClipID else { return }
        palette.pendingClipID = nil
        if let metadata = store.entries[id] { open((id: id, metadata: metadata)) }
    }

    /// Steps the open preview to the previous / next starred clip.
    private func stepPreview(from id: String, by offset: Int) {
        let entries = store.starredEntries.filter {
            ($0.metadata.isVideo || $0.metadata.isImage)
                && DeviceSource.resolve(id: $0.metadata.deviceID, in: appState) != nil
        }
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries.indices.contains(index + offset) else { return }
        open(entries[index + offset])
    }

    private func queue(_ entry: Entry) {
        guard let device = DeviceSource.resolve(id: entry.metadata.deviceID, in: appState) else { return }
        ExportQueueManager.shared.add(node: node(for: entry), device: device)
        showExportQueue = true
    }
}

// MARK: - Starred Clip Card

private struct StarredClipCard: View {
    let id: String
    let metadata: ClipMetadata
    let deviceAvailable: Bool
    let onPlay: () -> Void
    let onQueue: () -> Void

    @ObservedObject private var store = ClipMetadataStore.shared
    @State private var isEditingNote = false
    @State private var noteDraft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FileThumbnailView(node: FileNode(
                id: id, name: metadata.clipName, url: metadata.localURL, ftpPath: metadata.ftpPath,
                isDirectory: false, size: metadata.size, modified: metadata.modified, children: []
            ))
            .frame(width: 64, height: 64)
            .onTapGesture { if deviceAvailable { onPlay() } }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(metadata.clipName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        store.toggleStar(id: id)
                    } label: {
                        Image(systemName: "star.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.yellow)
                    .help("Unstar")
                }

                HStack(spacing: 6) {
                    Text(metadata.deviceLabel).font(.caption).foregroundStyle(.secondary)
                    if !deviceAvailable {
                        CanopyPill(label: "Device no longer configured", color: .canopyRust)
                    }
                }

                if !metadata.note.isEmpty && !isEditingNote {
                    Text(metadata.note)
                        .font(.caption)
                        .foregroundStyle(Color.canopyInk)
                        .lineLimit(2)
                }

                if isEditingNote {
                    VStack(alignment: .trailing, spacing: 6) {
                        TextEditor(text: $noteDraft)
                            .font(.caption)
                            .frame(height: 60)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.canopyRule, lineWidth: 1))
                        Button("Done") {
                            store.setNote(noteDraft, id: id)
                            isEditingNote = false
                        }
                        .buttonStyle(.canopyPrimary)
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 10) {
                    Button(metadata.note.isEmpty ? "Add Note" : "Edit Note") {
                        noteDraft = metadata.note
                        isEditingNote = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)

                    if metadata.isVideo || metadata.isImage {
                        Button("Play", action: onPlay)
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(!deviceAvailable)

                        Button("Add to Export Queue", action: onQueue)
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(!deviceAvailable)
                    }
                }
            }
        }
        .padding(12)
        .canopyCard()
    }
}
