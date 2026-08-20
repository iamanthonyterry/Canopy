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

// MARK: - Target Device Kind
// Which family of device a mapping controls. Kept separate from the
// per-device-kind action enums below so the settings UI can offer a single
// "Device Type" picker before narrowing down to a specific device + action.

enum RemoteTargetKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case hyperDeck, switcher

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hyperDeck: "HyperDeck"
        case .switcher:  "ATEM Switcher"
        }
    }
}

// MARK: - Target Device
// Which specific device a mapping controls.

enum RemoteTarget: Codable, Hashable {
    case hyperDeck(UUID)
    case switcher(UUID)

    var kind: RemoteTargetKind {
        switch self {
        case .hyperDeck: .hyperDeck
        case .switcher:  .switcher
        }
    }

    var deviceID: UUID {
        switch self {
        case .hyperDeck(let id): id
        case .switcher(let id):  id
        }
    }
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

// MARK: - ATEM Switcher Action Kind
// The catalog of switcher actions a trigger can fire, used to drive the
// "Action" picker in the mapping editor before any action-specific
// argument (like the input number) is filled in. Mirrors the
// StepKind/StepAction split in Workflow.swift.
enum SwitcherActionKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case cut, auto, programInput

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cut:          "Cut"
        case .auto:         "Auto Transition"
        case .programInput: "Program Input"
        }
    }

    var icon: String {
        switch self {
        case .cut:          "scissors"
        case .auto:         "arrow.triangle.2.circlepath"
        case .programInput: "rectangle.stack"
        }
    }
}

// MARK: - ATEM Switcher Action
// The instant transition commands a trigger can fire on an ATEM switcher's
// main (M/E 1) bus. `programInput` carries the 1-based input number to cut
// (or auto-transition) program to.
enum SwitcherRemoteAction: Codable, Hashable {
    case cut
    case auto
    case programInput(Int)

    var kind: SwitcherActionKind {
        switch self {
        case .cut:          .cut
        case .auto:         .auto
        case .programInput: .programInput
        }
    }

    /// Default argument values when the user switches the picker to a new kind.
    static func defaultAction(for kind: SwitcherActionKind) -> SwitcherRemoteAction {
        switch kind {
        case .cut:          .cut
        case .auto:         .auto
        case .programInput: .programInput(1)
        }
    }

    var title: String {
        if case .programInput(let input) = self { return "Program Input \(input)" }
        return kind.title
    }

    var icon: String { kind.icon }
}

// MARK: - Remote Action
// The action side of a mapping — paired with a RemoteTarget of the matching
// kind (enforced by the editor UI, not the type system, to keep this a
// simple flat enum like RemoteTrigger below).

enum RemoteAction: Codable, Hashable {
    case hyperDeck(HyperDeckRemoteAction)
    case switcher(SwitcherRemoteAction)

    var title: String {
        switch self {
        case .hyperDeck(let action): action.title
        case .switcher(let action):  action.title
        }
    }

    var icon: String {
        switch self {
        case .hyperDeck(let action): action.icon
        case .switcher(let action):  action.icon
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
