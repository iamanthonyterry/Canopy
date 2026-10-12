import Foundation
import Testing
@testable import Canopy

@MainActor
struct WorkflowCheckpointTests {
    private func makeStore() -> (WorkflowCheckpointStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("canopy-checkpoints-\(UUID().uuidString)", isDirectory: true)
        return (WorkflowCheckpointStore(directory: dir), dir)
    }

    private func makeCheckpoint(nextStepIndex: Int = 1) -> WorkflowCheckpoint {
        let workflow = Workflow(name: "Offload", steps: [
            WorkflowStep(action: .wait(minutes: 1)),
            WorkflowStep(action: .queueClips(minScore: 50)),
        ])
        var task = SyncTask(fileName: "Clip0001.mov", deckName: "Deck 1", destDir: URL(fileURLWithPath: "/tmp/out"))
        task.phase = .done
        task.verification = .verified
        task.sha256 = "abc123"
        return WorkflowCheckpoint(
            id: UUID(), workflow: workflow, targets: [.localFolder(UUID())], triggerChain: [workflow.id],
            startedAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 2_000),
            nextStepIndex: nextStepIndex,
            devices: [.init(
                resourceKey: "folder:/tmp/out", deviceName: "Out", destPath: "/tmp/out",
                destRelativePath: nil, cloudStoreID: nil, filePaths: ["/tmp/out/Clip0001.mp4"],
                verifyOffload: true, deleteAfterOffload: false
            )],
            tasks: [task], lines: ["[10:00] started"], converted: 1, skipped: 2, errors: 0,
            transcriptFilesToDelete: []
        )
    }

    @Test func savedCheckpointIsFoundByTheNextLaunchWithItsStateIntact() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = makeCheckpoint()
        store.save(checkpoint)

        // A "new launch" is a new store reading the same directory.
        let relaunched = WorkflowCheckpointStore(directory: dir)
        let found = try #require(relaunched.interrupted.first)
        #expect(found.id == checkpoint.id)
        #expect(found.nextStepIndex == 1)
        #expect(found.nextStep?.kind == .queueClips)
        #expect(found.devices.first?.filePaths == ["/tmp/out/Clip0001.mp4"])
        #expect(found.tasks.first?.verification == .verified)
        #expect(found.tasks.first?.sha256 == "abc123")
        #expect(found.skipped == 2)
    }

    @Test func removingACheckpointDeletesItsFile() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = makeCheckpoint()
        store.save(checkpoint)
        store.remove(id: checkpoint.id)

        #expect(WorkflowCheckpointStore(directory: dir).interrupted.isEmpty)
    }

    @Test func claimingHidesARunFromTheListButKeepsItsFile() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = makeCheckpoint()
        store.save(checkpoint)

        let relaunched = WorkflowCheckpointStore(directory: dir)
        relaunched.claim(id: checkpoint.id)
        #expect(relaunched.interrupted.isEmpty)
        // Still on disk: if the resumed run dies too, it can be resumed again.
        #expect(WorkflowCheckpointStore(directory: dir).interrupted.count == 1)
    }

    @Test func unreadableCheckpointIsDroppedInsteadOfFailingEveryLaunch() throws {
        let (_, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = dir.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: bad)

        #expect(WorkflowCheckpointStore(directory: dir).interrupted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bad.path))
    }

    @Test func restoringASessionMarksFinishedStepsAndCarriesCounters() {
        let checkpoint = makeCheckpoint(nextStepIndex: 1)
        let session = WorkflowRunSession(
            workflow: checkpoint.workflow, deckNames: ["Out"],
            id: checkpoint.id, startedAt: checkpoint.startedAt
        )
        session.restore(from: checkpoint)

        #expect(session.id == checkpoint.id)
        #expect(session.startedAt == checkpoint.startedAt)
        #expect(session.stepRuns[0].status == .done)
        #expect(session.stepRuns[1].status == .pending)
        #expect(session.converted == 1 && session.skipped == 2)
        #expect(session.tasks.count == 1)
        #expect(session.lines == ["[10:00] started"])
    }
}
