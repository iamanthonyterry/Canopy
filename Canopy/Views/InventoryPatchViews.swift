import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Signal flow

struct SignalFlowView: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    @State private var query = ""

    var body: some View {
        let chains = InventoryRules.buildChains(patches: store.scopedPatches, hops: store.scopedHops, routes: store.scopedRoutes)
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
                Text("\(shown.count) of \(chains.count) paths").font(.canopyCaption).foregroundStyle(.secondary)
            }
            .padding(.horizontal).padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Text("Each line follows a signal from where it starts to where it ends, over cables (→), stage box links (⇒) and a console's internal patch (⤳). A console's mix is inside it, so a line ends at an input channel and new ones start at its mixes.")
                        .font(.canopyCaption).foregroundStyle(.secondary).padding(.bottom, 4)
                    if shown.isEmpty {
                        Text(chains.isEmpty ? "Nothing is patched yet." : "No signal paths match.").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { c in
                        FlowLayout(spacing: 4) {
                            ForEach(Array(c.stops.enumerated()), id: \.element.id) { i, s in
                                if i > 0 {
                                    Text(c.via[i - 1] == .link ? "⇒" : c.via[i - 1] == .route ? "⤳" : "→")
                                        .foregroundStyle(c.via[i - 1] == .cable ? .secondary : Color.canopySage)
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
                                Text(c.notes.filter { !$0.isEmpty }.joined(separator: "; ")).font(.canopyCaption).foregroundStyle(.secondary)
                            }
                        }
                        .font(.canopyCallout)
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
                        .font(.canopyCallout).foregroundStyle(.secondary)
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
                        Text("\(parsed.0.count) \(parsed.0.count == 1 ? "cable" : "cables") ready").font(.canopyHeadline)
                        ForEach(parsed.1, id: \.self) { Text($0).font(.canopyCaption).foregroundStyle(Color.canopyRust) }
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
                                .font(.canopyCaption)
                            }
                        }
                        if parsed.0.count > 200 { Text("…and \(parsed.0.count - 200) more").font(.canopyCaption).foregroundStyle(.secondary) }
                        HStack {
                            Picker("Into", selection: $campus) {
                                if store.campuses.isEmpty { Text("No campus").tag("") }
                                ForEach(store.campuses) { Text($0.name).tag($0.id) }
                            }
                            .frame(maxWidth: 260)
                            Spacer()
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
                if working { PatchingAnimation() }
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

/// While an import loads: cables patch themselves from a stage box into a console, one at a time, with a
/// signal running down each finished one. Still under Reduce Motion, with only the captions changing.
struct PatchingAnimation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private static let captions = [
        "Untangling the snake…", "Following every XLR…", "Asking the stage box nicely…", "Counting the channels twice…",
        "Labelling it with gaffer tape…", "Finding where the pastor's mic went…", "Matching inputs to faders…", "Coiling over-under…",
    ]
    /// Where each stage box channel lands on the console: crossed, the way real patches are.
    private static let lands = [2, 0, 5, 1, 7, 3, 6, 4]
    private static let step = 0.45, hold = 1.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSince(start)
            let cycle = Double(Self.lands.count) * Self.step + Self.hold
            VStack(spacing: 8) {
                Canvas { context, size in draw(&context, size, phase: reduceMotion ? cycle : t.truncatingRemainder(dividingBy: cycle), time: t) }
                    .frame(width: 300, height: 128)
                Text(Self.captions[Int(timeline.date.timeIntervalSince(start) / 2.4) % Self.captions.count])
                    .font(.canopyCaption).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: Int(timeline.date.timeIntervalSince(start) / 2.4))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Converting")
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, phase: Double, time: Double) {
        let n = Self.lands.count
        let boxW: CGFloat = 54, top: CGFloat = 4, bottom = size.height - 18
        let left = CGRect(x: 0, y: top, width: boxW, height: bottom - top)
        let right = CGRect(x: size.width - boxW, y: top, width: boxW, height: bottom - top)
        for (box, name) in [(left, "STAGE BOX"), (right, "CONSOLE")] {
            context.fill(Path(roundedRect: box, cornerRadius: 8), with: .color(Color.canopyInk.opacity(0.06)))
            context.stroke(Path(roundedRect: box, cornerRadius: 8), with: .color(Color.canopyInk.opacity(0.25)), lineWidth: 1)
            context.draw(Text(name).font(.canopyCaption2).foregroundStyle(.secondary), at: CGPoint(x: box.midX, y: size.height - 6))
        }
        func jack(_ box: CGRect, _ i: Int, out: Bool) -> CGPoint {
            CGPoint(x: out ? box.maxX - 10 : box.minX + 10, y: box.minY + 10 + CGFloat(i) * (box.height - 20) / CGFloat(n - 1))
        }
        let colors: [Color] = [.canopySage, .canopyRust, .canopyInk]
        for i in 0..<n {
            for (box, out) in [(left, true), (right, false)] {
                let p = jack(box, i, out: out)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(Color.canopyInk.opacity(0.35)))
            }
        }
        for i in 0..<n {
            let drawn = min(max((phase - Double(i) * Self.step) / Self.step, 0), 1)
            guard drawn > 0 else { continue }
            let a = jack(left, i, out: true), b = jack(right, Self.lands[i], out: false)
            var cable = Path()
            cable.move(to: a)
            // A little slack: the middle of the cable hangs below a straight line.
            let sag: CGFloat = 18 + CGFloat(i % 3) * 6
            cable.addCurve(to: b, control1: CGPoint(x: a.x + 60, y: a.y + sag), control2: CGPoint(x: b.x - 60, y: b.y + sag))
            let color = colors[i % colors.count]
            context.stroke(cable.trimmedPath(from: 0, to: drawn), with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            for end in [a] + (drawn >= 1 ? [b] : []) {
                context.fill(Path(ellipseIn: CGRect(x: end.x - 4.5, y: end.y - 4.5, width: 9, height: 9)), with: .color(color))
            }
            // A finished cable carries signal: a bright dot running from the stage box to the console.
            if drawn >= 1, !reduceMotion {
                let f = (time * 0.9 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
                if let dot = cable.trimmedPath(from: 0, to: f).currentPoint {
                    context.fill(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)), with: .color(.white))
                    context.stroke(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)), with: .color(color), lineWidth: 1.5)
                }
            }
        }
    }
}
