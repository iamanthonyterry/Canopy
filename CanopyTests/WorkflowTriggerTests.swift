import Foundation
import Testing
@testable import Canopy

@MainActor
struct WorkflowTriggerTests {
    // Saturday 2026-10-10 12:00 — fixed so day-relative requests are deterministic.
    private let calendar = Calendar(identifier: .gregorian)
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
    }

    private let studioA = TriggerContext.Item(id: UUID(), name: "Studio A")
    private let studioB = TriggerContext.Item(id: UUID(), name: "Studio B")
    private let inbox = TriggerContext.Item(id: UUID(), name: "Inbox")
    private let cardIngest = TriggerContext.Item(id: UUID(), name: "Card Ingest")
    private let nightly = TriggerContext.Item(id: UUID(), name: "Nightly")

    private var context: TriggerContext {
        TriggerContext(decks: [studioA, studioB], folders: [inbox], workflows: [cardIngest, nightly])
    }

    private func build(_ kinds: [DraftStepKind], _ request: String, context: TriggerContext? = nil) -> WorkflowDraftResult {
        WorkflowDraftBuilder.build(
            from: WorkflowDraft(name: "Flow", steps: kinds), request: request,
            context: context ?? self.context, now: now)
    }

    private func edit(_ request: String, on workflow: Workflow, context: TriggerContext? = nil) -> WorkflowDraftResult {
        WorkflowEditBuilder.apply(
            WorkflowEditDraft(edits: []), to: workflow, request: request,
            context: context ?? self.context, now: now)
    }

    private func daily(hour: Int = 2, days: Set<Weekday> = []) -> ScheduleSettings {
        var t = ScheduleSettings()
        t.isEnabled = true; t.mode = .daily; t.hour = hour; t.selectedWeekdays = days
        return t
    }

    // MARK: Weekdays

    @Test func weekdaysLimitTheDailyTrigger() {
        func days(_ text: String) -> Set<Weekday>? { build([.offload], text).workflow.triggers.first?.selectedWeekdays }
        #expect(days("on weekdays at 6pm offload") == [.monday, .tuesday, .wednesday, .thursday, .friday])
        #expect(days("offload every monday and friday at 7am") == [.monday, .friday])
        #expect(days("offload every monday through thursday at 7am") == [.monday, .tuesday, .wednesday, .thursday])
        #expect(days("offload on saturdays at 9am") == [.saturday])
        #expect(days("offload every weekend at 10am") == [.saturday, .sunday])
        #expect(days("offload every night at 2am") == [])
    }

    @Test func dayAloneIsNotASchedule() {
        let r = build([.offload], "offload every monday")
        #expect(r.workflow.triggers.isEmpty)
        #expect(r.notes.contains { $0.contains("what time") })
    }

    @Test func aDayInAWorkflowNameIsNotAWeekday() {
        let r = build([.offload], "call it Friday Ingest and run it every night at 2am")
        #expect(r.workflow.triggers.first?.selectedWeekdays == [])
    }

    // MARK: One time

    @Test func tomorrowAtATimeIsOneTime() {
        let t = build([.offload], "offload tomorrow at 9am").workflow.triggers
        #expect(t.count == 1)
        #expect(t[0].mode == .oneTime)
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: t[0].oneTimeDate)
        #expect(parts.month == 10 && parts.day == 11 && parts.hour == 9 && parts.minute == 0)
    }

    @Test func namedDayAndDatesResolveToTheNextOccurrence() {
        func date(_ text: String) -> DateComponents? {
            build([.offload], text).workflow.triggers.first.map {
                calendar.dateComponents([.year, .month, .day, .hour], from: $0.oneTimeDate)
            }
        }
        // Saturday 10 Oct 2026.
        #expect(date("offload next friday at 5pm") == DateComponents(year: 2026, month: 10, day: 16, hour: 17))
        #expect(date("offload on friday at 5pm") == DateComponents(year: 2026, month: 10, day: 16, hour: 17))
        #expect(date("offload on october 20 at 8pm") == DateComponents(year: 2026, month: 10, day: 20, hour: 20))
        #expect(date("offload on 3/5 at 8am") == DateComponents(year: 2027, month: 3, day: 5, hour: 8))
    }

    @Test func inAnHourIsRelativeToNow() {
        let t = build([.offload], "run this in 2 hours and offload").workflow.triggers
        #expect(t.first?.mode == .oneTime)
        #expect(t.first?.oneTimeDate == now.addingTimeInterval(7200))
    }

    @Test func stopAfterIsNotAOneTimeRun() {
        let r = build([.startRecording], "start recording and stop in 45 minutes")
        #expect(r.workflow.triggers.isEmpty)
        #expect(r.workflow.steps.map(\.kind) == [.controlDeck, .wait, .controlDeck])
    }

    @Test func passedTimesAndMissingTimesAreNotScheduled() {
        let passed = build([.offload], "offload today at 8am")
        #expect(passed.workflow.triggers.isEmpty)
        #expect(passed.notes.contains { $0.contains("already passed") })

        let noTime = build([.offload], "offload tomorrow")
        #expect(noTime.workflow.triggers.isEmpty)
        #expect(noTime.notes.contains { $0.contains("what time") })
    }

    @Test func recurringWordsNeverMakeAOneTimeRun() {
        let t = build([.offload], "offload every night at 2am").workflow.triggers
        #expect(t.map(\.mode) == [.daily])
    }

    // MARK: Events

    @Test func recordingStoppedFollowsTheNamedDeck() {
        let r = build([.offload, .stopRecording], "when Studio A stops recording, offload the clips")
        #expect(r.workflow.triggers.count == 1)
        #expect(r.workflow.triggers[0].mode == .recordingStopped)
        #expect(r.workflow.triggers[0].deviceID == studioA.id)
        // The trigger phrase is not a Stop Recording step.
        #expect(r.workflow.steps.map(\.kind) == [.sync])
    }

    @Test func recordingStoppedWithoutADeckWatchesAnyDeck() {
        let t = build([.offload], "whenever a recording ends offload it").workflow.triggers
        #expect(t.first?.mode == .recordingStopped)
        #expect(t.first?.deviceID == nil)
    }

    @Test func twoNamedDecksGetATriggerEach() {
        let t = build([.offload], "when Studio A or Studio B stops recording offload").workflow.triggers
        #expect(Set(t.compactMap(\.deviceID)) == [studioA.id, studioB.id])
    }

    @Test func deviceOnline() {
        let t = build([.offload], "offload when Studio B comes back online").workflow.triggers
        #expect(t.first?.mode == .deviceOnline)
        #expect(t.first?.deviceID == studioB.id)
    }

    @Test func workflowFinishedMatchesByNameWithCondition() {
        let any = build([.notify], "after Card Ingest finishes email me").workflow
        #expect(any.triggers.first?.mode == .workflowFinished)
        #expect(any.triggers.first?.sourceWorkflowID == cardIngest.id)
        #expect(any.triggers.first?.finishCondition == .any)
        // The workflow's name is not an Offload step.
        #expect(any.steps.map(\.kind) == [.notify])

        let ok = build([.notify], "when the Card Ingest workflow finishes without errors, email me").workflow
        #expect(ok.triggers.first?.finishCondition == .withoutErrors)

        let bad = build([.notify], "email me if Nightly fails once Nightly has finished").workflow
        #expect(bad.triggers.first?.sourceWorkflowID == nightly.id)
        #expect(bad.triggers.first?.finishCondition == .withErrors)
    }

    @Test func aWorkflowNameAloneIsNotATrigger() {
        // "offload" is a step word, and a workflow could well be called "Offload".
        let ctx = TriggerContext(workflows: [.init(id: UUID(), name: "Offload")])
        let r = build([.offload, .notify], "offload the clips and let me know when it's done", context: ctx)
        #expect(r.workflow.triggers.isEmpty)
    }

    @Test func unknownWorkflowIsNotInvented() {
        let r = build([.notify], "after the other workflow finishes email me")
        #expect(r.workflow.triggers.isEmpty)
        #expect(r.notes.contains { $0.contains("which workflow") })
    }

    @Test func workflowCannotBeStartedByItselfOrByAWorkflowItStarts() {
        var ctx = context
        ctx.ineligibleWorkflowIDs = [cardIngest.id]
        let r = build([.notify], "after Card Ingest finishes email me", context: ctx)
        #expect(r.workflow.triggers.isEmpty)
        #expect(r.notes.contains { $0.contains("trigger each other") })
    }

    @Test func folderChangedNeedsAnArrivalVerbAndALeadWord() {
        let t = build([.offload], "when new clips arrive in Inbox, make proxies").workflow.triggers
        #expect(t.first?.mode == .folderChanged)
        #expect(t.first?.deviceID == inbox.id)

        // Describing what a step does isn't a trigger.
        let none = build([.offload], "offload so the footage is copied to the Inbox folder")
        #expect(none.workflow.triggers.isEmpty)
    }

    @Test func singleFolderNeedsNoName() {
        let t = build([.makeProxies], "whenever new files land in the folder make proxies").workflow.triggers
        #expect(t.first?.deviceID == inbox.id)
    }

    @Test func eventWithNothingToMatchAgainstExplainsItself() {
        let r = build([.makeProxies], "when new clips arrive in the folder make proxies", context: .empty)
        #expect(r.workflow.triggers.isEmpty)
        #expect(r.notes.contains { $0.contains("Local Folder") })
    }

    // MARK: Editing

    @Test func weekdaysOnlyNarrowTheExistingSchedule() {
        var w = Workflow(name: "Flow", steps: [WorkflowStep(action: .sync(destination: .global, verify: false))])
        w.triggers = [daily(hour: 6)]
        let r = edit("only run it on weekdays", on: w)
        #expect(r.workflow.triggers.count == 1)
        #expect(r.workflow.triggers[0].hour == 6)
        #expect(r.workflow.triggers[0].selectedWeekdays == [.monday, .tuesday, .wednesday, .thursday, .friday])
    }

    @Test func alsoAddsASecondDailyTrigger() {
        var w = Workflow(name: "Flow", steps: [WorkflowStep(action: .sync(destination: .global, verify: false))])
        w.triggers = [daily(hour: 6)]
        let r = edit("also run it every friday at 5pm", on: w)
        #expect(r.workflow.triggers.count == 2)
        #expect(r.workflow.triggers[0].hour == 6)
        #expect(r.workflow.triggers[1].hour == 17)
        #expect(r.workflow.triggers[1].selectedWeekdays == [.friday])
    }

    @Test func eventTriggerIsAddedOnceAndKeepsExistingTriggers() {
        var w = Workflow(name: "Flow", steps: [WorkflowStep(action: .sync(destination: .global, verify: false))])
        w.triggers = [daily()]
        let once = edit("start it when Studio A stops recording", on: w)
        #expect(once.workflow.triggers.map(\.mode) == [.daily, .recordingStopped])

        let twice = edit("start it when Studio A stops recording", on: once.workflow)
        #expect(twice.workflow.triggers.count == 2)
    }

    @Test func removingTheScheduleStillClearsEveryTrigger() {
        var w = Workflow(name: "Flow", steps: [WorkflowStep(action: .sync(destination: .global, verify: false))])
        var event = ScheduleSettings(); event.isEnabled = true; event.mode = .recordingStopped
        w.triggers = [daily(), event]
        #expect(edit("remove the trigger", on: w).workflow.triggers.isEmpty)
    }

    @Test func oneTimeIsAddedToAnExistingWorkflow() {
        var w = Workflow(name: "Flow", steps: [WorkflowStep(action: .sync(destination: .global, verify: false))])
        w.triggers = [daily()]
        let r = edit("also run it tomorrow at 9am", on: w)
        #expect(r.workflow.triggers.map(\.mode) == [.daily, .oneTime])
    }
}
