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
    /// What the user asked for; empty looks for whatever stands out.
    var focus = ClipFocus()
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

// MARK: - Music clips (pure — picks from what the detector heard)

enum MusicClips {
    /// Up to two clips per stretch of music: the loudest parts, which is
    /// usually where the chorus or the big moment is.
    static func candidates(from analysis: MusicAnalysis, transcript: Transcript,
                           options: ClipFinderOptions) -> [ClipCandidate] {
        var picks: [(range: MusicRange, start: TimeInterval, length: TimeInterval, level: Float)] = []
        for range in analysis.ranges where range.duration >= options.minDuration {
            let length = min(options.maxDuration, range.duration)
            var taken: [TimeInterval] = []
            for _ in 0..<2 {
                guard let best = loudestStart(in: range, length: length, loudness: analysis.loudness, avoiding: taken)
                else { break }
                taken.append(best.start)
                picks.append((range, best.start, length, best.level))
            }
        }
        let peak = max(picks.map(\.level).max() ?? 0, .leastNormalMagnitude)

        return picks.map { pick in
            var start = pick.start
            var end = pick.start + pick.length
            // Start and end on a sung line when the transcript has one close by.
            let from = nearest(to: start, in: transcript.segments.map(\.start)) ?? start
            let to = nearest(to: end, in: transcript.segments.map(\.end)) ?? end
            if (options.minDuration...options.maxDuration).contains(to - from) { start = from; end = to }
            if transcript.duration > 0 { end = min(end, transcript.duration) }

            let score = 50 + 30 * pick.range.confidence + 20 * Double(pick.level / peak)
            return ClipCandidate(
                start: max(0, start), end: end,
                title: "Music at \(clock(start))",
                reason: "Music heard in the audio. This is the loudest part of a \(clock(pick.range.duration)) stretch.",
                score: min(max(Int(score.rounded()), 0), 100),
                openingLine: transcript.segments.first { $0.end > start && $0.start < end }?.text ?? ""
            )
        }
    }

    /// The start of the loudest `length`-second window inside `range` that
    /// doesn't overlap one already taken. Falls back to the start of the
    /// range when there are no loudness readings to compare.
    static func loudestStart(in range: MusicRange, length: TimeInterval, loudness: [Float],
                             avoiding taken: [TimeInterval]) -> (start: TimeInterval, level: Float)? {
        let first = Int(range.start.rounded(.up))
        let last = Int((range.end - length).rounded(.down))
        func free(_ start: TimeInterval) -> Bool { taken.allSatisfy { abs($0 - start) >= length } }
        let seconds = Int(length)
        guard last >= first, seconds > 0, last + seconds <= loudness.count else {
            return free(range.start) ? (range.start, 0) : nil
        }
        var sum = loudness[first..<first + seconds].reduce(0, +)
        var best: (start: TimeInterval, level: Float)?
        for start in first...last {
            if start > first { sum += loudness[start + seconds - 1] - loudness[start - 1] }
            let level = sum / Float(seconds)
            if free(TimeInterval(start)), level > (best?.level ?? -1) { best = (TimeInterval(start), level) }
        }
        return best
    }

    private static func nearest(to time: TimeInterval, in boundaries: [TimeInterval], within: TimeInterval = 2) -> TimeInterval? {
        boundaries.min { abs($0 - time) < abs($1 - time) }.flatMap { abs($0 - time) <= within ? $0 : nil }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
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
    private static let defaultPreference =
        "Prefer personal stories, strong opinions, useful tips and funny or emotional moments."

    /// The standing instructions, with the user's focus in place of the
    /// default taste when they've said what they're after.
    static func instructions(for focus: ClipFocus) -> String {
        """
        You find moments in a video transcript that would work as standalone short social media posts.
        A good clip opens with a hook (a bold claim, a question, a surprising or emotional line), is one \
        complete thought or story beat that makes sense without the rest of the video, and ends on a \
        satisfying line.
        \(focus.guidance ?? defaultPreference)
        Skip intros, sign-offs, filler, and anything that depends on earlier context.
        Segments are numbered. Answer with segment numbers from the passage only.
        """
    }

    /// - Parameters:
    ///   - video: the file itself, listened to when the focus includes music.
    ///   - log: told what the music pass found, for the workflow log.
    ///   - progress: called with 0...1 as windows finish.
    static func findClips(
        in transcript: Transcript,
        video: URL? = nil,
        options: ClipFinderOptions = ClipFinderOptions(),
        log: (String) -> Void = { _ in },
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [ClipCandidate] {
        var options = options
        var candidates: [ClipCandidate] = []

        // Music is found by ear rather than from the transcript. When that
        // works, the model is left to look for everything else.
        if options.focus.kinds.contains(.music), let video {
            do {
                let analysis = try await MusicDetector.analyze(video: video)
                candidates = MusicClips.candidates(from: analysis, transcript: transcript, options: options)
                log("🎵 \(analysis.ranges.count) stretch\(analysis.ranges.count == 1 ? "" : "es") of music heard in \(video.lastPathComponent)")
                options.focus.set(.music, on: false)
                if options.focus.isEmpty { return ClipSelection.rank(candidates, limit: options.maxClips) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log("⚠️ Couldn't listen for music in \(video.lastPathComponent) (\(error.localizedDescription)) — looking for sung words instead")
            }
        }

        if let reason = WorkflowAssistant.unavailableReason {
            // The music already found doesn't need the model.
            guard !candidates.isEmpty else { throw ClipFinderError.modelUnavailable(reason) }
            log("⚠️ \(reason) — keeping only the music clips")
            return ClipSelection.rank(candidates, limit: options.maxClips)
        }

        // A stronger model can weigh much more of the video at once, which
        // is what lets it tell a real standout moment from a merely
        // decent one, so give it bigger windows.
        if AIModels.shared.isEnhancedActive { options.windowWords = max(options.windowWords, 900) }

        let instructions = Self.instructions(for: options.focus)
        // Repeated next to the passage: a small model follows what it read last.
        let reminder = options.focus.isEmpty ? "" : " Looking for: \(options.focus.summary)."
        let segments = transcript.segments
        let windows = ClipSelection.windows(for: segments, words: options.windowWords)

        for (n, window) in windows.enumerated() {
            try Task.checkCancellation()
            let passage = window.map { "[\($0)] \(segments[$0].text)" }.joined(separator: "\n")
            let prompt = """
            Passage (segments \(window.lowerBound) to \(window.upperBound - 1)):
            \(passage)

            Pick up to 2 moments of \(Int(options.minDuration)) to \(Int(options.maxDuration)) seconds.\(reminder)
            """
            do {
                let picks = try await AIModels.shared.generate(
                    ClipPicks.self, instructions: instructions, prompt: prompt)
                for pick in picks.picks {
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
