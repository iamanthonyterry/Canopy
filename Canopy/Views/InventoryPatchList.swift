import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Patch sheet
// An interactive patch list for every device, the way a console's patch screen reads: inputs on the left with
// where each comes from, outputs on the right with where each goes. Names, sources and destinations are all
// edited right in the row, and each change is saved to the church's inventory as it's made.

/// What's on the other end of a channel: a cable, a stage box link, or a console channel patched to the socket.
struct PatchPeer: Identifiable {
    enum Via { case cable(Cable), link, console }
    var id: String
    var device: Equipment
    var portID: String?
    var name: String
    var via: Via
    var warning: String

    var cable: Cable? { if case .cable(let c) = via { return c }; return nil }
    var viaLabel: String {
        switch via { case .cable: return "Cable"; case .link: return "Stage box link"; case .console: return "Console patch" }
    }
}

extension InventoryStore {
    /// Every channel's far ends, keyed by the channel's id. Cables can be changed from the sheet; links and a
    /// console's internal patch are shown as they are.
    func patchPeers() -> [String: [PatchPeer]] {
        var out: [String: [PatchPeer]] = [:]
        for c in cables {
            guard let a = port(c.fromPort), let b = port(c.toPort) else { continue }
            func peer(_ mine: (Equipment, EquipmentPort), _ other: (Equipment, EquipmentPort)) -> PatchPeer {
                let fit = InventoryRules.peerFit(mineRole: mine.0.role, direction: mine.1.direction, signal: mine.1.signal, otherRole: other.0.role, otherSignal: other.1.signal)
                return PatchPeer(id: "c-\(c.id)-\(mine.1.id)", device: other.0, portID: other.1.id, name: other.0.portName(other.1), via: .cable(c), warning: fit.warning)
            }
            out[a.1.id, default: []].append(peer(a, b))
            out[b.1.id, default: []].append(peer(b, a))
        }
        for h in hops {
            out[h.from.id, default: []].append(PatchPeer(id: "h-\(h.from.id)>\(h.to.id)-t", device: h.to.device, portID: h.to.id, name: h.to.name, via: .link, warning: ""))
            out[h.to.id, default: []].append(PatchPeer(id: "h-\(h.from.id)>\(h.to.id)-f", device: h.from.device, portID: h.from.id, name: h.from.name, via: .link, warning: ""))
        }
        let channelByID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for p in consolePatch {
            guard let ch = channelByID[p.channelId], let console = byID[ch.equipmentId] else { continue }
            out[p.portId, default: []].append(PatchPeer(id: "p-\(p.id)", device: console, portID: nil, name: ch.title, via: .console, warning: ""))
        }
        return out
    }
}

/// One group of a device's channels in the picker above a column: its own sockets, or one option card.
private struct PortGroup: Identifiable {
    var id: String
    var title: String
    var ports: [EquipmentPort]
}

struct PatchSheetView: View {
    @ObservedObject private var store = InventoryStore.shared
    @State private var query = ""
    @State private var onlyUnpatched = false
    @State private var expanded: Set<String> = []
    @State private var seeded = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let peers = store.patchPeers()
        let devices = store.scoped.filter { !$0.ports.isEmpty }
        let ports = devices.flatMap(\.ports)
        let patched = ports.filter { peers[$0.id] != nil }.count
        let shown = devices.filter { d in
            (!onlyUnpatched || d.ports.contains { peers[$0.id] == nil })
                && (q.isEmpty || PatchMatch.device(d, q, peers, place: store.place(d)))
        }
        let bare = store.scoped.count - devices.count

        VStack(spacing: 0) {
            HStack {
                TextField("Device, channel, connector, cable…", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Toggle("Not patched only", isOn: $onlyUnpatched).toggleStyle(.checkbox)
                Spacer()
                Button("Expand all") { expanded = Set(shown.map(\.id)) }.buttonStyle(.canopySecondary)
                Button("Collapse all") { expanded = [] }.buttonStyle(.canopySecondary)
                Button { export() } label: { Label("Export CSV…", systemImage: "square.and.arrow.up") }.buttonStyle(.canopySecondary)
            }
            .padding(.horizontal).padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("\(patched) of \(ports.count) channels patched across \(devices.count) \(devices.count == 1 ? "device" : "devices")." + (bare > 0 ? " \(bare) with no channels yet." : ""))
                        .font(.canopyCallout).foregroundStyle(.secondary)
                    ResultLine(result: result)
                    if devices.isEmpty {
                        Text(store.level.canEdit ? "No device has channels yet. Open a device to add its inputs and outputs, or import a spreadsheet." : "Nothing is patched yet.")
                            .foregroundStyle(.secondary)
                    } else if shown.isEmpty {
                        Text("No devices match.").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { d in
                        DevicePatchCard(equipment: d, peers: peers, query: q,
                                        open: Binding(get: { expanded.contains(d.id) || !q.isEmpty },
                                                      set: { if $0 { expanded.insert(d.id) } else { expanded.remove(d.id) } }),
                                        result: $result)
                    }
                }
                .padding()
            }
        }
        .onAppear(perform: seed)
        .onChange(of: store.scoped.count) { seed() }
    }

    /// A small system opens fully; a big one starts folded so it isn't hundreds of rows.
    private func seed() {
        guard !seeded else { return }
        let devices = store.scoped.filter { !$0.ports.isEmpty }
        guard !devices.isEmpty else { return }
        seeded = true
        if devices.count <= 3 { expanded = Set(devices.map(\.id)) }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Patch sheet - \(store.scopeName).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PatchImport.export(store.scopedPatches).write(to: url, atomically: true, encoding: .utf8)
            result = (true, "Saved \(url.lastPathComponent). Edit it in a spreadsheet and bring it back with Import.")
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}

private enum PatchMatch {
    static func port(_ p: EquipmentPort, _ d: Equipment, _ q: String, _ peers: [String: [PatchPeer]]) -> Bool {
        [p.label, p.kind, d.portName(p)].contains { $0.lowercased().contains(q) }
            || (peers[p.id] ?? []).contains { $0.device.name.lowercased().contains(q) || $0.name.lowercased().contains(q) || $0.cable?.note.lowercased().contains(q) == true }
    }
    static func device(_ d: Equipment, _ q: String, _ peers: [String: [PatchPeer]], place: String) -> Bool {
        [d.name, d.makeModel, place].contains { $0.lowercased().contains(q) } || d.ports.contains { port($0, d, q, peers) }
    }
}

// MARK: - One device

private struct DevicePatchCard: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    let peers: [String: [PatchPeer]]
    let query: String
    @Binding var open: Bool
    @Binding var result: (ok: Bool, message: String)?
    @State private var inGroup = ""
    @State private var outGroup = ""
    @State private var selection: Set<String> = []

    private var e: Equipment { equipment }
    private var canEdit: Bool { store.level.canEdit }

    private func groups(_ dir: PortDirection) -> [PortGroup] {
        var out: [PortGroup] = []
        let own = e.ownPorts.filter { $0.direction == dir }
        if !own.isEmpty { out.append(PortGroup(id: "", title: "Built-in", ports: own)) }
        for card in e.cards {
            let list = e.ports.filter { $0.cardId == card.id && $0.direction == dir }
            if !list.isEmpty { out.append(PortGroup(id: card.id, title: card.label, ports: list)) }
        }
        return out
    }
    private func current(_ groups: [PortGroup], _ id: String) -> PortGroup? { groups.first { $0.id == id } ?? groups.first }

    var body: some View {
        let ins = groups(.input), outs = groups(.output)
        let inList = current(ins, inGroup)?.ports ?? [], outList = current(outs, outGroup)?.ports ?? []
        let both = e.ports.filter { $0.direction == .both }
        let everyDeviceRow = query.isEmpty || [e.name, e.makeModel].contains { $0.lowercased().contains(query) }
        let pairs: [(input: EquipmentPort?, output: EquipmentPort?)] = (0..<max(inList.count, outList.count)).map { i in
            (i < inList.count ? inList[i] : nil, i < outList.count ? outList[i] : nil)
        }.filter { pair in
            everyDeviceRow || [pair.input, pair.output].contains { $0.map { PatchMatch.port($0, e, query, peers) } ?? false }
        }
        let bothShown = both.filter { everyDeviceRow || PatchMatch.port($0, e, query, peers) }
        let patched = e.ports.filter { peers[$0.id] != nil }.count

        VStack(alignment: .leading, spacing: 0) {
            header(patched: patched)
            if open {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    columnHeader(ins: ins, outs: outs, inList: inList, outList: outList)
                    Divider().opacity(0.5)
                    if pairs.isEmpty && bothShown.isEmpty {
                        Text(e.ports.isEmpty ? "No channels yet." : "No channels match.").foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                        HStack(spacing: 0) {
                            half(pair.input, side: .input).frame(maxWidth: .infinity)
                            Divider()
                            half(pair.output, side: .output).frame(maxWidth: .infinity)
                        }
                        Divider().opacity(0.3)
                    }
                    if !bothShown.isEmpty {
                        Text("In / out").font(.canopyCaption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                        ForEach(bothShown) { p in
                            half(p, side: .input)
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
        .canopyCard(padding: 0)
    }

    // MARK: Header

    private func header(patched: Int) -> some View {
        let selectedCables = Set(selection.flatMap { peers[$0] ?? [] }.compactMap { $0.cable?.id })
        return HStack(spacing: 8) {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(.canopyCaption).foregroundStyle(.secondary).frame(width: 14)
            Image(systemName: e.role?.symbol ?? "shippingbox").foregroundStyle(Color.canopySage)
            Button(e.name) { nav.open(e.id) }.buttonStyle(.plain).font(.canopyHeadline).foregroundStyle(Color.canopyInk)
            Text([e.makeModel == e.name ? "" : e.makeModel, store.place(e)].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.canopyCaption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if canEdit, !selectedCables.isEmpty {
                Button("Disconnect \(selectedCables.count)") {
                    let ids = Array(selectedCables)
                    selection = []
                    Task { result = await store.disconnect(all: ids) }
                }
                .buttonStyle(.canopySecondary)
            }
            Text("\(patched) of \(e.ports.count) patched").font(.canopyCaption).foregroundStyle(.secondary)
            if canEdit {
                Menu("Add channel…") {
                    Button("Input") { Task { result = await store.addPort(e.id, direction: .input) } }
                    Button("Output") { Task { result = await store.addPort(e.id, direction: .output) } }
                    Button("In / out") { Task { result = await store.addPort(e.id, direction: .both) } }
                    ForEach(e.cards) { card in
                        Divider()
                        Button("\(card.label) · input") { Task { result = await store.addPort(e.id, direction: .input, cardID: card.id) } }
                        Button("\(card.label) · output") { Task { result = await store.addPort(e.id, direction: .output, cardID: card.id) } }
                    }
                }
                .menuStyle(.button).fixedSize().font(.canopyCaption)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { if query.isEmpty { open.toggle() } }
    }

    // MARK: Columns

    private func columnHeader(ins: [PortGroup], outs: [PortGroup], inList: [EquipmentPort], outList: [EquipmentPort]) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                selectAll(inList)
                Text("From device").frame(minWidth: 80, maxWidth: 140, alignment: .leading)
                Text("Channel").frame(minWidth: 80, maxWidth: 140, alignment: .leading)
                groupPicker(ins, selection: $inGroup, label: "Inputs")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity)
            Divider()
            HStack(spacing: 6) {
                selectAll(outList)
                groupPicker(outs, selection: $outGroup, label: "Outputs")
                Spacer(minLength: 0)
                Text("To channel").frame(minWidth: 80, maxWidth: 140, alignment: .leading)
                Text("To device").frame(minWidth: 80, maxWidth: 140, alignment: .leading)
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity)
        }
        .font(.canopyCaption2).foregroundStyle(.secondary)
        .frame(height: 30)
    }

    @ViewBuilder private func selectAll(_ list: [EquipmentPort]) -> some View {
        if canEdit {
            Toggle("", isOn: Binding(
                get: { !list.isEmpty && list.allSatisfy { selection.contains($0.id) } },
                set: { on in if on { selection.formUnion(list.map(\.id)) } else { selection.subtract(list.map(\.id)) } }))
                .toggleStyle(.checkbox).labelsHidden().help("Select every channel shown")
        }
    }

    @ViewBuilder private func groupPicker(_ groups: [PortGroup], selection: Binding<String>, label: String) -> some View {
        if groups.count > 1 {
            Picker("", selection: Binding(get: { current(groups, selection.wrappedValue)?.id ?? "" }, set: { selection.wrappedValue = $0 })) {
                ForEach(groups) { Text($0.title).tag($0.id) }
            }
            .labelsHidden().fixedSize()
        } else {
            Text(groups.first.map { "\($0.title) \(label.lowercased())" } ?? label)
        }
    }

    // MARK: Rows

    private enum Side { case input, output }

    @ViewBuilder private func half(_ port: EquipmentPort?, side: Side) -> some View {
        if let port {
            let list = peers[port.id] ?? []
            HStack(spacing: 6) {
                if canEdit {
                    Toggle("", isOn: Binding(get: { selection.contains(port.id) },
                                             set: { if $0 { selection.insert(port.id) } else { selection.remove(port.id) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                }
                if side == .input {
                    PeerDeviceButton(equipment: e, port: port, peers: list, result: $result)
                    PeerPortButton(equipment: e, port: port, peers: list, result: $result)
                    channel(port, peers: list)
                } else {
                    channel(port, peers: list)
                    PeerPortButton(equipment: e, port: port, peers: list, result: $result)
                    PeerDeviceButton(equipment: e, port: port, peers: list, result: $result)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 3)
            .font(.canopyCallout)
        } else {
            Color.clear.frame(height: 30)
        }
    }

    private func channel(_ port: EquipmentPort, peers list: [PatchPeer]) -> some View {
        let warning = list.first { !$0.warning.isEmpty }?.warning ?? ""
        return HStack(spacing: 6) {
            Text(port.number.map(String.init) ?? "–").font(.canopyMono(11)).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
            Group {
                if list.isEmpty { Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5) }
                else { Circle().fill(warning.isEmpty ? Color.canopySage : Color.orange) }
            }
            .frame(width: 9, height: 9)
            .help(list.isEmpty ? "Not patched" : warning.isEmpty ? "Patched" : warning)
            if canEdit {
                CommitField(placeholder: "\(port.direction == .output ? "Output" : port.direction == .input ? "Input" : "Port") \(port.number ?? 0)", value: port.label) { v in
                    Task { result = await store.updatePort(port.id, label: v) }
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color.canopyPaperElevated, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.canopyRule))
                .frame(minWidth: 70)
            } else {
                Text(port.label.isEmpty ? port.name() : port.label).lineLimit(1).frame(minWidth: 70, alignment: .leading)
            }
        }
        .layoutPriority(1)
    }
}

// MARK: - Pickers

/// The dropdown look shared by the device and channel pickers.
private struct PickerLabel: View {
    let text: String
    var placeholder = false
    var badge = 0
    var icon: String?
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.canopyCaption).foregroundStyle(Color.canopySage) }
            Text(text).lineLimit(1).foregroundStyle(placeholder ? Color.secondary : Color.canopyInk)
            Spacer(minLength: 0)
            if badge > 0 {
                Text("+\(badge)").font(.canopyCaption2).padding(.horizontal, 4).background(Color.canopySage.opacity(0.18), in: Capsule())
            }
            Image(systemName: "chevron.up.chevron.down").font(.canopyCaption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .frame(minWidth: 80, maxWidth: 140)
        .background(Color.canopyPaperElevated, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.canopyRule))
        .contentShape(Rectangle())
    }
}

/// Who's on the other end of a channel. Pick a device to patch it to its first free matching channel; the channel
/// beside it then moves it to another. Each list is built when it opens, so a long page stays quick.
private struct PeerDeviceButton: View {
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    let port: EquipmentPort
    let peers: [PatchPeer]
    @Binding var result: (ok: Bool, message: String)?
    @State private var showing = false

    private var primary: PatchPeer? { peers.first }
    private var editable: Bool { store.level.canEdit && (primary == nil || primary?.cable != nil) }

    var body: some View {
        let label = PickerLabel(text: primary?.device.name ?? (store.level.canEdit ? "Patch…" : "—"), placeholder: primary == nil,
                                badge: max(0, peers.count - 1), icon: primary.flatMap { $0.cable == nil ? "link" : nil })
        if editable {
            Button { showing = true } label: { label }
                .buttonStyle(.plain)
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    DevicePickerList(equipment: equipment, port: port, peers: peers) { r in
                        if let r { result = r }
                        showing = false
                    }
                }
        } else {
            label.help(primary.map { "\($0.viaLabel) · changed from the device's own page" } ?? "")
        }
    }
}

private struct DevicePickerList: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    let port: EquipmentPort
    let peers: [PatchPeer]
    let done: ((ok: Bool, message: String)?) -> Void
    @State private var query = ""
    @State private var picking = false

    private var fansOut: Bool { port.direction == .both || (port.direction == .output && port.signal.fansOut) }

    var body: some View {
        let byDevice = Dictionary(grouping: store.candidates(for: port, on: equipment), by: \.device.id)
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let ranked = byDevice.values.map { (device: $0[0].device, rank: $0.map(\.rank).min() ?? 0) }
            .filter { q.isEmpty || $0.device.name.lowercased().contains(q) }
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : InventoryRules.ordered($0.device.name, $1.device.name) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Patch \(equipment.portName(port))").font(.canopyHeadline)
            if peers.count > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Now connected to").font(.canopyCaption).foregroundStyle(.secondary)
                    ForEach(peers) { p in
                        HStack(spacing: 4) {
                            Text("\(p.device.name) · \(p.name)").lineLimit(1)
                            Spacer()
                            if let c = p.cable {
                                Button { Task { done(await store.disconnect(c.id)) } } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless).help("Disconnect")
                            } else { Text(p.viaLabel).font(.canopyCaption).foregroundStyle(.secondary) }
                        }
                        .font(.canopyCallout)
                    }
                }
                Divider()
            }
            TextField("Search devices", text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach(ranked, id: \.device.id) { r in
                    Button { choose(r.device, in: byDevice[r.device.id] ?? []) } label: {
                        HStack {
                            Image(systemName: r.device.role?.symbol ?? "shippingbox").foregroundStyle(.secondary)
                            Text(r.device.name).lineLimit(1)
                            Spacer()
                            if r.rank < 25 { Image(systemName: "star.fill").font(.canopyCaption2).foregroundStyle(Color.canopySage).help("Usual for this channel") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 260, height: 240)
            if ranked.isEmpty { Text("No other devices in this campus have a matching channel.").font(.canopyCaption).foregroundStyle(.secondary) }
            HStack {
                if let c = peers.first?.cable {
                    Button("Disconnect", role: .destructive) { Task { done(await store.disconnect(c.id)) } }.buttonStyle(.canopySecondary)
                }
                if fansOut, !peers.isEmpty {
                    Button("Patch another…") { picking = true }.buttonStyle(.canopySecondary)
                }
                Spacer()
                if let d = peers.first?.device { Button("Open \(d.name)") { nav.open(d.id); done(nil) }.buttonStyle(.link) }
            }
        }
        .padding()
        .popover(isPresented: $picking, arrowEdge: .trailing) {
            PatchPicker(equipment: equipment, port: port, replacing: nil) { r in picking = false; done(r) }
        }
    }

    /// Lands on the device's first channel that isn't already taken, or its first one when every one is.
    private func choose(_ device: Equipment, in list: [InventoryStore.Candidate]) {
        let sorted = list.sorted { InventoryRules.byPort($0.port, $1.port) }
        let free = sorted.first { c in
            let cabled = !store.cable(at: c.port.id).isEmpty
            return !(cabled && (c.port.direction == .input || (c.port.direction == .output && !c.port.signal.fansOut)))
        }
        guard let pick = free ?? sorted.first else { return }
        Task { done(await store.patch(port.id, to: pick.port.id, replacing: peers.first?.cable?.id)) }
    }
}

/// The channel on the other device this one is patched to; opens a searchable list of that device's channels.
private struct PeerPortButton: View {
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    let port: EquipmentPort
    let peers: [PatchPeer]
    @Binding var result: (ok: Bool, message: String)?
    @State private var showing = false

    private var primary: PatchPeer? { peers.first }

    var body: some View {
        let label = PickerLabel(text: primary?.name ?? "—", placeholder: primary == nil)
        if store.level.canEdit, let primary, let cable = primary.cable {
            Button { showing = true } label: { label }
                .buttonStyle(.plain)
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    PortPickerList(equipment: equipment, port: port, peer: primary, replacing: cable.id) { r in
                        if let r { result = r }
                        showing = false
                    }
                }
        } else {
            label.opacity(primary == nil ? 0.5 : 1)
        }
    }
}

private struct PortPickerList: View {
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    let port: EquipmentPort
    let peer: PatchPeer
    let replacing: String
    let done: ((ok: Bool, message: String)?) -> Void
    @State private var query = ""

    var body: some View {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let list = store.candidates(for: port, on: equipment).filter { $0.device.id == peer.device.id }
            .sorted { InventoryRules.byPort($0.port, $1.port) }
            .filter { q.isEmpty || $0.device.portName($0.port).lowercased().contains(q) }
        VStack(alignment: .leading, spacing: 8) {
            Text("\(peer.device.name) channels").font(.canopyHeadline)
            TextField("Search channels", text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach(list) { c in
                    let cabled = !store.cable(at: c.port.id).isEmpty
                    let current = c.port.id == peer.portID
                    let busy = cabled && !current && (c.port.direction == .input || (c.port.direction == .output && !c.port.signal.fansOut))
                    Button {
                        if current { done(nil) } else { Task { done(await store.patch(port.id, to: c.port.id, replacing: replacing)) } }
                    } label: {
                        HStack(spacing: 4) {
                            if current { Image(systemName: "checkmark").font(.canopyCaption) }
                            Text(c.device.portName(c.port)).foregroundStyle(busy ? .secondary : Color.canopyInk).lineLimit(1)
                            SignalTag(signal: c.port.signal)
                            if busy { Text("in use").font(.canopyCaption2).foregroundStyle(.secondary) }
                            Spacer()
                            if !c.warning.isEmpty { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(c.warning) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(busy ? (c.port.direction == .input ? "Patching here replaces what feeds this input now." : "This output takes one cable, so patching here moves it from where it goes now.") : c.warning)
                }
            }
            .frame(width: 280, height: 280)
            if list.isEmpty { Text("No matching channels.").font(.canopyCaption).foregroundStyle(.secondary) }
        }
        .padding()
    }
}
