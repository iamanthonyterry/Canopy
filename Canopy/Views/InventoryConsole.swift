import SwiftUI

// MARK: - Console channels
// A console's own channel strips and its internal patch, the way the desk's
// input and output patch screens show them: each input channel takes its signal
// from one socket the console can reach (its own, an option card's, a linked
// stage box's or an attached surface's), and each mix goes out to any number of
// sockets. Beside every socket is what's plugged into it, so a channel can be
// followed from the mic to the fader and from the mix to the speaker.

struct ConsoleChannelsSection: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    var query = ""
    /// On the Console Patch tab the title is the console, linking to its page.
    var linksToDevice = false
    @State private var result: (ok: Bool, message: String)?
    @State private var sizing = false
    @State private var blocking: ChannelKind?

    private var e: Equipment { equipment }
    private var canEdit: Bool { store.level.canEdit && store.consoleReady }

    private func shown(_ kind: ChannelKind) -> [ConsoleChannel] {
        let all = store.channels(of: e, kind)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { c in
            c.title.lowercased().contains(q) || store.sockets(of: c).contains { s in
                [s.device.name, s.device.portName(s.port), store.upstream(of: s.port.id) ?? "", store.downstream(of: s.port.id) ?? ""]
                    .contains { $0.lowercased().contains(q) }
            }
        }
    }

    var body: some View {
        let inputs = store.channels(of: e, .input), outputs = store.channels(of: e, .output)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if linksToDevice {
                    Button(e.name) { nav.open(e.id) }.buttonStyle(.plain).font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                    Text(store.place(e)).font(.canopyCaption).foregroundStyle(.secondary)
                } else {
                    Text("Console channels").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                }
                Spacer()
                if canEdit {
                    Menu("Patch a block…") {
                        ForEach(ChannelKind.allCases) { k in
                            Button(k == .input ? "Input channels…" : "Mixes…") { blocking = k }.disabled(store.channels(of: e, k).isEmpty)
                        }
                    }
                    .menuStyle(.button).fixedSize().font(.canopyCaption)
                    .disabled(inputs.isEmpty && outputs.isEmpty)
                    .popover(item: $blocking, arrowEdge: .bottom) { k in
                        BlockPatchForm(console: e, kind: k) { r in result = r; if r.ok { blocking = nil } }
                    }
                    Button("Channels…") { sizing = true }
                        .buttonStyle(.canopySecondary)
                        .popover(isPresented: $sizing, arrowEdge: .bottom) {
                            ChannelCountForm(console: e, inputs: inputs.count, outputs: outputs.count) { r in result = r; if r.ok { sizing = false } }
                        }
                }
            }
            if !store.consoleReady {
                Text("Your church's database doesn't have console channels yet. Once whoever runs the website updates it, refresh here.")
                    .font(.canopyCaption).foregroundStyle(.secondary)
            }
            reaches
            ResultLine(result: result)
            if inputs.isEmpty && outputs.isEmpty && store.consoleReady {
                Text(store.level.canEdit
                     ? "Set how many input channels and mixes this console has (Channels…), then pick where each one's signal comes from: its own sockets, an option card, a stage box or a surface."
                     : "No console channels yet.")
                    .font(.canopyCallout).foregroundStyle(.secondary)
            }
            ForEach(ChannelKind.allCases) { kind in
                let list = shown(kind)
                let total = kind == .input ? inputs : outputs
                if !list.isEmpty {
                    DisclosureGroup {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(list) { c in
                                ConsoleChannelRow(console: e, channel: c, result: $result)
                                Divider().opacity(0.4)
                            }
                        }
                    } label: {
                        let patched = total.filter { c in store.consolePatch.contains { $0.channelId == c.id } }.count
                        Text("\(Text("\(kind.plural) · \(total.count)").fontWeight(.medium))\(Text("  \(patched) patched").font(.canopyCaption).foregroundColor(.secondary))")
                    }
                }
            }
        }
        .canopyCard(padding: 14)
    }

    /// The stage boxes, cards and surfaces this console can patch from, beyond its own sockets.
    @ViewBuilder private var reaches: some View {
        let groups = store.socketGroups(for: e, .input).filter { $0.id != e.id }
        if !groups.isEmpty {
            FlowLayout(spacing: 6) {
                Text("Reaches").font(.canopyCaption).foregroundStyle(.secondary)
                ForEach(groups) { g in
                    HStack(spacing: 4) {
                        Image(systemName: g.device.id == e.id ? "rectangle.connected.to.line.below" : g.device.role?.symbol ?? "shippingbox")
                            .foregroundStyle(Color.canopySage)
                        if g.device.id == e.id { Text(g.title) } else { Button(g.title) { nav.open(g.device.id) }.buttonStyle(.link) }
                        Text(g.detail).foregroundStyle(.secondary)
                    }
                    .font(.canopyCaption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.canopyPaperElevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.canopyRule))
                }
            }
        }
    }
}

private struct ConsoleChannelRow: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    let console: Equipment
    let channel: ConsoleChannel
    @Binding var result: (ok: Bool, message: String)?
    @State private var picking = false

    private var canEdit: Bool { store.level.canEdit && store.consoleReady }

    var body: some View {
        let sockets = store.sockets(of: channel)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(channel.number)").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
            if canEdit {
                CommitField(placeholder: "\(channel.kind.prefix) \(channel.number)", value: channel.label, width: 150) { v in
                    Task { result = await store.renameChannel(channel.id, v) }
                }
            } else {
                Text(channel.label.isEmpty ? "\(channel.kind.prefix) \(channel.number)" : channel.label).frame(width: 150, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sockets, id: \.patch.id) { s in socketLine(s.patch, s.device, s.port) }
                if sockets.isEmpty { Text("Not patched").foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 0)
            if canEdit && (channel.kind == .output || sockets.isEmpty) {
                Button { picking = true } label: { Image(systemName: sockets.isEmpty ? "cable.connector" : "plus") }
                    .buttonStyle(.borderless)
                    .help(channel.kind == .input ? "Choose where this channel's signal comes from" : sockets.isEmpty ? "Send this mix to a socket" : "Send it to another socket too")
                    .popover(isPresented: $picking, arrowEdge: .trailing) {
                        SocketPicker(console: console, channel: channel) { r in result = r; if r.ok { picking = false } }
                    }
            }
        }
        .font(.canopyCallout)
        .padding(.vertical, 3)
    }

    private func socketLine(_ patch: ConsolePatch, _ device: Equipment, _ port: EquipmentPort) -> some View {
        let input = channel.kind == .input
        let beyond = input ? store.upstream(of: port.id) : store.downstream(of: port.id)
        return HStack(spacing: 4) {
            Text(input ? "←" : "→").foregroundStyle(.secondary)
            if device.id == console.id {
                Text(device.portName(port))
            } else {
                Button(device.name) { nav.open(device.id) }.buttonStyle(.link)
                Text("· \(device.portName(port))")
            }
            SignalTag(signal: port.signal)
            if let beyond {
                Text("\(input ? "fed by" : "to") \(beyond)").font(.canopyCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            if canEdit {
                Menu {
                    if input { Button("Change…") { picking = true } }
                    Button("Unpatch", role: .destructive) { Task { result = await store.unpatchChannel(patch.id) } }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .popover(isPresented: Binding(get: { picking && input }, set: { if !$0 { picking = false } }), arrowEdge: .trailing) {
                        SocketPicker(console: console, channel: channel) { r in result = r; if r.ok { picking = false } }
                    }
            }
        }
    }
}

/// Every socket a channel could be patched to, by where it is: the console's own, a card, a stage box or a surface.
private struct SocketPicker: View {
    @ObservedObject private var store = InventoryStore.shared
    let console: Equipment
    let channel: ConsoleChannel
    let done: ((ok: Bool, message: String)) -> Void
    @State private var query = ""
    @State private var group: String?

    var body: some View {
        let groups = store.socketGroups(for: console, channel.kind)
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 8) {
            Text(channel.kind == .input ? "Source for \(channel.title)" : "Send \(channel.title) to").font(.canopyHeadline)
            TextField("Search sockets", text: $query).textFieldStyle(.roundedBorder)
            if channel.kind == .output {
                // Outputs: one list, each card's (or box's) outputs together under its name, in channel order.
                List {
                    ForEach(groups) { g in
                        let ports = g.ports
                            .filter { q.isEmpty || g.title.lowercased().contains(q) || matches($0, g, q) }
                            .sorted { InventoryRules.byPort($0, $1) }
                        if !ports.isEmpty {
                            Section {
                                ForEach(ports) { p in socketButton(p, g) }
                            } header: {
                                HStack(spacing: 6) {
                                    Text(g.title).fontWeight(.medium)
                                    Text(g.detail).font(.canopyCaption2).foregroundStyle(.secondary)
                                }
                                .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(width: 440, height: 320)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    List(selection: $group) {
                        ForEach(groups.filter { g in q.isEmpty || g.title.lowercased().contains(q) || g.ports.contains { matches($0, g, q) } }) { g in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.title).lineLimit(1)
                                Text(g.detail).font(.canopyCaption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .tag(g.id)
                        }
                    }
                    .frame(width: 220)
                    Divider()
                    List {
                        if let g = groups.first(where: { $0.id == (group ?? groups.first?.id) }) {
                            ForEach(g.ports.filter { q.isEmpty || matches($0, g, q) }) { p in socketButton(p, g) }
                        }
                    }
                    .frame(width: 300)
                }
                .frame(height: 320)
            }
            if groups.isEmpty {
                Text("This console has no \(channel.kind == .input ? "input" : "output") sockets yet. Give it some, fit a card, or connect a stage box or surface to it.")
                    .font(.canopyCaption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func socketButton(_ p: EquipmentPort, _ g: InventoryStore.SocketGroup) -> some View {
        let using = store.channels(at: p.id).filter { $0.console.id == console.id && $0.channel.kind == channel.kind && $0.channel.id != channel.id }
        let beyond = channel.kind == .input ? store.upstream(of: p.id) : store.downstream(of: p.id)
        return Button {
            Task { done(await store.patchChannels([(channel.id, p.id)])) }
        } label: {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) { Text(g.device.portName(p)); SignalTag(signal: p.signal) }
                    if let beyond { Text(beyond).font(.canopyCaption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if !using.isEmpty {
                    Text(using.map { "\($0.channel.kind.prefix) \($0.channel.number)" }.joined(separator: ", "))
                        .font(.canopyCaption2).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(using.isEmpty ? "" : channel.kind == .output ? "Sending here replaces the mix this socket carries now." : "Already feeds another channel; it can feed this one too.")
    }

    private func matches(_ p: EquipmentPort, _ g: InventoryStore.SocketGroup, _ q: String) -> Bool {
        g.device.portName(p).lowercased().contains(q) || p.kind.lowercased().contains(q)
    }
}

/// How many input channels and mixes a console has.
private struct ChannelCountForm: View {
    @ObservedObject private var store = InventoryStore.shared
    let console: Equipment
    @State var inputs: Int
    @State var outputs: Int
    let done: ((ok: Bool, message: String)) -> Void
    @State private var working = false

    var body: some View {
        let before = (store.channels(of: console, .input).count, store.channels(of: console, .output).count)
        VStack(alignment: .leading, spacing: 10) {
            Text("Channels on \(console.name)").font(.canopyHeadline)
            Text("The console's channel strips, apart from its sockets: a dLive has 128 input channels and up to 64 mixes, for example.")
                .font(.canopyCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Input channels")
                    TextField("", value: $inputs, format: .number).textFieldStyle(.roundedBorder).frame(width: 64)
                    Stepper("", value: $inputs, in: 0...512).labelsHidden()
                }
                GridRow {
                    Text("Mixes and outputs")
                    TextField("", value: $outputs, format: .number).textFieldStyle(.roundedBorder).frame(width: 64)
                    Stepper("", value: $outputs, in: 0...512).labelsHidden()
                }
            }
            if inputs < before.0 || outputs < before.1 {
                Text("The highest-numbered channels go, with their names and patch.").font(.canopyCaption).foregroundStyle(Color.canopyRust)
            }
            HStack {
                Spacer()
                Button("Save") {
                    Task { working = true; done(await store.setChannelCounts(console.id, inputs: inputs, outputs: outputs)); working = false }
                }
                .buttonStyle(.canopyPrimary).disabled(working)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

/// Patches a run of channels in one go: "channels 1–16 from the stage box's inputs 1–16".
private struct BlockPatchForm: View {
    @ObservedObject private var store = InventoryStore.shared
    let console: Equipment
    let kind: ChannelKind
    let done: ((ok: Bool, message: String)) -> Void
    @State private var first = 1
    @State private var count = 16
    @State private var group = ""
    @State private var start = ""
    @State private var working = false

    var body: some View {
        let groups = store.socketGroups(for: console, kind)
        let g = groups.first { $0.id == group } ?? groups.first
        let channels = store.channels(of: console, kind)
        let sockets = g?.ports ?? []
        let pairs = g.map { _ in InventoryRules.block(channels: channels, first: first, count: count, sockets: sockets, start: start.isEmpty ? sockets.first?.id ?? "" : start) } ?? []
        VStack(alignment: .leading, spacing: 10) {
            Text(kind == .input ? "Patch a block of input channels" : "Send a block of mixes").font(.canopyHeadline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text(kind == .input ? "Channels from" : "Mixes from")
                    Stepper("\(kind.prefix) \(first)", value: $first, in: 1...max(1, channels.map(\.number).max() ?? 1))
                }
                GridRow {
                    Text("How many")
                    Stepper("\(count)", value: $count, in: 1...512)
                }
                GridRow {
                    Text(kind == .input ? "From" : "To")
                    Picker("", selection: Binding(get: { g?.id ?? "" }, set: { group = $0; start = "" })) {
                        ForEach(groups) { Text("\($0.title) (\($0.detail))").tag($0.id) }
                    }
                    .labelsHidden().frame(maxWidth: 280)
                }
                GridRow {
                    Text("Starting at")
                    Picker("", selection: Binding(get: { start.isEmpty ? sockets.first?.id ?? "" : start }, set: { start = $0 })) {
                        ForEach(sockets) { p in Text(g?.device.portName(p) ?? p.name()).tag(p.id) }
                    }
                    .labelsHidden().frame(maxWidth: 280)
                }
            }
            if let a = pairs.first, let z = pairs.last, let g {
                Text("\(a.channel.kind.prefix) \(a.channel.number)–\(z.channel.number) \(kind == .input ? "←" : "→") \(g.title) \(g.device.portName(a.socket)) to \(g.device.portName(z.socket)). \(kind == .input ? "Their current sources are replaced." : "Mixes those sockets carry now are replaced.")")
                    .font(.canopyCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Patch \(pairs.count)") {
                    Task { working = true; done(await store.patchChannels(pairs.map { ($0.channel.id, $0.socket.id) })); working = false }
                }
                .buttonStyle(.canopyPrimary).disabled(pairs.isEmpty || working)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

// MARK: - Console patch tab

/// Every console's internal patch in one place, with the stage boxes and surfaces each one reaches.
struct ConsolePatchView: View {
    @ObservedObject private var store = InventoryStore.shared
    @State private var query = ""

    var body: some View {
        let consoles = store.consoles
        let surfaces = store.scoped.filter { $0.role == .surface }
        VStack(spacing: 0) {
            HStack {
                TextField("Channel, socket, device…", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("Inside each console: which socket feeds every input channel, and which sockets every mix goes out to. Sockets can be the console's own, an option card's, a stage box's or a control surface's.")
                        .font(.canopyCallout).foregroundStyle(.secondary)
                    let loose = surfaces.filter { store.controller(of: $0) == nil }
                    if !loose.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text("\(loose.map(\.name).joined(separator: ", ")) \(loose.count == 1 ? "isn't" : "aren't") attached to a controller yet, so \(loose.count == 1 ? "its" : "their") sockets can't be patched. Open \(loose.count == 1 ? "it" : "each one") and choose its controller.")
                                .font(.canopyCallout)
                        }
                    }
                    if consoles.isEmpty {
                        Text("No mixing consoles yet. Set a device's type to Mixing console to give it channels.").foregroundStyle(.secondary)
                    }
                    ForEach(consoles) { c in ConsoleChannelsSection(equipment: c, query: query, linksToDevice: true) }
                }
                .padding()
            }
        }
    }
}
