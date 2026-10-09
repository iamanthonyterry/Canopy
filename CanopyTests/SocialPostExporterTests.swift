import Foundation
import Testing
@testable import Canopy

struct SocialPostExporterTests {
    @Test func fileNamesAreSafeAndDescribeTheFormat() {
        #expect(SocialPostExporter.fileName(base: "A001", index: 2, title: "Big Idea!", format: .vertical) == "A001_clip02_Big-Idea_9x16.mp4")
        #expect(SocialPostExporter.fileName(base: "A001", index: 1, title: "???", format: .square) == "A001_clip01_clip_1x1.mp4")
    }
}
