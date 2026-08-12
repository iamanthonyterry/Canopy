import Foundation
import Network

// MARK: - ATEM Control Error

enum ATEMControlError: LocalizedError {
    case invalidHost
    case connectionFailed
    case rejected
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidHost:      return "Invalid switcher address"
        case .connectionFailed: return "Couldn't reach the switcher"
        case .rejected:         return "Switcher rejected the connection"
        case .timedOut:         return "Switcher didn't respond in time"
        }
    }
}

// MARK: - ATEM Control Service
//
// Sends one-shot "instant" commands (Cut, Auto) to a Blackmagic ATEM
// switcher over its UDP control protocol on port 9910. The protocol itself
// is proprietary and undocumented by Blackmagic; this implements just the
// handshake and command-packet format as reverse-engineered by the
// OpenSwitcher project (https://docs.openswitcher.org/udptransport.html),
// which ATEMProbe's existing "Hello" packet already relies on for its
// reachability check.
//
// This deliberately does the minimum needed for a fire-and-forget command
// rather than a persistent connection:
//   1. Send the SYN "Hello" packet (same payload ATEMProbe already sends).
//   2. Read the switcher's SYN reply and confirm it accepted the session.
//   3. Send the ACK that completes the handshake.
//   4. Send a single reliable packet containing the DCut/DAut command.
//
// After that we close the socket immediately. We never ACK the full state
// dump the switcher sends after the handshake (a real client, like ATEM
// Software Control, is expected to keep doing that for the life of the
// session) — for a single instant command that's unnecessary, and the
// switcher just times out our session on its own a few seconds later.
//
// NOTE: this has been written directly from the reverse-engineered protocol
// docs and has not been validated against real ATEM hardware in this
// environment. If Cut/Auto don't fire on a real switcher, the first thing
// to check is whether the switcher expects the *session id it assigns*
// (rather than the id we originally proposed) for the command packet in
// step 4 — see the comment on `sendCommand()` below.
enum ATEMControlService {
    /// The instant commands this service can send. `programInput` and
    /// `previewInput` select a source directly onto program/preview —
    /// `source` is the switcher's video source id, which for every physical
    /// input matches its 1-based input number (1 = Input 1, 2 = Input 2,
    /// ...). `previewInput` mirrors `programInput`'s wire format exactly;
    /// the OpenSwitcher docs list "CPgI" and "CPvI" as the same command
    /// shape targeting the program vs. preview bus respectively.
    enum Command {
        case cut
        case auto
        case programInput(source: UInt16)
        case previewInput(source: UInt16)

        /// Raw 4-character ASCII command name, matching the wire protocol.
        /// `nonisolated` so `ATEMCommandSession` (itself nonisolated, per
        /// its own doc comment) can read it directly.
        fileprivate nonisolated var name: String {
            switch self {
            case .cut:          "DCut"
            case .auto:         "DAut"
            case .programInput: "CPgI"
            case .previewInput: "CPvI"
            }
        }
    }

    /// - Parameters:
    ///   - meIndex: 0-indexed M/E number. 0 (the default) is the main bus on
    ///     every switcher model, including ones without multiple M/Es.
    ///
    /// `nonisolated`, matching `ATEMProbe.ping` — this is pure background
    /// networking with no UI state, so it shouldn't be pinned to the main
    /// actor by the module's default isolation.
    nonisolated static func send(
        _ command: Command,
        meIndex: UInt8 = 0,
        to host: String,
        port: UInt16 = BlackmagicSwitcher.controlPort,
        timeout: TimeInterval = 3
    ) async throws {
        guard NWEndpoint.Port(rawValue: port) != nil else { throw ATEMControlError.invalidHost }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let session = ATEMCommandSession(host: host, port: port, command: command, meIndex: meIndex, continuation: continuation)
            session.start(timeout: timeout)
        }
    }
}

// MARK: - Command Session
//
// Bridges NWConnection's callback-based API into a single checked
// continuation across the multi-step handshake, guaranteeing it resumes
// exactly once regardless of which step fails or how it fails. Mirrors the
// approach ATEMProbe's ProbeResolver uses for the same reason.
nonisolated private final class ATEMCommandSession: @unchecked Sendable {
    private let connection: NWConnection
    private let command: ATEMControlService.Command
    private let meIndex: UInt8
    private let continuation: CheckedContinuation<Void, Error>

    private let lock = NSLock()
    private var finished = false

    // The protocol wants a client-chosen session id for the handshake.
    // Docs indicate the switcher's SYN-ACK echoes this value back, so we
    // keep using it for every packet in this short-lived session.
    private let localSessionID = UInt16.random(in: 1...0x7FFF)
    private var localPacketID: UInt16 = 0

    init(host: String, port: UInt16, command: ATEMControlService.Command, meIndex: UInt8, continuation: CheckedContinuation<Void, Error>) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        self.command = command
        self.meIndex = meIndex
        self.continuation = continuation
    }

    // `stateUpdateHandler` below captures `self` strongly and NWConnection
    // retains its own handler, so this object is kept alive by that
    // intentional retain cycle for as long as the connection is live —
    // otherwise, with no other owner, it would deallocate as soon as
    // `start()` returns (before the handshake can complete), leaving `self`
    // nil in every callback and the continuation never resumed. The cycle
    // is broken in `finish()`. Mirrors ATEMProbe's ProbeResolver.
    func start(timeout: TimeInterval) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.sendHello()
            case .failed:
                self.finish(.failure(ATEMControlError.connectionFailed))
            default:
                break
            }
        }
        connection.start(queue: .global())

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            self.finish(.failure(ATEMControlError.timedOut))
        }
    }

    // MARK: Step 1 — Hello (SYN)

    private func sendHello() {
        // Identical payload to ATEMProbe's helloPacket: byte 0 requests a
        // new session, the rest is padding.
        let payload = Data([0x01, 0, 0, 0, 0, 0, 0, 0])
        let packet = Self.makePacket(flags: .syn, session: localSessionID, ackNumber: 0, packetID: 0, payload: payload)

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(.failure(error))
                return
            }
            self?.receiveHelloResponse()
        })
    }

    private func receiveHelloResponse() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            // 12-byte header + at least the 1-byte connection-status field.
            guard let data, data.count >= 13 else {
                self.finish(.failure(ATEMControlError.connectionFailed))
                return
            }
            let status = data[data.startIndex + 12]
            guard status == 0x02 else {
                // 0x04 (or anything else) means the switcher wants us to
                // restart the handshake — treated as a hard failure here
                // since a one-shot command isn't worth retrying.
                self.finish(.failure(ATEMControlError.rejected))
                return
            }
            let remotePacketID = Self.readUInt16(data, at: 10)
            self.sendHandshakeAck(acking: remotePacketID)
        }
    }

    // MARK: Step 2 — ACK the handshake

    private func sendHandshakeAck(acking remotePacketID: UInt16) {
        let packet = Self.makePacket(flags: .ack, session: localSessionID, ackNumber: remotePacketID, packetID: 0, payload: Data())
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(.failure(error))
                return
            }
            self?.sendCommand()
        })
    }

    // MARK: Step 3 — send the command

    /// If this never fires on real hardware, the most likely culprit is the
    /// session id: some ATEM firmware reassigns a *new* session id after the
    /// handshake ACK rather than keeping the one the client proposed. That
    /// would mean reading the switcher's next packet before sending this one
    /// and adopting whatever session id it carries.
    private func sendCommand() {
        localPacketID += 1

        let commandName = Data(command.name.utf8)               // 4 bytes, e.g. "DCut"

        // M/E index + payload, padded to 4 bytes. DCut/DAut just take the
        // M/E index; CPgI additionally carries the source id as a
        // big-endian uint16 in the last two bytes.
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

        let packet = Self.makePacket(flags: .reliable, session: localSessionID, ackNumber: 0, packetID: localPacketID, payload: block)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(.failure(error))
                return
            }
            // Fire-and-forget from here: the command packet is on the wire.
            // We don't wait for the switcher's ACK of it or process the
            // state dump that follows — see the type's doc comment.
            self?.finish(.success(()))
        })
    }

    // MARK: Completion

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }

    // MARK: Packet construction
    //
    // 12-byte header, per docs.openswitcher.org/udptransport.html:
    //   byte 0    = (flags << 3) | (packet length's top 3 bits)
    //   byte 1    = packet length's low 8 bits (length includes this header)
    //   bytes 2-3 = session id
    //   bytes 4-5 = acknowledgement number (last packet id received from the
    //               other end; only meaningful when the ACK flag is set)
    //   bytes 6-7 = unused
    //   bytes 8-9 = unused (the switcher's own "remote sequence number";
    //               irrelevant for a client that isn't tracking a long-lived
    //               session)
    //   bytes 10-11 = this packet's local sequence number ("packet id") —
    //               left at 0 for SYN/ACK-flagged packets per spec

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
