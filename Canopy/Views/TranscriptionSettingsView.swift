import SwiftUI

/// Chooses the engine that turns video audio into a transcript. Apple's
/// built-in recognizer is the default and needs no download; Whisper trades a
/// one-time download for better accuracy on names and rougher audio. The
/// download is shared with the Transcriber helper.
struct TranscriptionSettingsView: View {
    @ObservedObject private var models = WhisperModels.shared

    var body: some View {
        GroupBox(label: Label("Transcription", systemImage: "waveform")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Engine", selection: $models.engine) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if models.engine == .whisper {
                    Picker("Model", selection: $models.variant) {
                        ForEach(WhisperVariant.allCases) { variant in
                            Text(variant.title).tag(variant)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(isDownloading)

                    Text(models.variant.detail).font(.canopyCaption).foregroundStyle(.secondary)
                    downloadRow
                }

                note("Used for captions, clip finding and post copy. Runs entirely on this Mac. Models are kept in a folder shared with Transcriber, so one already downloaded there shows as ready. If Whisper isn't ready, Apple's recognizer is used.")
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
        .background(Color.canopyPaper)
        .onAppear { models.refresh() }
    }

    private var isDownloading: Bool {
        if case .downloading = models.downloadState { return true }
        return false
    }

    @ViewBuilder private var downloadRow: some View {
        switch models.downloadState {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction).tint(Color.canopySage)
                HStack {
                    Text("Downloading… \(Int(fraction * 100))%")
                        .font(.canopyCaption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { models.cancelDownload() }
                        .controlSize(.small)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.canopyCaption).foregroundStyle(Color.canopyRust)
                Button("Try Again") { models.download() }.controlSize(.small)
            }
        case .idle:
            if models.isDownloaded {
                HStack {
                    Label("Ready — in use", systemImage: "checkmark.circle.fill")
                        .font(.canopyCaption).foregroundStyle(Color.canopySage)
                    Spacer()
                    Button("Delete Download", role: .destructive) { models.deleteDownload() }
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Text("Not downloaded yet. Until it is, Apple's recognizer is used.")
                        .font(.canopyCaption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Download") { models.download() }
                        .buttonStyle(.canopyPrimary)
                        .controlSize(.small)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.canopyCaption2).foregroundStyle(.tertiary)
    }
}
