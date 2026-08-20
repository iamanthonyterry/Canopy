import Foundation

// MARK: - MIDI Message

struct MIDIMessage: Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Hashable {
        case noteOn, noteOff, controlChange, programChange

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .noteOn:         "Note On"
            case .noteOff:        "Note Off"
            case .controlChange:  "Control Change"
            case .programChange:  "Program Change"
            }
        }
    }

    var kind: Kind
    var channel: Int   // 0–15
    var number: Int    // note number, CC number, or program number
    var value: Int     // velocity or CC amount; 0 for program change
}

// MARK: - MIDI Codec
// Parses a flat byte stream (already extracted from a MIDIPacketList) into
// channel-voice messages. Only the message kinds a mapping can trigger off
// of are decoded; everything else (pitch bend, aftertouch, system/sysex) is
// skipped by advancing past its known length so later messages in the same
// packet still parse correctly.

enum MIDICodec {
    static func decode(_ bytes: [UInt8]) -> [MIDIMessage] {
        var messages: [MIDIMessage] = []
        var i = 0

        while i < bytes.count {
            let status = bytes[i]
            guard status & 0x80 != 0 else { i += 1; continue } // stray data byte, skip

            let channel = Int(status & 0x0F)
            switch status & 0xF0 {
            case 0x80, 0x90: // note off / note on
                guard i + 2 < bytes.count else { return messages }
                let number = Int(bytes[i + 1])
                let velocity = Int(bytes[i + 2])
                // A "note on" with velocity 0 is a note off per the MIDI spec.
                let kind: MIDIMessage.Kind = (status & 0xF0 == 0x90 && velocity > 0) ? .noteOn : .noteOff
                messages.append(MIDIMessage(kind: kind, channel: channel, number: number, value: velocity))
                i += 3
            case 0xB0: // control change
                guard i + 2 < bytes.count else { return messages }
                messages.append(MIDIMessage(kind: .controlChange, channel: channel, number: Int(bytes[i + 1]), value: Int(bytes[i + 2])))
                i += 3
            case 0xC0: // program change
                guard i + 1 < bytes.count else { return messages }
                messages.append(MIDIMessage(kind: .programChange, channel: channel, number: Int(bytes[i + 1]), value: 0))
                i += 2
            case 0xA0, 0xE0: // polyphonic aftertouch / pitch bend — 2 data bytes, not actionable
                i += 3
            case 0xD0: // channel pressure — 1 data byte
                i += 2
            default: // system message (0xF0–0xFF), including sysex — bail out of this packet
                return messages
            }
        }
        return messages
    }
}
