import SwiftUI
import Combine

// MARK: - Inventory
// The church's whole production system in one place: equipment and what it's
// worth, every channel and cable, how signal flows from a mic to a speaker, a
// map of how the devices connect, rooms and racks, config files, and a review of
// what still needs filling in. Everything is shared through the church's
// database, so every Mac (and the read-only patch sheet on the website) sees
// the same thing.

enum InventoryTab: String, CaseIterable, Identifiable {
    case equipment = "Devices"
    case list = "Full list"
    case patch = "Patch Sheet"
    case console = "Console Patch"
    case flow = "Signal Flow"
    case map = "System Map"
    case rooms = "Rooms & Racks"
    case configs = "Configs"
    case review = "Review"
    case importing = "Import"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .equipment: return "shippingbox"; case .list: return "tablecells"; case .patch: return "cable.connector"; case .console: return "slider.vertical.3"
        case .flow: return "arrow.triangle.branch"; case .map: return "point.3.connected.trianglepath.dotted"; case .rooms: return "square.stack.3d.up"
        case .configs: return "doc.badge.gearshape"; case .review: return "checklist"; case .importing: return "square.and.arrow.down"
        }
    }
}

/// The page's top level: nine screens grouped into five, so nothing is hidden but less is on show at once.
enum InventoryGroup: String, CaseIterable, Identifiable {
    case equipment = "Equipment", patching = "Patching", map = "System Map", places = "Rooms & Racks", tools = "Tools"
    var id: String { rawValue }
    var tabs: [InventoryTab] {
        switch self {
        case .equipment: return [.equipment, .list]
        case .patching: return [.patch, .console, .flow]
        case .map: return [.map]
        case .places: return [.rooms]
        case .tools: return [.review, .importing, .configs]
        }
    }
    var symbol: String { tabs[0].symbol }
    static func of(_ tab: InventoryTab) -> InventoryGroup { allCases.first { $0.tabs.contains(tab) } ?? .equipment }
}

/// Lets any inventory screen jump to a device's page.
@MainActor
final class InventoryNavigator: ObservableObject {
    @Published var tab: InventoryTab = .equipment
    @Published var selected: String?
    func open(_ id: String) { selected = id; tab = .equipment }
}

struct InventoryView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var account = SiteAccount.shared
    @ObservedObject private var store = InventoryStore.shared
    @StateObject private var nav = InventoryNavigator()
    @State private var showAdvanced = false
    @State private var adding: IdentifiedDraft?

    var body: some View {
        VStack(spacing: 0) {
            if account.isConnected {
                header
                Rectangle().fill(Color.canopyRule).frame(height: 1)
                connectedBody
            } else {
                ScrollView { signInCard.padding() }
            }
        }
        .background(Color.canopyPaper)
        .environmentObject(nav)
        .task(id: account.isConnected) {
            if account.isConnected { await store.refresh() } else { store.clear() }
        }
        .sheet(item: $adding) { d in
            EquipmentEditorSheet(title: "Add equipment", draft: d.draft) { draft in
                let id = try await store.createEquipment(draft)
                nav.open(id)
            }
        }
    }

    // MARK: Header

    private var tabs: [InventoryTab] {
        guard store.level.canViewDetails else { return [.patch, .console, .flow, .map] }
        return InventoryTab.allCases.filter { tab in
            switch tab {
            case .configs: return store.isAdmin
            case .review, .importing: return store.level.canEdit
            default: return true
            }
        }
    }

    private var groups: [InventoryGroup] { InventoryGroup.allCases.filter { !visible($0).isEmpty } }
    private func visible(_ g: InventoryGroup) -> [InventoryTab] { g.tabs.filter { tabs.contains($0) } }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inventory").font(.canopyTitle).foregroundStyle(Color.canopyInk)
                    Text(subtitle).font(.canopyCaption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                if store.campuses.count > 1 || store.hasUnassigned {
                    Picker("Campus", selection: $store.scope) {
                        Text("All campuses").tag("")
                        ForEach(store.campuses) { Text($0.name).tag($0.id) }
                        if store.hasUnassigned || store.scope == InventoryRules.unassigned {
                            Text("No campus yet").tag(InventoryRules.unassigned)
                        }
                    }
                    .pickerStyle(.menu).fixedSize()
                }
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.canopySecondary)
                    .keyboardShortcut("r", modifiers: .command)
                if store.level.canEdit {
                    Button { adding = IdentifiedDraft(draft: newDraft()) } label: { Label("Add equipment", systemImage: "plus") }
                        .buttonStyle(.canopyPrimary)
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                }
                Menu {
                    if let email = account.email { Text("Signed in as \(email)") }
                    Text("Access: \(store.level.label)")
                    Divider()
                    if let origin = account.origin {
                        Link("Open the patch sheet on the website", destination: origin.appendingPathComponent("inventory"))
                        Link("Open workflow progress on the website", destination: origin.appendingPathComponent("workflows"))
                        Link("Manage team access", destination: origin.appendingPathComponent("hub/team"))
                    }
                    Divider()
                    Button("Sign out", role: .destructive) { account.signOut() }
                } label: { Image(systemName: "person.crop.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 4) {
                ForEach(groups) { g in
                    let on = InventoryGroup.of(nav.tab) == g
                    Button { nav.tab = visible(g)[0] } label: {
                        Label(g.rawValue, systemImage: g.symbol)
                            .font(.canopySans(12, weight: on ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(on ? Color.canopySageTint : .clear, in: Capsule())
                            .foregroundStyle(on ? Color.canopyInk : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            let siblings = visible(InventoryGroup.of(nav.tab))
            if siblings.count > 1 {
                Picker("", selection: $nav.tab) {
                    ForEach(siblings) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        .padding(.horizontal).padding(.top).padding(.bottom, 10)
        .onChange(of: tabs) { if !tabs.contains(nav.tab), let first = tabs.first { nav.tab = first } }
    }

    private var subtitle: String {
        let devices = store.scoped.count
        var bits = [store.churchSlug, store.scopeName, "\(devices) \(devices == 1 ? "device" : "devices")", "\(store.scopedPatches.count) cables"]
        if store.level.canViewDetails, store.totalValue > 0 { bits.append("\(InventoryRules.money(store.totalValue)) value") }
        return bits.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func newDraft() -> EquipmentDraft {
        var d = EquipmentDraft()
        d.category = "Audio"
        let real = store.scope == InventoryRules.unassigned ? "" : store.scope
        d.campus = real.isEmpty && store.campuses.count == 1 ? store.campuses[0].id : real
        return d
    }

    // MARK: Body

    @ViewBuilder private var connectedBody: some View {
        if let error = store.error, !store.loadedOnce {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).foregroundStyle(Color.canopyRust)
                    Button("Try again") { Task { await store.refresh() } }.buttonStyle(.canopySecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).canopyCard().padding()
            }
        } else if !store.loadedOnce {
            ProgressView("Loading the inventory…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if let error = store.error {
                    Text(error).font(.canopyCaption).foregroundStyle(Color.canopyRust).padding(.horizontal).padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !store.level.canViewDetails {
                    Text("Your access is the patch sheet only, so device details, prices and logins are hidden. Ask an admin on the website's Team page for more.")
                        .font(.canopyCaption).foregroundStyle(.secondary).padding(.horizontal).padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                switch nav.tab {
                case .equipment: EquipmentBrowser()
                case .list: InventoryListView()
                case .patch: PatchSheetView()
                case .console: ConsolePatchView()
                case .flow: SignalFlowView()
                case .map: SystemMapView()
                case .rooms: RoomsRacksView()
                case .configs: ConfigFilesView()
                case .review: InventoryReviewView()
                case .importing: InventoryImportView()
                }
            }
        }
    }

    // MARK: Signed out

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your production inventory").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
            Text("Sign in with your church's website to manage every device, channel and cable in your production system: the patch sheet, signal flow, a map of how it all connects, rooms and racks, service history and config files. Your HyperDecks and Cloud Stores link to it, and saved configs can be applied to gear on this network.")
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
                Text(error).font(.canopyCaption).foregroundStyle(Color.canopyRust)
            }
            DisclosureGroup("Site address", isExpanded: $showAdvanced) {
                TextField("https://", text: $account.baseURL).textFieldStyle(.roundedBorder)
                Text("Only change this if your church uses its own domain.").font(.canopyCaption).foregroundStyle(.secondary)
            }
            .font(.canopyCaption)
        }
        .canopyCard()
    }
}

struct IdentifiedDraft: Identifiable {
    let id = UUID()
    var draft: EquipmentDraft
}

// MARK: - Shared pieces

/// The outcome of the last change, shown under the control that made it.
struct ResultLine: View {
    let result: (ok: Bool, message: String)?
    var body: some View {
        if let result {
            Text(result.message).font(.canopyCaption).foregroundStyle(result.ok ? Color.canopySage : Color.canopyRust)
        }
    }
}

struct SignalTag: View {
    let signal: Signal
    var body: some View {
        if signal.isTagged {
            Text(signal.label).font(.canopySans(10, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(signal.color.opacity(0.15), in: Capsule())
                .foregroundStyle(signal.color)
        }
    }
}

extension Signal {
    var color: Color {
        switch self {
        case .analog: return .gray; case .dante: return .red; case .madi: return .orange; case .aes50: return .purple
        case .gigaace: return .teal; case .soundgrid: return .indigo; case .avb: return .mint; case .usb: return .brown
        case .network: return .blue; case .video: return .green; case .dmx: return .yellow
        }
    }
}

extension EquipmentStatus {
    var color: Color {
        switch self { case .inService: return .canopySage; case .spare: return .blue; case .inRepair: return .canopyRust; case .loaned: return .orange; case .retired: return .gray }
    }
}

/// A plain text field that saves when you press Return or leave it, only if it changed.
struct CommitField: View {
    let placeholder: String
    let value: String
    var width: CGFloat? = nil
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .frame(width: width)
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value } }
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        if text != value { onCommit(text) }
    }
}

// MARK: - Scene recall sheet

struct SceneRecallSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let onRecall: (Int, Int) async -> Void

    @State private var scene = 1
    @State private var channel = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recall a scene on \(name)").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
            Text("Recalls a scene already stored on the console. This changes the console right now.")
                .font(.canopyCallout).foregroundStyle(.secondary)
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
