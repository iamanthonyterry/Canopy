import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Export/import Workflows + Device Settings (HyperDecks, Cloud Stores,
/// Local Folders) as a single CSV file — for backing up this Mac's setup or
/// copying it to another one.
struct DataBackupView: View {
    @EnvironmentObject var appState: AppState

    @State private var showingExportOptions = false
    @State private var includeCredentials = false
    @State private var resultMessage: String?
    @State private var isError = false

    var body: some View {
        GroupBox(label: Label("Backup", systemImage: "square.and.arrow.up.on.square")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Export every workflow and device setting (HyperDecks, Cloud Stores, Local Folders) to a CSV file, or import one to restore or copy them to this Mac.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                HStack {
                    Button {
                        showingExportOptions = true
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.canopySecondary)

                    Button {
                        importCSV()
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.canopySecondary)
                }

                if let resultMessage {
                    Text(resultMessage)
                        .font(.caption)
                        .foregroundStyle(isError ? Color.canopyRust : .secondary)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
        .popover(isPresented: $showingExportOptions) {
            exportOptions
        }
    }

    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Backup").font(.headline)

            Toggle("Include device usernames & passwords", isOn: $includeCredentials)
                .toggleStyle(.checkbox)

            Text(includeCredentials
                 ? "The file will contain plain-text credentials — keep it somewhere private."
                 : "Credentials are left blank; you'll re-enter them after importing.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 260, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") { showingExportOptions = false }
                Button("Export…") {
                    showingExportOptions = false
                    exportCSV()
                }
                .buttonStyle(.canopyPrimary)
            }
        }
        .padding()
        .frame(width: 300)
    }

    // MARK: - Export

    private func exportCSV() {
        let csv = BackupCSVService.export(
            hyperDecks: appState.hyperDecks,
            cloudStores: appState.cloudStores,
            localFolders: appState.localFolders,
            workflows: appState.workflows,
            includeCredentials: includeCredentials
        )

        let stamp = Date().formatted(
            Date.FormatStyle().year().month(.twoDigits).day(.twoDigits)
        )

        let panel = NSSavePanel()
        panel.title = "Export Canopy Backup"
        panel.nameFieldStringValue = "Canopy-Backup-\(stamp).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            isError = false
            resultMessage = "Exported \(appState.hyperDecks.count + appState.cloudStores.count + appState.localFolders.count) device(s) and \(appState.workflows.count) workflow(s)."
        } catch {
            isError = true
            resultMessage = "Couldn't write file: \(error.localizedDescription)"
        }
    }

    // MARK: - Import

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.title = "Import Canopy Backup"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try BackupCSVService.importCSV(text)
            let summary = appState.importBackup(parsed)
            isError = false
            resultMessage = "Imported \(summary.devices) device(s) and \(summary.workflows) workflow(s)."
        } catch {
            isError = true
            resultMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
