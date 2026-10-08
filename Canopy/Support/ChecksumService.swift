import Foundation
import CryptoKit

/// SHA-256 hashing and verification for offloaded footage.
///
/// Verification compares the hash of the copy on the destination volume
/// against a hash of the source streamed straight from the deck (a second
/// read of the source, nothing written), so a bad write to shared storage
/// is caught rather than assumed away.
nonisolated enum ChecksumService {
    static let manifestName = "checksums.sha256"
    private static let chunkSize = 4 * 1024 * 1024

    enum Outcome: Equatable {
        case verified(hash: String)
        case mismatch(destination: String, source: String)
        case failed(reason: String)
    }

    // MARK: Hashing

    /// Streams a file through SHA-256 without loading it into memory.
    static func sha256(ofFileAt url: URL) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                // nil or empty both mean end of file; only a throw is an error.
                let chunk: Data?
                do { chunk = try handle.read(upToCount: chunkSize) } catch { return nil }
                guard let data = chunk, !data.isEmpty else { break }
                hasher.update(data: data)
            }
            return hex(hasher.finalize())
        }.value
    }

    /// Streams a file from a HyperDeck over FTP through SHA-256 without
    /// writing it anywhere.
    static func sha256(ofDeckFile fileName: String, on deck: HyperDeck) async -> String? {
        let remotePath = deck.remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deck.remotePath
        let file = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let url = "ftp://\(deck.ipAddress)/\(remotePath)/\(file)"
        let user = "\(deck.username):\(deck.password)"

        return await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "--silent", "--show-error", "--user", user,
                "--connect-timeout", "10",
                "--speed-limit", "1024", "--speed-time", "20",
                url
            ]
            process.standardOutput = pipe
            process.standardError = Pipe()
            do { try process.run() } catch { return nil }

            var hasher = SHA256()
            let reader = pipe.fileHandleForReading
            while true {
                guard let data = try? reader.read(upToCount: chunkSize), !data.isEmpty else { break }
                hasher.update(data: data)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return hex(hasher.finalize())
        }.value
    }

    /// Hashes the copy at `destination` and compares it with the deck's copy.
    static func verifyDownload(of fileName: String, from deck: HyperDeck, at destination: URL) async -> Outcome {
        guard let destHash = await sha256(ofFileAt: destination) else {
            return .failed(reason: "couldn't read the copy on the destination")
        }
        guard let sourceHash = await sha256(ofDeckFile: fileName, on: deck) else {
            return .failed(reason: "couldn't re-read the source on the deck")
        }
        return destHash == sourceHash ? .verified(hash: destHash) : .mismatch(destination: destHash, source: sourceHash)
    }

    // MARK: Manifest

    /// `shasum -a 256 -c`-compatible line.
    static func manifestLine(hash: String, fileName: String) -> String {
        "\(hash)  \(fileName)"
    }

    /// Adds (or replaces) a file's entry in `checksums.sha256` in `directory`.
    static func record(hash: String, fileName: String, in directory: URL) {
        let manifest = directory.appendingPathComponent(manifestName)
        let existing = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
        let suffix = "  \(fileName)"
        var lines = existing.split(separator: "\n").map(String.init).filter { !$0.hasSuffix(suffix) }
        lines.append(manifestLine(hash: hash, fileName: fileName))
        try? (lines.joined(separator: "\n") + "\n").write(to: manifest, atomically: true, encoding: .utf8)
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
