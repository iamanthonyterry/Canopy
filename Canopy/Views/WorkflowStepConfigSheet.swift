import SwiftUI

/// Small focused sheet for configuring a single workflow step.
/// Only shows fields relevant to that step's kind.
struct WorkflowStepConfigSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Binding var step: WorkflowStep
    /// Other Create Folder steps in this workflow, so the Sync step can
    /// offer "use the folder that step creates" as a destination option.
    var availableFolderSteps: [WorkflowStep] = []
    /// The workflow this step belongs to, if it's being edited (nil for a
    /// brand-new workflow) — excluded from the Trigger Workflow picker so a
    /// workflow can't be pointed directly at itself.
    var excludingWorkflowID: UUID? = nil

    // Local editable copies so Cancel doesn't mutate the caller's step.
    @State private var syncUsesCreatedFolder = false
    @State private var syncCreatedFolderStepID: UUID? = nil
    @State private var syncCloudStoreID: UUID? = nil   // nil = global destination
    @State private var syncCloudStorePath = ""
    @State private var showFolderPicker = false
    @State private var createFolderCloudStoreID: UUID? = nil   // nil = global destination
    @State private var createFolderParentPath = ""
    @State private var createFolderNameTemplate = ""
    @State private var showCreateFolderPathPicker = false
    @State private var preset: ConversionSettings.FFmpegPreset = .fast
    @State private var deleteOriginal = true
    @State private var maxParallelJobs = 2
    @State private var convertInPlace = false
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
    @State private var triggerWorkflowID: UUID? = nil
    @State private var triggerWaitForCompletion = false

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
                    .font(.canopyTitle2)
                    .foregroundStyle(step.kind.color)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.canopyPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Rectangle().fill(Color.canopyRule).frame(height: 1)

            Form {
                Text(step.kind.subtitle)
                    .font(.caption).foregroundStyle(.secondary)

                switch step.kind {
                case .controlDeck:
                    controlDeckFields

                case .wait:
                    waitFields

                case .createFolder:
                    createFolderFields

                case .sync:
                    syncFields

                case .convert:
                    convertFields

                case .rename:
                    renameFields

                case .format:
                    Label("This step erases the device's drive. All footage still on it will be permanently deleted — this cannot be undone.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Color.canopyRust)

                case .cleanup:
                    cleanupFields

                case .notify:
                    notifyFields

                case .triggerWorkflow:
                    triggerWorkflowFields
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
        .background(Color.canopyPaper)
        .onAppear(perform: load)
        .sheet(isPresented: $showingAddRecipient) {
            AddRecipientSheet(isPresented: $showingAddRecipient) { name, email in
                notifyRecipients.append(NotificationRecipient(name: name, email: email))
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            if let store = selectedSyncStore {
                FolderPickerSheet(store: store) { path in
                    syncCloudStorePath = path
                }
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showCreateFolderPathPicker) {
            if let store = selectedCreateFolderStore {
                FolderPickerSheet(store: store) { path in
                    createFolderParentPath = path
                }
                .environmentObject(appState)
            }
        }
    }

    private var selectedSyncStore: CloudStore? {
        guard let id = syncCloudStoreID else { return nil }
        return appState.cloudStores.first { $0.id == id }
    }

    private var selectedCreateFolderStore: CloudStore? {
        guard let id = createFolderCloudStoreID else { return nil }
        return appState.cloudStores.first { $0.id == id }
    }

    /// The folder name a Create Folder step will resolve to, for display in
    /// the Sync step's "use created folder" picker.
    private func folderStepLabel(_ folderStep: WorkflowStep) -> String {
        if case .createFolder(_, _, let nameTemplate) = folderStep.action {
            return FolderNameEngine.resolve(nameTemplate)
        }
        return "Folder"
    }

    // MARK: - Field groups

    private var syncFields: some View {
        Group {
            Text("Downloads any files not already synced.")
                .font(.callout).foregroundStyle(.secondary)

            if !availableFolderSteps.isEmpty {
                Picker("Destination", selection: $syncUsesCreatedFolder) {
                    Text("Cloud Store").tag(false)
                    Text("Created Folder").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: syncUsesCreatedFolder) {
                    if syncUsesCreatedFolder && syncCreatedFolderStepID == nil {
                        syncCreatedFolderStepID = availableFolderSteps.first?.id
                    }
                }
            }

            if syncUsesCreatedFolder && !availableFolderSteps.isEmpty {
                Section("Sync Destination") {
                    Picker("Folder", selection: $syncCreatedFolderStepID) {
                        ForEach(availableFolderSteps) { folderStep in
                            Text(folderStepLabel(folderStep)).tag(Optional(folderStep.id))
                        }
                    }
                    .labelsHidden()
                    Text("Uses the folder created earlier in this workflow.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Sync Destination") {
                    LabeledContent("Cloud Store") {
                        Picker("", selection: $syncCloudStoreID) {
                            Text("Global Default").tag(Optional<UUID>.none)
                            if !appState.cloudStores.isEmpty {
                                Divider()
                                ForEach(appState.cloudStores) { store in
                                    Text(store.name).tag(Optional(store.id))
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        .onChange(of: syncCloudStoreID) {
                            // Clear the path when the store changes
                            syncCloudStorePath = ""
                        }
                    }

                    // Folder row — only shown when a specific store is chosen
                    if let store = selectedSyncStore {
                        LabeledContent("Folder") {
                            HStack(spacing: 8) {
                                Group {
                                    if syncCloudStorePath.isEmpty {
                                        Text("Volume root")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(syncCloudStorePath)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.callout)

                                if !syncCloudStorePath.isEmpty {
                                    Button {
                                        syncCloudStorePath = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Button {
                                    showFolderPicker = true
                                } label: {
                                    Label("Browse…", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        let folder = syncCloudStorePath.isEmpty ? "/" : "/\(syncCloudStorePath)"
                        Label("→ \(store.name)\(folder)",
                              systemImage: "externaldrive.connected.to.line.below")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Uses the global sync destination from Settings.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var createFolderFields: some View {
        Group {
            Section("Folder Name") {
                LabeledContent("Name") {
                    HStack(spacing: 8) {
                        TextField("e.g. Shoot_{date}", text: $createFolderNameTemplate)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            createFolderNameTemplate += FolderNameEngine.dateToken
                        } label: {
                            Label("Insert Date", systemImage: "calendar")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text("Preview: \(FolderNameEngine.resolve(createFolderNameTemplate))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Location") {
                LabeledContent("Cloud Store") {
                    Picker("", selection: $createFolderCloudStoreID) {
                        Text("Global Default").tag(Optional<UUID>.none)
                        if !appState.cloudStores.isEmpty {
                            Divider()
                            ForEach(appState.cloudStores) { store in
                                Text(store.name).tag(Optional(store.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: createFolderCloudStoreID) {
                        createFolderParentPath = ""
                    }
                }

                if let store = selectedCreateFolderStore {
                    LabeledContent("Parent Folder") {
                        HStack(spacing: 8) {
                            Group {
                                if createFolderParentPath.isEmpty {
                                    Text("Volume root")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(createFolderParentPath)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.callout)

                            if !createFolderParentPath.isEmpty {
                                Button {
                                    createFolderParentPath = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }

                            Button {
                                showCreateFolderPathPicker = true
                            } label: {
                                Label("Browse…", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    let folder = createFolderParentPath.isEmpty ? "/" : "/\(createFolderParentPath)/"
                    Label("→ \(store.name)\(folder)\(FolderNameEngine.resolve(createFolderNameTemplate))",
                          systemImage: "folder.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Creates the folder inside the global sync destination from Settings.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

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
            LabeledContent("Output Location") {
                Picker("", selection: $convertInPlace) {
                    Text("New \"Converted\" folder").tag(false)
                    Text("Convert in place").tag(true)
                }.labelsHidden().frame(width: 200)
            }
            Text(convertInPlace
                 ? "Converted files are saved alongside the originals in the same folder."
                 : "Converted files are saved into a \"Converted\" subfolder.")
                .font(.caption).foregroundStyle(.secondary)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .canopyCard(padding: 10, cornerRadius: 6)
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

    private var availableWorkflows: [Workflow] {
        appState.workflows
            .filter { $0.id != excludingWorkflowID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var triggerWorkflowFields: some View {
        Group {
            if availableWorkflows.isEmpty {
                Text("No other workflows to trigger yet — create another workflow first.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("Workflow") {
                    Picker("", selection: $triggerWorkflowID) {
                        Text("Select a workflow").tag(Optional<UUID>.none)
                        ForEach(availableWorkflows) { workflow in
                            Text(workflow.name).tag(Optional(workflow.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                Toggle("Wait for it to finish before continuing", isOn: $triggerWaitForCompletion)
                Text(triggerWaitForCompletion
                     ? "This workflow pauses here until the triggered one finishes."
                     : "This workflow starts the other one and immediately continues to its next step.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                                Image(systemName: "trash").foregroundStyle(Color.canopyRust)
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
        case .createFolder(let cloudStoreID, let parentPath, let nameTemplate):
            createFolderCloudStoreID = cloudStoreID
            createFolderParentPath = parentPath
            createFolderNameTemplate = nameTemplate
        case .sync(let destination):
            switch destination {
            case .global:
                syncUsesCreatedFolder = false
                syncCloudStoreID = nil
                syncCloudStorePath = ""
            case .cloudStore(let id, let path):
                syncUsesCreatedFolder = false
                syncCloudStoreID = id
                syncCloudStorePath = path
            case .createdFolder(let stepID):
                syncUsesCreatedFolder = true
                syncCreatedFolderStepID = stepID
            }
        case .format:
            break
        case .convert(let p, let del, let jobs, let inPlace):
            preset = p; deleteOriginal = del; maxParallelJobs = jobs; convertInPlace = inPlace
        case .rename(let pat):
            pattern = pat
        case .cleanup(let days):
            retentionDays = days
        case .notify(let header, let message, let recipients, let sendPerDrive):
            notifyHeader = header
            notifyMessage = message
            notifyRecipients = recipients
            notifySendPerDrive = sendPerDrive
        case .triggerWorkflow(let workflowID, let waitForCompletion):
            triggerWorkflowID = workflowID
            triggerWaitForCompletion = waitForCompletion
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
        case .createFolder:
            step.action = .createFolder(
                cloudStoreID: createFolderCloudStoreID,
                parentPath: createFolderParentPath,
                nameTemplate: createFolderNameTemplate.isEmpty ? "New Folder_\(FolderNameEngine.dateToken)" : createFolderNameTemplate
            )
        case .sync:
            let destination: SyncDestination
            if syncUsesCreatedFolder, !availableFolderSteps.isEmpty {
                destination = .createdFolder(stepID: syncCreatedFolderStepID ?? availableFolderSteps[0].id)
            } else if let storeID = syncCloudStoreID {
                destination = .cloudStore(id: storeID, path: syncCloudStorePath)
            } else {
                destination = .global
            }
            step.action = .sync(destination: destination)
        case .convert: step.action = .convert(preset: preset, deleteOriginal: deleteOriginal, maxParallelJobs: maxParallelJobs, convertInPlace: convertInPlace)
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
        case .triggerWorkflow:
            step.action = .triggerWorkflow(workflowID: triggerWorkflowID, waitForCompletion: triggerWaitForCompletion)
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
                .font(.canopyTitle2)
                .foregroundStyle(Color.canopyInk)

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
                .buttonStyle(.canopyPrimary)
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Color.canopyPaper)
    }
}
