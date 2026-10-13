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

// MARK: - Decks chosen on the steps

@MainActor
struct WorkflowDeckSelectionTests {
    private let offload = StepAction.sync(destination: .global, verify: false)

    private func roundTrip(_ workflow: Workflow) throws -> Workflow {
        try JSONDecoder().decode(Workflow.self, from: JSONEncoder().encode(workflow))
    }

    @Test func aStepsDecksSurviveSavingAndLoading() throws {
        let deck = UUID()
        let workflow = Workflow(name: "Offload", steps: [
            WorkflowStep(action: offload, decks: .only([deck])),
            WorkflowStep(action: .format, decks: .only([])),
        ], targets: [.localFolder(UUID())])
        let decoded = try roundTrip(workflow)
        #expect(decoded == workflow)
        #expect(decoded.usesDeck(deck))
        #expect(!decoded.usesDeck(UUID()))
    }

    @Test func oldWorkflowsMoveTheirDecksOntoTheDeckSteps() throws {
        let deck = UUID(), folder = UUID()
        let steps = try JSONEncoder().encode([
            WorkflowStep(action: offload), WorkflowStep(action: .rename(pattern: "{name}")),
        ])
        let targets = try JSONEncoder().encode([WorkflowTarget.hyperDeck(deck), .localFolder(folder)])
        // Saved by a version that chose decks for the whole workflow: no
        // per-step decks, and no marker saying they've been moved.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Workflow(name: "Old"))) as? [String: Any])
        object["decksInSteps"] = nil
        object["steps"] = (try JSONSerialization.jsonObject(with: steps) as? [[String: Any]])?.map { step in
            step.filter { $0.key != "decks" }
        }
        object["targets"] = try JSONSerialization.jsonObject(with: targets)
        let decoded = try JSONDecoder().decode(Workflow.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.steps[0].decks == .only([deck]))
        #expect(decoded.targets == [.localFolder(folder)])
        #expect(!decoded.legacyRunsOnAllLocalFolders)
    }

    @Test func oldAllDevicesWorkflowsKeepEveryDeckAndAskForTheFolders() throws {
        let json = #"{"name":"Old","steps":[{"action":{"format":{}}}],"targets":[]}"#
        let decoded = try JSONDecoder().decode(Workflow.self, from: Data(json.utf8))
        #expect(decoded.steps[0].decks == .all)
        #expect(decoded.legacyRunsOnAllLocalFolders)
    }

    @Test func runningOnOneDeckPointsEveryDeckStepAtIt() {
        let deck = UUID()
        let workflow = Workflow(name: "Offload", steps: [
            WorkflowStep(action: offload, decks: .only([UUID()])),
            WorkflowStep(action: .wait(minutes: 1)),
        ]).pointingDeckSteps(at: deck)
        #expect(workflow.steps[0].decks == .only([deck]))
        #expect(workflow.steps[1].decks == .only([]))
    }

    @Test func aNewDeckStepStartsWithNoDeckChosen() {
        #expect(WorkflowStep(action: .format).decks.isNone)
        #expect(!Workflow(name: "Erase", steps: [WorkflowStep(action: .format)]).selectsAnyDeck)
    }

    @Test func aWorkflowAsksForAFolderOnlyWhenItHasFilesToFindAndNowhereToLook() {
        let transcribe = WorkflowStep(action: .defaultAction(for: .transcribe))
        // Files to work on, no deck and no folder.
        #expect(Workflow(name: "A", steps: [transcribe]).choosesFolderAtRun)
        #expect(Workflow(name: "B", steps: [WorkflowStep(action: offload, decks: .only([])), transcribe]).choosesFolderAtRun)
        // A deck to pull from, or a folder to look in.
        #expect(!Workflow(name: "C", steps: [WorkflowStep(action: offload, decks: .all), transcribe]).choosesFolderAtRun)
        #expect(!Workflow(name: "D", steps: [transcribe], targets: [.localFolder(UUID())]).choosesFolderAtRun)
        // Nothing that touches files at all.
        #expect(!Workflow(name: "E", steps: [WorkflowStep(action: .wait(minutes: 1))]).choosesFolderAtRun)
    }

    @Test func aFolderPickedForOneRunIsRememberedByPath() throws {
        let target = WorkflowTarget.folder(path: "/Volumes/Media/Sunday", name: "Sunday")
        let decoded = try JSONDecoder().decode(WorkflowTarget.self, from: JSONEncoder().encode(target))
        #expect(decoded == target)
    }
}

// MARK: - Decks and folders from a plain-language request

@MainActor
struct WorkflowAssistantDeckTests {
    private let studioA = TriggerContext.Item(id: UUID(), name: "Studio A")
    private let studioB = TriggerContext.Item(id: UUID(), name: "Studio B")
    private let sunday = TriggerContext.Item(id: UUID(), name: "Sunday Services")
    private var context: TriggerContext { TriggerContext(decks: [studioA, studioB], folders: [sunday]) }

    private func build(_ kinds: [DraftStepKind], _ request: String, context: TriggerContext? = nil) -> WorkflowDraftResult {
        WorkflowDraftBuilder.build(from: WorkflowDraft(name: "Flow", steps: kinds), request: request, context: context ?? self.context)
    }

    private func edit(_ request: String, on workflow: Workflow, edits: [DraftEdit] = []) -> WorkflowDraftResult {
        WorkflowEditBuilder.apply(WorkflowEditDraft(edits: edits), to: workflow, request: request, context: context)
    }

    @Test func aNamedDeckIsChosenOnEveryDeckStep() {
        let r = build([.offload, .formatDrive], "offload from Studio B then erase the drive")
        #expect(r.workflow.steps.map(\.decks) == [.only([studioB.id]), .only([studioB.id])])
    }

    @Test func allDecksMeansEveryDeck() {
        let r = build([.offload], "offload all the decks every night at 2am")
        #expect(r.workflow.steps[0].decks == .all)
    }

    @Test func withSeveralDecksAndNoneNamedTheChoiceIsLeftOpen() {
        let r = build([.offload], "offload my clips")
        #expect(r.workflow.steps[0].decks.isNone)
        #expect(r.notes.contains { $0.contains("Choose which HyperDecks") })
    }

    @Test func theOnlyDeckIsUsedWithoutBeingNamed() {
        let r = build([.offload], "offload my clips", context: TriggerContext(decks: [studioA]))
        #expect(r.workflow.steps[0].decks == .only([studioA.id]))
    }

    @Test func theDeckATriggerWatchesIsTheDeckTheStepsUse() {
        let r = build([.offload], "when Studio A stops recording, offload")
        #expect(r.workflow.steps[0].decks == .only([studioA.id]))
    }

    @Test func aFolderToWorkInBecomesAFolderToProcess() {
        let r = build([.transcribe], "transcribe everything in Sunday Services")
        #expect(r.workflow.targets == [.localFolder(sunday.id)])
        #expect(!r.workflow.choosesFolderAtRun)
    }

    @Test func aFolderToCopyToIsNotProcessed() {
        let r = build([.offload, .copyTo], "offload from Studio A and copy to Sunday Services")
        #expect(r.workflow.targets.isEmpty)
    }

    @Test func namingADeckRepointsExistingDeckSteps() {
        let workflow = Workflow(name: "Flow", steps: [
            WorkflowStep(action: .sync(destination: .global, verify: false), decks: .only([studioA.id])),
            WorkflowStep(action: .format, decks: .only([studioA.id])),
        ])
        let all = edit("use Studio B instead", on: workflow)
        #expect(all.workflow.steps.map(\.decks) == [.only([studioB.id]), .only([studioB.id])])

        let one = edit("offload from every deck", on: workflow)
        #expect(one.workflow.steps.map(\.decks) == [.all, .only([studioA.id])])
    }

    @Test func aTriggerOnADeckLeavesTheStepsDecksAlone() {
        let workflow = Workflow(name: "Flow", steps: [
            WorkflowStep(action: .sync(destination: .global, verify: false), decks: .only([studioA.id])),
        ])
        let r = edit("start it when Studio B stops recording", on: workflow)
        #expect(r.workflow.steps[0].decks == .only([studioA.id]))
    }

    @Test func anAddedDeckStepGetsTheNamedDeck() {
        let workflow = Workflow(name: "Flow", steps: [WorkflowStep(action: .wait(minutes: 5))])
        let add = DraftEdit(action: .add, step: .offload, placement: .automatic, relativeTo: nil)
        let r = edit("add an offload from Studio A", on: workflow, edits: [add])
        #expect(r.workflow.steps.first { $0.kind == .sync }?.decks == .only([studioA.id]))
    }
}
