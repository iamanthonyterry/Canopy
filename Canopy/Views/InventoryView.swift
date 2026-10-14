import SwiftUI

// MARK: - Local device
// A HyperDeck or Cloud Store configured in Canopy, seen the same way for
// linking to an equipment record on the church site.
private enum LocalDevice: Identifiable, Hashable {
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
}

// MARK: - Inventory view

struct InventoryView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var account = SiteAccount.shared
    @ObservedObject private var store = InventoryStore.shared

    @State private var results: [String: (ok: Bool, text: String)] = [:]
    @State private var working: Set<String> = []
    @State private var pendingFile: (item: InventoryItem, file: InventoryItem.File)?
    @State private var sceneItem: InventoryItem?
    @State private var newDevice: NewDeviceRequest?
    @State private var showAdvanced = false

    private struct NewDeviceRequest: Identifiable {
        let id = UUID()
        var name = ""
        var makeModel = ""
        var category = "Video"
        var address = ""
        var linkTo: UUID?

        var asForm: NewInventoryDeviceSheet.Form {
            .init(name: name, makeModel: makeModel, category: category, address: address, linkTo: linkTo)
        }
    }

    private var locals: [LocalDevice] {
        appState.hyperDecks.map(LocalDevice.deck) + appState.cloudStores.map(LocalDevice.store)
    }
    private func linked(to item: InventoryItem) -> LocalDevice? {
        locals.first { $0.inventoryID == item.id }
    }
    /// Local devices with no live link to an inventory record.
    private var unlinked: [LocalDevice] {
        let ids = Set(store.items.map(\.id))
        return locals.filter { $0.inventoryID.map { !ids.contains($0) } ?? true }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if account.isConnected {
                    connectedBody
                } else {
                    signInCard
                }
            }
            .padding()
        }
        .background(Color.canopyPaper)
        .task(id: account.isConnected) {
            if account.isConnected { await store.refresh() } else { store.clear() }
        }
        .sheet(item: $newDevice) { request in
            NewInventoryDeviceSheet(request: request.asForm, localChoices: unlinked.map { ($0.id, "\($0.name) · \($0.kindLabel)") }) { form in
                await create(form)
            }
        }
        .sheet(item: $sceneItem) { item in
            SceneRecallSheet(item: item) { scene, channel in
                await recall(item, scene: scene, channel: channel)
            }
        }
        .confirmationDialog(
            pendingFile.map { "Apply “\($0.file.name)” to \($0.item.name)?" } ?? "",
            isPresented: Binding(get: { pendingFile != nil }, set: { if !$0 { pendingFile = nil } }),
            titleVisibility: .visible
        ) {
            Button("Apply") {
                if let p = pendingFile { Task { await apply(p.item, file: p.file) } }
                pendingFile = nil
            }
            Button("Cancel", role: .cancel) { pendingFile = nil }
        } message: {
            Text("This changes the labels and routing on the device right now.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Inventory").font(.canopyTitle).foregroundStyle(Color.canopyInk)
                if let campus = account.campusName, account.isConnected {
                    Text("\(campus) · from your church site").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if account.isConnected {
                if store.isLoading { ProgressView().controlSize(.small) }
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.canopySecondary)
                Button { newDevice = NewDeviceRequest() } label: { Label("Add device", systemImage: "plus") }
                    .buttonStyle(.canopyPrimary)
                Menu {
                    Button("Sign out of church site", role: .destructive) { account.signOut() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    // MARK: Signed out

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to your church site").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
            Text("Sign in to see your equipment inventory here, link your HyperDecks and Cloud Stores to it, add new devices, and apply saved configs to gear on this network.")
                .foregroundStyle(.secondary)
            HStack {
                Button { account.signIn() } label: {
                    Label(account.isConnecting ? "Waiting for the browser…" : "Sign in with website…", systemImage: "person.badge.key")
                }
                .buttonStyle(.canopyPrimary)
                .disabled(account.isConnecting)
                if account.isConnecting {
                    Button("Cancel") { account.cancelSignIn() }.buttonStyle(.canopySecondary)
                }
            }
            if let error = account.lastError {
                Text(error).font(.caption).foregroundStyle(Color.canopyRust)
            }
            DisclosureGroup("Site address", isExpanded: $showAdvanced) {
                TextField("https://", text: $account.baseURL).textFieldStyle(.roundedBorder)
                Text("Only change this if your church uses its own domain.").font(.caption).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .canopyCard()
    }

    // MARK: Signed in

    @ViewBuilder private var connectedBody: some View {
        if let error = store.error {
            Text(error).font(.callout).foregroundStyle(Color.canopyRust).canopyCard()
        }
        if store.loadedOnce && store.items.isEmpty {
            Text("No equipment is assigned to this campus yet. Add a device here or on the website.")
                .foregroundStyle(.secondary).canopyCard()
        }
        ForEach(store.items) { item in itemCard(item) }

        if !unlinked.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("In Canopy, not linked").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                ForEach(unlinked) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).fontWeight(.medium)
                            Text("\(device.kindLabel) · \(device.address)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add to inventory") {
                            newDevice = NewDeviceRequest(name: device.name, makeModel: device.makeModel, category: device.category, address: device.address, linkTo: device.id)
                        }.buttonStyle(.canopySecondary)
                    }
                    .canopyCard(padding: 12)
                }
            }
        }
    }

    private func itemCard(_ item: InventoryItem) -> some View {
        let local = linked(to: item)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.headline).foregroundStyle(Color.canopyInk)
                    Text([item.makeModel, item.host.isEmpty ? "No address saved" : item.host, item.location]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if working.contains(item.id) { ProgressView().controlSize(.small) }
                linkControl(item, local: local)
                applyControl(item)
            }
            if let local {
                Label("Linked to \(local.name) in Canopy", systemImage: "link")
                    .font(.caption).foregroundStyle(Color.canopySage)
            }
            if let r = results[item.id] {
                Text(r.text).font(.caption).foregroundStyle(r.ok ? Color.canopySage : Color.canopyRust)
            }
        }
        .canopyCard(padding: 12)
    }

    @ViewBuilder private func linkControl(_ item: InventoryItem, local: LocalDevice?) -> some View {
        if local != nil {
            Button("Unlink") { setLink(item: item, device: nil) }.buttonStyle(.canopySecondary)
        } else if !unlinked.isEmpty {
            Menu("Link to…") {
                ForEach(unlinked) { device in
                    Button("\(device.name) · \(device.kindLabel)") { setLink(item: item, device: device) }
                }
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }

    @ViewBuilder private func applyControl(_ item: InventoryItem) -> some View {
        if let driver = item.driver {
            if item.host.isEmpty {
                EmptyView()
            } else if driver.needs == "scene" {
                Button("Recall scene…") { sceneItem = item }.buttonStyle(.canopySecondary).disabled(working.contains(item.id))
            } else if item.files.isEmpty {
                Text("No config files").font(.caption).foregroundStyle(.secondary)
            } else {
                Menu("Apply config…") {
                    ForEach(item.files) { file in
                        Button(file.name) { pendingFile = (item, file) }
                    }
                }
                .menuStyle(.button).fixedSize().disabled(working.contains(item.id))
            }
        }
    }

    // MARK: Actions

    private func setLink(item: InventoryItem, device: LocalDevice?) {
        // One record per local device, and one local device per record.
        for d in appState.hyperDecks where d.inventoryID == item.id || (device.map { $0.id == d.id } ?? false) {
            var copy = d; copy.inventoryID = (device?.id == d.id) ? item.id : nil
            appState.updateDeck(copy)
        }
        for s in appState.cloudStores where s.inventoryID == item.id || (device.map { $0.id == s.id } ?? false) {
            var copy = s; copy.inventoryID = (device?.id == s.id) ? item.id : nil
            appState.updateCloudStore(copy)
        }
        // A record with no address picks up the one Canopy already knows.
        if let device, item.host.isEmpty, !device.address.isEmpty {
            Task {
                do {
                    try await InventoryClient.setAddress(id: item.id, address: device.address)
                    await store.refresh()
                    results[item.id] = (true, "Linked, and saved \(device.address) as its address.")
                } catch {
                    results[item.id] = (false, "Linked, but couldn't save the address: \(error.localizedDescription)")
                }
            }
        }
    }

    private func create(_ form: NewInventoryDeviceSheet.Form) async -> String? {
        do {
            let id = try await InventoryClient.create(name: form.name, makeModel: form.makeModel, category: form.category, address: form.address)
            if let local = form.linkTo {
                if let d = appState.hyperDecks.first(where: { $0.id == local }) { var c = d; c.inventoryID = id; appState.updateDeck(c) }
                if let s = appState.cloudStores.first(where: { $0.id == local }) { var c = s; c.inventoryID = id; appState.updateCloudStore(c) }
            }
            await store.refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func apply(_ item: InventoryItem, file: InventoryItem.File) async {
        working.insert(item.id); results[item.id] = nil
        defer { working.remove(item.id) }
        do {
            let payload = try await InventoryClient.file(equipmentID: item.id, fileID: file.id)
            guard isLocalAddress(payload.host) else {
                throw DeviceApplyError("\(payload.host) isn't on this network, so it was not contacted.")
            }
            guard payload.driver == "videohub", payload.port == 9990 else {
                throw DeviceApplyError("This version of Canopy doesn't know how to talk to that device.")
            }
            let message = try await Videohub.apply(host: payload.host, body: payload.body)
            results[item.id] = (true, "\(file.name): \(message)")
            appState.log("Inventory: applied \(file.name) to \(item.name)")
        } catch let e as DeviceApplyError {
            results[item.id] = (false, e.message)
        } catch {
            results[item.id] = (false, error.localizedDescription)
        }
    }

    private func recall(_ item: InventoryItem, scene: Int, channel: Int) async {
        working.insert(item.id); results[item.id] = nil
        defer { working.remove(item.id) }
        do {
            guard isLocalAddress(item.host) else { throw DeviceApplyError("\(item.host) isn't on this network, so it was not contacted.") }
            let message = try await AllenHeath.recallScene(host: item.host, scene: scene, channel: channel)
            results[item.id] = (true, message)
            appState.log("Inventory: recalled scene \(scene) on \(item.name)")
        } catch let e as DeviceApplyError {
            results[item.id] = (false, e.message)
        } catch {
            results[item.id] = (false, error.localizedDescription)
        }
    }
}

// MARK: - New device sheet

struct NewInventoryDeviceSheet: View {
    struct Form {
        var name = ""
        var makeModel = ""
        var category = "Video"
        var address = ""
        var linkTo: UUID?
    }

    @Environment(\.dismiss) private var dismiss
    @State private var form: Form
    let localChoices: [(UUID, String)]
    let onCreate: (Form) async -> String?

    @State private var saving = false
    @State private var error: String?

    private static let categories = ["Audio", "Video", "Lighting", "Network", "Computer", "Instrument", "Streaming", "Other"]

    init(request: Form, localChoices: [(UUID, String)], onCreate: @escaping (Form) async -> String?) {
        _form = State(initialValue: request)
        self.localChoices = localChoices
        self.onCreate = onCreate
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add to inventory").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { save() }
                    .buttonStyle(.canopyPrimary)
                    .disabled(form.name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Rectangle().fill(Color.canopyRule).frame(height: 1)
            formBody
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    private var formBody: some View {
        SwiftUI.Form {
            Section("Device") {
                LabeledContent("Name") { TextField("e.g. ISO 1", text: $form.name).textFieldStyle(.roundedBorder) }
                LabeledContent("Make / model") { TextField("e.g. Blackmagic HyperDeck Studio", text: $form.makeModel).textFieldStyle(.roundedBorder) }
                Picker("Category", selection: $form.category) {
                    ForEach(Self.categories, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Address") { TextField("192.168.x.x", text: $form.address).textFieldStyle(.roundedBorder) }
            }
            Section("Canopy") {
                Picker("Link to", selection: $form.linkTo) {
                    Text("Not linked").tag(UUID?.none)
                    ForEach(localChoices, id: \.0) { Text($0.1).tag(UUID?.some($0.0)) }
                }
                Text("It's added to this campus's inventory. Fill in the rest (value, serial, ports) on the website.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Color.canopyRust)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        saving = true; error = nil
        var trimmed = form
        trimmed.name = form.name.trimmingCharacters(in: .whitespaces)
        Task {
            let message = await onCreate(trimmed)
            saving = false
            if let message { error = message } else { dismiss() }
        }
    }
}

// MARK: - Scene recall sheet

struct SceneRecallSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: InventoryItem
    let onRecall: (Int, Int) async -> Void

    @State private var scene = 1
    @State private var channel = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recall a scene on \(item.name)").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
            Text("Recalls a scene already stored on the console. This changes the console right now.")
                .font(.callout).foregroundStyle(.secondary)
            Stepper("Scene \(scene)", value: $scene, in: 1...500)
            Stepper("MIDI channel \(channel)", value: $channel, in: 1...12)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Recall scene \(scene)") {
                    let s = scene, c = channel
                    dismiss()
                    Task { await onRecall(s, c) }
                }
                .buttonStyle(.canopyPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
