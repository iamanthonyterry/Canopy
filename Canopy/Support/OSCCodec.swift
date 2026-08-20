import Foundation

// MARK: - OSC Value
// The four argument types this app understands. OSC also defines a few
// no-payload type tags (true/false/nil/impulse) which we skip when
// encountered — they carry no data bytes to decode.

enum OSCValue: Hashable {
    case int(Int32)
    case float(Float)
    case string(String)
    case blob(Data)

    var displayText: String {
        switch self {
        case .int(let v):    return "\(v)"
        case .float(let v):  return "\(v)"
        case .string(let v): return v
        case .blob(let v):   return "<\(v.count) bytes>"
        }
    }
}

// MARK: - OSC Message

struct OSCMessage: Hashable {
    var address: String
    var arguments: [OSCValue]
}

// MARK: - OSC Codec
// Decodes raw UDP packet bytes per the OSC 1.0 spec: every field is padded
// to a 4-byte boundary, and a packet is either a single message (starts
// with '/') or a bundle of nested messages/bundles (starts with "#bundle").
// This app only needs to receive OSC, so encoding isn't implemented.

enum OSCCodec {
    static func decode(_ data: Data) -> [OSCMessage] {
        guard !data.isEmpty else { return [] }
        if data.starts(with: Data("#bundle\0".utf8)) {
            return decodeBundle(data)
        }
        return decodeMessage(data).map { [$0] } ?? []
    }

    // MARK: Bundle

    private static func decodeBundle(_ data: Data) -> [OSCMessage] {
        // Skip "#bundle\0" (8 bytes) + the 8-byte OSC time tag.
        var offset = data.startIndex + 16
        var messages: [OSCMessage] = []

        while offset + 4 <= data.endIndex {
            let size = Int(readInt32(data, at: offset))
            offset += 4
            guard size > 0, offset + size <= data.endIndex else { break }
            let element = data.subdata(in: offset..<(offset + size))
            messages.append(contentsOf: decode(element))
            offset += size
        }
        return messages
    }

    // MARK: Message

    private static func decodeMessage(_ data: Data) -> OSCMessage? {
        var offset = data.startIndex
        guard let address = readString(data, at: &offset), address.hasPrefix("/") else { return nil }

        // No type tag string means no arguments (some senders omit it).
        guard offset < data.endIndex, data[offset] == UInt8(ascii: ","),
              let typeTags = readString(data, at: &offset) else {
            return OSCMessage(address: address, arguments: [])
        }

        var arguments: [OSCValue] = []
        for tag in typeTags.dropFirst() { // drop the leading ','
            switch tag {
            case "i":
                guard offset + 4 <= data.endIndex else { return OSCMessage(address: address, arguments: arguments) }
                arguments.append(.int(Int32(bitPattern: readInt32(data, at: offset))))
                offset += 4
            case "f":
                guard offset + 4 <= data.endIndex else { return OSCMessage(address: address, arguments: arguments) }
                arguments.append(.float(Float(bitPattern: readInt32(data, at: offset))))
                offset += 4
            case "s":
                guard let s = readString(data, at: &offset) else { return OSCMessage(address: address, arguments: arguments) }
                arguments.append(.string(s))
            case "b":
                guard offset + 4 <= data.endIndex else { return OSCMessage(address: address, arguments: arguments) }
                let length = Int(readInt32(data, at: offset))
                offset += 4
                guard length >= 0, offset + length <= data.endIndex else { return OSCMessage(address: address, arguments: arguments) }
                arguments.append(.blob(data.subdata(in: offset..<(offset + length))))
                offset += paddedLength(length)
            default:
                // Type tag with no payload (T/F/N/I) or one we don't
                // support — nothing to advance past, just skip the tag.
                continue
            }
        }
        return OSCMessage(address: address, arguments: arguments)
    }

    // MARK: Primitives

    /// Reads a null-terminated, 4-byte-padded OSC string starting at
    /// `offset`, advancing `offset` past it on success.
    private static func readString(_ data: Data, at offset: inout Data.Index) -> String? {
        guard let nullIndex = data[offset...].firstIndex(of: 0) else { return nil }
        let string = String(data: data[offset..<nullIndex], encoding: .utf8) ?? ""
        let rawLength = nullIndex - offset + 1
        offset += paddedLength(rawLength)
        return string
    }

    /// Rounds a byte count up to the next multiple of 4, per OSC's padding rule.
    private static func paddedLength(_ length: Int) -> Int {
        length + ((4 - (length % 4)) % 4)
    }

    /// Reads a big-endian (network order) 32-bit value at `offset`.
    private static func readInt32(_ data: Data, at offset: Data.Index) -> UInt32 {
        let bytes = data[offset..<(offset + 4)]
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
