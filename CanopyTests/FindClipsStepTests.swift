import Foundation
import Testing
@testable import Canopy

@MainActor
struct FindClipsStepTests {
    @Test func exportSettingsRoundTrip() throws {
        let action = StepAction.findClips(maxClips: 3, minSeconds: 15, maxSeconds: 45, exportFormat: .square, captions: false)
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(StepAction.self, from: data) == action)
    }

    @Test func stepSavedBeforeExportExistedStillLoads() throws {
        let json = #"{"findClips":{"maxClips":4,"minSeconds":20,"maxSeconds":60}}"#.data(using: .utf8)!
        let action = try JSONDecoder().decode(StepAction.self, from: json)
        #expect(action == .findClips(maxClips: 4, minSeconds: 20, maxSeconds: 60, exportFormat: nil, captions: true))
    }
}

@MainActor
struct ClipFocusTests {
    @Test func focusRoundTripsWithTheStep() throws {
        var focus = ClipFocus(notes: "  about hope ")
        focus.set(.music, on: true)
        focus.set(.quotes, on: true)
        #expect(focus.kinds == [.quotes, .music])               // kept in a fixed order
        let action = StepAction.findClips(maxClips: 3, minSeconds: 15, maxSeconds: 45, focus: focus)
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(StepAction.self, from: data) == action)
        #expect(action.summary.contains("Speaker quotes, Music & songs · “about hope”"))
    }

    @Test func emptyFocusKeepsTheDefaultTaste() {
        #expect(ClipFocus(notes: "   ").isEmpty)
        #expect(ClipFocus().guidance == nil)
        #expect(ClipFinder.instructions(for: ClipFocus()).contains("Prefer personal stories"))
    }

    @Test func focusReplacesTheDefaultTasteInTheInstructions() {
        var focus = ClipFocus(notes: "the pastor's main point")
        focus.set(.quotes, on: true)
        let text = ClipFinder.instructions(for: focus)
        #expect(text.contains(ClipKind.quotes.guidance))
        #expect(text.contains("the pastor's main point"))
        #expect(!text.contains(ClipKind.music.guidance))
        #expect(!text.contains("Prefer personal stories"))
    }

    @Test func suggestionsRememberWhatTheyWereFoundFor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("A001.mov")
        let focus = ClipFocus(kinds: [.music])
        try ClipSuggestions(sourceFileName: "A001.mov", generatedAt: Date(timeIntervalSince1970: 0), candidates: [], focus: focus)
            .write(for: video)
        #expect(ClipSuggestions.load(for: video)?.focus == focus)
        // A file saved before a focus could be set still loads.
        try #"{"sourceFileName":"A001.mov","generatedAt":"1970-01-01T00:00:00Z","candidates":[]}"#
            .write(to: ClipSuggestions.sidecarURL(for: video), atomically: true, encoding: .utf8)
        let old = try #require(ClipSuggestions.load(for: video))
        #expect(old.focus == nil)
    }
}
