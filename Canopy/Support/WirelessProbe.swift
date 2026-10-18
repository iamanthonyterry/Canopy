import Foundation
import Network
import Darwin

// MARK: - Finding wireless gear on the network
// Wireless receivers don't reliably announce themselves over Bonjour, so the scan asks instead: it tries each
// address on this computer's own subnets with the same read-only question the monitor opens with, and keeps the
// ones that answer in a way only that maker's receiver would. Nothing is ever written to a device. Only private
// addresses are contacted, and addresses already in the inventory are skipped (an Audio-Technica receiver
// allows one control connection at a time, so a probe must never knock off the monitor).

nonisolated struct DiscoveredWireless: Hashable, Identifiable, Sendable {
    var ip: String
    var brand: WirelessBrand
    /// What the device called itself, when it said ("ULXD4D", "EW-DX EM 2"); "" otherwise.
    var model: String
    var iem: Bool
    var id: String { ip }

    var title: String { model.isEmpty ? "\(brand.label) \(iem ? "IEM transmitter" : "receiver")" : "\(brand.label) \(model)" }
    var makeModel: String { model.isEmpty ? brand.label : "\(brand.label) \(model)" }
}

nonisolated enum WirelessProbe {
    /// Every host address on the /24 around each of this computer's private IPv4 addresses, minus its own.
    static func candidateHosts() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  Int32(ifa.pointee.ifa_flags) & IFF_UP != 0, Int32(ifa.pointee.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let mine = String(cString: buf)
            let parts = mine.split(separator: ".")
            guard parts.count == 4, isLocalAddress(mine), !mine.hasPrefix("169.254.") else { continue }
            let prefix = parts[0..<3].joined(separator: ".")
            guard seen.insert(prefix).inserted else { continue }
            for n in 1...254 where "\(prefix).\(n)" != mine { out.append("\(prefix).\(n)") }
        }
        return out
    }

    /// Probes the hosts, a few dozen at a time, calling `found` for each wireless device that answers.
    static func sweep(_ hosts: [String], skipping known: Set<String>, found: @escaping @Sendable (DiscoveredWireless) async -> Void) async {
        let todo = hosts.filter { !known.contains($0) }
        var index = 0
        let width = 48
        await withTaskGroup(of: Void.self) { group in
            func next() {
                guard index < todo.count, !Task.isCancelled else { return }
                let host = todo[index]
                index += 1
                group.addTask { if let hit = await identify(host) { await found(hit) } }
            }
            for _ in 0..<min(width, todo.count) { next() }
            while await group.next() != nil { next() }
        }
    }

    /// Asks one host the three questions, cheapest first. A host that answers none of them is not wireless gear.
    static func identify(_ host: String) async -> DiscoveredWireless? {
        if let reply = await exchange(host, port: WirelessBrand.shure.port, udp: false, send: [ShureProtocol.get(0, "MODEL")]) {
            var snap = WirelessSnapshot()
            var buffer = String(decoding: reply, as: UTF8.self)
            var understood = false
            for message in ShureProtocol.extract(&buffer) where ShureProtocol.apply(message, to: &snap) { understood = true }
            if understood {
                let model = snap.model
                let iem = WirelessBrand.detectIEM(name: "", makeModel: model) != nil
                // A Shure box that isn't a receiver we know and isn't a PSM1000 (a charger or network switch, say) is left out.
                if iem || WirelessBrand.detect(name: "", makeModel: model) != nil || model.isEmpty {
                    return DiscoveredWireless(ip: host, brand: .shure, model: model, iem: iem)
                }
            }
        }
        if let reply = await exchange(host, port: WirelessBrand.sennheiser.port, udp: true,
                                      send: [SennheiserProtocol.probeRequest(1), identityRequest]) {
            var snap = WirelessSnapshot()
            if !SennheiserProtocol.apply(reply, to: &snap).isEmpty {
                return DiscoveredWireless(ip: host, brand: .sennheiser, model: product(in: reply), iem: false)
            }
        }
        if let reply = await exchange(host, port: WirelessBrand.audioTechnica.port, udp: false, send: [AudioTechnicaProtocol.nameRequest(1)]) {
            var snap = WirelessSnapshot()
            let lines = String(decoding: reply, as: UTF8.self).components(separatedBy: "\r")
            if lines.contains(where: { !$0.isEmpty && AudioTechnicaProtocol.apply($0, to: &snap) }) {
                return DiscoveredWireless(ip: host, brand: .audioTechnica, model: "", iem: false)
            }
        }
        return nil
    }

    /// Sennheiser Sound Control Protocol: the device's own product name.
    static let identityRequest = "{\"device\":{\"identity\":{\"product\":null}}}"

    static func product(in data: Data) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let device = root["device"] as? [String: Any], let identity = device["identity"] as? [String: Any],
              let product = identity["product"] as? String else { return "" }
        return product.trimmingCharacters(in: .whitespaces)
    }

    // MARK: One question

    /// Connects, sends the messages, and returns what came back, or nil when nothing answered in time.
    /// A refused or silent connection ends within `timeout` seconds.
    private static func exchange(_ host: String, port: Int, udp: Bool, send messages: [String], timeout: Double = 1.2) async -> Data? {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        return await withCheckedContinuation { continuation in
            Exchange(host: host, port: p, udp: udp, messages: messages, timeout: timeout, continuation: continuation).start()
        }
    }

    private final class Exchange: @unchecked Sendable {
        private let conn: NWConnection
        private let messages: [String]
        private let timeout: Double
        private let queue = DispatchQueue(label: "canopy.wireless.probe")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var data = Data()

        init(host: String, port: NWEndpoint.Port, udp: Bool, messages: [String], timeout: Double, continuation: CheckedContinuation<Data?, Never>) {
            conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: udp ? .udp : .tcp)
            self.messages = messages
            self.timeout = timeout
            self.continuation = continuation
        }

        func start() {
            conn.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    for m in messages { conn.send(content: Data(m.utf8), completion: .contentProcessed { _ in }) }
                    receive()
                case .failed, .cancelled, .waiting: finish()
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in finish() }
        }

        private func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, complete, error in
                if let chunk, !chunk.isEmpty {
                    lock.withLock { data.append(chunk) }
                    // Give a second datagram or the rest of a reply a moment, then stop.
                    queue.asyncAfter(deadline: .now() + 0.25) { [self] in finish() }
                }
                if error != nil || complete { return finish() }
                receive()
            }
        }

        /// Hands back what was heard, the first time only.
        private func finish() {
            let (cont, heard): (CheckedContinuation<Data?, Never>?, Data) = lock.withLock {
                defer { continuation = nil }
                return (continuation, data)
            }
            guard let cont else { return }
            conn.cancel()
            cont.resume(returning: heard.isEmpty ? nil : heard)
        }
    }
}
