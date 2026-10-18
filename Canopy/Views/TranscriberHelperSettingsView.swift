import ChurchKitCore
import SwiftUI

/// Starts and stops the Transcriber helper and shows what it reports. Hidden in builds that don't include it.
struct TranscriberHelperSettingsView: View {
    @ObservedObject private var helper = TranscriberHelper.shared
    @ObservedObject private var account = SiteAccount.shared

    var body: some View {
        if helper.isBundled {
            GroupBox(label: Label("Transcriber", systemImage: "captions.bubble")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Start Transcriber when this Mac starts", isOn: Binding(
                        get: { helper.startsAtLogin },
                        set: { helper.setStartsAtLogin($0) }))

                    statusRow

                    HStack {
                        if helper.isRunning {
                            Button("Stop") { helper.stop() }.controlSize(.small)
                        } else {
                            Button("Start") { helper.start() }.controlSize(.small)
                        }
                        if helper.isChoosingCampus {
                            Button("Cancel") { helper.cancelChoosingCampus() }.controlSize(.small)
                            Text("Waiting for the browser…").font(.canopyCaption).foregroundStyle(.secondary)
                        } else {
                            Button(helper.knownCampus.isEmpty ? "Choose Campus…" : "Change Campus…") {
                                if let origin = account.origin { helper.chooseCampus(site: origin) }
                            }
                            .controlSize(.small)
                            .disabled(account.origin == nil)
                        }
                    }
                    Text("Other settings are in the Transcriber menu-bar icon.")
                        .font(.canopyCaption2).foregroundStyle(.tertiary)

                    ForEach(helper.duplicates, id: \.self) { url in
                        HStack {
                            Label("A separate copy of Transcriber is installed at \(url.path). Canopy's built-in copy replaces it.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.canopyCaption).foregroundStyle(Color.canopyRust)
                            Spacer()
                            Button("Move to Trash") { helper.removeStandalone(url) }.controlSize(.small)
                        }
                    }
                    if helper.needsApproval {
                        HStack {
                            Label("Allow Transcriber in System Settings → Login Items.", systemImage: "exclamationmark.triangle.fill")
                                .font(.canopyCaption).foregroundStyle(Color.canopyRust)
                            Spacer()
                            Button("Open Settings") { helper.openLoginItemsSettings() }.controlSize(.small)
                        }
                    }
                    if let error = helper.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.canopyCaption).foregroundStyle(Color.canopyRust)
                    }

                    Text("Live captions for your church website, from the sound board. It runs as its own app so it keeps going while Canopy is closed, and it updates along with Canopy.")
                        .font(.canopyCaption2).foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal)
            .background(Color.canopyPaper)
            .task {
                // Poll while this screen is showing; the task is cancelled when it goes away.
                while !Task.isCancelled {
                    helper.refresh()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        if !helper.isRunning {
            Label("Not running", systemImage: "circle")
                .font(.canopyCaption).foregroundStyle(.secondary)
        } else if let s = helper.status {
            VStack(alignment: .leading, spacing: 4) {
                Label(s.listening ? "Listening" : "Running, not listening",
                      systemImage: s.listening ? "waveform.circle.fill" : "pause.circle")
                    .font(.canopyCaption).foregroundStyle(s.listening ? Color.canopySage : .secondary)
                Text(s.connectedTo.isEmpty ? "Not signed in to a campus yet" : "Sending to \(s.connectedTo)")
                    .font(.canopyCaption).foregroundStyle(.secondary)
                if let warning = s.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.canopyCaption).foregroundStyle(Color.canopyRust)
                }
            }
        } else {
            Label("Running", systemImage: "circle.fill")
                .font(.canopyCaption).foregroundStyle(Color.canopySage)
        }
    }
}
