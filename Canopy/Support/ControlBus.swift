import Foundation
import Combine

/// Everything that arrives by OSC or MIDI comes through here, once, and goes to whoever asked:
/// the Transcriber commands (`/transcriber/start`, `/canopy/stop`…), the HyperDeck remote-control mappings, and workflow
/// triggers. There is one MIDI input and one OSC listener per port in use. Two are possible, because the app used to
/// be two apps, each with its own OSC port setting, and a cue list pointed at either must keep working.
@MainActor
final class ControlBus: ObservableObject {
    static let shared = ControlBus()

    private var oscHandlers: [UUID: (OSCMessage) -> Void] = [:]
    private var midiHandlers: [UUID: (MIDIMessage) -> Void] = [:]

    /// The port in Settings → Transcription ("Listen for OSC on port"), or 0.
    private(set) var commandPort = 0
    /// Listens on `commandPort` when the remote-control listener isn't already on that port.
    private let secondary = OSCListenerService()

    private init() {
        secondary.onMessage = { [weak self] message, _ in self?.dispatch(osc: message) }
    }

    /// Whether the extra listener is open, or why not (shown next to the port in Settings).
    var commandPortStatus: String {
        if commandPort == 0 { return "off" }
        if secondary.isListening { return "listening on \(commandPort)" }
        if let e = secondary.lastError { return e }
        return "served by the remote-control listener"
    }

    // MARK: Subscribing

    @discardableResult
    func onOSC(_ handler: @escaping (OSCMessage) -> Void) -> UUID {
        let id = UUID(); oscHandlers[id] = handler; return id
    }

    @discardableResult
    func onMIDI(_ handler: @escaping (MIDIMessage) -> Void) -> UUID {
        let id = UUID(); midiHandlers[id] = handler; return id
    }

    func remove(_ id: UUID) {
        oscHandlers[id] = nil
        midiHandlers[id] = nil
    }

    /// The next OSC message, once ("learn"). Returns what to pass to `remove` to give up early.
    @discardableResult
    func learnOSC(_ found: @escaping (OSCMessage) -> Void) -> UUID {
        var token: UUID?
        let id = onOSC { [weak self] message in
            if let token { self?.remove(token) }
            found(message)
        }
        token = id
        return id
    }

    /// The next MIDI message that is a press (not a release), once.
    @discardableResult
    func learnMIDI(_ found: @escaping (MIDIMessage) -> Void) -> UUID {
        var token: UUID?
        let id = onMIDI { [weak self] message in
            guard message.kind != .noteOff, !(message.kind == .noteOn && message.value == 0) else { return }
            if let token { self?.remove(token) }
            found(message)
        }
        token = id
        return id
    }

    // MARK: Delivering

    func dispatch(osc message: OSCMessage) {
        for handler in Array(oscHandlers.values) { handler(message) }
    }

    func dispatch(midi message: MIDIMessage) {
        for handler in Array(midiHandlers.values) { handler(message) }
    }

    // MARK: Ports

    func setCommandPort(_ port: Int) {
        commandPort = max(0, port)
        refresh()
    }

    /// Opens or closes the extra listener to match the two port settings. Called when either changes.
    func refresh() {
        let remote = RemoteControlEngine.shared
        let mainPort = remote.osc.isListening || remote.isOSCRequested ? Int(remote.requestedOSCPort) : 0
        if commandPort > 0, commandPort != mainPort {
            if !secondary.isListening { secondary.start(port: UInt16(clamping: commandPort)) }
        } else {
            secondary.stop()
        }
    }
}
