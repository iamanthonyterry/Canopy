import SwiftUI

// MARK: - System map
// The whole production system as one picture: devices laid out left to right
// in the order signal moves through them (sources, then stage boxes and
// receivers, consoles and switchers, processing, amps and transmitters,
// speakers), with a line for every device-to-device connection, colored by
// what it carries. Hover a device to see only its connections; click to open it.

struct SystemMapView: View {
    @EnvironmentObject private var nav: InventoryNavigator
    @ObservedObject private var store = InventoryStore.shared
    @State private var hovered: String?
    @State private var zoom: Double = 1
    @AppStorage("inventory.mapAll") private var showUnconnected = false
    @AppStorage("inventory.mapRooms") private var byRoom = false

    struct Edge: Identifiable {
        var from: String
        var to: String
        var count: Int
        var signal: Signal
        var link: Bool
        var id: String { "\(from)>\(to)>\(link)" }
    }

    static let nodeSize = CGSize(width: 180, height: 46)
    static let columnGap: CGFloat = 110
    static let rowGap: CGFloat = 18
    static let stageNames = ["Sources", "Inputs & transport", "Mixing & switching", "Processing & network", "Amps & transmitters", "Speakers"]

    private var edges: [Edge] {
        var acc: [String: (Edge, [Signal: Int])] = [:]
        func add(_ from: String, _ to: String, _ signal: Signal, link: Bool) {
            guard from != to else { return }
            let key = "\(from)>\(to)>\(link)"
            var entry = acc[key] ?? (Edge(from: from, to: to, count: 0, signal: signal, link: link), [:])
            entry.0.count += 1
            entry.1[signal, default: 0] += 1
            acc[key] = entry
        }
        for p in store.scopedPatches { add(p.from.device.id, p.to.device.id, p.from.port.signal, link: false) }
        for l in store.links where store.byID[l.equipmentId].map(store.inScope) ?? false {
            let n = store.scopedHops.filter { $0.linkId == l.id }.count
            if n > 0 {
                add(l.equipmentId, l.hostId, l.signal, link: true)
                acc["\(l.equipmentId)>\(l.hostId)>true"]?.0.count = n
            }
        }
        return acc.values.map { e, signals in
            var edge = e
            edge.signal = signals.max { $0.value < $1.value }?.key ?? e.signal
            return edge
        }
    }

    private func layout(_ edges: [Edge]) -> (positions: [String: CGPoint], size: CGSize, columns: [Int]) {
        let connected = Set(edges.flatMap { [$0.from, $0.to] })
        let devices = store.scoped.filter { showUnconnected || connected.contains($0.id) }
        let columns = Dictionary(grouping: devices) { $0.role?.stage ?? 3 }
        let used = columns.keys.sorted()
        var positions: [String: CGPoint] = [:]
        var height: CGFloat = 0
        for (ci, stage) in used.enumerated() {
            let list = (columns[stage] ?? []).sorted { a, b in
                if byRoom {
                    let ra = store.place(a), rb = store.place(b)
                    if ra != rb { return InventoryRules.ordered(ra, rb) }
                }
                return InventoryRules.ordered(a.name, b.name)
            }
            for (ri, d) in list.enumerated() {
                let x = 20 + CGFloat(ci) * (Self.nodeSize.width + Self.columnGap) + Self.nodeSize.width / 2
                let y = 44 + CGFloat(ri) * (Self.nodeSize.height + Self.rowGap) + Self.nodeSize.height / 2
                positions[d.id] = CGPoint(x: x, y: y)
                height = max(height, y + Self.nodeSize.height)
            }
        }
        let width = 40 + CGFloat(used.count) * (Self.nodeSize.width + Self.columnGap) - Self.columnGap
        return (positions, CGSize(width: max(width, 400), height: max(height + 20, 200)), used)
    }

    var body: some View {
        let edges = self.edges
        let (positions, size, columns) = layout(edges)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Show unconnected devices", isOn: $showUnconnected)
                Toggle("Group by room", isOn: $byRoom)
                Spacer()
                legend(edges)
                Slider(value: $zoom, in: 0.4...1.6) { Text("Zoom") }.frame(width: 160)
            }
            .font(.caption)
            .padding(.horizontal).padding(.vertical, 8)
            if positions.isEmpty {
                Text("Patch some cables or connect a stage box, and the map of your system appears here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { ci, stage in
                            Text(Self.stageNames[min(stage, Self.stageNames.count - 1)].uppercased())
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(width: Self.nodeSize.width)
                                .position(x: 20 + CGFloat(ci) * (Self.nodeSize.width + Self.columnGap) + Self.nodeSize.width / 2, y: 16)
                        }
                        Canvas { ctx, _ in
                            for e in edges {
                                guard let a = positions[e.from], let b = positions[e.to] else { continue }
                                let dim = hovered != nil && hovered != e.from && hovered != e.to
                                let path = curve(from: a, to: b)
                                ctx.stroke(path, with: .color(e.signal.color.opacity(dim ? 0.08 : 0.7)),
                                           style: StrokeStyle(lineWidth: min(1.5 + CGFloat(e.count) / 6, 6), lineCap: .round, dash: e.link ? [6, 4] : []))
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        ForEach(edges) { e in
                            if let a = positions[e.from], let b = positions[e.to], hovered == nil || hovered == e.from || hovered == e.to {
                                Text("\(e.count)")
                                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                    .padding(.horizontal, 4)
                                    .background(Color.canopyPaper, in: Capsule())
                                    .foregroundStyle(e.signal.color)
                                    .position(mid(a, b))
                                    .help("\(e.count) \(e.link ? "channels over a link" : e.count == 1 ? "cable" : "cables") · \(e.signal.label)")
                            }
                        }
                        ForEach(store.scoped.filter { positions[$0.id] != nil }) { d in
                            node(d, connections: edges.filter { $0.from == d.id || $0.to == d.id }.reduce(0) { $0 + $1.count })
                                .position(positions[d.id]!)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
                    .padding()
                }
            }
        }
    }

    private func node(_ d: Equipment, connections: Int) -> some View {
        let lit = hovered == d.id
        return Button { nav.open(d.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: d.role?.symbol ?? "shippingbox").foregroundStyle(Color.canopySage).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text([store.place(d), connections > 0 ? "\(connections)" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
            .background(Color.canopyPaperElevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(lit ? Color.canopySage : Color.canopyRule, lineWidth: lit ? 2 : 1))
            .shadow(color: .black.opacity(lit ? 0.15 : 0.04), radius: lit ? 6 : 2, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? d.id : (hovered == d.id ? nil : hovered) }
        .help("\(d.name)\(d.role.map { " · \($0.label)" } ?? "")")
    }

    private func curve(from a: CGPoint, to b: CGPoint) -> Path {
        let half = Self.nodeSize.width / 2
        var p = Path()
        if b.x > a.x + 1 {
            let start = CGPoint(x: a.x + half, y: a.y), end = CGPoint(x: b.x - half, y: b.y)
            let dx = (end.x - start.x) / 2
            p.move(to: start)
            p.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
        } else {
            // Same column or flowing back: loop out to the right and come in from the right.
            let start = CGPoint(x: a.x + half, y: a.y), end = CGPoint(x: b.x + half, y: b.y)
            let out = max(start.x, end.x) + 50 + abs(a.y - b.y) * 0.08
            p.move(to: start)
            p.addCurve(to: end, control1: CGPoint(x: out, y: start.y), control2: CGPoint(x: out, y: end.y))
        }
        return p
    }

    private func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let half = Self.nodeSize.width / 2
        if b.x > a.x + 1 { return CGPoint(x: (a.x + half + b.x - half) / 2, y: (a.y + b.y) / 2) }
        return CGPoint(x: max(a.x, b.x) + half + 38 + abs(a.y - b.y) * 0.06, y: (a.y + b.y) / 2)
    }

    private func legend(_ edges: [Edge]) -> some View {
        let signals = Set(edges.map(\.signal)).sorted { $0.label < $1.label }
        return HStack(spacing: 8) {
            ForEach(signals) { s in
                HStack(spacing: 3) {
                    Capsule().fill(s.color).frame(width: 14, height: 4)
                    Text(s.label)
                }
            }
            if edges.contains(where: \.link) {
                HStack(spacing: 3) {
                    Text("- - -").foregroundStyle(Color.canopySage)
                    Text("stage box link")
                }
            }
        }
        .foregroundStyle(.secondary)
    }
}
