import SwiftUI

/// Opt-in switch for a larger on-device model. Apple's built-in model stays
/// the default; this lets people with the memory and disk to spare trade a
/// one-time download for noticeably better workflow building, clip finding
/// and post copy. Everything still runs on this Mac.
struct AIModelSettingsView: View {
    @ObservedObject private var models = AIModels.shared

    var body: some View {
        GroupBox(label: Label("On-Device AI", systemImage: "sparkles")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Use an enhanced model", isOn: $models.useEnhanced)
                    .disabled(!models.isSupported)

                if !models.isSupported {
                    note("The enhanced model needs macOS 27 or later. Apple's built-in model is used instead.")
                } else if models.useEnhanced {
                    Picker("Model", selection: $models.choice) {
                        ForEach(EnhancedModelChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(isDownloading)

                    Text(models.choice.detail).font(.canopyCaption).foregroundStyle(.secondary)

                    downloadRow
                }

                note("Used to build and edit workflows from plain language, find clips in long videos, and write post copy. Runs entirely on this Mac. If it can't answer, Canopy falls back to Apple's built-in model.")
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
        .background(Color.canopyPaper)
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
                    Text("Not downloaded yet. Until it is, Apple's built-in model is used.")
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
