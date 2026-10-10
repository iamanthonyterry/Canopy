import Foundation

// MARK: - Clip suggestions
// Moments in a long video that could stand alone as a short social post.
// Saved as a `.clips.json` sidecar next to the video, like transcripts.

/// Ready-to-post text for a clip.
nonisolated struct PostCopy: Codable, Hashable {
    var headline: String
    var caption: String
    /// Without the leading "#".
    var hashtags: [String]

    /// What to paste into a post: the caption followed by the hashtags.
    var postText: String {
        let tags = hashtags.map { "#\($0)" }.joined(separator: " ")
        return tags.isEmpty ? caption : "\(caption)\n\n\(tags)"
    }
}

struct ClipCandidate: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var title: String
    var reason: String
    /// 0–100, higher is a stronger standalone clip.
    var score: Int
    /// The first line spoken, for the review list.
    var openingLine: String
    /// Drafted by the Write Post Copy step; nil until then.
    var copy: PostCopy? = nil

    var duration: TimeInterval { end - start }
}

struct ClipSuggestions: Codable, Hashable {
    var sourceFileName: String
    var generatedAt: Date
    var candidates: [ClipCandidate]

    static func sidecarURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("clips.json")
    }

    static func load(for video: URL) -> ClipSuggestions? {
        guard let data = try? Data(contentsOf: sidecarURL(for: video)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClipSuggestions.self, from: data)
    }

    func write(for video: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.sidecarURL(for: video), options: .atomic)
    }
}
