import Foundation
import Network

// MARK: - ATEM State Capture
//
// Where ATEMControlService fires one command and disconnects, this stays
// connected after the handshake and listens to the flood of state commands
// every ATEM sends a client immediately upon connecting (the same dump
// ATEM Software Control reads to draw its UI). We decode only the fields
// ATEMSwitcherState cares about (PrgI/PrvI/KeOn) and ignore the rest.
//
// Completion is detected by idle timeout rather than a specific "dump
// finished" command: different firmware versions are inconsistent about
// signaling that, but every version goes quiet for a beat once the initial
// dump ends. This is the same reason a fixed capture timeout is used as a
// backstop below.
//
// NOTE: like ATEMControlService, this has been written from the
// reverse-engineered OpenSwitcher protocol docs and not yet validated
// against real hardware.
enum ATEMStateSession {
    nonisolated static func capture(
        from host: String,
        port: UInt16 = BlackmagicSwitcher.controlPort,
        idleTimeout: TimeInterval = 1.5,
        maxDuration: TimeInterval = 6
    ) async throws -> ATEMSwitcherState {
        guard NWEndpoint.Port(rawValue: port) != nil else { throw ATEMControlError.invalidHost }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ATEMSwitcherState, Error>) in
            let capture = ATEMStateCapture(host: host, port: port, continuation: continuation)
            capture.start(idleTimeout: idleTimeout, maxDuration: maxDuration)
        }
    }
}

// MARK: - Capture Session

nonisolated private final class ATEMStateCapture: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<ATEMSwitcherState, Error>

    private let lock = NSLock()
    private var finished = false
    private var idleWorkItem: DispatchWorkItem?

    private let localSessionID = UInt16.random(in: 1...0x7FFF)
    private var state = ATEMSwitcherState()
    private var idleTimeout: TimeInterval = 1.5

    init(host: String, port: UInt16, continuation: CheckedContinuation<ATEMSwitcherState, Error>) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        self.continuation = continuation
    }

    func start(idleTimeout: TimeInterval, maxDuration: TimeInterval) {
        self.idleTimeout = idleTimeout
        connection.stateUpdateHandler = { [weak self] nwState in
            guard let self else { return }
            switch nwState {
            case .ready:
                self.sendHello()
            case .failed:
                self.finish(ATEMControlError.connectionFailed)
            default:
                break
            }
        }
        connection.start(queue: .global())
        resetIdleTimer(idleTimeout)

        DispatchQueue.global().asyncAfter(deadline: .now() + maxDuration) { [weak self] in
            self?.finish(nil)
        }
    }

    /// Resumes the continuation exactly once, either with whatever state
    /// has been decoded so far (success) or an error (before the handshake
    /// even completed).
    private func finish(_ error: Error?) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }

        idleWorkItem?.cancel()
        connection.cancel()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: state)
        }
    }

    /// Restarts the "the switcher has gone quiet, the dump is done" timer.
    /// Called on init and after every packet received once past the
    /// handshake, so it only fires after a real gap in traffic.
    private func resetIdleTimer(_ timeout: TimeInterval) {
        idleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.finish(nil) }
        idleWorkItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
    }

    // MARK: Handshake (identical shape to ATEMCommandSession)

    private func sendHello() {
        let payload = Data([0x01, 0, 0, 0, 0, 0, 0, 0])
        let packet = Self.makePacket(flags: .syn, session: localSessionID, ackNumber: 0, payload: payload)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error); return }
            self?.receiveLoop()
        })
    }

    // MARK: Receive loop
    //
    // After the handshake, everything the switcher sends is either its own
    // SYN-ACK reply (first message only) or a stream of state commands. We
    // ACK every packet that carries a sequence number so the switcher
    // doesn't think we've dropped off and start retransmitting.

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { self.finish(error); return }
            guard let data, data.count >= 12 else { self.receiveLoop(); return }

            let remotePacketID = Self.readUInt16(data, at: 10)
            if remotePacketID != 0 {
                self.sendAck(acking: remotePacketID)
            }
            self.decodeCommandBlocks(in: data)

            self.resetIdleTimer(self.idleTimeout)
            self.receiveLoop()
        }
    }

    private func sendAck(acking remotePacketID: UInt16) {
        let packet = Self.makePacket(flags: .ack, session: localSessionID, ackNumber: remotePacketID, payload: Data())
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    // MARK: Command block decoding
    //
    // Each UDP packet's payload (after the 12-byte transport header) is one
    // or more back-to-back command blocks: 2-byte block length (including
    // this 8-byte block header itself), 2 reserved bytes, a 4-character
    // ASCII command name, then that command's own payload. This mirrors the
    // block format ATEMCommandSession already builds for outgoing commands
    // in ATEMControlService.swift — just read instead of written.
    //
    // Only the three commands ATEMSwitcherState models are decoded; every
    // other block is skipped over using its length prefix.
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

    /// Finds (or creates) the in-progress snapshot for an M/E index.
    private func mixEffect(_ index: UInt8) -> MixEffectState {
        if let existing = state.mixEffects.first(where: { $0.index == index }) { return existing }
        let created = MixEffectState(index: index)
        state.mixEffects.append(created)
        return created
    }

    private func setMixEffect(_ me: MixEffectState) {
        if let i = state.mixEffects.firstIndex(where: { $0.index == me.index }) {
            state.mixEffects[i] = me
        } else {
            state.mixEffects.append(me)
        }
    }

    // MARK: Packet helpers (same wire format as ATEMControlService)

    private struct Flags: OptionSet {
        let rawValue: UInt8
        static let syn = Flags(rawValue: 0x02)
        static let ack = Flags(rawValue: 0x10)
    }

    private static func makePacket(flags: Flags, session: UInt16, ackNumber: UInt16, payload: Data) -> Data {
        let length = UInt16(12 + payload.count)
        var header = [UInt8](repeating: 0, count: 12)
        header[0] = (flags.rawValue << 3) | UInt8((length >> 8) & 0x07)
        header[1] = UInt8(length & 0xFF)
        header[2] = UInt8(session >> 8)
        header[3] = UInt8(session & 0xFF)
        header[4] = UInt8(ackNumber >> 8)
        header[5] = UInt8(ackNumber & 0xFF)
        return Data(header) + payload
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let start = data.startIndex + offset
        guard start + 1 < data.endIndex else { return 0 }
        return (UInt16(data[start]) << 8) | UInt16(data[start + 1])
    }
}
