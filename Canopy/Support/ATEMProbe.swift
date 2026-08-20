import Foundation
import Network

// MARK: - ATEM Reachability Probe
//
// Blackmagic ATEM switchers speak a proprietary protocol over UDP on port
// 9910 — they never accept plain TCP connections there, so a TCP "ping"
// always reports offline even when the switcher is powered on and healthy.
//
// This sends the protocol's real opening handshake packet over UDP and
// treats any reply from the switcher as proof it's alive. We don't need to
// parse the response — just seeing one is enough for a reachability check.
//
// Marked `nonisolated` throughout: this is pure background networking with
// no UI state, so it shouldn't be pinned to the main actor.
enum ATEMProbe {

    /// The ATEM "Hello" packet: a 12-byte header (flags = NewSessionID,
    /// length = 20) followed by an 8-byte payload whose first byte (0x01)
    /// requests a new session. A live switcher always answers this with its
    /// own Hello packet.
    nonisolated private static let helloPacket = Data([
        0x10, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])

    /// Sends the handshake and reports whether the switcher replies within
    /// the timeout window.
    nonisolated static func ping(host: String, port: UInt16 = BlackmagicSwitcher.controlPort, timeout: TimeInterval = 2) async -> DeckStatus {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .offline }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)

        return await withCheckedContinuation { continuation in
            let resolver = ProbeResolver(connection: conn, continuation: continuation)
            resolver.start(sending: helloPacket, timeout: timeout)
        }
    }
}

/// Bridges NWConnection's state/completion callbacks into a single checked
/// continuation, guaranteeing it resumes exactly once no matter which
/// callback — ready, failed, receive, or timeout — fires first.
///
/// This lives as a class (rather than a local closure) specifically so the
/// callbacks handed to NWConnection, which are checked as `@Sendable`, have
/// something Sendable to capture: `self`, guarded by a lock.
nonisolated private final class ProbeResolver: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<DeckStatus, Never>
    private let lock = NSLock()
    private var resolved = false

    nonisolated init(connection: NWConnection, continuation: CheckedContinuation<DeckStatus, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    // `stateUpdateHandler` below captures `self` strongly and NWConnection
    // retains its own handler, so this object is kept alive by that
    // intentional retain cycle for as long as the connection is live —
    // otherwise, with no other owner, it would deallocate as soon as
    // `start()` returns (before any network response can arrive), leaving
    // `self` nil in every callback and the continuation never resumed. The
    // cycle is broken in `finish()`.
    nonisolated func start(sending packet: Data, timeout: TimeInterval) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.connection.send(content: packet, completion: .contentProcessed { error in
                    if error != nil { self.finish(.offline) }
                })
                self.connection.receiveMessage { data, _, _, error in
                    self.finish((data?.isEmpty == false && error == nil) ? .online : .offline)
                }
            case .failed:
                self.finish(.offline)
            default:
                break
            }
        }
        connection.start(queue: .global())

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            self.finish(.offline)
        }
    }

    nonisolated private func finish(_ status: DeckStatus) {
        lock.lock()
        let alreadyResolved = resolved
        resolved = true
        lock.unlock()
        guard !alreadyResolved else { return }

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: status)
    }
}
