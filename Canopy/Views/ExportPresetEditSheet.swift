import SwiftUI
import AppKit

// MARK: - Export Presets List
// Manage sheet reached from the Export Queue's "Manage Presets…" menu item —
// add, edit, or remove named export destinations.
struct ExportPresetsListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var editingPreset: ExportPreset?
    @State private var isAddingNew = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export Presets").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Rectangle().fill(Color.canopyRule).frame(height: 1)

            if appState.exportPresets.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "square.and.arrow.up.on.square")
                        .font(.system(size: 32)).foregroundStyle(Color.canopySage)
                    Text("No presets yet").foregroundStyle(.secondary)
                    Text("Save a destination and quality once, then export to it in one click.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(appState.exportPresets) { preset in
                        Button {
                            editingPreset = preset
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.system(size: 13, weight: .medium))
                                Text(preset.destinationPath)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets { appState.deleteExportPreset(id: appState.exportPresets[index].id) }
                    }
                }
                .listStyle(.inset)
            }

            Rectangle().fill(Color.canopyRule).frame(height: 1)
            HStack {
                Spacer()
                Button("Add Preset…") { isAddingNew = true }
                    .buttonStyle(.canopyPrimary)
            }
            .padding()
        }
        .frame(width: 420, height: 380)
        .background(Color.canopyPaper)
        .sheet(item: $editingPreset) { preset in
            ExportPresetEditSheet(preset: preset)
        }
        .sheet(isPresented: $isAddingNew) {
            ExportPresetEditSheet(preset: nil)
        }
    }
}

// MARK: - Export Preset Edit Sheet

struct ExportPresetEditSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let existingPreset: ExportPreset?

    @State private var name = ""
    @State private var destinationPath = ""
    @State private var isCompressed = false
    @State private var quality: ConversionSettings.FFmpegPreset = .fast

    init(preset: ExportPreset?) {
        existingPreset = preset
        _name = State(initialValue: preset?.name ?? "")
        _destinationPath = State(initialValue: preset?.destinationPath ?? "")
        if case .compressed(let quality) = preset?.mode {
            _isCompressed = State(initialValue: true)
            _quality = State(initialValue: quality)
        }
    }

    var canSave: Bool { !name.isEmpty && !destinationPath.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existingPreset == nil ? "Add Export Preset" : "Edit Export Preset")
                    .font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existingPreset == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.canopyPrimary).disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Rectangle().fill(Color.canopyRule).frame(height: 1)

            Form {
                Section("Preset") {
                    LabeledContent("Name") {
                        TextField("e.g. Social Team Drop", text: $name).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Destination") {
                        HStack(spacing: 8) {
                            Text(destinationPath.isEmpty ? "No folder chosen" : destinationPath)
                                .font(.caption)
                                .foregroundStyle(destinationPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                choosePath()
                            } label: {
                                Label("Choose…", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Section("Quality") {
                    Picker("", selection: $isCompressed) {
                        Text("Original Quality").tag(false)
                        Text("Compressed").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if isCompressed {
                        Picker("Preset", selection: $quality) {
                            ForEach(ConversionSettings.FFmpegPreset.allCases, id: \.self) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        Text(quality.description)
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Keeps the original codec — fast, no quality loss, larger files.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 440)
        .background(Color.canopyPaper)
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Destination"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationPath = url.path
        if name.isEmpty { name = url.lastPathComponent }
    }

    private func save() {
        let mode: ExportPreset.Mode = isCompressed ? .compressed(quality) : .original
        if var preset = existingPreset {
            preset.name = name; preset.destinationPath = destinationPath; preset.mode = mode
            appState.updateExportPreset(preset)
        } else {
            appState.addExportPreset(ExportPreset(name: name, destinationPath: destinationPath, mode: mode))
        }
        dismiss()
    }
}
