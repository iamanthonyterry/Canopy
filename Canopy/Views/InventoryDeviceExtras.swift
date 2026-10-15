import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Service log

struct ServiceLogSection: View {
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    @State private var adding = false
    @State private var kind: ServiceKind = .repair
    @State private var date = Date()
    @State private var summary = ""
    @State private var cost = ""
    @State private var vendor = ""
    @State private var newStatus: EquipmentStatus?
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        let entries = store.service(of: equipment)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Service log").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                let spent = entries.compactMap(\.cost).reduce(0, +)
                if spent > 0 { Text("\(InventoryRules.money(spent)) spent").font(.canopyCaption).foregroundStyle(.secondary) }
                Spacer()
                if store.level.canEdit && !adding { Button("Add entry") { adding = true }.buttonStyle(.canopySecondary) }
            }
            if adding { form }
            if entries.isEmpty && !adding {
                Text("No repairs, maintenance or inspections logged yet.").foregroundStyle(.secondary)
            }
            ForEach(entries) { s in
                HStack(alignment: .firstTextBaseline) {
                    Text(InventoryRules.formatDate(s.performedOn)).monospacedDigit().foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                    CanopyPill(label: s.kind.label, color: s.kind == .repair ? .canopyRust : .canopySage)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.summary)
                        let extra = [s.vendor, s.cost.map { InventoryRules.money($0) } ?? ""].filter { !$0.isEmpty }
                        if !extra.isEmpty { Text(extra.joined(separator: " · ")).font(.canopyCaption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if store.level.canEdit {
                        Button { Task { result = await store.deleteService(s.id) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete this entry")
                    }
                }
                .font(.canopyCallout)
            }
            ResultLine(result: result)
        }
        .canopyCard(padding: 14)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Kind", selection: $kind) { ForEach(ServiceKind.allCases) { Text($0.label).tag($0) } }.frame(width: 180)
                DatePicker("Date", selection: $date, displayedComponents: .date).frame(width: 200)
            }
            TextField("What was done", text: $summary).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Cost ($)", text: $cost).textFieldStyle(.roundedBorder).frame(width: 100)
                TextField("Who did it", text: $vendor).textFieldStyle(.roundedBorder)
                Picker("Then", selection: $newStatus) {
                    Text("Keep status").tag(EquipmentStatus?.none)
                    ForEach(EquipmentStatus.allCases) { Text("Mark \($0.label.lowercased())").tag(EquipmentStatus?.some($0)) }
                }
                .frame(width: 200)
            }
            HStack {
                Spacer()
                Button("Cancel") { adding = false }.buttonStyle(.canopySecondary)
                Button("Add") {
                    let amount = Double(cost.replacingOccurrences(of: #"[$,\s]"#, with: "", options: .regularExpression))
                    if !cost.isEmpty && amount == nil { result = (false, "The cost must be a dollar amount."); return }
                    Task {
                        result = await store.addService(equipment.id, kind: kind, date: date, summary: summary, cost: amount, vendor: vendor, newStatus: newStatus)
                        if result?.ok == true { adding = false; summary = ""; cost = ""; vendor = ""; newStatus = nil }
                    }
                }
                .buttonStyle(.canopyPrimary).disabled(summary.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10).background(Color.canopyPaper, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Files

struct FilesSection: View {
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    @State private var result: (ok: Bool, message: String)?
    @State private var working = false
    @State private var importing = false
    @State private var confirmDelete: EquipmentFile?

    var body: some View {
        let files = store.files(of: equipment)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Files").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Text("Scenes, show files, router backups, manuals, receipts").font(.canopyCaption).foregroundStyle(.secondary)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Add file…") { importing = true }.buttonStyle(.canopySecondary).disabled(working)
            }
            if files.isEmpty { Text("No files yet.").foregroundStyle(.secondary) }
            ForEach(files) { f in FileRow(file: f, result: $result, confirmDelete: $confirmDelete) }
            ResultLine(result: result)
        }
        .canopyCard(padding: 14)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { picked in
            guard case .success(let urls) = picked else { return }
            Task {
                working = true
                defer { working = false }
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    result = await store.uploadFile(equipment.id, url: url)
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    if result?.ok == false { break }
                }
            }
        }
        .confirmationDialog(confirmDelete.map { "Delete \($0.name)?" } ?? "",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let f = confirmDelete { Task { result = await store.deleteFile(f) } }; confirmDelete = nil }
        }
    }
}

struct FileRow: View {
    @ObservedObject private var store = InventoryStore.shared
    let file: EquipmentFile
    var showDevice = false
    @Binding var result: (ok: Bool, message: String)?
    @Binding var confirmDelete: EquipmentFile?

    var body: some View {
        HStack {
            Image(systemName: "doc").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                Text([showDevice ? store.byID[file.equipmentId]?.name ?? "" : "", InventoryRules.size(file.size), String(file.createdAt.prefix(10))]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.canopyCaption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save…") { save() }.buttonStyle(.borderless)
            Button { confirmDelete = file } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        .font(.canopyCallout)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await store.downloadFile(file).write(to: url)
                result = (true, "Saved \(url.lastPathComponent).")
            } catch {
                result = (false, error.localizedDescription)
            }
        }
    }
}

// MARK: - Add / edit form

struct EquipmentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = InventoryStore.shared
    let title: String
    @State var draft: EquipmentDraft
    var existing: Equipment? = nil
    let onSave: (EquipmentDraft) async throws -> Void

    @State private var saving = false
    @State private var error: String?
    @State private var presetQuery = ""
    @State private var more = false

    private var roomsHere: [Room] { store.rooms.filter { $0.campus == draft.campus } }
    private var racksHere: [Rack] { store.racks.filter { $0.roomId == draft.roomId } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.canopyPrimary)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Rectangle().fill(Color.canopyRule).frame(height: 1)
            Form {
                if existing == nil && !store.presets.isEmpty { startFrom }
                Section("Device") {
                    TextField("Name", text: $draft.name, prompt: Text("Allen & Heath dLive C3500"))
                    TextField("Make and model", text: $draft.makeModel)
                    Picker("Category", selection: $draft.category) {
                        Text("Not set").tag("")
                        ForEach(InventoryCategories.all, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Type", selection: $draft.role) {
                        Text("Not set").tag(DeviceRole?.none)
                        ForEach(DeviceRole.allCases) { Text($0.label).tag(DeviceRole?.some($0)) }
                    }
                    if draft.role == nil, let guess = InventoryRules.suggestRole(name: draft.name, makeModel: draft.makeModel, category: draft.category) {
                        Button("Looks like a \(guess.label.lowercased()). Use that?") { draft.role = guess }.buttonStyle(.link)
                    }
                    Text("The type is used to suggest what to patch to, and to warn about unusual cables.").font(.canopyCaption).foregroundStyle(.secondary)
                }
                Section("Channels") {
                    Stepper("Inputs: \(draft.inputs)", value: $draft.inputs, in: 0...256)
                    Stepper("Outputs: \(draft.outputs)", value: $draft.outputs, in: 0...256)
                    Picker("New channels carry", selection: $draft.signal) {
                        Text("Usual for the category").tag(Signal?.none)
                        ForEach(Signal.allCases) { Text($0.label).tag(Signal?.some($0)) }
                    }
                    Stepper("Option card slots: \(draft.cardSlots)", value: $draft.cardSlots, in: 0...16)
                    if existing != nil {
                        Text("Lowering a count removes the highest-numbered channels and their cables.").font(.canopyCaption).foregroundStyle(.secondary)
                    }
                }
                Section("Where it is") {
                    if store.campuses.count > 1 || !draft.campus.isEmpty {
                        Picker("Campus", selection: $draft.campus) {
                            Text("Not assigned yet").tag("")
                            ForEach(store.campuses) { Text($0.name).tag($0.id) }
                        }
                        .onChange(of: draft.campus) { if let r = draft.roomId, store.roomsByID[r]?.campus != draft.campus { draft.roomId = nil; draft.rackId = nil } }
                    }
                    Picker("Room", selection: Binding(get: { draft.roomId }, set: { draft.roomId = $0; draft.rackId = nil; draft.rackUnit = nil })) {
                        Text(roomsHere.isEmpty ? "No rooms in this campus yet" : "Not in a room").tag(String?.none)
                        ForEach(roomsHere) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    if draft.roomId != nil {
                        Picker("Rack", selection: $draft.rackId) {
                            Text(racksHere.isEmpty ? "No racks in this room" : "Not in a rack").tag(String?.none)
                            ForEach(racksHere) { Text("\($0.name) (\($0.units)U)").tag(String?.some($0.id)) }
                        }
                    }
                    if let rack = draft.rackId.flatMap({ store.racksByID[$0] }) {
                        HStack {
                            Toggle("Lowest rack unit", isOn: Binding(get: { draft.rackUnit != nil }, set: { draft.rackUnit = $0 ? 1 : nil }))
                            if draft.rackUnit != nil {
                                Stepper("U\(draft.rackUnit ?? 1)", value: Binding(get: { draft.rackUnit ?? 1 }, set: { draft.rackUnit = $0 }), in: 1...rack.units)
                            }
                        }
                        Stepper("Height: \(draft.rackHeight)U", value: $draft.rackHeight, in: 1...rack.units)
                    }
                    TextField("Spot in the room", text: $draft.location, prompt: Text("Left shelf, under the desk, stage right…"))
                    Text("Add rooms and racks on the Rooms & Racks tab.").font(.canopyCaption).foregroundStyle(.secondary)
                }
                Section("More") {
                    DisclosureGroup("Status, purchase and warranty, network login, notes", isExpanded: $more) {
                        Picker("Status", selection: $draft.status) { ForEach(EquipmentStatus.allCases) { Text($0.label).tag($0) } }
                        Picker("Condition", selection: $draft.condition) {
                            Text("Not set").tag(EquipmentCondition?.none)
                            ForEach(EquipmentCondition.allCases) { Text($0.label).tag(EquipmentCondition?.some($0)) }
                        }
                        TextField("Serial number", text: $draft.serial)
                        TextField("Value now ($)", value: $draft.value, format: .number)
                        OptionalDate(label: "Purchase date", date: $draft.purchaseDate)
                        if draft.purchaseDate == nil { TextField("Year purchased", value: $draft.yearPurchased, format: .number.grouping(.never)) }
                        TextField("Price paid ($)", value: $draft.purchasePrice, format: .number)
                        TextField("Bought from", text: $draft.vendor, prompt: Text("Sweetwater, B&H, a church member…"))
                        OptionalDate(label: "Warranty ends", date: $draft.warrantyExpires)
                        TextField("Warranty terms", text: $draft.warrantyTerms)
                        TextField("IP address", text: $draft.ipAddress)
                        TextField("Username", text: $draft.username)
                        SecureField("Password", text: $draft.password)
                        Text("Logins are visible only to people who can view everything.").font(.canopyCaption).foregroundStyle(.secondary)
                        TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(Color.canopyRust)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 560, idealHeight: 720)
    }

    private var startFrom: some View {
        Section("Start from") {
            TextField("Search devices, e.g. SQ-5 or Shure", text: $presetQuery)
            let q = presetQuery.lowercased().trimmingCharacters(in: .whitespaces)
            if !q.isEmpty {
                let hits = store.presets.filter { $0.name.lowercased().contains(q) || $0.category.lowercased().contains(q) }.prefix(12)
                ForEach(Array(hits)) { p in
                    Button {
                        draft.apply(p); presetQuery = ""
                    } label: {
                        HStack {
                            Text(p.name)
                            Spacer()
                            Text("\(p.inputs) in · \(p.outputs) out\(p.price.map { " · " + InventoryRules.money($0) } ?? "")").font(.canopyCaption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if hits.isEmpty { Text("Not in the list. Fill it in below.").font(.canopyCaption).foregroundStyle(.secondary) }
            }
        }
    }

    private func save() {
        saving = true; error = nil
        Task {
            do {
                try await onSave(draft)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

private struct OptionalDate: View {
    let label: String
    @Binding var date: Date?
    var body: some View {
        HStack {
            Toggle(label, isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? Date()) : nil }))
            if date != nil {
                DatePicker("", selection: Binding(get: { date ?? Date() }, set: { date = $0 }), displayedComponents: .date).labelsHidden()
            }
        }
    }
}
