import Foundation

// MARK: - Reading documents into the inventory
// A document someone already has (a network sheet, an integrator's device
// list, a patch or input list) read into devices and cables. Canopy's local
// model does the deciphering, a piece at a time (see DocumentReader); this file
// is the plain logic around it: cutting the text into pieces small enough for
// an on-device model, tidying what comes back, folding several rows about one
// device together, and finding the device each one already is in the
// inventory. Nothing is saved from here: a person reviews the result first.

/// What the model reports for one piece of the document, as plain values.
nonisolated struct RawAnswer: Sendable {
    struct Device: Sendable {
        var name = "", model = "", category = "", role = "", room = "", area = "", ip = "", network = "", mac = ""
        var hostname = "", serial = "", username = "", password = "", notes = ""
    }
    struct Cable: Sendable {
        var signal = "", from = "", fromCard = "", fromChannel = "", to = "", toCard = "", toChannel = "", note = ""
    }
    var summary = ""
    var devices: [Device] = []
    var cables: [Cable] = []
}

/// A device as the document describes it. `key` is how its cables and the review refer to it.
nonisolated struct FoundDevice: Hashable, Identifiable, Sendable {
    var key: String
    var name: String
    var makeModel = ""
    var category = ""
    var role: DeviceRole?
    var room = ""
    var location = ""
    var ipAddress = ""
    var serial = ""
    var username = ""
    var password = ""
    /// What has no field of its own: hostname, other addresses. One fact per line.
    var notes = ""
    var macs: [String] = []
    var hostname = ""
    /// Every address the document gives it, the main one included.
    var addresses: [String] = []
    /// How many rows of the document describe it; 0 when it's only named as the end of a cable.
    var rows = 0
    var id: String { key }
}

/// What a document says, ready for review. A cable's devices are `FoundDevice` keys.
nonisolated struct DocumentReading: Sendable {
    var summary: String
    var devices: [FoundDevice]
    var cables: [ImportRow]
    var warnings: [String]
}

/// The inventory device a found device most likely is, and why.
nonisolated struct DeviceMatch: Hashable, Sendable {
    var id: String
    var score: Int
    var why: String
}

nonisolated enum DocumentImport {
    static let maxChars = 150_000
    static let maxDevices = 400
    static let matchThreshold = 45

    // MARK: Pieces

    /// Cuts a document into pieces of about `lines` rows (and `chars` characters), so each answer stays short
    /// enough to finish. Every piece after the first is shown how the document starts (title and headings).
    static func chunk(_ raw: String, lines maxLines: Int, chars maxChars: Int) -> (head: String, chunks: [String]) {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            if current.count >= maxLines || (!current.isEmpty && size + line.count > maxChars) {
                chunks.append(current.joined(separator: "\n")); current = []; size = 0
            }
            let cut = String(line.prefix(maxChars))
            current.append(cut)
            size += cut.count + 1
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return (lines.prefix(4).joined(separator: "\n"), chunks)
    }

    // MARK: Text helpers

    static func str(_ v: String, _ max: Int = 200) -> String {
        String(v.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces).prefix(max))
    }
    static func norm(_ v: String) -> String {
        v.lowercased().replacingOccurrences(of: "&", with: "and").replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }
    static func words(_ v: String) -> [String] {
        v.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init).filter { $0.count > 1 }
    }
    /// A name as whole words with the punctuation inside them dropped: "D-Live SQ-6" is "dlive", "sq6".
    static func tokens(_ v: String) -> [String] {
        v.components(separatedBy: CharacterSet(charactersIn: " \t\n/,()")).map(norm).filter { !$0.isEmpty }
    }
    /// Whether every word of the shorter name is in the longer one ("Stage Box" in "DX168 Stage Box"); a word may be
    /// cut short ("SQ" for "SQ-6"), a number may not.
    static func nameWithin(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        guard !short.isEmpty, short.joined().count >= 2 else { return false }
        return short.allSatisfy { w in
            long.contains { l in l == w || (w.count >= 2 && w.allSatisfy(\.isLetter) && l.hasPrefix(w)) }
        }
    }

    /// "7c:2e:d:a5:be:d4", "00.10.7f.f1.6e.da" and "00-0F-9B-04-00-2F" as twelve lowercase hex digits; "" if not a MAC.
    static func normalMac(_ v: String) -> String {
        let parts = v.trimmingCharacters(in: .whitespaces).components(separatedBy: CharacterSet(charactersIn: ":.- ")).filter { !$0.isEmpty }
        let hex = parts.count == 6 ? parts.map { String(repeating: "0", count: max(0, 2 - $0.count)) + $0 }.joined() : parts.joined()
        return hex.range(of: #"^[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil ? hex.lowercased() : ""
    }
    static func prettyMac(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { i in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return hex[s..<hex.index(s, offsetBy: 2)].uppercased()
        }.joined(separator: ":")
    }
    static func isAddress(_ v: String) -> Bool { v.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil }

    /// A row's name without the "- Control" / "Dante Interface" ending that tells one network port of a device from another.
    static func portless(_ name: String) -> String {
        let cut = name.replacingOccurrences(of: #"\s*[-–—]?\s*\b(control|dante|video)(\s*/\s*(control|dante|video))?(\s+interface)?\s*$"#,
                                            with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? name : cut
    }

    static func channel(_ v: String) -> Int? {
        guard let r = str(v, 20).range(of: #"\d{1,4}(?!.*\d)"#, options: .regularExpression), let n = Int(str(v, 20)[r]), (1...9999).contains(n) else { return nil }
        return n
    }

    /// Keeps an address, MAC, serial or login only if the document says it on this device's own line(s), so a value a
    /// model copied from the row above is dropped. When no line names the device (prose, odd layouts) nothing is dropped.
    static func ground(_ d: RawAnswer.Device, in chunk: String) -> RawAnswer.Device {
        let lines = chunk.split(separator: "\n").map { String($0) }
        let keys = [norm(d.name), norm(portless(d.name)), norm(d.model)].filter { $0.count >= 3 }
        let mine = lines.filter { line in let n = norm(line); return keys.contains { n.contains($0) } }
        guard !mine.isEmpty else { return d }
        func says(_ v: String) -> Bool {
            let value = str(v)
            guard !value.isEmpty else { return true }
            return mine.contains { $0.lowercased().contains(value.lowercased()) }
        }
        var out = d
        let mac = normalMac(d.mac)
        if !mac.isEmpty, !mine.contains(where: { line in
            line.components(separatedBy: CharacterSet(charactersIn: " \t,;|")).contains { normalMac($0) == mac }
        }) { out.mac = "" }
        if !says(d.ip) { out.ip = "" }
        if !says(d.serial) { out.serial = "" }
        if !says(d.username) { out.username = "" }
        if !says(d.password) { out.password = "" }
        return out
    }

    // MARK: Putting the answers together

    private struct Row {
        var name, makeModel, category: String
        var role: DeviceRole?
        var room, area, ip, network, mac, hostname, serial, username, password, notes: String
    }

    private static func rows(_ a: RawAnswer) -> (rows: [Row], wires: [RawAnswer.Cable]) {
        let rows = a.devices.compactMap { d -> Row? in
            let makeModel = [str(d.model, 160)].filter { !$0.isEmpty }.joined(separator: " ")
            let name = str(d.name).isEmpty ? makeModel : str(d.name)
            guard name.contains(where: \.isLetter) else { return nil }  // a channel number isn't a device
            let category = InventoryCategories.all.first { $0.lowercased() == str(d.category, 40).lowercased() } ?? ""
            // A name that says what it is ("Videohub", "DX168") beats a small model's guess.
            let role = InventoryRules.suggestRole(name: name, makeModel: makeModel, category: category) ?? DeviceRole(rawValue: str(d.role, 40).lowercased())
            let ip = str(d.ip, 60), room = str(d.room, 80), area = str(d.area, 80)
            // Small models fill every field: drop the ones that only repeat another (a hostname that is the name, a
            // network that is the address) and notes that only restate the row.
            var network = str(d.network, 60)
            if isAddress(network) || norm(network) == norm(ip) { network = "" }
            var hostname = str(d.hostname, 100)
            if hostname.contains(" ") || norm(hostname) == norm(name) || norm(hostname) == norm(portless(name)) || isAddress(hostname) { hostname = "" }
            var notes = str(d.notes, 500)
            let said = Set(words([name, makeModel, category, room, area, ip, d.network, d.hostname, d.mac, d.serial, d.role].joined(separator: " ")))
            let filler: Set<String> = ["vlan", "location", "make", "model", "ip", "address", "mac", "network", "room", "name", "device", "category", "type", "role"]
            let noteWords = words(notes)
            if noteWords.count >= 3, Double(noteWords.filter { !said.contains($0) && !filler.contains($0) }.count) <= Double(noteWords.count) * 0.2 { notes = "" }
            return Row(name: name, makeModel: makeModel, category: category, role: role, room: room, area: area,
                       ip: ip, network: network, mac: normalMac(str(d.mac, 40)), hostname: hostname,
                       serial: str(d.serial, 100), username: str(d.username, 100), password: str(d.password, 200), notes: notes)
        }
        let wires = a.cables.filter { !str($0.from).isEmpty && !str($0.to).isEmpty }
        return (rows, wires)
    }

    /// Puts the answers (one per piece of the document) together. Rows about the same device become one device: a
    /// switch listed once per VLAN shares a MAC address, and a receiver's control and Dante ports share a name, model
    /// and room. Two identical rows with nothing to tell them apart stay two devices; racks hold two of the same thing.
    static func build(_ answers: [RawAnswer?]) -> DocumentReading {
        var warnings: [String] = []
        let failed = answers.filter { $0 == nil }.count
        if failed > 0 {
            warnings.append("\(failed) of the document's \(answers.count) parts couldn't be read, so some rows may be missing. Reading it again often helps.")
        }
        let parts = answers.compactMap { $0 }.map(rows)
        let rows = parts.flatMap(\.rows)
        let wires = parts.flatMap(\.wires)
        let summary = answers.compactMap { $0 }.map { str($0.summary, 400) }.first { !$0.isEmpty } ?? ""

        // Group the rows: each starts alone, then joins any earlier row that is plainly the same device.
        var group = Array(rows.indices)
        func find(_ i: Int) -> Int { var i = i; while group[i] != i { group[i] = group[group[i]]; i = group[i] }; return i }
        func join(_ a: Int, _ b: Int) { group[find(b)] = find(a) }
        var byMac: [String: Int] = [:]
        var byName: [String: [(at: Int, name: String)]] = [:]
        for (i, r) in rows.enumerated() {
            // One MAC is one device, but only between rows of the same model: a small model sometimes copies a MAC
            // onto the next row, and that mustn't fold a receiver into a switch.
            if !r.mac.isEmpty {
                if let seen = byMac[r.mac] {
                    let a = norm(rows[seen].makeModel), b = norm(r.makeModel)
                    if a.isEmpty || b.isEmpty || a == b { join(seen, i) }
                } else { byMac[r.mac] = i }
            }
            let key = "\(norm(r.makeModel))|\(norm(portless(r.name)))|\(norm(r.room))"
            let peers = byName[key] ?? []
            // Only rows whose names differ (control vs Dante port) are one device; identical rows are two units.
            if let twin = peers.first(where: { norm($0.name) != norm(r.name) }) { join(twin.at, i) }
            byName[key] = peers + [(i, r.name)]
        }

        var order: [Int] = []
        var grouped: [Int: [Row]] = [:]
        for (i, r) in rows.enumerated() {
            let g = find(i)
            if grouped[g] == nil { order.append(g) }
            grouped[g, default: []].append(r)
        }
        var devices: [FoundDevice] = order.enumerated().map { n, g in
            let members = grouped[g]!
            func first(_ pick: (Row) -> String) -> String { members.map(pick).first { !$0.isEmpty } ?? "" }
            func each(_ pick: (Row) -> String) -> [String] {
                var seen = Set<String>(); return members.map(pick).filter { !$0.isEmpty && seen.insert($0).inserted }
            }
            let names = each(\.name)
            // "Receiver 2 - Control" is the receiver, whether or not its Dante port has a row of its own.
            let name = names.count > 1 || names[0].range(of: #"\s[-–—]\s"#, options: .regularExpression) != nil ? portless(names[0]) : names[0]
            // The address people use to reach it is the one on the control network, when the document says which.
            let listed = members.filter { isAddress($0.ip) }
            let main = listed.first { $0.network.range(of: "control|manage|mgmt", options: [.regularExpression, .caseInsensitive]) != nil } ?? listed.first
            let macs = each(\.mac)
            var addresses: [String] = []
            for r in listed where !addresses.contains(r.ip) { addresses.append(r.ip) }
            var others: [String] = []
            for r in listed where r.ip != main?.ip {
                let text = r.network.isEmpty ? r.ip : "\(r.ip) (\(r.network))"
                if !others.contains(where: { $0.hasPrefix(r.ip) }) { others.append(text) }
            }
            let dhcpRows = members.filter { $0.ip.range(of: "dhcp", options: .caseInsensitive) != nil }
            var dhcp: [String] = []
            for r in dhcpRows where !r.network.isEmpty && !dhcp.contains(r.network) { dhcp.append(r.network) }
            let hostnames = each(\.hostname)
            let notes = [
                hostnames.isEmpty ? "" : "Hostname: \(hostnames.joined(separator: ", "))",
                main.map { $0.network.isEmpty ? "" : "Network: \($0.network)" } ?? "",
                others.isEmpty ? "" : "Also at: \(others.joined(separator: ", "))",
                main == nil && !dhcpRows.isEmpty ? "Address: DHCP\(dhcp.isEmpty ? "" : " (\(dhcp.joined(separator: ", ")))")"
                    : main != nil && !dhcp.isEmpty ? "Also on DHCP: \(dhcp.joined(separator: ", "))" : "",
            ] + each(\.notes)
            let area = first(\.area)
            let room = first(\.room).isEmpty ? area : first(\.room)
            return FoundDevice(
                key: "d\(n + 1)", name: name, makeModel: first(\.makeModel), category: first(\.category),
                role: members.compactMap(\.role).first, room: room, location: !area.isEmpty && norm(area) != norm(room) ? area : "",
                ipAddress: main?.ip ?? "", serial: first(\.serial),
                // A login belongs with the address it opens, so the main row's wins.
                username: main.map { $0.username.isEmpty ? first(\.username) : $0.username } ?? first(\.username),
                password: main.map { $0.password.isEmpty ? first(\.password) : $0.password } ?? first(\.password),
                notes: String(notes.filter { !$0.isEmpty }.joined(separator: "\n").prefix(2000)),
                macs: macs, hostname: hostnames.first ?? "", addresses: addresses, rows: members.count)
        }

        // A device a cable names is the described device of that name, or a new bare one.
        var lookup: [String: String] = [:]   // normalized name → key
        for d in devices where lookup[norm(d.name)] == nil { lookup[norm(d.name)] = d.key }
        func named(_ name: String) -> String {
            if let hit = lookup[norm(name)] { return hit }
            let key = "d\(devices.count + 1)"
            devices.append(FoundDevice(key: key, name: name, role: InventoryRules.suggestRole(name: name, makeModel: "", category: "")))
            lookup[norm(name)] = key
            return key
        }
        var seen = Set<String>()
        var cables: [ImportRow] = []
        for w in wires {
            let signal = str(w.signal, 80)
            let fromCh = channel(w.fromChannel), toCh = channel(w.toChannel)
            let from = named(str(w.from)), to = named(str(w.to))
            if from == to || (fromCh == nil && signal.isEmpty) || (toCh == nil && signal.isEmpty) { continue }
            let fromCard = str(w.fromCard, 80), toCard = str(w.toCard, 80)
            let id = "\(from)|\(fromCard)|\(fromCh.map(String.init) ?? signal)|\(to)|\(toCard)|\(toCh.map(String.init) ?? signal)".lowercased()
            guard seen.insert(id).inserted else { continue }
            cables.append(ImportRow(fromDevice: from, fromCard: fromCard, fromChannel: fromCh, fromName: signal,
                                    toDevice: to, toCard: toCard, toChannel: toCh, toName: signal, note: str(w.note, 300)))
        }

        // Several devices with one name ("Audio DSP" in four rooms) are told apart by where they are, then by a number.
        func clash() -> [String: Int] { var n: [String: Int] = [:]; for d in devices { n[norm(d.name), default: 0] += 1 }; return n }
        var counts = clash()
        for i in devices.indices where (counts[norm(devices[i].name)] ?? 0) > 1 {
            let place = devices[i].location.isEmpty ? devices[i].room : devices[i].location
            if !place.isEmpty { devices[i].name = String("\(devices[i].name) (\(place))".prefix(200)) }
        }
        counts = clash()
        var nth: [String: Int] = [:]
        for i in devices.indices where (counts[norm(devices[i].name)] ?? 0) > 1 {
            let k = norm(devices[i].name)
            nth[k, default: 0] += 1
            if nth[k]! > 1 { devices[i].name += " \(nth[k]!)" }
        }
        return DocumentReading(summary: summary, devices: devices, cables: cables, warnings: warnings)
    }

    // MARK: Input lists

    /// An input or patch list is a table: a column of signal names, then a column per device (stage box, console,
    /// recorder) holding the channel each signal is on there. That shape is read exactly, without a model: each row is
    /// a cable from the first device that lists a channel for it (where the signal enters) to every later one.
    /// Returns nil when the text isn't such a table. Each blank-line-separated block (a workbook sheet) is tried.
    static func inputList(_ text: String) -> DocumentReading? {
        var devices: [FoundDevice] = []
        var cables: [ImportRow] = []
        var signals = 0
        for block in text.components(separatedBy: "\n\n") {
            // Title lines above a tab-separated table ("Sheet: Inputs", "Sunday Input List") would hide its tabs.
            var blockLines = block.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("Sheet: ") }
            if blockLines.contains(where: { $0.contains("\t") }) { blockLines = Array(blockLines.drop { !$0.contains("\t") }) }
            let rowsText = blockLines.joined(separator: "\n")
            let table = PatchImport.parseTable(rowsText).filter { $0.count >= 3 || $0.contains { !$0.isEmpty } }
            guard table.count >= 3 else { continue }
            func isChannel(_ v: String) -> Bool { channel(v) != nil && v.range(of: #"^\D{0,4}\d{1,4}$"#, options: .regularExpression) != nil }
            // The heading row is the last of the first few rows before the channel numbers start.
            guard let headAt = (0..<min(6, table.count - 2)).first(where: { i in
                table[i].filter { !$0.isEmpty }.count >= 3 && table[(i + 1)...].prefix(5).filter { $0.filter(isChannel).count >= 2 }.count >= 2
            }) else { continue }
            let head = table[headAt]
            let body = Array(table[(headAt + 1)...])
            let width = head.count
            func cells(_ c: Int) -> [String] { body.map { c < $0.count ? $0[c] : "" }.filter { !$0.isEmpty } }
            let numeric = (0..<width).filter { c in
                let v = cells(c)
                return v.count >= 2 && Double(v.filter(isChannel).count) >= Double(v.count) * 0.7 && !head[c].isEmpty
            }
            guard numeric.count >= 2 else { continue }
            let textCols = (0..<width).filter { !numeric.contains($0) && cells($0).count >= body.count / 2 }
            let named = textCols.first { head[$0].range(of: "signal|name|source|input|description|instrument|mic|label", options: [.regularExpression, .caseInsensitive]) != nil }
            guard let signalCol = named ?? textCols.first else { continue }
            let noteCol = (0..<width).first { !numeric.contains($0) && $0 != signalCol && head[$0].range(of: "note|comment", options: [.regularExpression, .caseInsensitive]) != nil }

            var keys: [Int: String] = [:]
            for c in numeric {
                // "Stage Box (DX168)" is the stage box, a DX168.
                let heading = str(head[c])
                var name = heading, model = ""
                if let m = heading.range(of: #"\s*\(([^)]+)\)\s*$"#, options: .regularExpression) {
                    model = String(heading[m]).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
                    name = String(heading[..<m.lowerBound])
                }
                if let existing = devices.first(where: { norm($0.name) == norm(name) }) { keys[c] = existing.key; continue }
                let key = "d\(devices.count + 1)"
                devices.append(FoundDevice(key: key, name: name, makeModel: model,
                                           role: InventoryRules.suggestRole(name: name, makeModel: model, category: "Audio"), rows: 1))
                keys[c] = key
            }
            for row in body {
                let signal = signalCol < row.count ? str(row[signalCol], 80) : ""
                let at = numeric.filter { $0 < row.count && isChannel(row[$0]) }
                guard !signal.isEmpty, at.count >= 2 else { continue }
                signals += 1
                let note = noteCol.flatMap { $0 < row.count ? str(row[$0], 300) : nil } ?? ""
                let from = at[0]
                for to in at.dropFirst() where keys[to] != keys[from] {
                    cables.append(ImportRow(fromDevice: keys[from]!, fromChannel: channel(row[from]), fromName: signal,
                                            toDevice: keys[to]!, toChannel: channel(row[to]), toName: signal, note: note))
                }
            }
        }
        guard !cables.isEmpty else { return nil }
        return DocumentReading(summary: "Read as an input list: \(signals) signals across \(devices.count) devices, each patched from where it enters to everything else that lists it.",
                               devices: devices, cables: cables, warnings: [])
    }

    // MARK: Matching

    private static func hasModel(_ k: Equipment, _ model: String) -> Bool {
        model.count >= 3 && (norm("\(k.name) \(k.makeModel)").contains(model) || (norm(k.makeModel).count >= 3 && model.contains(norm(k.makeModel))))
    }

    /// The inventory device a document's device most likely is. A serial number, MAC or IP address settles it;
    /// otherwise it goes by name and model. `known` should be the devices of the campus being imported into.
    static func match(_ found: FoundDevice, in known: [Equipment]) -> DeviceMatch? {
        var best: DeviceMatch?
        let sameRole = found.role.map { r in known.filter { $0.role == r } } ?? []
        let model = norm(found.makeModel)
        for k in known {
            var score = 0
            var why: [String] = []
            let notes = k.notes.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
            if !found.serial.isEmpty, !k.serial.isEmpty, norm(found.serial) == norm(k.serial) { score += 90; why.append("same serial number") }
            if found.macs.contains(where: { notes.contains($0) || String(k.macAddress.lowercased().filter(\.isHexDigit)).contains($0) }) { score += 90; why.append("same MAC address") }
            let ip = k.ipAddress.trimmingCharacters(in: .whitespaces)
            if isAddress(ip), found.addresses.contains(ip) { score += 60; why.append("same IP address") }
            if found.hostname.count > 3, notes.contains(norm(found.hostname)) { score += 30; why.append("same hostname") }
            let a = norm(found.name), b = norm(k.name)
            if !a.isEmpty && a == b { score += 55; why.append("same name") }
            else if nameWithin(found.name, k.name) { score += 45; why.append("similar name") }
            else {
                let mine = Set(words(found.name))
                let theirs = Set(words(k.name))
                let overlap = Double(theirs.intersection(mine).count) / Double(max(1, mine.union(theirs).count))
                if overlap >= 0.5 { score += Int((40 * overlap).rounded()); why.append("similar name") }
            }
            if hasModel(k, model) {
                // One of several identical units needs something more to say which; the only one of its model doesn't.
                let only = known.filter { hasModel($0, model) }.count == 1
                score += only ? 45 : 25
                why.append(only ? "the only one of that model" : "same model")
            }
            // A patch list says "Stage Box" or "SQ" and means the only one there is.
            if found.rows == 0, sameRole.count == 1, sameRole[0].id == k.id, score < matchThreshold, let r = found.role {
                score += 45; why.append("the only \(r.label.lowercased())")
            }
            if score > (best?.score ?? 0) { best = DeviceMatch(id: k.id, score: score, why: why.joined(separator: ", ")) }
        }
        return best.flatMap { $0.score >= matchThreshold ? $0 : nil }
    }

    /// Each found device's best match, with no inventory device claimed twice (the stronger claim keeps it).
    static func matchAll(_ found: [FoundDevice], in known: [Equipment]) -> [String: DeviceMatch] {
        var out: [String: DeviceMatch] = [:]
        var taken: [String: (key: String, score: Int)] = [:]
        var pool = known
        // A device that loses its match to a stronger claim gets another try against what's left.
        for _ in 0..<3 {
            var changed = false
            for d in found where out[d.key] == nil {
                guard let m = match(d, in: pool) else { continue }
                if let holder = taken[m.id] {
                    if holder.score >= m.score { continue }
                    out[holder.key] = nil
                }
                out[d.key] = m
                taken[m.id] = (d.key, m.score)
                changed = true
            }
            if !changed { break }
            pool = known.filter { taken[$0.id] == nil }
        }
        return out
    }
}
