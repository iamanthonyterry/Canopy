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

@MainActor
struct MusicClipTests {
    private func sample(_ start: Double, music: Double, singing: Double = 0, speech: Double = 0) -> MusicSample {
        MusicSample(start: start, end: start + 3, music: music, singing: singing, speech: speech)
    }

    @Test func readingsJoinIntoStretchesAcrossShortGaps() {
        // 0–12s of music, a 4.5s gap, 16.5–30s more, then a long silence and a 3s sting.
        let samples = stride(from: 0.0, to: 12, by: 1.5).map { sample($0, music: 0.9) }
            + stride(from: 16.5, to: 27, by: 1.5).map { sample($0, music: 0.7) }
            + [sample(80, music: 0.95)]
        let ranges = MusicRanges.merge(samples)
        #expect(ranges.count == 1)                       // gap bridged, sting dropped
        #expect(ranges[0].start == 0 && ranges[0].end == 28.5)
        #expect(ranges[0].confidence > 0.7 && ranges[0].confidence < 0.9)
    }

    @Test func talkingOverBackgroundMusicIsNotASong() {
        let talkOver = stride(from: 0.0, to: 30, by: 1.5).map { sample($0, music: 0.6, speech: 0.9) }
        #expect(MusicRanges.merge(talkOver).isEmpty)
        let sung = stride(from: 0.0, to: 30, by: 1.5).map { sample($0, music: 0.6, singing: 0.5, speech: 0.9) }
        #expect(MusicRanges.merge(sung).count == 1)
    }

    @Test func clipsComeFromTheLoudestPartOfEachStretch() throws {
        // A 200s song that's loudest from 120s to 150s.
        var loudness = [Float](repeating: 0.1, count: 300)
        for i in 120..<150 { loudness[i] = 0.8 }
        let analysis = MusicAnalysis(ranges: [MusicRange(start: 40, end: 240, confidence: 0.9)], loudness: loudness)
        let transcript = Transcript(sourceFileName: "A001.mov", locale: "en-US", duration: 300, segments: [])
        var options = ClipFinderOptions()
        options.minDuration = 20
        options.maxDuration = 30
        let clips = MusicClips.candidates(from: analysis, transcript: transcript, options: options)
        #expect(clips.count == 2)                        // two per stretch, not overlapping
        let best = try #require(clips.max { $0.score < $1.score })
        #expect(best.start == 120 && best.end == 150)
        #expect(best.title == "Music at 2:00" && best.openingLine.isEmpty)
        #expect(clips.allSatisfy { $0.start >= 40 && $0.end <= 240 })
        #expect(abs(clips[0].start - clips[1].start) >= 30)
    }

    @Test func stretchesShorterThanAClipAreSkipped() {
        let analysis = MusicAnalysis(ranges: [MusicRange(start: 0, end: 12, confidence: 0.9)], loudness: [])
        let transcript = Transcript(sourceFileName: "A001.mov", locale: "en-US", duration: 60, segments: [])
        #expect(MusicClips.candidates(from: analysis, transcript: transcript, options: .init()).isEmpty)
    }

    @Test func musicClipsSnapToASungLineNearby() throws {
        let analysis = MusicAnalysis(ranges: [MusicRange(start: 10, end: 40, confidence: 0.8)], loudness: [])
        let line = TranscriptSegment(text: "Amazing grace", start: 11, end: 39)
        let transcript = Transcript(sourceFileName: "A001.mov", locale: "en-US", duration: 60, segments: [line])
        let clip = try #require(MusicClips.candidates(from: analysis, transcript: transcript, options: .init()).first)
        #expect(clip.start == 11 && clip.end == 39 && clip.openingLine == "Amazing grace")
    }
}
