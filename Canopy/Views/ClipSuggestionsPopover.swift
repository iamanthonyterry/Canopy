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
        case writingCopy(done: Int, total: Int)
        case failed(String)
    }

    @Published var candidates: [ClipCandidate] = []
    @Published var selected: Set<UUID> = []
    @Published var status: Status = .idle
    @Published var postOptions = SocialPostExporter.Options()
    @Published var copyPlatform = CopyPlatform.general
    /// What the next Find Clips run looks for.
    @Published var focus = ClipFocus()

    var isBusy: Bool {
        switch status {
        case .transcribing, .finding, .exporting, .writingCopy: return true
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
        focus = saved.focus ?? ClipFocus()
    }

    func find(in url: URL) {
        task?.cancel()
        status = .transcribing
        var options = ClipFinderOptions()
        options.focus = focus
        task = Task {
            do {
                var transcript = Transcript.load(for: url)
                if transcript == nil {
                    let made = try await TranscriptionService.transcribe(video: url, localeID: Locale.current.identifier)
                    try? made.write(for: url)
                    transcript = made
                }
                // Music can be found without any words to go on.
                guard let transcript, !transcript.segments.isEmpty || options.focus.kinds.contains(.music) else {
                    status = .failed("No speech was found in this video.")
                    return
                }
                status = .finding(0)
                let found = try await ClipFinder.findClips(in: transcript, video: url, options: options, progress: { pct in
                    // Progress hops back to the main actor asynchronously, so it can
                    // land after the run has finished — only apply it while still finding.
                    Task { @MainActor in
                        if case .finding = self.status { self.status = .finding(pct) }
                    }
                })
                try? ClipSuggestions(sourceFileName: url.lastPathComponent, generatedAt: Date(), candidates: found,
                                     focus: options.focus.isEmpty ? nil : options.focus).write(for: url)
                candidates = found
                selected = []
                status = found.isEmpty
                    ? .failed(options.focus.isEmpty ? "Nothing stood out as a standalone clip."
                                                    : "Nothing matched what you're looking for. Try widening it.")
                    : .idle
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

    /// Renders each ticked clip as a finished post (cropped to the chosen
    /// format, optionally captioned) into `folder`.
    func exportPosts(from source: URL, to folder: URL) {
        let chosen = candidates.filter { selected.contains($0.id) }.sorted { $0.start < $1.start }
        guard !chosen.isEmpty else { return }
        let base = source.deletingPathExtension().lastPathComponent
        let options = postOptions
        let transcript = Transcript.load(for: source)

        status = .exporting(done: 0, total: chosen.count)
        task = Task {
            var failures = 0
            var firstError: String?
            for (i, clip) in chosen.enumerated() {
                if Task.isCancelled { break }
                let output = folder.appendingPathComponent(
                    SocialPostExporter.fileName(base: base, index: i + 1, title: clip.title, format: options.format)
                )
                do {
                    try await SocialPostExporter.export(source: source, clip: clip, transcript: transcript, options: options, output: output)
                } catch {
                    failures += 1
                    firstError = firstError ?? error.localizedDescription
                }
                status = .exporting(done: i + 1, total: chosen.count)
            }
            if failures > 0 {
                status = .failed("\(failures) post\(failures == 1 ? "" : "s") couldn't be rendered: \(firstError ?? "unknown error")")
            } else {
                status = .idle
                onExported(folder)
            }
        }
    }

    /// Drafts post copy for every clip that doesn't have any yet, saving it
    /// with the suggestions.
    func writeCopy(for source: URL) {
        guard let transcript = Transcript.load(for: source) else {
            status = .failed("There's no transcript for this video yet — find clips first.")
            return
        }
        let pending = candidates.indices.filter { candidates[$0].copy == nil }
        guard !pending.isEmpty else { return }
        let platform = copyPlatform

        status = .writingCopy(done: 0, total: pending.count)
        task = Task {
            var firstError: String?
            for (n, index) in pending.enumerated() {
                if Task.isCancelled { break }
                do {
                    candidates[index].copy = try await PostCopyWriter.write(
                        for: candidates[index], transcript: transcript, platform: platform, hashtagCount: 5
                    )
                } catch {
                    firstError = firstError ?? error.localizedDescription
                }
                status = .writingCopy(done: n + 1, total: pending.count)
            }
            try? ClipSuggestions(sourceFileName: source.lastPathComponent, generatedAt: Date(), candidates: candidates,
                                 focus: ClipSuggestions.load(for: source)?.focus)
                .write(for: source)
            status = firstError.map { .failed($0) } ?? .idle
        }
    }

    static func slug(_ title: String) -> String { SocialPostExporter.slug(title) }
}

// MARK: - View

/// The "what to look for" controls, shared by the player's Find Clips panel
/// and the Find Clips workflow step.
struct ClipFocusFields: View {
    @Binding var focus: ClipFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(ClipKind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(get: { focus.kinds.contains(kind) }, set: { focus.set(kind, on: $0) }))
                }
            }
            .toggleStyle(.checkbox)
            TextField("Anything specific", text: $focus.notes, prompt: Text("Anything specific? e.g. quotes about hope"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            Text("Leave empty to find whatever stands out. Music is found by listening to the audio; everything else comes from what's said.")
                .font(.canopyCaption).foregroundStyle(.secondary)
        }
        .font(.canopyCallout)
    }
}

struct ClipSuggestionsPopover: View {
    @ObservedObject var model: ClipSuggestionsModel
    let sourceURL: URL?
    var onPreview: (ClipCandidate) -> Void
    @State private var showsFocus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Find Clips", systemImage: "sparkles").font(.canopyHeadline)
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
            case .writingCopy(let done, let total):
                progressRow("Writing copy \(done) of \(total)…", value: Double(done) / Double(max(total, 1)))
            case .failed(let message):
                Text(message).font(.canopyCallout).foregroundStyle(Color.canopyRust)
            case .idle:
                EmptyView()
            }

            if model.candidates.isEmpty {
                if !model.isBusy { emptyState }
            } else {
                if !model.isBusy { focusDisclosure }
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
                .font(.canopyCallout).foregroundStyle(.secondary)
            ClipFocusFields(focus: $model.focus)
            Button("Find Clips") { if let sourceURL { model.find(in: sourceURL) } }
                .buttonStyle(.borderedProminent)
                .disabled(sourceURL == nil)
        }
    }

    /// Lets the focus be changed before a Redo without crowding the list.
    private var focusDisclosure: some View {
        DisclosureGroup(isExpanded: $showsFocus) {
            ClipFocusFields(focus: $model.focus).padding(.top, 6)
        } label: {
            Text(model.focus.isEmpty ? "Looking for whatever stands out" : "Looking for \(model.focus.summary)")
                .font(.canopyCaption).foregroundStyle(.secondary).lineLimit(1)
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
                    Text(clip.title).font(.canopySubheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text("\(clip.score)")
                        .font(.canopyCaption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.canopySage.opacity(0.25), in: Capsule())
                        .help("Strength as a standalone clip, 0–100")
                }
                Text("\(Self.time(clip.start)) – \(Self.time(clip.end)) · \(Int(clip.duration.rounded()))s")
                    .font(.canopyCaption.monospacedDigit()).foregroundStyle(.secondary)
                if !clip.openingLine.isEmpty {
                    Text("“\(clip.openingLine)”")
                        .font(.canopyCaption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !clip.reason.isEmpty {
                    Text(clip.reason).font(.canopyCaption).foregroundStyle(.secondary.opacity(0.8)).lineLimit(2)
                }
                if let copy = clip.copy {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(copy.headline).font(.canopyCaption.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(copy.postText, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.plain)
                                .help("Copy the caption and hashtags")
                        }
                        Text(copy.postText).font(.canopyCaption).foregroundStyle(.secondary).lineLimit(4)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
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
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Picker("Format", selection: $model.postOptions.format) {
                    ForEach(SocialFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Captions", isOn: $model.postOptions.captions)
                Toggle("Follow subject", isOn: $model.postOptions.followSubject)
            }
            .toggleStyle(.checkbox)
            .font(.canopyCallout)

            HStack {
                Text("\(model.selected.count) selected").font(.canopyCaption).foregroundStyle(.secondary)
                Spacer()
                Button("Write Copy") { if let sourceURL { model.writeCopy(for: sourceURL) } }
                    .disabled(model.isBusy || sourceURL == nil || !model.candidates.contains { $0.copy == nil })
                    .help("Draft a caption and hashtags for each clip")
                Button("Export Clips…") { chooseFolder { model.exportSelected(from: $0, to: $1) } }
                    .disabled(model.selected.isEmpty || model.isBusy || sourceURL == nil)
                    .help("Plain trimmed copies, same shape as the original")
                Button("Export Posts…") { chooseFolder { model.exportPosts(from: $0, to: $1) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty || model.isBusy || sourceURL == nil)
                    .help("Cropped to the chosen format with captions burned in")
            }
        }
    }

    private func progressRow(_ text: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.canopyCallout).foregroundStyle(.secondary)
            if let value { ProgressView(value: value) } else { ProgressView().controlSize(.small) }
        }
    }

    private func chooseFolder(_ export: (URL, URL) -> Void) {
        guard let sourceURL else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for the Exported Clips"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        export(sourceURL, folder)
    }

    static func time(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
