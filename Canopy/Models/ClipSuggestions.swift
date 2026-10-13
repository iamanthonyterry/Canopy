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

// MARK: - What to look for

/// A kind of moment Find Clips can be asked to look for.
enum ClipKind: String, Codable, CaseIterable, Identifiable {
    case quotes, stories, teaching, funny, emotional, music

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quotes:    return "Speaker quotes"
        case .stories:   return "Stories"
        case .teaching:  return "Tips & teaching"
        case .funny:     return "Funny moments"
        case .emotional: return "Emotional moments"
        case .music:     return "Music & songs"
        }
    }

    /// How the kind is described to the model.
    var guidance: String {
        switch self {
        case .quotes:    return "Quotable lines: a speaker making one strong, memorable statement that could be shared as a quote"
        case .stories:   return "Stories: a speaker telling a personal story or anecdote from start to finish"
        case .teaching:  return "Tips and teaching: a speaker explaining one clear idea, lesson or piece of advice"
        case .funny:     return "Funny moments: jokes, banter and lines that get a laugh"
        case .emotional: return "Emotional moments: moving, vulnerable or heartfelt passages"
        case .music:     return "Songs and music: passages where the words are sung lyrics, such as repeated lines, a verse or a chorus"
        }
    }
}

/// What the user wants Find Clips to look for: any of the kinds above, plus
/// anything specific in their own words. Empty means "whatever stands out".
struct ClipFocus: Codable, Hashable {
    /// Kept in `ClipKind.allCases` order so equal choices compare equal.
    var kinds: [ClipKind] = []
    var notes = ""

    private static let maxNoteLength = 200

    /// `notes` as it's shown to the model.
    var note: String {
        String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNoteLength))
    }

    var isEmpty: Bool { kinds.isEmpty && note.isEmpty }

    mutating func set(_ kind: ClipKind, on: Bool) {
        var chosen = Set(kinds)
        if on { chosen.insert(kind) } else { chosen.remove(kind) }
        kinds = ClipKind.allCases.filter(chosen.contains)
    }

    /// "Speaker quotes, Music & songs · “about hope”" — for step summaries and logs.
    var summary: String {
        var parts: [String] = []
        if !kinds.isEmpty { parts.append(kinds.map(\.title).joined(separator: ", ")) }
        if !note.isEmpty { parts.append("“\(note)”") }
        return parts.joined(separator: " · ")
    }

    /// What the model is told to look for; nil when nothing was asked for.
    var guidance: String? {
        guard !isEmpty else { return nil }
        var lines: [String] = []
        if !kinds.isEmpty {
            lines.append("Only pick these kinds of moments:")
            lines += kinds.map { "- \($0.guidance)" }
        }
        if !note.isEmpty { lines.append("The user is specifically looking for: \(note)") }
        lines.append("Score a moment by how well it matches this. Pick nothing from a passage that has no match.")
        return lines.joined(separator: "\n")
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
    /// What these were found for; nil in files saved before a focus could be set.
    var focus: ClipFocus? = nil

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
