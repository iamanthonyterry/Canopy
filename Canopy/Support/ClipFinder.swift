import Foundation
import FoundationModels

// MARK: - Generable output
// The model picks segment *numbers*, not timestamps, so every suggested clip
// starts and ends on a real utterance boundary.

@Generable
struct ClipPick {
    @Guide(description: "Number of the first segment of the clip")
    var startIndex: Int

    @Guide(description: "Number of the last segment of the clip")
    var endIndex: Int

    @Guide(description: "A short, punchy title for the clip, 3 to 8 words")
    var title: String

    @Guide(description: "How strong a standalone social post this is, 1 (weak) to 10 (excellent)", .range(1...10))
    var score: Int

    @Guide(description: "One sentence on why it works as a short post")
    var reason: String
}

@Generable
struct ClipPicks {
    @Guide(description: "The best self-contained moments in this passage. Empty if nothing stands out.", .maximumCount(2))
    var picks: [ClipPick]
}

// MARK: - Options

struct ClipFinderOptions {
    var maxClips = 5
    var minDuration: TimeInterval = 20
    var maxDuration: TimeInterval = 60
    /// Approximate words of transcript shown to the model per request.
    var windowWords = 300
}

// MARK: - Selection (pure — no model involved)

struct RawClipPick {
    var startIndex: Int
    var endIndex: Int
    var title: String
    var score: Int          // 1...10 from the model
    var reason: String
}

enum ClipSelection {
    private static let terminal: Set<Character> = [".", "?", "!", "…"]
    private static let fillerStarts: Set<String> = ["and", "but", "so", "because", "which", "then", "or", "also"]

    /// Turns a model pick into a candidate: snaps to segment boundaries,
    /// enforces the duration limits, and scores how cleanly it cuts.
    static func candidate(
        from pick: RawClipPick,
        segments: [TranscriptSegment],
        videoDuration: TimeInterval,
        options: ClipFinderOptions
    ) -> ClipCandidate? {
        guard !segments.isEmpty else { return nil }
        var start = min(max(pick.startIndex, 0), segments.count - 1)
        var end = min(max(pick.endIndex, 0), segments.count - 1)
        if end < start { swap(&start, &end) }

        func length(_ s: Int, _ e: Int) -> TimeInterval { segments[e].end - segments[s].start }

        // Too long: drop trailing segments, keeping whole utterances.
        while length(start, end) > options.maxDuration, end > start { end -= 1 }
        guard length(start, end) <= options.maxDuration * 1.5 else { return nil }

        // Too short: grow forward first (completes the thought), then back.
        var growForward = true
        while length(start, end) < options.minDuration {
            if growForward, end + 1 < segments.count, length(start, end + 1) <= options.maxDuration {
                end += 1
            } else if start > 0, length(start - 1, end) <= options.maxDuration {
                start -= 1
            } else if end + 1 < segments.count, length(start, end + 1) <= options.maxDuration {
                end += 1
            } else {
                return nil
            }
            growForward.toggle()
        }

        let from = max(0, segments[start].start - 0.15)
        let to = min(videoDuration > 0 ? videoDuration : .infinity, segments[end].end + 0.35)
        let clean = cleanliness(start: start, end: end, segments: segments, duration: to - from)
        let combined = Int((Double(min(max(pick.score, 1), 10)) * 10 * 0.65 + Double(clean) * 0.35).rounded())

        return ClipCandidate(
            start: from, end: to,
            title: pick.title.trimmingCharacters(in: .whitespacesAndNewlines),
            reason: pick.reason.trimmingCharacters(in: .whitespacesAndNewlines),
            score: min(max(combined, 0), 100),
            openingLine: segments[start].text
        )
    }

    /// 0–100: does this clip start and end like a finished thought?
    static func cleanliness(start: Int, end: Int, segments: [TranscriptSegment], duration: TimeInterval) -> Int {
        var score = 50
        if let last = segments[end].text.last, terminal.contains(last) { score += 20 }
        if start == 0 { score += 15 }
        else if let prev = segments[start - 1].text.last, terminal.contains(prev) { score += 15 }
        if let first = segments[start].text.split(separator: " ").first?.lowercased(),
           fillerStarts.contains(first.trimmingCharacters(in: .punctuationCharacters)) { score -= 10 }
        if segments[start].text.contains("?") { score += 5 }
        if (25...45).contains(duration) { score += 10 }
        return min(max(score, 0), 100)
    }

    /// Highest score first; a candidate is dropped when it mostly covers
    /// ground an already-chosen one does.
    static func rank(_ candidates: [ClipCandidate], limit: Int) -> [ClipCandidate] {
        var chosen: [ClipCandidate] = []
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            let overlapsTooMuch = chosen.contains { other in
                let overlap = min(c.end, other.end) - max(c.start, other.start)
                return overlap > 0.3 * min(c.duration, other.duration)
            }
            if !overlapsTooMuch { chosen.append(c) }
            if chosen.count == limit { break }
        }
        return chosen
    }

    /// Overlapping windows of consecutive segments, about `words` words each.
    static func windows(for segments: [TranscriptSegment], words: Int) -> [Range<Int>] {
        guard !segments.isEmpty else { return [] }
        let counts = segments.map { $0.text.split(separator: " ").count }
        var result: [Range<Int>] = []
        var startIdx = 0
        while startIdx < segments.count {
            var total = 0
            var endIdx = startIdx
            while endIdx < segments.count, total + counts[endIdx] <= words || endIdx == startIdx {
                total += counts[endIdx]
                endIdx += 1
            }
            result.append(startIdx..<endIdx)
            if endIdx >= segments.count { break }
            // Step by half a window so a moment on a boundary is seen whole.
            startIdx += max(1, (endIdx - startIdx) / 2)
        }
        return result
    }
}

// MARK: - Finder

enum ClipFinderError: LocalizedError {
    case modelUnavailable(String)
    var errorDescription: String? {
        switch self { case .modelUnavailable(let why): return why }
    }
}

enum ClipFinder {
    private static let instructions = """
    You find moments in a video transcript that would work as standalone short social media posts.
    A good clip opens with a hook (a bold claim, a question, a surprising or emotional line), is one \
    complete thought or story beat that makes sense without the rest of the video, and ends on a \
    satisfying line. Prefer personal stories, strong opinions, useful tips and funny or emotional \
    moments. Skip intros, sign-offs, filler, and anything that depends on earlier context.
    Segments are numbered. Answer with segment numbers from the passage only.
    """

    /// - Parameter progress: called with 0...1 as windows finish.
    static func findClips(
        in transcript: Transcript,
        options: ClipFinderOptions = ClipFinderOptions(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [ClipCandidate] {
        if let reason = WorkflowAssistant.unavailableReason { throw ClipFinderError.modelUnavailable(reason) }

        let segments = transcript.segments
        let windows = ClipSelection.windows(for: segments, words: options.windowWords)
        var candidates: [ClipCandidate] = []

        for (n, window) in windows.enumerated() {
            try Task.checkCancellation()
            let passage = window.map { "[\($0)] \(segments[$0].text)" }.joined(separator: "\n")
            let prompt = """
            Passage (segments \(window.lowerBound) to \(window.upperBound - 1)):
            \(passage)

            Pick up to 2 moments of \(Int(options.minDuration)) to \(Int(options.maxDuration)) seconds.
            """
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: prompt, generating: ClipPicks.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                for pick in response.content.picks {
                    let raw = RawClipPick(startIndex: pick.startIndex, endIndex: pick.endIndex,
                                          title: pick.title, score: pick.score, reason: pick.reason)
                    // Only accept picks that point inside the window we showed.
                    guard window.contains(raw.startIndex), window.contains(raw.endIndex) else { continue }
                    if let c = ClipSelection.candidate(from: raw, segments: segments,
                                                       videoDuration: transcript.duration, options: options) {
                        candidates.append(c)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A single window the model refuses or overflows on shouldn't
                // sink the whole video.
                continue
            }
            progress(Double(n + 1) / Double(windows.count))
        }
        return ClipSelection.rank(candidates, limit: options.maxClips)
    }
}
