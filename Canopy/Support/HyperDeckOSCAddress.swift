import Foundation

// MARK: - HyperDeck OSC Format Address
//
// A dedicated, always-on OSC address scheme for formatting a specific slot
// on a specific HyperDeck by name — independent of the user-configurable
// RemoteMapping list, which only fires fixed no-argument actions on a
// pre-selected device.
//
// The address shape mirrors what this app's user already sends from
// Bitfocus Companion:
//
//   /hyperdeck/{deviceName}/slot/{slotNumber}/format/{filesystem}
//   e.g. /hyperdeck/ISO_1/slot/3/format/HFS+
//
// so switching from Companion's direct HyperDeck integration to routing
// through this app's OSC listener needs no reconfiguration on the
// controller side — every connected HyperDeck and every one of its slots
// is addressable this way automatically, with no manual mapping required.

struct HyperDeckOSCFormatCommand: Equatable {
    let deviceName: String
    let slot: Int
    let filesystem: String
}

enum HyperDeckOSCAddress {
    /// Parses `/hyperdeck/{name}/slot/{n}/format/{fs}`. Returns nil for any
    /// address that doesn't match this exact shape (including plain OSC
    /// triggers configured through the mapping list, which this parser
    /// should just ignore).
    static func parseFormatCommand(_ address: String) -> HyperDeckOSCFormatCommand? {
        let parts = address.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 6,
              parts[0].caseInsensitiveCompare("hyperdeck") == .orderedSame,
              parts[2].caseInsensitiveCompare("slot") == .orderedSame,
              parts[4].caseInsensitiveCompare("format") == .orderedSame,
              let slot = Int(parts[3]) else { return nil }

        return HyperDeckOSCFormatCommand(deviceName: parts[1], slot: slot, filesystem: parts[5])
    }

    /// Matches an OSC-supplied device name against a configured HyperDeck's
    /// name. Companion-style naming tends to use underscores where the
    /// app's own device names use spaces (e.g. "ISO_1" vs. "ISO 1"), so
    /// this normalizes both before comparing rather than requiring an exact
    /// match.
    static func namesMatch(_ deviceName: String, _ oscName: String) -> Bool {
        normalize(deviceName) == normalize(oscName)
    }

    private static func normalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "_")
    }
}
