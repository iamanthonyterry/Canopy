import SwiftUI

/// Create or edit a Workflow: name, target devices, an ordered list of
/// steps, and an optional schedule of its own.
struct WorkflowEditorSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let existingWorkflow: Workflow?

    @State private var name: String
    @State private var steps: [WorkflowStep]
    @State private var targetDeckIDs: Set<UUID>
    @State private var triggers: [ScheduleSettings]
    @State private var editingStep: WorkflowStep? = nil
    @State private var editingTrigger: ScheduleSettings? = nil

    init(workflow: Workflow?) {
        existingWorkflow = workflow
        _name          = State(initialValue: workflow?.name ?? "")
        _steps         = State(initialValue: workflow?.steps ?? [])
        _targetDeckIDs = State(initialValue: Set(workflow?.targetDeckIDs ?? []))
        _triggers      = State(initialValue: workflow?.triggers ?? [])
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
                WorkflowStepConfigSheet(step: $steps[index])
            }
        }
        .sheet(item: $editingTrigger) { trigger in
            if let index = triggers.firstIndex(where: { $0.id == trigger.id }) {
                ScheduleTriggerConfigSheet(trigger: $triggers[index])
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

    private var targetDevicesSection: some View {
        Section("Runs On") {
            Toggle("All Devices", isOn: Binding(
                get: { targetDeckIDs.isEmpty },
                set: { if $0 { targetDeckIDs.removeAll() } }
            ))
            if !appState.hyperDecks.isEmpty {
                ForEach(appState.hyperDecks) { deck in
                    Toggle(deck.name, isOn: Binding(
                        get: { targetDeckIDs.isEmpty || targetDeckIDs.contains(deck.id) },
                        set: { isOn in
                            if isOn {
                                targetDeckIDs.insert(deck.id)
                                if targetDeckIDs.count == appState.hyperDecks.count { targetDeckIDs.removeAll() }
                            } else {
                                if targetDeckIDs.isEmpty { targetDeckIDs = Set(appState.hyperDecks.map(\.id)) }
                                targetDeckIDs.remove(deck.id)
                            }
                        }
                    ))
                }
            } else {
                Text("No devices configured yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
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
                Text(step.kind.title).font(.body)
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
            ForEach(StepKind.allCases) { kind in
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
        workflow.targetDeckIDs = Array(targetDeckIDs)
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
