import Foundation

/// Whether an OSC or MIDI message is the one a workflow trigger is waiting for.
enum ControlTriggerMatch {
    /// Addresses are compared part by part, ignoring case; a `*` in the trigger's address stands for any one part
    /// (`/cue/*/start` matches `/cue/12/start`). When `argument` isn't empty, the message's first argument must equal it
    /// (numbers compare as numbers, so `1` matches 1, 1.0 and "1").
    static func osc(address pattern: String, argument: String, message: OSCMessage) -> Bool {
        let want = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard want.hasPrefix("/") else { return false }
        let wanted = want.split(separator: "/", omittingEmptySubsequences: false)
        let got = message.address.lowercased().split(separator: "/", omittingEmptySubsequences: false)
        guard wanted.count == got.count, zip(wanted, got).allSatisfy({ $0 == "*" || $0 == $1 }) else { return false }
        let arg = argument.trimmingCharacters(in: .whitespaces)
        if arg.isEmpty { return true }
        guard let first = message.arguments.first else { return false }
        return equal(arg, first.displayText)
    }

    /// Kind, channel and number must match. The velocity or amount is ignored, so a pad fires it when pressed, but a note
    /// that is really a release (a Note On with velocity 0, which many controllers send) is not a press.
    static func midi(kind: MIDIMessage.Kind, channel: Int, number: Int, message: MIDIMessage) -> Bool {
        guard message.kind == kind, message.channel == channel, message.number == number else { return false }
        return !(kind == .noteOn && message.value == 0)
    }

    private static func equal(_ a: String, _ b: String) -> Bool {
        if let x = Double(a), let y = Double(b) { return x == y }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}
