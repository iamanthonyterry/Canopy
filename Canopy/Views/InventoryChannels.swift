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
                    let patched = g.ports.filter { !store.cable(at: $0.id).isEmpty || feeds[$0.id] != nil || !store.channels(at: $0.id).isEmpty }.count
                    Text("\(Text("\(g.title) · \(g.ports.count)").fontWeight(.medium))\(Text("  \(patched) patched").font(.canopyCaption).foregroundColor(.secondary))")
                }
            }
        }
        .canopyCard(padding: 14)
    }
}

private struct ChannelRow: View {
    @EnvironmentObject private var nav: InventoryNavigator
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
                ForEach(store.channels(at: port.id), id: \.channel.id) { hit in
                    HStack(spacing: 4) {
                        Image(systemName: "slider.vertical.3").font(.canopyCaption).foregroundStyle(Color.canopySage)
                        Text(port.feedsIn && hit.channel.kind == .input ? "→" : "←").foregroundStyle(.secondary)
                        if hit.console.id == equipment.id { Text(hit.channel.title) }
                        else { Button(hit.console.name) { nav.open(hit.console.id) }.buttonStyle(.link); Text("· \(hit.channel.title)") }
                    }
                    .help(hit.channel.kind == .input ? "Patched inside the console to this input channel" : "This mix is sent out of this socket")
                }
                if cables.isEmpty && feed == nil && store.channels(at: port.id).isEmpty && !canEdit { Text("—").foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 0)
            // An input has one source and most outputs one cable (change those from the cable's menu); audio over a
            // network can go to many inputs.
            if canEdit && (cables.isEmpty || port.direction == .both || (port.direction == .output && port.signal.fansOut)) {
                let boxes = boxLinks
                let cards = cardSources
                Group {
                    if (boxes.isEmpty && cards.isEmpty) || feed != nil {
                        Button { picking = true } label: { Image(systemName: cables.isEmpty ? "cable.connector" : "plus") }
                            .buttonStyle(.borderless)
                    } else {
                        Menu {
                            Button("Cable to a device…") { picking = true }
                            Divider()
                            ForEach(boxes, id: \.link.id) { entry in
                                Menu("From \(entry.box.name)") { boxItems(entry.link, entry.box) }
                            }
                            ForEach(cards, id: \.title) { entry in
                                Menu(entry.title) { cardItems(entry.ports, entry.device) }
                            }
                        } label: { Image(systemName: cables.isEmpty ? "cable.connector" : "plus") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                }
                .help(cables.isEmpty ? "Patch this channel" : "Patch another destination")
                .popover(isPresented: $picking, arrowEdge: .trailing) {
                    PatchPicker(equipment: equipment, port: port, replacing: nil) { r in result = r; picking = false }
                }
            }
        }
        .font(.canopyCallout)
        .padding(.vertical, 3)
    }

    /// Stage boxes linked to this very port group whose own sockets of the same direction could land here.
    private var boxLinks: [(link: StageLink, box: Equipment)] {
        guard port.direction != .both, equipment.role != .stageBox else { return [] }
        return store.links(asHost: equipment).compactMap { l in
            guard l.hostCardId == port.cardId, let box = store.byID[l.equipmentId], box.ownPorts.contains(where: { $0.direction == port.direction }) else { return nil }
            return (l, box)
        }
    }

    /// Option card inputs on this console and on surfaces linked to it, for patching this input channel from.
    private var cardSources: [(title: String, device: Equipment, ports: [EquipmentPort])] {
        guard port.direction == .input, equipment.role != .stageBox else { return [] }
        var out: [(String, Equipment, [EquipmentPort])] = []
        func add(_ d: Equipment, prefix: String) {
            for card in d.cards {
                let ports = d.ports.filter { $0.cardId == card.id && $0.feedsIn && $0.id != port.id }.sorted { InventoryRules.byPort($0, $1) }
                if !ports.isEmpty { out.append(("\(prefix)Card \(card.slot) · \(card.name)", d, ports)) }
            }
        }
        add(equipment, prefix: "")
        for l in store.links(asHost: equipment) {
            if let box = store.byID[l.equipmentId], box.role == .surface { add(box, prefix: "\(box.name) · ") }
        }
        return out
    }

    /// Card sockets patch the console channel with this input's number, since a card isn't linked like a box.
    @ViewBuilder private func cardItems(_ ports: [EquipmentPort], _ device: Equipment) -> some View {
        let channel = store.channels(of: equipment, .input).first { $0.number == port.number }
        let pick: (EquipmentPort) -> Void = { p in
            if let channel { Task { result = await store.patchChannels([(channel.id, p.id)]) } }
        }
        if channel == nil { Text("No input channel \(port.number ?? 0) on this console") }
        else if ports.count > 24 {
            ForEach(Array(stride(from: 0, to: ports.count, by: 16)), id: \.self) { start in
                let run = Array(ports[start..<min(ports.count, start + 16)])
                Menu("\(run.first?.number ?? start + 1)–\(run.last?.number ?? start + run.count)") {
                    ForEach(run) { p in Button(device.portName(p)) { pick(p) } }
                }
            }
        } else {
            ForEach(ports) { p in Button(device.portName(p)) { pick(p) } }
        }
    }

    /// The box's sockets (inputs for an input), in runs of 16 when there are many; picking one lands it on this channel.
    @ViewBuilder private func boxItems(_ link: StageLink, _ box: Equipment) -> some View {
        let ports = box.ownPorts.filter { $0.direction == port.direction }.sorted { InventoryRules.byPort($0, $1) }
        let pick: (EquipmentPort) -> Void = { p in Task { result = await store.assignBoxChannel(link: link.id, hostPort: port.id, boxPort: p.id) } }
        if ports.count > 24 {
            ForEach(Array(stride(from: 0, to: ports.count, by: 16)), id: \.self) { start in
                let run = Array(ports[start..<min(ports.count, start + 16)])
                Menu("\(run.first?.number ?? start + 1)–\(run.last?.number ?? start + run.count)") {
                    ForEach(run) { p in Button(box.portName(p)) { pick(p) } }
                }
            }
        } else {
            ForEach(ports) { p in Button(box.portName(p)) { pick(p) } }
        }
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
            if canEdit, let link = store.links.first(where: { $0.id == f.linkId }), link.hostId == equipment.id, let boxPortId = f.boxPortId,
               let box = store.byID[link.equipmentId] {
                Menu {
                    let choices = box.ownPorts.filter { $0.direction == port.direction }
                    ForEach(choices) { c in
                        Button { Task { result = await store.assignBoxChannel(link: link.id, hostPort: port.id, boxPort: c.id) } } label: {
                            Text(c.id == boxPortId ? "✓ \(c.name())" : c.name())
                        }
                    }
                } label: { Image(systemName: "arrow.triangle.swap") }
                    .menuStyle(.borderlessButton).fixedSize().help("Take this channel from a different \(box.name) input")
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
                            let cabled = !store.cable(at: c.port.id).isEmpty
                            let busy = cabled && (c.port.direction == .input || (c.port.direction == .output && !c.port.signal.fansOut))
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
                            .help(!busy ? c.warning : c.port.direction == .input ? "Patching here replaces what feeds this input now."
                                  : "This output takes one cable, so patching here moves it from where it goes now.")
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
    private var isSurface: Bool { e.role == .surface }
    private var asBox: StageLink? { store.link(asBox: e) }
    private var asHost: [StageLink] { store.links(asHost: e) }
    /// Consoles first, then surfaces (a stage box can plug into a surface), then everything else.
    private var hosts: [Equipment] {
        func rank(_ d: Equipment) -> Int { d.role == .console ? 0 : d.role == .surface && !isSurface ? 1 : 2 }
        return store.equipment.filter { $0.id != e.id && $0.campus == e.campus }.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
    }
    /// Whether the box's channels land on the host's channels from a starting number (not for surfaces).
    private func lands(_ hostID: String) -> Bool { InventoryRules.landsChannels(box: e.role, host: store.byID[hostID]?.role) }
    private var relevant: Bool { e.role == .stageBox || isSurface || asBox != nil || !asHost.isEmpty || store.crossedCables(e) != nil }

    var body: some View {
        if relevant {
            VStack(alignment: .leading, spacing: 8) {
                Text(isSurface ? "Controller" : "Stage box connection").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Text(isSurface
                     ? "When the mixing happens in a separate controller (a dLive MixRack, say), attach this surface to it. The surface's own sockets, and any stage box plugged into the surface, then show up in the controller's console channels to patch from."
                     : "A stage box's channels reach the console over one link (gigaACE, Dante, AES50…) instead of a cable per channel. Box channel 1 lands on the first console channel you choose, and so on; reassign single channels from the channel list. Plugged into a control surface, its sockets are patched in the surface's controller instead.")
                    .font(.canopyCaption).foregroundStyle(.secondary)
                if let link = asBox, !editing {
                    HStack {
                        let host = store.byID[link.hostId]
                        Text(isSurface ? "Controlled by" : "Connected to")
                        Button(host?.name ?? "(unknown)") { if let host { nav.open(host.id) } }.buttonStyle(.link)
                        Text("· \(host?.card(link.hostCardId)?.label ?? "Built-in ports")" + (lands(link.hostId) ? " · from channel \(link.portOffset + 1)" : ""))
                        if !isSurface, host?.role == .surface, let ctrl = store.controller(of: e) {
                            Text("· patched in").foregroundStyle(.secondary)
                            Button(ctrl.name) { nav.open(ctrl.id) }.buttonStyle(.link)
                        }
                        SignalTag(signal: link.signal)
                        Spacer()
                        if store.level.canEdit {
                            Button("Change") { load(link); editing = true }.buttonStyle(.canopySecondary)
                            Button("Disconnect") { Task { result = await store.removeLink(link.id) } }.buttonStyle(.canopySecondary)
                        }
                    }
                } else if store.level.canEdit && (e.role == .stageBox || isSurface || editing || store.crossedCables(e) != nil) {
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
                    let other = store.byID[link.equipmentId]
                    HStack {
                        Text(other?.role == .surface ? "Controlled from" : "Feeds in from")
                        Button(other?.name ?? "(unknown)") { nav.open(link.equipmentId) }.buttonStyle(.link)
                        Text("on \(e.card(link.hostCardId)?.label ?? "built-in ports")" + (InventoryRules.landsChannels(box: other?.role, host: e.role) ? ", from channel \(link.portOffset + 1)" : ""))
                            .foregroundStyle(.secondary)
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
                Picker(isSurface ? "Controller" : "Console", selection: Binding(get: { hostID }, set: { hostID = $0; cardID = "" })) {
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
                if hostID.isEmpty || lands(hostID) {
                    Stepper("Box channel 1 lands on console channel \(first)", value: $first, in: 1...1025)
                }
                Spacer()
                if editing { Button("Cancel") { editing = false }.buttonStyle(.canopySecondary) }
                Button("Connect") {
                    Task {
                        result = await store.setLink(box: e.id, host: hostID, cardID: cardID.isEmpty ? nil : cardID, signal: signal, offset: lands(hostID) ? first - 1 : 0)
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
