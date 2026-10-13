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
    @State private var syncVerify = false
    @State private var syncDeleteFromDevice = false
    @State private var syncCloudStorePath = ""
    @State private var showFolderPicker = false
    @State private var createFolderCloudStoreID: UUID? = nil   // nil = global destination
    @State private var createFolderParentPath = ""
    @State private var createFolderNameTemplate = ""
    @State private var createFolderGroupByDevice = false
    @State private var showCreateFolderPathPicker = false
    @State private var preset: ConversionSettings.FFmpegPreset = .fast
    @State private var deleteOriginal = true
    @State private var maxParallelJobs = 2
    @State private var convertInPlace = false
    @State private var pattern = ""
    @State private var retentionDays = 30
    @State private var transcribeLocale = Locale.current.identifier
    @State private var transcribeWriteSRT = true
    @State private var transcribeSkipExisting = true
    @State private var transcribeDeleteWhenDone = false
    @State private var findClipsMax = 5
    @State private var findClipsMinSeconds = 20
    @State private var findClipsMaxSeconds = 60
    @State private var findClipsExport = false
    @State private var queueClipsMinScore = 0
    @State private var copyPlatform = CopyPlatform.general
    @State private var copyHashtagCount = 5
    @State private var webhookURL = ""
    @State private var webhookFormat = WebhookFormat.json
    @State private var webhookTestState: WebhookTestState = .idle
    @State private var copyToChoice = CopyTargetChoice.global
    @State private var copyToPath = ""
    @State private var copyToVerify = true
    @State private var copyToSidecars = true
    @State private var showCopyToFolderPicker = false

    private enum WebhookTestState: Equatable { case idle, sending, sent, failed(String) }
    private enum CopyTargetChoice: Hashable { case global, cloudStore(UUID), localFolder(UUID) }
    @State private var findClipsFormat = SocialFormat.vertical
    @State private var findClipsCaptions = true
    @State private var reframeFormat = SocialFormat.vertical
    @State private var reframeFollowSubject = true
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
    @State private var decks = DeckSelection.all
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

                if step.kind.usesHyperDeck {
                    deckFields
                }

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

                case .transcribe:
                    transcribeFields

                case .findClips:
                    findClipsFields

                case .queueClips:
                    queueClipsFields

                case .upload:
                    Label("Uploading is coming soon. Until it's ready this step does nothing when the workflow runs, so you can plan around it now — YouTube, Dropbox and Google Drive are first.", systemImage: "clock.badge")
                        .font(.callout).foregroundStyle(.secondary)

                case .writeCopy:
                    writeCopyFields

                case .webhook:
                    webhookFields

                case .copyTo:
                    copyToFields

                case .reframe:
                    reframeFields

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
        .sheet(isPresented: $showCopyToFolderPicker) {
            if case .cloudStore(let id) = copyToChoice, let store = appState.cloudStores.first(where: { $0.id == id }) {
                FolderPickerSheet(store: store) { path in
                    copyToPath = path
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
        if case .createFolder(_, _, let nameTemplate, _) = folderStep.action {
            return FolderNameEngine.resolve(nameTemplate)
        }
        return "Folder"
    }

    // MARK: - Field groups

    /// Which HyperDecks this step acts on. Ticking a single deck while "All
    /// HyperDecks" is on switches to an explicit list of the rest.
    private var deckFields: some View {
        Section("HyperDecks") {
            Toggle("All HyperDecks", isOn: Binding(
                get: { decks == .all },
                set: { decks = $0 ? .all : .only([]) }
            ))
            ForEach(appState.hyperDecks) { deck in
                Toggle(isOn: Binding(
                    get: { decks.includes(deck.id) },
                    set: { isOn in
                        var ids: [UUID]
                        switch decks {
                        case .all:           ids = appState.hyperDecks.map(\.id)
                        case .only(let set): ids = set
                        }
                        ids.removeAll { $0 == deck.id }
                        if isOn { ids.append(deck.id) }
                        decks = .only(ids)
                    }
                )) {
                    Label(deck.name, systemImage: "record.circle")
                }
            }
            if appState.hyperDecks.isEmpty {
                Text("No HyperDecks added yet.").font(.caption).foregroundStyle(.secondary)
            }
            if step.kind == .sync {
                Text("On a folder there's nothing to download — Offload just picks up the files already in it. Turn every deck off for a workflow that only works on folders.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if decks.isNone {
                Text("With no HyperDeck chosen this step does nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var syncFields: some View {
        Group {
            Text("Downloads any files not already synced.")
                .font(.callout).foregroundStyle(.secondary)

            Toggle("Verify with SHA-256", isOn: Binding(
                get: { syncVerify || syncDeleteFromDevice },
                set: { syncVerify = $0 }
            ))
            .disabled(syncDeleteFromDevice)
            Text("Re-reads each file from the device and compares it with the copy on the destination, then writes a checksums.sha256 manifest next to the footage. Adds time to every offload.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Remove from device after offload", isOn: $syncDeleteFromDevice)
            Text("Deletes each file from the HyperDeck once its copy has been verified — an alternative to a Format Drive step. Always verifies first, and a file that fails verification is left on the device. A clip that's still recording is never touched. Doesn't apply to folders.")
                .font(.caption).foregroundStyle(.secondary)

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

                Toggle("Create a subfolder for each device", isOn: $createFolderGroupByDevice)
                Text(createFolderGroupByDevice
                     ? "Each device in this workflow gets its own subfolder, named after the device (e.g. \"ISO 1\"), inside the created folder."
                     : "All devices in this workflow share the created folder directly.")
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
                    index: index,
                    projectName: appState.shoot.name.isEmpty ? "MyShoot" : appState.shoot.name,
                    cameraLabel: appState.shoot.cameraLabels.values.first ?? "A"
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

    private var transcribeFields: some View {
        Group {
            Picker("Language", selection: $transcribeLocale) {
                ForEach(transcribeLocaleChoices, id: \.self) { id in
                    Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                }
            }
            Toggle("Also write an .srt subtitle file", isOn: $transcribeWriteSRT)
            Toggle("Skip clips that already have a transcript", isOn: $transcribeSkipExisting)
            Toggle("Delete the new transcript files when the workflow is over", isOn: $transcribeDeleteWhenDone)
            Text("Runs entirely on this Mac. A .transcript.json file is saved next to each clip for later steps to use. The first run in a language downloads its speech model.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var writeCopyFields: some View {
        Group {
            Picker("Style", selection: $copyPlatform) {
                ForEach(CopyPlatform.allCases) { platform in
                    Text(platform.title).tag(platform)
                }
            }
            Stepper("Up to \(copyHashtagCount) hashtag\(copyHashtagCount == 1 ? "" : "s")", value: $copyHashtagCount, in: 0...10)
            Text("Drafts a headline, caption and hashtags for each suggested clip from what's said in it, on this Mac. Put this after Find Clips. The copy is saved with the clip suggestions and shown in the player's clip panel; rendered posts also get a matching .txt file.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var webhookFields: some View {
        Group {
            TextField("https://hooks.example.com/…", text: $webhookURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Picker("Format", selection: $webhookFormat) {
                ForEach(WebhookFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            HStack {
                Button("Send Test") { sendWebhookTest() }
                    .disabled(webhookURL.trimmingCharacters(in: .whitespaces).isEmpty || webhookTestState == .sending)
                switch webhookTestState {
                case .idle:           EmptyView()
                case .sending:        ProgressView().controlSize(.small)
                case .sent:           Label("Delivered", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                case .failed(let why): Text(why).font(.caption).foregroundStyle(Color.canopyRust).lineLimit(2)
                }
            }
            Text("Sends one request per device when this step runs, with the workflow name, the files it handled, and any clip suggestions and copy. A failed request is logged but doesn't stop the workflow. Treat the URL as a secret — it's stored with the workflow.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var copyToFields: some View {
        Group {
            Section("Copy Destination") {
                LabeledContent("Copy to") {
                    Picker("", selection: $copyToChoice) {
                        Text("Global Default").tag(CopyTargetChoice.global)
                        if !appState.cloudStores.isEmpty {
                            Divider()
                            ForEach(appState.cloudStores) { store in
                                Text(store.name).tag(CopyTargetChoice.cloudStore(store.id))
                            }
                        }
                        if !appState.localFolders.isEmpty {
                            Divider()
                            ForEach(appState.localFolders) { folder in
                                Text(folder.name).tag(CopyTargetChoice.localFolder(folder.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: copyToChoice) { copyToPath = "" }
                }

                if case .localFolder(let id) = copyToChoice, let folder = appState.localFolders.first(where: { $0.id == id }) {
                    LabeledContent("Subfolder") {
                        TextField("Optional", text: $copyToPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                    Label("→ \(folder.path)\(copyToPath.isEmpty ? "" : "/" + copyToPath)", systemImage: "externaldrive")
                        .font(.caption).foregroundStyle(.secondary)
                } else if case .cloudStore(let id) = copyToChoice, let store = appState.cloudStores.first(where: { $0.id == id }) {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(copyToPath.isEmpty ? "Volume root" : copyToPath)
                                .foregroundStyle(copyToPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.callout)
                            Button { showCopyToFolderPicker = true } label: {
                                Label("Browse…", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Label("→ \(store.name)/\(copyToPath)", systemImage: "externaldrive.connected.to.line.below")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Uses the global sync destination from Settings, in a folder named after the device.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Verify with SHA-256", isOn: $copyToVerify)
            Toggle("Include transcripts and clip suggestions", isOn: $copyToSidecars)
            Text("Copies the files this workflow handled to a second location. Files already there with the same contents are skipped, so it's safe to re-run. Each copy is written under a temporary name and only moved into place once it's complete.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sendWebhookTest() {
        webhookTestState = .sending
        let url = webhookURL
        let format = webhookFormat
        Task {
            let sample = WebhookReport(
                workflow: "Canopy test", device: "Test device", errors: 0,
                files: [WebhookReport.File(
                    name: "A001.mov", sizeBytes: 1_234_567,
                    clips: [WebhookReport.Clip(title: "Sample clip", start: 12, end: 42, score: 88,
                                               caption: "A sample caption", hashtags: ["canopy"])]
                )]
            )
            do {
                try await WebhookService.send(sample, to: url, format: format)
                webhookTestState = .sent
            } catch {
                webhookTestState = .failed(error.localizedDescription)
            }
        }
    }

    private var queueClipsFields: some View {
        Group {
            Stepper(
                queueClipsMinScore == 0 ? "Queue every suggested clip" : "Only clips scoring \(queueClipsMinScore)+",
                value: $queueClipsMinScore, in: 0...100, step: 5
            )
            Text("Adds each video's clips from a Find Clips step to the Export Queue as trimmed items. Put this after Find Clips. Nothing exports until you choose a destination in the Export Queue and start it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var findClipsFields: some View {
        Group {
            Stepper("Up to \(findClipsMax) clip\(findClipsMax == 1 ? "" : "s") per video", value: $findClipsMax, in: 1...10)
            Stepper("At least \(findClipsMinSeconds) seconds", value: $findClipsMinSeconds, in: 10...120, step: 5)
            Stepper("At most \(findClipsMaxSeconds) seconds", value: $findClipsMaxSeconds, in: 15...180, step: 5)
            Toggle("Also render finished posts", isOn: $findClipsExport)
            if findClipsExport {
                Picker("Format", selection: $findClipsFormat) {
                    ForEach(SocialFormat.allCases) { format in
                        Text("\(format.title) — \(format.detail)").tag(format)
                    }
                }
                Toggle("Burn in captions", isOn: $findClipsCaptions)
                Text("Saves each clip, cropped to follow the speaker and captioned, in a Social Posts folder next to the video. Rendering takes a few seconds per clip.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Reads each video's transcript (making one first if needed) and suggests moments that work as standalone short posts. Suggestions are saved next to the video; open it in the player to review and export them. Runs on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var reframeFields: some View {
        Group {
            Picker("Format", selection: $reframeFormat) {
                ForEach(SocialFormat.allCases) { format in
                    Text("\(format.title) — \(format.detail)").tag(format)
                }
            }
            Toggle("Keep the main subject in frame", isOn: $reframeFollowSubject)
            Text("Saves a cropped MP4 for each clip in a Reframed folder; the originals are untouched. The crop follows people in the shot, or whatever else stands out, and holds steady when they do. Turn this off for a plain centered crop.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Common languages plus whatever is currently selected, so a saved
    /// choice never disappears from the picker.
    private var transcribeLocaleChoices: [String] {
        var ids = ["en-US", "en-GB", "es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR", "ja-JP", "ko-KR", "zh-CN"]
        if !ids.contains(transcribeLocale) { ids.insert(transcribeLocale, at: 0) }
        return ids
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
        decks = step.decks
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
        case .createFolder(let cloudStoreID, let parentPath, let nameTemplate, let groupByDevice):
            createFolderCloudStoreID = cloudStoreID
            createFolderParentPath = parentPath
            createFolderNameTemplate = nameTemplate
            createFolderGroupByDevice = groupByDevice
        case .sync(let destination, let verify, let deleteFromDevice):
            syncVerify = verify || deleteFromDevice
            syncDeleteFromDevice = deleteFromDevice
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
        case .transcribe(let locale, let writeSRT, let skipExisting, let deleteWhenDone):
            transcribeLocale = locale; transcribeWriteSRT = writeSRT; transcribeSkipExisting = skipExisting
            transcribeDeleteWhenDone = deleteWhenDone
        case .findClips(let maxClips, let minSeconds, let maxSeconds, let exportFormat, let captions):
            findClipsMax = maxClips; findClipsMinSeconds = minSeconds; findClipsMaxSeconds = maxSeconds
            findClipsExport = exportFormat != nil
            if let exportFormat { findClipsFormat = exportFormat }
            findClipsCaptions = captions
        case .queueClips(let minScore):
            queueClipsMinScore = minScore
        case .upload:
            break
        case .writeCopy(let platform, let hashtagCount):
            copyPlatform = platform; copyHashtagCount = hashtagCount
        case .webhook(let url, let format):
            webhookURL = url; webhookFormat = format
        case .copyTo(let destination, let verify, let includeSidecars):
            copyToVerify = verify; copyToSidecars = includeSidecars
            switch destination {
            case .global:
                copyToChoice = .global
            case .cloudStore(let id, let path):
                copyToChoice = .cloudStore(id); copyToPath = path
            case .localFolder(let id, let path):
                copyToChoice = .localFolder(id); copyToPath = path
            }
        case .reframe(let format, let followSubject):
            reframeFormat = format; reframeFollowSubject = followSubject
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
        step.decks = decks
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
                nameTemplate: createFolderNameTemplate.isEmpty ? "New Folder_\(FolderNameEngine.dateToken)" : createFolderNameTemplate,
                groupByDevice: createFolderGroupByDevice
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
            step.action = .sync(destination: destination, verify: syncVerify || syncDeleteFromDevice, deleteFromDevice: syncDeleteFromDevice)
        case .convert: step.action = .convert(preset: preset, deleteOriginal: deleteOriginal, maxParallelJobs: maxParallelJobs, convertInPlace: convertInPlace)
        case .rename:  step.action = .rename(pattern: pattern.isEmpty ? "{name}" : pattern)
        case .transcribe: step.action = .transcribe(locale: transcribeLocale, writeSRT: transcribeWriteSRT, skipExisting: transcribeSkipExisting, deleteWhenDone: transcribeDeleteWhenDone)
        case .findClips: step.action = .findClips(maxClips: findClipsMax, minSeconds: findClipsMinSeconds, maxSeconds: max(findClipsMaxSeconds, findClipsMinSeconds),
                                                   exportFormat: findClipsExport ? findClipsFormat : nil, captions: findClipsCaptions)
        case .queueClips: step.action = .queueClips(minScore: queueClipsMinScore)
        case .upload: step.action = .upload
        case .writeCopy: step.action = .writeCopy(platform: copyPlatform, hashtagCount: copyHashtagCount)
        case .webhook: step.action = .webhook(url: webhookURL.trimmingCharacters(in: .whitespacesAndNewlines), format: webhookFormat)
        case .copyTo:
            let destination: CopyDestination
            switch copyToChoice {
            case .global:                destination = .global
            case .cloudStore(let id):    destination = .cloudStore(id: id, path: copyToPath)
            case .localFolder(let id):   destination = .localFolder(id: id, path: copyToPath.trimmingCharacters(in: .whitespaces))
            }
            step.action = .copyTo(destination: destination, verify: copyToVerify, includeSidecars: copyToSidecars)
        case .reframe: step.action = .reframe(format: reframeFormat, followSubject: reframeFollowSubject)
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
