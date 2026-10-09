import Foundation
import Testing
@testable import Canopy

@MainActor
struct WorkflowAssistantTests {
    private func build(_ kinds: [DraftStepKind], _ request: String, name: String = "  Test Flow ") -> WorkflowDraftResult {
        WorkflowDraftBuilder.build(from: WorkflowDraft(name: name, steps: kinds), request: request)
    }

    // MARK: Guardrails

    @Test func stepsTheRequestNeverMentionedAreDropped() {
        let r = build([.startRecording, .wait, .offload, .formatDrive, .cleanup], "offload my clips")
        #expect(r.workflow.steps.map(\.kind) == [.sync])
        #expect(r.workflow.triggers.isEmpty)
        #expect(r.notes.first?.contains("Left out") == true)
    }

    @Test func destructiveStepsAlwaysRequireConfirmation() {
        let r = build([.offload, .formatDrive, .cleanup], "offload then erase the drive and delete old files")
        #expect(r.workflow.steps.map(\.kind) == [.sync, .format, .cleanup])
        #expect(r.workflow.steps.map(\.requiresConfirmation) == [false, true, true])
    }

    @Test func offloadPointsAtEarlierCreateFolder() {
        let r = build([.createFolder, .offload], "make a folder and offload into it")
        let folderID = r.workflow.steps[0].id
        guard case .sync(let destination, _) = r.workflow.steps[1].action else { Issue.record("not sync"); return }
        #expect(destination == .createdFolder(stepID: folderID))
    }

    @Test func missedStatedStepsAreAddedBackInRunOrder() {
        let r = build([.notify], "offload the clips, make small versions for editing, rename them, then email me")
        #expect(r.workflow.steps.map(\.kind) == [.sync, .convert, .rename, .notify])
    }

    @Test func destructiveStepsAreNeverAddedByTheCode() {
        let r = build([.offload], "offload then erase the drive and delete old files")
        #expect(r.workflow.steps.map(\.kind) == [.sync])
    }

    @Test func proxiesKeepOriginalsUnlessToldOtherwise() {
        func deletes(_ text: String) -> Bool? {
            guard case .convert(_, let del, _, _) = build([.makeProxies], text).workflow.steps.first?.action else { return nil }
            return del
        }
        #expect(deletes("make proxies") == false)
        #expect(deletes("make proxies and delete the originals") == true)
    }

    @Test func grabbingFootageCountsAsOffload() {
        #expect(build([.rename], "grab the footage and rename it").workflow.steps.map(\.kind) == [.sync, .rename])
    }

    @Test func findClipsRecognisedAfterTranscribeAndBeforeResize() {
        let r = build([.resizeForSocial, .findClips, .transcribe], "transcribe, find the best moments for social and resize them vertical")
        #expect(r.workflow.steps.map(\.kind) == [.transcribe, .findClips, .reframe])
    }

    @Test func nameIsTrimmedAndDefaulted() {
        #expect(build([.offload], "offload", name: "  Test Flow ").workflow.name == "Test Flow")
        #expect(build([.offload], "offload", name: "  ").workflow.name == "New Workflow")
    }

    // MARK: Details read from the request

    @Test func verificationOnlyWhenAskedFor() {
        func verify(_ text: String) -> Bool? {
            guard case .sync(_, let v) = build([.offload], text).workflow.steps.first?.action else { return nil }
            return v
        }
        #expect(verify("offload my clips") == false)
        #expect(verify("offload with checksum verification") == true)
    }

    @Test func dailyScheduleNeedsRecurrenceAndClockTime() {
        func time(_ text: String) -> String? { build([.offload], text).workflow.triggers.first?.displayTime }
        #expect(time("every night at 2am offload") == "2:00 AM")
        #expect(time("offload daily at 6:30 pm") == "6:30 PM")
        #expect(time("every day at 12am offload") == "12:00 AM")
        #expect(time("every morning at 7 offload") == "7:00 AM")
        #expect(time("every night at 10 offload") == "10:00 PM")
        #expect(time("every night at 2 offload") == "2:00 AM")
        #expect(time("every day at 14:30 offload") == "2:30 PM")
        #expect(time("every day at 7 offload") == nil)
        #expect(time("offload at 5 clips") == nil)
        #expect(time("offload my clips") == nil)
    }

    @Test func numbersComeFromTheRequest() {
        func steps(_ kinds: [DraftStepKind], _ text: String) -> [StepAction] { build(kinds, text).workflow.steps.map(\.action) }
        #expect(steps([.startRecording], "start recording and stop after 45 minutes") == [.controlDeck(command: .start, stopAfterMinutes: 45)])
        #expect(steps([.wait], "wait 2 hours") == [.wait(minutes: 120)])
        #expect(steps([.cleanup], "delete files older than 2 weeks") == [.cleanup(retentionDays: 14)])
        #expect(steps([.cleanup], "delete old files") == [.cleanup(retentionDays: 30)])
    }

    @Test func renamePatternFollowsRequest() {
        func pattern(_ text: String) -> String? {
            guard case .rename(let p) = build([.rename], text).workflow.steps.first?.action else { return nil }
            return p
        }
        #expect(pattern("rename files with the project name and camera") == "{project}_{cam}_{index}")
        #expect(pattern("rename the files") == "{device}_{date}_{index}")
    }
}
