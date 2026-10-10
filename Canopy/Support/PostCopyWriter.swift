import Foundation
import FoundationModels

// MARK: - Generable output

@Generable
struct GeneratedPostCopy {
    @Guide(description: "A short hook-style headline for the post, under 10 words")
    var headline: String

    @Guide(description: "The post caption, one to three short sentences")
    var caption: String

    @Guide(description: "Relevant hashtags, single words or short phrases without spaces", .maximumCount(10))
    var hashtags: [String]
}

// MARK: - Transcript text for a clip

extension Transcript {
    /// What is said between `start` and `end`, from the word timings.
    func text(from start: TimeInterval, to end: TimeInterval) -> String {
        segments.flatMap(\.words)
            .filter { $0.end > start && $0.start < end }
            .map(\.text)
            .joined(separator: " ")
    }
}

// MARK: - Writer

enum PostCopyError: LocalizedError {
    case modelUnavailable(String)
    case nothingSaid
    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let why): return why
        case .nothingSaid:               return "There's no speech in this clip to write copy from."
        }
    }
}

enum PostCopyWriter {
    /// Most words of clip transcript shown to the model, to stay within its
    /// context window.
    private static let maxWords = 450

    static func write(
        for clip: ClipCandidate, transcript: Transcript, platform: CopyPlatform, hashtagCount: Int
    ) async throws -> PostCopy {
        if let reason = WorkflowAssistant.unavailableReason { throw PostCopyError.modelUnavailable(reason) }

        let words = transcript.text(from: clip.start, to: clip.end).split(separator: " ")
        guard !words.isEmpty else { throw PostCopyError.nothingSaid }
        let spoken = words.prefix(maxWords).joined(separator: " ")

        let instructions = """
        You write social media post copy for a short video clip, using only what is said in it.
        Style: \(platform.styleGuidance) Keep the caption under \(platform.maxCaptionLength) characters.
        Do not invent facts, names, links or claims that aren't in the transcript.
        """
        let generated = try await AIModels.shared.generate(
            GeneratedPostCopy.self,
            instructions: instructions,
            prompt: "Clip transcript:\n\(spoken)\n\nWrite the post copy."
        )
        return normalize(generated, platform: platform, hashtagCount: hashtagCount, fallbackTitle: clip.title)
    }

    /// Cleans what the model returned: hashtags without "#" or spaces,
    /// de-duplicated and capped; caption cut at a word boundary to fit the
    /// platform; blanks replaced with something usable.
    static func normalize(
        _ generated: GeneratedPostCopy, platform: CopyPlatform, hashtagCount: Int, fallbackTitle: String
    ) -> PostCopy {
        var seen = Set<String>()
        var tags: [String] = []
        for raw in generated.hashtags {
            if tags.count >= max(hashtagCount, 0) { break }
            let cleaned = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
            tags.append(cleaned)
        }

        let headline = generated.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = truncate(
            generated.caption.trimmingCharacters(in: .whitespacesAndNewlines),
            to: platform.maxCaptionLength
        )
        return PostCopy(
            headline: headline.isEmpty ? fallbackTitle : truncate(headline, to: 100),
            caption: caption.isEmpty ? fallbackTitle : caption,
            hashtags: tags
        )
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = String(text.prefix(limit))
        // Back up to the last space so a word isn't left half-written.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}
