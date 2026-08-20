import SwiftUI

struct RemoteControlSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var osc = RemoteControlEngine.shared.osc
    @ObservedObject private var midi = RemoteControlEngine.shared.midi

    @State private var sheetContext: MappingSheetContext?

    var body: some View {
        GroupBox(label: Label("Remote Control (OSC & MIDI)", systemImage: "dot.radiowaves.left.and.right")) {
            VStack(alignment: .leading, spacing: 16) {
                oscSection
                Divider()
                midiSection
                Divider()
                mappingsSection
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal)
        .sheet(item: $sheetContext) { context in
            RemoteMappingEditSheet(mapping: context.mapping) { saved in
                if context.mapping != nil {
                    appState.updateRemoteMapping(saved)
                } else {
                    appState.addRemoteMapping(saved)
                }
            }
        }
        .onChange(of: appState.remoteControlSettings) { _, _ in
            RemoteControlEngine.shared.applySettings()
        }
    }

    // MARK: - Sheet identity

    struct MappingSheetContext: Identifiable {
        let id = UUID()
        var mapping: RemoteMapping?
    }
}

// MARK: - OSC

private extension RemoteControlSettingsView {
    var oscSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $appState.remoteControlSettings.oscEnabled) {
                Text("Enable OSC Listener")
            }

            if appState.remoteControlSettings.oscEnabled {
                HStack(spacing: 12) {
                    Text("Port")
                    TextField("Port", value: $appState.remoteControlSettings.oscPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    statusBadge(isActive: osc.isListening, error: osc.lastError)
                }

                if !osc.receivedMessages.isEmpty {
                    DisclosureGroup("Recent Messages (\(osc.receivedMessages.count))") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(osc.receivedMessages.suffix(10).reversed()) { entry in
                                Text("\(Self.timeFormatter.string(from: entry.timestamp))  \(entry.message.address)  ·  \(entry.sourceHost)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                Text("Built in: **/hyperdeck/{name}/slot/{n}/format/{fs}** always formats that slot on the matching device by name — e.g. /hyperdeck/ISO_1/slot/3/format/HFS+. No mapping needed below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - MIDI

private extension RemoteControlSettingsView {
    var midiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $appState.remoteControlSettings.midiEnabled) {
                Text("Enable MIDI Listener")
            }

            if appState.remoteControlSettings.midiEnabled {
                HStack {
                    statusBadge(isActive: midi.isListening, error: midi.lastError)
                    Spacer()
                    Button("Refresh Sources") { midi.refreshSources() }
                        .buttonStyle(.link)
                        .font(.caption)
                }

                if midi.availableSources.isEmpty {
                    Text("No MIDI sources found. Connect a controller, or enable a virtual/network MIDI session in Audio MIDI Setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("All Sources", isOn: allSourcesBinding)
                        .font(.caption)
                    ForEach(midi.availableSources) { source in
                        Toggle(source.name, isOn: sourceBinding(source.name))
                            .font(.caption)
                            .padding(.leading, 16)
                            .disabled(allSourcesBinding.wrappedValue)
                    }
                }

                if !midi.receivedMessages.isEmpty {
                    DisclosureGroup("Recent Messages (\(midi.receivedMessages.count))") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(midi.receivedMessages.suffix(10).reversed()) { entry in
                                Text("\(Self.timeFormatter.string(from: entry.timestamp))  \(entry.message.kind.displayName)  ·  Ch \(entry.message.channel + 1)  ·  #\(entry.message.number)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    var allSourcesBinding: Binding<Bool> {
        Binding(
            get: { appState.remoteControlSettings.midiSourceNames.isEmpty },
            set: { isAll in
                appState.remoteControlSettings.midiSourceNames =
                    isAll ? [] : Set(midi.availableSources.map(\.name))
            }
        )
    }

    func sourceBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { appState.remoteControlSettings.midiSourceNames.contains(name) },
            set: { isOn in
                if isOn {
                    appState.remoteControlSettings.midiSourceNames.insert(name)
                } else {
                    appState.remoteControlSettings.midiSourceNames.remove(name)
                }
            }
        )
    }
}

// MARK: - Mappings

private extension RemoteControlSettingsView {
    var mappingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Mappings").bold()
                Spacer()
                Button {
                    sheetContext = MappingSheetContext(mapping: nil)
                } label: {
                    Label("Add Mapping", systemImage: "plus")
                }
                .disabled(appState.hyperDecks.isEmpty && appState.switchers.isEmpty)
            }

            if appState.hyperDecks.isEmpty && appState.switchers.isEmpty {
                Text("Add a HyperDeck or ATEM switcher first to create a remote-control mapping.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if appState.remoteMappings.isEmpty {
                Text("No mappings yet — add one to let an OSC or MIDI trigger control a device.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(appState.remoteMappings.sorted { $0.sortOrder < $1.sortOrder }) { mapping in
                    mappingRow(mapping)
                }
            }
        }
    }

    func mappingRow(_ mapping: RemoteMapping) -> some View {
        let deviceName: String
        switch mapping.target {
        case .hyperDeck(let id):
            deviceName = appState.hyperDecks.first { $0.id == id }?.name ?? "Unknown Device"
        case .switcher(let id):
            deviceName = appState.switchers.first { $0.id == id }?.name ?? "Unknown Device"
        }

        return HStack {
            Toggle("", isOn: Binding(
                get: { mapping.isEnabled },
                set: { newValue in
                    var updated = mapping
                    updated.isEnabled = newValue
                    appState.updateRemoteMapping(updated)
                }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(mapping.name)
                Text("\(mapping.trigger.displayText)  →  \(mapping.action.title) on \(deviceName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                sheetContext = MappingSheetContext(mapping: mapping)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                appState.deleteRemoteMapping(id: mapping.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Shared helpers

private extension RemoteControlSettingsView {
    @ViewBuilder
    func statusBadge(isActive: Bool, error: String?) -> some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if isActive {
            Label("Listening", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("Stopped", systemImage: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }
}
