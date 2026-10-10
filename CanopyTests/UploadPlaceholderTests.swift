import Foundation
import Testing
@testable import Canopy

@MainActor
struct UploadPlaceholderTests {
    @Test func uploadStepSavesAndLoadsAndIsFlaggedComingSoon() throws {
        let data = try JSONEncoder().encode(StepAction.upload)
        #expect(try JSONDecoder().decode(StepAction.self, from: data) == .upload)
        #expect(StepKind.upload.isComingSoon)
        #expect(StepKind.allCases.filter(\.isComingSoon) == [.upload])
        #expect(StepAction.upload.summary.contains("Coming soon"))
        #expect(StepKind.upload.subtitle.hasPrefix("Coming soon"))
    }

    @Test func aWorkflowWithAnUploadStepSurvivesARoundTrip() throws {
        let workflow = Workflow(name: "Shorts", steps: [
            WorkflowStep(action: .findClips(maxClips: 3, minSeconds: 20, maxSeconds: 60)),
            WorkflowStep(action: .upload),
        ])
        let copy = try JSONDecoder().decode(Workflow.self, from: JSONEncoder().encode(workflow))
        #expect(copy.steps.map(\.kind) == [.findClips, .upload])
    }

    @Test func uploadDoesNotNeedTheSharedDestinationMounted() {
        #expect(!Workflow(name: "x", steps: [WorkflowStep(action: .upload)]).needsDestinationMount)
    }

    @Test func builderSaysUploadingIsComingSoonInsteadOfAddingIt() {
        let r = WorkflowDraftBuilder.build(
            from: WorkflowDraft(name: "Shorts", steps: [.offload, .findClips]),
            request: "offload, find the best moments and upload them to YouTube"
        )
        #expect(r.workflow.steps.map(\.kind) == [.sync, .findClips])
        #expect(r.notes.contains { $0.contains("Uploading is coming soon") })
    }
}
