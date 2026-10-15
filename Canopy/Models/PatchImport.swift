import Foundation

// MARK: - Patch sheet import / export
// Reads cables out of a spreadsheet saved as CSV (or copied from one as
// tab-separated text), and writes the patch sheet back out the same way.
// Headings are matched loosely ("From device", "Source channel", "Dest.
// connector", "Notes"…). "Card" is optional: leave it blank for a device's own
// channels, or give a slot ("Slot 1", "1") or part of the card's name ("Dante").

nonisolated struct ImportRow: Hashable, Sendable {
    var fromDevice = "", fromCard = "", fromChannel: Int? = nil, fromName = "", fromKind = ""
    var toDevice = "", toCard = "", toChannel: Int? = nil, toName = "", toKind = ""
    var note = ""
}

nonisolated enum PatchImport {
    static let maxRows = 1000
    static let headers = ["From device", "From card", "From channel", "From name", "From connector", "To device", "To card", "To channel", "To name", "To connector", "Note"]
    static let example = [
        ["Stage box", "", "1", "Kick In", "XLR", "Mixer", "", "1", "Kick In", "XLR", ""],
        ["Stage box", "", "2", "Snare Top", "XLR", "Mixer", "", "2", "Snare Top", "XLR", "Long run, snake A"],
        ["Mixer", "Dante", "1", "IEM Mix 1 L", "", "IEM transmitter", "Dante", "1", "", "", "Dante to the transmitter"],
    ]

    /// Splits CSV or TSV text into rows of cells (quoted cells may hold commas, tabs and line breaks).
    static func parseTable(_ raw: String) -> [[String]] {
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        let firstLine = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let delimiter: Character = firstLine.contains("\t") ? "\t"
            : firstLine.split(separator: ";", omittingEmptySubsequences: false).count > firstLine.split(separator: ",", omittingEmptySubsequences: false).count ? ";" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        let chars = Array(text.unicodeScalars.map(Character.init))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"", i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 }
                else if c == "\"" { quoted = false }
                else { cell.append(c) }
            } else if c == "\"", cell.isEmpty {
                quoted = true
            } else if c == delimiter {
                row.append(cell); cell = ""
            } else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(cell); cell = ""
                rows.append(row); row = []
            } else {
                cell.append(c)
            }
            i += 1
        }
        row.append(cell)
        rows.append(row)
        return rows.map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }.filter { $0.contains { !$0.isEmpty } }
    }

    private enum Field { case device, card, channel, name, kind }
    private enum Column { case note; case side(from: Bool, field: Field) }

    private static func column(_ heading: String) -> Column? {
        let h = heading.lowercased().replacingOccurrences(of: #"[^a-z0-9#]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: "^(\(pattern))$", options: .regularExpression) != nil }
        if matches(h, "notes?|comments?|cable|cable notes?") { return .note }
        guard let m = h.range(of: #"^(from|source|src|out|output|to|dest|destination|in|input)\b"#, options: .regularExpression) else { return nil }
        let lead = String(h[m])
        let rest = h[m.upperBound...].trimmingCharacters(in: .whitespaces)
        let from = matches(lead, "from|source|src|out|output")
        let field: Field?
        if rest.isEmpty || matches(rest, "device|equipment|gear|unit") { field = .device }
        else if matches(rest, "card|option card|slot|card slot") { field = .card }
        else if matches(rest, "channel|ch|chan|number|num|no|#|port|port number|channel number") { field = .channel }
        else if matches(rest, "name|label|signal|description|desc|port name|channel name") { field = .name }
        else if matches(rest, "connector|connection|type|kind|jack|plug") { field = .kind }
        else { field = nil }
        return field.map { .side(from: from, field: $0) }
    }

    private static func channel(_ v: String) -> Int? {
        guard let r = v.range(of: #"\d{1,4}$"#, options: .regularExpression),
              v[..<r.lowerBound].allSatisfy({ !$0.isNumber }),
              let n = Int(v[r]), (1...9999).contains(n) else { return nil }
        return n
    }

    /// Reads the whole sheet. Rows that can't be used are skipped and described in `problems` (with their spreadsheet row number).
    static func parse(_ raw: String) -> (rows: [ImportRow], problems: [String]) {
        let table = parseTable(raw)
        guard table.count >= 2 else { return ([], ["Add a heading row and at least one cable."]) }
        let columns = table[0].map(column)
        func has(_ from: Bool, _ fields: [Field]) -> Bool {
            columns.contains { if case .side(let f, let x)? = $0 { return f == from && fields.contains(x) }; return false }
        }
        let missing = [true, false].filter { !has($0, [.device]) || !has($0, [.channel, .name]) }.map { $0 ? "from" : "to" }
        if !missing.isEmpty {
            return ([], ["Couldn't find the \(missing.joined(separator: " and ")) columns. The headings should be: \(headers.joined(separator: ", "))."])
        }
        var rows: [ImportRow] = []
        var problems: [String] = []
        for (i, cells) in table.dropFirst().enumerated() {
            let at = i + 2
            var out = ImportRow()
            var bad = ""
            for (x, col) in columns.enumerated() {
                let v = String((x < cells.count ? cells[x] : "").prefix(200))
                guard let col, !v.isEmpty else { continue }
                switch col {
                case .note: out.note = v
                case .side(let from, let field):
                    switch field {
                    case .device: if from { out.fromDevice = v } else { out.toDevice = v }
                    case .card: if from { out.fromCard = v } else { out.toCard = v }
                    case .name: if from { out.fromName = v } else { out.toName = v }
                    case .kind: if from { out.fromKind = v } else { out.toKind = v }
                    case .channel:
                        if let n = channel(v) { if from { out.fromChannel = n } else { out.toChannel = n } }
                        else { bad = "row \(at): \"\(v)\" isn't a channel number" }
                    }
                }
            }
            if !bad.isEmpty { problems.append(bad) }
            else if out.fromDevice.isEmpty || out.toDevice.isEmpty { problems.append("row \(at): needs a device on both ends") }
            else if (out.fromChannel == nil && out.fromName.isEmpty) || (out.toChannel == nil && out.toName.isEmpty) { problems.append("row \(at): needs a channel number or name on both ends") }
            else { rows.append(out) }
        }
        if rows.count > maxRows { return ([], ["That's \(rows.count) cables; import at most \(maxRows) at a time."]) }
        return (rows, problems)
    }

    static func csv(_ table: [[String]]) -> String {
        table.map { row in
            row.map { v in v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"\(v.replacingOccurrences(of: "\"", with: "\"\""))\"" : v }
                .joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }

    static var templateCSV: String { csv([headers] + example) }

    /// The cables the model found in a document, laid out as a patch sheet (its device keys swapped for their names).
    static func sheet(from reading: DocumentReading) -> String {
        let names = Dictionary(reading.devices.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        return csv([headers] + reading.cables.map { c in
            [names[c.fromDevice] ?? c.fromDevice, c.fromCard, c.fromChannel.map(String.init) ?? "", c.fromName, c.fromKind,
             names[c.toDevice] ?? c.toDevice, c.toCard, c.toChannel.map(String.init) ?? "", c.toName, c.toKind, c.note]
        })
    }

    /// The patch sheet in the import format, so it can be edited in a spreadsheet and brought back in.
    static func export(_ patches: [Patch]) -> String {
        csv([headers] + patches.map { p in
            [p.from.device.name, p.from.device.card(p.from.port.cardId).map { "Slot \($0.slot)" } ?? "", p.from.port.number.map(String.init) ?? "", p.from.port.label, p.from.port.kind,
             p.to.device.name, p.to.device.card(p.to.port.cardId).map { "Slot \($0.slot)" } ?? "", p.to.port.number.map(String.init) ?? "", p.to.port.label, p.to.port.kind,
             p.cable.note]
        })
    }
}
