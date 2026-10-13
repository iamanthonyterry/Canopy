import Foundation
import Testing
@testable import Canopy

@MainActor
struct RunEstimateTests {
    private let mb: Int64 = 1_000_000

    private func makeHistory() -> RunTimingHistory {
        let suite = "canopy-timing-\(UUID().uuidString)"
        return RunTimingHistory(defaults: UserDefaults(suiteName: suite)!, key: "history")
    }

    private func makeSession(_ steps: [WorkflowStep], history: RunTimingHistory? = nil) -> WorkflowRunSession {
        let session = WorkflowRunSession(workflow: Workflow(name: "Offload", steps: steps), deckNames: ["Deck 1"])
        session.timingHistory = history ?? makeHistory()
        return session
    }

    private func task(
        _ name: String, deck: String = "Deck 1", size: Int64, phase: SyncTask.Phase = .queued,
        progress: Double = 0, speed: Double = 0
    ) -> SyncTask {
        var task = SyncTask(fileName: name, deckName: deck, destDir: URL(fileURLWithPath: "/tmp/out"))
        task.fileSizeBytes = size
        task.phase = phase
        task.syncProgress = progress
        task.bytesPerSecond = speed
        return task
    }

    private var syncStep: WorkflowStep { WorkflowStep(action: .sync(destination: .global)) }
    private var convertStep: WorkflowStep {
        WorkflowStep(action: .convert(preset: .veryfast, deleteOriginal: false, maxParallelJobs: 1))
    }

    // MARK: Downloads

    @Test func queuedFilesAreCountedAtTheSpeedOfTheFileInFlight() throws {
        let sync = syncStep
        let session = makeSession([sync])
        session.beginStep(sync.id)
        session.tasks = [
            task("a.mov", size: 1000 * mb, phase: .downloading, progress: 0.5, speed: Double(10 * mb)),
            task("b.mov", size: 1000 * mb),
        ]
        let estimate = try #require(session.estimate())
        #expect(abs(estimate.secondsRemaining - 150) < 1)
        #expect(!estimate.isLowerBound)
    }

    @Test func aFileThatHasJustStartedBorrowsThePreviousFilesSpeed() throws {
        let sync = syncStep
        let session = makeSession([sync])
        session.beginStep(sync.id)
        session.tasks = [
            task("a.mov", size: 1000 * mb, phase: .done, progress: 1, speed: Double(10 * mb)),
            task("b.mov", size: 1000 * mb, phase: .downloading),
        ]
        let estimate = try #require(session.estimate())
        #expect(abs(estimate.secondsRemaining - 100) < 1)
    }

    @Test func devicesDownloadingSideBySideTakeAsLongAsTheSlowest() throws {
        let sync = syncStep
        let session = makeSession([sync])
        session.beginStep(sync.id)
        session.tasks = [
            task("a.mov", deck: "Deck 1", size: 1000 * mb, phase: .downloading, progress: 0.5, speed: Double(10 * mb)),
            task("a.mov", deck: "Deck 2", size: 1000 * mb, phase: .downloading, progress: 0.5, speed: Double(5 * mb)),
        ]
        let estimate = try #require(session.estimate())
        #expect(abs(estimate.secondsRemaining - 100) < 1)
    }

    @Test func verifyingCountsASecondPassOverEachFile() throws {
        let sync = WorkflowStep(action: .sync(destination: .global, verify: true))
        let session = makeSession([sync])
        session.beginStep(sync.id)
        session.tasks = [task("a.mov", size: 1000 * mb, phase: .downloading, progress: 0.5, speed: Double(10 * mb))]
        let estimate = try #require(session.estimate())
        #expect(abs(estimate.secondsRemaining - 150) < 1)
    }

    @Test func anEarlierRunsSpeedGivesAnEstimateBeforeAnySample() throws {
        let history = makeHistory()
        history.recordDownloadSpeed(Double(20 * mb), forDevice: "Deck 1")
        let sync = syncStep
        let session = makeSession([sync], history: history)
        session.beginStep(sync.id)
        session.tasks = [task("a.mov", size: 1000 * mb)]
        let estimate = try #require(session.estimate())
        #expect(abs(estimate.secondsRemaining - 50) < 1)
    }

    @Test func nothingIsShownWhenNothingIsKnown() {
        let sync = syncStep
        let session = makeSession([sync])
        session.beginStep(sync.id)
        session.tasks = [task("a.mov", size: 1000 * mb)]
        #expect(session.estimate() == nil)
    }

    // MARK: Later steps

    @Test func waitStepsAheadAreAddedOn() throws {
        let sync = syncStep
        let session = makeSession([sync, WorkflowStep(action: .wait(minutes: 5))])
        session.beginStep(sync.id)
        session.tasks = [task("a.mov", size: 1000 * mb, phase: .downloading, progress: 0.5, speed: Double(10 * mb))]
        let estimate = try #require(session.estimate())
        #expect(abs(estimate.secondsRemaining - 350) < 1)
    }

    @Test func conversionStillToComeIsCountedAfterTheDownloads() throws {
        let sync = syncStep
        let convert = convertStep
        // A step in between keeps the two from running as one.
        let session = makeSession([sync, WorkflowStep(action: .wait(minutes: 0)), convert])
        let now = Date()
        session.beginStep(sync.id)
        var converted = task("a.mov", size: 1000 * mb, phase: .done, progress: 1, speed: Double(10 * mb))
        converted.convertStartedAt = now.addingTimeInterval(-200)
        converted.convertFinishedAt = now.addingTimeInterval(-100)
        session.tasks = [
            converted,
            task("b.mov", size: 500 * mb, phase: .downloading, progress: 0.5, speed: Double(10 * mb)),
        ]
        // 25 s of download left, then 500 MB to convert at 100 s per 1000 MB.
        let estimate = try #require(session.estimate(at: now))
        #expect(abs(estimate.secondsRemaining - 75) < 1)
    }

    @Test func aRunningConversionIsProjectedFromItsOwnProgress() throws {
        let convert = convertStep
        let session = makeSession([convert])
        let now = Date()
        session.beginStep(convert.id)
        var converting = task("a.mov", size: 1000 * mb, phase: .converting, progress: 1)
        converting.convertProgress = 0.25
        converting.convertStartedAt = now.addingTimeInterval(-30)
        session.tasks = [converting]
        let estimate = try #require(session.estimate(at: now))
        #expect(abs(estimate.secondsRemaining - 90) < 1)
    }

    @Test func aStepWithNoHistoryMakesTheEstimateALowerBound() throws {
        let sync = syncStep
        let transcribe = WorkflowStep(action: .transcribe(locale: "en-US", writeSRT: false, skipExisting: true))
        let session = makeSession([sync, transcribe])
        session.beginStep(sync.id)
        session.tasks = [task("a.mov", size: 1000 * mb, phase: .downloading, progress: 0.5, speed: Double(10 * mb))]
        let estimate = try #require(session.estimate())
        #expect(estimate.isLowerBound)
        #expect(estimate.label(at: estimate.asOf) == "50s+ left")
    }

    @Test func aStepsLastDurationIsScaledToThisRunsFootage() throws {
        let transcribe = WorkflowStep(action: .transcribe(locale: "en-US", writeSRT: false, skipExisting: true))
        let history = makeHistory()
        history.recordStep(transcribe.id, seconds: 100, bytes: 1000 * mb)
        let session = makeSession([transcribe], history: history)
        session.tasks = [task("a.mov", size: 2000 * mb, phase: .done, progress: 1)]
        let estimate = try #require(session.estimate())
        #expect(abs(estimate.secondsRemaining - 200) < 1)
        #expect(!estimate.isLowerBound)
    }

    // MARK: Counting down

    @Test func theEstimateCountsDownBetweenUpdatesUnlessTheRunIsHeld() {
        let asOf = Date()
        var estimate = RunEstimate(secondsRemaining: 90, asOf: asOf)
        #expect(estimate.remaining(at: asOf.addingTimeInterval(30)) == 60)
        #expect(estimate.label(at: asOf.addingTimeInterval(30)) == "~1m left")
        #expect(estimate.label(at: asOf.addingTimeInterval(120)) == "almost done")

        estimate.countsDown = false
        #expect(estimate.remaining(at: asOf.addingTimeInterval(30)) == 90)
    }

    @Test func aRunWaitingOnConfirmationDoesNotCountDown() throws {
        let wait = WorkflowStep(action: .wait(minutes: 1), requiresConfirmation: true)
        let session = makeSession([wait])
        session.markAwaitingConfirmation(wait.id)
        let estimate = try #require(session.estimate())
        #expect(estimate.secondsRemaining == 60)
        #expect(!estimate.countsDown)
    }

    // MARK: Remembering

    @Test func aFinishedRunsTimingsAreKeptForTheNextOne() throws {
        let history = makeHistory()
        let convert = convertStep
        let session = makeSession([convert], history: history)
        let now = Date()
        session.beginStep(convert.id)
        var done = task("a.mov", size: 1000 * mb, phase: .done, progress: 1, speed: Double(10 * mb))
        done.convertStartedAt = now.addingTimeInterval(-100)
        done.convertFinishedAt = now
        session.tasks = [done]
        session.endStep(convert.id)
        session.recordTimings()

        let speed = try #require(history.downloadSpeed(forDevice: "Deck 1"))
        #expect(abs(speed - Double(10 * mb)) < 1)
        let rate = try #require(history.convertSecondsPerByte(for: .veryfast))
        #expect(abs(rate * Double(1000 * mb) - 100) < 0.001)
        #expect(history.timing(forStep: convert.id)?.bytes == 1000 * mb)
    }

    @Test func aStoppedRunTeachesNothing() {
        let history = makeHistory()
        let session = makeSession([], history: history)
        session.tasks = [task("a.mov", size: 1000 * mb, phase: .done, progress: 1, speed: Double(10 * mb))]
        session.isCancelled = true
        session.recordTimings()
        #expect(history.downloadSpeed(forDevice: "Deck 1") == nil)
    }
}
