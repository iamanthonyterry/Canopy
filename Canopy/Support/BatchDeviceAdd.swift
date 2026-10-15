import Foundation

// MARK: - Batch add naming
// Used by the inventory's add-equipment form to create several of the same
// device in one go. Copies are numbered, and an IPv4 address has its last
// octet counted up so each copy gets its own.
nonisolated enum BatchDeviceAdd {
    static let hardLimit = 24

    /// "Wedge 3" -> Wedge 3, Wedge 4, …   "SQ-5" -> SQ-5 1, SQ-5 2, …
    /// Only a number set off by a space counts as a count, so model numbers
    /// like "SQ-5" or "X32" are never bumped into a different model.
    static func names(base: String, count: Int) -> [String] {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard count > 1 else { return [trimmed] }

        if let range = trimmed.range(of: #"\s\d+$"#, options: .regularExpression) {
            let digits = trimmed[range].trimmingCharacters(in: .whitespaces)
            if let start = Int(digits) {
                let prefix = String(trimmed[..<range.lowerBound])
                return (0..<count).map { "\(prefix) \(String(format: "%0*d", digits.count, start + $0))" }
            }
        }
        return (1...count).map { "\(trimmed) \($0)" }
    }

    /// Counts the last octet of an IPv4 address up. Anything else (a host
    /// name, IPv6, blank) is kept on the first and left blank on the rest, so
    /// no two copies share an address.
    static func addresses(base: String, count: Int) -> [String] {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard count > 1 else { return [trimmed] }
        guard let (prefix, last) = splitIPv4(trimmed) else {
            return [trimmed] + Array(repeating: "", count: count - 1)
        }
        return (0..<count).map { "\(prefix).\(last + $0)" }
    }

    /// The most copies that can be made from this address without running the
    /// last octet past 254.
    static func maxQuantity(forAddress address: String) -> Int {
        guard let (_, last) = splitIPv4(address.trimmingCharacters(in: .whitespaces)) else { return hardLimit }
        return min(hardLimit, max(1, 255 - last))
    }

    private static func splitIPv4(_ address: String) -> (prefix: String, last: Int)? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return (parts[0..<3].joined(separator: "."), octets[3])
    }
}
