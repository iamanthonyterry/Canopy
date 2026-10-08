import Foundation
import Testing
@testable import Canopy

@MainActor
struct ClipBrowsingTests {
    private func node(_ name: String, dir: Bool = false, day: Int = 1, hour: Int = 12) -> FileNode {
        var c = DateComponents(year: 2026, month: 3, day: day, hour: hour)
        c.calendar = Calendar(identifier: .gregorian)
        return FileNode(id: name, name: name, url: nil, ftpPath: nil, isDirectory: dir,
                        size: 1, modified: c.date!, children: nil)
    }

    @Test func durationFormatting() {
        #expect(ClipInfoFormat.duration(5) == "0:05")
        #expect(ClipInfoFormat.duration(75.4) == "1:15")
        #expect(ClipInfoFormat.duration(3725) == "1:02:05")
        #expect(ClipInfoFormat.duration(.nan) == "0:00")
    }

    @Test func frameRateAndCodecLabels() {
        #expect(ClipInfoFormat.frameRate(24) == "24p")
        #expect(ClipInfoFormat.frameRate(23.976) == "23.98p")
        #expect(ClipInfoFormat.codecName(fourCC: "apch") == "ProRes 422 HQ")
        #expect(ClipInfoFormat.codecName(fourCC: "avc1") == "H.264")
        #expect(ClipInfoFormat.codecName(fourCC: "zzzz") == "zzzz")
    }

    @Test func keywordParsing() {
        #expect(ClipMetadataStore.parseKeywords(" b-roll, Hero ,hero,\n interview,, ") == ["b-roll", "Hero", "interview"])
        #expect(ClipMetadataStore.parseKeywords("").isEmpty)
    }

    @Test func labelOrKeywordsKeepEntryNonEmpty() {
        var m = ClipMetadata(clipName: "a", deviceID: "d", deviceLabel: "D", ftpPath: nil, localURL: nil,
                             isVideo: true, isImage: false, size: 1, modified: Date(), updatedAt: Date())
        m.label = .green
        #expect(!m.isEmpty)
        m.label = nil
        m.keywords = ["x"]
        #expect(!m.isEmpty)
    }

    @Test func groupingPutsFoldersFirstThenNewestDay() {
        let nodes = [node("a.mov", day: 1), node("b.mov", day: 3), node("c.mov", day: 3, hour: 9),
                     node("Folder", dir: true)]
        let groups = ClipGrouping.groups(for: nodes, calendar: Calendar(identifier: .gregorian))
        #expect(groups.count == 3)
        #expect(groups[0].title == "Folders")
        #expect(groups[1].nodes.count == 2)   // day 3 before day 1
        #expect(groups[2].nodes.map(\.name) == ["a.mov"])
    }
}
