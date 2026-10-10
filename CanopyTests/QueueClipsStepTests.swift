import Foundation
import Testing
@testable import Canopy

@MainActor
struct QueueClipsStepTests {
    @Test func stepRoundTripsAndOldWorkflowsAreUnaffected() throws {
        let action = StepAction.queueClips(minScore: 70)
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(StepAction.self, from: data) == action)
        #expect(action.kind == .queueClips)
        let bare = try JSONDecoder().decode(StepAction.self, from: #"{"queueClips":{}}"#.data(using: .utf8)!)
        #expect(bare == .queueClips(minScore: 0))
    }
}
