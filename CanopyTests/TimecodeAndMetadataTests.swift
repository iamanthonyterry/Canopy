import Foundation
import Testing
@testable import Canopy

@MainActor
struct TimecodeAndMetadataTests {
    private func makeMetadata() -> ClipMetadata {
        ClipMetadata(clipName: "a.mov", deviceID: "d", deviceLabel: "Deck", ftpPath: nil, localURL: nil,
                     isVideo: true, isImage: false, size: 1, modified: Date(), updatedAt: Date())
    }

    @Test func timecodeFormatsFrames() {
        #expect(Timecode.string(seconds: 0, fps: 24) == "00:00:00:00")
        #expect(Timecode.string(seconds: 1.5, fps: 24) == "00:00:01:12")
        #expect(Timecode.string(seconds: 3661, fps: 25) == "01:01:01:00")
    }

    @Test func timecodeRejectsBadInput() {
        #expect(Timecode.string(seconds: -1, fps: 24) == "00:00:00:00")
        #expect(Timecode.string(seconds: 5, fps: 0) == "00:00:00:00")
    }

    @Test func oldMetadataPayloadDecodesWithoutMarkers() throws {
        var old = makeMetadata()
        old.starred = true
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "markers")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ClipMetadata.self, from: data)
        #expect(decoded.markers.isEmpty)
        #expect(decoded.starred)
    }

    @Test func markersKeepEntryNonEmpty() {
        var m = makeMetadata()
        #expect(m.isEmpty)
        m.markers = [ClipMarker(time: 2, label: "x")]
        #expect(!m.isEmpty)
    }
}

@MainActor
struct CommandPaletteSearchTests {
    @Test func rankingPrefixThenSubstringThenSubsequence() {
        #expect(CommandPaletteSearch.score(query: "str", title: "Starred") == 2)
        #expect(CommandPaletteSearch.score(query: "sta", title: "Starred") == 0)
        #expect(CommandPaletteSearch.score(query: "red", title: "Starred") == 1)
        #expect(CommandPaletteSearch.score(query: "srd", title: "Starred") == 2)
        #expect(CommandPaletteSearch.score(query: "", title: "Anything") == 0)
        #expect(CommandPaletteSearch.score(query: "zzz", title: "Starred") == nil)
    }
}
