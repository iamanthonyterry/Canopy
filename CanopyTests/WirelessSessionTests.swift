import Foundation
import Network
import Testing
@testable import Canopy

/// A stand-in receiver on this machine that answers the way the makers' documents say a real one does.
private final class FakeReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "canopy.test.fake-receiver")
    private let lock = NSLock()
    private var _received: [String] = []
    private let respond: @Sendable (String) -> [String]

    var received: [String] { lock.withLock { _received } }

    init(port: UInt16, respond: @escaping @Sendable (String) -> [String]) throws {
        self.respond = respond
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.read(conn)
        }
        listener.start(queue: queue)
    }

    private func read(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                self.lock.withLock { self._received.append(text) }
                for reply in self.respond(text) { conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in }) }
            }
            if done || error != nil { return }
            self.read(conn)
        }
    }

    func stop() { listener.cancel() }
}

@MainActor
struct WirelessSessionTests {
    private func wait(_ seconds: Double = 6, until check: () -> Bool) async -> Bool {
        var waited = 0.0
        while waited < seconds {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        return check()
    }

    @Test func shureSessionReadsLevelsAndRenames() async throws {
        let server = try FakeReceiver(port: 2202) { text in
            var out: [String] = []
            if text.contains("GET 0 MODEL") { out.append("< REP MODEL {ULXD4D} >") }
            if text.contains("SET 1 METER_RATE") {
                out.append("< REP 1 CHAN_NAME {Pastor 1} >< REP 1 BATT_BARS 004 >< SAMPLE 1 ALL AX 090 075 >")
            }
            if text.contains("SET 2 METER_RATE") { out.append("< SAMPLE 2 ALL XX 000 000 >") }
            if text.contains("SET 1 CHAN_NAME {Keys}") { out.append("< REP 1 CHAN_NAME {Keys    } >") }
            return out
        }
        defer { server.stop() }
        let monitor = WirelessMonitor.shared
        let target = WirelessMonitor.Target(id: "shure-test", name: "ULXD", host: "127.0.0.1", brand: .shure, modelHint: "ULXD4D")
        monitor.retain(target)
        defer { monitor.release(target.id) }

        #expect(await wait { monitor.snapshots[target.id]?.channels[1]?.name == "Pastor 1" })
        let c = monitor.snapshots[target.id]?.channels[1]
        #expect(c?.rfDbm == -38)
        #expect(c?.batteryFraction == 0.8)
        #expect(monitor.snapshots[target.id]?.state == .live)
        #expect(monitor.snapshots[target.id]?.channels[2] != nil)   // a ULXD4D has two channels

        let result = await monitor.rename(target.id, channel: 1, to: "Keys")
        #expect(result.ok)
        #expect(server.received.joined().contains("< SET 1 CHAN_NAME {Keys} >"))
    }

    @Test func audioTechnicaSessionReadsLevelsAndRenames() async throws {
        let server = try FakeReceiver(port: 17300) { text in
            var out: [String] = []
            for line in text.components(separatedBy: "\r") where !line.isEmpty {
                if line.hasPrefix("garlv O 0000 00 NC 1") {
                    out.append("garlv 0000 00 NC 1,10,9,8,-80,9,-78,1,0,0,0,,0,0,0,0,,0,1,1,0,0,1,7,0,4,474325000,0,0\r")
                } else if line.hasPrefix("garlv") {
                    out.append("garlv NAK 04\r")
                } else if line.hasPrefix("gprch O 0000 00 NC 1") {
                    out.append("gprch 0000 00 NC 1,\"LEAD VOX\",,1,,,0,470125000,0,0,0\r")
                } else if line.hasPrefix("sprch S 0000 00 NC 1,\"KEYS\"") {
                    out.append("sprch ACK\r")
                }
            }
            return out
        }
        defer { server.stop() }
        let monitor = WirelessMonitor.shared
        let target = WirelessMonitor.Target(id: "at-test", name: "ATW", host: "127.0.0.1", brand: .audioTechnica, modelHint: "ATW-R3210N")
        monitor.retain(target)
        defer { monitor.release(target.id) }

        #expect(await wait { monitor.snapshots[target.id]?.channels[1]?.name == "LEAD VOX" })
        let c = monitor.snapshots[target.id]?.channels[1]
        #expect(c?.rfDbm == -78)
        #expect(c?.batteryText == "80–100%")
        #expect(monitor.snapshots[target.id]?.channels[2] == nil)   // the one-channel receiver answered NAK for RX2
        #expect(server.received.joined().contains("garlv O 0000 00 NC 1\r"))

        // The fake only confirms a name it was sent; the receiver in real life would report it back on the next poll.
        _ = await monitor.rename(target.id, channel: 1, to: "keys")
        #expect(server.received.joined().contains("sprch S 0000 00 NC 1,\"KEYS\",,,,,,,,\r"))
    }

    @Test func addressesOffTheNetworkAreNotContacted() {
        let monitor = WirelessMonitor.shared
        let target = WirelessMonitor.Target(id: "far-test", name: "Far", host: "8.8.8.8", brand: .shure, modelHint: "")
        monitor.retain(target)
        defer { monitor.release(target.id) }
        if case .offline = monitor.snapshots[target.id]?.state {} else { Issue.record("expected an offline state") }
    }
}
