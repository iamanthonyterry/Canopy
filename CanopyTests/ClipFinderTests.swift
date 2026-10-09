import Foundation
import Testing
@testable import Canopy

@MainActor
struct ClipFinderTests {
    /// `n` segments of `len` seconds each, back to back, ending in a full stop.
    private func segments(_ n: Int, len: Double = 10, text: String = "This is a complete sentence.") -> [TranscriptSegment] {
        (0..<n).map { TranscriptSegment(text: text, start: Double($0) * len, end: Double($0 + 1) * len) }
    }
    private func pick(_ s: Int, _ e: Int, score: Int = 8) -> RawClipPick {
        RawClipPick(startIndex: s, endIndex: e, title: " Title ", score: score, reason: "why")
    }

    @Test func snapsToSegmentBoundariesWithSmallPadding() throws {
        let c = try #require(ClipSelection.candidate(from: pick(2, 4), segments: segments(10), videoDuration: 100, options: .init()))
        #expect(abs(c.start - 19.85) < 0.001)   // segment 2 starts at 20s, minus 0.15s
        #expect(abs(c.end - 50.35) < 0.001)     // segment 4 ends at 50s, plus 0.35s
        #expect(c.title == "Title")
    }

    @Test func tooLongPicksAreTrimmedToWholeSegments() throws {
        let c = try #require(ClipSelection.candidate(from: pick(0, 9), segments: segments(10), videoDuration: 100, options: .init()))
        #expect(c.duration <= 61)               // 60s limit plus padding
    }

    @Test func tooShortPicksAreGrownToTheMinimum() throws {
        let c = try #require(ClipSelection.candidate(from: pick(3, 3), segments: segments(10), videoDuration: 100, options: .init()))
        #expect(c.duration >= 20)
    }

    @Test func outOfRangeAndReversedIndicesAreClamped() throws {
        let c = try #require(ClipSelection.candidate(from: pick(12, 1), segments: segments(10), videoDuration: 100, options: .init()))
        #expect(c.start >= 0 && c.end <= 100)
    }

    @Test func transcriptTooShortForMinimumGivesNothing() {
        let short = segments(1, len: 5)
        #expect(ClipSelection.candidate(from: pick(0, 0), segments: short, videoDuration: 5, options: .init()) == nil)
    }

    @Test func cleanCutsScoreHigherThanMidSentenceCuts() {
        var segs = segments(6)
        segs[1].text = "and then something happened"       // no full stop, filler start
        segs[3].text = "and that was when it all"
        let mid = ClipSelection.cleanliness(start: 2, end: 3, segments: segs, duration: 20)
        let clean = ClipSelection.cleanliness(start: 4, end: 5, segments: segs, duration: 20)
        #expect(clean > mid)
    }

    @Test func rankingDropsOverlapsAndKeepsBestFirst() {
        func cand(_ s: Double, _ e: Double, _ score: Int) -> ClipCandidate {
            ClipCandidate(start: s, end: e, title: "t", reason: "r", score: score, openingLine: "")
        }
        let ranked = ClipSelection.rank([cand(0, 30, 60), cand(10, 40, 90), cand(100, 130, 70)], limit: 5)
        #expect(ranked.map(\.score) == [90, 70])
        #expect(ClipSelection.rank([cand(0, 30, 60), cand(100, 130, 70)], limit: 1).map(\.score) == [70])
    }

    @Test func windowsOverlapAndCoverEverySegment() {
        let segs = segments(60, text: "one two three four five six seven eight nine ten")
        let windows = ClipSelection.windows(for: segs, words: 100)
        #expect(windows.first?.lowerBound == 0)
        #expect(windows.last?.upperBound == 60)
        for (a, b) in zip(windows, windows.dropFirst()) { #expect(b.lowerBound < a.upperBound) }
    }

    @Test func sidecarRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("A001.mov")
        let s = ClipSuggestions(sourceFileName: "A001.mov", generatedAt: Date(timeIntervalSince1970: 0),
                                candidates: [ClipCandidate(start: 1, end: 31, title: "T", reason: "R", score: 80, openingLine: "Hi")])
        try s.write(for: video)
        #expect(ClipSuggestions.sidecarURL(for: video).lastPathComponent == "A001.clips.json")
        #expect(ClipSuggestions.load(for: video)?.candidates.first?.title == "T")
    }
}
