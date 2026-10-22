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
