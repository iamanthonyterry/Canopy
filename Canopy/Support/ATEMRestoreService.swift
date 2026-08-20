import Foundation
import Network

// MARK: - ATEM Restore Service
//
// Pushes a saved ATEMSwitcherState back to a live switcher as a sequence of
// set-commands (CPgI/CPvI/CKOn) over one handshake — the write-side
// counterpart to ATEMStateSession's capture. Reuses the exact packet format
// ATEMControlService already sends for CPgI; see that file's header comment
// for the protocol source and its "not yet validated against real
// hardware" caveat, which applies here too.
enum ATEMRestoreService {
    nonisolated static func restore(
        _ state: ATEMSwitcherState,
        to host: String,
        port: UInt16 = BlackmagicSwitcher.controlPort,
        timeout: TimeInterval = 5
    ) async throws {
        guard NWEndpoint.Port(rawValue: port) != nil else { throw ATEMControlError.invalidHost }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let session = ATEMRestoreSession(host: host, port: port, state: state, continuation: continuation)
            session.start(timeout: timeout)
        }
    }
}

// MARK: - Restore Session

nonisolated private final class ATEMRestoreSession: @unchecked Sendable {
    /// One flattened set-command still to send: 4-char name + its payload.
    private struct PendingCommand {
        let name: String
        let payload: Data
    }

    private let connection: NWConnection
    private let continuation: CheckedContinuation<Void, Error>

    private let lock = NSLock()
    private var finished = false

    // `localSessionID` proposes a session id in the initial SYN, but the
    // switcher's SYN-ACK reply may assign a different one — confirmed on
    // real hardware, where packets sent using the originally-proposed id
    // were silently dropped. Every packet from the handshake ACK onward
    // must carry whichever id the switcher actually replied with;
    // `sessionID` holds that once known. See ATEMControlService for the
    // full story.
    private let localSessionID = UInt16.random(in: 1...0x7FFF)
    private var sessionID: UInt16 = 0
    private var localPacketID: UInt16 = 0
    private var queue: [PendingCommand]

    init(host: String, port: UInt16, state: ATEMSwitcherState, continuation: CheckedContinuation<Void, Error>) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        self.continuation = continuation
        queue = Self.commands(for: state)
    }

    /// Preview restored first, then keyers, then program last — so program
    /// only cuts to its saved source once everything feeding it is already
    /// back in its saved state.
    private static func commands(for state: ATEMSwitcherState) -> [PendingCommand] {
        var commands: [PendingCommand] = []
        for me in state.mixEffects {
            commands.append(PendingCommand(name: "CPvI", payload: Data([me.index, 0, UInt8(me.previewInput >> 8), UInt8(me.previewInput & 0xFF)])))
        }
        for me in state.mixEffects {
            for keyer in me.upstreamKeyers {
                commands.append(PendingCommand(name: "CKOn", payload: Data([me.index, keyer.index, keyer.isOnAir ? 1 : 0, 0])))
            }
        }
        for me in state.mixEffects {
            commands.append(PendingCommand(name: "CPgI", payload: Data([me.index, 0, UInt8(me.programInput >> 8), UInt8(me.programInput & 0xFF)])))
        }
        return commands
    }

    // `stateUpdateHandler` below captures `self` strongly and NWConnection
    // retains its own handler, so this object is kept alive by that
    // intentional retain cycle for as long as the connection is live —
    // otherwise, with no other owner, it would deallocate as soon as
    // `start()` returns (before the handshake can complete), leaving the
    // continuation captured inside it dropped without ever resuming. The
    // cycle is broken in `finish()`. Mirrors ATEMCommandSession/ATEMStateCapture.
    func start(timeout: TimeInterval) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.sendHello()
            case .failed:
                self.finish(ATEMControlError.connectionFailed)
            default:
                break
            }
        }
        connection.start(queue: .global())

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(ATEMControlError.timedOut)
        }
    }

    private func sendHello() {
        let payload = Data([0x01, 0, 0, 0, 0, 0, 0, 0])
        let packet = Self.makePacket(flags: .syn, session: localSessionID, ackNumber: 0, packetID: 0, payload: payload)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error); return }
            self?.receiveHelloResponse()
        })
    }

    private func receiveHelloResponse() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { self.finish(error); return }
            guard let data, data.count >= 13, data[data.startIndex + 12] == 0x02 else {
                self.finish(ATEMControlError.rejected)
                return
            }
            self.sessionID = Self.readUInt16(data, at: 2)
            let remotePacketID = Self.readUInt16(data, at: 10)
            self.sendHandshakeAck(acking: remotePacketID)
        }
    }

    private func sendHandshakeAck(acking remotePacketID: UInt16) {
        let packet = Self.makePacket(flags: .ack, session: sessionID, ackNumber: remotePacketID, packetID: 0, payload: Data())
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error); return }
            self?.sendNext()
        })
    }

    /// Sends the next queued command, if any, waiting for each send to
    /// clear the socket before moving on so the switcher sees a steady
    /// stream of small packets rather than one burst.
    private func sendNext() {
        guard !queue.isEmpty else {
            finish(nil)
            return
        }
        let command = queue.removeFirst()
        localPacketID += 1

        var block = Data()
        let blockLength = UInt16(8 + command.payload.count)
        block.append(UInt8(blockLength >> 8))
        block.append(UInt8(blockLength & 0xFF))
        block.append(contentsOf: [0x00, 0x00])
        block.append(Data(command.name.utf8))
        block.append(command.payload)

        let packet = Self.makePacket(flags: .reliable, session: sessionID, ackNumber: 0, packetID: localPacketID, payload: block)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error); return }
            self?.sendNext()
        })
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }

        connection.stateUpdateHandler = nil
        connection.cancel()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: ())
        }
    }

    // MARK: Packet helpers (same wire format as ATEMControlService)

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
