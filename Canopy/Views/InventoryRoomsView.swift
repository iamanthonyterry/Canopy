import SwiftUI

// MARK: - Rooms and racks
// Where everything lives: each campus's rooms, the racks in them drawn unit by
// unit (U1 at the bottom), and what's on a shelf rather than in a rack.

struct RoomsRacksView: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    @State private var newRoom = ""
    @State private var newRoomCampus = ""
    @State private var result: (ok: Bool, message: String)?

    private var campusesShown: [String] {
        if store.scope == InventoryRules.unassigned { return [""] }
        if !store.scope.isEmpty { return [store.scope] }
        var ids = store.campuses.map(\.id)
        if store.rooms.contains(where: { $0.campus.isEmpty }) || store.hasUnassigned { ids.append("") }
        return ids
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.level.canEdit { addRoom }
                ResultLine(result: result)
                ForEach(campusesShown, id: \.self) { campus in
                    VStack(alignment: .leading, spacing: 10) {
                        if campusesShown.count > 1 { Text(store.campusName(campus)).font(.canopyTitle).foregroundStyle(Color.canopyInk) }
                        let rooms = store.rooms.filter { $0.campus == campus }
                        if rooms.isEmpty { Text("No rooms in this campus yet.").foregroundStyle(.secondary) }
                        ForEach(rooms) { RoomCard(room: $0, result: $result) }
                        let loose = store.equipment.filter { $0.campus == campus && $0.roomId == nil }
                        if !loose.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Not in a room · \(loose.count)").font(.canopyHeadline)
                                FlowLayout(spacing: 6) {
                                    ForEach(loose) { d in DeviceChip(device: d, rooms: rooms, result: $result) }
                                }
                            }
                            .canopyCard(padding: 12)
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear { newRoomCampus = store.scope == InventoryRules.unassigned ? "" : (store.scope.isEmpty ? store.campuses.first?.id ?? "" : store.scope) }
    }

    private var addRoom: some View {
        HStack {
            TextField("New room: Sanctuary, Tech booth, Youth room…", text: $newRoom).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                .onSubmit(add)
            if store.scope.isEmpty && store.campuses.count > 1 {
                Picker("in", selection: $newRoomCampus) { ForEach(store.campuses) { Text($0.name).tag($0.id) } }.fixedSize()
            }
            Button("Add room", action: add).buttonStyle(.canopySecondary).disabled(newRoom.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
    }

    private func add() {
        let campus = store.scope.isEmpty ? newRoomCampus : (store.scope == InventoryRules.unassigned ? "" : store.scope)
        Task {
            result = await store.addRoom(campus: campus, name: newRoom)
            if result?.ok == true { newRoom = "" }
        }
    }
}

private struct RoomCard: View {
    @ObservedObject private var store = InventoryStore.shared
    let room: Room
    @Binding var result: (ok: Bool, message: String)?
    @State private var renaming = false
    @State private var name = ""
    @State private var campus = ""
    @State private var newRack = ""
    @State private var units = 42
    @State private var confirmDelete = false

    var body: some View {
        let racks = store.racks(in: room)
        let shelf = store.equipment.filter { $0.roomId == room.id && $0.rackId == nil }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(room.name).font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                let count = store.equipment.filter { $0.roomId == room.id }.count
                Text("\(count) \(count == 1 ? "device" : "devices")").font(.canopyCaption).foregroundStyle(.secondary)
                Spacer()
                if store.level.canEdit {
                    Button("Rename or move") { name = room.name; campus = room.campus; renaming = true }.buttonStyle(.borderless)
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            if renaming {
                HStack {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    if store.campuses.count > 1 {
                        Picker("Campus", selection: $campus) { ForEach(store.campuses) { Text($0.name).tag($0.id) } }.fixedSize()
                    }
                    Button("Cancel") { renaming = false }.buttonStyle(.canopySecondary)
                    Button("Save") { Task { result = await store.updateRoom(room.id, name: name, campus: campus); if result?.ok == true { renaming = false } } }
                        .buttonStyle(.canopyPrimary)
                }
                if campus != room.campus { Text("Moving the room takes its racks and everything in it to that campus.").font(.canopyCaption).foregroundStyle(.secondary) }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(racks) { RackElevation(rack: $0, result: $result) }
                    if store.level.canEdit {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Add a rack").font(.canopyHeadline)
                            TextField("Rack A, FOH rack…", text: $newRack).textFieldStyle(.roundedBorder).frame(width: 180)
                            Stepper("\(units) units", value: $units, in: 1...60)
                            Button("Add rack") { Task { result = await store.addRack(room: room.id, name: newRack, units: units); if result?.ok == true { newRack = "" } } }
                                .buttonStyle(.canopySecondary).disabled(newRack.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .frame(width: 200).padding(10)
                        .background(Color.canopyPaper, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            if !shelf.isEmpty {
                Text("Not in a rack").font(.canopyCaption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(shelf) { d in DeviceChip(device: d, rooms: store.rooms.filter { $0.campus == room.campus }, result: $result) }
                }
            }
        }
        .canopyCard(padding: 14)
        .confirmationDialog("Delete \(room.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { result = await store.deleteRoom(room.id) } }
        } message: { Text("Its equipment stays in the inventory, just no longer placed in a room.") }
    }
}

/// A device that can be opened, moved to a room, or put in a rack.
private struct DeviceChip: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    let device: Equipment
    let rooms: [Room]
    @Binding var result: (ok: Bool, message: String)?

    var body: some View {
        Menu {
            Button("Open") { nav.open(device.id) }
            if store.level.canEdit {
                Menu("Move to room") {
                    ForEach(rooms) { r in Button(r.name) { Task { result = await store.moveToRoom(device.id, room: r.id) } } }
                    if device.roomId != nil { Divider(); Button("Not in a room") { Task { result = await store.moveToRoom(device.id, room: nil) } } }
                }
            }
        } label: {
            Label(device.name, systemImage: device.role?.symbol ?? "shippingbox").font(.canopyCaption)
        }
        .menuStyle(.button).fixedSize()
    }
}

private struct RackElevation: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    let rack: Rack
    @Binding var result: (ok: Bool, message: String)?
    @State private var editing = false
    @State private var name = ""
    @State private var units = 42
    @State private var confirmDelete = false

    private static let unitHeight: CGFloat = 18

    var body: some View {
        let inRack = store.devices(in: rack)
        let placed = inRack.filter { $0.rackUnit != nil }
        let unplaced = inRack.filter { $0.rackUnit == nil }
        let candidates = store.equipment.filter { $0.campus == (store.roomsByID[rack.roomId]?.campus ?? "") && $0.rackId == nil }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(rack.name).font(.canopyHeadline)
                Text("\(rack.units)U").font(.canopyCaption).foregroundStyle(.secondary)
                Spacer()
                if store.level.canEdit {
                    Menu {
                        Button("Rename or resize…") { name = rack.name; units = rack.units; editing = true }
                        Button("Delete rack…", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            if editing {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                Stepper("\(units) units", value: $units, in: 1...60)
                HStack {
                    Button("Cancel") { editing = false }.buttonStyle(.canopySecondary)
                    Button("Save") { Task { result = await store.updateRack(rack.id, name: name, units: units); if result?.ok == true { editing = false } } }.buttonStyle(.canopyPrimary)
                }
            }
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    ForEach((1...rack.units).reversed(), id: \.self) { u in
                        HStack(spacing: 4) {
                            Text("\(u)").font(.canopySans(9)).monospacedDigit().foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
                            if store.level.canEdit && !placed.contains(where: { u >= $0.rackUnit! && u < $0.rackUnit! + $0.rackHeight }) {
                                Menu {
                                    ForEach(candidates + unplaced) { d in
                                        Button(d.name) { Task { result = await store.placeInRack(d.id, rack: rack.id, unit: u, height: d.rackId == rack.id ? d.rackHeight : 1) } }
                                    }
                                } label: { Rectangle().fill(Color.clear).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle()) }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                                    .help("Put a device in U\(u)")
                            } else {
                                Spacer()
                            }
                        }
                        .frame(height: Self.unitHeight)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.canopyRule.opacity(0.5)).frame(height: 0.5) }
                    }
                }
                ForEach(placed) { d in
                    let top = CGFloat(rack.units - (d.rackUnit! + d.rackHeight - 1)) * Self.unitHeight
                    Menu {
                        Button("Open") { nav.open(d.id) }
                        if store.level.canEdit {
                            if d.rackUnit! + d.rackHeight - 1 < rack.units {
                                Button("Move up a unit") { Task { result = await store.placeInRack(d.id, rack: rack.id, unit: d.rackUnit! + 1, height: d.rackHeight) } }
                            }
                            if d.rackUnit! > 1 {
                                Button("Move down a unit") { Task { result = await store.placeInRack(d.id, rack: rack.id, unit: d.rackUnit! - 1, height: d.rackHeight) } }
                            }
                            Button("One unit taller") { Task { result = await store.placeInRack(d.id, rack: rack.id, unit: d.rackUnit!, height: d.rackHeight + 1) } }
                            if d.rackHeight > 1 {
                                Button("One unit shorter") { Task { result = await store.placeInRack(d.id, rack: rack.id, unit: d.rackUnit!, height: d.rackHeight - 1) } }
                            }
                            Divider()
                            Button("Take out of the rack") { Task { result = await store.removeFromRack(d.id) } }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: d.role?.symbol ?? "shippingbox").font(.system(size: 9))
                            Text(d.name).font(.canopySans(10, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(InventoryRules.rackSpan(unit: d.rackUnit, height: d.rackHeight)).font(.canopySans(9)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.canopySageTint, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.canopySage.opacity(0.6)))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(height: CGFloat(d.rackHeight) * Self.unitHeight - 2)
                    .padding(.leading, 22).padding(.trailing, 2)
                    .offset(y: top + 1)
                }
            }
            .frame(width: 220, height: CGFloat(rack.units) * Self.unitHeight, alignment: .top)
            .background(Color.canopyPaper, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.canopyRule))
            if !unplaced.isEmpty {
                Text("Unit not set: " + unplaced.map(\.name).joined(separator: ", ")).font(.canopyCaption).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
            }
        }
        .frame(width: 220)
        .confirmationDialog("Delete \(rack.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { result = await store.deleteRack(rack.id) } }
        } message: { Text("What's in it stays in the room, with no rack or unit.") }
    }
}

// MARK: - Configs

struct ConfigFilesView: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    @State private var query = ""
    @State private var result: (ok: Bool, message: String)?
    @State private var confirmDelete: EquipmentFile?

    var body: some View {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let files = store.files.filter { f in
            guard let d = store.byID[f.equipmentId], store.inScope(d) else { return false }
            return q.isEmpty || f.name.lowercased().contains(q) || d.name.lowercased().contains(q)
        }
        let byDevice = Dictionary(grouping: files, by: \.equipmentId).sorted { InventoryRules.ordered(store.byID[$0.key]?.name ?? "", store.byID[$1.key]?.name ?? "") }
        VStack(spacing: 0) {
            HStack {
                TextField("Search files and devices", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Spacer()
                Text("\(files.count) files · \(InventoryRules.size(files.map(\.size).reduce(0, +)))").font(.canopyCaption).foregroundStyle(.secondary)
            }
            .padding(.horizontal).padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Every scene, show file, router backup and receipt attached to your equipment. Add files from a device's page.")
                        .font(.canopyCaption).foregroundStyle(.secondary)
                    ResultLine(result: result)
                    if files.isEmpty { Text("No files yet.").foregroundStyle(.secondary) }
                    ForEach(byDevice, id: \.key) { id, list in
                        VStack(alignment: .leading, spacing: 6) {
                            if let d = store.byID[id] {
                                HStack {
                                    Button(d.name) { nav.open(d.id) }.buttonStyle(.plain).font(.canopyHeadline)
                                    Text([d.makeModel, d.ipAddress, store.place(d)].filter { !$0.isEmpty }.joined(separator: " · ")).font(.canopyCaption).foregroundStyle(.secondary)
                                }
                            }
                            ForEach(list) { f in FileRow(file: f, result: $result, confirmDelete: $confirmDelete) }
                        }
                        .canopyCard(padding: 12)
                    }
                }
                .padding()
            }
        }
        .confirmationDialog(confirmDelete.map { "Delete \($0.name)?" } ?? "",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let f = confirmDelete { Task { result = await store.deleteFile(f) } }; confirmDelete = nil }
        }
    }
}

// MARK: - Review
// What's left to fill in or double-check: devices without a type, cables between
// different signals, channels set to an odd signal for the category, warranties
// running out, and Canopy's own devices that aren't in the inventory yet.

struct InventoryReviewView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    @State private var result: (ok: Bool, message: String)?
    @State private var adding: IdentifiedDraft?
    @State private var addingLocal: LocalDevice?

    var body: some View {
        let devices = store.scoped
        let needsRole = devices.filter { $0.role == nil }.map { ($0, InventoryRules.suggestRole(name: $0.name, makeModel: $0.makeModel, category: $0.category)) }
        let mismatched = store.scopedPatches.filter { $0.from.port.signal != $0.to.port.signal }
        let odd = devices.filter { d in
            let own = d.ownPorts
            return !d.category.isEmpty && d.category != "Audio" && !own.isEmpty && own.allSatisfy { $0.signal != Signal.default(for: d.category) }
        }
        let warranty = devices.filter { InventoryRules.warrantyState($0.warrantyExpires) == .soon }
        let ids = Set(store.equipment.map(\.id))
        let localOnly = LocalDevice.all(appState).filter { $0.inventoryID.map { !ids.contains($0) } ?? true }

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ResultLine(result: result)
                if needsRole.isEmpty && mismatched.isEmpty && odd.isEmpty && warranty.isEmpty && localOnly.isEmpty {
                    Text("Nothing needs a second look.").foregroundStyle(.secondary).canopyCard()
                }
                if !needsRole.isEmpty {
                    section("Devices without a type · \(needsRole.count)", "The type decides what each channel is suggested to patch to.") {
                        let withGuess = needsRole.compactMap { d, g in g.map { (id: d.id, role: $0) } }
                        if !withGuess.isEmpty {
                            Button("Apply all \(withGuess.count) suggestions") { Task { result = await store.setRoles(withGuess) } }.buttonStyle(.canopySecondary)
                        }
                        ForEach(needsRole, id: \.0.id) { d, guess in
                            HStack {
                                Button(d.name) { nav.open(d.id) }.buttonStyle(.link)
                                Text(d.makeModel).font(.canopyCaption).foregroundStyle(.secondary)
                                Spacer()
                                Menu(guess.map { "Use \($0.label)" } ?? "Set type…") {
                                    ForEach(DeviceRole.allCases) { r in Button(r.label) { Task { result = await store.setRole(d.id, r) } } }
                                } primaryAction: {
                                    if let guess { Task { result = await store.setRole(d.id, guess) } }
                                }
                                .menuStyle(.button).fixedSize()
                            }
                        }
                    }
                }
                if !mismatched.isEmpty {
                    section("Cables between different signals · \(mismatched.count)", "Fine for a converter or a mislabeled channel; worth a look otherwise.") {
                        ForEach(mismatched) { p in
                            HStack(spacing: 4) {
                                Button(p.from.device.name) { nav.open(p.from.device.id) }.buttonStyle(.link)
                                Text("\(p.from.name) (\(p.from.port.signal.label)) →").foregroundStyle(.secondary)
                                Button(p.to.device.name) { nav.open(p.to.device.id) }.buttonStyle(.link)
                                Text("\(p.to.name) (\(p.to.port.signal.label))").foregroundStyle(.secondary)
                                Spacer()
                                Menu("Fix") {
                                    Button("Set \(p.to.name) to \(p.from.port.signal.label)") { Task { result = await store.updatePort(p.to.id, signal: p.from.port.signal) } }
                                    Button("Set \(p.from.name) to \(p.to.port.signal.label)") { Task { result = await store.updatePort(p.from.id, signal: p.to.port.signal) } }
                                }
                                .menuStyle(.button).fixedSize()
                            }
                            .font(.canopyCallout)
                        }
                    }
                }
                if !odd.isEmpty {
                    section("Unusual for the category · \(odd.count)", "Every channel on these carries something other than the category's usual signal.") {
                        ForEach(odd) { d in
                            let usual = Signal.default(for: d.category)
                            HStack {
                                Button(d.name) { nav.open(d.id) }.buttonStyle(.link)
                                Text("\(d.category) device, channels set to \(d.ownPorts.first?.signal.label ?? "")").font(.canopyCaption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Set to \(usual.label)") { Task { result = await store.setDeviceSignal(d.id, usual) } }.buttonStyle(.canopySecondary)
                            }
                        }
                    }
                }
                if !warranty.isEmpty {
                    section("Warranty ending soon · \(warranty.count)", "Within the next \(InventoryRules.warrantySoonDays) days.") {
                        ForEach(warranty) { d in
                            HStack {
                                Button(d.name) { nav.open(d.id) }.buttonStyle(.link)
                                Text("Until \(InventoryRules.formatDate(d.warrantyExpires))\(d.vendor.isEmpty ? "" : " · \(d.vendor)")").font(.canopyCaption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !localOnly.isEmpty {
                    section("In Canopy, not in the inventory · \(localOnly.count)", "Add them so they show up on the patch sheet, or link them from a device's page.") {
                        ForEach(localOnly) { d in
                            HStack {
                                Text(d.name).fontWeight(.medium)
                                Text("\(d.kindLabel) · \(d.address)").font(.canopyCaption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Add to inventory") {
                                    var draft = EquipmentDraft()
                                    draft.name = d.name; draft.makeModel = d.makeModel; draft.category = d.category; draft.ipAddress = d.address
                                    draft.role = d.category == "Video" ? .other : .computer
                                    let real = store.scope == InventoryRules.unassigned ? "" : store.scope
                                    draft.campus = real.isEmpty && store.campuses.count == 1 ? store.campuses[0].id : real
                                    addingLocal = d
                                    adding = IdentifiedDraft(draft: draft)
                                }
                                .buttonStyle(.canopySecondary)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .sheet(item: $adding) { d in
            EquipmentEditorSheet(title: "Add to inventory", draft: d.draft) { draft in
                let id = try await store.createEquipment(draft)
                if let local = addingLocal { LocalDevice.link(appState, record: id, to: local) }
                nav.open(id)
            }
        }
    }

    private func section<Content: View>(_ title: String, _ blurb: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.canopyTitle2).foregroundStyle(Color.canopyInk)
            Text(blurb).font(.canopyCaption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .canopyCard(padding: 14)
    }
}
