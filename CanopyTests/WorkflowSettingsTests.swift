import Foundation
import Testing
@testable import Canopy

@MainActor
struct WorkflowSettingsTests {
    private let deckA = TriggerContext.Item(id: UUID(), name: "Studio A")
    private let deckB = TriggerContext.Item(id: UUID(), name: "Studio B")

    private var oneDeck: TriggerContext { TriggerContext(decks: [deckA]) }
    private var twoDecks: TriggerContext { TriggerContext(decks: [deckA, deckB]) }

    private func build(_ kinds: [DraftStepKind], _ request: String, context: TriggerContext? = nil,
                       name: String = "  Test Flow ") -> WorkflowDraftResult {
        WorkflowDraftBuilder.build(
            from: WorkflowDraft(name: name, steps: kinds), request: request, context: context ?? .empty)
    }

    private func actions(_ kinds: [DraftStepKind], _ request: String, context: TriggerContext? = nil) -> [StepAction] {
        build(kinds, request, context: context).workflow.steps.map(\.action)
    }

    private func edit(_ kind: DraftStepKind, _ request: String, on actions: [StepAction],
                      context: TriggerContext? = nil) -> Workflow {
        let w = Workflow(name: "Flow", steps: actions.map { WorkflowStep(action: $0) })
        let e = DraftEdit(action: .update, step: kind, placement: .automatic, relativeTo: nil)
        return WorkflowEditBuilder.apply(WorkflowEditDraft(edits: [e]), to: w, request: request, context: context ?? .empty).workflow
    }

    // MARK: Proxies

    @Test func proxyQualityFollowsTheWording() {
        func preset(_ text: String) -> ConversionSettings.FFmpegPreset? {
            guard case .convert(let p, _, _, _) = actions([.makeProxies], text).first else { return nil }
            return p
        }
        #expect(preset("make proxies") == .fast)
        #expect(preset("make small proxies") == .superfast)
        #expect(preset("make high quality proxies") == .medium)
        #expect(preset("make the best quality proxies") == .slow)
        #expect(preset("make balanced proxies") == .veryfast)
    }

    @Test func parallelJobsAreStatedOrEfficient() {
        func jobs(_ text: String) -> Int? {
            guard case .convert(_, _, let j, _) = actions([.makeProxies], text).first else { return nil }
            return j
        }
        #expect(jobs("make proxies") == WorkflowEfficiency.parallelJobs)
        #expect((2...4).contains(WorkflowEfficiency.parallelJobs))
        #expect(jobs("make proxies, 3 at a time") == 3)
        #expect(jobs("make proxies one at a time") == 1)
        #expect(jobs("make proxies as fast as possible") == 4)
    }

    @Test func replacingOriginalsConvertsInPlaceInsteadOfDuplicating() {
        guard case .convert(_, let delete, _, let inPlace) = actions([.makeProxies], "make proxies and replace the originals").first
        else { Issue.record("no convert"); return }
        #expect(delete && inPlace)

        guard case .convert(_, let keepDelete, _, let keepInPlace) = actions([.makeProxies], "make proxies and keep the originals").first
        else { Issue.record("no convert"); return }
        #expect(!keepDelete && !keepInPlace)
    }

    // MARK: Verification

    @Test func negatedVerificationIsNotVerification() {
        func verify(_ text: String) -> Bool? {
            guard case .sync(_, let v, _) = actions([.offload], text).first else { return nil }
            return v
        }
        #expect(verify("offload with verification") == true)
        #expect(verify("offload without verification") == false)
        #expect(verify("offload and skip verifying") == false)
        #expect(verify("offload the clips") == false)
    }

    // MARK: Transcribe and clips

    @Test func deletingTranscriptsIsASettingNotACleanupStep() {
        func deletes(_ text: String) -> Bool? {
            guard case .transcribe(_, _, _, let d) = actions([.transcribe], text).first else { return nil }
            return d
        }
        #expect(deletes("transcribe the clips and delete the transcripts when it's done") == true)
        #expect(deletes("transcribe everything, then get rid of the transcript files afterwards") == true)
        #expect(deletes("transcribe them, don't keep the transcripts") == true)
        #expect(deletes("transcribe them but keep the transcripts") == false)
        #expect(deletes("transcribe everything") == false)
        let r = build([.transcribe, .cleanup], "transcribe the clips and delete the transcripts when it's done")
        #expect(r.workflow.steps.map(\.kind) == [.transcribe])
    }

    @Test func transcriptionSettingsComeFromTheRequest() {
        func transcribe(_ text: String) -> (String, Bool, Bool)? {
            guard case .transcribe(let l, let srt, let skip, _) = actions([.transcribe], text).first else { return nil }
            return (l, srt, skip)
        }
        #expect(transcribe("transcribe the spanish interviews")?.0 == "es-ES")
        #expect(transcribe("transcribe them, no subtitles")?.1 == false)
        #expect(transcribe("transcribe them again")?.2 == false)
        #expect(transcribe("transcribe everything")?.1 == true)
        #expect(transcribe("transcribe everything")?.2 == true)
        // Subtitles *in* French is a translation, not the spoken language.
        #expect(transcribe("transcribe it and add subtitles in french")?.0 == Locale.current.identifier)
    }

    @Test func clipCountAndLengthFollowTheRequest() {
        func clips(_ text: String) -> (Int, Int, Int)? {
            guard case .findClips(let n, let lo, let hi, _, _) = actions([.findClips], text).first else { return nil }
            return (n, lo, hi)
        }
        #expect(clips("find the best moments") ?? (-1, 0, 0) == (5, 20, 60))
        #expect(clips("find the top 3 highlights under 30 seconds") ?? (-1, 0, 0) == (3, 20, 30))
        #expect(clips("find clips between 15 and 45 seconds") ?? (-1, 0, 0) == (5, 15, 45))
        #expect(clips("find the best moments of at least 30 seconds") ?? (-1, 0, 0) == (5, 30, 60))
        // A short maximum pulls the minimum down with it.
        #expect(clips("find highlights under 15 seconds") ?? (-1, 0, 0) == (5, 10, 15))
        #expect(clips("find highlights: the five best clips, up to a minute") ?? (-1, 0, 0) == (5, 20, 60))
    }

    @Test func timesAndCountsOfOtherStepsAreNotClipSettings() {
        guard case .findClips(let n, _, _, _, _) = actions([.findClips, .wait], "find highlights, then wait 45 minutes").last
        else { Issue.record("no clips"); return }
        #expect(n == 5)
    }

    @Test func finishedPostsAreRenderedOnceNotTwice() {
        func export(_ kinds: [DraftStepKind], _ text: String) -> SocialFormat?? {
            for case .findClips(_, _, _, let f, _) in actions(kinds, text) { return .some(f) }
            return nil
        }
        #expect(export([.findClips], "find highlights and export finished posts for tiktok") == .some(.vertical))
        #expect(export([.findClips], "find highlights for tiktok") == .some(nil))
        // Resize for Social already crops each clip.
        #expect(export([.findClips, .resizeForSocial], "find highlights, resize them vertical and export finished posts") == .some(nil))
    }

    @Test func queueScoreAndCopyDetails() {
        guard case .queueClips(let score) = actions([.findClips, .queueClips], "find highlights and queue the clips, only the best ones").last
        else { Issue.record("no queue"); return }
        #expect(score == 70)
        guard case .queueClips(let exact) = actions([.findClips, .queueClips], "find highlights and add them to the queue, scoring above 80").last
        else { Issue.record("no queue"); return }
        #expect(exact == 80)

        guard case .writeCopy(let platform, let tags) = actions([.findClips, .writeCopy], "find highlights and write post copy for linkedin with 3 hashtags").last
        else { Issue.record("no copy"); return }
        #expect(platform == .linkedin && tags == 3)
    }

    // MARK: Social, Copy To, Notification, Folder

    @Test func resizeFormatAndTracking() {
        func reframe(_ text: String) -> (SocialFormat, Bool)? {
            guard case .reframe(let f, let follow) = actions([.resizeForSocial], text).first else { return nil }
            return (f, follow)
        }
        #expect(reframe("resize for social") ?? (.landscape, false) == (.vertical, true))
        #expect(reframe("resize them square with a centered crop") ?? (.landscape, false) == (.square, false))
        #expect(reframe("crop for the instagram feed") ?? (.landscape, false) == (.portrait, true))
        #expect(reframe("resize for youtube video, 16:9") ?? (.landscape, false) == (.landscape, true))
    }

    @Test func copyToOptions() {
        guard case .copyTo(_, let verify, let sidecars) = actions([.offload, .copyTo], "offload, then back up to the second drive without verification, just the videos").last
        else { Issue.record("no copy"); return }
        #expect(!verify && !sidecars)
        guard case .copyTo(_, let v2, let s2) = actions([.offload, .copyTo], "offload, then back up to the second drive").last
        else { Issue.record("no copy"); return }
        #expect(v2 && s2)
    }

    @Test func severalDecksMeanOneSummaryAndSeparateFolders() {
        func notify(_ text: String, _ context: TriggerContext) -> Bool? {
            guard case .notify(_, _, _, let perDrive) = actions([.offload, .notify], text, context: context).last else { return nil }
            return perDrive
        }
        #expect(notify("offload and email me", oneDeck) == true)
        #expect(notify("offload and email me", twoDecks) == false)
        #expect(notify("offload and email me for each deck", twoDecks) == true)
        #expect(notify("offload and send one summary email", oneDeck) == false)

        func grouped(_ text: String, _ context: TriggerContext) -> Bool? {
            guard case .createFolder(_, _, _, let g) = actions([.createFolder, .offload], text, context: context).first else { return nil }
            return g
        }
        #expect(grouped("make a folder and offload", oneDeck) == false)
        #expect(grouped("make a folder and offload", twoDecks) == true)
        #expect(grouped("make a folder per camera and offload", oneDeck) == true)
    }

    @Test func notificationSubjectIsTheWorkflowName() {
        guard case .notify(let header, _, _, _) = actions([.offload, .notify], "offload and email me").last
        else { Issue.record("no notify"); return }
        #expect(header == "Test Flow")
    }

    @Test func inferredSettingsAreExplainedAndPlainRequestsAreQuiet() {
        let quiet = build([.offload, .makeProxies], "offload and make proxies")
        #expect(!quiet.notes.contains { $0.hasPrefix("Make Proxies:") })

        let tuned = build([.offload, .makeProxies], "offload and make small proxies")
        #expect(tuned.notes.contains { $0.hasPrefix("Make Proxies:") })
    }

    // MARK: Layout advice

    @Test func advisesWhenOffloadAndProxiesCannotOverlap() {
        let steps = [
            WorkflowStep(action: .sync(destination: .global, verify: false)),
            WorkflowStep(action: .rename(pattern: "{index}")),
            WorkflowStep(action: StepAction.defaultAction(for: .convert)),
        ]
        #expect(WorkflowEfficiency.advisories(for: steps).contains { $0.contains("aren't next to each other") })

        var gated = steps
        gated.remove(at: 1)
        gated[1].requiresConfirmation = true
        #expect(WorkflowEfficiency.advisories(for: gated).contains { $0.contains("confirmation") })

        gated[1].requiresConfirmation = false
        #expect(WorkflowEfficiency.advisories(for: gated).isEmpty)
    }

    // MARK: Editing

    @Test func existingStepSettingsChangeOnlyWhatIsStated() {
        let proxies = StepAction.convert(preset: .fast, deleteOriginal: false, maxParallelJobs: 2, convertInPlace: false)
        let w = edit(.makeProxies, "make the proxies smaller", on: [proxies])
        guard case .convert(let preset, let delete, let jobs, let inPlace) = w.steps[0].action else { Issue.record("no convert"); return }
        #expect(preset == .superfast)
        #expect(!delete && jobs == 2 && !inPlace)
    }

    @Test func clipSettingsCanBeUpdated() {
        let find = StepAction.findClips(maxClips: 5, minSeconds: 20, maxSeconds: 60)
        let w = edit(.findClips, "only 3 clips under 30 seconds", on: [find])
        guard case .findClips(let n, let lo, let hi, _, _) = w.steps[0].action else { Issue.record("no clips"); return }
        #expect(n == 3 && lo == 20 && hi == 30)
    }

    @Test func notificationCanBecomeOneSummary() {
        let notify = StepAction.notify(header: "Done", message: "", recipients: [], sendPerDrive: true)
        let w = edit(.notify, "send one summary email", on: [notify])
        guard case .notify(let header, _, _, let perDrive) = w.steps[0].action else { Issue.record("no notify"); return }
        #expect(header == "Done" && !perDrive)
    }

    @Test func makeItFasterRaisesJobsAndSummarisesWithoutTouchingOutputs() {
        let proxies = StepAction.convert(preset: .medium, deleteOriginal: false, maxParallelJobs: 1, convertInPlace: false)
        let notify = StepAction.notify(header: "Done", message: "", recipients: [], sendPerDrive: true)
        var w = Workflow(name: "Flow", steps: [proxies, notify].map { WorkflowStep(action: $0) })
        w.triggers = []
        let r = WorkflowEditBuilder.apply(WorkflowEditDraft(edits: []), to: w, request: "make it faster", context: twoDecks)

        guard case .convert(let preset, let delete, let jobs, _) = r.workflow.steps[0].action else { Issue.record("no convert"); return }
        #expect(preset == .medium)          // quality is never traded for speed
        #expect(!delete)
        #expect(jobs == WorkflowEfficiency.parallelJobs)
        guard case .notify(_, _, _, let perDrive) = r.workflow.steps[1].action else { Issue.record("no notify"); return }
        #expect(!perDrive)
        #expect(r.notes.contains { $0.contains("Make Proxies now runs") })
    }
}
