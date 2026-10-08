import Foundation
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
