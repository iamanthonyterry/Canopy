import Foundation
import CryptoKit
import Testing
@testable import Canopy

@MainActor
struct OffloadTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func sha256MatchesKnownVector() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("abc.txt")
        try "abc".write(to: file, atomically: true, encoding: .utf8)
        let hash = await ChecksumService.sha256(ofFileAt: file)
        #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func sha256OfMissingFileIsNil() async {
        let hash = await ChecksumService.sha256(ofFileAt: URL(fileURLWithPath: "/nonexistent/x.mov"))
        #expect(hash == nil)
    }

    @Test func sha256OfMultiChunkFileMatchesOneShotHash() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.bin")
        // Larger than two read chunks, with a ragged tail.
        let data = Data((0 ..< 9 * 1024 * 1024 + 123).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: file)
        let hash = await ChecksumService.sha256(ofFileAt: file)
        #expect(hash == ChecksumService.hex(SHA256.hash(data: data)))
    }

    @Test func limiterDropsToOneSlotUnderMemoryPressure() async {
        let limiter = ConversionSlotLimiter()
        await limiter.setLimit(3)
        await limiter.setMemoryPressure(true)
        await limiter.acquire()

        let second = Task { await limiter.acquire(); return true }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await limiter.waitingCount == 1)

        // Pressure clearing brings the configured limit back.
        await limiter.setMemoryPressure(false)
        #expect(await second.value)
    }

    @Test func manifestReplacesExistingEntryAndKeepsOthers() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        ChecksumService.record(hash: "aaa", fileName: "A.mov", in: dir)
        ChecksumService.record(hash: "bbb", fileName: "B.mov", in: dir)
        ChecksumService.record(hash: "ccc", fileName: "A.mov", in: dir)
        let text = try String(contentsOf: dir.appendingPathComponent(ChecksumService.manifestName), encoding: .utf8)
        #expect(text == "bbb  B.mov\nccc  A.mov\n")
    }

    @Test func syncStepRoundTripsVerifyFlag() throws {
        let step = StepAction.sync(destination: .global, verify: true)
        let decoded = try JSONDecoder().decode(StepAction.self, from: JSONEncoder().encode(step))
        #expect(decoded == step)
    }

    @Test func oldSyncPayloadWithoutVerifyDecodesAsOff() throws {
        let json = #"{"sync":{"destination":{"global":{}}}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(StepAction.self, from: json)
        #expect(decoded == .sync(destination: .global, verify: false))
    }
}

@MainActor
struct NLEExportTests {
    private func clip(_ name: String, seconds: Double = 10, fps: Double = 24) -> NLEClip {
        NLEClip(name: name, url: URL(fileURLWithPath: "/Volumes/Shoot Drive/\(name).mov"),
                info: ClipInfo(duration: seconds, width: 1920, height: 1080, fps: fps, codec: "ProRes 422", hasAudio: true),
                markers: [ClipMarker(time: 2.5, label: "Best <take> & more")],
                keywords: ["interview"], note: "Hero shot", label: .green)
    }

    @Test func frameDurationsForBroadcastRates() {
        #expect(FrameTiming.frameDuration(fps: 23.976) == (1001, 24000))
        #expect(FrameTiming.frameDuration(fps: 29.97) == (1001, 30000))
        #expect(FrameTiming.frameDuration(fps: 25) == (1, 25))
        #expect(FrameTiming.rational(frames: 0, fps: 24) == "0s")
        #expect(FrameTiming.rational(seconds: 1, fps: 23.976) == "24024/24000s")
    }

    @Test func timecodeFromFrames() {
        #expect(FrameTiming.timecode(frames: 3600 * 24, fps: 24) == "01:00:00:00")
        #expect(FrameTiming.timecode(frames: 3600 * 24 + 25, fps: 24) == "01:00:01:01")
    }

    @Test func fcpxmlIsWellFormedAndCarriesMetadata() {
        let xml = FCPXMLBuilder.xml(projectName: "Selects & Co", clips: [clip("A001"), clip("A002", seconds: 5)])
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse())
        #expect(xml.contains("<fcpxml version=\"1.9\">"))
        #expect(xml.contains("file:///Volumes/Shoot%20Drive/A001.mov"))
        #expect(xml.contains("Best &lt;take&gt; &amp; more"))
        #expect(xml.contains("<keyword"))
        #expect(xml.contains("Selects &amp; Co"))
        // Second clip starts where the first ends: 01:00:00:00 + 10s at 24fps.
        #expect(xml.contains("offset=\"86640/24s\""))
    }

    @Test func emptyClipListProducesNothing() {
        #expect(FCPXMLBuilder.xml(projectName: "x", clips: []).isEmpty)
        #expect(EDLBuilder.edl(title: "x", clips: []).isEmpty)
    }

    @Test func edlHasEventsAndMarkers() {
        let edl = EDLBuilder.edl(title: "Selects", clips: [clip("A001"), clip("A002")])
        #expect(edl.hasPrefix("TITLE: Selects\nFCM: NON-DROP FRAME"))
        #expect(edl.contains("001  AX"))
        #expect(edl.contains("002  AX"))
        #expect(edl.contains("01:00:00:00 01:00:10:00"))
        #expect(edl.contains("* FROM CLIP NAME: A002"))
        #expect(edl.contains("* LOC: 01:00:02:12 GREEN Best <take> & more"))
    }
}

@MainActor
struct OffloadReportTests {
    @Test func reportEscapesAndSummarises() {
        let records = [
            RunFileRecord(fileName: "A<1>.mov", deviceName: "Deck & A", sizeBytes: 2_000_000_000, succeeded: true,
                          errorMessage: nil, verification: "verified", sha256: String(repeating: "ab", count: 32), folderPath: "/x"),
            RunFileRecord(fileName: "B.mov", deviceName: "Deck A", sizeBytes: 0, succeeded: false,
                          errorMessage: "Checksum mismatch", verification: "mismatch", sha256: nil, folderPath: "/x")
        ]
        let run = WorkflowRun(workflowName: "Day 1 <wrap>", startedAt: Date(), finishedAt: Date(), processed: 1, errors: 1,
                              decksProcessed: ["Deck A"], log: [], fileRecords: records)
        let html = OffloadReportBuilder.html(for: run)
        #expect(html.contains("Day 1 &lt;wrap&gt;"))
        #expect(html.contains("A&lt;1&gt;.mov"))
        #expect(html.contains("Deck &amp; A"))
        #expect(html.contains("1/2"))              // verified of total
        #expect(html.contains("Checksum mismatch"))
    }

    @Test func oldRunsWithoutRecordsStillDecode() throws {
        let run = WorkflowRun(workflowName: "Old", startedAt: Date(), finishedAt: Date(), processed: 0, errors: 0,
                              decksProcessed: [], log: [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as! [String: Any]
        json.removeValue(forKey: "fileRecords")
        let decoded = try JSONDecoder().decode(WorkflowRun.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.fileRecords == nil)
        #expect(OffloadReportBuilder.html(for: decoded).contains("No per-file details"))
    }
}

@MainActor
struct RenameTokenTests {
    @Test func projectAndCameraTokensExpand() {
        let name = RenamePatternEngine.apply(
            pattern: "{project}_{cam}_{index}", originalName: "Clip0001", deviceName: "Stage Left",
            index: 3, projectName: "Spring/Campaign", cameraLabel: "A")
        #expect(name == "Spring-Campaign_A_003")
    }

    @Test func emptyProjectLeavesPatternUsable() {
        let name = RenamePatternEngine.apply(pattern: "{device}_{index}", originalName: "x", deviceName: "D", index: 1)
        #expect(name == "D_001")
    }
}
