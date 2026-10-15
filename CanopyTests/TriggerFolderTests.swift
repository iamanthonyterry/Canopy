import Foundation
import Testing
@testable import Canopy

@MainActor
struct TriggerFolderTests {
    private func roundTrip(_ action: StepAction) throws -> StepAction {
        let data = try JSONEncoder().encode(action)
        return try JSONDecoder().decode(StepAction.self, from: data)
    }

    @Test func aTriggerDefaultsToTheWorkflowsOwnTargets() {
        #expect(StepAction.defaultAction(for: .triggerWorkflow)
                == .triggerWorkflow(workflowID: nil, waitForCompletion: false, folder: .ownTargets))
    }

    @Test func aCreatedFolderChoiceSurvivesSaving() throws {
        let folderStep = UUID(), workflow = UUID(), deck = UUID()
        let whole = StepAction.triggerWorkflow(
            workflowID: workflow, waitForCompletion: true,
            folder: .createdFolder(stepID: folderStep, deviceID: nil))
        let subfolder = StepAction.triggerWorkflow(
            workflowID: workflow, waitForCompletion: false,
            folder: .createdFolder(stepID: folderStep, deviceID: deck))
        #expect(try roundTrip(whole) == whole)
        #expect(try roundTrip(subfolder) == subfolder)
    }

    @Test func aTriggerSavedBeforeFolderChoiceStillLoads() throws {
        let workflow = UUID()
        let json = """
        {"triggerWorkflow":{"workflowID":"\(workflow.uuidString)","waitForCompletion":true}}
        """
        let action = try JSONDecoder().decode(StepAction.self, from: Data(json.utf8))
        #expect(action == .triggerWorkflow(workflowID: workflow, waitForCompletion: true, folder: .ownTargets))
    }

    @Test func theSummaryNamesTheFolder() {
        let id = UUID()
        let whole = StepAction.triggerWorkflow(
            workflowID: id, waitForCompletion: false, folder: .createdFolder(stepID: UUID(), deviceID: nil))
        let sub = StepAction.triggerWorkflow(
            workflowID: id, waitForCompletion: false, folder: .createdFolder(stepID: UUID(), deviceID: UUID()))
        #expect(whole.summary.contains("created folder"))
        #expect(sub.summary.contains("subfolder"))
    }
}
