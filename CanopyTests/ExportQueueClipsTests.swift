import Foundation
import AVFoundation
import Testing
@testable import Canopy

@MainActor
struct ExportQueueClipsTests {
    private func node(_ name: String = "A001.mov") -> FileNode {
        FileNode(id: "/v/\(name)", name: name, url: URL(fileURLWithPath: "/v/\(name)"), ftpPath: nil,
                 isDirectory: false, size: 1, modified: Date(), children: nil)
    }
    private func device() -> DeviceSource { .localFolder(LocalFolder(name: "Shoot", path: "/v")) }
    private func range(_ a: Double, _ b: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600), end: CMTime(seconds: b, preferredTimescale: 600))
    }

    @Test func differentRangesOfOneVideoAreAllQueued() {
        let m = ExportQueueManager()
        let d = device(), n = node()
        m.add(node: n, device: d, trimRange: range(0, 20), label: "One")
        m.add(node: n, device: d, trimRange: range(30, 55), label: "Two")
        #expect(m.items.count == 2)
        #expect(m.items.map(\.label) == ["One", "Two"])
    }

    @Test func requeueingTheSameClipIsANoOp() {
        let m = ExportQueueManager()
        let d = device(), n = node()
        m.add(node: n, device: d, trimRange: range(0, 20), label: "One")
        m.add(node: n, device: d, trimRange: range(0, 20), label: "One")
        m.add(node: n, device: d)                      // whole file is a different item
        m.add(node: n, device: d)
        #expect(m.items.count == 2)
    }

    @Test func savedSuggestionsAreQueuedAsLabelledTrims() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("A001.mov")
        try Data().write(to: video)
        func clip(_ s: Double, _ e: Double, _ title: String, _ score: Int) -> ClipCandidate {
            ClipCandidate(start: s, end: e, title: title, reason: "", score: score, openingLine: "")
        }
        try ClipSuggestions(sourceFileName: "A001.mov", generatedAt: Date(), candidates: [
            clip(60, 90, "Later", 90), clip(10, 40, "Earlier", 55), clip(100, 120, "Weak", 20),
        ]).write(for: video)

        let m = ExportQueueManager()
        let shoot = device()
        #expect(m.addSuggestedClips(for: video, device: shoot, minScore: 50) == 2)
        #expect(m.items.map(\.label) == ["Earlier", "Later"])          // chronological, weak one skipped
        #expect(m.items.allSatisfy { $0.isTrimmed && $0.node.url == video })
        #expect(abs((m.items[0].trimRange?.start.seconds ?? 0) - 10) < 0.001)
        // Running it again adds nothing new.
        #expect(m.addSuggestedClips(for: video, device: shoot, minScore: 50) == 0)
        #expect(m.items.count == 2)
    }

    @Test func videoWithoutSuggestionsReportsNil() {
        let m = ExportQueueManager()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        #expect(m.addSuggestedClips(for: missing, device: device()) == nil)
    }
}
