import SwiftUI
import AVKit
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import Combine

// Presented by StorageBrowserView when the user plays a video file so they
// can preview a clip without leaving the app. Cloud Store files live on an
// already-mounted SMB volume and play directly; HyperDeck files only exist
// over FTP, so they're downloaded to a temp location first, then played
// locally (AVFoundation doesn't support streaming ftp:// URLs).
//
// Also offers a trim/export feature: the user marks in/out points against
// the local (possibly downloaded) file and exports that sub-range to disk.
struct VideoPlayerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let node: FileNode
    let device: DeviceSource

    @State private var player: AVPlayer?
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var errorMessage: String?
    @State private var downloadedFileURL: URL?
    @State private var cancellables = Set<AnyCancellable>()

    // Local URL the trim/export feature reads from — the downloaded temp
    // file for HyperDeck clips, or the node's own URL for Cloud Store.
    @State private var sourceURL: URL?

    // Trim / export state
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var inPoint: Double = 0
    @State private var outPoint: Double = 0
    @State private var timeObserverToken: Any?
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Header
            HStack {
                Image(systemName: "film.fill").foregroundStyle(.purple)
                Text(node.name)
                    .font(.title3).bold()
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            // PlayerContainerView (below) wraps AVKit's plain AppKit
            // AVPlayerView instead of SwiftUI's own VideoPlayer. VideoPlayer
            // is backed by the private _AVKit_SwiftUI framework, and
            // instantiating its generic view-representable metadata for the
            // first time during any reentrant SwiftUI view-graph update
            // (sheet presentation, initial window construction — anywhere
            // Update.ensure/GraphHost nests one graph update inside another)
            // loses a race in the Swift runtime's generic metadata cache and
            // aborts with a fatalError inside getSuperclassMetadata. It's
            // timing-dependent, so it wouldn't reproduce in an Xcode Debug
            // build but would crash a notarized Release build (sometimes on
            // first sheet presentation, sometimes on every launch depending
            // on exactly where the metadata got instantiated). AVPlayerView
            // is an ordinary NSView with no such generic metadata dance, so
            // it sidesteps the bug entirely. It's still mounted
            // unconditionally, same as VideoPlayer(player:) was, so no
            // swap-in-mid-transition crash either.
            ZStack {
                PlayerContainerView(player: player)
                if player == nil {
                    statusOverlay
                }
            }

            if player != nil {
                Divider()
                trimControls
                    .padding()
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .task { await load() }
        .onDisappear { cleanUp() }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let errorMessage {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40)).foregroundStyle(.red)
                Text("Can't play this file").font(.headline)
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

    // MARK: - Trim / Export Controls

    @ViewBuilder
    private var trimControls: some View {
        VStack(spacing: 10) {
            if duration > 0 {
                TrimBarView(
                    duration: duration,
                    currentTime: currentTime,
                    inPoint: $inPoint,
                    outPoint: $outPoint
                )
                .frame(height: 28)
            }

            HStack(spacing: 16) {
                Button {
                    inPoint = min(currentTime, max(0, outPoint - 0.05))
                } label: {
                    Label(timeString(inPoint), systemImage: "arrow.right.to.line")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Set In Point to current playhead")

                Spacer()

                Text("Clip: \(timeString(max(0, outPoint - inPoint)))")
                    .font(.caption).foregroundStyle(.secondary)

                Spacer()

                Button {
                    outPoint = max(currentTime, min(duration, inPoint + 0.05))
                } label: {
                    Label(timeString(outPoint), systemImage: "arrow.left.to.line")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Set Out Point to current playhead")
            }

            if isExporting {
                VStack(spacing: 4) {
                    ProgressView(value: exportProgress)
                    Text("Exporting clip… \(Int(exportProgress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    if let exportError {
                        Text(exportError)
                            .font(.caption).foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        exportClip()
                    } label: {
                        Label("Export Clip…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceURL == nil || outPoint <= inPoint)
                }
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Load

    private func load() async {
        switch device {
        case .cloudStore:
            guard let url = node.url else {
                errorMessage = "Couldn't locate this file on the volume."
                return
            }
            sourceURL = url
            preparePlayer(for: url)

        case .hyperDeck(let deck):
            guard let fileName = node.ftpPath else {
                errorMessage = "Couldn't locate this file on the deck."
                return
            }
            await downloadAndPlay(fileName: fileName, deck: deck)

        case .switcher:
            errorMessage = "This device doesn't expose a file system."
        }
    }

    private func downloadAndPlay(fileName: String, deck: HyperDeck) async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkSyncPreview", isDirectory: true)
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
            sourceURL = destination
            preparePlayer(for: destination)
        } else {
            errorMessage = result.failureReason ?? "Download failed."
        }
    }

    private func preparePlayer(for url: URL) {
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)

        // Covers the file being unreadable up front (bad container, etc).
        // AVFoundation can deliver this KVO change on a background queue, so
        // hop to the main actor before touching view state — mutating
        // @State off the main thread corrupts the SwiftUI view graph
        // instead of reliably erroring, which is what was crashing preview.
        item.publisher(for: \.status)
            .sink { status in
                Task { @MainActor in
                    switch status {
                    case .failed:
                        errorMessage = item.error?.localizedDescription
                            ?? "This file's format isn't supported for preview."
                        player = nil
                    case .readyToPlay:
                        await loadDuration(for: item)
                    default:
                        break
                    }
                }
            }
            .store(in: &cancellables)

        // Covers decode failures mid-playback (readable container, but a
        // codec AVFoundation can't fully decode — status alone won't catch
        // this, it just stalls silently while CoreMedia logs FigFilePlayer
        // errors to the console). Same main-actor hop as above and for the
        // same reason.
        NotificationCenter.default
            .publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .sink { notification in
                let underlying = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?
                    .localizedDescription
                Task { @MainActor in
                    errorMessage = underlying ?? "Playback failed — this file's codec may not be fully supported."
                    player = nil
                }
            }
            .store(in: &cancellables)

        player = newPlayer

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in currentTime = time.seconds }
        }

        newPlayer.play()
    }

    private func loadDuration(for item: AVPlayerItem) async {
        guard let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite, seconds > 0 else { return }
        duration = seconds
        if outPoint == 0 { outPoint = seconds }
    }

    // MARK: - Export

    private func exportClip() {
        guard let sourceURL, outPoint > inPoint else { return }

        let base = (node.name as NSString).deletingPathExtension
        let ext = (node.name as NSString).pathExtension.lowercased()
        let useMP4 = ext == "mp4"

        let panel = NSSavePanel()
        panel.title = "Export Clip"
        panel.nameFieldStringValue = "\(base)_clip.\(useMP4 ? "mp4" : "mov")"
        panel.allowedContentTypes = [useMP4 ? .mpeg4Movie : .quickTimeMovie]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let range = CMTimeRange(
            start: CMTime(seconds: inPoint, preferredTimescale: 600),
            end: CMTime(seconds: outPoint, preferredTimescale: 600)
        )

        exportError = nil
        isExporting = true
        exportProgress = 0

        Task {
            let success = await ConversionService.exportClip(
                input: sourceURL, output: destination, timeRange: range
            ) { pct in
                Task { @MainActor in exportProgress = pct }
            }

            isExporting = false
            if success {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } else {
                exportError = "Export failed. Try a shorter range or a different destination."
            }
        }
    }

    // MARK: - Cleanup

    private func cleanUp() {
        player?.pause()
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        cancellables.removeAll()
        if let downloadedFileURL {
            try? FileManager.default.removeItem(at: downloadedFileURL)
        }
    }
}

// MARK: - Player Container

/// Wraps AVKit's AppKit `AVPlayerView` directly rather than using SwiftUI's
/// `VideoPlayer` — see the comment above its call site in `VideoPlayerSheet`
/// for why.
private struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

// MARK: - Trim Bar

/// A compact timeline with two draggable handles for picking an in/out
/// range, plus a playhead showing the current position.
private struct TrimBarView: View {
    let duration: Double
    let currentTime: Double
    @Binding var inPoint: Double
    @Binding var outPoint: Double

    private let handleWidth: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let inX = position(for: inPoint, width: width)
            let outX = position(for: outPoint, width: width)
            let playX = position(for: currentTime, width: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 6)

                Capsule()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(0, outX - inX), height: 6)
                    .offset(x: inX)

                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: playX - 1)

                trimHandle
                    .offset(x: inX - handleWidth / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            let t = time(for: value.location.x, width: width)
                            inPoint = min(max(0, t), outPoint - 0.05)
                        }
                    )

                trimHandle
                    .offset(x: outX - handleWidth / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            let t = time(for: value.location.x, width: width)
                            outPoint = max(min(duration, t), inPoint + 0.05)
                        }
                    )
            }
            .frame(height: geo.size.height)
        }
    }

    private var trimHandle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: 24)
    }

    private func position(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1)) * width
    }

    private func time(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x, 0), width) / width) * duration
    }
}
