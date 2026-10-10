import Foundation
import Testing
@testable import Canopy

@MainActor
struct WorkflowEditTests {
    private func workflow(_ actions: [StepAction]) -> Workflow {
        Workflow(name: "Flow", steps: actions.map { WorkflowStep(action: $0) })
    }

    private func edit(_ edits: [DraftEdit], _ request: String, on w: Workflow) -> WorkflowDraftResult {
        WorkflowEditBuilder.apply(WorkflowEditDraft(edits: edits), to: w, request: request)
    }

    private func e(_ action: DraftEditAction, _ step: DraftStepKind,
                   _ placement: DraftPlacement = .automatic, relativeTo: DraftStepKind? = nil) -> DraftEdit {
        DraftEdit(action: action, step: step, placement: placement, relativeTo: relativeTo)
    }

    private let sync = StepAction.sync(destination: .global, verify: false)
    private let proxies = StepAction.convert(preset: .fast, deleteOriginal: false, maxParallelJobs: 2, convertInPlace: false)

    @Test func addedStepLandsInNaturalRunOrder() {
        let w = workflow([sync, proxies])
        let r = edit([e(.add, .notify)], "email me when it's done", on: w)
        #expect(r.workflow.steps.map(\.kind) == [.sync, .convert, .notify])
    }

    @Test func addRespectsExplicitPlacement() {
        let w = workflow([sync, proxies])
        let r = edit([e(.add, .rename, .after, relativeTo: .offload)], "rename the files after the offload", on: w)
        #expect(r.workflow.steps.map(\.kind) == [.sync, .rename, .convert])
    }

    @Test func addIsDroppedWhenRequestNeverMentionsIt() {
        let w = workflow([sync])
        let r = edit([e(.add, .formatDrive)], "make it faster", on: w)
        #expect(r.workflow.steps.map(\.kind) == [.sync])
    }

    @Test func removeDeletesOnlyTheNamedKind() {
        let w = workflow([sync, proxies, .wait(minutes: 5)])
        let r = edit([e(.remove, .makeProxies)], "remove the proxies", on: w)
        #expect(r.workflow.steps.map(\.kind) == [.sync, .wait])
    }

    @Test func removeIsIgnoredWhenRequestDoesNotRefer() {
        let w = workflow([sync, proxies])
        let r = edit([e(.remove, .makeProxies)], "email me at the end", on: w)
        #expect(r.workflow.steps.count == 2)
    }

    @Test func moveReordersExistingStep() {
        let w = workflow([sync, proxies])
        let r = edit([e(.move, .makeProxies, .before, relativeTo: .offload)], "do the proxies before the offload", on: w)
        #expect(r.workflow.steps.map(\.kind) == [.convert, .sync])
    }

    @Test func updateChangesWaitLengthFromTheRequestText() {
        let w = workflow([sync, .wait(minutes: 60)])
        let r = edit([e(.update, .wait)], "make the wait 30 minutes", on: w)
        guard case .wait(let minutes) = r.workflow.steps[1].action else { Issue.record("not wait"); return }
        #expect(minutes == 30)
    }

    @Test func scheduleIsReadFromTheRequestWithoutAnyModelEdit() {
        let w = workflow([sync])
        let r = edit([], "run it every night at 2am", on: w)
        #expect(r.workflow.triggers.count == 1)
        #expect(r.workflow.triggers[0].hour == 2)
        #expect(r.workflow.steps.count == 1)
    }

    @Test func existingDailyTriggerIsUpdatedNotDuplicated() {
        var w = workflow([sync])
        var t = ScheduleSettings(); t.mode = .daily; t.isEnabled = true; t.hour = 6
        w.triggers = [t]
        let r = edit([], "run every morning at 7am", on: w)
        #expect(r.workflow.triggers.count == 1)
        #expect(r.workflow.triggers[0].hour == 7)
    }

    @Test func scheduleCanBeRemoved() {
        var w = workflow([sync])
        var t = ScheduleSettings(); t.mode = .daily; t.isEnabled = true
        w.triggers = [t]
        let r = edit([], "remove the schedule", on: w)
        #expect(r.workflow.triggers.isEmpty)
    }

    @Test func addedCleanupAsksForConfirmation() {
        let w = workflow([sync])
        let r = edit([e(.add, .cleanup)], "delete files older than 14 days", on: w)
        #expect(r.workflow.steps.last?.requiresConfirmation == true)
        guard case .cleanup(let days)? = r.workflow.steps.last?.action else { Issue.record("not cleanup"); return }
        #expect(days == 14)
    }
}
