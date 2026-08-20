import Foundation
import Combine
import Network

// MARK: - Received OSC Message
// A logged entry for the live "Recent Messages" list in Settings.

struct ReceivedOSCMessage: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: OSCMessage
    let sourceHost: String
}

// MARK: - OSC Listener Service
// Binds a UDP socket and decodes any OSC packets that arrive on it.
// Each remote sender gets its own inbound NWConnection (handed to us via
// the listener's newConnectionHandler); we keep receiving on it for as
// long as it stays open.

@MainActor
final class OSCListenerService: ObservableObject {
    @Published var isListening = false
    @Published var lastError: String? = nil
    @Published private(set) var receivedMessages: [ReceivedOSCMessage] = []

    /// Called on the main actor for every decoded message, in addition to
    /// it being appended to `receivedMessages`.
    var onMessage: ((OSCMessage, String) -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private static let logLimit = 100

    func start(port: UInt16) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "\(port) isn't a valid port number"
            return
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            lastError = error.localizedDescription
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleState(state) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        isListening = false
    }

    // MARK: - Listener state

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
            lastError = nil
        case .failed(let error):
            isListening = false
            lastError = error.localizedDescription
        case .cancelled:
            isListening = false
        default:
            break
        }
    }

    // MARK: - Per-sender connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.connections.removeValue(forKey: key) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(on: connection, key: key)
    }

    private func receive(on connection: NWConnection, key: ObjectIdentifier) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    let host = Self.hostDescription(connection)
                    for message in OSCCodec.decode(data) {
                        self.record(message, from: host)
                    }
                }
                if error == nil {
                    self.receive(on: connection, key: key)
                } else {
                    self.connections.removeValue(forKey: key)
                }
            }
        }
    }

    private func record(_ message: OSCMessage, from host: String) {
        receivedMessages.append(ReceivedOSCMessage(message: message, sourceHost: host))
        if receivedMessages.count > Self.logLimit {
            receivedMessages.removeFirst(receivedMessages.count - Self.logLimit)
        }
        onMessage?(message, host)
    }

    private static func hostDescription(_ connection: NWConnection) -> String {
        guard case .hostPort(let host, _) = connection.endpoint else { return "unknown" }
        return "\(host)"
    }
}
