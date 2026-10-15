import SwiftUI

// MARK: - Channels
// A device's inputs and outputs, channel by channel: name, connector, signal,
// and what's plugged in. Patching picks the far end from a list that puts the
// usual device first and says why an odd pairing is odd (it never stops one:
// the patch sheet is how the gear is really wired).

struct ChannelsSection: View {
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    @State private var result: (ok: Bool, message: String)?

    private var e: Equipment { equipment }

    private var groups: [(title: String, ports: [EquipmentPort])] {
        var out: [(String, [EquipmentPort])] = []
        let own = e.ownPorts
        for dir in PortDirection.allCases {
            let list = own.filter { $0.direction == dir }
            if !list.isEmpty { out.append((dir == .both ? "In / out" : dir == .input ? "Inputs" : "Outputs", list)) }
        }
        for card in e.cards {
            let list = e.ports.filter { $0.cardId == card.id }
            for dir in PortDirection.allCases {
                let part = list.filter { $0.direction == dir }
                if !part.isEmpty { out.append(("\(card.label) · \(dir == .input ? "inputs" : dir == .output ? "outputs" : "in / out")", part)) }
            }
        }
        return out
    }

    var body: some View {
        let feeds = store.feeds(for: e)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Channels").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Spacer()
                if store.level.canEdit, !e.ownPorts.isEmpty {
                    Menu("All channels carry…") {
                        ForEach(Signal.allCases) { s in Button(s.label) { Task { result = await store.setDeviceSignal(e.id, s) } } }
                    }
                    .menuStyle(.button).fixedSize().font(.canopyCaption)
                }
            }
            ResultLine(result: result)
            if e.ports.isEmpty {
                Text(store.level.canEdit ? "Set how many inputs and outputs this has (Edit), then patch them here." : "No channels yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.title) { g in
                DisclosureGroup {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(g.ports) { p in
                            ChannelRow(equipment: e, port: p, feed: feeds[p.id], result: $result)
                            Divider().opacity(0.4)
                        }
                    }
                } label: {
                    let patched = g.ports.filter { !store.cable(at: $0.id).isEmpty || feeds[$0.id] != nil }.count
                    Text("\(g.title) · \(g.ports.count)").fontWeight(.medium)
                        + Text("  \(patched) patched").font(.canopyCaption).foregroundColor(.secondary)
                }
            }
        }
        .canopyCard(padding: 14)
    }
}

private struct ChannelRow: View {
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    let port: EquipmentPort
    let feed: InventoryStore.Feed?
    @Binding var result: (ok: Bool, message: String)?
    @State private var picking = false

    private var canEdit: Bool { store.level.canEdit }
    private var cables: [Cable] { store.cable(at: port.id) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(port.number.map(String.init) ?? "–").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
            if canEdit {
                CommitField(placeholder: port.direction == .output ? "Output \(port.number ?? 0)" : "Input \(port.number ?? 0)", value: port.label, width: 150) { v in
                    Task { result = await store.updatePort(port.id, label: v) }
                }
                CommitField(placeholder: "Connector", value: port.kind, width: 80) { v in
                    Task { result = await store.updatePort(port.id, kind: v) }
                }
                .foregroundStyle(.secondary)
                Menu {
                    ForEach(Signal.allCases) { s in Button(s.label) { Task { result = await store.updatePort(port.id, signal: s) } } }
                } label: { Text(port.signal.label).font(.canopyCaption) }
                    .menuStyle(.borderlessButton).fixedSize().frame(width: 74, alignment: .leading)
            } else {
                Text(port.label.isEmpty ? port.name() : port.label).frame(width: 150, alignment: .leading)
                Text(port.kind).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                Text(port.signal.label).font(.canopyCaption).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(cables) { c in cableLine(c) }
                if let feed { feedLine(feed) }
                if cables.isEmpty && feed == nil && !canEdit { Text("—").foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 0)
            if canEdit && (cables.isEmpty || port.direction != .input) {
                Button { picking = true } label: { Image(systemName: cables.isEmpty ? "cable.connector" : "plus") }
                    .buttonStyle(.borderless)
                    .help(cables.isEmpty ? "Patch this channel" : "Patch another destination")
                    .popover(isPresented: $picking, arrowEdge: .trailing) {
                        PatchPicker(equipment: equipment, port: port, replacing: nil) { r in result = r; picking = false }
                    }
            }
        }
        .font(.canopyCallout)
        .padding(.vertical, 3)
    }

    @ViewBuilder private func cableLine(_ c: Cable) -> some View {
        let otherID = c.fromPort == port.id ? c.toPort : c.fromPort
        if let other = store.port(otherID) {
            CableLine(cable: c, mine: port, otherDevice: other.0, otherPort: other.1, equipment: equipment, result: $result)
        }
    }

    @ViewBuilder private func feedLine(_ f: InventoryStore.Feed) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.canopyCaption).foregroundStyle(Color.canopySage)
            Text(f.text).foregroundStyle(f.conflict ? Color.canopyRust : Color.canopyInk)
            if f.conflict { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.canopyRust).help("Two channels land on the same console channel") }
            if f.custom { Text("reassigned").font(.canopyCaption2).foregroundStyle(.secondary) }
            if canEdit, let link = store.links.first(where: { $0.id == f.linkId }), link.equipmentId == equipment.id, let host = store.byID[link.hostId] {
                Menu {
                    let choices = host.ports.filter { $0.direction == port.direction && $0.cardId == link.hostCardId }
                    ForEach(choices) { c in
                        Button(c.name()) { Task { result = await store.setMapping(link: link.id, boxPort: port.id, hostPort: c.id) } }
                    }
                    if f.custom {
                        Divider()
                        Button("Back to default") { Task { result = await store.setMapping(link: link.id, boxPort: port.id, hostPort: nil) } }
                    }
                } label: { Image(systemName: "arrow.triangle.swap") }
                    .menuStyle(.borderlessButton).fixedSize().help("Land this channel on a different console channel")
            }
        }
    }
}

private struct CableLine: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    let cable: Cable
    let mine: EquipmentPort
    let otherDevice: Equipment
    let otherPort: EquipmentPort
    let equipment: Equipment
    @Binding var result: (ok: Bool, message: String)?
    @State private var replacing = false
    @State private var noting = false
    @State private var note = ""

    var body: some View {
        let fit = InventoryRules.peerFit(mineRole: equipment.role, direction: mine.direction, signal: mine.signal, otherRole: otherDevice.role, otherSignal: otherPort.signal)
        HStack(spacing: 4) {
            Text(cable.fromPort == mine.id ? "→" : "←").foregroundStyle(.secondary)
            Button(otherDevice.name) { nav.open(otherDevice.id) }.buttonStyle(.link)
            Text("· \(otherDevice.portName(otherPort))\(otherPort.kind.isEmpty ? "" : " (\(otherPort.kind))")")
            SignalTag(signal: otherPort.signal)
            if !fit.warning.isEmpty {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(fit.warning)
            }
            if !cable.note.isEmpty { Text(cable.note).font(.canopyCaption).foregroundStyle(.secondary).lineLimit(1) }
            if store.level.canEdit {
                Menu {
                    Button("Change…") { replacing = true }
                    Button(cable.note.isEmpty ? "Add a note…" : "Edit note…") { note = cable.note; noting = true }
                    Divider()
                    Button("Disconnect", role: .destructive) { Task { result = await store.disconnect(cable.id) } }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .popover(isPresented: $replacing, arrowEdge: .trailing) {
                        PatchPicker(equipment: equipment, port: mine, replacing: cable.id) { r in result = r; replacing = false }
                    }
                    .popover(isPresented: $noting) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Cable note").font(.canopyHeadline)
                            TextField("Long run, snake A…", text: $note).textFieldStyle(.roundedBorder).frame(width: 260)
                                .onSubmit(saveNote)
                            HStack { Spacer(); Button("Save", action: saveNote).buttonStyle(.canopyPrimary) }
                        }
                        .padding()
                    }
            }
        }
    }

    private func saveNote() {
        noting = false
        Task { result = await store.setCableNote(cable.id, note) }
    }
}

/// Searchable list of every channel this one could be patched to, the likely devices first.
struct PatchPicker: View {
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    let port: EquipmentPort
    let replacing: String?
    let done: ((ok: Bool, message: String)) -> Void
    @State private var query = ""
    @State private var device: String?

    private var candidates: [InventoryStore.Candidate] { store.candidates(for: port, on: equipment) }

    var body: some View {
        let all = candidates
        let byDevice = Dictionary(grouping: all, by: \.device.id)
        let ranked = byDevice.values.map { list in (list[0].device, list.map(\.rank).min() ?? 0, list) }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : InventoryRules.ordered($0.0.name, $1.0.name) }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 8) {
            Text("Patch \(equipment.portName(port))").font(.canopyHeadline)
            TextField("Search devices and channels", text: $query).textFieldStyle(.roundedBorder)
            HStack(alignment: .top, spacing: 0) {
                List(selection: $device) {
                    ForEach(ranked.filter { q.isEmpty || $0.0.name.lowercased().contains(q) || $0.2.contains { $0.port.label.lowercased().contains(q) } }, id: \.0.id) { d, rank, _ in
                        HStack {
                            Image(systemName: d.role?.symbol ?? "shippingbox").foregroundStyle(.secondary)
                            Text(d.name).lineLimit(1)
                            Spacer()
                            if rank < 25 { Image(systemName: "star.fill").font(.canopyCaption2).foregroundStyle(Color.canopySage).help("Usual for this channel") }
                        }
                        .tag(d.id)
                    }
                }
                .frame(width: 210)
                Divider()
                List {
                    if let id = device ?? ranked.first?.0.id, let list = byDevice[id] {
                        ForEach(list.sorted { InventoryRules.byPort($0.port, $1.port) }.filter { q.isEmpty || $0.device.name.lowercased().contains(q) || $0.port.label.lowercased().contains(q) || $0.device.portName($0.port).lowercased().contains(q) }) { c in
                            let busy = c.port.direction == .input && !store.cable(at: c.port.id).isEmpty
                            Button {
                                Task { done(await store.patch(port.id, to: c.port.id, replacing: replacing)) }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(c.device.portName(c.port)).foregroundStyle(busy ? .secondary : Color.canopyInk)
                                    SignalTag(signal: c.port.signal)
                                    if busy { Text("in use").font(.canopyCaption2).foregroundStyle(.secondary) }
                                    Spacer()
                                    if !c.warning.isEmpty { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(c.warning) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(busy ? "Patching here replaces what feeds this input now." : c.warning)
                        }
                    }
                }
                .frame(width: 280)
            }
            .frame(height: 320)
            if all.isEmpty { Text("No other devices in this campus have a matching channel.").font(.canopyCaption).foregroundStyle(.secondary) }
        }
        .padding()
    }
}

// MARK: - Option cards

struct CardSlotsSection: View {
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    @State private var result: (ok: Bool, message: String)?
    @State private var confirmRemove: OptionCard?

    private var e: Equipment { equipment }
    /// Cards that fit this maker first, then ones that fit any console.
    private var types: [CardType] {
        let make = e.makeModel.lowercased() + " " + e.name.lowercased()
        return store.cardTypes.filter { $0.brand.isEmpty || make.contains($0.brand.lowercased()) }
            .sorted { ($0.brand.isEmpty ? 1 : 0, $0.name) < ($1.brand.isEmpty ? 1 : 0, $1.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Option cards").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
            ForEach(1...max(1, max(e.cardSlots, e.cards.map(\.slot).max() ?? 0)), id: \.self) { slot in
                HStack {
                    Text("Slot \(slot)").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    if let card = e.cards.first(where: { $0.slot == slot }) {
                        Text(card.name).fontWeight(.medium)
                        SignalTag(signal: card.signal)
                        Text("\(card.inputs) in · \(card.outputs) out").font(.canopyCaption).foregroundStyle(.secondary)
                        Spacer()
                        if store.level.canEdit {
                            Button("Remove") { confirmRemove = card }.buttonStyle(.canopySecondary)
                        }
                    } else {
                        Text("Empty").foregroundStyle(.tertiary)
                        Spacer()
                        if store.level.canEdit {
                            Menu("Fit a card…") {
                                ForEach(types) { t in
                                    Button("\(t.name) (\(t.inputs)×\(t.outputs))") { Task { result = await store.addCard(e.id, slot: slot, type: t) } }
                                }
                            }
                            .menuStyle(.button).fixedSize().disabled(types.isEmpty)
                        }
                    }
                }
            }
            ResultLine(result: result)
        }
        .canopyCard(padding: 14)
        .confirmationDialog(confirmRemove.map { "Remove \($0.name) from slot \($0.slot)?" } ?? "",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let c = confirmRemove { Task { result = await store.removeCard(c.id) } }; confirmRemove = nil }
        } message: {
            Text("Its channels and everything patched to them go with it.")
        }
    }
}

// MARK: - Stage box links

struct StageLinkSection: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    @State private var result: (ok: Bool, message: String)?
    @State private var hostID = ""
    @State private var cardID = ""
    @State private var signal: Signal = .network
    @State private var first = 1
    @State private var editing = false

    private var e: Equipment { equipment }
    private var asBox: StageLink? { store.link(asBox: e) }
    private var asHost: [StageLink] { store.links(asHost: e) }
    private var hosts: [Equipment] {
        store.equipment.filter { $0.id != e.id && $0.campus == e.campus }
            .sorted { ($0.role == .console ? 0 : 1, $0.name) < ($1.role == .console ? 0 : 1, $1.name) }
    }
    private var relevant: Bool { e.role == .stageBox || asBox != nil || !asHost.isEmpty || store.crossedCables(e) != nil }

    var body: some View {
        if relevant {
            VStack(alignment: .leading, spacing: 8) {
                Text("Stage box connection").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Text("A stage box's channels reach the console over one link (gigaACE, Dante, AES50…) instead of a cable per channel. Box channel 1 lands on the first console channel you choose, and so on; reassign single channels from the channel list.")
                    .font(.canopyCaption).foregroundStyle(.secondary)
                if let link = asBox, !editing {
                    HStack {
                        let host = store.byID[link.hostId]
                        Text("Connected to")
                        Button(host?.name ?? "(unknown)") { if let host { nav.open(host.id) } }.buttonStyle(.link)
                        Text("· \(host?.card(link.hostCardId)?.label ?? "Built-in ports") · from channel \(link.portOffset + 1)")
                        SignalTag(signal: link.signal)
                        Spacer()
                        if store.level.canEdit {
                            Button("Change") { load(link); editing = true }.buttonStyle(.canopySecondary)
                            Button("Disconnect") { Task { result = await store.removeLink(link.id) } }.buttonStyle(.canopySecondary)
                        }
                    }
                } else if store.level.canEdit && (e.role == .stageBox || editing || store.crossedCables(e) != nil) {
                    editor
                }
                if let crossed = store.crossedCables(e), store.level.canEdit {
                    HStack {
                        Image(systemName: "lightbulb").foregroundStyle(.orange)
                        Text("\(crossed.count) cables run from this box's outputs into \(crossed.host.name)'s inputs. Turn them into one connection?")
                            .font(.canopyCallout)
                        Spacer()
                        Button("Convert") { Task { result = await store.convertCables(box: e.id, host: crossed.host.id) } }.buttonStyle(.canopySecondary)
                    }
                }
                ForEach(asHost) { link in
                    HStack {
                        Text("Feeds in from")
                        Button(store.byID[link.equipmentId]?.name ?? "(unknown)") { nav.open(link.equipmentId) }.buttonStyle(.link)
                        Text("on \(e.card(link.hostCardId)?.label ?? "built-in ports"), from channel \(link.portOffset + 1)").foregroundStyle(.secondary)
                        SignalTag(signal: link.signal)
                    }
                    .font(.canopyCallout)
                }
                ResultLine(result: result)
            }
            .canopyCard(padding: 14)
        }
    }

    private var editor: some View {
        let host = store.byID[hostID]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Console", selection: Binding(get: { hostID }, set: { hostID = $0; cardID = "" })) {
                    Text("Choose…").tag("")
                    ForEach(hosts) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 260)
                Picker("Through", selection: $cardID) {
                    Text("Built-in ports").tag("")
                    ForEach(host?.cards ?? []) { Text($0.label).tag($0.id) }
                }
                .frame(maxWidth: 240)
                .disabled(host == nil)
            }
            HStack {
                if cardID.isEmpty {
                    Picker("Link", selection: $signal) { ForEach(Signal.allCases) { Text($0.label).tag($0) } }.frame(maxWidth: 180)
                }
                Stepper("Box channel 1 lands on console channel \(first)", value: $first, in: 1...1025)
                Spacer()
                if editing { Button("Cancel") { editing = false }.buttonStyle(.canopySecondary) }
                Button("Connect") {
                    Task {
                        result = await store.setLink(box: e.id, host: hostID, cardID: cardID.isEmpty ? nil : cardID, signal: signal, offset: first - 1)
                        if result?.ok == true { editing = false }
                    }
                }
                .buttonStyle(.canopyPrimary).disabled(hostID.isEmpty)
            }
        }
    }

    private func load(_ link: StageLink) {
        hostID = link.hostId; cardID = link.hostCardId ?? ""; signal = link.signal; first = link.portOffset + 1
    }
}
