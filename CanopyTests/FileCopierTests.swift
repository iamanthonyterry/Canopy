import Foundation
import Testing
@testable import Canopy

@MainActor
struct FileCopierTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func copiesAndLeavesNoPartialFile() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.mov"); try Data("hello world".utf8).write(to: src)
        let dst = dir.appendingPathComponent("out/a.mov")
        #expect(await FileCopier.copy(from: src, to: dst, verify: true) == .copied)
        #expect(try Data(contentsOf: dst) == Data("hello world".utf8))
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathExtension("partial").path))
    }

    @Test func identicalFileIsSkipped() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.mov"); try Data("same".utf8).write(to: src)
        let dst = dir.appendingPathComponent("b.mov")
        _ = await FileCopier.copy(from: src, to: dst, verify: true)
        #expect(await FileCopier.copy(from: src, to: dst, verify: true) == .skipped)
        #expect(await FileCopier.copy(from: src, to: dst, verify: false) == .skipped)
    }

    @Test func sameSizeButDifferentContentIsOverwrittenWhenVerifying() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.mov"); try Data("AAAA".utf8).write(to: src)
        let dst = dir.appendingPathComponent("b.mov"); try Data("BBBB".utf8).write(to: dst)
        #expect(await FileCopier.copy(from: src, to: dst, verify: true) == .copied)
        #expect(try Data(contentsOf: dst) == Data("AAAA".utf8))
    }

    @Test func missingSourceFailsCleanly() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let result = await FileCopier.copy(from: dir.appendingPathComponent("nope.mov"), to: dir.appendingPathComponent("x.mov"), verify: true)
        if case .failed = result {} else { Issue.record("expected failure, got \(result)") }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.mov.partial").path))
    }

    @Test func sidecarsAreOnlyThoseThatExist() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("A001.mov")
        try Data().write(to: dir.appendingPathComponent("A001.transcript.json"))
        try Data().write(to: dir.appendingPathComponent("A001.clips.json"))
        #expect(FileCopier.sidecars(of: video).map(\.lastPathComponent) == ["A001.transcript.json", "A001.clips.json"])
    }

    @Test func copyToStepRoundTrips() throws {
        let id = UUID()
        for destination in [CopyDestination.global, .cloudStore(id: id, path: "Backups"), .localFolder(id: id, path: "Shoot 1")] {
            let action = StepAction.copyTo(destination: destination, verify: false, includeSidecars: true)
            let data = try JSONEncoder().encode(action)
            #expect(try JSONDecoder().decode(StepAction.self, from: data) == action)
        }
    }
}
