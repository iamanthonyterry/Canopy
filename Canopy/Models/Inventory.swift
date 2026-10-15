import Foundation

// MARK: - Production inventory
// The church's whole production system: every device, its channels and option
// cards, every cable between them, stage box links, rooms and racks, service
// history and config files. It lives in the church's Supabase project (shared by
// every Mac and team member); InventoryStore reads and writes it as the person
// signed in, so their inventory level decides what they can see and change.
//
// Everything in this file is plain data and rules with no network access, so
// it can be tested on its own. The names and rules match the database (see the
// church site's supabase/migrations/2026100x–2026110x_*.sql).

nonisolated enum PortDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case input, output, both
    var id: String { rawValue }
    var label: String {
        switch self { case .input: return "Input"; case .output: return "Output"; case .both: return "In / out" }
    }
}

nonisolated enum Signal: String, Codable, CaseIterable, Identifiable, Sendable {
    case analog, dante, madi, aes50, gigaace, soundgrid, avb, usb, network, video, dmx
    var id: String { rawValue }
    var label: String {
        switch self {
        case .analog: return "Analog"; case .dante: return "Dante"; case .madi: return "MADI"; case .aes50: return "AES50"
        case .gigaace: return "gigaACE"; case .soundgrid: return "SoundGrid"; case .avb: return "AVB"; case .usb: return "USB"
        case .network: return "Network"; case .video: return "Video"; case .dmx: return "DMX"
        }
    }
    /// What a port carries when nobody said otherwise, from the device's category.
    static func `default`(for category: String) -> Signal {
        switch category { case "Video": return .video; case "Lighting": return .dmx; case "Network": return .network; default: return .analog }
    }
    /// Digital audio links are worth showing beside a port; plain analog, video, DMX and network stay untagged.
    var isTagged: Bool { ![.analog, .network, .video, .dmx].contains(self) }
}

nonisolated enum DeviceRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case console, surface, stageBox = "stage-box", wirelessReceiver = "wireless-receiver", iemTransmitter = "iem-transmitter"
    case source, amp, speaker, processor, computer, videoSwitcher = "video-switcher", videoEncoder = "video-encoder"
    case videoDecoder = "video-decoder", ledProcessor = "led-processor", camera, lightingConsole = "lighting-console"
    case lightingNode = "lighting-node", networkSwitch = "switch", other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .console: return "Mixing console"; case .surface: return "Control surface"; case .stageBox: return "Stage box"
        case .wirelessReceiver: return "Wireless mic receiver"; case .iemTransmitter: return "IEM transmitter"; case .source: return "Mic / source"
        case .amp: return "Amplifier"; case .speaker: return "Speaker"; case .processor: return "Processor"; case .computer: return "Computer"
        case .videoSwitcher: return "Video switcher"; case .videoEncoder: return "Video encoder"; case .videoDecoder: return "Video decoder"
        case .ledProcessor: return "LED wall processor"; case .camera: return "Camera"; case .lightingConsole: return "Lighting console"
        case .lightingNode: return "Lighting node"; case .networkSwitch: return "Network switch"; case .other: return "Other"
        }
    }
    var symbol: String {
        switch self {
        case .console, .surface: return "slider.vertical.3"; case .stageBox: return "square.grid.3x3"; case .wirelessReceiver: return "antenna.radiowaves.left.and.right"
        case .iemTransmitter: return "earbuds"; case .source: return "music.mic"; case .amp: return "bolt.horizontal"; case .speaker: return "hifispeaker"
        case .processor: return "waveform"; case .computer: return "desktopcomputer"; case .videoSwitcher: return "rectangle.split.3x3"
        case .videoEncoder, .videoDecoder: return "arrow.left.arrow.right.square"; case .ledProcessor: return "tv"; case .camera: return "video"
        case .lightingConsole: return "lightbulb.2"; case .lightingNode: return "lightbulb"; case .networkSwitch: return "network"; case .other: return "shippingbox"
        }
    }
    /// Where a device sits in the signal path, left to right, for the system map.
    var stage: Int {
        switch self {
        case .source, .camera, .computer: return 0
        case .wirelessReceiver, .stageBox, .videoEncoder, .videoDecoder: return 1
        case .console, .surface, .videoSwitcher, .lightingConsole: return 2
        case .processor, .networkSwitch, .lightingNode, .other: return 3
        case .amp, .iemTransmitter, .ledProcessor: return 4
        case .speaker: return 5
        }
    }
}

nonisolated enum EquipmentStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case inService = "in-service", spare, inRepair = "in-repair", loaned, retired
    var id: String { rawValue }
    var label: String {
        switch self { case .inService: return "In service"; case .spare: return "Spare"; case .inRepair: return "In repair"; case .loaned: return "Loaned out"; case .retired: return "Retired" }
    }
}

nonisolated enum EquipmentCondition: String, Codable, CaseIterable, Identifiable, Sendable {
    case new, good, fair, poor
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

nonisolated enum ServiceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case repair, maintenance, inspection, note
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// How much of the inventory someone gets. Owners and admins always have `.edit`.
nonisolated enum InventoryLevel: String, Codable, Sendable, Comparable {
    case none, patch, view, edit
    var canViewDetails: Bool { self == .view || self == .edit }
    var canEdit: Bool { self == .edit }
    var label: String {
        switch self { case .none: return "No access"; case .patch: return "Patch sheet only"; case .view: return "View everything"; case .edit: return "Can edit" }
    }
    private var rank: Int { switch self { case .none: return 0; case .patch: return 1; case .view: return 2; case .edit: return 3 } }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

nonisolated enum InventoryCategories {
    static let all = ["Audio", "Video", "Lighting", "Network", "Computer", "Instrument", "Streaming", "Other"]
}

// MARK: - Records

nonisolated struct Campus: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
}

nonisolated struct OptionCard: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var slot: Int
    var name: String
    var signal: Signal
    var inputs: Int
    var outputs: Int
    /// How a card is named where its channels are listed: "Slot 1 Dante 64×64".
    var label: String { "Slot \(slot) \(name)" }
}

nonisolated struct CardType: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var brand: String
    var signal: Signal
    var inputs: Int
    var outputs: Int
}

nonisolated struct EquipmentPort: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var equipmentId: String
    var number: Int?
    var label: String
    var kind: String
    var direction: PortDirection
    var signal: Signal
    /// The option card this channel belongs to; nil for the device's own.
    var cardId: String?

    /// "3. Kick In", or "Input 3" while it has no name.
    func name(card: String = "") -> String {
        let prefix = card.isEmpty ? "" : "\(card) · "
        if !label.isEmpty { return prefix + (number.map { "\($0). " } ?? "") + label }
        let word = direction == .output ? "Output" : direction == .input ? "Input" : "Port"
        return prefix + word + (number.map { " \($0)" } ?? "")
    }
    /// Like `name`, with the connector when one is set.
    func title(card: String = "") -> String { name(card: card) + (kind.isEmpty ? "" : " (\(kind))") }

    var feedsIn: Bool { direction != .output }
    var feedsOut: Bool { direction != .input }
}

nonisolated struct Equipment: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var category: String = ""
    var role: DeviceRole?
    var makeModel: String = ""
    var serial: String = ""
    var location: String = ""
    /// The campus it belongs to; "" while unassigned.
    var campus: String = ""
    var value: Double?
    var yearPurchased: Int?
    var ipAddress: String = ""
    var username: String = ""
    var password: String = ""
    var notes: String = ""
    var status: EquipmentStatus = .inService
    var condition: EquipmentCondition?
    /// "YYYY-MM-DD", or nil.
    var purchaseDate: String?
    var purchasePrice: Double?
    var vendor: String = ""
    var warrantyExpires: String?
    var warrantyTerms: String = ""
    var roomId: String?
    var rackId: String?
    /// The lowest rack unit it fills, counted from 1 at the bottom.
    var rackUnit: Int?
    var rackHeight: Int = 1
    var cardSlots: Int = 0
    var cards: [OptionCard] = []
    var ports: [EquipmentPort] = []

    var ownPorts: [EquipmentPort] { ports.filter { $0.cardId == nil } }
    func card(_ id: String?) -> OptionCard? { id.flatMap { cid in cards.first { $0.id == cid } } }
    func portName(_ p: EquipmentPort) -> String { p.name(card: card(p.cardId)?.label ?? "") }
    /// The address as a bare host (no scheme, port or path), or nil when it isn't one.
    var host: String? { InventoryRules.hostOf(ipAddress) }
}

nonisolated struct Cable: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var fromPort: String
    var toPort: String
    var note: String
}

/// A stage box connected to a console: box channel N lands on console channel N + offset,
/// through the console's own ports (hostCardId nil) or one of its option cards.
nonisolated struct StageLink: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var equipmentId: String
    var hostId: String
    var hostCardId: String?
    var signal: Signal
    var portOffset: Int
}

nonisolated struct LinkMapEntry: Codable, Hashable, Sendable {
    var linkId: String
    var boxPort: String
    var hostPort: String
}

nonisolated struct Room: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var campus: String
}

nonisolated struct Rack: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var roomId: String
    var name: String
    var units: Int
}

nonisolated struct ServiceEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var equipmentId: String
    var kind: ServiceKind
    var performedOn: String
    var summary: String
    var cost: Double?
    var vendor: String
}

nonisolated struct EquipmentFile: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var equipmentId: String
    var name: String
    var size: Int
    var createdAt: String
}

/// A starting-point device for "Start from" (shared by every church).
nonisolated struct EquipmentPreset: Codable, Hashable, Identifiable, Sendable {
    var category: String
    var brand: String
    var model: String
    var inputs: Int
    var outputs: Int
    var price: Double?
    var role: String
    var signal: String
    var extraInputs: Int
    var extraSignal: String
    var cardSlots: Int
    var id: String { "\(brand)\n\(model)" }
    var name: String { "\(brand) \(model)" }
}

// MARK: - Derived views

/// A port with the device it's on, as the patch sheet shows it.
nonisolated struct PatchPort: Hashable, Identifiable, Sendable {
    var port: EquipmentPort
    var device: Equipment
    var place: String
    var id: String { port.id }
    var name: String { device.portName(port) }
    var title: String { name + (port.kind.isEmpty ? "" : " (\(port.kind))") }
    static func == (a: Self, b: Self) -> Bool { a.port == b.port && a.device.id == b.device.id && a.place == b.place }
    func hash(into h: inout Hasher) { h.combine(port.id) }
}

nonisolated struct Patch: Hashable, Identifiable, Sendable {
    var cable: Cable
    var from: PatchPort
    var to: PatchPort
    var id: String { cable.id }
}

/// A channel carried over a stage box link rather than a cable.
nonisolated struct Hop: Hashable, Sendable {
    var from: PatchPort
    var to: PatchPort
    var custom: Bool
    var linkId: String
}

/// One path signal takes: each stop, and how it got to the next.
nonisolated struct SignalChain: Hashable, Identifiable, Sendable {
    enum Via: String, Sendable { case cable, link }
    var stops: [PatchPort]
    var via: [Via]
    var notes: [String]
    var id: String { stops.map(\.id).joined(separator: ">") }
}

// MARK: - Rules

nonisolated enum InventoryRules {
    /// "3" before "10", ignoring case.
    static func ordered(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }

    /// Channel number (unnumbered last), then name.
    static func byPort(_ a: EquipmentPort, _ b: EquipmentPort) -> Bool {
        let x = a.number ?? .max, y = b.number ?? .max
        return x != y ? x < y : ordered(a.label, b.label)
    }

    static func rackSpan(unit: Int?, height: Int) -> String {
        guard let unit else { return "" }
        return height > 1 ? "U\(unit)–\(unit + height - 1)" : "U\(unit)"
    }

    /// "Sanctuary · Rack A U12–13 · left shelf". The typed location is left out where it only repeats the room.
    static func placeLabel(_ e: Equipment, rooms: [String: Room], racks: [String: Rack]) -> String {
        let room = e.roomId.flatMap { rooms[$0]?.name } ?? ""
        let rack = e.rackId.flatMap { racks[$0] }
        let loc = e.location.trimmingCharacters(in: .whitespaces)
        let parts = [
            room,
            rack.map { r in e.rackUnit == nil ? r.name : "\(r.name) \(rackSpan(unit: e.rackUnit, height: e.rackHeight))" } ?? "",
            loc.lowercased() == room.lowercased() ? "" : loc,
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The campus view: "" is every campus, `unassigned` is equipment with no campus yet.
    static let unassigned = "_none"
    static func inCampus(_ scope: String, _ campus: String) -> Bool {
        scope.isEmpty || (scope == unassigned ? campus.isEmpty : campus == scope)
    }

    /// A device address reduced to a bare host (no scheme, port or path).
    static func hostOf(_ address: String) -> String? {
        var t = address.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        t = String(t.split(whereSeparator: { "/?#".contains($0) }).first ?? "")
        if let r = t.range(of: #":\d+$"#, options: .regularExpression) { t.removeSubrange(r) }
        let ip = #"^(\d{1,3}\.){3}\d{1,3}$"#
        let name = #"^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$"#
        return t.range(of: ip, options: .regularExpression) != nil || t.range(of: name, options: .regularExpression) != nil ? t : nil
    }

    /// The box's channels paired with the console channels they land on: 1:1 plus the offset, unless a channel was
    /// reassigned (`overrides`: box port id → console port id). Box inputs go to console inputs; console outputs come back.
    static func resolveLink(_ link: StageLink, box: [EquipmentPort], host: [EquipmentPort], overrides: [String: String]) -> [(box: EquipmentPort, host: EquipmentPort, custom: Bool)] {
        var pairs: [(EquipmentPort, EquipmentPort, Bool)] = []
        for b in box where b.cardId == nil && b.direction != .both {
            let target: EquipmentPort?
            if let forced = overrides[b.id] {
                target = host.first { $0.id == forced }
            } else {
                target = host.first { h in
                    h.direction == b.direction && h.cardId == link.hostCardId && h.number != nil && b.number != nil && h.number == b.number! + link.portOffset
                }
            }
            if let target { pairs.append((b, target, overrides[b.id] != nil)) }
        }
        return pairs
    }

    /// Follows the signal from every channel nothing feeds, cable by cable and link by link, to where it ends.
    /// A console's mix is inside it, so chains end at its inputs and new ones start at its outputs.
    static func buildChains(patches: [Patch], hops: [Hop], limit: Int = 2000) -> [SignalChain] {
        struct Edge { var to: PatchPort; var via: SignalChain.Via; var note: String }
        var next: [String: [Edge]] = [:]
        var fed = Set<String>()
        var starts: [String: PatchPort] = [:]
        var order: [String] = []
        func add(_ from: PatchPort, _ e: Edge) { next[from.id, default: []].append(e); fed.insert(e.to.id) }
        for p in patches { add(p.from, Edge(to: p.to, via: .cable, note: p.cable.note)) }
        for h in hops { add(h.from, Edge(to: h.to, via: .link, note: "")) }
        for f in patches.map(\.from) + hops.map(\.from) where !fed.contains(f.id) && starts[f.id] == nil {
            starts[f.id] = f; order.append(f.id)
        }
        var chains: [SignalChain] = []
        func walk(_ stops: [PatchPort], _ via: [SignalChain.Via], _ notes: [String]) {
            guard chains.count < limit, let last = stops.last else { return }
            let edges = (next[last.id] ?? []).filter { e in !stops.contains { $0.id == e.to.id } }
            if edges.isEmpty {
                if stops.count > 1 { chains.append(SignalChain(stops: stops, via: via, notes: notes)) }
                return
            }
            for e in edges { walk(stops + [e.to], via + [e.via], notes + [e.note]) }
        }
        for id in order { if let s = starts[id] { walk([s], [], []) } }
        return chains
    }

    // MARK: Patching advice

    /// For a port on a device with this role and direction, the roles usually on the other end, best first.
    private static let usual: [DeviceRole: (input: [DeviceRole], output: [DeviceRole])] = [
        .console: ([.stageBox, .wirelessReceiver, .source, .processor, .computer, .surface], [.iemTransmitter, .amp, .processor, .stageBox, .computer]),
        .surface: ([.source, .wirelessReceiver], [.amp, .iemTransmitter, .console]),
        .stageBox: ([.source, .wirelessReceiver, .processor], [.iemTransmitter, .amp, .console, .processor]),
        .wirelessReceiver: ([], [.console, .stageBox, .processor]),
        .iemTransmitter: ([.stageBox, .console, .processor], []),
        .source: ([], [.stageBox, .console, .processor]),
        .processor: ([.console, .stageBox, .wirelessReceiver, .source], [.amp, .console, .iemTransmitter, .stageBox]),
        .amp: ([.processor, .console, .stageBox], [.speaker]),
        .speaker: ([.amp], []),
        .videoEncoder: ([.camera, .videoSwitcher, .computer, .source], [.videoDecoder, .networkSwitch]),
        .videoDecoder: ([.videoEncoder, .networkSwitch], [.ledProcessor, .videoSwitcher]),
        .ledProcessor: ([.videoDecoder, .videoSwitcher, .computer, .camera, .source], []),
    ]

    /// How well `other` suits the far end of a cable from `mine`: lower rank is a better match. The warning is
    /// advice only; it never blocks a cable.
    static func peerFit(mineRole: DeviceRole?, direction: PortDirection, signal: Signal, otherRole: DeviceRole?, otherSignal: Signal) -> (rank: Int, warning: String) {
        var rank = 0
        var notes: [String] = []
        if signal != otherSignal {
            rank += 100
            notes.append("\(signal.label) doesn't connect straight to \(otherSignal.label)")
        }
        let list: [DeviceRole]? = mineRole.flatMap { r in
            guard direction != .both, let u = usual[r] else { return nil }
            let l = direction == .input ? u.input : u.output
            return l.isEmpty ? nil : l
        }
        if let list, let otherRole, let mineRole {
            if let at = list.firstIndex(of: otherRole) {
                rank += at
            } else {
                rank += 50
                notes.append("\(mineRole.label) \(direction == .output ? "output" : "input")s don't usually connect to a \(otherRole.label.lowercased())")
            }
        } else {
            rank += 25
        }
        return (rank, notes.isEmpty ? "" : notes.joined(separator: "; ") + ". Fine if that's how it's wired.")
    }

    /// A guess at what a device is from its name, make and model and category. The person confirms every suggestion.
    static func suggestRole(name: String, makeModel: String, category: String) -> DeviceRole? {
        let text = "\(name) \(makeModel)".lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("stage box", "stagebox", "expander", "dx168", "ab168", "gx4816", "rio3224", "rio1608", "dl16", "dl32", "s16") { return .stageBox }
        if has("iem", "psm", "in-ear", "in ear") { return .iemTransmitter }
        if has("receiver", "qlx", "slx", "ulx", "ew-d", "ew-dx") { return .wirelessReceiver }
        if has("dlive"), has("surface") { return .surface }
        if has("dlive", "dm0", "mixrack", "console", "mixer", "x32", "m32", "avantis", "sq-5", "sq-6", "sq-7", "qu-16", "qu-24", "tf1", "tf3", "tf5", "soundcraft", "xr18") {
            return category == "Lighting" ? .lightingConsole : .console
        }
        if has("decoder"), !has("encoder") { return .videoDecoder }
        if has("encoder") { return .videoEncoder }
        if has("novastar", "led processor", "led controller", "colorlight", "mctrl", "vx1000", "vx16s", "vx4s", "vx6s", "mx30", "mx40", "novapro", "splicer") { return .ledProcessor }
        if has("atem", "videohub", "switcher") { return .videoSwitcher }
        if has("ptz", "camera") { return .camera }
        if has("switch", "router") { return .networkSwitch }
        if has("amp", "amplifier") { return .amp }
        if has("speaker", "wedge", "monitor") { return .speaker }
        if has("microphone", " mic", "di box") { return .source }
        if has("hog", "grandma", "chamsys", "light console") { return .lightingConsole }
        if has("dmx", "node", "gateway") { return .lightingNode }
        return nil
    }

    // MARK: Warranty

    enum WarrantyState { case none, active, soon, expired }
    static let warrantySoonDays = 90

    static func warrantyState(_ expires: String?, now: Date = Date()) -> WarrantyState {
        guard let expires, let end = day(expires) else { return .none }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .gmt
        let today = cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: today, to: end).day ?? 0
        return days < 0 ? .expired : days <= warrantySoonDays ? .soon : .active
    }

    // MARK: Formatting

    private static let isoDay = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().dateSeparator(.dash)
    static func day(_ s: String) -> Date? { try? isoDay.parse(s) }
    static func dayString(_ d: Date) -> String { isoDay.format(d) }
    /// A stored "YYYY-MM-DD" as midnight here, and back: what a date picker shows and gives.
    static func localDate(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
    static func localDayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func formatDate(_ s: String?) -> String {
        guard let s, let d = day(s) else { return "—" }
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    static func money(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    static func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : bytes < 1024 * 1024 ? "\(bytes / 1024) KB" : String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    static func counts(_ ports: [EquipmentPort]) -> (inputs: Int, outputs: Int) {
        (ports.filter(\.feedsIn).count, ports.filter(\.feedsOut).count)
    }
}
