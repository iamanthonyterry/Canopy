import SwiftUI

/// Full-screen drag-and-drop builder for creating or editing a Workflow.
///
/// Left: a palette of every step and trigger that can be added (drag it onto
/// the workspace, or click it to append). Right: the workspace — what starts
/// the workflow, which devices it runs on, and the ordered steps, which can be
/// reordered by dragging.
struct WorkflowBuilderView: View {
    @EnvironmentObject var appState: AppState
    let existingWorkflow: Workflow?
    /// Called when the builder should go away (saved, or discarded).
    let onClose: () -> Void

    @State private var name: String
    @State private var steps: [WorkflowStep]
    @State private var targets: Set<WorkflowTarget>
    @State private var triggers: [ScheduleSettings]

    @State private var editingStep: WorkflowStep? = nil
    @State private var editingTrigger: ScheduleSettings? = nil
    @State private var pickingCloudStoreFolder: CloudStore? = nil
    @State private var confirmingDiscard = false
    @State private var paletteQuery = ""
    @State private var triggerZoneTargeted = false

    // Natural-language editing
    @State private var assistantRequest = ""
    @State private var isAssisting = false
    @State private var assistantNotes: [String] = []
    @State private var assistantError: String? = nil
    /// What the workflow looked like before the last assistant change, so it can be undone.
    @State private var assistantUndo: (name: String, steps: [WorkflowStep], targets: Set<WorkflowTarget>, triggers: [ScheduleSettings])? = nil
    @FocusState private var assistantFocused: Bool
    private var assistantUnavailableReason: String? { WorkflowAssistant.unavailableReason }

    /// Snapshot of the values the builder opened with, to know whether
    /// leaving would throw anything away.
    private let initialName: String
    private let initialSteps: [WorkflowStep]
    private let initialTargets: Set<WorkflowTarget>
    private let initialTriggers: [ScheduleSettings]

    /// `prefill` seeds a brand-new workflow's fields (e.g. from the
    /// natural-language builder) without making this an edit of an existing one.
    init(workflow: Workflow?, prefill: Workflow? = nil, onClose: @escaping () -> Void) {
        existingWorkflow = workflow
        self.onClose = onClose
        let source = workflow ?? prefill
        _name     = State(initialValue: source?.name ?? "")
        _steps    = State(initialValue: source?.steps ?? [])
        _targets  = State(initialValue: Set(source?.targets ?? []))
        _triggers = State(initialValue: source?.triggers ?? [])
        // A prefilled draft hasn't been saved yet, so it counts as unsaved work.
        initialName     = workflow?.name ?? ""
        initialSteps    = workflow?.steps ?? []
        initialTargets  = Set(workflow?.targets ?? [])
        initialTriggers = workflow?.triggers ?? []
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !steps.isEmpty }

    private var isDirty: Bool {
        name != initialName || steps != initialSteps
            || targets != initialTargets || triggers != initialTriggers
    }

    // MARK: - Drag payloads

    private enum Payload {
        static let step = "canopy.step:"        // + StepKind.rawValue — new step from the palette
        static let move = "canopy.move:"        // + step UUID — reorder an existing step
        static let trigger = "canopy.trigger:"  // + ScheduleMode.rawValue — new trigger from the palette
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Color.canopyRule).frame(height: 1)
            GeometryReader { geo in
                // Shrink the block palette on narrow windows so the canvas
                // keeps room for steps.
                let paletteWidth = min(270, max(200, geo.size.width * 0.3))
                HStack(spacing: 0) {
                    palette
                        .frame(width: paletteWidth)
                    Rectangle().fill(Color.canopyRule).frame(width: 1)
                    workspace
                }
            }
        }
        .background(Color.canopyPaper)
        .sheet(item: $editingStep) { step in
            if let index = steps.firstIndex(where: { $0.id == step.id }) {
                WorkflowStepConfigSheet(
                    step: $steps[index],
                    availableFolderSteps: steps.filter { $0.kind == .createFolder && $0.id != step.id },
                    precedingFolderSteps: steps.prefix(upTo: index).filter { $0.kind == .createFolder },
                    excludingWorkflowID: existingWorkflow?.id
                )
                .environmentObject(appState)
            }
        }
        .sheet(item: $editingTrigger) { trigger in
            if let index = triggers.firstIndex(where: { $0.id == trigger.id }) {
                ScheduleTriggerConfigSheet(
                    trigger: $triggers[index],
                    sourceWorkflows: eligibleSourceWorkflows
                )
                .environmentObject(appState)
            }
        }
        .sheet(item: $pickingCloudStoreFolder) { store in
            FolderPickerSheet(store: store) { path in
                targets.insert(.cloudStore(id: store.id, path: path))
            }
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard) {
            Button("Discard Changes", role: .destructive) { onClose() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("This workflow has unsaved changes.")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                if isDirty { confirmingDiscard = true } else { onClose() }
            } label: {
                Label("All Workflows", systemImage: "chevron.left")
                    .lineLimit(1)
            }
            .keyboardShortcut(.cancelAction)
            .fixedSize()

            Rectangle().fill(Color.canopyRule).frame(width: 1, height: 22)

            TextField("Workflow Name", text: $name)
                .textFieldStyle(.plain)
                .font(.canopyTitle)
                .foregroundStyle(Color.canopyInk)

            Spacer()

            if isDirty {
                Text("Unsaved changes").font(.canopyCaption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Button(existingWorkflow == nil ? "Create Workflow" : "Save Workflow") { save() }
                .buttonStyle(.canopyPrimary)
                .fixedSize()
                .disabled(!canSave)
                .keyboardShortcut("s", modifiers: .command)
                .help(canSave ? "" : "Give the workflow a name and at least one step")
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    // MARK: - Palette (left)

    private var query: String { paletteQuery.trimmingCharacters(in: .whitespaces) }

    private func matches(_ title: String, _ subtitle: String) -> Bool {
        query.isEmpty
            || title.localizedCaseInsensitiveContains(query)
            || subtitle.localizedCaseInsensitiveContains(query)
    }

    private var paletteKinds: [StepKind] {
        StepKind.allCases.filter { matches($0.title, $0.subtitle) }
    }

    private var paletteModes: [ScheduleMode] {
        (ScheduleMode.scheduleModes + ScheduleMode.eventModes).filter { matches($0.title, "trigger") }
    }

    private var palette: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search blocks", text: $paletteQuery)
                    .textFieldStyle(.plain)
                if !paletteQuery.isEmpty {
                    Button { paletteQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !paletteKinds.isEmpty {
                        paletteHeader("Steps", hint: "Drag into the workflow, or click to add")
                        ForEach(paletteKinds) { kind in
                            stepTile(kind)
                        }
                    }
                    if !paletteModes.isEmpty {
                        paletteHeader("Triggers", hint: "What starts the workflow")
                            .padding(.top, 10)
                        ForEach(paletteModes) { mode in
                            triggerTile(mode)
                        }
                    }
                    if paletteKinds.isEmpty && paletteModes.isEmpty {
                        Text("Nothing matches \"\(query)\".")
                            .font(.canopyCaption).foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .background(Color.canopyPaper)
    }

    private func paletteHeader(_ title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.canopySans(11, weight: .semibold)).foregroundStyle(.secondary)
            Text(hint).font(.canopyCaption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func stepTile(_ kind: StepKind) -> some View {
        PaletteTile(
            icon: kind.icon,
            color: kind.color,
            title: kind.isComingSoon ? "\(kind.title) · Coming Soon" : kind.title,
            subtitle: kind.subtitle
        )
        .onTapGesture { insertStep(kind, at: steps.count) }
        .draggable(Payload.step + kind.rawValue)
    }

    private func triggerTile(_ mode: ScheduleMode) -> some View {
        PaletteTile(
            icon: mode.icon,
            color: Color.canopySage,
            title: mode.title,
            subtitle: ScheduleMode.eventModes.contains(mode) ? "When something happens" : "On a schedule",
            dimmed: false
        )
        .onTapGesture { addTrigger(mode) }
        .draggable(Payload.trigger + mode.rawValue)
    }

    // MARK: - Workspace (right)

    private var workspace: some View {
        ScrollView {
            VStack(spacing: 0) {
                startsSection
                connector
                runsOnSection
                connector
                stepsSection
            }
            .frame(maxWidth: 620)
            .padding(.vertical, 28)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .background(
            // A faint dot grid so the workspace reads as a canvas.
            DotGrid().opacity(0.5)
        )
        .safeAreaInset(edge: .bottom, spacing: 0) { assistantBar }
    }

    // MARK: Assistant bar

    private var assistantIsBuilding: Bool { steps.isEmpty && triggers.isEmpty }

    private var assistantBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if assistantError != nil || !assistantNotes.isEmpty || assistantUndo != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let assistantError {
                        Label(assistantError, systemImage: "exclamationmark.triangle.fill")
                            .font(.canopyCaption).foregroundStyle(Color.canopyRust)
                    }
                    ForEach(assistantNotes, id: \.self) { note in
                        Label(note, systemImage: "checkmark.circle")
                            .font(.canopyCaption).foregroundStyle(.secondary)
                    }
                }
                if assistantUndo != nil {
                    Button("Undo last change") { undoAssistantChange() }
                        .buttonStyle(.link).font(.canopyCaption)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.canopySage)
                TextField(
                    assistantIsBuilding
                        ? "Describe the workflow you want…"
                        : "Describe a change — \"add an email at the end\", \"remove the wait\", \"run every night at 2am\"",
                    text: $assistantRequest
                )
                .textFieldStyle(.plain)
                .focused($assistantFocused)
                .onSubmit { runAssistant() }
                .disabled(isAssisting || assistantUnavailableReason != nil)

                if isAssisting { ProgressView().controlSize(.small) }
                Button(assistantIsBuilding ? "Build" : "Apply") { runAssistant() }
                    .buttonStyle(.canopyPrimary)
                    .disabled(isAssisting || assistantUnavailableReason != nil
                              || assistantRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.canopyRule, lineWidth: 1))

            if let assistantUnavailableReason {
                Text(assistantUnavailableReason).font(.canopyCaption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.canopyPaper.opacity(0.96))
        .overlay(alignment: .top) { Rectangle().fill(Color.canopyRule).frame(height: 1) }
    }

    private func runAssistant() {
        let request = assistantRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isAssisting, assistantUnavailableReason == nil else { return }
        isAssisting = true
        assistantError = nil
        assistantNotes = []
        let snapshot = (name: name, steps: steps, targets: targets, triggers: triggers)
        let building = assistantIsBuilding
        let current = Workflow(name: name, steps: steps, targets: Array(targets), triggers: triggers)

        let context = TriggerContext(appState: appState, workflowID: existingWorkflow?.id)

        Task {
            defer { isAssisting = false }
            do {
                let result = building
                    ? try await WorkflowAssistant.draft(from: request, context: context)
                    : try await WorkflowAssistant.edit(current, request: request, context: context)
                withAnimation(.snappy) {
                    steps = result.workflow.steps
                    targets = Set(result.workflow.targets)
                    triggers = result.workflow.triggers
                    // A name the user already typed wins over a generated one.
                    if building {
                        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = result.workflow.name }
                    } else {
                        name = result.workflow.name
                    }
                }
                assistantUndo = snapshot
                assistantNotes = result.notes
                assistantRequest = ""
            } catch {
                assistantError = error.localizedDescription
            }
        }
    }

    private func undoAssistantChange() {
        guard let previous = assistantUndo else { return }
        withAnimation(.snappy) {
            name = previous.name
            steps = previous.steps
            targets = previous.targets
            triggers = previous.triggers
        }
        assistantUndo = nil
        assistantNotes = []
        assistantError = nil
    }

    private var connector: some View {
        Rectangle().fill(Color.canopyRule).frame(width: 2, height: 22)
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title.uppercased(), systemImage: systemImage)
            .font(.canopySans(11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
    }

    // MARK: Triggers

    /// Workflows that can start this one when they finish. Excludes this
    /// workflow itself, and any workflow that is itself started by this one,
    /// so two workflows can't be wired to trigger each other forever.
    private var eligibleSourceWorkflows: [Workflow] {
        appState.workflows
            .filter { candidate in
                guard candidate.id != existingWorkflow?.id else { return false }
                return !candidate.triggers.contains {
                    $0.mode == .workflowFinished && $0.sourceWorkflowID == existingWorkflow?.id
                }
            }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var startsSection: some View {
        VStack(spacing: 0) {
            sectionLabel("Starts when", systemImage: "bolt.fill")
            VStack(spacing: 8) {
                ForEach(Array(triggers.enumerated()), id: \.element.id) { index, trigger in
                    triggerNode(trigger, index: index)
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                    Text(triggers.isEmpty
                         ? "Runs when started manually — drop a trigger here to automate it"
                         : "Drop another trigger here")
                        .font(.canopyCaption)
                }
                .foregroundStyle(triggerZoneTargeted ? Color.canopySage : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, triggers.isEmpty ? 18 : 10)
                .background(DropOutline(isTargeted: triggerZoneTargeted))
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    handleTriggerDrop(items)
                } isTargeted: { triggerZoneTargeted = $0 }
            }
        }
    }

    private func triggerTitle(_ trigger: ScheduleSettings) -> String {
        switch trigger.mode {
        case .daily:
            return "Daily · \(trigger.displayTime)"
        case .oneTime:
            return "One Time · \(trigger.displayOneTimeDate)"
        case .recordingStopped:
            return "When \(deckName(trigger.deviceID)) stops recording"
        case .deviceOnline:
            return "When \(deckName(trigger.deviceID)) comes online"
        case .workflowFinished:
            let name = appState.workflows.first { $0.id == trigger.sourceWorkflowID }?.name
            return name.map { "When \"\($0)\" finishes" } ?? "When a workflow finishes"
        case .folderChanged:
            let name = appState.localFolders.first { $0.id == trigger.deviceID }?.name
            return name.map { "When new clips arrive in \($0)" } ?? "When new clips arrive in a folder"
        }
    }

    private func triggerDetail(_ trigger: ScheduleSettings) -> String {
        switch trigger.mode {
        case .daily:
            return trigger.displayWeekdays
        case .oneTime:
            return "Runs once, then turns off"
        case .recordingStopped, .deviceOnline:
            return "Runs on that deck · at most every \(trigger.cooldownMinutes) min"
        case .workflowFinished:
            return "\(trigger.finishCondition.title) · at most every \(trigger.cooldownMinutes) min"
        case .folderChanged:
            return trigger.deviceID == nil
                ? "Choose a folder to watch"
                : "Runs on that folder · at most every \(trigger.cooldownMinutes) min"
        }
    }

    private func deckName(_ id: UUID?) -> String {
        guard let id else { return "any deck" }
        return appState.hyperDecks.first { $0.id == id }?.name ?? "a deck"
    }

    private func triggerNode(_ trigger: ScheduleSettings, index: Int) -> some View {
        HStack(spacing: 12) {
            NodeIcon(systemImage: trigger.mode.icon,
                     color: trigger.isEnabled ? Color.canopySage : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(triggerTitle(trigger)).font(.canopyBody)
                Text(triggerDetail(trigger)).font(.canopyCaption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { trigger.isEnabled },
                set: { triggers[index].isEnabled = $0 }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)

            Button { editingTrigger = trigger } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless).help("Configure trigger")
            Button {
                withAnimation(.snappy) { _ = triggers.remove(at: index) }
            } label: {
                Image(systemName: "trash").foregroundStyle(Color.canopyRust)
            }
            .buttonStyle(.borderless).help("Remove trigger")
        }
        .padding(12)
        .background(NodeBackground())
        .contentShape(Rectangle())
        .onTapGesture { editingTrigger = trigger }
    }

    private func addTrigger(_ mode: ScheduleMode) {
        var trigger = ScheduleSettings()
        trigger.isEnabled = true
        trigger.mode = mode
        if mode == .folderChanged {
            trigger.deviceID = appState.localFolders.first?.id
        }
        withAnimation(.snappy) { triggers.append(trigger) }
        editingTrigger = trigger
    }

    private func handleTriggerDrop(_ items: [String]) -> Bool {
        var handled = false
        for item in items where item.hasPrefix(Payload.trigger) {
            let raw = String(item.dropFirst(Payload.trigger.count))
            if let mode = ScheduleMode(rawValue: raw) {
                addTrigger(mode)
                handled = true
            }
        }
        return handled
    }

    // MARK: Runs on

    /// True when, as it stands, the workflow has files to work on but no
    /// HyperDeck or folder to get them from.
    private var choosesFolderAtRun: Bool {
        Workflow(name: name, steps: steps, targets: Array(targets)).choosesFolderAtRun
    }

    private var runsOnSection: some View {
        VStack(spacing: 0) {
            sectionLabel("Folders to process", systemImage: "folder")
            VStack(alignment: .leading, spacing: 8) {
                Text("HyperDecks are chosen on the Offload, Control HyperDeck and Format Drive steps. Tick a folder to also run the steps on the files already in it.")
                    .font(.canopyCaption).foregroundStyle(.secondary)

                ForEach(appState.localFolders) { folder in
                    targetToggle(.localFolder(folder.id), label: folder.name, icon: "folder")
                }

                ForEach(selectedCloudStoreFolderTargets, id: \.target) { entry in
                    HStack {
                        Label(
                            entry.path.isEmpty ? entry.store.name : "\(entry.store.name)/\(entry.path)",
                            systemImage: "externaldrive.badge.wifi"
                        )
                        Spacer()
                        Button { targets.remove(entry.target) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                if !appState.cloudStores.isEmpty {
                    Menu {
                        ForEach(appState.cloudStores) { store in
                            Button(store.name) { pickingCloudStoreFolder = store }
                        }
                    } label: {
                        Label("Add Cloud Store Folder…", systemImage: "plus.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if choosesFolderAtRun {
                    Text("No HyperDeck or folder is set, so you'll be asked for a folder when you press Run.")
                        .font(.canopyCaption).foregroundStyle(.secondary)
                    if !triggers.isEmpty {
                        Label("Triggers can't start it — there's no folder to run on until you pick one.", systemImage: "exclamationmark.triangle")
                            .font(.canopyCaption).foregroundStyle(Color.canopyRust)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NodeBackground())
        }
    }

    /// Cloud Store Folder targets currently selected on this workflow, paired
    /// with the still-configured store they point at (a target whose store
    /// was since deleted is silently dropped from the list rather than shown
    /// broken).
    private var selectedCloudStoreFolderTargets: [(target: WorkflowTarget, store: CloudStore, path: String)] {
        targets.compactMap { target in
            guard case .cloudStore(let id, let path) = target,
                  let store = appState.cloudStores.first(where: { $0.id == id }) else { return nil }
            return (target, store, path)
        }
    }

    private func targetToggle(_ target: WorkflowTarget, label: String, icon: String) -> some View {
        Toggle(isOn: Binding(
            get: { targets.contains(target) },
            set: { isOn in
                if isOn { targets.insert(target) } else { targets.remove(target) }
            }
        )) {
            Label(label, systemImage: icon)
        }
    }

    // MARK: Steps

    private var stepsSection: some View {
        VStack(spacing: 0) {
            sectionLabel("Then, in order", systemImage: "list.number")
            if steps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.system(size: 28)).foregroundStyle(Color.canopySage)
                    Text("Drag steps here to build your workflow")
                        .font(.canopyHeadline).foregroundStyle(Color.canopyInk)
                    Text("Pick from the list on the left. Steps run top to bottom, and files flow from one step to the next.")
                        .font(.canopyCaption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36).padding(.horizontal, 20)
                .background(DropOutline(isTargeted: false))
                .modifier(StepDropTarget { handleStepDrop($0, at: 0) })
            } else {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    StepDropGap { handleStepDrop($0, at: index) }
                    stepNode(step, index: index)
                    suggestedNextRow(after: index)
                }
                StepDropGap(isLast: true) { handleStepDrop($0, at: steps.count) }
            }
            if !steps.isEmpty {
                Text("Steps run in order, top to bottom. Files flow from one step to the next.")
                    .font(.canopyCaption2).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    private func stepNode(_ step: WorkflowStep, index: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.canopyCaption).foregroundStyle(.tertiary)
                .help("Drag to reorder")
            Text("\(index + 1)")
                .font(.canopyCaption.weight(.semibold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(Circle().fill(step.kind.color.opacity(0.15)))
                .foregroundStyle(step.kind.color)
            NodeIcon(systemImage: step.kind.icon, color: step.kind.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(step.kind.title).font(.canopyBody)
                    if step.requiresConfirmation {
                        Image(systemName: "hand.raised.fill")
                            .font(.canopyCaption2).foregroundStyle(.orange)
                            .help("Asks for confirmation before running")
                    }
                }
                Text(step.kind.usesHyperDeck
                     ? "\(appState.label(for: step.decks)) · \(step.action.summary)"
                     : step.action.summary)
                    .font(.canopyCaption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button { editingStep = step } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless).help("Configure step")
            Button {
                duplicateStep(at: index)
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless).help("Duplicate step")
            Button {
                withAnimation(.snappy) { _ = steps.remove(at: index) }
            } label: {
                Image(systemName: "trash").foregroundStyle(Color.canopyRust)
            }
            .buttonStyle(.borderless).help("Remove step")
        }
        .padding(12)
        .background(NodeBackground())
        .contentShape(Rectangle())
        .onTapGesture { editingStep = step }
        .draggable(Payload.move + step.id.uuidString)
    }

    /// Steps that usually follow `steps[index]` and aren't already somewhere
    /// after it. Offered, never added automatically.
    private func suggestions(after index: Int) -> [StepAction] {
        // Start and Stop Recording share a kind, so compare by label.
        let later = Set(steps[(index + 1)...].map(\.action.shortLabel))
        return steps[index].action.suggestedFollowUps.filter { !later.contains($0.shortLabel) && !$0.kind.isComingSoon }
    }

    @ViewBuilder
    private func suggestedNextRow(after index: Int) -> some View {
        let kinds = suggestions(after: index)
        if !kinds.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.canopyCaption).foregroundStyle(.tertiary)
                Text("Suggested next")
                    .font(.canopyCaption).foregroundStyle(.secondary)
                ForEach(kinds, id: \.shortLabel) { action in
                    Button {
                        insertSuggestion(action, after: index)
                    } label: {
                        Label(action.shortLabel, systemImage: "plus")
                            .font(.canopyCaption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().strokeBorder(action.kind.color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .foregroundStyle(action.kind.color)
                    }
                    .buttonStyle(.plain)
                    .help(action.kind.subtitle)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6).padding(.leading, 14)
        }
    }

    /// A suggested step goes straight after its step. A deck step (Stop
    /// Recording) takes the same decks as the step it follows, so it acts
    /// on the decks that step started.
    private func insertSuggestion(_ action: StepAction, after index: Int) {
        var step = WorkflowStep(action: action)
        if step.kind.usesHyperDeck { step.decks = steps[index].decks }
        withAnimation(.snappy) { steps.insert(step, at: index + 1) }
    }

    private func insertStep(_ kind: StepKind, at index: Int) {
        let step = WorkflowStep(action: .defaultAction(for: kind))
        withAnimation(.snappy) {
            steps.insert(step, at: min(max(index, 0), steps.count))
        }
    }

    private func duplicateStep(at index: Int) {
        // New id so the copy is its own step; a Create Folder copy shouldn't
        // be mistaken for the original by steps that point at it.
        let copy = WorkflowStep(action: steps[index].action,
                                requiresConfirmation: steps[index].requiresConfirmation,
                                decks: steps[index].decks)
        withAnimation(.snappy) { steps.insert(copy, at: index + 1) }
    }

    /// Handles a drop onto the gap before step `index` (or the end of the list).
    /// A palette drag adds a new step there; a step drag moves that step.
    private func handleStepDrop(_ items: [String], at index: Int) -> Bool {
        var handled = false
        for item in items {
            if item.hasPrefix(Payload.step) {
                let raw = String(item.dropFirst(Payload.step.count))
                guard let kind = StepKind(rawValue: raw) else { continue }
                insertStep(kind, at: index)
                handled = true
            } else if item.hasPrefix(Payload.move) {
                let raw = String(item.dropFirst(Payload.move.count))
                guard let id = UUID(uuidString: raw),
                      let from = steps.firstIndex(where: { $0.id == id }) else { continue }
                // `move(toOffset:)` takes the offset in the pre-removal array,
                // so dropping directly above/below itself is a no-op.
                if index == from || index == from + 1 { handled = true; continue }
                withAnimation(.snappy) {
                    steps.move(fromOffsets: IndexSet(integer: from), toOffset: index)
                }
                handled = true
            }
        }
        return handled
    }

    // MARK: - Save

    private func save() {
        var workflow = existingWorkflow ?? Workflow(name: name)
        workflow.name = name.trimmingCharacters(in: .whitespaces)
        workflow.steps = steps
        workflow.targets = Array(targets)
        workflow.triggers = triggers

        if existingWorkflow == nil {
            appState.addWorkflow(workflow)
        } else {
            appState.updateWorkflow(workflow)
        }
        SchedulerService.shared.sync()
        onClose()
    }
}

// MARK: - Palette tile

private struct PaletteTile: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    var dimmed = false

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            NodeIcon(systemImage: icon, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.canopySans(13, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.canopyCaption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering && !dimmed ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.canopyRule, lineWidth: 1)
        )
        .opacity(dimmed ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Workspace pieces

private struct NodeIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.14)))
    }
}

private struct NodeBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.canopyRule, lineWidth: 1))
    }
}

private struct DropOutline: View {
    let isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
                isTargeted ? Color.canopySage : Color.canopyRule,
                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [6, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isTargeted ? Color.canopySage.opacity(0.10) : .clear)
            )
    }
}

/// The slot between two steps. Grows and lights up while something is dragged over it.
private struct StepDropGap: View {
    var isLast = false
    let onDrop: ([String]) -> Bool

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.canopyRule).frame(width: 2)
                .frame(maxHeight: .infinity)
                .opacity(isLast ? 0 : 1)
            if isTargeted {
                Capsule().fill(Color.canopySage).frame(height: 4)
                    .overlay(alignment: .center) {
                        Text("Drop here")
                            .font(.canopyCaption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Color.canopySage))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(height: isTargeted ? 44 : (isLast ? 36 : 22))
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            onDrop(items)
        } isTargeted: { isTargeted = $0 }
        .animation(.snappy(duration: 0.15), value: isTargeted)
    }
}

private struct StepDropTarget: ViewModifier {
    let onDrop: ([String]) -> Bool
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay(DropOutline(isTargeted: isTargeted).allowsHitTesting(false).opacity(isTargeted ? 1 : 0))
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                onDrop(items)
            } isTargeted: { isTargeted = $0 }
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 22
            var path = Path()
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += spacing
                }
                y += spacing
            }
            context.fill(path, with: .color(Color.canopyRule))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Schedule Trigger Config Sheet

/// Small focused sheet for configuring a single schedule trigger — mirrors
/// WorkflowStepConfigSheet's pattern of editing one item from a list.
struct ScheduleTriggerConfigSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Binding var trigger: ScheduleSettings
    /// Workflows offered by a "When a workflow finishes" trigger.
    var sourceWorkflows: [Workflow] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(trigger.mode.title) Trigger", systemImage: trigger.mode.icon)
                .font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.canopyPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Rectangle().fill(Color.canopyRule).frame(height: 1)

            Form {
                Toggle("Enabled", isOn: $trigger.isEnabled)

                Picker("Trigger", selection: $trigger.mode) {
                    Section("On a schedule") {
                        ForEach(ScheduleMode.scheduleModes) { Text($0.title).tag($0) }
                    }
                    Section("When something happens") {
                        ForEach(ScheduleMode.eventModes) { Text($0.title).tag($0) }
                    }
                }

                switch trigger.mode {
                case .daily:
                    HStack(spacing: 8) {
                        Stepper(value: $trigger.hour, in: 0...23) {
                            Text(String(format: "%02d", trigger.hour)).monospacedDigit().frame(width: 28)
                        }
                        Text(":")
                        Stepper(value: $trigger.minute, in: 0...59, step: 5) {
                            Text(String(format: "%02d", trigger.minute)).monospacedDigit().frame(width: 28)
                        }
                        Text(trigger.displayTime).font(.canopyCaption).foregroundStyle(.secondary).padding(.leading, 4)
                    }
                    Toggle("Repeat Daily", isOn: $trigger.repeatDaily)
                    if trigger.repeatDaily {
                        weekdaySelector
                    }

                case .oneTime:
                    DatePicker(
                        "Run At",
                        selection: $trigger.oneTimeDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Text("Runs once at the selected date and time, then turns off.")
                        .font(.canopyCaption).foregroundStyle(.secondary)

                case .recordingStopped:
                    deckPicker
                    note("Runs the workflow on the deck that just stopped, so a take can be offloaded the moment it ends. Decks that drop off the network don't count.")
                    cooldownStepper

                case .deviceOnline:
                    deckPicker
                    note("Runs when a deck that was unreachable — or had lost its drive or login — is back online. A deck that's already online when Canopy launches doesn't count.")
                    cooldownStepper

                case .workflowFinished:
                    Picker("Workflow", selection: $trigger.sourceWorkflowID) {
                        Text("Choose a workflow").tag(UUID?.none)
                        ForEach(sourceWorkflows) { workflow in
                            Text(workflow.name).tag(Optional(workflow.id))
                        }
                    }
                    Picker("Run when", selection: $trigger.finishCondition) {
                        ForEach(WorkflowFinishCondition.allCases) { Text($0.title).tag($0) }
                    }
                    note("Runs after the chosen workflow finishes. Runs you stop by hand don't count.")
                    cooldownStepper

                case .folderChanged:
                    Picker("Folder", selection: $trigger.deviceID) {
                        Text("Choose a folder").tag(UUID?.none)
                        ForEach(appState.localFolders) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }
                    if appState.localFolders.isEmpty {
                        note("Add a Local Folder in Devices first.")
                    } else {
                        note("Checked every 30 seconds. Clips already in the folder are ignored; the workflow runs on the folder once new clips have finished copying in.")
                    }
                    cooldownStepper
                }
            }
            .formStyle(.grouped)
            .padding(.top, 4)
        }
        .frame(width: 420)
        .background(Color.canopyPaper)
    }

    private var deckPicker: some View {
        Picker("Deck", selection: $trigger.deviceID) {
            Text("Any deck").tag(UUID?.none)
            ForEach(appState.hyperDecks) { deck in
                Text(deck.name).tag(Optional(deck.id))
            }
        }
    }

    private var cooldownStepper: some View {
        Stepper(value: $trigger.cooldownMinutes, in: 1...240) {
            Text("At most once every \(trigger.cooldownMinutes) min")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.canopyCaption).foregroundStyle(.secondary)
    }

    private var weekdaySelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runs On").font(.canopyCaption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Weekday.allCases) { day in
                    let isOn = trigger.selectedWeekdays.contains(day)
                    Button {
                        if isOn {
                            trigger.selectedWeekdays.remove(day)
                        } else {
                            trigger.selectedWeekdays.insert(day)
                        }
                    } label: {
                        Text(day.shortLabel)
                            .font(.canopyCaption).bold()
                            .frame(width: 32, height: 28)
                            .background(isOn ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                            .foregroundStyle(isOn ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(trigger.displayWeekdays)
                .font(.canopyCaption2).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }
}
