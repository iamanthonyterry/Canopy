import Foundation

// MARK: - Built-In OSC Action Address
//
// A fixed, zero-configuration OSC namespace that sits alongside
// HyperDeckOSCAddress's slot-format scheme and covers every instant,
// no-argument action this app knows how to fire. Any OSC controller
// (TouchOSC, Companion, QLab, a custom fader bank) can drive every
// configured device the moment it knows the device's name — nothing to
// map in the app first:
//
//   /hyperdeck/{deviceName}/record
//   /hyperdeck/{deviceName}/stop
//   /hyperdeck/{deviceName}/format
//   /switcher/{deviceName}/cut
//   /switcher/{deviceName}/auto
//   /switcher/{deviceName}/input/{n}
//
// The user-configurable RemoteMapping list still exists for custom
// addresses or MIDI triggers — this is purely an always-on shortcut.

enum RemoteOSCCommand: Equatable {
    case hyperDeck(deviceName: String, action: HyperDeckRemoteAction)
    case switcher(deviceName: String, action: SwitcherRemoteAction)

    /// Parses `/hyperdeck/{name}/{action}`, `/switcher/{name}/{action}`, or
    /// the 4-part `/switcher/{name}/input/{n}`. Returns nil for anything
    /// else — including the slot-specific format scheme in
    /// HyperDeckOSCAddress and plain addresses configured through the
    /// mapping list — so callers can try both parsers without them
    /// stepping on each other.
    static func parse(_ address: String) -> RemoteOSCCommand? {
        let parts = address.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }

        let kind = parts[0]
        let deviceName = parts[1]
        let actionName = parts[2].lowercased()

        if parts.count == 3, kind.caseInsensitiveCompare("hyperdeck") == .orderedSame,
           let action = HyperDeckRemoteAction(rawValue: actionName) {
            return .hyperDeck(deviceName: deviceName, action: action)
        }
        guard kind.caseInsensitiveCompare("switcher") == .orderedSame else { return nil }

        if parts.count == 3 {
            switch actionName {
            case "cut":  return .switcher(deviceName: deviceName, action: .cut)
            case "auto": return .switcher(deviceName: deviceName, action: .auto)
            default:     return nil
            }
        }
        if parts.count == 4, actionName == "input", let input = Int(parts[3]) {
            return .switcher(deviceName: deviceName, action: .programInput(input))
        }
        return nil
    }
}
