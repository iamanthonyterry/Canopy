import Foundation
import Testing
@testable import Canopy

@MainActor
struct TranscriptTests {
    private let sample = Transcript(
        sourceFileName: "A001.mov", locale: "en-US", duration: 12,
        segments: [
            TranscriptSegment(text: "Hello there.", start: 0.5, end: 1.75,
                              words: [TranscriptWord(text: "Hello", start: 0.5, end: 1.0),
                                      TranscriptWord(text: "there.", start: 1.1, end: 1.75)]),
            TranscriptSegment(text: "Second line.", start: 3661.2, end: 3662.0)
        ]
    )

    @Test func srtFormatting() {
        let lines = sample.srt.components(separatedBy: "\n")
        #expect(lines[0] == "1")
        #expect(lines[1] == "00:00:00,500 --> 00:00:01,750")
        #expect(lines[2] == "Hello there.")
        #expect(sample.srt.contains("01:01:01,200 --> 01:01:02,000"))
    }

    @Test func sidecarRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("A001.mov")

        #expect(Transcript.load(for: video) == nil)
        try sample.write(for: video)
        #expect(Transcript.sidecarURL(for: video).lastPathComponent == "A001.transcript.json")
        #expect(Transcript.load(for: video)?.fullText == "Hello there. Second line.")
    }

    @Test func transcribeStepCodableRoundTrip() throws {
        let action = StepAction.transcribe(locale: "es-ES", writeSRT: false, skipExisting: true)
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(StepAction.self, from: data) == action)
        #expect(action.kind == .transcribe)
    }
}
