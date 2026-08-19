import SwiftUI
import AVKit
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import Combine

// Presented by DeviceFilesBrowser when the user plays a video file so they
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

    // Custom transport state — AVPlayerView's native chrome is disabled
    // (see PlayerContainerView) so this view drives play/pause and
    // scrubbing itself.
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var wasPlayingBeforeScrub = false

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
            ZStack(alignment: .bottom) {
                Color.black

                PlayerContainerView(player: player)
                    .onTapGesture { togglePlayback() }

                if player == nil {
                    statusOverlay
                } else {
                    playerControls
                }
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

    // MARK: - Player Controls

    /// One unified control surface overlaid on the video itself — a single
    /// scrub bar that doubles as the in/out range selector, transport, and
    /// export, all in the same translucent panel. Deliberately not a
    /// separate SwiftUI section bolted on below the native player chrome
    /// (see PlayerContainerView): the goal is one cohesive player, not a
    /// native control strip with add-ons underneath it.
    @ViewBuilder
    private var playerControls: some View {
        VStack(spacing: 10) {
            if duration > 0 {
                HStack(spacing: 10) {
                    Text(timeString(currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 52, alignment: .leading)

                    PlaybackTimelineView(
                        duration: duration,
                        currentTime: $currentTime,
                        inPoint: $inPoint,
                        outPoint: $outPoint,
                        onScrubBegan: beginScrub,
                        onScrubChanged: scrub,
                        onScrubEnded: endScrub
                    )
                    .frame(height: 24)

                    Text(timeString(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 52, alignment: .trailing)
                }
            }

            HStack(spacing: 20) {
                playerIconButton("arrow.right.to.line", help: "Set In Point to current playhead") {
                    inPoint = min(currentTime, max(0, outPoint - 0.05))
                }

                Spacer()

                playerIconButton(isPlaying ? "pause.fill" : "play.fill", size: 20, help: isPlaying ? "Pause" : "Play") {
                    togglePlayback()
                }

                Spacer()

                playerIconButton("arrow.left.to.line", help: "Set Out Point to current playhead") {
                    outPoint = max(currentTime, min(duration, inPoint + 0.05))
                }

                if duration > 0 {
                    Text("Clip \(timeString(max(0, outPoint - inPoint)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }

                if isExporting {
                    ProgressView(value: exportProgress)
                        .frame(width: 90)
                } else {
                    Button {
                        exportClip()
                    } label: {
                        Text("Export Clip…")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.black)
                    .disabled(sourceURL == nil || outPoint <= inPoint)
                    .opacity(sourceURL == nil || outPoint <= inPoint ? 0.5 : 1)
                }
            }

            if let exportError {
                Text(exportError)
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.55), .black.opacity(0.8)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private func playerIconButton(_ systemImage: String, size: CGFloat = 15, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Transport

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func beginScrub() {
        wasPlayingBeforeScrub = isPlaying
        player?.pause()
        isScrubbing = true
    }

    private func scrub(to time: Double) {
        currentTime = time
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func endScrub() {
        isScrubbing = false
        if wasPlayingBeforeScrub {
            player?.play()
            isPlaying = true
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
            Task { @MainActor in
                guard !isScrubbing else { return }
                currentTime = time.seconds
            }
        }

        newPlayer.play()
        isPlaying = true
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
/// for why. `controlsStyle = .none` strips all of AVPlayerView's own
/// transport chrome so the only controls on screen are the custom ones in
/// `playerControls` — one unified player instead of native controls with a
/// trim bar bolted on underneath.
private struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

// MARK: - Playback Timeline

/// The single scrub bar: dragging anywhere on the track seeks playback, and
/// two handles mark the in/out range that will be exported. One control
/// does both jobs instead of a separate native scrubber plus a bolted-on
/// trim bar.
private struct PlaybackTimelineView: View {
    let duration: Double
    @Binding var currentTime: Double
    @Binding var inPoint: Double
    @Binding var outPoint: Double
    let onScrubBegan: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: () -> Void

    private let handleWidth: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let inX = position(for: inPoint, width: width)
            let outX = position(for: outPoint, width: width)
            let playX = position(for: currentTime, width: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: max(0, outX - inX), height: 4)
                    .offset(x: inX)

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(height: geo.size.height)
                    .gesture(scrubGesture(width: width))

                Circle()
                    .fill(Color.white)
                    .shadow(radius: 1)
                    .frame(width: 12, height: 12)
                    .offset(x: playX - 6)
                    .allowsHitTesting(false)

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

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    onScrubBegan()
                }
                onScrubChanged(time(for: value.location.x, width: width))
            }
            .onEnded { value in
                onScrubChanged(time(for: value.location.x, width: width))
                onScrubEnded()
                isDragging = false
            }
    }

    @State private var isDragging = false

    private var trimHandle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
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
