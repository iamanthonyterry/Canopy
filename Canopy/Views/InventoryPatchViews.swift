import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Patch sheet
// How all the equipment fits together: one row per cable, grouped by the device
// being patched, channel by channel, the way a stage patch list reads.

struct PatchSheetView: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    @State private var query = ""
    @AppStorage("inventory.patchSide") private var byInputs = true
    @State private var result: (ok: Bool, message: String)?
    @State private var confirm: Patch?

    private func matches(_ p: PatchPort, _ q: String) -> Bool {
        [p.device.name, p.port.label, p.port.kind, p.place].contains { $0.lowercased().contains(q) }
    }

    var body: some View {
        let patches = store.scopedPatches
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = patches.filter { q.isEmpty || matches($0.from, q) || matches($0.to, q) || $0.cable.note.lowercased().contains(q) }
        let groups = Dictionary(grouping: shown) { byInputs ? $0.to.device.id : $0.from.device.id }
            .map { id, rows in (device: store.byID[id], rows: rows.sorted { InventoryRules.byPort(byInputs ? $0.to.port : $0.from.port, byInputs ? $1.to.port : $1.from.port) }) }
            .sorted { InventoryRules.ordered($0.device?.name ?? "", $1.device?.name ?? "") }
        let own = store.scoped.flatMap(\.ownPorts)
        let used = Set(store.patches.flatMap { [$0.from.id, $0.to.id] } + store.hops.flatMap { [$0.from.id, $0.to.id] })
        let unpatched = own.filter { !used.contains($0.id) }
        let devices = Set(patches.flatMap { [$0.from.device.id, $0.to.device.id] })

        VStack(spacing: 0) {
            HStack {
                TextField("Device, port, connector, room, cable…", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Picker("", selection: $byInputs) {
                    Text("By where it plugs in").tag(true)
                    Text("By where it comes from").tag(false)
                }
                .pickerStyle(.segmented).fixedSize()
                Spacer()
                Button { export(patches) } label: { Label("Export CSV…", systemImage: "square.and.arrow.up") }.buttonStyle(.canopySecondary)
            }
            .padding(.horizontal).padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("\(patches.count) \(patches.count == 1 ? "cable" : "cables") across \(devices.count) \(devices.count == 1 ? "device" : "devices"), plus \(store.scopedHops.count) channels over stage box links. \(own.count) ports in all, \(unpatched.count) not patched.")
                        .font(.callout).foregroundStyle(.secondary)
                    ResultLine(result: result)
                    if patches.isEmpty {
                        Text(store.level.canEdit ? "Nothing is patched yet. Open a device to patch its channels, or import a spreadsheet." : "Nothing is patched yet.")
                            .foregroundStyle(.secondary)
                    } else if shown.isEmpty {
                        Text("No connections match.").foregroundStyle(.secondary)
                    }
                    ForEach(groups, id: \.device?.id) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                if let d = g.device {
                                    Button(d.name) { nav.open(d.id) }.buttonStyle(.plain).font(.headline).foregroundStyle(Color.canopyInk)
                                    Text([store.place(d), "\(g.rows.count) \(g.rows.count == 1 ? "cable" : "cables") \(byInputs ? "in" : "out")"].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            ForEach(g.rows) { p in row(p) }
                        }
                        .canopyCard(padding: 12)
                    }
                    if !unpatched.isEmpty {
                        let byDevice = Dictionary(grouping: unpatched, by: \.equipmentId).sorted { InventoryRules.ordered(store.byID[$0.key]?.name ?? "", store.byID[$1.key]?.name ?? "") }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Not patched yet").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                            ForEach(byDevice, id: \.key) { id, ports in
                                HStack {
                                    Button(store.byID[id]?.name ?? "") { nav.open(id) }.buttonStyle(.link)
                                    let c = InventoryRules.counts(ports)
                                    Text("\(c.inputs) in · \(c.outputs) out not patched").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .canopyCard(padding: 12)
                    }
                }
                .padding()
            }
        }
        .confirmationDialog(confirm.map { "Disconnect \($0.from.device.name) from \($0.to.device.name)?" } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { if let p = confirm { Task { result = await store.disconnect(p.id) } }; confirm = nil }
        }
    }

    private func row(_ p: Patch) -> some View {
        let mine = byInputs ? p.to : p.from
        let other = byInputs ? p.from : p.to
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(mine.name).fontWeight(.medium).frame(width: 220, alignment: .leading).lineLimit(1)
            Text(mine.port.kind).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(byInputs ? "←" : "→").foregroundStyle(.secondary)
            Button(other.device.name) { nav.open(other.device.id) }.buttonStyle(.link)
            Text("· \(other.title)").lineLimit(1)
            SignalTag(signal: other.port.signal)
            if p.from.port.signal != p.to.port.signal {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("\(p.from.port.signal.label) into \(p.to.port.signal.label)")
            }
            Spacer()
            Text(p.cable.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if store.level.canEdit {
                Button { confirm = p } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Disconnect")
            }
        }
        .font(.callout)
    }

    private func export(_ patches: [Patch]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Patch sheet - \(store.scopeName).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PatchImport.export(patches).write(to: url, atomically: true, encoding: .utf8)
            result = (true, "Saved \(url.lastPathComponent). Edit it in a spreadsheet and bring it back with Import.")
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}

// MARK: - Signal flow

struct SignalFlowView: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    @State private var query = ""

    var body: some View {
        let chains = InventoryRules.buildChains(patches: store.scopedPatches, hops: store.scopedHops)
            .sorted { a, b in
                a.stops[0].device.name != b.stops[0].device.name ? InventoryRules.ordered(a.stops[0].device.name, b.stops[0].device.name)
                    : InventoryRules.byPort(a.stops[0].port, b.stops[0].port)
            }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = chains.filter { c in
            q.isEmpty || c.stops.contains { [$0.device.name, $0.port.label, $0.port.kind, $0.place].contains { $0.lowercased().contains(q) } }
                || c.notes.contains { $0.lowercased().contains(q) }
        }
        VStack(spacing: 0) {
            HStack {
                TextField("Follow a device, channel or room…", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Spacer()
                Text("\(shown.count) of \(chains.count) paths").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal).padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Text("Each line follows a signal from where it starts to where it ends, over cables (→) and stage box links (⇒). A console's mix is inside it, so a line ends at a console input and new ones start at its outputs.")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                    if shown.isEmpty {
                        Text(chains.isEmpty ? "Nothing is patched yet." : "No signal paths match.").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { c in
                        FlowLayout(spacing: 4) {
                            ForEach(Array(c.stops.enumerated()), id: \.element.id) { i, s in
                                if i > 0 {
                                    Text(c.via[i - 1] == .link ? "⇒" : "→").foregroundStyle(c.via[i - 1] == .link ? Color.canopySage : .secondary)
                                        .help(c.notes[i - 1])
                                }
                                HStack(spacing: 3) {
                                    Button(s.device.name) { nav.open(s.device.id) }.buttonStyle(.link)
                                    Text(s.name).foregroundStyle(.secondary)
                                    SignalTag(signal: s.port.signal)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.canopyPaperElevated, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.canopyRule))
                            }
                            if c.notes.contains(where: { !$0.isEmpty }) {
                                Text(c.notes.filter { !$0.isEmpty }.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                        .padding(.vertical, 3)
                        Divider().opacity(0.4)
                    }
                }
                .padding()
            }
        }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += line + spacing; x = 0; line = 0 }
            x += s.width + spacing; line = max(line, s.height); widest = max(widest, x)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y + (line > 0 ? 0 : 0)), proposal: ProposedViewSize(s))
            x += s.width + spacing; line = max(line, s.height)
        }
    }
}

// MARK: - Import

/// Import: read any document with the on-device model, or bring in a spreadsheet already in the patch-sheet layout.
struct InventoryImportView: View {
    enum Mode: String, CaseIterable, Identifiable { case document = "Read a document", sheet = "Patch sheet spreadsheet"; var id: String { rawValue } }
    @AppStorage("inventory.importMode") private var mode: Mode = .document
    @State private var sheetText = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).fixedSize().padding(.top, 10)
            switch mode {
            case .document: DocumentImportView { text in sheetText = text; mode = .sheet }
            case .sheet: PatchImportView(text: $sheetText)
            }
        }
    }
}

struct PatchImportView: View {
    @ObservedObject private var store = InventoryStore.shared
    @Binding var text: String
    @State private var campus = ""
    @State private var result: (ok: Bool, message: String)?
    @State private var opening = false
    @State private var working = false

    var body: some View {
        let parsed = text.isEmpty ? ([], []) : PatchImport.parse(text)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Import a patch sheet").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                    Text("Bring cables in from a spreadsheet saved as CSV, or paste rows copied from one. Devices are matched by name and channels by number (or name); anything missing is added. A row replaces whatever fed that input before. Headings: \(PatchImport.headers.joined(separator: ", ")).")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Open CSV…") { opening = true }.buttonStyle(.canopySecondary)
                        Button("Paste") { text = NSPasteboard.general.string(forType: .string) ?? "" }.buttonStyle(.canopySecondary)
                        Button("Save template…") { saveTemplate() }.buttonStyle(.canopySecondary)
                        if !text.isEmpty { Button("Clear") { text = ""; result = nil }.buttonStyle(.canopySecondary) }
                        Spacer()
                    }
                }
                .canopyCard(padding: 14)

                if !text.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(parsed.0.count) \(parsed.0.count == 1 ? "cable" : "cables") ready").font(.headline)
                        ForEach(parsed.1, id: \.self) { Text($0).font(.caption).foregroundStyle(Color.canopyRust) }
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                            GridRow { Text("From").bold(); Text("Channel").bold(); Text("To").bold(); Text("Channel").bold(); Text("Note").bold() }
                            ForEach(Array(parsed.0.prefix(200).enumerated()), id: \.offset) { _, r in
                                GridRow {
                                    Text(r.fromDevice + (r.fromCard.isEmpty ? "" : " · \(r.fromCard)"))
                                    Text([r.fromChannel.map(String.init) ?? "", r.fromName].filter { !$0.isEmpty }.joined(separator: ". "))
                                    Text(r.toDevice + (r.toCard.isEmpty ? "" : " · \(r.toCard)"))
                                    Text([r.toChannel.map(String.init) ?? "", r.toName].filter { !$0.isEmpty }.joined(separator: ". "))
                                    Text(r.note).foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                        }
                        if parsed.0.count > 200 { Text("…and \(parsed.0.count - 200) more").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Picker("Into", selection: $campus) {
                                if store.campuses.isEmpty { Text("No campus").tag("") }
                                ForEach(store.campuses) { Text($0.name).tag($0.id) }
                            }
                            .frame(maxWidth: 260)
                            Spacer()
                            if working { ProgressView().controlSize(.small) }
                            Button("Import \(parsed.0.count) \(parsed.0.count == 1 ? "cable" : "cables")") {
                                Task {
                                    working = true
                                    result = await store.importCables(parsed.0, campus: campus)
                                    working = false
                                    if result?.ok == true { text = "" }
                                }
                            }
                            .buttonStyle(.canopyPrimary).disabled(parsed.0.isEmpty || working)
                        }
                    }
                    .canopyCard(padding: 14)
                }
                ResultLine(result: result)
            }
            .padding()
        }
        .onAppear {
            let real = store.scope == InventoryRules.unassigned ? "" : store.scope
            campus = real.isEmpty ? store.campuses.first?.id ?? "" : real
        }
        .fileImporter(isPresented: $opening, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { picked in
            guard case .success(let url) = picked else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        }
    }

    private func saveTemplate() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Patch sheet template.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? PatchImport.templateCSV.write(to: url, atomically: true, encoding: .utf8)
    }
}
