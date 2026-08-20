import Foundation
import Combine
import CoreMIDI

// MARK: - MIDI Source Info

struct MIDISourceInfo: Identifiable, Hashable {
    var id: String { name }
    let name: String
}

// MARK: - Received MIDI Message

struct ReceivedMIDIMessage: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: MIDIMessage
}

// MARK: - MIDI Listener Service
// Opens a CoreMIDI input port and connects it to every available source
// (or a chosen subset), decoding incoming packets into `MIDIMessage`s.

@MainActor
final class MIDIListenerService: ObservableObject {
    @Published var isListening = false
    @Published var lastError: String? = nil
    @Published private(set) var receivedMessages: [ReceivedMIDIMessage] = []
    @Published private(set) var availableSources: [MIDISourceInfo] = []

    /// Called on the main actor for every decoded message, in addition to
    /// it being appended to `receivedMessages`.
    var onMessage: ((MIDIMessage, String) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private static let logLimit = 100

    /// Carries a source's display name through CoreMIDI's untyped refCon
    /// pointer so the read callback can tag each message with where it came
    /// from. One is retained (via `Unmanaged`) per connected source and
    /// released again in `stop()`.
    private final class SourceBox {
        let name: String
        init(name: String) { self.name = name }
    }
    private var retainedBoxes: [UnsafeMutableRawPointer] = []

    // MARK: - Sources

    func refreshSources() {
        let count = MIDIGetNumberOfSources()
        availableSources = (0..<count).map { MIDISourceInfo(name: Self.name(for: MIDIGetSource($0))) }
    }

    private static func name(for endpoint: MIDIEndpointRef) -> String {
        var unmanagedName: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName)
        guard status == noErr, let unmanagedName else { return "Unknown MIDI Source" }
        return unmanagedName.takeRetainedValue() as String
    }

    // MARK: - Start / Stop

    /// Starts listening. `sourceFilter` limits which sources get connected
    /// by name — an empty set means "every available source."
    func start(sourceFilter: Set<String>) {
        stop()
        refreshSources()

        var newClient = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock("CanopyRemoteControl" as CFString, &newClient) { _ in }
        guard clientStatus == noErr else {
            lastError = "Couldn't create MIDI client (status \(clientStatus))"
            return
        }

        var newPort = MIDIPortRef()
        let portStatus = MIDIInputPortCreateWithBlock(newClient, "Listener" as CFString, &newPort) { [weak self] packetListPtr, srcConnRefCon in
            let sourceName = srcConnRefCon.map { Unmanaged<SourceBox>.fromOpaque($0).takeUnretainedValue().name } ?? "MIDI"
            let messages = Self.decodePacketList(packetListPtr)
            guard !messages.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                for message in messages { self.record(message, from: sourceName) }
            }
        }
        guard portStatus == noErr else {
            lastError = "Couldn't create MIDI input port (status \(portStatus))"
            MIDIClientDispose(newClient)
            return
        }

        client = newClient
        inputPort = newPort

        var connectedAny = false
        for i in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(i)
            let name = Self.name(for: endpoint)
            guard sourceFilter.isEmpty || sourceFilter.contains(name) else { continue }

            let refCon = Unmanaged.passRetained(SourceBox(name: name)).toOpaque()
            if MIDIPortConnectSource(inputPort, endpoint, refCon) == noErr {
                retainedBoxes.append(refCon)
                connectedAny = true
            } else {
                Unmanaged<SourceBox>.fromOpaque(refCon).release()
            }
        }

        isListening = connectedAny
        if !connectedAny {
            lastError = availableSources.isEmpty
                ? "No MIDI sources found"
                : "Couldn't connect to any matching MIDI source"
        }
    }

    func stop() {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
        inputPort = 0
        client = 0
        retainedBoxes.forEach { Unmanaged<SourceBox>.fromOpaque($0).release() }
        retainedBoxes.removeAll()
        isListening = false
    }

    // MARK: - Packet decoding

    /// Flattens every packet in the list into raw bytes and runs them
    /// through `MIDICodec`. `packet.data` is a fixed 256-byte C tuple —
    /// `withUnsafeBytes` gives us a view onto it we can safely prefix to
    /// the packet's real (variable) length.
    private static func decodePacketList(_ packetListPtr: UnsafePointer<MIDIPacketList>) -> [MIDIMessage] {
        var messages: [MIDIMessage] = []
        withUnsafePointer(to: packetListPtr.pointee.packet) { firstPacketPtr in
            var packetPtr = firstPacketPtr
            for _ in 0..<packetListPtr.pointee.numPackets {
                let packet = packetPtr.pointee
                let bytes = withUnsafeBytes(of: packet.data) { Array($0.prefix(Int(packet.length))) }
                messages.append(contentsOf: MIDICodec.decode(bytes))
                packetPtr = UnsafePointer(MIDIPacketNext(packetPtr))
            }
        }
        return messages
    }

    // MARK: - Logging

    private func record(_ message: MIDIMessage, from source: String) {
        receivedMessages.append(ReceivedMIDIMessage(message: message))
        if receivedMessages.count > Self.logLimit {
            receivedMessages.removeFirst(receivedMessages.count - Self.logLimit)
        }
        onMessage?(message, source)
    }
}
