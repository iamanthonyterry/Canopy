import Foundation
import Network
import Combine

// MARK: - ATEM Live Session
//
// One persistent UDP session per switcher for the life of the live control
// panel (SwitcherControlPanel): a single handshake, continuously decoded
// state (PrgI/PrvI/KeOn — the same fields ATEMStateSession decodes), and
// every Cut/Auto/program-preview command sent over that same session.
//
// ATEMControlService and ATEMStateSession each open and tear down their own
// short-lived session per call, which is fine for the rare, one-off
// "save/restore a config" actions in SwitcherEditSheet, but is far too
// aggressive for a live panel: a fresh session on every button tap plus a
// periodic polling session raced brand-new sessions against ones the
// switcher hadn't finished expiring yet. Most ATEM models accept only a
// small, fixed number of simultaneous client sessions — some consumer
// models accept just one — so that contention showed up as the switcher
// rejecting connections outright, and as dropped/incomplete state captures
// that left stale defaults in the decoded state (e.g. program and preview
// both appearing to show the same input). Keeping one session open for as
// long as the panel is visible avoids both, and matches how a real client
// (ATEM Software Control) behaves.
//
// NOTE: like ATEMControlService/ATEMStateSession, this is written from the
// reverse-engineered OpenSwitcher protocol docs and not yet validated
// against every ATEM model.
@MainActor
final class ATEMLiveSession: ObservableObject {
    @Published private(set) var state = ATEMSwitcherState()
    @Published private(set) var isConnected = false
    @Published var lastError: String?

    private let host: String
    private let port: UInt16
    private var connection: ATEMLiveConnection?

    init(host: String, port: UInt16 = BlackmagicSwitcher.controlPort) {
        self.host = host
        self.port = port
    }

    func connect() {
        guard connection == nil else { return }
        lastError = nil

        let conn = ATEMLiveConnection(
            host: host, port: port,
            onConnected: { [weak self] in
                Task { @MainActor in
                    self?.isConnected = true
                    self?.lastError = nil
                }
            },
            onStateUpdate: { [weak self] mixEffect in
                Task { @MainActor in self?.apply(mixEffect) }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in
                    self?.isConnected = false
                    self?.lastError = error.localizedDescription
                    self?.connection = nil
                }
            }
        )
        connection = conn
        conn.start()
    }

    func disconnect() {
        connection?.stop()
        connection = nil
        isConnected = false
    }

    func send(_ command: ATEMControlService.Command, meIndex: UInt8 = 0) {
        guard let connection, isConnected else {
            lastError = "Not connected to the switcher yet"
            return
        }
        connection.send(command, meIndex: meIndex)
    }

    private func apply(_ mixEffect: MixEffectState) {
        if let i = state.mixEffects.firstIndex(where: { $0.index == mixEffect.index }) {
            state.mixEffects[i] = mixEffect
        } else {
            state.mixEffects.append(mixEffect)
        }
    }
}

// MARK: - Live Connection
//
// The nonisolated background half: owns the NWConnection, speaks the
// handshake once, then keeps receiving + ACKing state packets and sending
// command packets for as long as the session lives. Mirrors the handshake
// and packet format ATEMCommandSession/ATEMStateCapture already use, but
// unlike either of those this never disconnects on its own — the caller
// decides the session's lifetime via `stop()`.
nonisolated private final class ATEMLiveConnection: @unchecked Sendable {
    private let onConnected: @Sendable () -> Void
    private let onStateUpdate: @Sendable (MixEffectState) -> Void
    private let onFailure: @Sendable (Error) -> Void

    private let connection: NWConnection

    private let lock = NSLock()
    private var stopped = false
    private var connected = false

    // `localSessionID` is only ever used for the initial SYN, which
    // proposes it to the switcher. Some ATEM firmware echoes it straight
    // back in the SYN-ACK reply, but others assign a *different* session id
    // there — every packet from the ACK onward (including every command)
    // must carry whichever one the switcher actually replied with, or it
    // gets silently dropped. `sessionID` holds that once known.
    private let localSessionID = UInt16.random(in: 1...0x7FFF)
    private var sessionID: UInt16 = 0
    private var outgoingPacketID: UInt16 = 0
    private var lastRemotePacketID: UInt16 = 0
    private var mixEffects: [UInt8: MixEffectState] = [:]

    private var keepAliveTimer: DispatchSourceTimer?

    init(
        host: String, port: UInt16,
        onConnected: @escaping @Sendable () -> Void,
        onStateUpdate: @escaping @Sendable (MixEffectState) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        self.onConnected = onConnected
        self.onStateUpdate = onStateUpdate
        self.onFailure = onFailure
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] nwState in
            switch nwState {
            case .ready:
                self?.sendHello()
            case .failed:
                self?.fail(ATEMControlError.connectionFailed)
            default:
                break
            }
        }
        connection.start(queue: .global())

        // Handshake-only timeout — once connected, the session is meant to
        // stay open indefinitely, so this never fires again after that.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldTimeOut = !self.connected && !self.stopped
            self.lock.unlock()
            if shouldTimeOut { self.fail(ATEMControlError.timedOut) }
        }
    }

    /// Deliberate close from the UI side (panel closed/switched away). Does
    /// not report an error — this is expected, not a failure.
    func stop() {
        guard markStopped() else { return }
        keepAliveTimer?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func fail(_ error: Error) {
        guard markStopped() else { return }
        keepAliveTimer?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        onFailure(error)
    }

    /// Marks the session stopped exactly once; returns whether this call
    /// was the one that did it (false if `stop()`/`fail()` already ran).
    private func markStopped() -> Bool {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        return !already
    }

    private func isStopped() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    // MARK: Handshake

    private func sendHello() {
        let payload = Data([0x01, 0, 0, 0, 0, 0, 0, 0])
        let packet = Self.makePacket(flags: .syn, session: localSessionID, ackNumber: 0, packetID: 0, payload: payload)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error); return }
            self?.receiveHelloResponse()
        })
    }

    private func receiveHelloResponse() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.isStopped() else { return }
            if let error { self.fail(error); return }
            guard let data, data.count >= 13 else { self.fail(ATEMControlError.connectionFailed); return }
            let status = data[data.startIndex + 12]
            guard status == 0x02 else { self.fail(ATEMControlError.rejected); return }

            self.sessionID = Self.readUInt16(data, at: 2)
            let remotePacketID = Self.readUInt16(data, at: 10)
            self.lastRemotePacketID = remotePacketID
            self.sendHandshakeAck(acking: remotePacketID)
        }
    }

    private func sendHandshakeAck(acking remotePacketID: UInt16) {
        let packet = Self.makePacket(flags: .ack, session: sessionID, ackNumber: remotePacketID, packetID: 0, payload: Data())
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self, !self.isStopped() else { return }
            if let error { self.fail(error); return }

            self.lock.lock(); self.connected = true; self.lock.unlock()
            self.onConnected()
            self.startKeepAlive()
            self.receiveLoop()
        })
    }

    // MARK: Receive loop — decodes state and ACKs everything received, for
    // the life of the session (not just the initial dump).

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.isStopped() else { return }
            if let error { self.fail(error); return }
            guard let data, data.count >= 12 else { self.receiveLoop(); return }

            let remotePacketID = Self.readUInt16(data, at: 10)
            if remotePacketID != 0 {
                self.lastRemotePacketID = remotePacketID
                self.sendAck(acking: remotePacketID)
            }
            self.decodeCommandBlocks(in: data)
            self.receiveLoop()
        }
    }

    private func sendAck(acking remotePacketID: UInt16) {
        let packet = Self.makePacket(flags: .ack, session: sessionID, ackNumber: remotePacketID, packetID: 0, payload: Data())
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    // MARK: Keepalive
    //
    // Nothing in the protocol docs specifies a required interval, but a
    // session with zero traffic risks the switcher expiring it after some
    // inactivity window — exactly the kind of silent drop this persistent
    // session exists to avoid. Re-ACKing the last packet seen periodically
    // is a no-op to the switcher if the session is already busy, and keeps
    // us looking alive if it's gone quiet.
    private func startKeepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopped() else { return }
            self.sendAck(acking: self.lastRemotePacketID)
        }
        timer.resume()
        keepAliveTimer = timer
    }

    // MARK: Sending commands

    func send(_ command: ATEMControlService.Command, meIndex: UInt8) {
        lock.lock()
        outgoingPacketID += 1
        let packetID = outgoingPacketID
        lock.unlock()

        let commandName = Data(Self.wireName(for: command).utf8)
        let commandData: Data
        switch command {
        case .cut, .auto:
            commandData = Data([meIndex, 0, 0, 0])
        case .programInput(let source), .previewInput(let source):
            commandData = Data([meIndex, 0, UInt8(source >> 8), UInt8(source & 0xFF)])
        }

        let blockLength = UInt16(2 + 2 + commandName.count + commandData.count)
        var block = Data()
        block.append(UInt8(blockLength >> 8))
        block.append(UInt8(blockLength & 0xFF))
        block.append(contentsOf: [0x00, 0x00]) // reserved
        block.append(commandName)
        block.append(commandData)

        let packet = Self.makePacket(flags: .reliable, session: sessionID, ackNumber: 0, packetID: packetID, payload: block)
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    private static func wireName(for command: ATEMControlService.Command) -> String {
        switch command {
        case .cut:          "DCut"
        case .auto:         "DAut"
        case .programInput: "CPgI"
        case .previewInput: "CPvI"
        }
    }

    // MARK: Command block decoding — same shape as ATEMStateSession's
    // ATEMStateCapture, but emits an update per M/E as each one changes
    // instead of collecting into a single snapshot returned once at the end.

    private func decodeCommandBlocks(in packet: Data) {
        var offset = packet.startIndex + 12
        while offset + 8 <= packet.endIndex {
            let blockLength = Int(Self.readUInt16(packet, at: offset - packet.startIndex))
            guard blockLength >= 8, offset + blockLength <= packet.endIndex else { break }

            let name = String(decoding: packet[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let body = packet[(offset + 8)..<(offset + blockLength)]
            decode(name: name, body: body)

            offset += blockLength
        }
    }

    private func decode(name: String, body: Data) {
        guard body.count >= 4 else { return }
        let meIndex = body[body.startIndex]

        switch name {
        case "PrgI":
            var me = mixEffect(meIndex)
            me.programInput = Self.readUInt16(body, at: 2)
            setMixEffect(me)
        case "PrvI":
            var me = mixEffect(meIndex)
            me.previewInput = Self.readUInt16(body, at: 2)
            setMixEffect(me)
        case "KeOn":
            let keyerIndex = body[body.startIndex + 1]
            let onAir = body[body.startIndex + 2] != 0
            var me = mixEffect(meIndex)
            if let i = me.upstreamKeyers.firstIndex(where: { $0.index == keyerIndex }) {
                me.upstreamKeyers[i].isOnAir = onAir
            } else {
                me.upstreamKeyers.append(KeyerOnAirState(index: keyerIndex, isOnAir: onAir))
            }
            setMixEffect(me)
        default:
            break
        }
    }

    private func mixEffect(_ index: UInt8) -> MixEffectState {
        mixEffects[index] ?? MixEffectState(index: index)
    }

    private func setMixEffect(_ me: MixEffectState) {
        mixEffects[me.index] = me
        onStateUpdate(me)
    }

    // MARK: Packet helpers (same wire format as ATEMControlService/ATEMStateSession)

    private struct Flags: OptionSet {
        let rawValue: UInt8
        static let reliable = Flags(rawValue: 0x01)
        static let syn       = Flags(rawValue: 0x02)
        static let ack       = Flags(rawValue: 0x10)
    }

    private static func makePacket(flags: Flags, session: UInt16, ackNumber: UInt16, packetID: UInt16, payload: Data) -> Data {
        let length = UInt16(12 + payload.count)
        var header = [UInt8](repeating: 0, count: 12)
        header[0]  = (flags.rawValue << 3) | UInt8((length >> 8) & 0x07)
        header[1]  = UInt8(length & 0xFF)
        header[2]  = UInt8(session >> 8)
        header[3]  = UInt8(session & 0xFF)
        header[4]  = UInt8(ackNumber >> 8)
        header[5]  = UInt8(ackNumber & 0xFF)
        header[10] = UInt8(packetID >> 8)
        header[11] = UInt8(packetID & 0xFF)
        return Data(header) + payload
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let start = data.startIndex + offset
        guard start + 1 < data.endIndex else { return 0 }
        return (UInt16(data[start]) << 8) | UInt16(data[start + 1])
    }
}
