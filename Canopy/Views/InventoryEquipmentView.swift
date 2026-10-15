import SwiftUI
import AppKit

// MARK: - Equipment browser
// Every device in the campus, grouped the way you're looking for it, with the
// selected device's whole page beside the list.

struct EquipmentBrowser: View {
    @ObservedObject private var store = InventoryStore.shared
    @EnvironmentObject private var nav: InventoryNavigator
    @State private var query = ""
    @AppStorage("inventory.group") private var group: Grouping = .room
    @AppStorage("inventory.filter") private var filter: Filter = .all

    enum Grouping: String, CaseIterable, Identifiable {
        case name = "Name", room = "Room", rack = "Rack", type = "Type", category = "Category", status = "Status"
        var id: String { rawValue }
    }
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Everything", warranty = "Warranty ending or ended", noWarranty = "No warranty on file", needsType = "No type set", unplaced = "Not in a room"
        var id: String { rawValue }
    }

    private static let none = "Not set"

    private var shown: [Equipment] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.scoped.filter { e in
            switch filter {
            case .all: break
            case .warranty: guard [.soon, .expired].contains(InventoryRules.warrantyState(e.warrantyExpires)) else { return false }
            case .noWarranty: guard e.warrantyExpires == nil else { return false }
            case .needsType: guard e.role == nil else { return false }
            case .unplaced: guard e.roomId == nil else { return false }
            }
            guard !q.isEmpty else { return true }
            return [e.name, e.makeModel, e.serial, e.ipAddress, e.category, e.role?.label ?? "", store.place(e), e.notes]
                .contains { $0.lowercased().contains(q) }
        }
    }

    private var sections: [(title: String, items: [Equipment])] {
        let items = shown
        guard group != .name else { return [("", items)] }
        let key: (Equipment) -> String = { e in
            switch group {
            case .name: return ""
            case .room: return e.roomId.flatMap { store.roomsByID[$0]?.name } ?? Self.none
            case .rack: return e.rackId.flatMap { store.racksByID[$0]?.name } ?? Self.none
            case .type: return e.role?.label ?? Self.none
            case .category: return e.category.isEmpty ? Self.none : e.category
            case .status: return e.status.label
            }
        }
        let groups = Dictionary(grouping: items, by: key)
        return groups.keys.sorted { a, b in
            if a == Self.none { return false }
            if b == Self.none { return true }
            return InventoryRules.ordered(a, b)
        }.map { title in
            var list = groups[title] ?? []
            if group == .rack { list.sort { ($0.rackUnit ?? -1) > ($1.rackUnit ?? -1) } }  // top of the rack first
            return (title, list)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    TextField("Search name, model, room, IP…", text: $query).textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("Group", selection: $group) { ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) } }
                            .labelsHidden().fixedSize()
                        Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                            .labelsHidden().fixedSize()
                        Spacer()
                    }
                    .font(.canopyCaption)
                }
                .padding(10)
                List(selection: $nav.selected) {
                    ForEach(sections, id: \.title) { section in
                        Section(section.title.isEmpty ? "" : "\(section.title) · \(section.items.count)") {
                            ForEach(section.items) { e in EquipmentRow(e: e).tag(e.id) }
                        }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if shown.isEmpty {
                        Text(store.scoped.isEmpty ? "Nothing here yet. Add equipment, or import a patch sheet." : "No equipment matches.")
                            .foregroundStyle(.secondary).padding()
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

            Group {
                if let id = nav.selected, let e = store.byID[id] {
                    EquipmentDetailView(equipment: e).id(e.id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("Select a device to see its channels, cables and history.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct EquipmentRow: View {
    @ObservedObject private var store = InventoryStore.shared
    let e: Equipment
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: e.role?.symbol ?? "shippingbox").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).fontWeight(.medium).lineLimit(1)
                let c = InventoryRules.counts(e.ownPorts)
                Text([e.makeModel == e.name ? "" : e.makeModel, store.place(e), c.inputs + c.outputs > 0 ? "\(c.inputs) in · \(c.outputs) out" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.canopyCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if e.status != .inService { CanopyPill(label: e.status.label, color: e.status.color) }
            switch InventoryRules.warrantyState(e.warrantyExpires) {
            case .soon: Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange).help("Warranty ends soon")
            case .expired: Image(systemName: "clock.badge.xmark").foregroundStyle(.secondary).help("Warranty ended")
            default: EmptyView()
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Device page

struct EquipmentDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment

    @State private var editing: IdentifiedDraft?
    @State private var confirmDelete = false
    @State private var result: (ok: Bool, message: String)?
    @State private var showLogin = false

    private var e: Equipment { equipment }
    private var canEdit: Bool { store.level.canEdit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ResultLine(result: result)
                if store.level.canViewDetails { details }
                CanopyLinkSection(equipment: e)
                ChannelsSection(equipment: e)
                if e.cardSlots > 0 || !e.cards.isEmpty { CardSlotsSection(equipment: e) }
                StageLinkSection(equipment: e)
                if e.role == .console || !store.channels(of: e, .input).isEmpty || !store.channels(of: e, .output).isEmpty {
                    ConsoleChannelsSection(equipment: e)
                }
                if store.level.canViewDetails { ServiceLogSection(equipment: e) }
                if store.isAdmin { FilesSection(equipment: e) }
            }
            .padding()
        }
        .sheet(item: $editing) { d in
            EquipmentEditorSheet(title: "Edit \(e.name)", draft: d.draft, existing: e) { draft in
                let r = await store.updateEquipment(e.id, draft)
                if !r.ok { throw InventoryError(r.message) }
            }
        }
        .confirmationDialog("Delete \(e.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    let r = await store.deleteEquipment(e.id)
                    if r.ok { nav.selected = nil } else { result = r }
                }
            }
        } message: {
            Text("Its channels, cables, service log and files are deleted too. This can't be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: e.role?.symbol ?? "shippingbox").font(.title).foregroundStyle(Color.canopySage).frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.name).font(.canopyTitle).foregroundStyle(Color.canopyInk).textSelection(.enabled)
                Text([e.makeModel == e.name ? "" : e.makeModel, e.role?.label ?? "", store.place(e)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.canopyCallout).foregroundStyle(.secondary)
                let c = InventoryRules.counts(e.ports)
                Text("\(c.inputs) inputs · \(c.outputs) outputs · \(store.cables(of: e).count) cables")
                    .font(.canopyCaption).foregroundStyle(.secondary)
            }
            Spacer()
            if canEdit {
                Menu {
                    ForEach(EquipmentStatus.allCases) { s in
                        Button(s.label) { Task { result = await store.setStatus(e.id, s) } }
                    }
                } label: { CanopyPill(label: e.status.label, color: e.status.color) }
                    .menuStyle(.borderlessButton).fixedSize()
                Button("Edit") { editing = IdentifiedDraft(draft: EquipmentDraft(e)) }.buttonStyle(.canopySecondary)
                Menu {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            } else {
                CanopyPill(label: e.status.label, color: e.status.color)
            }
        }
    }

    private var details: some View {
        let warranty = InventoryRules.warrantyState(e.warrantyExpires)
        return VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                fact("Campus", store.campusName(e.campus), "Category", e.category)
                fact("Serial", e.serial, "Condition", e.condition?.label ?? "")
                fact("Value", e.value.map { InventoryRules.money($0) } ?? "", "Paid", e.purchasePrice.map { InventoryRules.money($0) } ?? "")
                fact("Purchased", e.purchaseDate.map { InventoryRules.formatDate($0) } ?? e.yearPurchased.map(String.init) ?? "", "From", e.vendor)
                GridRow {
                    label("Warranty")
                    Text(warranty == .none ? "—" : "\(warranty == .expired ? "Ended" : "Until") \(InventoryRules.formatDate(e.warrantyExpires))\(e.warrantyTerms.isEmpty ? "" : " · \(e.warrantyTerms)")")
                        .foregroundStyle(warranty == .soon ? .orange : warranty == .expired ? .secondary : Color.canopyInk)
                        .gridCellColumns(3)
                }
                GridRow {
                    label("Address")
                    HStack(spacing: 6) {
                        Text(e.ipAddress.isEmpty ? "—" : e.ipAddress).textSelection(.enabled)
                        if let host = e.host, let url = URL(string: "http://\(host)") {
                            Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("Open its web page")
                        }
                    }
                    label("Login")
                    if e.username.isEmpty && e.password.isEmpty {
                        Text("—")
                    } else if showLogin {
                        Text("\(e.username) / \(e.password)").textSelection(.enabled)
                    } else {
                        Button("Show") { showLogin = true }.buttonStyle(.link)
                    }
                }
            }
            .font(.canopyCallout)
            if !e.notes.isEmpty {
                Text(e.notes).font(.canopyCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(Color.canopyPaper, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .canopyCard(padding: 14)
    }

    private func label(_ s: String) -> some View { Text(s).foregroundStyle(.secondary) }

    private func fact(_ a: String, _ av: String, _ b: String, _ bv: String) -> some View {
        GridRow {
            label(a); Text(av.isEmpty ? "—" : av).textSelection(.enabled)
            label(b); Text(bv.isEmpty ? "—" : bv).textSelection(.enabled)
        }
    }
}

// MARK: - Canopy devices and apply-to-device

/// A HyperDeck or Cloud Store configured in Canopy, seen the same way for linking to an equipment record.
enum LocalDevice: Identifiable, Hashable {
    case deck(HyperDeck)
    case store(CloudStore)

    var id: UUID {
        switch self { case .deck(let d): return d.id; case .store(let s): return s.id }
    }
    var name: String {
        switch self { case .deck(let d): return d.name; case .store(let s): return s.name }
    }
    var address: String {
        switch self { case .deck(let d): return d.ipAddress; case .store(let s): return s.ipAddress }
    }
    var inventoryID: String? {
        switch self { case .deck(let d): return d.inventoryID; case .store(let s): return s.inventoryID }
    }
    var kindLabel: String {
        switch self { case .deck: return "HyperDeck"; case .store(let s): return s.kind.displayName }
    }
    var makeModel: String {
        switch self {
        case .deck: return "Blackmagic HyperDeck"
        case .store(let s): return s.kind == .synologyNAS ? "Synology NAS" : "Blackmagic Cloud Store"
        }
    }
    var category: String {
        switch self { case .deck: return "Video"; case .store: return "Computer" }
    }

    static func all(_ appState: AppState) -> [LocalDevice] {
        appState.hyperDecks.map(LocalDevice.deck) + appState.cloudStores.map(LocalDevice.store)
    }

    /// One record per local device, and one local device per record.
    static func link(_ appState: AppState, record: String, to device: LocalDevice?) {
        for d in appState.hyperDecks where d.inventoryID == record || device?.id == d.id {
            var copy = d; copy.inventoryID = device?.id == d.id ? record : nil
            appState.updateDeck(copy)
        }
        for s in appState.cloudStores where s.inventoryID == record || device?.id == s.id {
            var copy = s; copy.inventoryID = device?.id == s.id ? record : nil
            appState.updateCloudStore(copy)
        }
    }
}

struct CanopyLinkSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    @State private var result: (ok: Bool, message: String)?
    @State private var working = false
    @State private var pendingFile: EquipmentFile?
    @State private var recalling = false

    private var e: Equipment { equipment }
    private var locals: [LocalDevice] { LocalDevice.all(appState) }
    private var linked: LocalDevice? { locals.first { $0.inventoryID == e.id } }
    private var unlinked: [LocalDevice] {
        let ids = Set(store.equipment.map(\.id))
        return locals.filter { $0.inventoryID.map { !ids.contains($0) } ?? true }
    }
    private var driver: DeviceDriver? { DeviceDriver.detect(name: e.name, makeModel: e.makeModel) }

    var body: some View {
        if linked != nil || !unlinked.isEmpty || driver != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("In Canopy").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                }
                HStack {
                    if let linked {
                        Label("Linked to \(linked.name) (\(linked.kindLabel))", systemImage: "link").foregroundStyle(Color.canopySage)
                        Spacer()
                        Button("Unlink") { LocalDevice.link(appState, record: e.id, to: nil) }.buttonStyle(.canopySecondary)
                    } else if !unlinked.isEmpty {
                        Text("Not linked to a device in Canopy.").foregroundStyle(.secondary)
                        Spacer()
                        Menu("Link to…") {
                            ForEach(unlinked) { d in Button("\(d.name) · \(d.kindLabel)") { link(d) } }
                        }
                        .menuStyle(.button).fixedSize()
                    }
                }
                if let driver {
                    applyRow(driver)
                }
                ResultLine(result: result)
            }
            .canopyCard(padding: 14)
            .sheet(isPresented: $recalling) {
                SceneRecallSheet(name: e.name) { scene, channel in await recall(scene: scene, channel: channel) }
            }
            .confirmationDialog(pendingFile.map { "Apply “\($0.name)” to \(e.name)?" } ?? "",
                                isPresented: Binding(get: { pendingFile != nil }, set: { if !$0 { pendingFile = nil } }), titleVisibility: .visible) {
                Button("Apply") { if let f = pendingFile { Task { await apply(f) } }; pendingFile = nil }
                Button("Cancel", role: .cancel) { pendingFile = nil }
            } message: {
                Text("This changes the labels and routing on the device right now.")
            }
        }
    }

    @ViewBuilder private func applyRow(_ driver: DeviceDriver) -> some View {
        HStack {
            Text(driver.label).font(.canopyCallout).foregroundStyle(.secondary)
            Spacer()
            if e.host == nil {
                Text("Add its IP address to apply configs.").font(.canopyCaption).foregroundStyle(.secondary)
            } else if driver == .ahScene {
                Button("Recall scene…") { recalling = true }.buttonStyle(.canopySecondary).disabled(working)
            } else if !store.isAdmin {
                Text("Owners and admins can apply configs.").font(.canopyCaption).foregroundStyle(.secondary)
            } else if store.files(of: e).isEmpty {
                Text("Attach a Videohub config file below to apply it.").font(.canopyCaption).foregroundStyle(.secondary)
            } else {
                Menu("Apply config…") {
                    ForEach(store.files(of: e)) { f in Button(f.name) { pendingFile = f } }
                }
                .menuStyle(.button).fixedSize().disabled(working)
            }
        }
    }

    private func link(_ d: LocalDevice) {
        LocalDevice.link(appState, record: e.id, to: d)
        // A record with no address picks up the one Canopy already knows.
        if e.ipAddress.isEmpty, !d.address.isEmpty, store.level.canEdit {
            Task {
                let r = await store.setAddress(e.id, d.address)
                result = r.ok ? (true, "Linked, and saved \(d.address) as its address.") : (false, "Linked, but couldn't save the address: \(r.message)")
            }
        }
    }

    private func apply(_ file: EquipmentFile) async {
        working = true; result = nil
        defer { working = false }
        do {
            guard let host = e.host, isLocalAddress(host) else { throw DeviceApplyError("\(e.ipAddress) isn't on this network, so it was not contacted.") }
            guard file.size <= 200_000 else { throw DeviceApplyError("That file is too large to be a Videohub config.") }
            let body = String(decoding: try await store.downloadFile(file), as: UTF8.self)
            let message = try await Videohub.apply(host: host, body: body)
            result = (true, "\(file.name): \(message)")
            appState.log("Inventory: applied \(file.name) to \(e.name)")
        } catch let err as DeviceApplyError {
            result = (false, err.message)
        } catch {
            result = (false, error.localizedDescription)
        }
    }

    private func recall(scene: Int, channel: Int) async {
        working = true; result = nil
        defer { working = false }
        do {
            guard let host = e.host, isLocalAddress(host) else { throw DeviceApplyError("\(e.ipAddress) isn't on this network, so it was not contacted.") }
            result = (true, try await AllenHeath.recallScene(host: host, scene: scene, channel: channel))
            appState.log("Inventory: recalled scene \(scene) on \(e.name)")
        } catch let err as DeviceApplyError {
            result = (false, err.message)
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}
