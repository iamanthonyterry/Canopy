import SwiftUI

/// Create or edit a Workflow: name, target devices, an ordered list of
/// steps, and an optional schedule of its own.
struct WorkflowEditorSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let existingWorkflow: Workflow?

    @State private var name: String
    @State private var steps: [WorkflowStep]
    @State private var targets: Set<WorkflowTarget>
    @State private var triggers: [ScheduleSettings]
    @State private var editingStep: WorkflowStep? = nil
    @State private var editingTrigger: ScheduleSettings? = nil
    @State private var pickingCloudStoreFolder: CloudStore? = nil

    init(workflow: Workflow?) {
        existingWorkflow = workflow
        _name    = State(initialValue: workflow?.name ?? "")
        _steps   = State(initialValue: workflow?.steps ?? [])
        _targets = State(initialValue: Set(workflow?.targets ?? []))
        _triggers = State(initialValue: workflow?.triggers ?? [])
    }

    var canSave: Bool { !name.isEmpty && !steps.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                detailsSection
                targetDevicesSection
                stepsSection
                scheduleSection
            }
            .listStyle(.inset)
        }
        .frame(width: 520, height: 620)
        .sheet(item: $editingStep) { step in
            if let index = steps.firstIndex(where: { $0.id == step.id }) {
                WorkflowStepConfigSheet(
                    step: $steps[index],
                    availableFolderSteps: steps.filter { $0.kind == .createFolder && $0.id != step.id },
                    excludingWorkflowID: existingWorkflow?.id
                )
                .environmentObject(appState)
            }
        }
        .sheet(item: $editingTrigger) { trigger in
            if let index = triggers.firstIndex(where: { $0.id == trigger.id }) {
                ScheduleTriggerConfigSheet(trigger: $triggers[index])
            }
        }
        .sheet(item: $pickingCloudStoreFolder) { store in
            FolderPickerSheet(store: store) { path in
                addCloudStoreFolderTarget(store: store, path: path)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(existingWorkflow == nil ? "New Workflow" : "Edit Workflow")
                .font(.title2).bold()
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(existingWorkflow == nil ? "Create" : "Save") { save() }
                .buttonStyle(.borderedProminent).disabled(!canSave)
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Details

    private var detailsSection: some View {
        Section("Details") {
            TextField("Workflow Name", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Target Devices

    /// Every HyperDeck and Local Folder currently configured — used to
    /// decide when an explicit selection actually covers everything (and
    /// so can collapse back down to the "All Devices" empty-set shorthand).
    private var allPossibleTargets: Set<WorkflowTarget> {
        Set(appState.hyperDecks.map { WorkflowTarget.hyperDeck($0.id) }
            + appState.localFolders.map { WorkflowTarget.localFolder($0.id) })
    }

    private var targetDevicesSection: some View {
        Section {
            Toggle("All Devices", isOn: Binding(
                get: { targets.isEmpty },
                set: { if $0 { targets.removeAll() } }
            ))
            if !appState.hyperDecks.isEmpty {
                ForEach(appState.hyperDecks) { deck in
                    targetToggle(.hyperDeck(deck.id), label: deck.name)
                }
            }
            if !appState.localFolders.isEmpty {
                ForEach(appState.localFolders) { folder in
                    targetToggle(.localFolder(folder.id), label: folder.name)
                }
            }
            if appState.hyperDecks.isEmpty && appState.localFolders.isEmpty {
                Text("No devices configured yet.").font(.caption).foregroundStyle(.secondary)
            }

            ForEach(selectedCloudStoreFolderTargets, id: \.target) { entry in
                HStack {
                    Label(
                        entry.path.isEmpty ? entry.store.name : "\(entry.store.name)/\(entry.path)",
                        systemImage: "externaldrive.badge.wifi"
                    )
                    Spacer()
                    Button {
                        targets.remove(entry.target)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
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
        } header: {
            Text("Runs On")
        } footer: {
            Text("A Cloud Store Folder runs in place, like a Local Folder — it processes files already sitting in that folder rather than downloading from a device.")
                .font(.caption).foregroundStyle(.secondary)
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

    /// Adds a Cloud Store Folder target for the given store + path. If the
    /// selection was still the "All Devices" shorthand (an empty `targets`
    /// set), that shorthand is expanded to its explicit equivalent first —
    /// otherwise adding this one target would also silently drop every
    /// implicitly-included HyperDeck and Local Folder.
    private func addCloudStoreFolderTarget(store: CloudStore, path: String) {
        if targets.isEmpty { targets = allPossibleTargets }
        targets.insert(.cloudStore(id: store.id, path: path))
    }

    private func targetToggle(_ target: WorkflowTarget, label: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { targets.isEmpty || targets.contains(target) },
            set: { isOn in
                if isOn {
                    targets.insert(target)
                    if targets.count == allPossibleTargets.count { targets.removeAll() }
                } else {
                    if targets.isEmpty { targets = allPossibleTargets }
                    targets.remove(target)
                }
            }
        ))
    }

    /// Whether the current selection includes at least one HyperDeck —
    /// explicitly, or implicitly via "All Devices" when any are configured.
    /// Gates whether HyperDeck-only steps can be added below.
    private var includesHyperDeckTarget: Bool {
        if targets.isEmpty { return !appState.hyperDecks.isEmpty }
        return targets.contains { if case .hyperDeck = $0 { return true }; return false }
    }

    // MARK: - Steps

    private var stepsSection: some View {
        Section {
            if steps.isEmpty {
                Text("Add steps below to build your workflow.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    stepRow(step, index: index)
                }
                .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { steps.remove(atOffsets: $0) }
            }
            addStepMenu
        } header: {
            Text("Steps")
        } footer: {
            Text("Steps run in order, top to bottom. Files flow from one step to the next.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stepRow(_ step: WorkflowStep, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: step.kind.icon)
                .foregroundStyle(step.kind.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(step.kind.title).font(.body)
                    if step.requiresConfirmation {
                        Image(systemName: "hand.raised.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Asks for confirmation before running")
                    }
                }
                Text(step.action.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            VStack(spacing: 0) {
                Button {
                    guard index > 0 else { return }
                    steps.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)

                Button {
                    guard index < steps.count - 1 else { return }
                    steps.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(index == steps.count - 1)
            }
            .font(.caption)

            Button {
                editingStep = step
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)

            Button {
                steps.remove(at: index)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture { editingStep = step }
    }

    private var addStepMenu: some View {
        Menu {
            ForEach(StepKind.allCases.filter { includesHyperDeckTarget || ![.controlDeck, .format].contains($0) }) { kind in
                Button {
                    steps.append(WorkflowStep(action: .defaultAction(for: kind)))
                } label: {
                    Label(kind.title, systemImage: kind.icon)
                }
            }
        } label: {
            Label("Add Step", systemImage: "plus.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        Section {
            if triggers.isEmpty {
                Text("This workflow only runs when started manually.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(triggers.enumerated()), id: \.element.id) { index, trigger in
                    triggerRow(trigger, index: index)
                }
                .onDelete { triggers.remove(atOffsets: $0) }
            }
            addTriggerMenu
        } header: {
            Text("Schedule")
        } footer: {
            Text("Add one or more triggers to run this workflow automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func triggerRow(_ trigger: ScheduleSettings, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: trigger.mode == .daily ? "clock" : "calendar")
                .foregroundStyle(trigger.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.mode == .daily ? "Daily · \(trigger.displayTime)" : "One Time · \(trigger.displayOneTimeDate)")
                    .font(.body)
                Text(trigger.mode == .daily ? trigger.displayWeekdays : "Runs once, then turns off")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { trigger.isEnabled },
                set: { triggers[index].isEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                editingTrigger = trigger
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)

            Button {
                triggers.remove(at: index)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture { editingTrigger = trigger }
    }

    private var addTriggerMenu: some View {
        Button {
            var trigger = ScheduleSettings()
            trigger.isEnabled = true
            triggers.append(trigger)
            editingTrigger = trigger
        } label: {
            Label("Add Trigger", systemImage: "plus.circle.fill")
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Save

    private func save() {
        var workflow = existingWorkflow ?? Workflow(name: name)
        workflow.name = name
        workflow.steps = steps
        workflow.targets = Array(targets)
        workflow.triggers = triggers

        if existingWorkflow == nil {
            appState.addWorkflow(workflow)
        } else {
            appState.updateWorkflow(workflow)
        }
        SchedulerService.shared.sync()
        dismiss()
    }
}

// MARK: - Schedule Trigger Config Sheet

/// Small focused sheet for configuring a single schedule trigger — mirrors
/// WorkflowStepConfigSheet's pattern of editing one item from a list.
struct ScheduleTriggerConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var trigger: ScheduleSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(
                    trigger.mode == .daily ? "Daily Trigger" : "One-Time Trigger",
                    systemImage: trigger.mode == .daily ? "clock" : "calendar"
                )
                .font(.title3).bold()
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            Form {
                Toggle("Enabled", isOn: $trigger.isEnabled)

                Picker("", selection: $trigger.mode) {
                    ForEach(ScheduleMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

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
                        Text(trigger.displayTime).font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
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
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.top, 4)
        }
        .frame(width: 380)
    }

    private var weekdaySelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runs On").font(.caption).foregroundStyle(.secondary)
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
                            .font(.caption).bold()
                            .frame(width: 32, height: 28)
                            .background(isOn ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                            .foregroundStyle(isOn ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(trigger.displayWeekdays)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }
}
