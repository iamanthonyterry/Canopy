import Foundation

/// Copies one file to a second location, safely: written under a temporary
/// name and moved into place so a half-copied file never looks finished, and
/// optionally verified by comparing SHA-256 hashes of both ends.
nonisolated enum FileCopier {
    enum Result: Equatable {
        case copied
        /// The destination already held an identical file.
        case skipped
        /// The copy's hash didn't match the source's; the copy was removed.
        case mismatch
        case failed(String)
    }

    @concurrent
    static func copy(from source: URL, to destination: URL, verify: Bool) async -> Result {
        let fm = FileManager.default

        // Already there? Same size (and same hash, when verifying) → nothing to do.
        if fm.fileExists(atPath: destination.path), sameSize(source, destination) {
            if !verify { return .skipped }
            if let a = await ChecksumService.sha256(ofFileAt: source),
               let b = await ChecksumService.sha256(ofFileAt: destination), a == b {
                return .skipped
            }
        }

        let partial = destination.appendingPathExtension("partial")
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: source, to: partial)
        } catch {
            try? fm.removeItem(at: partial)
            return .failed(error.localizedDescription)
        }

        if verify {
            let a = await ChecksumService.sha256(ofFileAt: source)
            let b = await ChecksumService.sha256(ofFileAt: partial)
            guard let a, let b, a == b else {
                try? fm.removeItem(at: partial)
                return .mismatch
            }
        }

        do {
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: partial)
            return .failed(error.localizedDescription)
        }
        return .copied
    }

    private static func sameSize(_ a: URL, _ b: URL) -> Bool {
        let sizeA = try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let sizeB = try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return sizeA != nil && sizeA == sizeB
    }

    /// The files that travel with a video: its transcript, subtitles, clip
    /// suggestions, and any finished posts rendered from it.
    static func sidecars(of video: URL) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for name in [
            video.deletingPathExtension().appendingPathExtension("transcript.json"),
            video.deletingPathExtension().appendingPathExtension("srt"),
            video.deletingPathExtension().appendingPathExtension("clips.json"),
        ] where fm.fileExists(atPath: name.path) {
            result.append(name)
        }
        return result
    }
}
