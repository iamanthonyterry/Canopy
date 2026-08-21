import SwiftUI

/// Small focused sheet for configuring a single workflow step.
/// Only shows fields relevant to that step's kind.
struct WorkflowStepConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var step: WorkflowStep

    // Local editable copies so Cancel doesn't mutate the caller's step.
    @State private var preset: ConversionSettings.FFmpegPreset = .fast
    @State private var deleteOriginal = true
    @State private var maxParallelJobs = 2
    @State private var pattern = ""
    @State private var retentionDays = 30
    @State private var controlCommand: DeckCommand = .start
    @State private var stopRecordingAutomatically = false
    @State private var stopAfterMinutes = 5
    @State private var waitValue = 1
    @State private var waitUnit: WaitUnit = .hours
    @State private var notifyHeader = ""
    @State private var notifyMessage = ""
    @State private var notifyRecipients: [NotificationRecipient] = []
    @State private var notifySendPerDrive = true
    @State private var showingAddRecipient = false
    @State private var requiresConfirmation = false

    // Tracks which notify field a variable pill should insert into — the
    // one that most recently had the cursor, since tapping a pill steals
    // focus away from the text field before the insert happens.
    private enum NotifyField: Hashable { case header, message }
    @FocusState private var notifyFocusedField: NotifyField?
    @State private var notifyLastFocusedField: NotifyField = .message
    @State private var notifyHeaderSelection: TextSelection?
    @State private var notifyMessageSelection: TextSelection?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(step.kind.title, systemImage: step.kind.icon)
                    .font(.title3).bold()
                    .foregroundStyle(step.kind.color)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            Form {
                Text(step.kind.subtitle)
                    .font(.caption).foregroundStyle(.secondary)

                switch step.kind {
                case .controlDeck:
                    controlDeckFields

                case .wait:
                    waitFields

                case .sync:
                    Text("No configuration needed — downloads any files not already synced.")
                        .font(.callout).foregroundStyle(.secondary)

                case .convert:
                    convertFields

                case .rename:
                    renameFields

                case .format:
                    Label("This step erases the device's drive. All footage still on it will be permanently deleted — this cannot be undone.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)

                case .cleanup:
                    cleanupFields

                case .notify:
                    notifyFields
                }

                Section {
                    Toggle("Ask for confirmation before this step", isOn: $requiresConfirmation)
                } footer: {
                    Text("Pauses the workflow here until someone confirms it should continue.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.top, 4)
        }
        .frame(width: 420)
        .onAppear(perform: load)
        .sheet(isPresented: $showingAddRecipient) {
            AddRecipientSheet(isPresented: $showingAddRecipient) { name, email in
                notifyRecipients.append(NotificationRecipient(name: name, email: email))
            }
        }
    }

    // MARK: - Field groups

    private var controlDeckFields: some View {
        Group {
            Picker("Action", selection: $controlCommand) {
                ForEach(DeckCommand.allCases) { command in
                    Text(command.title).tag(command)
                }
            }
            .pickerStyle(.segmented)

            if controlCommand == .start {
                Toggle("Stop recording automatically", isOn: $stopRecordingAutomatically)
                if stopRecordingAutomatically {
                    Stepper(
                        "\(stopAfterMinutes) minute\(stopAfterMinutes == 1 ? "" : "s")",
                        value: $stopAfterMinutes, in: 1...240
                    )
                } else {
                    Text("Recording keeps rolling while the workflow moves on to its next step.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Stops recording on the device if it's currently rolling.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var waitFields: some View {
        Group {
            LabeledContent("Wait For") {
                HStack(spacing: 10) {
                    Stepper(value: $waitValue, in: 1...(waitUnit == .hours ? 72 : 1440)) {
                        Text("\(waitValue)").monospacedDigit().frame(width: 30, alignment: .trailing)
                    }
                    Picker("", selection: $waitUnit) {
                        ForEach(WaitUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
            }
            Text("Pauses the workflow for \(WaitDurationFormatter.string(forMinutes: waitValue * (waitUnit == .hours ? 60 : 1))) before moving to the next step.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var convertFields: some View {
        Group {
            LabeledContent("Quality Preset") {
                Picker("", selection: $preset) {
                    ForEach(ConversionSettings.FFmpegPreset.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }.labelsHidden().frame(width: 200)
            }
            Toggle("Delete original after converting", isOn: $deleteOriginal)
            LabeledContent("Max Parallel Jobs") {
                Stepper("\(maxParallelJobs)", value: $maxParallelJobs, in: 1...8)
            }
            Text("How many files this step converts at the same time.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var renameFields: some View {
        Group {
            LabeledContent("Pattern") {
                TextField("{device}_{date}_{index}", text: $pattern)
                    .textFieldStyle(.roundedBorder)
            }
            renamePreview
            VStack(alignment: .leading, spacing: 4) {
                Text("Available tokens").font(.caption).bold()
                ForEach(RenameToken.allCases, id: \.self) { token in
                    HStack {
                        Text(token.rawValue).font(.system(.caption, design: .monospaced))
                        Text(token.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Shows how the current pattern would rename a couple of example files,
    /// so the person can see the result before running the workflow.
    private var renamePreview: some View {
        let examples = [
            ("Clip0001.mov", 1),
            ("Clip0002.mov", 2)
        ]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Preview").font(.caption).bold()
            ForEach(examples, id: \.0) { original, index in
                let newName = RenamePatternEngine.apply(
                    pattern: pattern.isEmpty ? "{name}" : pattern,
                    originalName: (original as NSString).deletingPathExtension,
                    deviceName: "Stage Camera",
                    index: index
                )
                HStack(spacing: 6) {
                    Text(original)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("\(newName).\((original as NSString).pathExtension)")
                        .font(.system(.caption, design: .monospaced))
                        .bold()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var cleanupFields: some View {
        Group {
            LabeledContent("Retention") {
                Stepper("\(retentionDays) day\(retentionDays == 1 ? "" : "s")", value: $retentionDays, in: 1...365)
            }
            Text("Deletes files older than this from the workflow's destination folder — not from the device itself.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var notifyFields: some View {
        Group {
            if GmailAuthService.shared.connectedEmail == nil {
                Label("No Gmail account connected — this step won't be able to send email. Connect one in Settings.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }

            Section("Delivery Options") {
                Picker("Send Options", selection: $notifySendPerDrive) {
                    Text("Individual email per drive completed").tag(true)
                    Text("Single email for entire workflow").tag(false)
                }
                .pickerStyle(.radioGroup)
            }

            Section {
                LabeledContent("Header") {
                    TextField("e.g. Sync Complete", text: $notifyHeader, selection: $notifyHeaderSelection)
                        .textFieldStyle(.roundedBorder)
                        .focused($notifyFocusedField, equals: .header)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Message").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $notifyMessage, selection: $notifyMessageSelection)
                        .frame(minHeight: 80, maxHeight: 160)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .focused($notifyFocusedField, equals: .message)
                    Text("HTML tags (e.g. <b>, <a href>) are sent as formatted email; plain text is sent as-is.")
                        .font(.caption2).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Click to insert into \(notifyLastFocusedField == .header ? "header" : "message")")
                            .font(.caption).bold()
                            .padding(.top, 4)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(Self.notifyVariables, id: \.token) { variable in
                                Button {
                                    insertNotifyVariable(variable.token)
                                } label: {
                                    Text(variable.token)
                                        .font(.system(.caption, design: .monospaced))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.3)))
                                }
                                .buttonStyle(.plain)
                                .help(variable.description)
                            }
                        }
                    }
                }
            }
            .onChange(of: notifyFocusedField) { _, newValue in
                if let newValue { notifyLastFocusedField = newValue }
            }

            Section {
                HStack {
                    Text("Recipients").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingAddRecipient = true
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if notifyRecipients.isEmpty {
                    Text("No recipients added yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(notifyRecipients) { recipient in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recipient.name).font(.body)
                                Text(recipient.email).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                notifyRecipients.removeAll { $0.id == recipient.id }
                            } label: {
                                Image(systemName: "trash").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Notify Variables

    private struct NotifyVariable {
        let token: String
        let description: String
    }

    private static let notifyVariables: [NotifyVariable] = [
        .init(token: "{workflow_name}", description: "The name of the current workflow"),
        .init(token: "{time_taken}", description: "Time elapsed since start (e.g. 1m 30s)"),
        .init(token: "{file_names}", description: "Files processed (list in body, comma-separated in header)"),
        .init(token: "{recipient_name}", description: "The recipient's name"),
    ]

    private func insertNotifyVariable(_ token: String) {
        switch notifyLastFocusedField {
        case .header:
            insert(token, into: &notifyHeader, selection: &notifyHeaderSelection)
        case .message:
            insert(token, into: &notifyMessage, selection: &notifyMessageSelection)
        }
        notifyFocusedField = notifyLastFocusedField
    }

    private func insert(_ token: String, into text: inout String, selection: inout TextSelection?) {
        guard let current = selection, case .selection(let range) = current.indices else {
            text += token
            selection = TextSelection(insertionPoint: text.endIndex)
            return
        }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        text.replaceSubrange(range, with: token)
        let newIndex = text.index(text.startIndex, offsetBy: offset + token.count)
        selection = TextSelection(insertionPoint: newIndex)
    }

    // MARK: - Load / Save

    private func load() {
        requiresConfirmation = step.requiresConfirmation
        switch step.action {
        case .controlDeck(let command, let savedMinutes):
            controlCommand = command
            if let minutes = savedMinutes {
                stopRecordingAutomatically = true
                stopAfterMinutes = minutes
            }
        case .wait(let minutes):
            if minutes >= 60 && minutes % 60 == 0 {
                waitUnit = .hours
                waitValue = minutes / 60
            } else {
                waitUnit = .minutes
                waitValue = max(minutes, 1)
            }
        case .sync, .format:
            break
        case .convert(let p, let del, let jobs):
            preset = p; deleteOriginal = del; maxParallelJobs = jobs
        case .rename(let pat):
            pattern = pat
        case .cleanup(let days):
            retentionDays = days
        case .notify(let header, let message, let recipients, let sendPerDrive):
            notifyHeader = header
            notifyMessage = message
            notifyRecipients = recipients
            notifySendPerDrive = sendPerDrive
        }
    }

    private func save() {
        step.requiresConfirmation = requiresConfirmation
        switch step.kind {
        case .controlDeck:
            step.action = .controlDeck(
                command: controlCommand,
                stopAfterMinutes: (controlCommand == .start && stopRecordingAutomatically) ? stopAfterMinutes : nil
            )
        case .wait:
            step.action = .wait(minutes: waitUnit == .hours ? waitValue * 60 : waitValue)
        case .sync:    step.action = .sync
        case .convert: step.action = .convert(preset: preset, deleteOriginal: deleteOriginal, maxParallelJobs: maxParallelJobs)
        case .rename:  step.action = .rename(pattern: pattern.isEmpty ? "{name}" : pattern)
        case .format:  step.action = .format
        case .cleanup: step.action = .cleanup(retentionDays: retentionDays)
        case .notify:
            step.action = .notify(
                header: notifyHeader.isEmpty ? "Workflow update" : notifyHeader,
                message: notifyMessage,
                recipients: notifyRecipients,
                sendPerDrive: notifySendPerDrive
            )
        }
        dismiss()
    }
}

// MARK: - Add Recipient Sheet

struct AddRecipientSheet: View {
    @Binding var isPresented: Bool
    var onAdd: (String, String) -> Void

    @State private var name: String = ""
    @State private var email: String = ""

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        email.contains("@") &&
        email.contains(".")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Recipient")
                .font(.title3)
                .bold()

            Form {
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .autocorrectionDisabled()

                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Button("Add") {
                    onAdd(name.trimmingCharacters(in: .whitespaces), email.trimmingCharacters(in: .whitespaces))
                    isPresented = false
                }
                .keyboardShortcut(.return)
                .disabled(!isValid)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
