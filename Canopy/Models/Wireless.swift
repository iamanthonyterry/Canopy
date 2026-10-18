import Foundation

// MARK: - Wireless receivers
// What a wireless mic receiver reports while it runs: each channel's name, RF
// level, audio level, battery and frequency. Everything here is plain data and
// text parsing with no network access, so it can be tested on its own. The
// strings follow the makers' own control documents:
//   Shure ULX-D command strings (TCP 2202, "< GET 1 ALL >" style),
//   Sennheiser Sound Control Protocol for EW-DX (UDP 45, JSON),
//   Audio-Technica IP Control Protocol 1.1.0 (TCP 17300, CR-ended lines).

nonisolated enum WirelessBrand: String, Codable, CaseIterable, Sendable {
    case shure, sennheiser, audioTechnica = "audio-technica"

    var label: String {
        switch self { case .shure: return "Shure"; case .sennheiser: return "Sennheiser"; case .audioTechnica: return "Audio-Technica" }
    }
    var port: Int {
        switch self { case .shure: return 2202; case .sennheiser: return 45; case .audioTechnica: return 17300 }
    }
    var usesUDP: Bool { self == .sennheiser }
    /// Every one of these receivers keeps a channel name to 8 characters.
    var nameLimit: Int { 8 }

    /// Models whose documents were checked: Shure ULX-D (QLX-D and Axient Digital share its command family),
    /// Sennheiser EW-DX, and Audio-Technica 3000 and 5000 series receivers.
    static func detect(name: String, makeModel: String) -> WirelessBrand? {
        let text = "\(makeModel) \(name)".lowercased()
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        if has(#"ulx-?d|qlx-?d|\bad4[dq]?\b|axient"#) { return .shure }
        if has(#"ew-?\s?dx"#) { return .sennheiser }
        if has(#"atw-?d?r\d{4}"#) { return .audioTechnica }
        return nil
    }

    /// IEM transmitters that can be watched. Only the Shure PSM1000 (P10T) so far; it speaks the same TCP 2202 command family.
    static func detectIEM(name: String, makeModel: String) -> WirelessBrand? {
        let text = "\(makeModel) \(name)".lowercased()
        return text.range(of: #"psm\s?-?1000|\bp10t\b"#, options: .regularExpression) != nil ? .shure : nil
    }

    /// How many channels a Shure receiver has, from its model: ULXD4 is one, ULXD4D two, ULXD4Q four.
    static func shureChannels(model: String) -> Int {
        let m = model.lowercased()
        if m.range(of: #"4q|d4q|ad4q"#, options: .regularExpression) != nil { return 4 }
        if m.range(of: #"4d|ad4d"#, options: .regularExpression) != nil { return 2 }
        return 1
    }

    /// A name the receiver will accept: its length limit, and only characters its document allows.
    func sanitizedName(_ raw: String) -> String {
        var allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -_.#&+")
        if self == .audioTechnica { allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _+-#&") }
        var text = raw.trimmingCharacters(in: .whitespaces)
        if self == .audioTechnica { text = text.uppercased() }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { allowed.contains(Character($0)) }).prefix(nameLimit))
            .trimmingCharacters(in: .whitespaces)
    }
}

nonisolated struct WirelessChannel: Hashable, Identifiable, Sendable {
    var index: Int
    var name = ""
    /// Strongest antenna, dBm.
    var rfDbm: Double?
    /// 0...1 where the receiver reports link quality (Sennheiser), else nil.
    var rfQuality: Double?
    /// "A", "B", "A+B", or "" when none.
    var antenna = ""
    /// 0...1 for a meter bar, and dBFS where the receiver gives it.
    var audioFraction: Double?
    var audioDb: Double?
    /// Right-hand audio level of an IEM mix (the left is audioFraction), nil on mono and on receivers.
    var audioRightFraction: Double?
    /// An IEM transmitter's RF output switch; nil on receivers.
    var rfOutput: Bool?
    /// 0...1 and a readable form, nil while unknown.
    var batteryFraction: Double?
    var batteryText = ""
    var transmitterPresent: Bool?
    var transmitterModel = ""
    var frequencyKHz: Int?
    var muted: Bool?
    var warnings: [String] = []
    var id: Int { index }

    /// A transmitter is on and the receiver hears it.
    var onAir: Bool { transmitterPresent != false && (rfDbm != nil || (rfQuality ?? 0) > 0 || rfOutput == true) }

    /// 0...1 for an RF bar, from dBm (-90 is weak, -30 is strong), or the receiver's own quality figure.
    var rfFraction: Double? {
        if let rfQuality { return rfQuality }
        guard let rfDbm else { return nil }
        return min(1, max(0, (rfDbm + 90) / 60))
    }
    var frequencyText: String {
        guard let k = frequencyKHz, k > 0 else { return "" }
        return String(format: "%.3f MHz", Double(k) / 1000)
    }
}

nonisolated struct WirelessSnapshot: Sendable {
    enum State: Equatable, Sendable { case connecting, live, offline(String) }
    var state: State = .connecting
    var model = ""
    var channels: [Int: WirelessChannel] = [:]
    var heard: Date?

    var sorted: [WirelessChannel] { channels.values.sorted { $0.index < $1.index } }

    mutating func update(_ index: Int, _ change: (inout WirelessChannel) -> Void) {
        var c = channels[index] ?? WirelessChannel(index: index)
        change(&c)
        channels[index] = c
    }
}

// MARK: - Shure

nonisolated enum ShureProtocol {
    /// Pulls every complete "< ... >" message out of the buffer, leaving any partial one behind.
    static func extract(_ buffer: inout String) -> [String] {
        var out: [String] = []
        while let open = buffer.firstIndex(of: "<") {
            // A channel name sits in braces and may hold a ">", so look for the closing one past any open brace.
            var depth = 0
            var close: String.Index?
            var i = buffer.index(after: open)
            while i < buffer.endIndex {
                let c = buffer[i]
                if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) }
                else if c == ">" && depth == 0 { close = i; break }
                i = buffer.index(after: i)
            }
            guard let close else { buffer = String(buffer[open...]); return out }
            out.append(String(buffer[buffer.index(after: open)..<close]).trimmingCharacters(in: .whitespaces))
            buffer = String(buffer[buffer.index(after: close)...])
        }
        if !buffer.contains("<") { buffer = "" }
        return out
    }

    /// Splits "REP 1 CHAN_NAME {Pastor 1}" into words, keeping a braced name as one word.
    static func words(_ message: String) -> [String] {
        var out: [String] = []
        var current = ""
        var depth = 0
        for c in message {
            if c == "{" { depth += 1 }
            if c == "}" { depth = max(0, depth - 1) }
            if c == " " && depth == 0 {
                if !current.isEmpty { out.append(current); current = "" }
            } else { current.append(c) }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func unbrace(_ s: String) -> String {
        var t = s
        if t.hasPrefix("{") { t.removeFirst() }
        if t.hasSuffix("}") { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func get(_ channel: Int, _ property: String) -> String { "< GET \(channel) \(property) >" }
    static func meterRate(_ channel: Int, milliseconds: Int) -> String { "< SET \(channel) METER_RATE \(String(format: "%05d", milliseconds)) >" }
    static func setName(_ channel: Int, _ name: String) -> String { "< SET \(channel) CHAN_NAME {\(name)} >" }

    /// Applies one message to the snapshot. Returns true if it was one we understand.
    @discardableResult
    static func apply(_ message: String, to snap: inout WirelessSnapshot) -> Bool {
        let w = words(message)
        guard w.count >= 2 else { return false }
        if w[0] == "REP", w[1] == "MODEL", w.count >= 3 { snap.model = unbrace(w[2...].joined(separator: " ")); return true }
        guard let ch = Int(w[1]), (1...8).contains(ch) else { return false }
        switch w[0] {
        case "SAMPLE":
            // SAMPLE x ALL nn aaa eee: antenna status, RF level per antenna, then audio level.
            guard w.count >= 5, w[2] == "ALL" else { return false }
            let antenna = w[3]
            let levels = w[4...].compactMap { Int($0) }
            guard levels.count >= 2 else { return false }
            let audio = levels[levels.count - 1]
            let rf = levels.dropLast().max() ?? 0
            snap.update(ch) { c in
                c.antenna = antenna == "AB" ? "A+B" : antenna == "AX" ? "A" : antenna == "XB" ? "B" : ""
                c.rfDbm = antenna == "XX" ? nil : Double(rf) - 128
                // Receiver reports dBFS + 50, so 50 is full scale.
                c.audioDb = Double(audio) - 50
                c.audioFraction = min(1, max(0, Double(audio) / 50))
            }
            return true
        case "REP":
            guard w.count >= 4 else { return false }
            let value = w[3...].joined(separator: " ")
            switch w[2] {
            case "CHAN_NAME": snap.update(ch) { $0.name = unbrace(value) }
            case "TX_TYPE": snap.update(ch) { $0.transmitterModel = value == "UNKN" ? "" : value; $0.transmitterPresent = value != "UNKN" }
            case "BATT_BARS":
                let bars = Int(value) ?? 255
                snap.update(ch) {
                    if bars == 255 { $0.batteryFraction = nil; $0.batteryText = "" }
                    else { $0.batteryFraction = Double(min(bars, 5)) / 5; $0.batteryText = "\(min(bars, 5)) of 5 bars" }
                }
            case "BATT_CHARGE":
                let pct = Int(value) ?? 255
                if pct <= 100 { snap.update(ch) { $0.batteryFraction = Double(pct) / 100; $0.batteryText = "\(pct)%" } }
            case "FREQUENCY": snap.update(ch) { $0.frequencyKHz = Int(value) }
            case "AUDIO_MUTE": snap.update(ch) { $0.muted = value == "ON" }
            default: return false
            }
            return true
        default: return false
        }
    }
}

// MARK: - Shure PSM1000 (IEM)
// UNVERIFIED: the PSM1000 (P10T) command strings below follow the ULX-D family and have not been checked
// against Shure's PSM1000 document or a real unit. Specifically assumed: "SAMPLE n ALL <left> [<right>]" for
// the input meter (dBFS + 50, like ULX-D), "REP n RF_OUTPUT ON|OFF", and the CHAN_NAME, FREQUENCY and
// AUDIO_MUTE reports. Anything that doesn't match is ignored rather than guessed at.

nonisolated enum ShurePSMProtocol {
    /// The P10T is a dual-channel transmitter.
    static let channelCount = 2

    @discardableResult
    static func apply(_ message: String, to snap: inout WirelessSnapshot) -> Bool {
        let w = ShureProtocol.words(message)
        guard w.count >= 2 else { return false }
        if w[0] == "REP", w[1] == "MODEL", w.count >= 3 { snap.model = ShureProtocol.unbrace(w[2...].joined(separator: " ")); return true }
        guard let ch = Int(w[1]), (1...channelCount).contains(ch) else { return false }
        func fraction(_ v: Int) -> Double { min(1, max(0, Double(v) / 50)) }
        switch w[0] {
        case "SAMPLE":
            guard w.count >= 4, w[2] == "ALL" else { return false }
            let levels = w[3...].compactMap { Int($0) }
            guard let left = levels.first else { return false }
            snap.update(ch) { c in
                c.audioDb = Double(left) - 50
                c.audioFraction = fraction(left)
                c.audioRightFraction = levels.count >= 2 ? fraction(levels[1]) : nil
            }
            return true
        case "REP":
            guard w.count >= 4 else { return false }
            let value = w[3...].joined(separator: " ")
            switch w[2] {
            case "CHAN_NAME": snap.update(ch) { $0.name = ShureProtocol.unbrace(value) }
            case "FREQUENCY": snap.update(ch) { $0.frequencyKHz = Int(value) }
            case "AUDIO_MUTE": snap.update(ch) { $0.muted = value == "ON" }
            case "RF_OUTPUT": snap.update(ch) { $0.rfOutput = value == "ON"; $0.transmitterPresent = value == "ON" }
            default: return false
            }
            return true
        default: return false
        }
    }
}

// MARK: - Sennheiser

nonisolated enum SennheiserProtocol {
    /// One request that reads every meter on a channel: RF strength, link quality, diversity and audio level.
    static func meterRequest(_ channel: Int) -> String {
        "{\"m\":{\"rx\(channel)\":{\"rssi\":null,\"rsqi\":null,\"divi\":null,\"af\":null}}}"
    }
    /// The slower facts about a channel: name, mute, frequency, warnings and the transmitter's battery.
    static func statusRequest(_ channel: Int) -> String {
        "{\"rx\(channel)\":{\"name\":null,\"mute\":null,\"frequency\":null,\"warnings\":null},"
        + "\"mates\":{\"tx\(channel)\":{\"battery\":{\"gauge\":null,\"lifetime\":null},\"type\":null}}}"
    }
    static func probeRequest(_ channel: Int) -> String { "{\"rx\(channel)\":{\"name\":null}}" }
    static func setName(_ channel: Int, _ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"rx\(channel)\":{\"name\":\"\(escaped)\"}}"
    }

    /// Applies one reply datagram. Returns the channels it mentioned.
    @discardableResult
    static func apply(_ data: Data, to snap: inout WirelessSnapshot) -> Set<Int> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var seen: Set<Int> = []
        /// An error reply echoes the address with null, so only a branch holding a real value counts.
        func hasValue(_ d: [String: Any]) -> Bool {
            d.values.contains { v in
                if v is NSNull { return false }
                if let nested = v as? [String: Any] { return hasValue(nested) }
                return true
            }
        }
        func number(_ v: Any?) -> Double? { (v as? NSNumber).flatMap { $0 === kCFBooleanTrue || $0 === kCFBooleanFalse ? nil : $0.doubleValue } }

        if let m = root["m"] as? [String: Any] {
            for (key, value) in m {
                guard key.hasPrefix("rx"), let ch = Int(key.dropFirst(2)), let d = value as? [String: Any], hasValue(d) else { continue }
                seen.insert(ch)
                snap.update(ch) { c in
                    if let rssi = number(d["rssi"]) { c.rfDbm = rssi }
                    if let q = number(d["rsqi"]) { c.rfQuality = min(1, max(0, q / 100)) }
                    if let divi = number(d["divi"]) { c.antenna = divi == 1 ? "A" : divi == 2 ? "B" : "" }
                    if let af = number(d["af"]) { c.audioDb = af; c.audioFraction = min(1, max(0, (af + 60) / 60)) }
                }
            }
        }
        for (key, value) in root {
            guard key.hasPrefix("rx"), let ch = Int(key.dropFirst(2)), let d = value as? [String: Any], hasValue(d) else { continue }
            seen.insert(ch)
            snap.update(ch) { c in
                if let name = d["name"] as? String { c.name = name.trimmingCharacters(in: .whitespaces) }
                if let mute = d["mute"] as? Bool { c.muted = mute }
                if let f = number(d["frequency"]) { c.frequencyKHz = Int(f) }
                if let warnings = d["warnings"] as? [String] {
                    c.warnings = warnings
                    c.transmitterPresent = !warnings.contains("NoLink")
                }
            }
        }
        if let mates = root["mates"] as? [String: Any] {
            for (key, value) in mates {
                guard key.hasPrefix("tx"), let ch = Int(key.dropFirst(2)), let d = value as? [String: Any], hasValue(d) else { continue }
                seen.insert(ch)
                snap.update(ch) { c in
                    if let type = d["type"] as? String { c.transmitterModel = type }
                    if let b = d["battery"] as? [String: Any] {
                        if let gauge = number(b["gauge"]) {
                            c.batteryFraction = min(1, max(0, gauge / 100))
                            let minutes = number(b["lifetime"]).map { Int($0) }
                            c.batteryText = "\(Int(gauge))%" + (minutes.map { " · \($0 / 60)h \($0 % 60)m left" } ?? "")
                        }
                    }
                }
            }
        }
        return seen
    }
}

// MARK: - Audio-Technica

nonisolated enum AudioTechnicaProtocol {
    /// Command lines end with a carriage return and use single spaces between fields.
    static func line(_ command: String, handshake: String, parameters: String) -> String {
        "\(command) \(handshake) 0000 00 NC \(parameters)\r"
    }
    static func levelRequest(_ rx: Int) -> String { line("garlv", handshake: "O", parameters: "\(rx)") }
    static func nameRequest(_ rx: Int) -> String { line("gprch", handshake: "O", parameters: "\(rx)") }
    /// Changes only the name: every other field is left blank, which the document says means unchanged.
    static func setName(_ rx: Int, _ name: String) -> String {
        line("sprch", handshake: "S", parameters: "\(rx),\"\(name)\",,,,,,,,")
    }

    /// Splits parameters on commas that aren't inside quotes.
    static func fields(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        for c in s {
            if c == "\"" { quoted.toggle(); current.append(c) }
            else if c == "," && !quoted { out.append(current); current = "" }
            else { current.append(c) }
        }
        out.append(current)
        return out
    }

    /// The parts of an answer line: its command, and the parameters after "0000 00 NC ".
    static func parse(_ line: String) -> (command: String, params: String)? {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let command = String(parts[0])
        if parts[1] == "ACK" || parts[1] == "NAK" { return nil }
        guard parts.count == 5, parts[3] == "NC" else { return nil }
        return (command, String(parts[4]).trimmingCharacters(in: .whitespaces))
    }

    private static let batteryMid: [Double] = [0.1, 0.3, 0.5, 0.7, 0.9]
    private static let batteryRange = ["0–19%", "20–39%", "40–59%", "60–79%", "80–100%"]

    /// Applies one answer line. Returns true if it was one we understand.
    @discardableResult
    static func apply(_ line: String, to snap: inout WirelessSnapshot) -> Bool {
        guard let (command, params) = parse(line) else { return false }
        let f = fields(params)
        guard let rx = f.first.flatMap({ Int($0) }) else { return false }
        switch command {
        case "gprch":
            guard f.count >= 2 else { return false }
            let name = f[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).trimmingCharacters(in: .whitespaces)
            snap.update(rx) { $0.name = name }
            return true
        case "garlv":
            // RX, TX audio meter, RX audio meter (0-16), antenna A meter and dBm, antenna B meter and dBm, then
            // many status fields, and at the end: battery type, battery level (0-4), frequency (Hz), group, channel.
            guard f.count >= 12 else { return false }
            let audio = Double(f[2])
            let meterA = Int(f[3]) ?? 0, meterB = Int(f[5]) ?? 0
            let dbmA = Double(f[4]), dbmB = Double(f[6])
            var heard: [Double] = []
            if meterA > 0, let dbmA { heard.append(dbmA) }
            if meterB > 0, let dbmB { heard.append(dbmB) }
            let level = Int(f[f.count - 4])
            let hz = Int(f[f.count - 3])
            snap.update(rx) { c in
                c.audioFraction = audio.map { min(1, max(0, $0 / 16)) }
                c.rfDbm = heard.max()
                c.antenna = meterA > 0 && meterB > 0 ? "A+B" : meterA > 0 ? "A" : meterB > 0 ? "B" : ""
                c.transmitterPresent = meterA > 0 || meterB > 0
                if let level, (0...4).contains(level) { c.batteryFraction = batteryMid[level]; c.batteryText = batteryRange[level] }
                if let hz, hz > 0 { c.frequencyKHz = hz / 1000 }
            }
            return true
        default: return false
        }
    }
}
