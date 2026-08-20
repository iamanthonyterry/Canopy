import Foundation

/// Used/total storage figures for a single device, shown on the Storage page.
struct StorageInfo: Equatable {
    var usedBytes: Int64
    var totalBytes: Int64?   // nil when the device can't report or hasn't been given a capacity

    var usedFormatted: String {
        ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
    }

    var totalFormatted: String? {
        guard let totalBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    /// e.g. "3.2 GB of 10 GB" or, when total is unknown, just "3.2 GB".
    var summary: String {
        guard let totalFormatted else { return usedFormatted }
        return "\(usedFormatted) of \(totalFormatted)"
    }

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(Double(usedBytes) / Double(totalBytes), 1.0)
    }
}

enum StorageCapacityService {

    /// Cloud Store: reads the real total/available capacity straight from the
    /// mounted SMB volume, so this is accurate down to the byte.
    static func capacity(for store: CloudStore) async throws -> StorageInfo {
        let mountPath = try await SMBService.mount(store: store)
        let values = try URL(fileURLWithPath: mountPath).resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        )
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        return StorageInfo(usedBytes: max(total - available, 0), totalBytes: total > 0 ? total : nil)
    }

    /// HyperDeck: the Ethernet protocol has no command that reports raw disk
    /// capacity — only an estimated recording-time-remaining figure — so
    /// "used" is the real total of every file's size from the deck's FTP
    /// listing, walked recursively. "Total" comes from the capacity the user
    /// optionally entered for the deck, since the deck itself can't report it.
    static func capacity(for deck: HyperDeck) async -> StorageInfo {
        let used = await recursiveSize(deck: deck, path: deck.remotePath)
        let total = deck.capacityGB.map { Int64($0 * 1_000_000_000) }
        return StorageInfo(usedBytes: used, totalBytes: total)
    }

    private static func recursiveSize(deck: HyperDeck, path: String) async -> Int64 {
        let entries = await FTPService.listAllFiles(on: deck, path: path)
        var total: Int64 = 0
        for entry in entries {
            if entry.isDirectory {
                let childPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
                total += await recursiveSize(deck: deck, path: childPath)
            } else {
                total += entry.size
            }
        }
        return total
    }
}
