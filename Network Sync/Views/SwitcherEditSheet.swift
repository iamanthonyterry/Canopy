import SwiftUI

struct SwitcherEditSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let existingSwitcher: BlackmagicSwitcher?

    @State private var name      = ""
    @State private var ipAddress = ""
    @State private var model     = ""
    @State private var pingStatus: DeckStatus = .unknown
    @State private var isTesting = false

    @State private var savedConfigs: [ATEMSwitcherState] = []
    @State private var newConfigName = ""
    @State private var isSavingConfig = false
    @State private var restoringConfigID: UUID?
    @State private var configError: String?
    @State private var configToRestore: ATEMSwitcherState?

    init(switcher: BlackmagicSwitcher?) {
        existingSwitcher = switcher
        _name      = State(initialValue: switcher?.name      ?? "")
        _ipAddress = State(initialValue: switcher?.ipAddress ?? "")
        _model     = State(initialValue: switcher?.model     ?? "")
    }

    var canSave: Bool { !name.isEmpty && !ipAddress.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existingSwitcher == nil ? "Add ATEM Switcher" : "Edit ATEM Switcher")
                    .font(.title2).bold()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existingSwitcher == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.borderedProminent).disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            Form {
                Section("Device Info") {
                    LabeledContent("Name") {
                        TextField("e.g. Main ATEM", text: $name).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("IP Address") {
                        TextField("192.168.x.x", text: $ipAddress).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Model") {
                        TextField("e.g. ATEM Mini Pro", text: $model).textFieldStyle(.roundedBorder)
                    }
                }
                Section {
                    HStack {
                        Button(action: testConnection) {
                            if isTesting {
                                ProgressView().controlSize(.small)
                                Text("Testing…")
                            } else {
                                Label("Test Connection", systemImage: "network")
                            }
                        }.disabled(ipAddress.isEmpty || isTesting)
                        Spacer()
                        if pingStatus != .unknown {
                            Label(
                                pingStatus == .online ? "Connected" : "No Response",
                                systemImage: pingStatus == .online ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(pingStatus == .online ? .green : .red)
                            .font(.subheadline)
                        }
                    }
                }

                if existingSwitcher != nil {
                    configSection
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 440)
        .onAppear { loadConfigs() }
        .alert("Restore this config?", isPresented: .init(get: { configToRestore != nil }, set: { if !$0 { configToRestore = nil } })) {
            Button("Cancel", role: .cancel) { configToRestore = nil }
            Button("Restore", role: .destructive) {
                if let config = configToRestore { restore(config) }
                configToRestore = nil
            }
        } message: {
            Text("This immediately changes program, preview, and keyer state on the live switcher.")
        }
    }

    @ViewBuilder
    private var configSection: some View {
        Section("Saved Configs") {
            HStack {
                TextField("Config name", text: $newConfigName).textFieldStyle(.roundedBorder)
                Button(action: saveCurrentState) {
                    if isSavingConfig {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Save Current", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(newConfigName.isEmpty || isSavingConfig)
            }

            if savedConfigs.isEmpty {
                Text("No saved configs yet — capture the switcher's current program/preview/keyer state above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(savedConfigs) { config in
                HStack {
                    VStack(alignment: .leading) {
                        Text(config.name)
                        Text(config.savedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if restoringConfigID == config.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Restore") { configToRestore = config }
                        Button(role: .destructive) { deleteConfig(config) } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            if let configError {
                Text(configError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func loadConfigs() {
        guard let id = existingSwitcher?.id else { return }
        savedConfigs = ATEMConfigStore.list(for: id)
    }

    private func saveCurrentState() {
        guard let id = existingSwitcher?.id else { return }
        isSavingConfig = true; configError = nil
        let name = newConfigName
        Task {
            defer { isSavingConfig = false }
            do {
                var state = try await ATEMStateSession.capture(from: ipAddress)
                state.name = name
                try ATEMConfigStore.save(state, switcherID: id)
                newConfigName = ""
                loadConfigs()
            } catch {
                configError = error.localizedDescription
            }
        }
    }

    private func restore(_ config: ATEMSwitcherState) {
        restoringConfigID = config.id; configError = nil
        Task {
            defer { restoringConfigID = nil }
            do {
                try await ATEMRestoreService.restore(config, to: ipAddress)
            } catch {
                configError = error.localizedDescription
            }
        }
    }

    private func deleteConfig(_ config: ATEMSwitcherState) {
        guard let id = existingSwitcher?.id else { return }
        ATEMConfigStore.delete(config, switcherID: id)
        loadConfigs()
    }

    private func save() {
        if var s = existingSwitcher {
            s.name = name; s.ipAddress = ipAddress; s.model = model
            appState.updateSwitcher(s)
        } else {
            appState.addSwitcher(BlackmagicSwitcher(name: name, ipAddress: ipAddress, model: model))
        }
        dismiss()
    }

    private func testConnection() {
        isTesting = true; pingStatus = .unknown
        Task {
            pingStatus = await ATEMProbe.ping(host: ipAddress)
            isTesting = false
        }
    }
}
