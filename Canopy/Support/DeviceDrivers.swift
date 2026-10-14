import Foundation
import Network

// MARK: - Apply-to-device drivers
// Sends a config from the church site's inventory to a device on this
// network. Ported from the Transcriber's DeviceAgent so the two behave the
// same: only protocols checked against the maker's documentation, only
// addresses on this network, and the content is re-checked before sending.

nonisolated struct DeviceApplyError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Only devices on this network: private IPv4 ranges, link-local, loopback, or a `.local` name.
nonisolated func isLocalAddress(_ host: String) -> Bool {
    let h = host.lowercased()
    if h.hasSuffix(".local") || h == "localhost" { return true }
    let parts = h.split(separator: ".")
    let p = parts.compactMap { Int($0) }
    guard parts.count == 4, p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
    switch (p[0], p[1]) {
    case (10, _), (127, _), (192, 168), (169, 254): return true
    case (172, 16...31): return true
    default: return false
    }
}

/// Blackmagic Videohub Ethernet Protocol 2.3: text blocks on TCP 9990. A block we send is answered with ACK or NAK.
nonisolated enum Videohub {
    /// Only these blocks may be sent; locks, serial directions and anything else are refused.
    static let allowed: Set<String> = [
        "INPUT LABELS", "OUTPUT LABELS", "MONITORING OUTPUT LABELS", "SERIAL PORT LABELS",
        "VIDEO OUTPUT ROUTING", "VIDEO MONITORING OUTPUT ROUTING", "SERIAL PORT ROUTING",
    ]

    static func blocks(_ body: String) throws -> [String] {
        var out: [String] = []
        for raw in body.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n") {
            let block = raw.trimmingCharacters(in: .newlines)
            if block.isEmpty { continue }
            let lines = block.components(separatedBy: "\n")
            guard let head = lines.first, head.hasSuffix(":"), allowed.contains(String(head.dropLast())) else {
                throw DeviceApplyError("The file contains something a Videohub config may not change.")
            }
            let isLabels = head.contains("LABELS")
            for line in lines.dropFirst() {
                let ok = isLabels
                    ? line.range(of: #"^\d{1,3} \S.{0,59}$"#, options: .regularExpression) != nil
                    : line.range(of: #"^\d{1,3} \d{1,3}$"#, options: .regularExpression) != nil
                guard ok else { throw DeviceApplyError("The file has a line the Videohub protocol doesn't accept.") }
            }
            out.append(block + "\n\n")
        }
        guard !out.isEmpty, out.count <= 7 else { throw DeviceApplyError("The file has nothing to apply.") }
        return out
    }

    static func apply(host: String, port: Int = 9990, body: String) async throws -> String {
        let blocks = try blocks(body)
        let payload = Data(blocks.joined().utf8)
        let reply = try await TCPExchange.run(host: host, port: port, send: payload, timeout: 8) { data in
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            return lines.filter { $0 == "ACK" || $0 == "NAK" }.count >= blocks.count
        }
        let text = String(decoding: reply, as: UTF8.self)
        guard text.contains("PROTOCOL PREAMBLE") else { throw DeviceApplyError("\(host) didn't answer like a Videohub.") }
        // The Videohub software answers even with no hardware behind it, and ACKs anything. Don't call that success.
        if text.contains("Device present: false") { throw DeviceApplyError("\(host) has no Videohub attached (the Videohub software is running but sees no unit).") }
        if text.contains("Device present: needs") { throw DeviceApplyError("The Videohub at \(host) needs a firmware update before it can be changed.") }
        let lines = text.components(separatedBy: "\n")
        let acks = lines.filter { $0 == "ACK" }.count
        let naks = lines.filter { $0 == "NAK" }.count
        if naks > 0 { throw DeviceApplyError("The Videohub rejected \(naks) of \(blocks.count) blocks.") }
        guard acks >= blocks.count else { throw DeviceApplyError("The Videohub didn't confirm every block (\(acks) of \(blocks.count)).") }
        return "Applied \(blocks.count) \(blocks.count == 1 ? "block" : "blocks") to the Videohub."
    }
}

/// Allen & Heath dLive and Avantis MIDI over TCP (port 51325): a bank select then a program change on the
/// console's base MIDI channel recalls a scene. Scenes 1–128 are bank 0, 129–256 bank 1, and so on.
nonisolated enum AllenHeath {
    static func message(scene: Int, channel: Int) -> Data? {
        guard (1...500).contains(scene), (1...12).contains(channel) else { return nil }
        let index = scene - 1
        let n = UInt8(channel - 1)
        return Data([0xB0 | n, 0x00, UInt8(index / 128), 0xC0 | n, UInt8(index % 128)])
    }

    static func recallScene(host: String, scene: Int, channel: Int) async throws -> String {
        guard let bytes = message(scene: scene, channel: channel) else { throw DeviceApplyError("That scene number isn't valid.") }
        // The console doesn't acknowledge a recall; it just does it. Give it a moment before closing.
        _ = try await TCPExchange.run(host: host, port: 51325, send: bytes, timeout: 0.6) { _ in false }
        return "Sent the recall for scene \(scene). Check that the console shows it."
    }
}

nonisolated enum TCPExchange {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var finished = false
        var continuation: CheckedContinuation<Data, Error>?
        func append(_ d: Data) -> Data { lock.withLock { data.append(d); return data } }
        func snapshot() -> Data { lock.withLock { data } }
        func finish(_ result: Result<Data, Error>) -> Bool {
            let c: CheckedContinuation<Data, Error>? = lock.withLock {
                if finished { return nil }
                finished = true
                defer { continuation = nil }
                return continuation
            }
            guard let c else { return false }
            switch result {
            case .success(let d): c.resume(returning: d)
            case .failure(let e): c.resume(throwing: e)
            }
            return true
        }
    }

    /// Opens a TCP connection, sends `send`, and collects what comes back until `done` says it has enough, the
    /// device closes, or `timeout` passes (which returns whatever arrived; the caller decides if that's enough).
    /// Fails only when the device can't be reached.
    static func run(host: String, port: Int, send: Data, timeout: TimeInterval, done: @escaping @Sendable (Data) -> Bool) async throws -> Data {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw DeviceApplyError("Bad port.") }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let box = Box()
            box.continuation = cont
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let queue = DispatchQueue(label: "canopy.device.tcp")
            @Sendable func end(_ r: Result<Data, Error>) {
                if box.finish(r) { conn.cancel() }
            }
            @Sendable func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        if done(box.append(data)) { return end(.success(box.snapshot())) }
                    }
                    if isComplete || error != nil { return end(.success(box.snapshot())) }
                    receive()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: send, completion: .contentProcessed { error in
                        if error != nil { end(.failure(DeviceApplyError("Couldn't send to \(host)."))) } else { receive() }
                    })
                case .failed, .waiting:
                    end(.failure(DeviceApplyError("Can't reach \(host) on port \(port). Check its IP address and that this Mac is on the same network.")))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { end(.success(box.snapshot())) }
            conn.start(queue: queue)
        }
    }
}
