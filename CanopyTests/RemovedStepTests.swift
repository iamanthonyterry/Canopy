import Foundation
import Testing
@testable import Canopy

@MainActor
struct RemovedStepTests {
    /// The Export Queue, and with it the Queue Clips step, was removed. A workflow saved with one still loads,
    /// without that step and with every other step in order.
    @Test func workflowSavedWithQueueClipsLoadsWithoutIt() throws {
        let original = Workflow(name: "Shorts", steps: [
            WorkflowStep(action: .wait(minutes: 1)),
            WorkflowStep(action: .wait(minutes: 2)),
        ])
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var steps = try #require(json["steps"] as? [[String: Any]])
        steps.insert(["id": UUID().uuidString, "action": ["queueClips": ["minScore": 50]]], at: 1)
        json["steps"] = steps

        let loaded = try JSONDecoder().decode(Workflow.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.name == "Shorts")
        #expect(loaded.steps.map(\.id) == original.steps.map(\.id))
        #expect(loaded.steps.map(\.kind) == [.wait, .wait])
    }

    @Test func aStepThatIsBrokenForAnotherReasonStillFails() throws {
        let json = #"{"name":"Bad","steps":[{"action":{"wait":"not an object"}}]}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Workflow.self, from: Data(json.utf8)) }
    }
}
