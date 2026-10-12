import Foundation
import Combine

// MARK: - Checkpoint
/// A snapshot of a workflow run taken at a step boundary, written to disk so
/// a run that was cut short — the app crashed, the Mac lost power, the user
/// force-quit — can pick up at the step it was on instead of starting over.
///
/// It holds the workflow as it was when the run began (so edits made in the
/// meantime can't shift which step is "next"), the files each device had
/// carried through the steps so far, and the run's log and task list so the
/// finished run reads as one continuous history entry.
struct WorkflowCheckpoint: Codable, Identifiable {
    /// Where one device's working state stood.
    struct DeviceState: Codable {
        var resourceKey: String
        var deviceName: String
        var destPath: String
        /// `destPath` relative to the mounted volume root it lives under, when
        /// it lives under one. A volume can come back at a different path
        /// after a restart (`/Volumes/Share` → `/Volumes/Share-1`), so on
        /// resume the store is re-mounted and this is re-applied to
        /// whatever root it returns.
        var destRelativePath: String?
        var cloudStoreID: UUID?
        var filePaths: [String]
        var verifyOffload: Bool
        var deleteAfterOffload: Bool
    }

    /// Same as the interrupted run's session id, so a resumed run keeps
    /// overwriting this one file rather than leaving a stale copy behind.
    var id: UUID
    var workflow: Workflow
    var targets: [WorkflowTarget]
    var triggerChain: Set<UUID>
    var startedAt: Date
    var updatedAt: Date
    /// Index of the first step that has not finished. A step that was
    /// running when the run died is re-run from its beginning.
    var nextStepIndex: Int
    var devices: [DeviceState]
    var tasks: [SyncTask]
    var lines: [String]
    var converted: Int
    var skipped: Int
    var errors: Int
    var transcriptFilesToDelete: [String]

    var nextStep: WorkflowStep? {
        workflow.steps.indices.contains(nextStepIndex) ? workflow.steps[nextStepIndex] : nil
    }
}

// MARK: - Store
/// Keeps one JSON file per in-progress run under Application Support, and
/// exposes whichever ones were left behind by a previous launch.
///
/// A checkpoint is written at every step boundary and deleted when its run
/// finishes — cleanly, with errors, or stopped by the user. The only way one
/// outlives its run is the app (or Mac) dying mid-run, so anything found on
/// disk at launch is, by definition, an interrupted run.
@MainActor
final class WorkflowCheckpointStore: ObservableObject {
    static let shared = WorkflowCheckpointStore()

    /// Runs left unfinished by a previous launch, newest first. Resuming or
    /// discarding one removes it from here.
    @Published private(set) var interrupted: [WorkflowCheckpoint] = []

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        interrupted = loadAll().sorted { $0.updatedAt > $1.updatedAt }
    }

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Canopy/RunCheckpoints", isDirectory: true)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Writes (or overwrites) a run's checkpoint. Failure is deliberately
    /// silent: checkpointing is a safety net, and a full disk shouldn't be
    /// able to take down the run it's meant to protect.
    func save(_ checkpoint: WorkflowCheckpoint) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(checkpoint)
            try data.write(to: url(for: checkpoint.id), options: .atomic)
        } catch {
            AppState.shared.log("⚠️ Couldn't save run checkpoint: \(error.localizedDescription)")
        }
    }

    /// Deletes a run's checkpoint — called when the run ends, however it ends.
    func remove(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        interrupted.removeAll { $0.id == id }
    }

    /// Takes an interrupted run off the "needs attention" list without
    /// deleting its file — the resumed run keeps writing to it.
    func claim(id: UUID) {
        interrupted.removeAll { $0.id == id }
    }

    /// Gives up on an interrupted run. Files it already copied or converted
    /// stay where they are; only the saved position is dropped.
    func discard(id: UUID) {
        remove(id: id)
    }

    private func loadAll() -> [WorkflowCheckpoint] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let checkpoint = try? JSONDecoder().decode(WorkflowCheckpoint.self, from: data) else {
                // Unreadable — most likely written by a version of the app
                // whose format has since changed. It can't be resumed, and
                // leaving it would just re-fail on every launch.
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            return checkpoint
        }
    }
}
