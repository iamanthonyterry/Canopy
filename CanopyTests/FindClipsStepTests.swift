import Foundation
import Testing
@testable import Canopy

@MainActor
struct FindClipsStepTests {
    @Test func exportPostsSettingsRoundTrip() throws {
        let action = StepAction.exportPosts(format: .square, captions: false)
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(StepAction.self, from: data) == action)
    }

    @Test func findClipsThatRenderedPostsItselfBecomesTwoSteps() throws {
        let json = #"""
        {"name":"Clips","steps":[
          {"action":{"findClips":{"maxClips":3,"minSeconds":15,"maxSeconds":45,"exportFormat":"square","captions":false}}},
          {"action":{"notify":{"header":"Done","message":"","recipients":[]}}}
        ]}
        """#.data(using: .utf8)!
        let workflow = try JSONDecoder().decode(Workflow.self, from: json)
        #expect(workflow.steps.map(\.kind) == [.findClips, .exportPosts, .notify])
        #expect(workflow.steps[0].action == .findClips(maxClips: 3, minSeconds: 15, maxSeconds: 45))
        #expect(workflow.steps[1].action == .exportPosts(format: .square, captions: false))
    }

    @Test func findClipsWithoutExportStaysOneStep() throws {
        let json = #"{"name":"Clips","steps":[{"action":{"findClips":{"maxClips":4}}}]}"#.data(using: .utf8)!
        let workflow = try JSONDecoder().decode(Workflow.self, from: json)
        #expect(workflow.steps.map(\.kind) == [.findClips])
    }

    @Test func startRecordingThatStoppedItselfBecomesThreeSteps() throws {
        let deck = UUID()
        // Encode a current workflow, then put the old `stopAfterMinutes` back
        // the way a workflow saved before this change would have it.
        let current = Workflow(name: "Record", steps: [
            WorkflowStep(action: .controlDeck(command: .start), decks: .only([deck]))
        ])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        var steps = try #require(object["steps"] as? [[String: Any]])
        var action = try #require(steps[0]["action"] as? [String: Any])
        var control = try #require(action["controlDeck"] as? [String: Any])
        control["stopAfterMinutes"] = 45
        action["controlDeck"] = control
        steps[0]["action"] = action
        object["steps"] = steps

        let data = try JSONSerialization.data(withJSONObject: object)
        let workflow = try JSONDecoder().decode(Workflow.self, from: data)
        #expect(workflow.steps.map(\.action) == [.controlDeck(command: .start), .wait(minutes: 45), .controlDeck(command: .stop)])
        #expect(workflow.steps[2].decks == .only([deck]))
    }

    @Test func startRecordingSuggestsWaitThenStop() {
        let labels = StepAction.controlDeck(command: .start).suggestedFollowUps.map(\.shortLabel)
        #expect(labels == ["Wait", "Stop Recording"])
        #expect(StepAction.controlDeck(command: .stop).suggestedFollowUps.isEmpty)
    }

    @Test func nextStepsAreSuggestedNotAdded() {
        #expect(StepKind.findClips.suggestedFollowUps.contains(.exportPosts))
        #expect(StepKind.transcribe.suggestedFollowUps == [.findClips])
        #expect(StepKind.wait.suggestedFollowUps.isEmpty)
    }

    @Test func stepSavedBeforeExportExistedStillLoads() throws {
        let json = #"{"findClips":{"maxClips":4,"minSeconds":20,"maxSeconds":60}}"#.data(using: .utf8)!
        let action = try JSONDecoder().decode(StepAction.self, from: json)
        #expect(action == .findClips(maxClips: 4, minSeconds: 20, maxSeconds: 60, focus: ClipFocus()))
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
