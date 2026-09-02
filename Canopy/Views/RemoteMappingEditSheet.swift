import SwiftUI

struct RemoteMappingEditSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let existingMapping: RemoteMapping?
    let onSave: (RemoteMapping) -> Void

    @ObservedObject private var osc = RemoteControlEngine.shared.osc
    @ObservedObject private var midi = RemoteControlEngine.shared.midi

    @State private var name: String
    @State private var triggerKind: TriggerKind
    @State private var oscAddress: String
    @State private var midiKind: MIDIMessage.Kind
    @State private var midiChannel: Int
    @State private var midiNumber: Int
    @State private var hyperDeckID: UUID?
    @State private var hyperDeckAction: HyperDeckRemoteAction

    @State private var isListeningOSC = false
    @State private var isListeningMIDI = false

    enum TriggerKind: String, CaseIterable, Identifiable {
        case osc = "OSC", midi = "MIDI"
        var id: String { rawValue }
    }

    init(mapping: RemoteMapping?, onSave: @escaping (RemoteMapping) -> Void) {
        existingMapping = mapping
        self.onSave = onSave

        _name = State(initialValue: mapping?.name ?? "")

        switch mapping?.trigger {
        case .osc(let address):
            _triggerKind = State(initialValue: .osc)
            _oscAddress  = State(initialValue: address)
            _midiKind    = State(initialValue: .noteOn)
            _midiChannel = State(initialValue: 0)
            _midiNumber  = State(initialValue: 0)
        case .midi(let kind, let channel, let number):
            _triggerKind = State(initialValue: .midi)
            _oscAddress  = State(initialValue: "")
            _midiKind    = State(initialValue: kind)
            _midiChannel = State(initialValue: channel)
            _midiNumber  = State(initialValue: number)
        case nil:
            _triggerKind = State(initialValue: .osc)
            _oscAddress  = State(initialValue: "")
            _midiKind    = State(initialValue: .noteOn)
            _midiChannel = State(initialValue: 0)
            _midiNumber  = State(initialValue: 0)
        }

        switch mapping?.target {
        case .hyperDeck(let id):
            _hyperDeckID = State(initialValue: id)
        case nil:
            _hyperDeckID = State(initialValue: nil)
        }

        switch mapping?.action {
        case .hyperDeck(let action):
            _hyperDeckAction = State(initialValue: action)
        case nil:
            _hyperDeckAction = State(initialValue: .record)
        }
    }

    var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if triggerKind == .osc && !oscAddress.hasPrefix("/") { return false }
        return hyperDeckID != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existingMapping == nil ? "Add Mapping" : "Edit Mapping")
                    .font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existingMapping == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.canopyPrimary).disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Rectangle().fill(Color.canopyRule).frame(height: 1)

            Form {
                Section("Name") {
                    TextField("e.g. Deck A Record", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                triggerSection
                deviceSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 480)
        .background(Color.canopyPaper)
        .onAppear(perform: selectDefaultTargetIfNeeded)
        .onChange(of: osc.receivedMessages.count) { _, _ in
            guard isListeningOSC, let last = osc.receivedMessages.last else { return }
            oscAddress = last.message.address
            isListeningOSC = false
        }
        .onChange(of: midi.receivedMessages.count) { _, _ in
            guard isListeningMIDI, let last = midi.receivedMessages.last else { return }
            midiKind = last.message.kind
            midiChannel = last.message.channel
            midiNumber = last.message.number
            isListeningMIDI = false
        }
    }

    private func selectDefaultTargetIfNeeded() {
        guard hyperDeckID == nil else { return }
        hyperDeckID = appState.hyperDecks.first?.id
    }

    private func save() {
        let trigger: RemoteTrigger = triggerKind == .osc
            ? .osc(address: oscAddress)
            : .midi(kind: midiKind, channel: midiChannel, number: midiNumber)

        guard let id = hyperDeckID else { return }
        let target: RemoteTarget = .hyperDeck(id)
        let action: RemoteAction = .hyperDeck(hyperDeckAction)

        var mapping = existingMapping ?? RemoteMapping(name: name, trigger: trigger, target: target, action: action)
        mapping.name = name
        mapping.trigger = trigger
        mapping.target = target
        mapping.action = action
        onSave(mapping)
        dismiss()
    }
}

// MARK: - Trigger

private extension RemoteMappingEditSheet {
    var triggerSection: some View {
        Section("Trigger") {
            Picker("Type", selection: $triggerKind) {
                ForEach(TriggerKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if triggerKind == .osc {
                LabeledContent("Address") {
                    TextField("/hyperdeck/record", text: $oscAddress)
                        .textFieldStyle(.roundedBorder)
                }
                listenRow(
                    isListening: $isListeningOSC,
                    isAvailable: osc.isListening,
                    unavailableHint: "Enable the OSC listener above first.",
                    label: "Listen for Next Message"
                )
            } else {
                LabeledContent("Captured") {
                    Text("\(midiKind.displayName) · Ch \(midiChannel + 1) · #\(midiNumber)")
                        .font(.callout.monospaced())
                }
                listenRow(
                    isListening: $isListeningMIDI,
                    isAvailable: midi.isListening,
                    unavailableHint: "Enable the MIDI listener above first, or set the values manually below.",
                    label: "Learn (press the button/key)"
                )
                Picker("Kind", selection: $midiKind) {
                    ForEach(MIDIMessage.Kind.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper("Channel \(midiChannel + 1)", value: $midiChannel, in: 0...15)
                Stepper("Number \(midiNumber)", value: $midiNumber, in: 0...127)
            }
        }
    }

    @ViewBuilder
    func listenRow(isListening: Binding<Bool>, isAvailable: Bool, unavailableHint: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isListening.wrappedValue.toggle()
            } label: {
                Label(
                    isListening.wrappedValue ? "Listening… (send it now)" : label,
                    systemImage: isListening.wrappedValue ? "dot.radiowaves.left.and.right" : "waveform"
                )
            }
            .disabled(!isAvailable)

            if !isAvailable {
                Text(unavailableHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Device & Action

private extension RemoteMappingEditSheet {
    var deviceSection: some View {
        Section("Device & Action") {
            if appState.hyperDecks.isEmpty {
                Text("No HyperDecks configured.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Device", selection: $hyperDeckID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(appState.hyperDecks) { deck in
                        Text(deck.name).tag(Optional(deck.id))
                    }
                }
                Picker("Action", selection: $hyperDeckAction) {
                    ForEach(HyperDeckRemoteAction.allCases) { action in
                        Label(action.title, systemImage: action.icon).tag(action)
                    }
                }
            }
        }
    }
}
