import Foundation
import Testing
@testable import Canopy

@MainActor
struct CaptionTests {
    private func transcript(_ words: [(String, Double, Double)]) -> Transcript {
        let ws = words.map { TranscriptWord(text: $0.0, start: $0.1, end: $0.2) }
        return Transcript(sourceFileName: "v.mov", locale: "en-US", duration: 100,
                          segments: [TranscriptSegment(text: words.map(\.0).joined(separator: " "),
                                                       start: words.first!.1, end: words.last!.2, words: ws)])
    }

    @Test func groupsAtMostFourWords() {
        let t = transcript((0..<9).map { ("word\($0)", Double($0) * 0.3, Double($0) * 0.3 + 0.25) })
        let cues = CaptionBuilder.cues(from: t, clipStart: 0, clipEnd: 10)
        #expect(cues.map { $0.text.split(separator: " ").count } == [4, 4, 1])
    }

    @Test func breaksAtSentenceEndsAndPauses() {
        let t = transcript([("Hello", 0, 0.3), ("there.", 0.3, 0.6), ("Next", 0.7, 1.0), ("one", 1.0, 1.2),
                            ("after", 2.5, 2.8), ("pause", 2.8, 3.0)])
        let cues = CaptionBuilder.cues(from: t, clipStart: 0, clipEnd: 10)
        #expect(cues.map(\.text) == ["Hello there.", "Next one", "after pause"])
    }

    @Test func timesAreRelativeToClipStartAndOnlyCoverTheClip() {
        let t = transcript([("before", 1, 1.4), ("inside", 10, 10.4), ("words", 10.4, 10.8), ("after", 40, 40.4)])
        let cues = CaptionBuilder.cues(from: t, clipStart: 10, clipEnd: 20)
        #expect(cues.count == 1)
        #expect(cues[0].text == "inside words")
        #expect(abs(cues[0].start - 0) < 0.001)
    }

    @Test func captionsStayOnScreenAcrossSmallGaps() {
        let t = transcript([("one", 0, 0.3), ("two.", 0.3, 0.6), ("three", 0.8, 1.1), ("four.", 1.1, 1.4)])
        let cues = CaptionBuilder.cues(from: t, clipStart: 0, clipEnd: 10)
        #expect(cues.count == 2)
        let gap = cues[1].start - cues[0].end
        #expect(gap > 0 && gap < 0.05)   // 0.2s gap is bridged, without overlapping
    }

    @Test func noWordsInRangeGivesNoCaptions() {
        let t = transcript([("a", 1, 1.2)])
        #expect(CaptionBuilder.cues(from: t, clipStart: 50, clipEnd: 60).isEmpty)
    }
}
