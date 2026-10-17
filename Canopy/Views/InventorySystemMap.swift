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
            // A stage box's channels land on the console; a surface (or a box on one) is patched in the controller,
            // so its count is how many console channels use its sockets.
            let landing = store.scopedHops.filter { $0.linkId == l.id }.count
            let patched = store.scopedRoutes.filter { $0.from.device.id == l.equipmentId || $0.to.device.id == l.equipmentId }.count
            let lands = InventoryRules.landsChannels(box: store.byID[l.equipmentId]?.role, host: store.byID[l.hostId]?.role)
            guard landing > 0 || !lands else { continue }
            add(l.equipmentId, l.hostId, l.signal, link: true)
            acc["\(l.equipmentId)>\(l.hostId)>true"]?.0.count = lands ? landing : patched
        }
        return acc.values.map { e, signals in
            var edge = e
            edge.signal = signals.max { $0.value < $1.value }?.key ?? e.signal
            return edge
        }
    }

    static let busWidth: CGFloat = 44

    struct MapLayout {
        var positions: [String: CGPoint]
        var size: CGSize
        var columns: [Int]
        var centers: [CGFloat]
        var busX: CGFloat?
    }

    private func layout(_ edges: [Edge], hasBus: Bool) -> MapLayout {
        let connected = Set(edges.flatMap { [$0.from, $0.to] })
        let devices = store.scoped.filter { showUnconnected || connected.contains($0.id) }
        let columns = Dictionary(grouping: devices) { $0.role?.stage ?? 3 }
        let used = columns.keys.sorted()
        // The Dante network sits as a bar between the stage I/O column and the consoles, like the signal-flow diagram.
        let busAt: Int? = hasBus ? used.filter { $0 <= 1 }.count : nil
        var x: CGFloat = 20
        var centers: [CGFloat] = []
        var busX: CGFloat?
        for slot in 0..<(used.count + (hasBus ? 1 : 0)) {
            if slot == busAt {
                busX = x + Self.busWidth / 2
                x += Self.busWidth + Self.columnGap
            } else {
                centers.append(x + Self.nodeSize.width / 2)
                x += Self.nodeSize.width + Self.columnGap
            }
        }
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
                let y = 44 + CGFloat(ri) * (Self.nodeSize.height + Self.rowGap) + Self.nodeSize.height / 2
                positions[d.id] = CGPoint(x: centers[ci], y: y)
                height = max(height, y + Self.nodeSize.height)
            }
        }
        return MapLayout(positions: positions, size: CGSize(width: max(x - Self.columnGap + 20, 400), height: max(height + 20, 200)), columns: used, centers: centers, busX: busX)
    }

    var body: some View {
        let allEdges = self.edges
        // Dante is drawn as taps onto one shared network bar instead of a line per device pair.
        let danteIDs = Set(allEdges.filter { $0.signal == .dante && !$0.link }.flatMap { [$0.from, $0.to] })
        let edges = allEdges.filter { !($0.signal == .dante && !$0.link) }
        let map = layout(allEdges, hasBus: !danteIDs.isEmpty)
        let positions = map.positions, size = map.size, columns = map.columns
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Show unconnected devices", isOn: $showUnconnected)
                Toggle("Group by room", isOn: $byRoom)
                Spacer()
                legend(edges)
                Slider(value: $zoom, in: 0.4...1.6) { Text("Zoom") }.frame(width: 160)
            }
            .font(.canopyCaption)
            .padding(.horizontal).padding(.vertical, 8)
            if positions.isEmpty {
                Text("Patch some cables or connect a stage box, and the map of your system appears here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { ci, stage in
                            Text(Self.stageNames[min(stage, Self.stageNames.count - 1)].uppercased())
                                .font(.canopySans(10, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(width: Self.nodeSize.width)
                                .position(x: map.centers[ci], y: 16)
                        }
                        if let busX = map.busX {
                            let h = size.height - 40
                            RoundedRectangle(cornerRadius: Self.busWidth / 2)
                                .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .top, endPoint: .bottom))
                                .frame(width: Self.busWidth, height: h)
                                .overlay(Text("DANTE NETWORK").font(.canopySans(10, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.85))
                                    .fixedSize().rotationEffect(.degrees(-90)))
                                .position(x: busX, y: 30 + h / 2)
                        }
                        Canvas { ctx, _ in
                            if let busX = map.busX {
                                for id in danteIDs {
                                    guard let p = positions[id] else { continue }
                                    let dim = hovered != nil && hovered != id
                                    let edge = p.x < busX ? p.x + Self.nodeSize.width / 2 : p.x - Self.nodeSize.width / 2
                                    var tap = Path()
                                    tap.move(to: CGPoint(x: edge, y: p.y)); tap.addLine(to: CGPoint(x: busX, y: p.y))
                                    ctx.stroke(tap, with: .color(Color.purple.opacity(dim ? 0.1 : 0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    ctx.fill(Path(ellipseIn: CGRect(x: busX - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white.opacity(dim ? 0.2 : 0.95)))
                                }
                            }
                            for e in edges {
                                guard let a = positions[e.from], let b = positions[e.to] else { continue }
                                let dim = hovered != nil && hovered != e.from && hovered != e.to
                                let path = curve(from: a, to: b)
                                ctx.stroke(path, with: .color(e.signal.color.opacity(dim ? 0.08 : 0.7)),
                                           style: StrokeStyle(lineWidth: min(1.5 + CGFloat(e.count) / 6, 6), lineCap: .round, dash: dash(for: e)))
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        ForEach(edges) { e in
                            if let a = positions[e.from], let b = positions[e.to], e.count > 0, hovered == nil || hovered == e.from || hovered == e.to {
                                Text("\(e.count)")
                                    .font(.canopySans(10, weight: .semibold)).monospacedDigit()
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
                Image(systemName: d.role?.symbol ?? "shippingbox").foregroundStyle(Self.tint(d.role)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).font(.canopySans(12, weight: .semibold)).lineLimit(1)
                    Text([store.place(d), connections > 0 ? "\(connections)" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.canopySans(10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
            .background(Color.canopyPaperElevated, in: RoundedRectangle(cornerRadius: 10))
            .background(Self.tint(d.role).opacity(lit ? 0.35 : 0.18), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(lit ? Self.tint(d.role) : Color.canopyRule, lineWidth: lit ? 2 : 1))
            .shadow(color: Self.tint(d.role).opacity(lit ? 0.4 : 0.15), radius: lit ? 8 : 4, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? d.id : (hovered == d.id ? nil : hovered) }
        .help("\(d.name)\(d.role.map { " · \($0.label)" } ?? "")")
    }

    /// Card color by what the device is, so the map reads like the signal-flow diagram: sources, stage I/O, computers, consoles, IEMs, PA.
    static func tint(_ role: DeviceRole?) -> Color {
        switch role {
        case .source, .camera: return .teal
        case .stageBox, .wirelessReceiver, .videoEncoder, .videoDecoder: return .blue
        case .computer: return .purple
        case .console, .surface, .videoSwitcher, .lightingConsole: return .pink
        case .iemTransmitter: return Color(red: 0.95, green: 0.4, blue: 0.7)
        case .amp, .speaker, .ledProcessor: return .orange
        case .networkSwitch, .processor: return .indigo
        default: return Color.canopySage
        }
    }

    /// Line style shows the kind of cable: dashed for stage-box links, dotted for wireless hops, dash-dot for AES50 and MADI.
    private func dash(for e: Edge) -> [CGFloat] {
        if e.link { return [6, 4] }
        let roles = [store.byID[e.from]?.role, store.byID[e.to]?.role]
        if roles.contains(.wirelessReceiver) || roles.contains(.iemTransmitter) { return [2, 4] }
        if e.signal == .aes50 || e.signal == .madi { return [8, 3, 2, 3] }
        return []
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
                    Text("stage box or surface link")
                }
            }
        }
        .foregroundStyle(.secondary)
    }
}
