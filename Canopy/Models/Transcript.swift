import Foundation

// MARK: - Transcript
// Timed text for one video. Saved as a `.transcript.json` sidecar next to the
// clip so later steps (clip finding, captions) can read it without re-running
// speech recognition.

struct TranscriptWord: Codable, Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct TranscriptSegment: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var words: [TranscriptWord] = []
}

struct Transcript: Codable, Hashable {
    var sourceFileName: String
    var locale: String
    var duration: TimeInterval
    var segments: [TranscriptSegment]

    var fullText: String { segments.map(\.text).joined(separator: " ") }

    // MARK: Sidecar files

    static let sidecarSuffix = ".transcript.json"

    static func sidecarURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    static func srtURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("srt")
    }

    static func load(for video: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: sidecarURL(for: video)) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    func write(for video: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.sidecarURL(for: video), options: .atomic)
    }

    func writeSRT(for video: URL) throws {
        try srt.write(to: Self.srtURL(for: video), atomically: true, encoding: .utf8)
    }

    // MARK: SRT

    var srt: String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(Self.srtTime(segment.start)) --> \(Self.srtTime(segment.end))\n\(segment.text)\n"
        }.joined(separator: "\n")
    }

    private static func srtTime(_ t: TimeInterval) -> String {
        let ms = Int((max(t, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
