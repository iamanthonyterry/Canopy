import Foundation
import Testing
@testable import Canopy

@MainActor
struct PostCopyTests {
    private func generated(tags: [String], caption: String = "Short caption.", headline: String = "A headline") -> GeneratedPostCopy {
        GeneratedPostCopy(headline: headline, caption: caption, hashtags: tags)
    }

    @Test func hashtagsAreCleanedDedupedAndCapped() {
        let r = PostCopyWriter.normalize(
            generated(tags: ["#Matcha", "matcha", "fresh start!", "#", "Career Change", "life", "work"]),
            platform: .general, hashtagCount: 3, fallbackTitle: "T"
        )
        #expect(r.hashtags == ["Matcha", "freshstart", "CareerChange"])
    }

    @Test func zeroHashtagsMeansNone() {
        let r = PostCopyWriter.normalize(generated(tags: ["a", "b"]), platform: .general, hashtagCount: 0, fallbackTitle: "T")
        #expect(r.hashtags.isEmpty)
        #expect(r.postText == "Short caption.")
    }

    @Test func longCaptionsAreCutAtAWordToFitThePlatform() {
        let long = String(repeating: "word ", count: 80)
        let r = PostCopyWriter.normalize(generated(tags: [], caption: long), platform: .youtube, hashtagCount: 0, fallbackTitle: "T")
        #expect(r.caption.count <= CopyPlatform.youtube.maxCaptionLength + 1)   // plus the ellipsis
        #expect(r.caption.hasSuffix("…"))
        #expect(!r.caption.dropLast().hasSuffix(" "))
    }

    @Test func blankOutputFallsBackToTheClipTitle() {
        let r = PostCopyWriter.normalize(generated(tags: [], caption: "  ", headline: ""), platform: .general, hashtagCount: 5, fallbackTitle: "Big moment")
        #expect(r.headline == "Big moment")
        #expect(r.caption == "Big moment")
    }

    @Test func postTextListsCaptionThenHashtags() {
        let copy = PostCopy(headline: "H", caption: "Cap", hashtags: ["a", "b"])
        #expect(copy.postText == "Cap\n\n#a #b")
    }

    @Test func clipTextComesFromWordsInsideTheRange() {
        let words = [("before", 0.0, 1.0), ("inside", 5.0, 6.0), ("also", 6.0, 7.0), ("after", 20.0, 21.0)]
            .map { TranscriptWord(text: $0.0, start: $0.1, end: $0.2) }
        let t = Transcript(sourceFileName: "v", locale: "en", duration: 30,
                           segments: [TranscriptSegment(text: "", start: 0, end: 21, words: words)])
        #expect(t.text(from: 4, to: 10) == "inside also")
    }

    @Test func suggestionsSavedBeforeCopyExistedStillLoad() throws {
        let old = #"{"sourceFileName":"v.mov","generatedAt":"2026-10-09T10:00:00Z","candidates":[{"id":"7A5C5E5A-0000-4000-8000-000000000001","start":1,"end":31,"title":"T","reason":"R","score":80,"openingLine":"Hi"}]}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let s = try decoder.decode(ClipSuggestions.self, from: old.data(using: .utf8)!)
        #expect(s.candidates[0].copy == nil)
    }

    @Test func writeCopyStepRoundTrips() throws {
        let action = StepAction.writeCopy(platform: .tiktok, hashtagCount: 3)
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(StepAction.self, from: data) == action)
    }
}
