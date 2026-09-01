import SwiftUI
import AppKit

// Presented by DeviceFilesBrowser when the user previews an image. Cloud
// Store / Local Folder files live on an already-mounted volume and load
// directly; HyperDeck files only exist over FTP, so they're downloaded to a
// temp location first, same approach as VideoPlayerSheet.
struct ImagePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let node: FileNode
    let device: DeviceSource

    @State private var image: NSImage?
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var errorMessage: String?
    @State private var downloadedFileURL: URL?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "photo.fill").foregroundStyle(.tint)
                Text(node.name)
                    .font(.title3).bold()
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if image != nil {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { resetZoom() }
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset Zoom")
                    .disabled(scale == 1 && offset == .zero)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            ZStack {
                Color.black

                if let image {
                    GeometryReader { geo in
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        scale = max(1, min(8, lastScale * value))
                                    }
                                    .onEnded { _ in
                                        lastScale = scale
                                        if scale == 1 { withAnimation(.easeOut(duration: 0.2)) { resetZoom() } }
                                    }
                            )
                            .simultaneousGesture(
                                DragGesture()
                                    .onChanged { value in
                                        guard scale > 1 else { return }
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in lastOffset = offset }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    if scale > 1 { resetZoom() } else { scale = 2; lastScale = 2 }
                                }
                            }
                    }
                } else {
                    statusOverlay
                }
            }
            .clipped()
        }
        .frame(minWidth: 680, minHeight: 460)
        .task { await load() }
        .onDisappear { cleanUp() }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let errorMessage {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40)).foregroundStyle(.red)
                Text("Can't preview this file").font(.headline)
                Text(errorMessage)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
            }
            .padding()
        } else {
            VStack(spacing: 12) {
                Spacer()
                if isDownloading {
                    ProgressView(value: downloadProgress).frame(width: 220)
                    Text("Downloading for preview… \(Int(downloadProgress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView("Loading…")
                }
                Spacer()
            }
        }
    }

    // MARK: - Load

    private func load() async {
        switch device {
        case .cloudStore, .localFolder:
            guard let url = node.url else {
                errorMessage = "Couldn't locate this file on the volume."
                return
            }
            await loadImage(from: url)

        case .hyperDeck(let deck):
            guard let fileName = node.ftpPath else {
                errorMessage = "Couldn't locate this file on the deck."
                return
            }
            await downloadAndLoad(fileName: fileName, deck: deck)
        }
    }

    private func downloadAndLoad(fileName: String, deck: HyperDeck) async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanopyPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let destination = tempDir.appendingPathComponent("\(deck.id.uuidString)-\(fileName)")
        try? FileManager.default.removeItem(at: destination)

        isDownloading = true
        downloadProgress = 0

        let result = await FTPService.downloadFile(named: fileName, from: deck, to: destination) { pct in
            Task { @MainActor in downloadProgress = pct }
        }

        isDownloading = false
        if result.success {
            downloadedFileURL = destination
            await loadImage(from: destination)
        } else {
            errorMessage = result.failureReason ?? "Download failed."
        }
    }

    private func loadImage(from url: URL) async {
        let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            NSImage(contentsOf: url)
        }.value
        guard let loaded else {
            errorMessage = "This file's format isn't supported for preview."
            return
        }
        image = loaded
    }

    // MARK: - Cleanup

    private func cleanUp() {
        if let downloadedFileURL {
            try? FileManager.default.removeItem(at: downloadedFileURL)
        }
    }
}
