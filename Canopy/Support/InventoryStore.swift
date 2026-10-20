import ChurchKitAuth
import Foundation
import Combine
import UniformTypeIdentifiers

// MARK: - Inventory store
// The church's production inventory, read from and written to its Supabase
// project as the signed-in person. It loads the whole church at once (every
// device, channel, card, cable, link, room and rack) so the patch sheet, signal
// flow and system map can follow a signal anywhere, and the campus picker just
// filters what's shown. Every change goes to the database first; the store then
// reloads, so several Macs and the read-only patch sheet on the website always
// agree. The rules here are the ones the website's inventory used.

nonisolated struct InventoryError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What "apply to device" can do for a piece of equipment.
nonisolated enum DeviceDriver: String, Sendable {
    case videohub, ahScene
    var label: String { self == .videohub ? "Blackmagic Videohub" : "Allen & Heath scene recall" }

    static func detect(name: String, makeModel: String) -> DeviceDriver? {
        let text = "\(makeModel) \(name)".lowercased()
        if text.contains("videohub") { return .videohub }
        if text.range(of: #"\bdlive\b|\bavantis\b|\bdm(0|32|48|64)u?\b"#, options: .regularExpression) != nil,
           text.range(of: #"expander|stage ?box|ab168|dx168|gx4816"#, options: .regularExpression) == nil { return .ahScene }
        return nil
    }
}

/// The equipment form: everything a device has that a person types in.
struct EquipmentDraft: Equatable {
    var name = ""
    var category = ""
    var role: DeviceRole?
    var makeModel = ""
    var serial = ""
    var campus = ""
    var status: EquipmentStatus = .inService
    var condition: EquipmentCondition?
    var roomId: String?
    var rackId: String?
    var rackUnit: Int?
    var rackHeight = 1
    var location = ""
    var value: Double?
    var yearPurchased: Int?
    var purchaseDate: Date?
    var purchasePrice: Double?
    var vendor = ""
    var warrantyExpires: Date?
    var warrantyTerms = ""
    var ipAddress = ""
    var macAddress = ""
    var username = ""
    var password = ""
    var notes = ""
    var cardSlots = 0
    var inputs = 0
    var outputs = 0
    /// What new channels carry: `signal`, except the highest-numbered `extraInputs` inputs and `extraOutputs`
    /// outputs, which carry `extraSignal` (a Dante AVIO: analog in, Dante out).
    var signal: Signal?
    var extraInputs = 0
    var extraOutputs = 0
    var extraSignal: Signal?

    init() {}

    init(_ e: Equipment) {
        name = e.name; category = e.category; role = e.role; makeModel = e.makeModel; serial = e.serial; campus = e.campus
        status = e.status; condition = e.condition; roomId = e.roomId; rackId = e.rackId; rackUnit = e.rackUnit; rackHeight = e.rackHeight
        location = e.location; value = e.value; yearPurchased = e.yearPurchased
        purchaseDate = e.purchaseDate.flatMap(InventoryRules.localDate); purchasePrice = e.purchasePrice; vendor = e.vendor
        warrantyExpires = e.warrantyExpires.flatMap(InventoryRules.localDate); warrantyTerms = e.warrantyTerms
        ipAddress = e.ipAddress; macAddress = e.macAddress; username = e.username; password = e.password; notes = e.notes; cardSlots = e.cardSlots
        let own = e.ownPorts
        inputs = own.filter { $0.direction == .input }.compactMap(\.number).max() ?? 0
        outputs = own.filter { $0.direction == .output }.compactMap(\.number).max() ?? 0
    }

    mutating func apply(_ p: EquipmentPreset) {
        name = p.name; makeModel = p.name; category = p.category; role = DeviceRole(rawValue: p.role)
        inputs = p.inputs; outputs = p.outputs; cardSlots = p.cardSlots; value = p.price
        signal = Signal(rawValue: p.signal); extraInputs = p.extraInputs; extraOutputs = p.extraOutputs ?? 0; extraSignal = Signal(rawValue: p.extraSignal)
    }
}

@MainActor
final class InventoryStore: ObservableObject {
    static let shared = InventoryStore()

    // Who and where
    @Published private(set) var level: InventoryLevel = .none
    @Published private(set) var isAdmin = false
    @Published private(set) var churchId = ""
    @Published private(set) var churchSlug = ""
    @Published private(set) var campuses: [Campus] = []
    /// The campus view: "" is every campus, InventoryRules.unassigned is equipment with no campus yet.
    @Published var scope: String = UserDefaults.standard.string(forKey: "inventory.scope") ?? "" {
        didSet { UserDefaults.standard.set(scope, forKey: "inventory.scope") }
    }

    // The system
    @Published private(set) var equipment: [Equipment] = []
    @Published private(set) var cables: [Cable] = []
    @Published private(set) var links: [StageLink] = []
    @Published private(set) var linkMap: [LinkMapEntry] = []
    @Published private(set) var channels: [ConsoleChannel] = []
    @Published private(set) var consolePatch: [ConsolePatch] = []
    /// False until the church's database has the console channel tables.
    @Published private(set) var consoleReady = false
    @Published private(set) var rooms: [Room] = []
    @Published private(set) var racks: [Rack] = []
    @Published private(set) var service: [ServiceEntry] = []
    @Published private(set) var files: [EquipmentFile] = []
    @Published private(set) var presets: [EquipmentPreset] = []
    @Published private(set) var cardTypes: [CardType] = []

    // Derived, rebuilt on every load
    @Published private(set) var byID: [String: Equipment] = [:]
    @Published private(set) var patches: [Patch] = []
    @Published private(set) var hops: [Hop] = []
    @Published private(set) var routes: [Route] = []
    private(set) var portOwner: [String: String] = [:]
    private(set) var roomsByID: [String: Room] = [:]
    private(set) var racksByID: [String: Rack] = [:]

    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var loadedOnce = false

    private var db: SupabaseClient {
        get throws {
            guard let c = SiteAccount.shared.client else { throw InventoryError("Sign in to your church first.") }
            return c
        }
    }

    // MARK: Loading

    private nonisolated struct Membership: Decodable {
        nonisolated struct Church: Decodable { var id: String; var slug: String; var campuses: [Campus]? }
        var role: String
        var inventory: String?
        var churches: Church?
    }

    private nonisolated struct EquipmentRow: Decodable {
        var id: String; var name: String; var category: String; var role: String; var makeModel: String; var serial: String
        var location: String; var campus: String; var value: Double?; var yearPurchased: Int?; var ipAddress: String; var macAddress: String
        var username: String; var password: String; var notes: String; var status: String; var condition: String
        var purchaseDate: String?; var purchasePrice: Double?; var vendor: String; var warrantyExpires: String?
        var warrantyTerms: String; var roomId: String?; var rackId: String?; var rackUnit: Int?; var rackHeight: Int; var cardSlots: Int
    }

    private static let equipmentColumns = "id,name,category,role,make_model,serial,location,campus,value,year_purchased,ip_address,mac_address,username,password,notes,status,condition,purchase_date,purchase_price,vendor,warranty_expires,warranty_terms,room_id,rack_id,rack_unit,rack_height,card_slots"
    private static let portColumns = "id,equipment_id,number,label,kind,direction,signal,card_id"

    func refresh() async {
        guard SiteAccount.shared.isConnected else { clear(); return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await load()
            error = nil
            loadedOnce = true
        } catch {
            handle(error)
        }
    }

    private func handle(_ error: Error) {
        if let e = error as? SupabaseError, e.status == 401 { SiteAccount.shared.sessionExpired(); clear(); return }
        self.error = error.localizedDescription
    }

    private func load() async throws {
        let db = try db
        let uid = db.session.userID
        guard let me = try await db.select("church_members", "role,inventory,churches(id,slug,campuses:site->campuses)",
                                           [.eq("user_id", uid)], as: Membership.self).first, let church = me.churches else {
            throw InventoryError("\(db.session.email) isn't part of a church yet. Ask an admin to invite you.")
        }
        let admin = me.role == "owner" || me.role == "admin"
        let lvl = admin ? .edit : InventoryLevel(rawValue: me.inventory ?? "none") ?? .none
        guard lvl != .none else { throw InventoryError("You don't have inventory access. Ask an admin to give you access on the website's Team page.") }

        let cid = church.id
        let mine = [Filter.eq("church_id", cid)]
        async let eqRows = db.select("equipment", Self.equipmentColumns, mine + [.order("name")], as: EquipmentRow.self)
        async let portRows = db.select("equipment_ports", Self.portColumns, mine, as: EquipmentPort.self)
        async let cardRows = db.select("equipment_cards", "id,equipment_id,slot,name,signal,inputs,outputs", mine, as: CardRow.self)
        async let cableRows = db.select("equipment_connections", "id,from_port,to_port,note", mine, as: Cable.self)
        async let linkRows = db.select("equipment_links", "id,equipment_id,host_id,host_card_id,signal,port_offset", mine, as: StageLink.self)
        async let mapRows = db.select("equipment_link_map", "link_id,box_port,host_port", mine, as: LinkMapEntry.self)
        async let roomRows = db.select("equipment_rooms", "id,name,campus", mine, as: Room.self)
        async let rackRows = db.select("equipment_racks", "id,room_id,name,units", mine, as: Rack.self)
        async let presetRows = Self.loadPresets(db)
        async let typeRows = db.select("equipment_card_types", "id,name,brand,signal,inputs,outputs", [.order("sort_order,name")], as: CardType.self)
        async let channelRows = db.select("console_channels", "id,equipment_id,kind,number,label", mine, as: ConsoleChannel.self)
        async let consolePatchRows = db.select("console_patch", "id,channel_id,port_id", mine, as: ConsolePatch.self)

        let (e, p, c, k, l, m, r, rk) = try await (eqRows, portRows, cardRows, cableRows, linkRows, mapRows, roomRows, rackRows)
        // Catalogs are nice-to-have: the inventory still works without them.
        let pr = (try? await presetRows) ?? []
        let ct = (try? await typeRows) ?? []
        // The console channel tables came later; without them the rest of the inventory still works.
        let ch = try? await channelRows
        let cp = try? await consolePatchRows
        // Prices and service costs need "view"; config files are for owners and admins.
        let sv: [ServiceEntry] = lvl.canViewDetails
            ? ((try? await db.select("equipment_service", "id,equipment_id,kind,performed_on,summary,cost,vendor", mine + [.order("performed_on.desc,created_at.desc")])) ?? [])
            : []
        let fl: [EquipmentFile] = admin
            ? ((try? await db.select("equipment_files", "id,equipment_id,name,size,created_at", mine + [.order("created_at.desc")])) ?? [])
            : []

        let portsBy = Dictionary(grouping: p, by: \.equipmentId)
        let cardsBy = Dictionary(grouping: c, by: \.equipmentId)
        let devices = e.map { row in
            Equipment(id: row.id, name: row.name, category: row.category, role: DeviceRole(rawValue: row.role), makeModel: row.makeModel,
                      serial: row.serial, location: row.location, campus: row.campus, value: row.value, yearPurchased: row.yearPurchased,
                      ipAddress: row.ipAddress, macAddress: row.macAddress, username: row.username, password: row.password, notes: row.notes,
                      status: EquipmentStatus(rawValue: row.status) ?? .inService, condition: EquipmentCondition(rawValue: row.condition),
                      purchaseDate: row.purchaseDate, purchasePrice: row.purchasePrice, vendor: row.vendor,
                      warrantyExpires: row.warrantyExpires, warrantyTerms: row.warrantyTerms, roomId: row.roomId, rackId: row.rackId,
                      rackUnit: row.rackUnit, rackHeight: row.rackHeight, cardSlots: row.cardSlots,
                      cards: (cardsBy[row.id] ?? []).map(\.card).sorted { $0.slot < $1.slot },
                      ports: (portsBy[row.id] ?? []).sorted(by: InventoryRules.byPort))
        }.sorted { InventoryRules.ordered($0.name, $1.name) }

        level = lvl; isAdmin = admin; churchId = cid; churchSlug = church.slug
        campuses = church.campuses ?? []
        if !scope.isEmpty, scope != InventoryRules.unassigned, !campuses.contains(where: { $0.id == scope }) { scope = "" }
        equipment = devices; cables = k; links = l; linkMap = m
        channels = (ch ?? []).sorted { ($0.equipmentId, $0.kind.rawValue, $0.number) < ($1.equipmentId, $1.kind.rawValue, $1.number) }
        consolePatch = cp ?? []; consoleReady = ch != nil && cp != nil
        rooms = r.sorted { InventoryRules.ordered($0.name, $1.name) }; racks = rk.sorted { InventoryRules.ordered($0.name, $1.name) }
        service = sv; files = fl; presets = pr; cardTypes = ct
        rebuild()
    }

    private nonisolated struct CardRow: Decodable {
        var id: String; var equipmentId: String; var slot: Int; var name: String; var signal: Signal; var inputs: Int; var outputs: Int
        var card: OptionCard { OptionCard(id: id, slot: slot, name: name, signal: signal, inputs: inputs, outputs: outputs) }
    }

    private func rebuild() {
        byID = Dictionary(uniqueKeysWithValues: equipment.map { ($0.id, $0) })
        roomsByID = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0) })
        racksByID = Dictionary(uniqueKeysWithValues: racks.map { ($0.id, $0) })
        var owner: [String: String] = [:]
        var patchPorts: [String: PatchPort] = [:]
        for e in equipment {
            let place = InventoryRules.placeLabel(e, rooms: roomsByID, racks: racksByID)
            for p in e.ports { owner[p.id] = e.id; patchPorts[p.id] = PatchPort(port: p, device: e, place: place) }
        }
        portOwner = owner
        patches = cables.compactMap { c in
            guard let f = patchPorts[c.fromPort], let t = patchPorts[c.toPort] else { return nil }
            return Patch(cable: c, from: f, to: t)
        }.sorted { a, b in
            if a.from.device.name != b.from.device.name { return InventoryRules.ordered(a.from.device.name, b.from.device.name) }
            return InventoryRules.byPort(a.from.port, b.from.port)
        }
        let overrides = Dictionary(grouping: linkMap, by: \.linkId).mapValues { Dictionary($0.map { ($0.boxPort, $0.hostPort) }, uniquingKeysWith: { $1 }) }
        // Console channels already in use (a cable into an input or out of an output, or a box channel reassigned onto
        // it): a box's default landing doesn't stack on top of them.
        let taken = Set(cables.flatMap { [$0.fromPort, $0.toPort] } + linkMap.map(\.hostPort))
        hops = links.flatMap { l -> [Hop] in
            guard let box = byID[l.equipmentId], let host = byID[l.hostId], InventoryRules.landsChannels(box: box.role, host: host.role) else { return [] }
            return InventoryRules.resolveLink(l, box: box.ports, host: host.ports, overrides: overrides[l.id] ?? [:], taken: taken).compactMap { pair in
                guard let b = patchPorts[pair.box.id], let h = patchPorts[pair.host.id] else { return nil }
                // Inputs flow from the box to the console; the console's outputs flow back out to the box's outputs.
                return pair.box.direction == .input ? Hop(from: b, to: h, custom: pair.custom, linkId: l.id) : Hop(from: h, to: b, custom: pair.custom, linkId: l.id)
            }
        }
        // The internal patch, as signal flow. A stage box socket whose channel lands on the console is followed through
        // the console channel it lands on, so the path reads box → link → console → channel.
        var landedOn: [String: PatchPort] = [:], landedFrom: [String: PatchPort] = [:]
        for h in hops {
            if h.from.port.direction == .input { landedOn[h.from.id] = h.to } else { landedFrom[h.to.id] = h.from }
        }
        let channelByID = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
        routes = consolePatch.compactMap { p in
            guard let ch = channelByID[p.channelId], let console = byID[ch.equipmentId], let socket = patchPorts[p.portId] else { return nil }
            let strip = PatchPort(port: ch.asPort, device: console, place: InventoryRules.placeLabel(console, rooms: roomsByID, racks: racksByID))
            if ch.kind == .input {
                let from = landedOn[socket.id].flatMap { $0.device.id == console.id ? $0 : nil } ?? socket
                return Route(from: from, to: strip, channelId: ch.id)
            }
            let to = landedFrom[socket.id].flatMap { $0.device.id == console.id ? $0 : nil } ?? socket
            return Route(from: strip, to: to, channelId: ch.id)
        }
    }

    func clear() {
        level = .none; isAdmin = false; churchId = ""; churchSlug = ""; campuses = []
        equipment = []; cables = []; links = []; linkMap = []; rooms = []; racks = []; service = []; files = []
        channels = []; consolePatch = []; consoleReady = false
        byID = [:]; patches = []; hops = []; routes = []; portOwner = [:]; roomsByID = [:]; racksByID = [:]
        error = nil; loadedOnce = false
    }

    // MARK: Views of the data

    func inScope(_ e: Equipment) -> Bool { InventoryRules.inCampus(scope, e.campus) }
    var scoped: [Equipment] { equipment.filter(inScope) }
    var scopedPatches: [Patch] { patches.filter { inScope($0.from.device) || inScope($0.to.device) } }
    var scopedHops: [Hop] { hops.filter { inScope($0.from.device) || inScope($0.to.device) } }
    var scopedRoutes: [Route] { routes.filter { inScope($0.from.device) || inScope($0.to.device) } }
    var scopedRooms: [Room] { rooms.filter { InventoryRules.inCampus(scope, $0.campus) } }
    var hasUnassigned: Bool { equipment.contains { $0.campus.isEmpty } }

    func campusName(_ id: String) -> String {
        id.isEmpty ? "No campus yet" : campuses.first { $0.id == id }?.name ?? id
    }
    var scopeName: String {
        scope.isEmpty ? "All campuses" : scope == InventoryRules.unassigned ? "No campus yet" : campusName(scope)
    }

    func place(_ e: Equipment) -> String { InventoryRules.placeLabel(e, rooms: roomsByID, racks: racksByID) }
    func port(_ id: String) -> (Equipment, EquipmentPort)? {
        guard let eid = portOwner[id], let e = byID[eid], let p = e.ports.first(where: { $0.id == id }) else { return nil }
        return (e, p)
    }
    func cables(of e: Equipment) -> [Cable] {
        let ids = Set(e.ports.map(\.id))
        return cables.filter { ids.contains($0.fromPort) || ids.contains($0.toPort) }
    }
    func cable(at portID: String) -> [Cable] { cables.filter { $0.fromPort == portID || $0.toPort == portID } }
    func link(asBox e: Equipment) -> StageLink? { links.first { $0.equipmentId == e.id } }
    func links(asHost e: Equipment) -> [StageLink] { links.filter { $0.hostId == e.id } }
    func service(of e: Equipment) -> [ServiceEntry] { service.filter { $0.equipmentId == e.id } }
    func files(of e: Equipment) -> [EquipmentFile] { files.filter { $0.equipmentId == e.id } }
    func racks(in room: Room) -> [Rack] { racks.filter { $0.roomId == room.id } }
    func devices(in rack: Rack) -> [Equipment] { equipment.filter { $0.rackId == rack.id } }
    var totalValue: Double { scoped.compactMap(\.value).reduce(0, +) }

    /// Channels carried over stage box links, keyed by this device's own port: what's on the other end, and any clash.
    struct Feed { var text: String; var conflict: Bool; var linkId: String; var custom: Bool; var hostPortId: String?; var boxPortId: String? }
    func feeds(for e: Equipment) -> [String: Feed] {
        let linkByID = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })
        var claimed: [String: Int] = [:] // console channel id → how many box channels land on it
        for h in hops {
            guard let l = linkByID[h.linkId] else { continue }
            claimed[h.from.device.id == l.hostId ? h.from.id : h.to.id, default: 0] += 1
        }
        var out: [String: Feed] = [:]
        for h in hops {
            guard let l = linkByID[h.linkId] else { continue }
            let boxSide = h.from.device.id == l.equipmentId ? h.from : h.to
            let hostSide = boxSide.id == h.from.id ? h.to : h.from
            let clash = (claimed[hostSide.id] ?? 0) > 1
            if boxSide.device.id == e.id {
                out[boxSide.id] = Feed(text: "\(boxSide.port.direction == .input ? "→" : "←") \(hostSide.device.name) · \(hostSide.name)",
                                       conflict: clash, linkId: l.id, custom: h.custom, hostPortId: hostSide.id, boxPortId: nil)
            }
            if hostSide.device.id == e.id {
                let text = "\(hostSide.port.direction == .input ? "←" : "→") \(boxSide.device.name) · \(boxSide.port.name())"
                if let seen = out[hostSide.id] { out[hostSide.id] = Feed(text: "\(seen.text); \(text)", conflict: true, linkId: l.id, custom: false, hostPortId: nil, boxPortId: nil) }
                else { out[hostSide.id] = Feed(text: text, conflict: clash, linkId: l.id, custom: false, hostPortId: nil, boxPortId: boxSide.id) }
            }
        }
        return out
    }

    /// For the patch picker: every port on other devices that could take a cable from `port`, best match first.
    struct Candidate: Identifiable { var device: Equipment; var port: EquipmentPort; var rank: Int; var warning: String; var id: String { port.id } }
    func candidates(for port: EquipmentPort, on device: Equipment) -> [Candidate] {
        let mineSignal = port.signal
        return equipment.filter { $0.id != device.id && InventoryRules.inCampus(device.campus, $0.campus) }.flatMap { other in
            other.ports.filter { p in
                port.direction == .both ? true : port.direction == .output ? p.feedsIn : p.feedsOut
            }.map { p -> Candidate in
                let fit = InventoryRules.peerFit(mineRole: device.role, direction: port.direction, signal: mineSignal, otherRole: other.role, otherSignal: p.signal)
                return Candidate(device: other, port: p, rank: fit.rank, warning: fit.warning)
            }
        }
    }

    // MARK: Console channels

    func channels(of e: Equipment, _ kind: ChannelKind) -> [ConsoleChannel] { channels.filter { $0.equipmentId == e.id && $0.kind == kind } }
    /// Consoles with channels to patch: every mixing console, and anything else that has channels already.
    var consoles: [Equipment] {
        let having = Set(channels.map(\.equipmentId))
        return scoped.filter { $0.role == .console || having.contains($0.id) }
    }
    /// The sockets a channel uses: its source, or where a mix goes.
    func sockets(of channel: ConsoleChannel) -> [(patch: ConsolePatch, device: Equipment, port: EquipmentPort)] {
        consolePatch.filter { $0.channelId == channel.id }.compactMap { p in port(p.portId).map { (p, $0.0, $0.1) } }
            .sorted { InventoryRules.byPort($0.port, $1.port) }
    }
    /// Console channels patched to a socket, for showing beside the socket.
    func channels(at portID: String) -> [(console: Equipment, channel: ConsoleChannel)] {
        let ids = Set(consolePatch.filter { $0.portId == portID }.map(\.channelId))
        return channels.filter { ids.contains($0.id) }.compactMap { c in byID[c.equipmentId].map { ($0, c) } }
    }

    /// The controller a surface (or a box on one) is attached to, if any.
    func controller(of e: Equipment) -> Equipment? {
        guard let host = link(asBox: e).flatMap({ byID[$0.hostId] }) else { return nil }
        return host.role == .surface ? controller(of: host) : host
    }

    /// One place a console can take signal from or send it to: its own sockets, an option card, or a device linked to it.
    struct SocketGroup: Identifiable {
        var id: String
        var title: String
        var detail: String
        var device: Equipment
        var ports: [EquipmentPort]
    }

    /// Every socket a console's channels can be patched to, grouped the way the desk lists them: its own, each card,
    /// then the stage boxes and surfaces linked to it (and the boxes plugged into those surfaces).
    func socketGroups(for console: Equipment, _ kind: ChannelKind) -> [SocketGroup] {
        let fits: (EquipmentPort) -> Bool = { kind == .input ? $0.feedsIn : $0.feedsOut }
        var out = [SocketGroup(id: console.id, title: "Local", detail: console.name, device: console, ports: console.ownPorts.filter(fits))]
        for card in console.cards {
            out.append(SocketGroup(id: card.id, title: card.label, detail: card.signal.label, device: console,
                                   ports: console.ports.filter { $0.cardId == card.id && fits($0) }))
        }
        func linked(to host: Equipment, depth: Int) {
            let attached = links(asHost: host).compactMap { l in byID[l.equipmentId].map { (l, $0) } }
                .sorted { ($0.1.role == .surface ? 1 : 0, $0.1.name) < ($1.1.role == .surface ? 1 : 0, $1.1.name) }
            for (l, d) in attached {
                var bits = [d.role?.label ?? "Linked", l.signal.label]
                if let card = host.card(l.hostCardId) { bits.append("via \(card.label)") }
                if host.id != console.id { bits.append("on \(host.name)") }
                out.append(SocketGroup(id: d.id, title: d.name, detail: bits.joined(separator: " · "), device: d, ports: d.ports.filter(fits)))
                if depth < 2, d.role == .surface { linked(to: d, depth: depth + 1) }
            }
        }
        linked(to: console, depth: 0)
        return out.filter { !$0.ports.isEmpty }
    }

    /// What's plugged into a socket from outside: "← Mic 4 · 1. SM58", or nil when nothing is.
    func upstream(of portID: String) -> String? {
        if let c = cables.first(where: { $0.toPort == portID }), let from = port(c.fromPort) { return "\(from.0.name) · \(from.0.portName(from.1))" }
        if let h = hops.first(where: { $0.to.id == portID && $0.to.port.direction == .input }) { return "\(h.from.device.name) · \(h.from.name)" }
        return nil
    }

    /// Where a socket goes from here: "→ Amp 2 · Input 1", or nil.
    func downstream(of portID: String) -> String? {
        let outs = cables.filter { $0.fromPort == portID }.compactMap { port($0.toPort) }.map { "\($0.0.name) · \($0.0.portName($0.1))" }
        let hopped = hops.filter { $0.from.id == portID && $0.from.port.direction == .output }.map { "\($0.to.device.name) · \($0.to.name)" }
        let all = outs + hopped
        return all.isEmpty ? nil : all.joined(separator: ", ")
    }

    // MARK: Changing things

    private func editor() throws -> SupabaseClient {
        guard level.canEdit else { throw InventoryError("You can't change the inventory. Ask an admin.") }
        return try db
    }

    /// Runs a change, then reloads. Errors come back as a message to show.
    @discardableResult
    func run(_ change: () async throws -> String) async -> (ok: Bool, message: String) {
        do {
            let message = try await change()
            try? await load()
            return (true, message)
        } catch let e as SupabaseError where e.status == 401 {
            SiteAccount.shared.sessionExpired(); clear()
            return (false, e.message)
        } catch {
            try? await load()
            return (false, error.localizedDescription)
        }
    }

    private static let uuid = #"^[0-9a-fA-F-]{36}$"#

    private func row(_ d: EquipmentDraft) throws -> [String: Any?] {
        let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw InventoryError("Give the equipment a name.") }
        if let v = d.value, v < 0 { throw InventoryError("Value must be a dollar amount.") }
        if let v = d.purchasePrice, v < 0 { throw InventoryError("The price paid must be a dollar amount.") }
        // A purchase date says which year it was bought, so it wins over a typed year.
        let year = d.purchaseDate.map { Calendar.current.component(.year, from: $0) } ?? d.yearPurchased
        if let year, !(1900...2100).contains(year) { throw InventoryError("Enter a four-digit year.") }
        if !d.campus.isEmpty, !campuses.contains(where: { $0.id == d.campus }) { throw InventoryError("Pick one of your campuses.") }
        guard (0...16).contains(d.cardSlots) else { throw InventoryError("Card slots must be a whole number from 0 to 16.") }
        func t(_ s: String, _ max: Int = 200) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max)) }
        return [
            "name": t(name), "campus": d.campus, "category": t(d.category, 60), "role": d.role?.rawValue ?? "", "card_slots": d.cardSlots,
            "make_model": t(d.makeModel), "serial": t(d.serial), "location": t(d.location), "value": d.value, "year_purchased": year,
            "status": d.status.rawValue, "condition": d.condition?.rawValue ?? "",
            "purchase_date": d.purchaseDate.map(InventoryRules.localDayString), "purchase_price": d.purchasePrice, "vendor": t(d.vendor),
            "warranty_expires": d.warrantyExpires.map(InventoryRules.localDayString), "warranty_terms": t(d.warrantyTerms, 1000),
            "ip_address": t(d.ipAddress, 100), "mac_address": t(d.macAddress, 100), "username": t(d.username), "password": String(d.password.prefix(500)), "notes": String(d.notes.prefix(4000)),
        ]
    }

    /// The room, rack and unit of the form, checked: a rack decides the room, the room must be in the device's campus,
    /// and the unit must fit the rack and not overlap anything else in it.
    private func placement(_ d: EquipmentDraft, selfID: String = "") async throws -> [String: Any?] {
        let none: [String: Any?] = ["room_id": nil, "rack_id": nil, "rack_unit": nil, "rack_height": 1]
        var roomID = d.roomId
        var units = 0
        if let rackID = d.rackId {
            guard let rack = racks.first(where: { $0.id == rackID }) else { throw InventoryError("Pick a rack from the list.") }
            roomID = rack.roomId
            units = rack.units
        }
        guard let roomID else { return none }
        guard let room = rooms.first(where: { $0.id == roomID }) else { throw InventoryError("Pick a room from the list.") }
        guard room.campus == d.campus else { throw InventoryError("That room is in a different campus. Pick a room from this campus, or change the campus.") }
        guard let rackID = d.rackId else { return ["room_id": roomID, "rack_id": nil, "rack_unit": nil, "rack_height": 1] }
        guard (1...units).contains(d.rackHeight) else { throw InventoryError("Height must be a whole number from 1 to \(units).") }
        if let unit = d.rackUnit { try await checkFit(rackID: rackID, units: units, unit: unit, height: d.rackHeight, selfID: selfID) }
        return ["room_id": roomID, "rack_id": rackID, "rack_unit": d.rackUnit, "rack_height": d.rackHeight]
    }

    private func checkFit(rackID: String, units: Int, unit: Int, height: Int, selfID: String) async throws {
        guard (1...max(1, units)).contains(height) else { throw InventoryError("Height must be a whole number from 1 to \(units).") }
        guard unit >= 1, unit + height - 1 <= units else { throw InventoryError("That doesn't fit: this rack has \(units) units, counted from 1 at the bottom.") }
        nonisolated struct R: Decodable { var id: String; var name: String; var rackUnit: Int; var rackHeight: Int }
        let inRack = try await db.select("equipment", "id,name,rack_unit,rack_height", [.eq("rack_id", rackID), .notNull("rack_unit")], as: R.self)
        if let hit = inRack.first(where: { $0.id != selfID && $0.rackUnit <= unit + height - 1 && unit <= $0.rackUnit + $0.rackHeight - 1 }) {
            throw InventoryError("\(hit.name) is already in \(InventoryRules.rackSpan(unit: hit.rackUnit, height: hit.rackHeight)).")
        }
    }

    /// The "Start from" list. Falls back to the older columns while the database lacks extra_outputs.
    nonisolated private static func loadPresets(_ db: SupabaseClient) async throws -> [EquipmentPreset] {
        let columns = "category,brand,model,inputs,outputs,price,role,signal,extra_inputs,extra_signal,card_slots"
        let order: [Filter] = [.order("sort_order,brand,model")]
        if let rows = try? await db.select("equipment_presets", columns + ",extra_outputs", order, as: EquipmentPreset.self) { return rows }
        return try await db.select("equipment_presets", columns, order, as: EquipmentPreset.self)
    }

    /// Makes a device have exactly `inputs` input and `outputs` output channels of its own, numbered from 1. New
    /// channels start unnamed; lowering a count removes the highest-numbered channels and their cables.
    private func syncPorts(_ equipmentID: String, _ d: EquipmentDraft) async throws {
        let db = try editor()
        guard (0...256).contains(d.inputs), (0...256).contains(d.outputs) else { throw InventoryError("Inputs and outputs must be a whole number from 0 to 256.") }
        nonisolated struct R: Decodable { var id: String; var number: Int?; var label: String; var direction: PortDirection }
        let all = try await db.select("equipment_ports", "id,number,label,direction", [.eq("equipment_id", equipmentID), .isNull("card_id")], as: R.self)
        let signal = d.signal ?? Signal.default(for: d.category)
        let extra = d.extraSignal ?? signal
        for (direction, count) in [(PortDirection.input, d.inputs), (.output, d.outputs)] {
            var mine = all.filter { $0.direction == direction }
                .sorted { ($0.number ?? .max, $0.label) < ($1.number ?? .max, $1.label) }
            var taken = Set(mine.compactMap(\.number))
            var next = 1
            for i in mine.indices where mine[i].number == nil {
                while taken.contains(next) { next += 1 } // ports made before channel numbers existed get the next free number
                mine[i].number = next
                taken.insert(next)
                try await db.update("equipment_ports", ["number": next], [.eq("id", mine[i].id)])
            }
            let doomed = mine.filter { ($0.number ?? 0) > count }.map(\.id)
            if !doomed.isEmpty { try await db.delete("equipment_ports", [.in("id", doomed)]) }
            let rows: [[String: Any?]] = (1...max(1, count)).filter { count > 0 && !taken.contains($0) }.map { n in
                let isExtra = n > count - (direction == .input ? d.extraInputs : d.extraOutputs)
                return ["church_id": churchId, "equipment_id": equipmentID, "number": n, "label": "", "direction": direction.rawValue,
                        "signal": (isExtra ? extra : signal).rawValue]
            }
            if !rows.isEmpty { _ = try await db.insert("equipment_ports", rows) }
        }
    }

    /// Adds a device and returns its id.
    func createEquipment(_ d: EquipmentDraft) async throws -> String {
        let db = try editor()
        var values = try row(d)
        for (k, v) in try await placement(d) { values[k] = v }
        values["church_id"] = churchId
        guard let id = try await db.insertIDs("equipment", [values]).first else { throw InventoryError("Couldn't save that.") }
        try await syncPorts(id, d)
        try await load()
        return id
    }

    func updateEquipment(_ id: String, _ d: EquipmentDraft) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            var values = try row(d)
            if let card = byID[id]?.cards.first(where: { $0.slot > d.cardSlots }) {
                throw InventoryError("There's a card in slot \(card.slot). Remove it before reducing the card slots.")
            }
            for (k, v) in try await placement(d, selfID: id) { values[k] = v }
            try await db.update("equipment", values, [.eq("id", id)])
            try await syncPorts(id, d)
            return "Saved."
        }
    }

    func deleteEquipment(_ id: String) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            // Attached files live in storage, outside the database's cascade, so clear them out first.
            let paths = files.filter { $0.equipmentId == id }.map { "\(churchId)/\(id)/\($0.id)" }
            try? await db.remove(bucket: "equipment-files", paths: paths)
            try await db.delete("equipment", [.eq("id", id)])
            return "Deleted."
        }
    }

    func setAddress(_ id: String, _ address: String) async -> (ok: Bool, message: String) {
        await run {
            guard let host = InventoryRules.hostOf(address) else { throw InventoryError("That isn't a valid IP address or host name.") }
            try await editor().update("equipment", ["ip_address": host], [.eq("id", id)])
            return "Saved \(host) as its address."
        }
    }

    func setRole(_ id: String, _ role: DeviceRole?) async -> (ok: Bool, message: String) {
        await run { try await editor().update("equipment", ["role": role?.rawValue ?? ""], [.eq("id", id)]); return "Saved." }
    }

    func setRoles(_ items: [(id: String, role: DeviceRole)]) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard !items.isEmpty else { throw InventoryError("There's nothing to apply.") }
            for item in items { try await db.update("equipment", ["role": item.role.rawValue], [.eq("id", item.id)]) }
            return "Set the type of \(items.count) \(items.count == 1 ? "device" : "devices")."
        }
    }

    func setStatus(_ id: String, _ status: EquipmentStatus) async -> (ok: Bool, message: String) {
        await run { try await editor().update("equipment", ["status": status.rawValue], [.eq("id", id)]); return "Saved." }
    }

    // Channels

    func updatePort(_ id: String, label: String? = nil, kind: String? = nil, signal: Signal? = nil) async -> (ok: Bool, message: String) {
        await run {
            var values: [String: Any?] = [:]
            if let label { values["label"] = String(label.trimmingCharacters(in: .whitespaces).prefix(80)) }
            if let kind { values["kind"] = String(kind.trimmingCharacters(in: .whitespaces).prefix(60)) }
            if let signal { values["signal"] = signal.rawValue }
            try await editor().update("equipment_ports", values, [.eq("id", id)])
            return "Saved."
        }
    }

    /// Adds one channel on the next free number of its direction, on the device itself or one of its option cards.
    /// A card's channel carries the card's signal.
    func addPort(_ equipmentID: String, direction: PortDirection, cardID: String? = nil) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard let e = byID[equipmentID] else { throw InventoryError("That device no longer exists.") }
            let mine = e.ports.filter { $0.direction == direction && $0.cardId == cardID }
            guard mine.count < 256 else { throw InventoryError("A device can have up to 256 of each.") }
            let taken = Set(mine.compactMap(\.number))
            var n = 1
            while taken.contains(n) { n += 1 }
            let signal = cardID.flatMap { id in e.cards.first { $0.id == id }?.signal } ?? mine.last?.signal ?? Signal.default(for: e.category)
            _ = try await db.insert("equipment_ports", [["church_id": churchId, "equipment_id": equipmentID, "card_id": cardID, "number": n,
                                                          "label": "", "direction": direction.rawValue, "signal": signal.rawValue]])
            return "Added \(direction == .input ? "input" : direction == .output ? "output" : "port") \(n)."
        }
    }

    /// Removes one channel, with its cables and any console patch that uses it.
    func removePort(_ id: String) async -> (ok: Bool, message: String) {
        await run { try await editor().delete("equipment_ports", [.eq("id", id)]); return "Channel removed." }
    }

    /// Changes what all of a device's own channels carry (an option card's channels follow the card).
    func setDeviceSignal(_ equipmentID: String, _ signal: Signal) async -> (ok: Bool, message: String) {
        await run {
            try await editor().update("equipment_ports", ["signal": signal.rawValue], [.eq("equipment_id", equipmentID), .isNull("card_id")])
            return "Saved."
        }
    }

    // Option cards

    func addCard(_ equipmentID: String, slot: Int, type: CardType) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard let device = byID[equipmentID], (1...max(1, device.cardSlots)).contains(slot), device.cardSlots > 0 else {
                throw InventoryError("That slot doesn't exist on this device.")
            }
            let cardID: String
            do {
                cardID = try await db.insertIDs("equipment_cards", [["church_id": churchId, "equipment_id": equipmentID, "slot": slot, "name": type.name,
                                                                     "signal": type.signal.rawValue, "inputs": type.inputs, "outputs": type.outputs]])[0]
            } catch let e as SupabaseError where e.isUnique { throw InventoryError("That slot already has a card.") }
            let rows: [[String: Any?]] = [(PortDirection.input, type.inputs), (.output, type.outputs)].flatMap { dir, n in
                (0..<n).map { i in ["church_id": churchId, "equipment_id": equipmentID, "card_id": cardID, "number": i + 1, "label": "",
                                    "direction": dir.rawValue, "signal": type.signal.rawValue] }
            }
            do {
                for start in stride(from: 0, to: rows.count, by: 500) { _ = try await db.insert("equipment_ports", Array(rows[start..<min(rows.count, start + 500)])) }
            } catch {
                try? await db.delete("equipment_cards", [.eq("id", cardID)]) // takes any channels already made with it
                throw InventoryError("Couldn't set up that card's channels.")
            }
            return "Added \(type.name) in slot \(slot)."
        }
    }

    func removeCard(_ cardID: String) async -> (ok: Bool, message: String) {
        await run { try await editor().delete("equipment_cards", [.eq("id", cardID)]); return "Card removed." }
    }

    // Cables

    /// Patches a channel to another device's channel, replacing the cable it had (`previous`). A cable is stored output
    /// to input whichever end you started from. An input takes one source, and an output takes one cable unless it's
    /// audio over a network (Dante, AVB, SoundGrid), which any number of inputs can subscribe to.
    func patch(_ mine: String, to other: String, replacing previous: String? = nil) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard let a = port(mine)?.1, let b = port(other)?.1 else { throw InventoryError("One of those channels no longer exists.") }
            if a.direction == b.direction, a.direction != .both {
                throw InventoryError(a.direction == .input ? "An input can only be fed by an output." : "An output can only feed an input.")
            }
            if let previous { try await db.delete("equipment_connections", [.eq("id", previous)]) }
            let (from, to) = a.direction == .output || b.direction == .input ? (a, b) : (b, a)
            if to.direction == .input { try await db.delete("equipment_connections", [.eq("to_port", to.id)]) }
            if from.direction == .output, !from.signal.fansOut { try await db.delete("equipment_connections", [.eq("from_port", from.id)]) }
            do {
                _ = try await db.insert("equipment_connections", [["church_id": churchId, "from_port": from.id, "to_port": to.id]])
            } catch let e as SupabaseError where e.isUnique { throw InventoryError("Those are already connected.") }
            return "Connected."
        }
    }

    func disconnect(_ cableID: String) async -> (ok: Bool, message: String) {
        await run { try await editor().delete("equipment_connections", [.eq("id", cableID)]); return "Disconnected." }
    }

    /// Disconnects several cables with one reload.
    func disconnect(all cableIDs: [String]) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            for id in cableIDs { try await db.delete("equipment_connections", [.eq("id", id)]) }
            return "Disconnected \(cableIDs.count) \(cableIDs.count == 1 ? "cable" : "cables")."
        }
    }

    func setCableNote(_ cableID: String, _ note: String) async -> (ok: Bool, message: String) {
        await run { try await editor().update("equipment_connections", ["note": String(note.prefix(500))], [.eq("id", cableID)]); return "Saved." }
    }

    // Stage box links

    /// Connects a stage box to a console, through its own ports (`cardID` nil) or one of its option cards. Box channel
    /// N lands on console channel N + offset. Pointing the box somewhere else drops any reassigned channels.
    func setLink(box: String, host: String, cardID: String?, signal: Signal, offset: Int) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard box != host else { throw InventoryError("A device can't be connected to itself.") }
            guard (0...1024).contains(offset) else { throw InventoryError("The first console channel must be a whole number from 1 up.") }
            var linkSignal = signal
            if let cardID {
                guard let card = byID[host]?.cards.first(where: { $0.id == cardID }) else { throw InventoryError("That card isn't in this console.") }
                linkSignal = card.signal
            }
            if let previous = links.first(where: { $0.equipmentId == box }), previous.hostId != host || previous.hostCardId != cardID {
                try await db.delete("equipment_link_map", [.eq("link_id", previous.id)])
            }
            _ = try await db.upsert("equipment_links", ["church_id": churchId, "equipment_id": box, "host_id": host, "host_card_id": cardID,
                                                        "signal": linkSignal.rawValue, "port_offset": offset], onConflict: "equipment_id")
            return "Connected."
        }
    }

    func removeLink(_ id: String) async -> (ok: Bool, message: String) {
        await run { try await editor().delete("equipment_links", [.eq("id", id)]); return "Disconnected." }
    }

    /// Lands one box channel on a specific console channel; nil puts it back to 1:1.
    func setMapping(link linkID: String, boxPort: String, hostPort: String?) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard let hostPort else {
                try await db.delete("equipment_link_map", [.eq("link_id", linkID), .eq("box_port", boxPort)])
                return "Back to the default channel."
            }
            guard let link = links.first(where: { $0.id == linkID }) else { throw InventoryError("That connection no longer exists.") }
            guard let b = port(boxPort), b.0.id == link.equipmentId, b.1.cardId == nil else { throw InventoryError("That isn't one of the stage box's channels.") }
            guard let h = port(hostPort), h.0.id == link.hostId, h.1.cardId == link.hostCardId else { throw InventoryError("That channel isn't on the connected console port.") }
            guard h.1.direction == b.1.direction else { throw InventoryError("An input has to go to an input, and an output to an output.") }
            _ = try await db.upsert("equipment_link_map", ["church_id": churchId, "link_id": linkID, "box_port": boxPort, "host_port": hostPort], onConflict: "box_port")
            return "Reassigned."
        }
    }

    /// From the console's side: land the given stage box channel on this console channel. The box channel that was
    /// there takes the spot the chosen one leaves, so nothing ends up doubled up.
    func assignBoxChannel(link linkID: String, hostPort: String, boxPort: String) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard let link = links.first(where: { $0.id == linkID }) else { throw InventoryError("That connection no longer exists.") }
            guard let b = port(boxPort), b.0.id == link.equipmentId, b.1.cardId == nil else { throw InventoryError("That isn't one of the stage box's channels.") }
            guard let h = port(hostPort), h.0.id == link.hostId, h.1.cardId == link.hostCardId else { throw InventoryError("That channel isn't on the connected console port.") }
            guard h.1.direction == b.1.direction else { throw InventoryError("An input has to go to an input, and an output to an output.") }
            var landing: [String: String] = [:] // box port → console port, as resolved today
            for hop in hops where hop.linkId == linkID {
                if hop.from.device.id == link.equipmentId { landing[hop.from.id] = hop.to.id } else { landing[hop.to.id] = hop.from.id }
            }
            guard landing[boxPort] != hostPort else { return "Already there." }
            var writes: [(String, String)] = [(boxPort, hostPort)]
            if let displaced = landing.first(where: { $0.value == hostPort })?.key, let freed = landing[boxPort] { writes.append((displaced, freed)) }
            for (box, host) in writes {
                _ = try await db.upsert("equipment_link_map", ["church_id": churchId, "link_id": linkID, "box_port": box, "host_port": host], onConflict: "box_port")
            }
            return "Reassigned."
        }
    }

    /// Cables that look like a stand-in for a link: a stage box's outputs patched into a console's inputs.
    func crossedCables(_ box: Equipment) -> (host: Equipment, count: Int)? {
        guard link(asBox: box) == nil else { return nil }
        let outs = Set(box.ownPorts.filter { $0.direction == .output }.map(\.id))
        var counts: [String: Int] = [:]
        for c in cables where outs.contains(c.fromPort) {
            if let hit = port(c.toPort), hit.0.role == .console, hit.1.direction == .input, hit.1.cardId == nil { counts[hit.0.id, default: 0] += 1 }
        }
        guard let top = counts.max(by: { $0.value < $1.value }), let host = byID[top.key] else { return nil }
        return (host, top.value)
    }

    /// Turns box output → console input cables (the old stand-in for a link) into a real link, reassigning channels
    /// where a cable wasn't 1:1.
    func convertCables(box: String, host: String) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard let b = byID[box], let h = byID[host] else { throw InventoryError("Couldn't find those devices.") }
            let outs = Dictionary(uniqueKeysWithValues: b.ownPorts.filter { $0.direction == .output }.map { ($0.id, $0.number) })
            let ins = Dictionary(b.ownPorts.filter { $0.direction == .input && $0.number != nil }.map { ($0.number!, $0.id) }, uniquingKeysWith: { a, _ in a })
            let hostIns = Dictionary(uniqueKeysWithValues: h.ownPorts.filter { $0.direction == .input }.map { ($0.id, $0.number) })
            let found = cables.filter { outs[$0.fromPort] != nil && hostIns[$0.toPort] != nil }
            guard !found.isEmpty else { throw InventoryError("Couldn't find any cables to convert.") }
            nonisolated struct R: Decodable { var id: String }
            let data = try await db.upsert("equipment_links", ["church_id": churchId, "equipment_id": box, "host_id": host, "host_card_id": nil,
                                                               "signal": Signal.network.rawValue, "port_offset": 0], onConflict: "equipment_id", returning: "id")
            guard let linkID = (try? JSONDecoder().decode([R].self, from: data))?.first?.id else { throw InventoryError("Couldn't create the connection.") }
            try await db.delete("equipment_link_map", [.eq("link_id", linkID)])
            var maps: [String: [String: Any?]] = [:]
            for c in found {
                guard let n = outs[c.fromPort] ?? nil, let boxIn = ins[n], hostIns[c.toPort] ?? nil != n else { continue }
                // Two cables from the same box channel can't both be reassigned; the last wins, like an input taking one source.
                maps[boxIn] = ["church_id": churchId, "link_id": linkID, "box_port": boxIn, "host_port": c.toPort]
            }
            if !maps.isEmpty { _ = try await db.insert("equipment_link_map", Array(maps.values)) }
            try await db.delete("equipment_connections", [.in("id", found.map(\.id))])
            return "Converted \(found.count) \(found.count == 1 ? "cable" : "cables") into a connection."
        }
    }

    // Console channels

    private func consoleEditor() throws -> SupabaseClient {
        let db = try editor()
        guard consoleReady else { throw InventoryError("Your church's database doesn't have console channels yet. Ask whoever runs the website to update it.") }
        return db
    }

    /// Gives a console exactly this many input channels and mixes, numbered from 1. New ones start unnamed; lowering a
    /// count removes the highest-numbered ones and their patch.
    func setChannelCounts(_ consoleID: String, inputs: Int, outputs: Int) async -> (ok: Bool, message: String) {
        await run {
            let db = try consoleEditor()
            guard (0...512).contains(inputs), (0...512).contains(outputs) else { throw InventoryError("Channels and mixes must be a whole number from 0 to 512.") }
            var add: [[String: Any?]] = [], remove: [String] = []
            for (kind, count) in [(ChannelKind.input, inputs), (.output, outputs)] {
                let change = InventoryRules.channelChanges(channels.filter { $0.equipmentId == consoleID && $0.kind == kind }, count: count)
                add += change.add.map { ["church_id": churchId, "equipment_id": consoleID, "kind": kind.rawValue, "number": $0, "label": ""] }
                remove += change.remove
            }
            for start in stride(from: 0, to: remove.count, by: 100) {
                try await db.delete("console_channels", [.in("id", Array(remove[start..<min(remove.count, start + 100)]))])
            }
            for start in stride(from: 0, to: add.count, by: 500) { _ = try await db.insert("console_channels", Array(add[start..<min(add.count, start + 500)])) }
            return "Saved."
        }
    }

    func renameChannel(_ id: String, _ label: String) async -> (ok: Bool, message: String) {
        await run {
            try await consoleEditor().update("console_channels", ["label": String(label.trimmingCharacters(in: .whitespaces).prefix(80))], [.eq("id", id)])
            return "Saved."
        }
    }

    /// Patches channels to sockets. An input channel takes one source, so its old one goes; an output socket carries one
    /// mix, so whatever mix it carried goes. A mix can go to many sockets, and a socket can feed many input channels.
    func patchChannels(_ pairs: [(channel: String, port: String)]) async -> (ok: Bool, message: String) {
        await run {
            let db = try consoleEditor()
            guard !pairs.isEmpty else { throw InventoryError("There's nothing to patch.") }
            let byID = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
            var inputs: [String] = [], doomed = Set<String>()
            for (c, p) in pairs {
                guard let ch = byID[c], let socket = port(p)?.1 else { throw InventoryError("One of those channels no longer exists.") }
                if ch.kind == .input {
                    guard socket.feedsIn else { throw InventoryError("An input channel takes its signal from an input socket.") }
                    inputs.append(c)
                } else {
                    guard socket.feedsOut else { throw InventoryError("A mix goes out of an output socket.") }
                    for old in consolePatch where old.portId == p && byID[old.channelId]?.kind == .output { doomed.insert(old.id) }
                }
            }
            for start in stride(from: 0, to: inputs.count, by: 100) {
                try await db.delete("console_patch", [.in("channel_id", Array(inputs[start..<min(inputs.count, start + 100)]))])
            }
            let ids = Array(doomed)
            for start in stride(from: 0, to: ids.count, by: 100) { try await db.delete("console_patch", [.in("id", Array(ids[start..<min(ids.count, start + 100)]))]) }
            let rows: [[String: Any?]] = pairs.map { ["church_id": churchId, "channel_id": $0.channel, "port_id": $0.port] }
            do {
                for start in stride(from: 0, to: rows.count, by: 500) { _ = try await db.insert("console_patch", Array(rows[start..<min(rows.count, start + 500)])) }
            } catch let e as SupabaseError where e.isUnique { throw InventoryError("That mix already goes to that socket.") }
            return pairs.count == 1 ? "Patched." : "Patched \(pairs.count) channels."
        }
    }

    func unpatchChannel(_ patchID: String) async -> (ok: Bool, message: String) {
        await run { try await consoleEditor().delete("console_patch", [.eq("id", patchID)]); return "Unpatched." }
    }

    // Service log

    func addService(_ equipmentID: String, kind: ServiceKind, date: Date, summary: String, cost: Double?, vendor: String, newStatus: EquipmentStatus?) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw InventoryError("Say what was done.") }
            if let cost, cost < 0 { throw InventoryError("The cost must be a dollar amount.") }
            _ = try await db.insert("equipment_service", [["church_id": churchId, "equipment_id": equipmentID, "kind": kind.rawValue,
                                                           "performed_on": InventoryRules.localDayString(date), "summary": String(text.prefix(1000)),
                                                           "cost": cost, "vendor": String(vendor.trimmingCharacters(in: .whitespaces).prefix(200))]])
            if let newStatus { try await db.update("equipment", ["status": newStatus.rawValue], [.eq("id", equipmentID)]) }
            return "Added."
        }
    }

    func deleteService(_ id: String) async -> (ok: Bool, message: String) {
        await run { try await editor().delete("equipment_service", [.eq("id", id)]); return "Deleted." }
    }

    // Rooms and racks

    private func placeName(_ name: String, _ what: String) throws -> String {
        let v = String(name.trimmingCharacters(in: .whitespaces).prefix(80))
        guard !v.isEmpty else { throw InventoryError("Give the \(what) a name.") }
        return v
    }

    func addRoom(campus: String, name: String) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            if !campus.isEmpty, !campuses.contains(where: { $0.id == campus }) { throw InventoryError("Pick one of your campuses.") }
            do { _ = try await db.insert("equipment_rooms", [["church_id": churchId, "campus": campus, "name": try placeName(name, "room")]]) }
            catch let e as SupabaseError where e.isUnique { throw InventoryError("This campus already has a room with that name.") }
            return "Room added."
        }
    }

    /// Renames a room and, when `campus` changes, moves it there with its racks and everything in it.
    func updateRoom(_ id: String, name: String, campus: String) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            if !campus.isEmpty, !campuses.contains(where: { $0.id == campus }) { throw InventoryError("Pick one of your campuses.") }
            do { try await db.update("equipment_rooms", ["name": try placeName(name, "room"), "campus": campus], [.eq("id", id)]) }
            catch let e as SupabaseError where e.isUnique { throw InventoryError("That campus already has a room with that name.") }
            // A device is always in its room's campus, so the room's equipment goes with it.
            try await db.update("equipment", ["campus": campus], [.eq("room_id", id), .neq("campus", campus)])
            return "Saved."
        }
    }

    func deleteRoom(_ id: String) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard !racks.contains(where: { $0.roomId == id }) else { throw InventoryError("Remove this room's racks first.") }
            try await db.delete("equipment_rooms", [.eq("id", id)])
            return "Room deleted."
        }
    }

    func addRack(room: String, name: String, units: Int) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard (1...60).contains(units) else { throw InventoryError("A rack can have from 1 to 60 units.") }
            do { _ = try await db.insert("equipment_racks", [["church_id": churchId, "room_id": room, "name": try placeName(name, "rack"), "units": units]]) }
            catch let e as SupabaseError where e.isUnique { throw InventoryError("This room already has a rack with that name.") }
            return "Rack added."
        }
    }

    /// Renames a rack or changes its size; it can't shrink below the highest unit something is in.
    func updateRack(_ id: String, name: String, units: Int) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard (1...60).contains(units) else { throw InventoryError("A rack can have from 1 to 60 units.") }
            if let high = equipment.first(where: { $0.rackId == id && ($0.rackUnit ?? 0) + $0.rackHeight - 1 > units && $0.rackUnit != nil }) {
                throw InventoryError("\(high.name) is in \(InventoryRules.rackSpan(unit: high.rackUnit, height: high.rackHeight)). Move it before making the rack smaller.")
            }
            do { try await db.update("equipment_racks", ["name": try placeName(name, "rack"), "units": units], [.eq("id", id)]) }
            catch let e as SupabaseError where e.isUnique { throw InventoryError("This room already has a rack with that name.") }
            return "Saved."
        }
    }

    /// Deletes a rack. What was in it stays in the room, with no rack or unit.
    func deleteRack(_ id: String) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            try await db.update("equipment", ["rack_id": nil, "rack_unit": nil, "rack_height": 1], [.eq("rack_id", id)])
            try await db.delete("equipment_racks", [.eq("id", id)])
            return "Rack deleted."
        }
    }

    /// Puts a device in a rack at a unit (counted from 1 at the bottom). The device has to be in the rack's campus.
    func placeInRack(_ equipmentID: String, rack rackID: String, unit: Int, height: Int) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard let rack = racksByID[rackID], let room = roomsByID[rack.roomId], let device = byID[equipmentID] else { throw InventoryError("Couldn't find that rack.") }
            guard room.campus == device.campus else { throw InventoryError("That device is in a different campus than this room.") }
            try await checkFit(rackID: rackID, units: rack.units, unit: unit, height: height, selfID: equipmentID)
            try await db.update("equipment", ["room_id": rack.roomId, "rack_id": rackID, "rack_unit": unit, "rack_height": height], [.eq("id", equipmentID)])
            return "Placed."
        }
    }

    func removeFromRack(_ equipmentID: String) async -> (ok: Bool, message: String) {
        await run {
            try await editor().update("equipment", ["rack_id": nil, "rack_unit": nil, "rack_height": 1], [.eq("id", equipmentID)])
            return "Removed from the rack."
        }
    }

    func moveToRoom(_ equipmentID: String, room roomID: String?) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            if let roomID, let room = roomsByID[roomID], room.campus != byID[equipmentID]?.campus {
                throw InventoryError("That room is in a different campus.")
            }
            try await db.update("equipment", ["room_id": roomID, "rack_id": nil, "rack_unit": nil, "rack_height": 1], [.eq("id", equipmentID)])
            return "Moved."
        }
    }

    // Config files (owners and admins)

    static let maxFileBytes = 25 * 1024 * 1024

    func uploadFile(_ equipmentID: String, url: URL) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard isAdmin else { throw InventoryError("Only owners and admins can add files.") }
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maxFileBytes else { throw InventoryError("Files can be up to 25 MB.") }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType) ?? "application/octet-stream"
            let id = UUID().uuidString.lowercased()
            try await db.upload(bucket: "equipment-files", path: "\(churchId)/\(equipmentID)/\(id)", data: data, contentType: type)
            do {
                _ = try await db.insert("equipment_files", [["id": id, "church_id": churchId, "equipment_id": equipmentID,
                                                             "name": String(url.lastPathComponent.prefix(200)), "size": data.count, "content_type": type]])
            } catch {
                try? await db.remove(bucket: "equipment-files", paths: ["\(churchId)/\(equipmentID)/\(id)"])
                throw error
            }
            return "Added \(url.lastPathComponent)."
        }
    }

    func downloadFile(_ file: EquipmentFile) async throws -> Data {
        try await db.download(bucket: "equipment-files", path: "\(churchId)/\(file.equipmentId)/\(file.id)")
    }

    func deleteFile(_ file: EquipmentFile) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            guard isAdmin else { throw InventoryError("Only owners and admins can remove files.") }
            try await db.remove(bucket: "equipment-files", paths: ["\(churchId)/\(file.equipmentId)/\(file.id)"])
            try await db.delete("equipment_files", [.eq("id", file.id)])
            return "Deleted."
        }
    }

    // MARK: Import

    /// Brings a spreadsheet's cables into the patch sheet for one campus. Devices are matched by name and channels by
    /// number (or name when a row has none); anything missing is created. A row replaces whatever fed that input before.
    func importCables(_ rows: [ImportRow], campus: String) async -> (ok: Bool, message: String) {
        await run {
            guard !rows.isEmpty else { throw InventoryError("There are no cables to import.") }
            if !campus.isEmpty, !campuses.contains(where: { $0.id == campus }) { throw InventoryError("Pick one of your campuses.") }
            return try await saveCables(rows, campus: campus) + "."
        }
    }

    /// Saves cable rows for one campus and says what it did. A row's device is found by name unless `pinned` says which
    /// device that name is (a document import has already settled that with the person). `lenient` is for rows a model
    /// read: a card the device doesn't have falls back to the device's own channels instead of stopping the import.
    private func saveCables(_ rows: [ImportRow], campus: String, pinned: [String: String] = [:], lenient: Bool = false) async throws -> String {
            let db = try editor()
            guard rows.count <= PatchImport.maxRows else { throw InventoryError("Import at most \(PatchImport.maxRows) cables at a time.") }
            func same(_ a: String, _ b: String) -> Bool { a.compare(b, options: [.caseInsensitive]) == .orderedSame }

            final class Slot { var id: String; var equipmentId: String; var number: Int?; var label: String; var kind: String; var direction: PortDirection; var cardId: String?
                init(_ p: EquipmentPort) { id = p.id; equipmentId = p.equipmentId; number = p.number; label = p.label; kind = p.kind; direction = p.direction; cardId = p.cardId }
                init(equipmentId: String, number: Int?, label: String, kind: String, direction: PortDirection) { id = ""; self.equipmentId = equipmentId; self.number = number; self.label = label; self.kind = kind; self.direction = direction }
            }
            final class Device { var id: String; var name: String; var ports: [Slot]; var cards: [OptionCard]
                init(id: String, name: String, ports: [Slot], cards: [OptionCard]) { self.id = id; self.name = name; self.ports = ports; self.cards = cards }
            }
            let pinnedIDs = Set(pinned.values)
            var devices = equipment.filter { $0.campus == campus || pinnedIDs.contains($0.id) }.map { Device(id: $0.id, name: $0.name, ports: $0.ports.map(Slot.init), cards: $0.cards) }

            // Devices the sheet mentions that don't exist yet.
            var wanted: [String] = []
            for r in rows { for n in [r.fromDevice, r.toDevice] where pinned[n] == nil && !devices.contains(where: { same($0.name, n) }) && !wanted.contains(where: { same($0, n) }) { wanted.append(n) } }
            if !wanted.isEmpty {
                let ids = try await db.insertIDs("equipment", wanted.map { ["church_id": churchId, "name": $0, "campus": campus] })
                for (id, name) in zip(ids, wanted) { devices.append(Device(id: id, name: name, ports: [], cards: [])) }
            }
            func device(_ name: String) throws -> Device {
                let hit = pinned[name].map { id in devices.first { $0.id == id } } ?? devices.first { same($0.name, name) }
                guard let hit else { throw InventoryError("One of the devices to patch no longer exists. Read the document again.") }
                return hit
            }

            func resolve(_ d: Device, _ dir: PortDirection, _ number: Int?, _ label: String, _ kind: String, _ card: String) throws -> Slot {
                let fits: (Slot) -> Bool = { $0.direction == dir || $0.direction == .both }
                if !card.isEmpty {
                    // An option card's channels already exist; a row can only pick one of them.
                    let slot = Int(card.replacingOccurrences(of: #"^slot\s*"#, with: "", options: [.regularExpression, .caseInsensitive]))
                    let fitted = d.cards.first(where: { $0.slot == slot || $0.name.lowercased().contains(card.lowercased()) })
                    if fitted == nil && !lenient { throw InventoryError("\(d.name) has no option card matching \"\(card)\".") }
                    if let fitted {
                        let onCard = d.ports.filter { $0.cardId == fitted.id && fits($0) }
                        if let hit = number != nil ? onCard.first(where: { $0.number == number }) : onCard.first(where: { same($0.label, label) }) { return hit }
                        if !lenient { throw InventoryError("\(d.name) slot \(fitted.slot) (\(fitted.name)) has no \(dir.rawValue) \(number.map(String.init) ?? label).") }
                    }
                    // The device has no such card on file: keep the cable on a channel of its own, marked with what the document called it.
                    let marked = d.ports.filter { $0.cardId == nil && fits($0) && same($0.kind, card) }
                    if let again = number != nil ? marked.first(where: { $0.number == number }) : marked.first(where: { same($0.label, label) }) { return again }
                    let s = Slot(equipmentId: d.id, number: number, label: label, kind: String(card.prefix(60)), direction: dir)
                    d.ports.append(s)
                    return s
                }
                let own = d.ports.filter { $0.cardId == nil }
                if let found = number != nil ? own.first(where: { fits($0) && $0.number == number }) : own.first(where: { fits($0) && same($0.label, label) }) { return found }
                var n = number ?? 1
                if number == nil { while own.contains(where: { $0.direction == dir && $0.number == n }) { n += 1 } }
                let s = Slot(equipmentId: d.id, number: n, label: label, kind: kind, direction: dir)
                d.ports.append(s)
                return s
            }
            let pairs = try rows.map { r in
                (r, try resolve(device(r.fromDevice), .output, r.fromChannel, r.fromName, r.fromKind, r.fromCard),
                 try resolve(device(r.toDevice), .input, r.toChannel, r.toName, r.toKind, r.toCard))
            }
            // Name and connector only fill blanks; they never overwrite what someone has already typed in.
            var fills: [ObjectIdentifier: (Slot, [String: Any?])] = [:]
            for (r, from, to) in pairs {
                for (s, label, kind) in [(from, r.fromName, r.fromKind), (to, r.toName, r.toKind)] {
                    if s.id.isEmpty { if s.label.isEmpty { s.label = label }; if s.kind.isEmpty { s.kind = kind }; continue }
                    var fill = fills[ObjectIdentifier(s)]?.1 ?? [:]
                    if s.label.isEmpty, !label.isEmpty { fill["label"] = label }
                    if s.kind.isEmpty, !kind.isEmpty { fill["kind"] = kind }
                    if !fill.isEmpty { fills[ObjectIdentifier(s)] = (s, fill) }
                }
            }
            var fresh: [Slot] = []
            for (_, f, t) in pairs { for s in [f, t] where s.id.isEmpty && !fresh.contains(where: { $0 === s }) { fresh.append(s) } }
            for start in stride(from: 0, to: fresh.count, by: 500) {
                let chunk = Array(fresh[start..<min(fresh.count, start + 500)])
                let ids = try await db.insertIDs("equipment_ports", chunk.map { ["church_id": churchId, "equipment_id": $0.equipmentId, "number": $0.number,
                                                                                 "label": $0.label, "kind": $0.kind, "direction": $0.direction.rawValue] })
                for (s, id) in zip(chunk, ids) { s.id = id }
            }
            for (s, fill) in fills.values { try await db.update("equipment_ports", fill, [.eq("id", s.id)]) }

            // Cables: the last row for an input wins, and for an output that takes one cable (anything but audio over
            // a network) the last row from it wins too. A channel can't be patched to itself.
            var byInput: [String: (from: String, note: String)] = [:]
            var order: [String] = []
            var skipped = 0
            for (r, f, t) in pairs {
                if f.id == t.id { skipped += 1; continue }
                if byInput[t.id] == nil { order.append(t.id) }
                byInput[t.id] = (f.id, r.note)
            }
            // A channel this import made carries what the database gives it, which is analog.
            let single = Set(byInput.values.map(\.from).filter { !(port($0)?.1.signal.fansOut ?? false) })
            var lastInto: [String: String] = [:]
            for t in order where single.contains(byInput[t]!.from) { lastInto[byInput[t]!.from] = t }
            let moved = order.filter { t in single.contains(byInput[t]!.from) && lastInto[byInput[t]!.from] != t }.count
            order.removeAll { t in single.contains(byInput[t]!.from) && lastInto[byInput[t]!.from] != t }
            for start in stride(from: 0, to: order.count, by: 100) {
                try await db.delete("equipment_connections", [.in("to_port", Array(order[start..<min(order.count, start + 100)]))])
            }
            let made: [[String: Any?]] = order.map { ["church_id": churchId, "from_port": byInput[$0]!.from, "to_port": $0, "note": byInput[$0]!.note] }
            for start in stride(from: 0, to: made.count, by: 500) { _ = try await db.insert("equipment_connections", Array(made[start..<min(made.count, start + 500)])) }

            var bits = ["Imported \(made.count) \(made.count == 1 ? "cable" : "cables")"]
            if !wanted.isEmpty { bits.append("added \(wanted.count) new \(wanted.count == 1 ? "device" : "devices")") }
            if !fresh.isEmpty { bits.append("\(fresh.count) new \(fresh.count == 1 ? "channel" : "channels")") }
            if skipped > 0 { bits.append("skipped \(skipped) patched to themselves") }
            if moved > 0 { bits.append("skipped \(moved) \(moved == 1 ? "row" : "rows") sending an analog output to a second input (the last one wins)") }
            return bits.joined(separator: ", ")
    }

    /// Saves what a document import found, after the person reviewed it. A device they matched to one already in the
    /// inventory only has its blanks filled in: what someone typed is never replaced, and new facts for the notes are
    /// added underneath. The rest are added, in the rooms the document names (made if missing). Then the cables are patched.
    func importDocument(_ decisions: [DeviceDecision], cables: [ImportRow], campus: String) async -> (ok: Bool, message: String) {
        await run {
            let db = try editor()
            if !campus.isEmpty, !campuses.contains(where: { $0.id == campus }) { throw InventoryError("Pick one of your campuses.") }
            guard !decisions.isEmpty || !cables.isEmpty else { throw InventoryError("There's nothing to import.") }
            guard decisions.count <= DocumentImport.maxDevices else { throw InventoryError("Import at most \(DocumentImport.maxDevices) devices at a time.") }
            func t(_ s: String, _ max: Int = 200) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max)) }
            let targets = decisions.compactMap(\.target)
            guard Set(targets).count == targets.count else {
                throw InventoryError("Two of the document's devices are matched to the same device in the inventory. Pick a different one for one of them.")
            }
            guard decisions.allSatisfy({ !t($0.name).isEmpty }) else { throw InventoryError("Every device needs a name.") }
            for id in targets where byID[id] == nil { throw InventoryError("One of the matched devices no longer exists. Read the document again.") }

            // Rooms, by campus and name: found if they exist, made if not.
            func roomKey(_ c: String, _ name: String) -> String { "\(c)\n\(name.lowercased())" }
            var roomIDs = Dictionary(rooms.map { (roomKey($0.campus, $0.name), $0.id) }, uniquingKeysWith: { a, _ in a })
            let known = byID
            func campusOf(_ d: DeviceDecision) -> String { d.target.flatMap { known[$0]?.campus } ?? campus }
            var missing: [String: (campus: String, name: String)] = [:]
            for d in decisions {
                let room = t(d.room, 80)
                let key = roomKey(campusOf(d), room)
                let alreadyPlaced = d.target.flatMap { byID[$0]?.roomId } != nil
                if !room.isEmpty, !alreadyPlaced, roomIDs[key] == nil { missing[key] = (campusOf(d), room) }
            }
            if !missing.isEmpty {
                let list = Array(missing)
                let ids = try await db.insertIDs("equipment_rooms", list.map { ["church_id": churchId, "campus": $0.value.campus, "name": $0.value.name] })
                for (entry, id) in zip(list, ids) { roomIDs[entry.key] = id }
            }
            func roomOf(_ d: DeviceDecision) -> String? { t(d.room, 80).isEmpty ? nil : roomIDs[roomKey(campusOf(d), t(d.room, 80))] }

            var ids: [String: String] = [:]
            let fresh = decisions.filter { $0.target == nil }
            for start in stride(from: 0, to: fresh.count, by: 200) {
                let chunk = Array(fresh[start..<min(fresh.count, start + 200)])
                let made = try await db.insertIDs("equipment", chunk.map { d in
                    ["church_id": churchId, "campus": campus, "name": t(d.name), "make_model": t(d.makeModel),
                     "category": InventoryCategories.all.contains(d.category) ? d.category : "", "role": d.role?.rawValue ?? "",
                     "location": t(d.location), "ip_address": t(d.ipAddress, 100), "mac_address": t(d.macAddress, 100), "serial": t(d.serial), "username": t(d.username),
                     "password": String(d.password.prefix(500)), "notes": String(d.notes.prefix(4000)), "room_id": roomOf(d)]
                })
                for (d, id) in zip(chunk, made) { ids[d.key] = id }
            }

            var filled = 0
            for d in decisions {
                guard let target = d.target, let now = byID[target] else { continue }
                ids[d.key] = target
                var change: [String: Any?] = [:]
                let fields: [(String, String, String)] = [
                    ("category", now.category, InventoryCategories.all.contains(d.category) ? d.category : ""), ("make_model", now.makeModel, t(d.makeModel)),
                    ("serial", now.serial, t(d.serial)), ("location", now.location, t(d.location)), ("ip_address", now.ipAddress, t(d.ipAddress, 100)), ("mac_address", now.macAddress, t(d.macAddress, 100)),
                    ("username", now.username, t(d.username)), ("password", now.password, String(d.password.prefix(500))),
                ]
                for (column, have, new) in fields where have.trimmingCharacters(in: .whitespaces).isEmpty && !new.isEmpty { change[column] = new }
                if now.role == nil, let role = d.role { change["role"] = role.rawValue }
                // Notes are facts, one per line (MAC, hostname…): only the lines it doesn't already have are added.
                let have = now.notes.lowercased()
                let lines = d.notes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !have.contains($0.lowercased()) }
                if !lines.isEmpty { change["notes"] = String(([now.notes.trimmingCharacters(in: .whitespacesAndNewlines)] + lines).filter { !$0.isEmpty }.joined(separator: "\n").prefix(4000)) }
                if now.roomId == nil, let room = roomOf(d) { change["room_id"] = room }
                guard !change.isEmpty else { continue }
                try await db.update("equipment", change, [.eq("id", target)])
                filled += 1
            }

            let wanted = cables.filter { ids[$0.fromDevice] != nil && ids[$0.toDevice] != nil }
            let patched = wanted.isEmpty ? "" : try await saveCables(wanted, campus: campus, pinned: ids, lenient: true)

            var bits: [String] = []
            if !fresh.isEmpty { bits.append("Added \(fresh.count) \(fresh.count == 1 ? "device" : "devices")") }
            if filled > 0 { bits.append("\(bits.isEmpty ? "Filled" : "filled") in \(filled) already in the inventory") }
            if !missing.isEmpty { bits.append("\(bits.isEmpty ? "Made" : "made") \(missing.count) \(missing.count == 1 ? "room" : "rooms")") }
            if !patched.isEmpty { bits.append(bits.isEmpty ? patched : patched.replacingOccurrences(of: "Imported", with: "patched")) }
            return bits.isEmpty ? "Everything in that document was already in the inventory." : bits.joined(separator: ", ") + "."
        }
    }
}

/// What the person decided for one found device: `target` is nil to add it, or the inventory device it is. The details
/// are as they left them in the review.
struct DeviceDecision: Identifiable {
    var key: String
    var target: String?
    var name: String
    var makeModel: String
    var category: String
    var role: DeviceRole?
    var room: String
    var location: String
    var ipAddress: String
    var macAddress: String
    var serial: String
    var username: String
    var password: String
    var notes: String
    var id: String { key }

    init(_ d: FoundDevice, target: String?) {
        key = d.key; self.target = target; name = d.name; makeModel = d.makeModel; category = d.category; role = d.role
        room = d.room; location = d.location; ipAddress = d.ipAddress; macAddress = d.macs.map(DocumentImport.prettyMac).joined(separator: ", "); serial = d.serial; username = d.username; password = d.password; notes = d.notes
    }
}
