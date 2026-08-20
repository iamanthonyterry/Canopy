import Foundation

// MARK: - Remote Control Settings
// Persisted OSC/MIDI listener configuration, shown in Settings.

struct RemoteControlSettings: Codable, Equatable {
    var oscEnabled: Bool = false
    var oscPort: UInt16 = 8000

    var midiEnabled: Bool = false
    /// Which MIDI source names to listen to. Empty = every available source.
    var midiSourceNames: Set<String> = []
}

// MARK: - Target Device
// Which specific device a mapping controls. Kept as a single-case enum
// (rather than a plain UUID) so the persisted JSON shape
// (`{"hyperDeck": {...}}`) is unchanged from before switcher targets were
// removed — existing saved HyperDeck mappings keep decoding correctly.

enum RemoteTarget: Codable, Hashable {
    case hyperDeck(UUID)
}

// MARK: - HyperDeck Action
// What an incoming OSC/MIDI trigger can do to a HyperDeck. Kept as its own
// small enum (rather than reusing WorkflowStep.Action) since remote-control
// triggers only make sense for a handful of instant, no-argument commands.

enum HyperDeckRemoteAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case record, stop, format

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: "Record"
        case .stop:   "Stop"
        case .format: "Format Drive"
        }
    }

    var icon: String {
        switch self {
        case .record: "record.circle"
        case .stop:   "stop.circle"
        case .format: "exclamationmark.triangle"
        }
    }
}

// MARK: - Remote Action
// The action side of a mapping. Kept as a single-case enum (rather than a
// plain HyperDeckRemoteAction) so the persisted JSON shape
// (`{"hyperDeck": {...}}`) is unchanged from before switcher actions were
// removed — existing saved mappings keep decoding correctly.

enum RemoteAction: Codable, Hashable {
    case hyperDeck(HyperDeckRemoteAction)

    var title: String {
        switch self {
        case .hyperDeck(let action): action.title
        }
    }

    var icon: String {
        switch self {
        case .hyperDeck(let action): action.icon
        }
    }
}

// MARK: - Trigger
// What has to arrive over OSC or MIDI to fire a mapping's action.
//
// OSC matches on address pattern alone (arguments are ignored) — that
// covers the common case of a button/cue on a control surface sending a
// fixed address per action. MIDI matches on message kind + channel + note
// or controller number; the actual value (velocity/CC amount) is ignored
// so the mapping fires the moment the button/key/pad is pressed.

enum RemoteTrigger: Codable, Hashable {
    case osc(address: String)
    case midi(kind: MIDIMessage.Kind, channel: Int, number: Int)

    var displayText: String {
        switch self {
        case .osc(let address):
            return address
        case .midi(let kind, let channel, let number):
            return "\(kind.displayName) · Ch \(channel + 1) · #\(number)"
        }
    }

    var isOSC: Bool {
        if case .osc = self { true } else { false }
    }
}

// MARK: - Mapping
// One row of "when this trigger arrives, do this action to this device."

struct RemoteMapping: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var trigger: RemoteTrigger
    var target: RemoteTarget
    var action: RemoteAction
    var isEnabled: Bool = true
    var sortOrder: Int = 0
}
