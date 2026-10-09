import SwiftUI
import AVFoundation
import Combine

// MARK: - Model

/// Drives the player's "Find Clips" panel: loads saved suggestions, runs
/// transcription + clip finding when there are none, and exports the ones
/// the user ticks.
@MainActor
final class ClipSuggestionsModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case transcribing
        case finding(Double)
        case exporting(done: Int, total: Int)
        case failed(String)
    }

    @Published var candidates: [ClipCandidate] = []
    @Published var selected: Set<UUID> = []
    @Published var status: Status = .idle

    var isBusy: Bool {
        switch status {
        case .transcribing, .finding, .exporting: return true
        default: return false
        }
    }

    /// What to do with the output folder once an export finishes.
    var onExported: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    private var task: Task<Void, Never>?
    /// The running find/export, so a test can wait for it.
    var currentTask: Task<Void, Never>? { task }

    func load(for url: URL?) {
        guard let url, let saved = ClipSuggestions.load(for: url) else { return }
        candidates = saved.candidates
        selected = []
    }

    func find(in url: URL) {
        task?.cancel()
        status = .transcribing
        task = Task {
            do {
                var transcript = Transcript.load(for: url)
                if transcript == nil {
                    let made = try await TranscriptionService.transcribe(video: url, localeID: Locale.current.identifier)
                    try? made.write(for: url)
                    transcript = made
                }
                guard let transcript, !transcript.segments.isEmpty else {
                    status = .failed("No speech was found in this video.")
                    return
                }
                status = .finding(0)
                let found = try await ClipFinder.findClips(in: transcript) { pct in
                    // Progress hops back to the main actor asynchronously, so it can
                    // land after the run has finished — only apply it while still finding.
                    Task { @MainActor [weak self] in
                        if case .finding = self?.status { self?.status = .finding(pct) }
                    }
                }
                try? ClipSuggestions(sourceFileName: url.lastPathComponent, generatedAt: Date(), candidates: found).write(for: url)
                candidates = found
                selected = []
                status = found.isEmpty ? .failed("Nothing stood out as a standalone clip.") : .idle
            } catch is CancellationError {
                status = .idle
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel(); status = .idle }

    func toggle(_ candidate: ClipCandidate) {
        if selected.contains(candidate.id) { selected.remove(candidate.id) } else { selected.insert(candidate.id) }
    }

    /// Exports each ticked clip as its own file in `folder`.
    func exportSelected(from source: URL, to folder: URL) {
        let chosen = candidates.filter { selected.contains($0.id) }.sorted { $0.start < $1.start }
        guard !chosen.isEmpty else { return }
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.lowercased() == "mp4" ? "mp4" : "mov"

        status = .exporting(done: 0, total: chosen.count)
        task = Task {
            var failures = 0
            for (i, clip) in chosen.enumerated() {
                if Task.isCancelled { break }
                let name = String(format: "%@_clip%02d_%@.%@", base, i + 1, Self.slug(clip.title), ext)
                let range = CMTimeRange(
                    start: CMTime(seconds: clip.start, preferredTimescale: 600),
                    end: CMTime(seconds: clip.end, preferredTimescale: 600)
                )
                let outcome = await ConversionService.exportClip(
                    input: source, output: folder.appendingPathComponent(name), timeRange: range
                ) { _ in }
                if case .success = outcome {} else { failures += 1 }
                status = .exporting(done: i + 1, total: chosen.count)
            }
            if failures > 0 {
                status = .failed("\(failures) clip\(failures == 1 ? "" : "s") couldn't be exported.")
            } else {
                status = .idle
                onExported(folder)
            }
        }
    }

    static func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let words = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        let joined = String(words).split(separator: " ").prefix(6).joined(separator: "-")
        return joined.isEmpty ? "clip" : joined
    }
}

// MARK: - View

struct ClipSuggestionsPopover: View {
    @ObservedObject var model: ClipSuggestionsModel
    let sourceURL: URL?
    var onPreview: (ClipCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Find Clips", systemImage: "sparkles").font(.headline)
                Spacer()
                if !model.candidates.isEmpty, !model.isBusy {
                    Button("Redo") { if let sourceURL { model.find(in: sourceURL) } }
                        .buttonStyle(.link).disabled(sourceURL == nil)
                }
            }

            switch model.status {
            case .transcribing:
                progressRow("Transcribing the video…", value: nil)
            case .finding(let pct):
                progressRow("Looking for standalone moments…", value: pct)
            case .exporting(let done, let total):
                progressRow("Exporting \(done) of \(total)…", value: Double(done) / Double(max(total, 1)))
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(Color.canopyRust)
            case .idle:
                EmptyView()
            }

            if model.candidates.isEmpty {
                if !model.isBusy { emptyState }
            } else {
                list
                footer
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggests moments in this video that would work as short social posts, using the transcript. Runs entirely on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Find Clips") { if let sourceURL { model.find(in: sourceURL) } }
                .buttonStyle(.borderedProminent)
                .disabled(sourceURL == nil)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.candidates) { clip in
                    row(clip)
                }
            }
        }
        .frame(maxHeight: 340)
    }

    private func row(_ clip: ClipCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { model.selected.contains(clip.id) }, set: { _ in model.toggle(clip) }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(clip.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text("\(clip.score)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.canopySage.opacity(0.25), in: Capsule())
                        .help("Strength as a standalone clip, 0–100")
                }
                Text("\(Self.time(clip.start)) – \(Self.time(clip.end)) · \(Int(clip.duration.rounded()))s")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("“\(clip.openingLine)”")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if !clip.reason.isEmpty {
                    Text(clip.reason).font(.caption).foregroundStyle(.secondary.opacity(0.8)).lineLimit(2)
                }
            }
            Button { onPreview(clip) } label: { Image(systemName: "play.circle.fill").font(.title3) }
                .buttonStyle(.plain)
                .help("Jump to this clip in the player")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
    }

    private var footer: some View {
        HStack {
            Text("\(model.selected.count) selected").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Export Selected…") { chooseFolderAndExport() }
                .buttonStyle(.borderedProminent)
                .disabled(model.selected.isEmpty || model.isBusy || sourceURL == nil)
        }
    }

    private func progressRow(_ text: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.callout).foregroundStyle(.secondary)
            if let value { ProgressView(value: value) } else { ProgressView().controlSize(.small) }
        }
    }

    private func chooseFolderAndExport() {
        guard let sourceURL else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Selected Clips"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.exportSelected(from: sourceURL, to: folder)
    }

    static func time(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
