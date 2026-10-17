import Foundation
import Network
import Combine

// MARK: - Live wireless monitoring
// Keeps one connection open to each wireless receiver on this network and
// publishes what it reports: RF, audio, battery, frequency and channel names.
// Only addresses on this network are contacted (isLocalAddress), and the only
// thing ever written to a receiver is a channel name, when someone asks.

/// One open connection to a receiver, TCP or UDP, reporting bytes and when it ends.
nonisolated final class DeviceLink: @unchecked Sendable {
    enum Event: Sendable { case ready, data(Data), closed(String) }

    private let conn: NWConnection
    private let udp: Bool
    private let queue = DispatchQueue(label: "canopy.wireless.link")
    private let onEvent: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var finished = false

    init?(host: String, port: Int, udp: Bool, onEvent: @escaping @Sendable (Event) -> Void) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        self.conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: udp ? .udp : .tcp)
        self.udp = udp
        self.onEvent = onEvent
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onEvent(.ready); self.receive()
            case .failed(let e): self.finish(e.localizedDescription)
            case .waiting(let e): self.finish(e.localizedDescription)
            case .cancelled: self.finish("Closed")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func send(_ text: String) {
        conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    func cancel() {
        lock.withLock { finished = true }
        conn.cancel()
    }

    private func finish(_ reason: String) {
        let first: Bool = lock.withLock { defer { finished = true }; return !finished }
        if first { onEvent(.closed(reason)) }
        conn.cancel()
    }

    private func receive() {
        let handler: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onEvent(.data(data)) }
            if let error { return self.finish(error.localizedDescription) }
            if complete && !self.udp { return self.finish("The receiver closed the connection.") }
            self.receive()
        }
        if udp { conn.receiveMessage(completion: handler) }
        else { conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, c, done, e in handler(d, c, done, e) } }
    }
}

@MainActor
final class WirelessMonitor: ObservableObject {
    static let shared = WirelessMonitor()

    struct Target: Hashable, Sendable {
        var id: String
        var name: String
        var host: String
        var brand: WirelessBrand
        /// The inventory's make and model, used to guess a Shure receiver's channel count until it says.
        var modelHint: String
    }

    @Published private(set) var snapshots: [String: WirelessSnapshot] = [:]

    private var holds: [String: Int] = [:]
    private var sessions: [String: Session] = [:]

    /// Starts watching a receiver, or adds one more reason to keep watching it. Pair every retain with a release.
    func retain(_ target: Target) {
        holds[target.id, default: 0] += 1
        guard sessions[target.id] == nil else { return }
        guard isLocalAddress(target.host) else {
            var snap = WirelessSnapshot()
            snap.state = .offline("\(target.host) isn't on this network, so it was not contacted.")
            snapshots[target.id] = snap
            return
        }
        let session = Session(target: target, monitor: self)
        sessions[target.id] = session
        session.start()
    }

    func release(_ id: String) {
        guard let n = holds[id] else { return }
        if n > 1 { holds[id] = n - 1; return }
        holds[id] = nil
        sessions[id]?.stop()
        sessions[id] = nil
        snapshots[id] = nil
    }

    fileprivate func publish(_ id: String, _ snap: WirelessSnapshot) { snapshots[id] = snap }

    /// Renames a channel on the receiver, then waits briefly for the receiver to report the new name.
    func rename(_ id: String, channel: Int, to raw: String) async -> (ok: Bool, message: String) {
        guard let session = sessions[id] else { return (false, "Not connected to this receiver.") }
        let name = session.target.brand.sanitizedName(raw)
        guard !name.isEmpty else { return (false, "That name has no characters this receiver accepts.") }
        session.sendName(channel, name)
        for _ in 0..<14 {
            try? await Task.sleep(for: .milliseconds(250))
            if let got = snapshots[id]?.channels[channel]?.name, got.caseInsensitiveCompare(name) == .orderedSame {
                return (true, "Channel \(channel) is now “\(got)”.")
            }
        }
        return (false, "Sent “\(name)” to channel \(channel), but the receiver didn't report it back.")
    }

    // MARK: One receiver

    @MainActor
    private final class Session {
        let target: Target
        private weak var monitor: WirelessMonitor?
        private var snap = WirelessSnapshot()
        private var link: DeviceLink?
        private var task: Task<Void, Never>?

        private var ready = false
        private var closed: String?
        private var buffer = ""
        private var lastHeard = Date.distantPast
        /// Channels this receiver has actually answered for.
        private var present: Set<Int> = []
        private var shureStarted = false

        init(target: Target, monitor: WirelessMonitor) {
            self.target = target
            self.monitor = monitor
        }

        func start() { task = Task { await run() } }

        func stop() {
            task?.cancel()
            link?.cancel()
        }

        private func publish() { monitor?.publish(target.id, snap) }

        private func offline(_ reason: String) {
            snap.state = .offline(reason)
            publish()
        }

        private var silenceHint: String {
            switch target.brand {
            case .shure: return "No answer from the receiver on TCP 2202."
            case .sennheiser: return "No answer on UDP 45. Third-party control may be switched off on the receiver, or its firmware may need the secured protocol."
            case .audioTechnica: return "No answer on TCP 17300. The receiver allows one control connection at a time, so close any other software connected to it."
            }
        }

        private func run() async {
            while !Task.isCancelled {
                await connectAndPoll()
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(5))
            }
        }

        private func connectAndPoll() async {
            ready = false; closed = nil; buffer = ""; shureStarted = false; present = []
            snap.state = .connecting
            publish()
            let handler: @Sendable (DeviceLink.Event) -> Void = { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            guard let link = DeviceLink(host: target.host, port: target.brand.port, udp: target.brand.usesUDP, onEvent: handler) else {
                return offline("Couldn't open a connection to \(target.host).")
            }
            self.link = link
            link.start()
            var waited = 0.0
            while !ready && closed == nil && waited < 6 && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 0.1
            }
            guard ready, closed == nil, !Task.isCancelled else {
                if !Task.isCancelled { offline(closed ?? "Couldn't reach \(target.host).") }
                link.cancel()
                return
            }
            lastHeard = Date()
            var tick = 0
            while !Task.isCancelled, closed == nil {
                poll(tick)
                tick += 1
                try? await Task.sleep(for: .milliseconds(250))
                if Date().timeIntervalSince(lastHeard) > 8, snap.state != .offline(silenceHint) {
                    offline(silenceHint)
                    if !target.brand.usesUDP { break }
                }
            }
            if let closed, !Task.isCancelled { offline(closed) }
            link.cancel()
        }

        // MARK: Sending

        func sendName(_ channel: Int, _ name: String) {
            switch target.brand {
            case .shure: link?.send(ShureProtocol.setName(channel, name))
            case .sennheiser: link?.send(SennheiserProtocol.setName(channel, name))
            case .audioTechnica:
                link?.send(AudioTechnicaProtocol.setName(channel, name))
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    link?.send(AudioTechnicaProtocol.nameRequest(channel))
                }
            }
        }

        private func startShure(channels: Int) {
            guard !shureStarted else { return }
            shureStarted = true
            for ch in 1...channels { link?.send(ShureProtocol.meterRate(ch, milliseconds: 500)) }
            link?.send(ShureProtocol.get(0, "ALL"))
        }

        private func poll(_ tick: Int) {
            guard let link else { return }
            switch target.brand {
            case .shure:
                if tick == 0 { link.send(ShureProtocol.get(0, "MODEL")) }
                // If the receiver hasn't named its model after a couple of seconds, go by the inventory's.
                if tick == 8 { startShure(channels: WirelessBrand.shureChannels(model: target.modelHint)) }
                if tick > 0 && tick % 240 == 0 { for ch in snap.channels.keys { link.send(ShureProtocol.meterRate(ch, milliseconds: 500)) } }
            case .sennheiser:
                if present.isEmpty {
                    // Ask each of the four possible channels; only the ones that exist answer with a value.
                    if tick % 40 == 0 { for ch in 1...4 { link.send(SennheiserProtocol.probeRequest(ch)) } }
                } else {
                    for ch in present.sorted() {
                        link.send(SennheiserProtocol.meterRequest(ch))
                        if tick % 20 == 0 { link.send(SennheiserProtocol.statusRequest(ch)) }
                    }
                }
            case .audioTechnica:
                // The receiver answers for RX2 only if it has one; stop asking if it never does.
                let channels = tick < 6 || tick % 80 == 0 ? [1, 2] : (present.isEmpty ? [1] : present.sorted())
                for rx in channels {
                    link.send(AudioTechnicaProtocol.levelRequest(rx))
                    if tick % 20 == 0 { link.send(AudioTechnicaProtocol.nameRequest(rx)) }
                }
            }
        }

        // MARK: Receiving

        private func handle(_ event: DeviceLink.Event) {
            switch event {
            case .ready: ready = true
            case .closed(let reason): closed = reason
            case .data(let data):
                var understood = false
                switch target.brand {
                case .shure:
                    buffer += String(decoding: data, as: UTF8.self)
                    for message in ShureProtocol.extract(&buffer) {
                        if ShureProtocol.apply(message, to: &snap) { understood = true }
                        if message.hasPrefix("REP MODEL") { startShure(channels: WirelessBrand.shureChannels(model: snap.model)) }
                    }
                case .sennheiser:
                    let seen = SennheiserProtocol.apply(data, to: &snap)
                    if !seen.isEmpty {
                        understood = true
                        let isNew = !seen.isSubset(of: present)
                        present.formUnion(seen)
                        if isNew { for ch in seen { link?.send(SennheiserProtocol.statusRequest(ch)) } }
                    }
                case .audioTechnica:
                    buffer += String(decoding: data, as: UTF8.self)
                    var lines = buffer.components(separatedBy: "\r")
                    buffer = lines.removeLast()
                    for line in lines where !line.isEmpty {
                        if AudioTechnicaProtocol.apply(line, to: &snap) {
                            understood = true
                            if line.hasPrefix("garlv"), let rx = AudioTechnicaProtocol.parse(line).flatMap({ AudioTechnicaProtocol.fields($0.params).first.flatMap(Int.init) }) {
                                present.insert(rx)
                            }
                        }
                    }
                }
                if understood {
                    lastHeard = Date()
                    snap.heard = lastHeard
                    snap.state = .live
                    publish()
                }
            }
        }
    }
}
