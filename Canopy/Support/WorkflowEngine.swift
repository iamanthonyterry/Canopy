import Foundation
import Combine

/// Runs a user-defined `Workflow`: for each target device, executes the
/// workflow's steps in order, passing the current working set of local
/// files from one step to the next (sync produces files, convert/rename
/// transform them, format/cleanup act independently of them).
///
/// Multiple workflows can run at once as long as they don't target the same
/// device — each run gets its own `WorkflowRunSession` (its own log, task
/// list, and cancellation flag) instead of sharing one global "current run"
/// state, so stopping or watching one run never affects another.
@MainActor
final class WorkflowEngine: ObservableObject {
    static let shared = WorkflowEngine()

    private let appState = AppState.shared

    /// The device a workflow's steps are running against — a real network
    /// HyperDeck, a folder already on this Mac's filesystem, or a specific
    /// folder within a mounted Cloud Store.
    enum WorkflowTargetDevice: Hashable {
        case hyperDeck(HyperDeck)
        case localFolder(LocalFolder)
        case cloudStore(CloudStore, path: String)

        var name: String {
            switch self {
            case .hyperDeck(let d):   return d.name
            case .localFolder(let f): return f.name
            case .cloudStore(let s, let path): return path.isEmpty ? s.name : "\(s.name)/\(path)"
            }
        }

        var resourceKey: String {
            switch self {
            case .hyperDeck(let d):   return AppState.resourceKey(d)
            case .localFolder(let f): return AppState.resourceKey(f)
            case .cloudStore(let s, let path): return AppState.resourceKey(s, path: path)
            }
        }

        /// Non-nil only for a HyperDeck target — used to guard steps
        /// (Control HyperDeck, Format) that only make sense for a real
        /// device, and by retry to decide whether there's anything to
        /// re-download.
        var hyperDeck: HyperDeck? {
            if case .hyperDeck(let d) = self { return d }
            return nil
        }

        /// The saved form of this device, as stored in a workflow's target
        /// list — what a run checkpoint records so it can find it again.
        var workflowTarget: WorkflowTarget {
            switch self {
            case .hyperDeck(let d):            return .hyperDeck(d.id)
            case .localFolder(let f):          return .localFolder(f.id)
            case .cloudStore(let s, let path): return .cloudStore(id: s.id, path: path)
            }
        }

        /// A folder that isn't a registered device, picked for one run. It
        /// behaves exactly like a Local Folder target: steps run in place on
        /// the files already there.
        static func folder(at url: URL) -> WorkflowTargetDevice {
            .localFolder(LocalFolder(name: url.lastPathComponent, path: url.path))
        }
    }

    /// Per-device state threaded through a workflow's steps.
    private struct StepContext {
        let device: WorkflowTargetDevice
        /// `var` because a Create Folder step earlier in the run can
        /// replace it with the folder it just created, for every device at
        /// once, before the Sync step that consumes it executes.
        var destDir: URL
        /// Which cloud store `destDir` lives on, if any — carried alongside
        /// it so per-file tasks can remember it, for retries.
        var cloudStoreID: UUID? = nil
        var files: [URL] = []
        /// Set from the Sync step: hash each download against the source.
        var verifyOffload = false
        /// Set from the Sync step: remove each file from the device once
        /// its copy has been verified.
        var deleteAfterOffload = false
        let session: WorkflowRunSession
    }

    // MARK: - Run (all target devices)

    func run(_ workflow: Workflow) async {
        await start(workflow, targets: targetDevices(for: workflow), triggerChain: [workflow.id])
    }

    // MARK: - Run (single device)
    // Runs the workflow's steps against exactly one device, regardless of
    // the decks and folders that workflow normally uses — used by the
    // per-device "Run Workflow" action on the Dashboard. On a HyperDeck,
    // every deck step acts on that deck for this run.

    func runDevice(_ workflow: Workflow, target: WorkflowTargetDevice) async {
        let workflow = target.hyperDeck.map { workflow.pointingDeckSteps(at: $0.id) } ?? workflow
        await start(workflow, targets: [target], triggerChain: [workflow.id])
    }

    // MARK: - Run (a chosen folder)
    // Runs the workflow's steps in place on any folder, registered as a
    // device or not — used by "Run Workflow" on a folder in the file
    // browser, and by a workflow with no fixed devices.

    func runFolder(_ workflow: Workflow, at url: URL) async {
        await runDevice(workflow, target: .folder(at: url))
    }

    // MARK: - Resume an interrupted run
    // A run that was cut short (crash, power loss, force quit) leaves its
    // checkpoint behind — see `WorkflowCheckpointStore`. Resuming re-enters
    // the normal run loop at the step it was on, with each device's files
    // and destination folder put back as they were.

    /// False while any device the interrupted run used is busy elsewhere.
    func canResume(_ checkpoint: WorkflowCheckpoint) -> Bool {
        appState.canRun(checkpoint.workflow)
    }

    func resume(_ checkpoint: WorkflowCheckpoint) async {
        guard canResume(checkpoint) else { return }
        WorkflowCheckpointStore.shared.claim(id: checkpoint.id)
        let targets = checkpoint.targets.compactMap(device(for:))
        await start(
            checkpoint.workflow, targets: targets,
            triggerChain: checkpoint.triggerChain, resuming: checkpoint
        )
    }

    // MARK: - Shared run loop

    /// `triggerChain` accumulates the IDs of every workflow already running
    /// upstream in this call stack (the workflow itself, plus any that
    /// triggered it via a Trigger Workflow step) — checked before honoring
    /// another Trigger Workflow step so A → B → A can't recurse forever.
    private func start(
        _ workflow: Workflow, targets: [WorkflowTargetDevice], triggerChain: Set<UUID> = [],
        resuming: WorkflowCheckpoint? = nil
    ) async {
        // The Run buttons are already disabled when this would conflict, so
        // this mainly guards races — e.g. the scheduler firing at the same
        // instant someone taps Run manually.
        guard appState.canRun(
            deviceNames: Set(targets.map(\.name)), resourceKeys: Set(targets.map(\.resourceKey))
        ) else { return }

        let session = appState.beginRun(
            for: workflow,
            deckNames: Set(targets.map(\.name)),
            resourceKeys: Set(targets.map(\.resourceKey)),
            id: resuming?.id ?? UUID(),
            startedAt: resuming?.startedAt ?? Date()
        )
        if let resuming {
            session.restore(from: resuming)
            let total = workflow.steps.count
            let position = min(resuming.nextStepIndex + 1, total)
            let title = resuming.nextStep?.kind.title ?? "finishing up"
            session.log("↻ Resuming interrupted run — continuing at step \(position) of \(total) (\(title))")
        } else {
            session.log("▶ Workflow started: \(workflow.name)")
        }
        let checkpointTargets = targets.map(savedTarget(for:))

        guard !targets.isEmpty else {
            session.log(workflow.choosesFolderAtRun
                ? "⚠️ This workflow has no HyperDeck or folder set — run it on a folder from the file browser, or press Run and choose one"
                : "⚠️ No HyperDeck or folder is available for this workflow")
            finishRun(workflow: workflow, session: session)
            return
        }

        // Each HyperDeck target may point at its own Cloud Store, or fall
        // back to the shared global destination — mount every distinct
        // store exactly once and reuse the resolved path for every device
        // that needs it. This is done up front so every device has a ready
        // context before the step loop below starts fanning steps out
        // across them.
        //
        // A Local Folder target is never mounted and never redirected by
        // the workflow's configured Sync destination — its own path always
        // is its destination, since the whole point of a folder target is
        // to run in place. A Cloud Store Folder target works the same way
        // (its own configured folder is always its destination, regardless
        // of the workflow's Sync step) except that its store still needs
        // mounting first, same as a HyperDeck's destination would.
        //
        // The one exception is a Sync step pointed at a Create Folder step:
        // that folder's name can depend on the date it's created, so it's
        // resolved when the run loop actually reaches that step, below —
        // every HyperDeck context just gets a placeholder destDir until then.
        var mountedPaths: [UUID?: String] = [:]
        var contexts: [StepContext] = []
        let syncDestination = workflow.syncDestination

        var referencedFolderStepID: UUID? = nil
        if case .createdFolder(let stepID) = syncDestination { referencedFolderStepID = stepID }

        if let referencedFolderStepID,
           !workflow.steps.contains(where: { $0.id == referencedFolderStepID && $0.kind == .createFolder }) {
            session.log("❌ The Sync step's destination points at a Create Folder step that no longer exists in this workflow")
            session.mountError = "Sync destination step missing"
            session.errors += 1
            finishRun(workflow: workflow, session: session)
            return
        }

        for target in targets {
            switch target {
            case .localFolder(let folder):
                contexts.append(StepContext(device: target, destDir: URL(fileURLWithPath: folder.path), session: session))

            case .cloudStore(let store, let path):
                guard workflow.needsDestinationMount else {
                    contexts.append(StepContext(device: target, destDir: URL(fileURLWithPath: "/dev/null"), session: session))
                    continue
                }
                do {
                    let root = try await mountBase(cloudStoreID: store.id, session: session, cache: &mountedPaths)
                    let destDir = path.isEmpty ? root : root.appendingPathComponent(path)
                    try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                    contexts.append(StepContext(device: target, destDir: destDir, cloudStoreID: store.id, session: session))
                } catch {
                    session.log("❌ \(store.name): \(error.localizedDescription)")
                    session.mountError = error.localizedDescription
                    session.errors += 1
                }

            case .hyperDeck(let deck):
                guard workflow.needsDestinationMount else {
                    contexts.append(StepContext(device: target, destDir: URL(fileURLWithPath: "/dev/null"), session: session))
                    continue
                }
                guard referencedFolderStepID == nil else {
                    contexts.append(StepContext(device: target, destDir: URL(fileURLWithPath: "/dev/null"), session: session))
                    continue
                }
                do {
                    let destDir = try await resolveDestination(
                        for: deck, destination: syncDestination, session: session, cache: &mountedPaths
                    )
                    try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                    contexts.append(StepContext(
                        device: target, destDir: destDir,
                        cloudStoreID: syncDestination.cloudStoreIDIfAny,
                        session: session
                    ))
                } catch {
                    session.log("❌ \(deck.name): \(error.localizedDescription)")
                    session.mountError = error.localizedDescription
                    session.errors += 1
                }
            }
        }

        guard !contexts.isEmpty else {
            finishRun(workflow: workflow, session: session)
            return
        }

        // Run one step at a time, fanning each step out across every deck
        // at once — this is what keeps multi-deck control synchronized,
        // e.g. every HyperDeck starts (or stops) recording together instead
        // of one finishing its entire step list before the next begins.
        // Looked up once so the Sync step's "already processed" check knows
        // where a prior run's converted output would have landed, even
        // though Convert runs as a later step against a different context.
        let convertInPlace: Bool = workflow.steps.lazy.compactMap {
            if case .convert(_, _, _, let inPlace) = $0.action { return inPlace }
            return nil
        }.first ?? false

        // Every folder a Create Folder step has made so far in this run, by
        // step ID — what a Trigger Workflow step points at when it's set to
        // run on a created folder.
        var createdFolders: [UUID: URL] = [:]

        var stepIndex = 0
        if let resuming {
            contexts = await restoreContexts(contexts, from: resuming, session: session, mountedPaths: &mountedPaths)
            guard !contexts.isEmpty else {
                finishRun(workflow: workflow, session: session)
                return
            }
            stepIndex = min(resuming.nextStepIndex, workflow.steps.count)
            if case .sync(_, _, let deleteFromDevice)? = resuming.nextStep?.action, deleteFromDevice {
                warnAboutUnconvertedLeftovers(contexts: contexts, convertInPlace: convertInPlace, session: session)
            }
        }

        // Saved before every step (and once more after the last), so a
        // crash costs at most the step that was running — see
        // `WorkflowCheckpointStore`.
        func checkpoint(at index: Int) {
            saveCheckpoint(
                workflow: workflow, targets: checkpointTargets, triggerChain: triggerChain,
                nextStepIndex: index, contexts: contexts, mountedPaths: mountedPaths, session: session
            )
        }

        while stepIndex < workflow.steps.count {
            let step = workflow.steps[stepIndex]
            if !session.isCancelled { checkpoint(at: stepIndex) }
            guard !session.isCancelled else { break }
            await session.waitWhilePaused()
            guard !session.isCancelled else { break }
            if case .notify(_, _, _, let sendPerDrive) = step.action, !sendPerDrive {
                stepIndex += 1
                continue
            }

            // Pipeline a Sync step immediately followed by its Convert step
            // — each device starts converting a file the instant it's
            // downloaded rather than waiting for its whole batch (or for
            // other devices) to finish syncing first. Skipped whenever
            // either step is gated by a confirmation checkpoint, since that
            // checkpoint is a deliberate whole-run pause a person needs to
            // see and approve before conversion starts — pipelining ahead
            // of it would silently bypass that. See `runSyncAndConvert`.
            if case .sync(_, let verifyPair, let deletePair) = step.action,
               stepIndex + 1 < workflow.steps.count,
               case .convert(let preset, let deleteOriginal, let maxParallelJobs, let pairConvertInPlace) = workflow.steps[stepIndex + 1].action,
               !step.requiresConfirmation, !workflow.steps[stepIndex + 1].requiresConfirmation {
                let convertStep = workflow.steps[stepIndex + 1]
                session.beginStep(step.id)
                session.beginStep(convertStep.id)

                contexts = await withTaskGroup(of: StepContext.self) { group in
                    for context in contexts {
                        let takesPart = self.applies(step, to: context.device)
                        group.addTask {
                            var context = context
                            guard takesPart else { return context }
                            context.verifyOffload = verifyPair || deletePair
                            context.deleteAfterOffload = deletePair
                            await self.runSyncAndConvert(
                                context: &context, preset: preset, deleteOriginal: deleteOriginal,
                                maxParallelJobs: maxParallelJobs, convertInPlace: pairConvertInPlace
                            )
                            return context
                        }
                    }
                    var updated: [StepContext] = []
                    for await context in group { updated.append(context) }
                    return updated
                }

                session.endStep(step.id)
                session.endStep(convertStep.id)
                stepIndex += 2
                continue
            }

            if step.requiresConfirmation {
                session.log("⏸ Paused — waiting for confirmation on \"\(step.kind.title)\"")
                session.markAwaitingConfirmation(step.id)
                let shouldContinue = await session.waitForConfirmation(on: step)
                guard shouldContinue else {
                    if !session.isCancelled {
                        session.isCancelled = true
                        session.log("⏹ Workflow stopped — confirmation declined")
                    }
                    break
                }
                session.log("▶️ Confirmed \"\(step.kind.title)\" — continuing")
            }

            session.beginStep(step.id)

            // Create Folder runs once for the whole workflow (like the
            // destination resolution above), not once per device — so it's
            // handled here rather than fanned out through `execute`.
            if case .createFolder(let cloudStoreID, let parentPath, let nameTemplate, let groupByDevice) = step.action {
                do {
                    let folderURL = try await resolveCreateFolder(
                        cloudStoreID: cloudStoreID, parentPath: parentPath, nameTemplate: nameTemplate,
                        session: session, cache: &mountedPaths
                    )
                    session.log("📁 Created folder: \(folderURL.path)")
                    createdFolders[step.id] = folderURL
                    if step.id == referencedFolderStepID {
                        contexts = contexts.map {
                            var context = $0
                            // A Local Folder target always keeps its own
                            // path as destDir — it never adopts a shared
                            // created folder.
                            guard context.device.hyperDeck != nil else { return context }
                            let deviceDestDir = groupByDevice
                                ? folderURL.appendingPathComponent(context.device.name)
                                : folderURL
                            if groupByDevice {
                                try? FileManager.default.createDirectory(at: deviceDestDir, withIntermediateDirectories: true)
                            }
                            context.destDir = deviceDestDir
                            context.cloudStoreID = cloudStoreID
                            return context
                        }
                    }
                } catch {
                    session.log("❌ Failed to create folder: \(error.localizedDescription)")
                    session.errors += 1
                }
                session.endStep(step.id)
                stepIndex += 1
                continue
            }

            // Trigger Workflow runs once for the whole workflow, like Create
            // Folder above — it isn't tied to any one device's files.
            if case .triggerWorkflow(let workflowID, let waitForCompletion, let folder) = step.action {
                await runTriggerWorkflow(
                    workflowID: workflowID, waitForCompletion: waitForCompletion, folder: folder,
                    createdFolders: createdFolders,
                    session: session, triggerChain: triggerChain
                )
                session.endStep(step.id)
                stepIndex += 1
                continue
            }

            contexts = await withTaskGroup(of: StepContext.self) { group in
                for context in contexts {
                    group.addTask {
                        var context = context
                        await self.execute(step, context: &context, convertInPlace: convertInPlace)
                        return context
                    }
                }
                var updated: [StepContext] = []
                for await context in group { updated.append(context) }
                return updated
            }
            session.endStep(step.id)
            stepIndex += 1
        }

        if !session.isCancelled { checkpoint(at: workflow.steps.count) }

        let allProcessedFiles = contexts.flatMap(\.files)

        // Send workflow-wide notifications (single email for the entire workflow)
        let workflowWideNotifySteps = workflow.steps.filter {
            if case .notify(_, _, _, let sendPerDrive) = $0.action {
                return !sendPerDrive
            }
            return false
        }

        if !workflowWideNotifySteps.isEmpty && !session.isCancelled {
            var workflowContext = StepContext(
                device: contexts.first?.device ?? .hyperDeck(HyperDeck(name: "Workflow", ipAddress: "", remotePath: "")),
                destDir: URL(fileURLWithPath: "/dev/null"),
                files: allProcessedFiles,
                session: session
            )
            for step in workflowWideNotifySteps {
                if case .notify(let header, let message, let recipients, _) = step.action {
                    session.beginStep(step.id)
                    await runNotify(context: &workflowContext, header: header, message: message, recipients: recipients)
                    session.endStep(step.id)
                }
            }
        }

        finishRun(workflow: workflow, session: session)
    }

    /// Stops every run currently in progress.
    func stop() {
        for session in appState.activeRuns where !session.isFinished {
            stop(session)
        }
    }

    /// Stops just one run, leaving any other concurrent runs untouched.
    func stop(_ session: WorkflowRunSession) {
        session.isCancelled = true
        session.log("⏹ Workflow stopped by user")
        // Release a paused confirmation prompt or a user pause, if either is
        // active, so the run doesn't hang forever waiting for a response
        // that will never come.
        session.resolveConfirmation(proceed: false)
        session.releasePause()
    }

    // MARK: - Retry failed tasks
    // Re-downloads and re-converts whichever files errored out on a previous
    // run, using each task's own remembered destination (its Cloud Store, or
    // the shared global destination) and the app's current conversion
    // settings. Gets its own session like any other run, so it's blocked
    // only if one of those specific decks is already busy elsewhere.

    /// Groups failed tasks that share both a device and a destination, since
    /// two failed tasks for the same deck can come from different workflow
    /// runs (and therefore different Sync-step destinations).
    private struct RetryGroupKey: Hashable {
        let deckName: String
        let destDir: URL
        let cloudStoreID: UUID?
    }

    func retryFailed() async {
        let failed = appState.failedTasks
        guard !failed.isEmpty else { return }

        let deckNames = Set(failed.map(\.deckName))
        guard appState.busyDeckNames.isDisjoint(with: deckNames) else { return }

        let workflow = Workflow(name: "Retry Failed")
        let session = appState.beginRun(for: workflow, deckNames: deckNames)
        session.log("↩ Retrying \(failed.count) failed file(s)...")

        var mountedPaths: [UUID?: String] = [:]
        let byDeck = Dictionary(grouping: failed) {
            RetryGroupKey(deckName: $0.deckName, destDir: $0.destDir, cloudStoreID: $0.cloudStoreID)
        }

        for (key, tasks) in byDeck {
            guard let device = resolveTargetDevice(named: key.deckName) else { continue }
            let destDir = key.destDir

            switch device {
            case .hyperDeck(let deck):
                // The exact folder is already known (key.destDir, including
                // any dynamically-dated name it was given when first
                // created) — all that's needed here is to make sure its
                // volume is mounted.
                do {
                    _ = try await mountBase(cloudStoreID: key.cloudStoreID, session: session, cache: &mountedPaths)
                } catch {
                    session.log("❌ \(deck.name): \(error.localizedDescription)")
                    session.mountError = error.localizedDescription
                    session.errors += 1
                    continue
                }
                try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

                var toConvert: [URL] = []

                for task in tasks {
                    resetTask(id: task.id)
                    let destURL = destDir.appendingPathComponent(task.fileName)
                    try? FileManager.default.removeItem(at: destURL)

                    let result = await FTPService.downloadFile(
                        named: task.fileName, from: deck, to: destURL
                    ) { [weak self] pct in Task { @MainActor in self?.updateTask(id: task.id, syncProgress: pct) } }

                    if result.success {
                        updateTask(id: task.id, phase: .converting, syncProgress: 1)
                        toConvert.append(destURL)
                    } else {
                        let reason = result.failureReason ?? "unknown error"
                        updateTask(id: task.id, phase: .error, errorMessage: "Retry failed: \(reason)")
                        session.log("  ❌ Retry failed: \(task.fileName) (\(reason))")
                        session.errors += 1
                    }
                }

                if !toConvert.isEmpty {
                    var context = StepContext(device: device, destDir: destDir, files: toConvert, session: session)
                    await runConvert(context: &context, preset: .fast, deleteOriginal: true, maxParallelJobs: 2, convertInPlace: false)
                }

            case .localFolder, .cloudStore:
                // A folder-sourced failure (Local Folder or Cloud Store
                // Folder) can only ever be a conversion failure — the file
                // was never downloaded, it was already sitting in the
                // folder — so "retry" here means re-convert in place, not
                // re-download. A Cloud Store Folder's store still needs
                // (re-)mounting first, since it may no longer be mounted
                // from a previous run.
                if case .cloudStore = device {
                    do {
                        _ = try await mountBase(cloudStoreID: key.cloudStoreID, session: session, cache: &mountedPaths)
                    } catch {
                        session.log("❌ \(key.deckName): \(error.localizedDescription)")
                        session.mountError = error.localizedDescription
                        session.errors += 1
                        continue
                    }
                }
                var toConvert: [URL] = []
                for task in tasks {
                    resetTask(id: task.id)
                    let fileURL = destDir.appendingPathComponent(task.fileName)
                    guard FileManager.default.fileExists(atPath: fileURL.path) else {
                        updateTask(id: task.id, phase: .error, errorMessage: "Retry failed: file no longer in folder")
                        session.log("  ❌ Retry failed: \(task.fileName) is no longer in \(key.deckName)")
                        session.errors += 1
                        continue
                    }
                    updateTask(id: task.id, phase: .converting, syncProgress: 1)
                    toConvert.append(fileURL)
                }

                if !toConvert.isEmpty {
                    var context = StepContext(device: device, destDir: destDir, files: toConvert, session: session)
                    await runConvert(context: &context, preset: .fast, deleteOriginal: true, maxParallelJobs: 2, convertInPlace: false)
                }
            }
        }

        session.log("↩ Retry complete")
        finishRun(workflow: workflow, session: session)
        appState.pruneCleanSessions()
    }

    // MARK: - Step dispatch

    /// A deck step only touches the HyperDecks it names. Folders always
    /// take part — each deck step knows what it means for a folder (Offload
    /// picks up the files already there; the others skip it).
    private func applies(_ step: WorkflowStep, to device: WorkflowTargetDevice) -> Bool {
        guard step.kind.usesHyperDeck, let deck = device.hyperDeck else { return true }
        return step.decks.includes(deck.id)
    }

    private func execute(_ step: WorkflowStep, context: inout StepContext, convertInPlace: Bool) async {
        guard applies(step, to: context.device) else { return }
        switch step.action {
        case .controlDeck(let command):
            await runControlDeck(context: &context, command: command)
        case .wait(let minutes):
            await runWait(minutes: minutes, session: context.session)
        case .createFolder:
            break // handled once per run, before the per-deck fan-out — see `start`
        case .triggerWorkflow:
            break // handled once per run, before the per-deck fan-out — see `start`
        case .sync(_, let verify, let deleteFromDevice):
            // Removing an original is only safe against a verified copy.
            context.verifyOffload = verify || deleteFromDevice
            context.deleteAfterOffload = deleteFromDevice
            // The destination for this step (from the workflow's Sync step
            // config) is already resolved into context.destDir before the
            // run loop begins. `convertInPlace` here is the *workflow's*
            // Convert step setting (looked up ahead of time in `start`), so
            // the "already processed" check below knows where a prior run's
            // output would have landed even though Convert hasn't run yet.
            await runSync(context: &context, convertInPlace: convertInPlace)
        case .convert(let preset, let deleteOriginal, let maxParallelJobs, let convertInPlace):
            await runConvert(context: &context, preset: preset, deleteOriginal: deleteOriginal, maxParallelJobs: maxParallelJobs, convertInPlace: convertInPlace)
        case .rename(let pattern):
            runRename(context: &context, pattern: pattern)
        case .transcribe(let locale, let writeSRT, let skipExisting, let deleteWhenDone):
            await runTranscribe(context: &context, locale: locale, writeSRT: writeSRT, skipExisting: skipExisting, deleteWhenDone: deleteWhenDone)
        case .findClips(let maxClips, let minSeconds, let maxSeconds, let focus):
            await runFindClips(context: &context, maxClips: maxClips, minSeconds: minSeconds, maxSeconds: maxSeconds, focus: focus)
        case .exportPosts(let format, let captions):
            await runExportPosts(context: &context, format: format, captions: captions)
        case .queueClips(let minScore):
            runQueueClips(context: &context, minScore: minScore)
        case .upload:
            context.session.log("  ⏭ Upload: uploading is coming soon — this step was skipped")
        case .writeCopy(let platform, let hashtagCount):
            await runWriteCopy(context: &context, platform: platform, hashtagCount: hashtagCount)
        case .webhook(let url, let format):
            await runWebhook(context: &context, url: url, format: format)
        case .copyTo(let destination, let verify, let includeSidecars):
            await runCopyTo(context: &context, destination: destination, verify: verify, includeSidecars: includeSidecars)
        case .reframe(let format, let followSubject):
            await runReframe(context: &context, format: format, followSubject: followSubject)
        case .format:
            await runFormat(context: &context)
        case .cleanup(let retentionDays):
            await runCleanup(context: &context, retentionDays: retentionDays)
        case .notify(let header, let message, let recipients, _):
            await runNotify(context: &context, header: header, message: message, recipients: recipients)
        }
    }

    // MARK: - Sync step

    private func runSync(context: inout StepContext, convertInPlace: Bool) async {
        switch context.device {
        case .hyperDeck(let deck):
            await runSyncFromDeck(context: &context, deck: deck, convertInPlace: convertInPlace)
        case .localFolder, .cloudStore:
            await runSyncInPlace(context: &context, convertInPlace: convertInPlace)
        }
    }

    /// The deck's `.mov` files, minus the one it's recording right now. A
    /// clip still being written can't be offloaded safely — it would copy
    /// half-written (or fail verification) — so while the deck is recording,
    /// the newest file is left alone; a later run picks it up once it's
    /// finished. Recording state is read both before and after listing, so a
    /// recording that starts mid-scan is still caught.
    private func listFinishedClips(on deck: HyperDeck, session: WorkflowRunSession) async -> [FTPService.FTPEntry] {
        let recordingBefore = await HyperDeckService.isRecording(host: deck.ipAddress)
        let files = await FTPService.listMovFiles(on: deck)
        let recordingAfter = recordingBefore ? true : await HyperDeckService.isRecording(host: deck.ipAddress)

        // The listing carries no modification dates, so "newest" is the
        // highest file name — HyperDeck numbers clips sequentially.
        guard recordingAfter,
              let inProgress = files.max(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) else {
            return files
        }
        session.log("  ⏺ \(deck.name) is recording — leaving \(inProgress.name) for a later run")
        return files.filter { $0.name != inProgress.name }
    }

    /// Removes an original from the deck after its copy has been verified.
    /// A failure leaves the file where it is and is reported as an error, so
    /// it's clear the space wasn't freed.
    private func removeFromDevice(fileName: String, deck: HyperDeck, session: WorkflowRunSession) async {
        let removed = await FTPService.deleteEntry(atRelativePath: fileName, isDirectory: false, on: deck)
        if removed {
            session.log("  🗑 Removed \(fileName) from \(deck.name)")
        } else {
            session.log("  ⚠️ Copied \(fileName), but couldn't remove it from \(deck.name)")
            session.errors += 1
        }
    }

    private func runSyncFromDeck(context: inout StepContext, deck: HyperDeck, convertInPlace: Bool) async {
        let session = context.session
        session.log("  📡 Scanning \(deck.name) (\(deck.ipAddress))...")

        let remoteFiles = await listFinishedClips(on: deck, session: session)
        guard !remoteFiles.isEmpty else {
            session.log("  \(deck.name): no .mov files found")
            return
        }
        session.log("  \(deck.name): \(remoteFiles.count) file(s) found")

        // Queue every file needing a download up front (with its known size)
        // before downloading any of them. Files download one at a time, but
        // pre-queuing the rest lets the UI show what's still waiting and
        // lets the run-level ETA account for the full remaining queue, not
        // just whichever file happens to be downloading right now.
        var queue: [(entry: FTPService.FTPEntry, destURL: URL, taskID: UUID)] = []
        for entry in remoteFiles {
            let fileName = entry.name
            let destURL = context.destDir.appendingPathComponent(fileName)
            let convertedDir = convertInPlace ? context.destDir : context.destDir.appendingPathComponent("Converted")
            let convertedURL = convertedDir
                .appendingPathComponent((fileName as NSString).deletingPathExtension + ".mp4")

            if FileManager.default.fileExists(atPath: convertedURL.path) {
                session.log("  ⏭ \(fileName) already processed")
                session.skipped += 1
                continue
            }

            let task = addTask(
                fileName: fileName, deckName: deck.name,
                destDir: context.destDir, cloudStoreID: context.cloudStoreID,
                fileSizeBytes: entry.size,
                in: session
            )
            queue.append((entry, destURL, task.id))
        }

        for (entry, destURL, taskID) in queue {
            guard !session.isCancelled else { return }

            updateTask(id: taskID, phase: .downloading, syncProgress: 0)
            session.log("  ⬇ Downloading \(entry.name)...")

            // FTPService.downloadFile already retries transient failures
            // internally (dropped connection, stalled transfer), cleaning up
            // any partial file between attempts — so a single call here
            // already reflects the outcome after those retries.
            let result = await FTPService.downloadFile(
                named: entry.name, from: deck, to: destURL
            ) { [weak self] pct in Task { @MainActor in self?.updateTask(id: taskID, syncProgress: pct) } }

            guard result.success else {
                let reason = result.failureReason ?? "unknown error"
                updateTask(id: taskID, phase: .error, errorMessage: "Download failed after retries: \(reason)")
                session.log("  ❌ Download failed: \(entry.name) — \(reason)")
                session.errors += 1
                continue
            }

            if context.verifyOffload {
                let ok = await verifyCopy(taskID: taskID, fileName: entry.name, deck: deck, destURL: destURL, session: session)
                guard ok else { continue }
            }

            if context.deleteAfterOffload {
                await removeFromDevice(fileName: entry.name, deck: deck, session: session)
            }

            updateTask(id: taskID, phase: .done, syncProgress: 1)
            session.log("  ✅ Downloaded \(entry.name)")
            context.files.append(destURL)
        }
    }

    /// A Local Folder or Cloud Store Folder target has no download step —
    /// the folder is both source and working directory (a Cloud Store
    /// Folder's store is already mounted into `context.destDir` by the time
    /// this runs). "Sync" for either just means finding files already
    /// sitting there that haven't been processed yet, using the same
    /// "already has a converted output" check as the HyperDeck path, so
    /// re-running such a workflow is just as idempotent as re-running a
    /// deck one.
    private func runSyncInPlace(context: inout StepContext, convertInPlace: Bool) async {
        let session = context.session
        let name = context.device.name
        session.log("  📂 Scanning \(name) (\(context.destDir.path))...")

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: context.destDir, includingPropertiesForKeys: nil) else {
            session.log("  ❌ \(name): couldn't read folder contents")
            session.errors += 1
            return
        }

        let convertibleFiles = entries
            .filter { ConversionService.canConvert(url: $0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !convertibleFiles.isEmpty else {
            session.log("  \(name): no convertible files found")
            return
        }
        session.log("  \(name): \(convertibleFiles.count) file(s) found")

        for fileURL in convertibleFiles {
            guard !session.isCancelled else { return }

            let fileName = fileURL.lastPathComponent
            let convertedDir = convertInPlace ? context.destDir : context.destDir.appendingPathComponent("Converted")
            let convertedURL = convertedDir
                .appendingPathComponent((fileName as NSString).deletingPathExtension + ".mp4")

            if fm.fileExists(atPath: convertedURL.path) {
                session.log("  ⏭ \(fileName) already processed")
                session.skipped += 1
                continue
            }

            let fileSize = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int64
            let task = addTask(
                fileName: fileName, deckName: name,
                destDir: context.destDir, cloudStoreID: context.cloudStoreID,
                fileSizeBytes: fileSize ?? 0,
                in: session
            )
            // The file is already local — there's no download phase.
            updateTask(id: task.id, phase: .done, syncProgress: 1)
            session.log("  📄 Found \(fileName) in \(name)")
            context.files.append(fileURL)
        }
    }

    // MARK: - Convert step

    private func runConvert(context: inout StepContext, preset: ConversionSettings.FFmpegPreset, deleteOriginal: Bool, maxParallelJobs: Int, convertInPlace: Bool) async {
        let session = context.session
        guard !context.files.isEmpty else {
            session.log("  ⏭ Convert: no files to convert")
            return
        }

        let settings = ConversionSettings(preset: preset)

        let convertedDir = convertInPlace ? context.destDir : context.destDir.appendingPathComponent("Converted")
        try? FileManager.default.createDirectory(at: convertedDir, withIntermediateDirectories: true)

        let maxJobs = maxParallelJobs
        let batches = stride(from: 0, to: context.files.count, by: maxJobs).map {
            Array(context.files[$0 ..< min($0 + maxJobs, context.files.count)])
        }

        let deckName = context.device.name
        var convertedFiles: [URL] = []

        for batch in batches {
            guard !session.isCancelled else { break }

            let results: [(input: URL, output: URL, outcome: ConversionOutcome)] = await withTaskGroup(of: (URL, URL, ConversionOutcome).self) { group in
                for inputURL in batch {
                    group.addTask {
                        let fileName  = inputURL.lastPathComponent
                        let outputURL = convertedDir.appendingPathComponent(
                            (fileName as NSString).deletingPathExtension + ".mp4"
                        )
                        let taskID = await MainActor.run {
                            self.taskID(forFileName: fileName, deckName: deckName)
                        }

                        // Waits for a global slot (shared across every
                        // device converting in this run, not just this
                        // one's own maxParallelJobs) before actually
                        // starting the encode — see ConversionSlotLimiter.
                        // The "Converting" status only appears once the
                        // slot is granted, so it reflects a task actually
                        // running rather than one still queued behind it.
                        await ConversionSlotLimiter.shared.acquire()
                        await MainActor.run {
                            session.log("  🎬 Converting \(fileName) (\(deckName))...")
                            if let id = taskID { self.updateTask(id: id, phase: .converting, convertProgress: 0) }
                        }

                        let outcome = await ConversionService.convert(
                            input: inputURL, output: outputURL, settings: settings
                        ) { pct in
                            if let id = taskID {
                                Task { @MainActor in self.updateTask(id: id, convertProgress: pct) }
                            }
                        }
                        await ConversionSlotLimiter.shared.release()

                        await MainActor.run {
                            switch outcome {
                            case .success:
                                if let id = taskID { self.updateTask(id: id, phase: .done, convertProgress: 1) }
                            case .failure:
                                if let id = taskID { self.updateTask(id: id, phase: .error, errorMessage: "Conversion failed") }
                            case .diskFull:
                                if let id = taskID { self.updateTask(id: id, phase: .error, errorMessage: "Destination drive full") }
                            }
                        }
                        return (inputURL, outputURL, outcome)
                    }
                }
                var collected: [(URL, URL, ConversionOutcome)] = []
                for await result in group { collected.append(result) }
                return collected
            }

            var diskFullDetected = false
            for (input, output, outcome) in results {
                switch outcome {
                case .success:
                    session.log("  ✅ Converted → \(output.lastPathComponent) (\(deckName))")
                    session.converted += 1
                    convertedFiles.append(output)
                    if deleteOriginal { try? FileManager.default.removeItem(at: input) }
                case .failure:
                    session.log("  ❌ Conversion failed: \(input.lastPathComponent) (\(deckName))")
                    session.errors += 1
                    if !deleteOriginal { convertedFiles.append(input) }
                case .diskFull:
                    session.log("  🛑 Destination drive is full — stopping (\(input.lastPathComponent), \(deckName))")
                    session.errors += 1
                    diskFullDetected = true
                }
            }

            if diskFullDetected {
                session.isCancelled = true
                session.log("⏹ Workflow stopped — destination drive is full")
                NotificationService.sendDeviceAlert(
                    title: "Canopy: Destination Drive Full",
                    body: "Sync to \(deckName) was stopped because the destination drive ran out of space. Free up space and run it again."
                )
                break
            }
        }

        context.files = convertedFiles
    }

    // MARK: - Pipelined Sync + Convert
    //
    // Used when a workflow's Sync step is immediately followed by its
    // Convert step with neither gated by a confirmation checkpoint (see the
    // run loop in `start`). A Cloud Store Folder / Local Folder source has
    // no download phase to overlap with anything, so it just lists what's
    // already there and converts it with the same batched `runConvert`
    // logic as before — it only gains the cross-device barrier removal, for
    // free, by being inside the same combined task group as every other
    // device. A HyperDeck source gets the full pipeline below.
    private func runSyncAndConvert(
        context: inout StepContext,
        preset: ConversionSettings.FFmpegPreset,
        deleteOriginal: Bool,
        maxParallelJobs: Int,
        convertInPlace: Bool
    ) async {
        switch context.device {
        case .hyperDeck(let deck):
            await runPipelinedDeckSyncAndConvert(
                context: &context, deck: deck, preset: preset, deleteOriginal: deleteOriginal,
                maxParallelJobs: maxParallelJobs, convertInPlace: convertInPlace
            )
        case .localFolder, .cloudStore:
            await runSyncInPlace(context: &context, convertInPlace: convertInPlace)
            await runConvert(
                context: &context, preset: preset, deleteOriginal: deleteOriginal,
                maxParallelJobs: maxParallelJobs, convertInPlace: convertInPlace
            )
        }
    }

    /// One file queued for the pipeline below, carrying its original
    /// position so `context.files` can be reassembled in source order
    /// afterward — task-group completion order doesn't match spawn order,
    /// and `runRename` numbers files by their position in `context.files`.
    private struct PipelineDownload: Sendable {
        let index: Int
        let entry: FTPService.FTPEntry
        let destURL: URL
        let taskID: UUID
    }

    private enum PipelineFileOutcome {
        case converted(index: Int, url: URL)
        case keptOriginal(index: Int, url: URL)
        case droppedAfterFailure
        case diskFull
    }

    /// Downloads a HyperDeck's queued files one at a time — still a single
    /// FTP connection, same as always — but hands each off to conversion
    /// the moment it lands instead of waiting for the rest of the batch.
    /// Conversion is bounded both by this device's own `maxParallelJobs`
    /// and by the app-wide `ConversionSlotLimiter` shared across every
    /// device converting in this run.
    private func runPipelinedDeckSyncAndConvert(
        context: inout StepContext,
        deck: HyperDeck,
        preset: ConversionSettings.FFmpegPreset,
        deleteOriginal: Bool,
        maxParallelJobs: Int,
        convertInPlace: Bool
    ) async {
        let session = context.session
        session.log("  📡 Scanning \(deck.name) (\(deck.ipAddress))...")

        let remoteFiles = await listFinishedClips(on: deck, session: session)
        guard !remoteFiles.isEmpty else {
            session.log("  \(deck.name): no .mov files found")
            return
        }
        session.log("  \(deck.name): \(remoteFiles.count) file(s) found")

        let convertedDir = convertInPlace ? context.destDir : context.destDir.appendingPathComponent("Converted")
        try? FileManager.default.createDirectory(at: convertedDir, withIntermediateDirectories: true)

        var downloads: [PipelineDownload] = []
        for entry in remoteFiles {
            let fileName = entry.name
            let destURL = context.destDir.appendingPathComponent(fileName)
            let convertedURL = convertedDir.appendingPathComponent((fileName as NSString).deletingPathExtension + ".mp4")

            if FileManager.default.fileExists(atPath: convertedURL.path) {
                session.log("  ⏭ \(fileName) already processed")
                session.skipped += 1
                continue
            }

            let task = addTask(
                fileName: fileName, deckName: deck.name,
                destDir: context.destDir, cloudStoreID: context.cloudStoreID,
                fileSizeBytes: entry.size,
                in: session
            )
            downloads.append(PipelineDownload(index: downloads.count, entry: entry, destURL: destURL, taskID: task.id))
        }
        guard !downloads.isEmpty else { return }

        // Copied to an immutable local — `downloads` itself is never
        // mutated again, but the producer closure below needs to capture
        // something Swift's concurrency checker can prove isn't still
        // reachable from this MainActor-isolated method after that.
        let downloadQueue = downloads
        let queue = PipelineQueue<PipelineDownload>()
        let deckName = deck.name
        let settings = ConversionSettings(preset: preset)
        let verifyDownloads = context.verifyOffload
        let deleteAfterOffload = context.deleteAfterOffload

        let outcomes: [PipelineFileOutcome] = await withTaskGroup(of: [PipelineFileOutcome].self) { group in
            // Producer: downloads each file in order, pushing it to the
            // convert queue as soon as it succeeds. A download failure is
            // logged and skipped, same as the non-pipelined path.
            group.addTask {
                for item in downloadQueue {
                    let cancelled = await MainActor.run { session.isCancelled }
                    guard !cancelled else { break }

                    await MainActor.run {
                        self.updateTask(id: item.taskID, phase: .downloading, syncProgress: 0)
                        session.log("  ⬇ Downloading \(item.entry.name)...")
                    }

                    let result = await FTPService.downloadFile(
                        named: item.entry.name, from: deck, to: item.destURL
                    ) { pct in Task { @MainActor in self.updateTask(id: item.taskID, syncProgress: pct) } }

                    guard result.success else {
                        let reason = result.failureReason ?? "unknown error"
                        await MainActor.run {
                            self.updateTask(id: item.taskID, phase: .error, errorMessage: "Download failed after retries: \(reason)")
                            session.log("  ❌ Download failed: \(item.entry.name) — \(reason)")
                            session.errors += 1
                        }
                        continue
                    }

                    if verifyDownloads {
                        let ok = await self.verifyCopy(
                            taskID: item.taskID, fileName: item.entry.name, deck: deck,
                            destURL: item.destURL, session: session
                        )
                        guard ok else { continue }
                    }

                    if deleteAfterOffload {
                        await self.removeFromDevice(fileName: item.entry.name, deck: deck, session: session)
                    }

                    await MainActor.run {
                        self.updateTask(id: item.taskID, syncProgress: 1)
                        session.log("  ✅ Downloaded \(item.entry.name)")
                    }
                    await queue.push(item)
                }
                await queue.finish()
                return []
            }

            // Consumers: up to maxParallelJobs, each pulling the next
            // downloaded file and converting it.
            for _ in 0..<max(1, maxParallelJobs) {
                group.addTask {
                    var results: [PipelineFileOutcome] = []
                    while let item = await queue.next() {
                        let cancelled = await MainActor.run { session.isCancelled }
                        guard !cancelled else { break }

                        let outputURL = convertedDir.appendingPathComponent(
                            (item.entry.name as NSString).deletingPathExtension + ".mp4"
                        )

                        await ConversionSlotLimiter.shared.acquire()
                        await MainActor.run {
                            session.log("  🎬 Converting \(item.entry.name) (\(deckName))...")
                            self.updateTask(id: item.taskID, phase: .converting, convertProgress: 0)
                        }

                        let outcome = await ConversionService.convert(
                            input: item.destURL, output: outputURL, settings: settings
                        ) { pct in Task { @MainActor in self.updateTask(id: item.taskID, convertProgress: pct) } }
                        await ConversionSlotLimiter.shared.release()

                        await MainActor.run {
                            switch outcome {
                            case .success:
                                self.updateTask(id: item.taskID, phase: .done, convertProgress: 1)
                                session.log("  ✅ Converted → \(outputURL.lastPathComponent) (\(deckName))")
                                session.converted += 1
                                if deleteOriginal { try? FileManager.default.removeItem(at: item.destURL) }
                                results.append(.converted(index: item.index, url: outputURL))
                            case .failure:
                                self.updateTask(id: item.taskID, phase: .error, errorMessage: "Conversion failed")
                                session.log("  ❌ Conversion failed: \(item.entry.name) (\(deckName))")
                                session.errors += 1
                                results.append(deleteOriginal ? .droppedAfterFailure : .keptOriginal(index: item.index, url: item.destURL))
                            case .diskFull:
                                self.updateTask(id: item.taskID, phase: .error, errorMessage: "Destination drive full")
                                session.log("  🛑 Destination drive is full — stopping (\(item.entry.name), \(deckName))")
                                session.errors += 1
                                results.append(.diskFull)
                                if !session.isCancelled {
                                    session.isCancelled = true
                                    session.log("⏹ Workflow stopped — destination drive is full")
                                    NotificationService.sendDeviceAlert(
                                        title: "Canopy: Destination Drive Full",
                                        body: "Sync to \(deckName) was stopped because the destination drive ran out of space. Free up space and run it again."
                                    )
                                }
                            }
                        }
                    }
                    return results
                }
            }

            var collected: [PipelineFileOutcome] = []
            for await results in group { collected += results }
            return collected
        }

        context.files = outcomes
            .compactMap { outcome -> (index: Int, url: URL)? in
                switch outcome {
                case .converted(let index, let url):   return (index, url)
                case .keptOriginal(let index, let url): return (index, url)
                case .droppedAfterFailure, .diskFull:   return nil
                }
            }
            .sorted { $0.index < $1.index }
            .map(\.url)
    }

    // MARK: - Rename step

    private func runRename(context: inout StepContext, pattern: String) {
        let session = context.session
        guard !context.files.isEmpty else {
            session.log("  ⏭ Rename: no files to rename")
            return
        }

        var renamed: [URL] = []

        for (index, url) in context.files.enumerated() {
            let ext = url.pathExtension
            let originalName = (url.lastPathComponent as NSString).deletingPathExtension

            let newName = RenamePatternEngine.apply(
                pattern: pattern,
                originalName: originalName,
                deviceName: context.device.name,
                index: index + 1,
                projectName: appState.shoot.name,
                cameraLabel: appState.shoot.cameraLabel(for: context.device.name)
            )
            let newURL = url.deletingLastPathComponent().appendingPathComponent("\(newName).\(ext)")

            do {
                if FileManager.default.fileExists(atPath: newURL.path) {
                    try FileManager.default.removeItem(at: newURL)
                }
                try FileManager.default.moveItem(at: url, to: newURL)
                session.log("  ✏️ Renamed → \(newURL.lastPathComponent) (\(context.device.name))")
                renamed.append(newURL)
            } catch {
                session.log("  ❌ Rename failed for \(url.lastPathComponent) (\(context.device.name)): \(error.localizedDescription)")
                session.errors += 1
                renamed.append(url)
            }
        }

        context.files = renamed
    }

    // MARK: - Transcribe step

    private func runTranscribe(context: inout StepContext, locale: String, writeSRT: Bool, skipExisting: Bool, deleteWhenDone: Bool) async {
        let session = context.session

        // Nothing handed down from an earlier step (e.g. a workflow that is
        // only Transcribe, pointed at a folder): scan the target folder
        // itself. Not for a HyperDeck, whose destDir is only a placeholder
        // until an Offload step runs.
        var files = context.files
        if files.isEmpty, context.device.hyperDeck == nil {
            session.log("  📂 Scanning \(context.device.name) (\(context.destDir.path)) for clips...")
            files = ((try? FileManager.default.contentsOfDirectory(at: context.destDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { ConversionService.canConvert(url: $0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard !files.isEmpty else {
            session.log("  ⏭ Transcribe: no video files found in \(context.device.name)")
            return
        }

        for url in files {
            if session.isCancelled { return }
            if skipExisting, Transcript.load(for: url) != nil {
                session.log("  ⏭ \(url.lastPathComponent) already has a transcript")
                continue
            }
            session.log("  🗣 Transcribing \(url.lastPathComponent) (\(context.device.name))...")
            do {
                let transcript = try await TranscriptionService.transcribe(video: url, localeID: locale)
                try transcript.write(for: url)
                if deleteWhenDone { session.transcriptFilesToDelete.insert(Transcript.sidecarURL(for: url)) }
                if writeSRT {
                    try transcript.writeSRT(for: url)
                    if deleteWhenDone { session.transcriptFilesToDelete.insert(Transcript.srtURL(for: url)) }
                }
                session.log("  📝 Transcript ready: \(transcript.segments.count) segment(s), \(transcript.fullText.split(separator: " ").count) word(s)")
            } catch {
                session.log("  ❌ Transcribe failed for \(url.lastPathComponent): \(error.localizedDescription)")
                session.errors += 1
            }
        }
    }

    // MARK: - Find Clips step

    /// Suggests short-form clips for each video and saves them next to it as
    /// `<name>.clips.json`. Transcribes first when there's no transcript yet.
    private func runFindClips(context: inout StepContext, maxClips: Int, minSeconds: Int, maxSeconds: Int,
                              focus: ClipFocus) async {
        let session = context.session

        var files = context.files
        if files.isEmpty, context.device.hyperDeck == nil {
            session.log("  📂 Scanning \(context.device.name) (\(context.destDir.path)) for clips...")
            files = ((try? FileManager.default.contentsOfDirectory(at: context.destDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { ConversionService.canConvert(url: $0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard !files.isEmpty else {
            session.log("  ⏭ Find Clips: no video files found in \(context.device.name)")
            return
        }

        var options = ClipFinderOptions()
        options.maxClips = maxClips
        options.minDuration = TimeInterval(minSeconds)
        options.maxDuration = TimeInterval(max(maxSeconds, minSeconds))
        options.focus = focus
        if !focus.isEmpty { session.log("  🔎 Looking for \(focus.summary)") }

        for url in files {
            if session.isCancelled { return }
            do {
                var transcript = Transcript.load(for: url)
                // Suggestions found for something else don't answer this step.
                if let saved = ClipSuggestions.load(for: url), (saved.focus ?? ClipFocus()) == focus {
                    session.log("  ⏭ \(url.lastPathComponent) already has clip suggestions")
                } else {
                    if transcript == nil {
                        session.log("  🗣 Transcribing \(url.lastPathComponent) first (\(context.device.name))...")
                        let made = try await TranscriptionService.transcribe(video: url, localeID: Locale.current.identifier)
                        try made.write(for: url)
                        transcript = made
                    }
                    // Music can be found without any words to go on.
                    guard let transcript, !transcript.segments.isEmpty || focus.kinds.contains(.music) else {
                        session.log("  ⏭ \(url.lastPathComponent): no speech found")
                        continue
                    }
                    session.log("  ✨ Finding clips in \(url.lastPathComponent) (\(context.device.name))...")
                    let clips = try await ClipFinder.findClips(in: transcript, video: url, options: options,
                                                               log: { session.log("  \($0)") })
                    try ClipSuggestions(sourceFileName: url.lastPathComponent, generatedAt: Date(), candidates: clips,
                                        focus: focus.isEmpty ? nil : focus).write(for: url)
                    session.log("  🎬 \(clips.count) clip suggestion(s) for \(url.lastPathComponent)")
                    for clip in clips {
                        session.log("     • \(clip.title) (\(Int(clip.duration))s)")
                    }
                }

            } catch {
                session.log("  ❌ Find Clips failed for \(url.lastPathComponent): \(error.localizedDescription)")
                session.errors += 1
            }
        }
    }

    // MARK: - Export Posts step

    /// Renders each video's suggested clips as finished posts in a
    /// `Social Posts` folder next to the video. Posts that already exist are
    /// left alone.
    private func runExportPosts(context: inout StepContext, format exportFormat: SocialFormat, captions: Bool) async {
        let session = context.session
        let files = workingVideos(for: context)
        guard !files.isEmpty else {
            session.log("  ⏭ Export Posts: no video files found in \(context.device.name)")
            return
        }

        for url in files {
            if session.isCancelled { return }
            guard let suggestions = ClipSuggestions.load(for: url) else {
                session.log("  ⏭ \(url.lastPathComponent): no clip suggestions — add a Find Clips step before this one")
                continue
            }
            let clips = suggestions.candidates
            guard !clips.isEmpty else { continue }
            let transcript = Transcript.load(for: url)

            let folder = url.deletingLastPathComponent().appendingPathComponent("Social Posts")
            let base = url.deletingPathExtension().lastPathComponent
            var postOptions = SocialPostExporter.Options()
            postOptions.format = exportFormat
            postOptions.captions = captions
            for (i, clip) in clips.sorted(by: { $0.start < $1.start }).enumerated() {
                if session.isCancelled { return }
                let output = folder.appendingPathComponent(
                    SocialPostExporter.fileName(base: base, index: i + 1, title: clip.title, format: exportFormat)
                )
                if FileManager.default.fileExists(atPath: output.path) {
                    session.log("  ⏭ \(output.lastPathComponent) already exists")
                    continue
                }
                session.log("  📱 Rendering \(output.lastPathComponent)...")
                do {
                    try await SocialPostExporter.export(source: url, clip: clip, transcript: transcript, options: postOptions, output: output)
                    session.log("  ✅ Social Posts/\(output.lastPathComponent)")
                } catch ReframeError.diskFull {
                    session.log("  🛑 Destination drive is full — stopping (\(url.lastPathComponent), \(context.device.name))")
                    session.errors += 1
                    session.isCancelled = true
                    return
                } catch {
                    session.log("  ❌ Couldn't render \(output.lastPathComponent): \(error.localizedDescription)")
                    session.errors += 1
                }
            }
        }
    }

    // MARK: - Shared: which videos a step works on

    /// The working set handed down from earlier steps; failing that, for a
    /// target that's a real folder, the video files in it. (A HyperDeck's
    /// destDir is only a placeholder until Offload runs.)
    private func workingVideos(for context: StepContext) -> [URL] {
        if !context.files.isEmpty { return context.files }
        guard context.device.hyperDeck == nil else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: context.destDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ConversionService.canConvert(url: $0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Write Post Copy step

    /// Drafts a title, caption and hashtags for each suggested clip and saves
    /// them back into the video's clip suggestions. Clips that already have
    /// copy are left alone.
    private func runWriteCopy(context: inout StepContext, platform: CopyPlatform, hashtagCount: Int) async {
        let session = context.session
        let files = workingVideos(for: context)
        guard !files.isEmpty else {
            session.log("  ⏭ Write Post Copy: no video files found in \(context.device.name)")
            return
        }

        for url in files {
            if session.isCancelled { return }
            guard var suggestions = ClipSuggestions.load(for: url) else {
                session.log("  ⏭ \(url.lastPathComponent): no clip suggestions — add a Find Clips step before this one")
                continue
            }
            guard let transcript = Transcript.load(for: url) else {
                session.log("  ⏭ \(url.lastPathComponent): no transcript to write copy from")
                continue
            }

            var written = 0
            for index in suggestions.candidates.indices where suggestions.candidates[index].copy == nil {
                if session.isCancelled { return }
                let clip = suggestions.candidates[index]
                do {
                    suggestions.candidates[index].copy = try await PostCopyWriter.write(
                        for: clip, transcript: transcript, platform: platform, hashtagCount: hashtagCount
                    )
                    written += 1
                } catch {
                    session.log("  ❌ Couldn't write copy for \"\(clip.title)\": \(error.localizedDescription)")
                    session.errors += 1
                }
            }
            if written > 0 {
                do { try suggestions.write(for: url) } catch {
                    session.log("  ❌ Couldn't save copy for \(url.lastPathComponent): \(error.localizedDescription)")
                    session.errors += 1
                    continue
                }
            }
            session.log("  ✍️ \(url.lastPathComponent): wrote copy for \(written) clip(s)")
        }
    }

    // MARK: - Send Webhook step

    private func runWebhook(context: inout StepContext, url: String, format: WebhookFormat) async {
        let session = context.session
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else {
            session.log("  ⏭ Send Webhook: no URL set")
            return
        }

        let files: [WebhookReport.File] = context.files.map { file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            let clips = (ClipSuggestions.load(for: file)?.candidates ?? []).sorted { $0.start < $1.start }.map {
                WebhookReport.Clip(
                    title: $0.title, start: $0.start, end: $0.end, score: $0.score,
                    caption: $0.copy?.caption, hashtags: $0.copy?.hashtags ?? []
                )
            }
            return WebhookReport.File(name: file.lastPathComponent, sizeBytes: Int64(size), clips: clips)
        }
        let report = WebhookReport(
            workflow: session.workflow.name, device: context.device.name,
            errors: session.errors, files: files
        )

        // The URL itself can be a secret (Slack and Discord webhook URLs
        // are), so only the host goes in the log.
        let host = URL(string: url)?.host ?? "webhook"
        do {
            try await WebhookService.send(report, to: url, format: format)
            session.log("  📡 Webhook sent to \(host)")
        } catch {
            session.log("  ⚠️ Webhook to \(host) failed: \(error.localizedDescription)")
            session.errors += 1
        }
    }

    // MARK: - Copy To step

    private func runCopyTo(
        context: inout StepContext, destination: CopyDestination, verify: Bool, includeSidecars: Bool
    ) async {
        let session = context.session
        let videos = workingVideos(for: context)
        guard !videos.isEmpty else {
            session.log("  ⏭ Copy To: no files to copy for \(context.device.name)")
            return
        }

        let base: URL
        do {
            switch destination {
            case .global:
                let mountPath = try await mountSMBVolume(location: appState.syncLocation)
                appState.syncLocation.resolvedMountPath = mountPath
                base = URL(fileURLWithPath: appState.syncLocation.recordsPath)
                    .appendingPathComponent(context.device.name)
            case .cloudStore(let id, let path):
                guard let store = appState.cloudStores.first(where: { $0.id == id }) else {
                    session.log("  ❌ Copy To: the selected cloud store no longer exists")
                    session.errors += 1
                    return
                }
                session.log("  Mounting \(store.name)...")
                let mount = URL(fileURLWithPath: try await SMBService.mount(store: store))
                base = path.isEmpty ? mount : mount.appendingPathComponent(path)
            case .localFolder(let id, let path):
                guard let folder = appState.localFolders.first(where: { $0.id == id }) else {
                    session.log("  ❌ Copy To: the selected local folder no longer exists")
                    session.errors += 1
                    return
                }
                guard folder.exists else {
                    session.log("  ❌ Copy To: \(folder.name) isn't available — is the drive connected?")
                    session.errors += 1
                    return
                }
                let root = URL(fileURLWithPath: folder.path)
                base = path.isEmpty ? root : root.appendingPathComponent(path)
            }
        } catch {
            session.log("  ❌ Copy To: couldn't reach the destination — \(error.localizedDescription)")
            session.errors += 1
            return
        }

        // Each file keeps its place relative to where it is now: a flat
        // list of names, matching how the clips sit in the source folder.
        var jobs: [(from: URL, to: URL)] = []
        for video in videos {
            jobs.append((video, base.appendingPathComponent(video.lastPathComponent)))
            if includeSidecars {
                for sidecar in FileCopier.sidecars(of: video) {
                    jobs.append((sidecar, base.appendingPathComponent(sidecar.lastPathComponent)))
                }
            }
        }

        session.log("  📋 Copying \(jobs.count) file(s) to \(base.path)\(verify ? " (verified)" : "")...")
        var copied = 0, skipped = 0, problems = 0
        for job in jobs {
            if session.isCancelled { return }
            switch await FileCopier.copy(from: job.from, to: job.to, verify: verify) {
            case .copied:
                copied += 1
            case .skipped:
                skipped += 1
            case .mismatch:
                problems += 1
                session.log("  ❌ \(job.from.lastPathComponent): copy didn't match the original and was removed")
            case .failed(let why):
                problems += 1
                session.log("  ❌ \(job.from.lastPathComponent): \(why)")
            }
        }
        session.errors += problems
        session.log("  ✅ Copy To: \(copied) copied, \(skipped) already there\(problems > 0 ? ", \(problems) failed" : "")")
    }

    // MARK: - Queue Clips step

    /// Adds each video's saved clip suggestions to the Export Queue as
    /// trimmed items. Doesn't search for clips itself — that's the Find Clips
    /// step — and doesn't start the export; the queue's destination is
    /// chosen in the Export Queue panel.
    private func runQueueClips(context: inout StepContext, minScore: Int) {
        let session = context.session

        var files = context.files
        if files.isEmpty, context.device.hyperDeck == nil {
            files = ((try? FileManager.default.contentsOfDirectory(at: context.destDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { ConversionService.canConvert(url: $0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard !files.isEmpty else {
            session.log("  ⏭ Queue Clips: no video files found in \(context.device.name)")
            return
        }

        // Files are always local by now (a deck's footage was offloaded),
        // so queue them against the local place they live in.
        let device: DeviceSource
        switch context.device {
        case .localFolder(let folder):
            device = .localFolder(folder)
        case .cloudStore(let store, _):
            device = .cloudStore(store)
        case .hyperDeck:
            if let id = context.cloudStoreID, let store = appState.cloudStores.first(where: { $0.id == id }) {
                device = .cloudStore(store)
            } else {
                device = .localFolder(LocalFolder(name: "Workflow output", path: context.destDir.path))
            }
        }

        var queued = 0
        for url in files {
            guard let added = ExportQueueManager.shared.addSuggestedClips(for: url, device: device, minScore: minScore) else {
                session.log("  ⏭ \(url.lastPathComponent): no clip suggestions — add a Find Clips step before this one")
                continue
            }
            queued += added
        }
        session.log("  📥 \(queued) clip(s) added to the Export Queue — open it to choose a destination and start")
    }

    // MARK: - Resize for Social step

    /// Writes `<name>_<ratio>.mp4` into a `Reframed` folder. The working set
    /// of files is left as it was, so later steps still see the originals
    /// (or proxies) rather than the social crops.
    private func runReframe(context: inout StepContext, format: SocialFormat, followSubject: Bool) async {
        let session = context.session

        var files = context.files
        if files.isEmpty, context.device.hyperDeck == nil {
            session.log("  📂 Scanning \(context.device.name) (\(context.destDir.path)) for clips...")
            files = ((try? FileManager.default.contentsOfDirectory(at: context.destDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { ConversionService.canConvert(url: $0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard !files.isEmpty else {
            session.log("  ⏭ Resize for Social: no video files found in \(context.device.name)")
            return
        }

        let outDir = context.destDir.appendingPathComponent("Reframed")
        for url in files {
            if session.isCancelled { return }
            let output = outDir.appendingPathComponent(
                (url.lastPathComponent as NSString).deletingPathExtension + "_\(format.fileSuffix).mp4"
            )
            if FileManager.default.fileExists(atPath: output.path) {
                session.log("  ⏭ \(output.lastPathComponent) already exists")
                continue
            }
            session.log("  📐 Resizing \(url.lastPathComponent) to \(format.title) (\(context.device.name))...")
            do {
                try await ReframeService.reframe(input: url, output: output, format: format, followSubject: followSubject)
                session.log("  ✅ Resized → Reframed/\(output.lastPathComponent)")
            } catch ReframeError.diskFull {
                session.log("  🛑 Destination drive is full — stopping (\(url.lastPathComponent), \(context.device.name))")
                session.errors += 1
                session.isCancelled = true
                return
            } catch {
                session.log("  ❌ Resize failed for \(url.lastPathComponent): \(error.localizedDescription)")
                session.errors += 1
            }
        }
    }

    // MARK: - Control HyperDeck step

    private func runControlDeck(context: inout StepContext, command: DeckCommand) async {
        let session = context.session
        guard let deck = context.device.hyperDeck else {
            session.log("  ⏭ \(context.device.name): Control HyperDeck only applies to a HyperDeck target — skipped")
            return
        }
        let service = HyperDeckService(host: deck.ipAddress)

        await service.fetchTransport()
        guard service.isConnected else {
            session.log("  ❌ \(deck.name) is not reachable — skipping control step")
            session.errors += 1
            return
        }

        switch command {
        case .start:
            if service.transport == .recording {
                session.log("  ⏺ \(deck.name) is already recording")
            } else {
                session.log("  ⏺ Starting recording on \(deck.name)...")
                await service.record()
                if let error = service.lastError {
                    session.log("  ❌ \(deck.name) failed to start recording: \(error)")
                    session.errors += 1
                    return
                }
                session.log("  ✅ \(deck.name) is recording")
            }

        case .stop:
            guard service.transport == .recording else {
                session.log("  ⏭ \(deck.name) is not recording")
                return
            }

            session.log("  ⏹ Stopping recording on \(deck.name)...")
            await service.stop()
            if let error = service.lastError {
                session.log("  ❌ \(deck.name) failed to stop recording: \(error)")
                session.errors += 1
            } else {
                session.log("  ✅ \(deck.name) stopped recording")
            }
        }
    }

    // MARK: - Wait step

    /// Pauses the workflow for a fixed duration before moving on. Sleeps in
    /// short chunks (rather than one long `Task.sleep`) so this run's Stop
    /// button takes effect promptly instead of after the full wait elapses.
    private func runWait(minutes: Int, session: WorkflowRunSession) async {
        guard minutes > 0 else { return }
        let totalSeconds = minutes * 60
        session.log("  ⏳ Waiting \(WaitDurationFormatter.string(forMinutes: minutes)) before continuing...")

        var elapsed = 0
        let chunk = 5
        while elapsed < totalSeconds {
            guard !session.isCancelled else { return }
            let sleepSeconds = min(chunk, totalSeconds - elapsed)
            try? await Task.sleep(for: .seconds(sleepSeconds))
            elapsed += sleepSeconds
        }
        session.log("  ⏳ Wait complete")
    }

    // MARK: - Format step

    private func runFormat(context: inout StepContext) async {
        let session = context.session
        guard let deck = context.device.hyperDeck else {
            session.log("  ⏭ \(context.device.name): Format Drive only applies to a HyperDeck target — skipped")
            return
        }
        session.log("  🗑 Erasing \(deck.name)'s drive (\(deck.ipAddress))...")
        do {
            try await HyperDeckService.formatDrive(deck: deck)
            session.log("  ✅ \(deck.name)'s drive erased successfully")
        } catch {
            session.log("  ❌ \(deck.name) drive erase failed: \(error.localizedDescription)")
            session.errors += 1
        }
    }

    // MARK: - Cleanup step

    private func runCleanup(context: inout StepContext, retentionDays: Int) async {
        let session = context.session
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let base = context.destDir
        session.log("  🧹 Cleaning \(context.device.name)'s destination folder — removing files older than \(retentionDays) day(s)...")

        // destDir is often a Cloud Store's SMB mount, so an unbroken burst of
        // per-file stat/delete calls over a large or slow tree can hammer the
        // SMB client for minutes at a stretch. Check for Stop and yield
        // periodically, and cap the whole walk with a hard deadline, so a bad
        // share degrades this step instead of stalling it indefinitely.
        let deadline = Date().addingTimeInterval(5 * 60)

        let (deletedCount, cutShort): (Int, Bool) = await Task.detached(priority: .background) {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: base,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return (0, false) }

            var deleted = 0
            var checked = 0
            while let url = enumerator.nextObject() as? URL {
                checked += 1
                if checked % 20 == 0 {
                    if await session.isCancelled { return (deleted, true) }
                    if Date() > deadline { return (deleted, true) }
                    await Task.yield()
                }
                guard !url.hasDirectoryPath else { continue }
                if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   mod < cutoff {
                    try? fm.removeItem(at: url)
                    deleted += 1
                }
            }
            return (deleted, false)
        }.value

        if cutShort {
            session.log("  ⚠️ Cleanup stopped early after removing \(deletedCount) file(s) — destination folder may be slow to respond")
        } else {
            session.log("  🗑 Cleanup removed \(deletedCount) old file(s)")
        }
    }

    // MARK: - Trigger Workflow step

    /// Starts another workflow from within this one. Runs it through the
    /// normal `start` path — its own session, its own log, its own history
    /// entry — so it shows up in the Dashboard exactly like a manually or
    /// schedule-triggered run.
    ///
    /// With a `.createdFolder` choice the target runs in place on that
    /// folder — or on one device's subfolder of it — instead of on its own
    /// devices, the same as running it on a folder from the file browser.
    private func runTriggerWorkflow(
        workflowID: UUID?, waitForCompletion: Bool, folder: TriggerFolder,
        createdFolders: [UUID: URL],
        session: WorkflowRunSession, triggerChain: Set<UUID>
    ) async {
        guard let workflowID, let target = appState.workflows.first(where: { $0.id == workflowID }) else {
            session.log("  ❌ Trigger Workflow: no workflow selected")
            session.errors += 1
            return
        }
        guard !triggerChain.contains(workflowID) else {
            session.log("  ❌ Trigger Workflow: skipped \"\(target.name)\" — it's already running upstream in this chain")
            session.errors += 1
            return
        }
        var folderTarget: WorkflowTargetDevice?
        if case .createdFolder(let stepID, let deviceID) = folder {
            guard let folderURL = createdFolders[stepID] else {
                session.log("  ❌ Trigger Workflow: skipped \"\(target.name)\" — the folder it should run on hasn't been created yet in this run")
                session.errors += 1
                return
            }
            var url = folderURL
            // Shown for the run and checked for conflicts by name, so a
            // device's subfolder must not simply borrow the device's own
            // name — the run that triggered this one is using that device.
            var runName = folderURL.lastPathComponent
            if let deviceID {
                guard let deck = appState.hyperDecks.first(where: { $0.id == deviceID }) else {
                    session.log("  ❌ Trigger Workflow: skipped \"\(target.name)\" — the device it should run on no longer exists")
                    session.errors += 1
                    return
                }
                // Named after the device, the same way Create Folder's
                // "one subfolder per device" lays it out.
                url = folderURL.appendingPathComponent(deck.name)
                runName = "\(folderURL.lastPathComponent)/\(deck.name)"
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let device = WorkflowTargetDevice.localFolder(LocalFolder(name: runName, path: url.path))
            guard appState.canRun(deviceNames: [device.name], resourceKeys: [device.resourceKey]) else {
                session.log("  ⚠️ Trigger Workflow: \"\(target.name)\" can't start — \(runName) is already in use by another run")
                return
            }
            folderTarget = device
        } else {
            guard appState.canRun(target) else {
                session.log("  ⚠️ Trigger Workflow: \"\(target.name)\" can't start — one of its devices is already busy")
                return
            }
        }

        // The target may itself have been mid-run when the app died. Pick
        // that run back up rather than starting a second one beside it.
        if folderTarget == nil, let interrupted = WorkflowCheckpointStore.shared.interrupted.first(where: { $0.workflow.id == workflowID }) {
            session.log("  🔗 Resuming interrupted run of \"\(target.name)\"...")
            if waitForCompletion {
                await resume(interrupted)
                session.log("  🔗 \"\(target.name)\" finished")
            } else {
                Task { await self.resume(interrupted) }
            }
            return
        }

        let nextChain = triggerChain.union([workflowID])
        let targets = folderTarget.map { [$0] } ?? targetDevices(for: target)

        if let folderTarget {
            session.log("  🔗 Running \"\(target.name)\" on \(folderTarget.name)")
        }
        if waitForCompletion {
            session.log("  🔗 Triggering \"\(target.name)\" and waiting for it to finish...")
            await start(target, targets: targets, triggerChain: nextChain)
            session.log("  🔗 \"\(target.name)\" finished")
        } else {
            session.log("  🔗 Triggering \"\(target.name)\"...")
            Task { await self.start(target, targets: targets, triggerChain: nextChain) }
        }
    }

    // MARK: - Notification step

    private func runNotify(
        context: inout StepContext,
        header: String,
        message: String,
        recipients: [NotificationRecipient]
    ) async {
        let session = context.session
        guard !recipients.isEmpty else {
            session.log("  ⏭ Notification: no recipients configured")
            return
        }
        guard NotificationMailer.isAvailable else {
            session.log("  ⚠️ Notification: sign in to the church site in Settings to send email")
            return
        }

        let isHTML = message.range(of: "<[a-zA-Z][^<>]*>", options: .regularExpression) != nil

        // Apply template variables
        let duration = Date().timeIntervalSince(session.startedAt)
        let totalSeconds = Int(duration)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        let timeTakenStr = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"

        let fileNamesHeader = context.files.isEmpty ? "no files" : context.files.map(\.lastPathComponent).joined(separator: ", ")
        let fileNamesBody: String
        if context.files.isEmpty {
            fileNamesBody = isHTML ? "<p>No files</p>" : "No files"
        } else if isHTML {
            fileNamesBody = "<ul>" + context.files.map { "<li>\($0.lastPathComponent)</li>" }.joined() + "</ul>"
        } else {
            fileNamesBody = context.files.map { "- \($0.lastPathComponent)" }.joined(separator: "\n")
        }

        let resolvedHeader = header
            .replacingOccurrences(of: "{workflow_name}", with: session.workflow.name)
            .replacingOccurrences(of: "{workflow}", with: session.workflow.name)
            .replacingOccurrences(of: "{time_taken}", with: timeTakenStr)
            .replacingOccurrences(of: "{file_names}", with: fileNamesHeader)

        let resolvedMessage = message
            .replacingOccurrences(of: "{workflow_name}", with: session.workflow.name)
            .replacingOccurrences(of: "{workflow}", with: session.workflow.name)
            .replacingOccurrences(of: "{time_taken}", with: timeTakenStr)
            .replacingOccurrences(of: "{file_names}", with: fileNamesBody)

        session.log("  ✉️ Sending notification \"\(resolvedHeader)\" to \(recipients.count) recipient(s)...")
        var failed: [(recipient: String, reason: String)] = []

        for recipient in recipients {
            let recipientHeader = resolvedHeader
                .replacingOccurrences(of: "{recipient_name}", with: recipient.name)
                .replacingOccurrences(of: "{name}", with: recipient.name)

            let recipientMessage = resolvedMessage
                .replacingOccurrences(of: "{recipient_name}", with: recipient.name)
                .replacingOccurrences(of: "{name}", with: recipient.name)

            do {
                try await NotificationMailer.send(to: [recipient.email], subject: recipientHeader, body: recipientMessage, isHTML: isHTML)
            } catch {
                failed.append((recipient.email, NotificationMailer.describe(error)))
            }
        }

        if failed.isEmpty {
            session.log("  ✅ Notification sent")
        } else {
            for failure in failed {
                session.log("  ⚠️ Failed to email \(failure.recipient): \(failure.reason)")
            }
            session.errors += 1
        }
    }

    // MARK: - Finish

    private static func verificationKey(_ v: SyncTask.Verification) -> String {
        switch v {
        case .none, .verifying: return "none"
        case .verified:         return "verified"
        case .mismatch:         return "mismatch"
        case .failed:           return "failed"
        }
    }

    /// Deletes the transcript files a Transcribe step marked "delete when
    /// done". Runs at the very end so Find Clips, Copy To and the rest have
    /// used them first — including when the run is stopped or had errors.
    private func removeTemporaryTranscripts(session: WorkflowRunSession) {
        let files = session.transcriptFilesToDelete
        guard !files.isEmpty else { return }
        session.transcriptFilesToDelete = []
        var removed = 0
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            do {
                try FileManager.default.removeItem(at: file)
                removed += 1
            } catch {
                session.log("  ⚠️ Couldn't delete \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if removed > 0 { session.log("  🧹 Deleted \(removed) temporary transcript file(s)") }
    }

    private func finishRun(workflow: Workflow, session: WorkflowRunSession) {
        WorkflowCheckpointStore.shared.remove(id: session.id)
        removeTemporaryTranscripts(session: session)
        session.recordTimings()
        session.finalizeSteps()
        let c = session.converted
        let e = session.errors
        session.log("✅ Workflow finished — \(c) processed, \(e) errors")

        let run = WorkflowRun(
            workflowName:   workflow.name,
            startedAt:      session.startedAt,
            finishedAt:     Date(),
            processed:      c,
            errors:         e,
            decksProcessed: Array(session.deckNames).sorted(),
            log:            session.lines,
            fileRecords:    session.tasks.map { task in
                RunFileRecord(
                    fileName: task.fileName, deviceName: task.deckName,
                    sizeBytes: task.fileSizeBytes, succeeded: task.phase == .done,
                    errorMessage: task.errorMessage,
                    verification: Self.verificationKey(task.verification),
                    sha256: task.sha256, folderPath: task.destDir.path
                )
            }
        )
        appState.workflowRunHistory.insert(run, at: 0)
        if appState.workflowRunHistory.count > 50 {
            appState.workflowRunHistory = Array(appState.workflowRunHistory.prefix(50))
        }

        appState.finish(session)
        NotificationService.sendCompletion(converted: c, errors: e)

        SchedulerService.shared.workflowFinished(workflow, errors: e, wasCancelled: session.isCancelled)
    }

    // MARK: - Helpers

    /// Everything a workflow runs against: the HyperDecks its deck steps
    /// name, plus the folders it's set to process in place.
    ///
    /// A workflow with neither, and no step that works on files (just a
    /// wait and a webhook, say), still has to run once — so it gets a
    /// stand-in target named after the workflow, with nowhere on disk
    /// behind it. One that does work on files and has nowhere to find them
    /// gets nothing here, and is run on a chosen folder instead.
    private func targetDevices(for workflow: Workflow) -> [WorkflowTargetDevice] {
        let devices = appState.hyperDecks(for: workflow).map(WorkflowTargetDevice.hyperDeck)
            + workflow.targets.compactMap(device(for:))
        if devices.isEmpty, workflow.targets.isEmpty, !workflow.selectsAnyDeck,
           !workflow.steps.isEmpty, !workflow.choosesFolderAtRun {
            return [.localFolder(LocalFolder(name: workflow.name, path: "/dev/null/\(workflow.id.uuidString)"))]
        }
        return devices
    }

    /// Looks a saved target up among the devices currently configured; nil
    /// if it has since been deleted.
    private func device(for target: WorkflowTarget) -> WorkflowTargetDevice? {
        switch target {
        case .hyperDeck(let id):
            return appState.hyperDecks.first { $0.id == id }.map(WorkflowTargetDevice.hyperDeck)
        case .localFolder(let id):
            return appState.localFolders.first { $0.id == id }.map(WorkflowTargetDevice.localFolder)
        case .cloudStore(let id, let path):
            return appState.cloudStores.first { $0.id == id }.map { WorkflowTargetDevice.cloudStore($0, path: path) }
        case .folder(let path, let name):
            return .localFolder(LocalFolder(name: name, path: path))
        }
    }

    /// What a checkpoint records for a device. A folder picked just for this
    /// run isn't in the device list, so it's saved by path instead of by id.
    private func savedTarget(for device: WorkflowTargetDevice) -> WorkflowTarget {
        if case .localFolder(let folder) = device, !appState.localFolders.contains(where: { $0.id == folder.id }) {
            return .folder(path: folder.path, name: folder.name)
        }
        return device.workflowTarget
    }

    // MARK: - Checkpointing

    private func saveCheckpoint(
        workflow: Workflow, targets: [WorkflowTarget], triggerChain: Set<UUID>,
        nextStepIndex: Int, contexts: [StepContext], mountedPaths: [UUID?: String],
        session: WorkflowRunSession
    ) {
        let devices = contexts.map { context -> WorkflowCheckpoint.DeviceState in
            // A Local Folder's path is its own and never moves; anything
            // else may live under a mounted volume whose path can change.
            var relative: String? = nil
            if case .localFolder = context.device {} else if let root = mountedPaths[context.cloudStoreID] {
                let path = context.destDir.path
                if path == root {
                    relative = ""
                } else if path.hasPrefix(root + "/") {
                    relative = String(path.dropFirst(root.count + 1))
                }
            }
            return WorkflowCheckpoint.DeviceState(
                resourceKey: context.device.resourceKey,
                deviceName: context.device.name,
                destPath: context.destDir.path,
                destRelativePath: relative,
                cloudStoreID: context.cloudStoreID,
                filePaths: context.files.map(\.path),
                verifyOffload: context.verifyOffload,
                deleteAfterOffload: context.deleteAfterOffload
            )
        }
        WorkflowCheckpointStore.shared.save(WorkflowCheckpoint(
            id: session.id, workflow: workflow, targets: targets, triggerChain: triggerChain,
            startedAt: session.startedAt, updatedAt: Date(), nextStepIndex: nextStepIndex,
            devices: devices, tasks: session.tasks, lines: session.lines,
            converted: session.converted, skipped: session.skipped, errors: session.errors,
            transcriptFilesToDelete: session.transcriptFilesToDelete.map(\.path)
        ))
    }

    /// Puts each freshly-built device context back the way the interrupted
    /// run left it: its working files, its Sync flags, and — the one thing
    /// that can't simply be recomputed — the destination folder a Create
    /// Folder step had already made. A device that can no longer be
    /// reached is dropped, as a mount failure would be on a normal start.
    private func restoreContexts(
        _ contexts: [StepContext], from checkpoint: WorkflowCheckpoint,
        session: WorkflowRunSession, mountedPaths: inout [UUID?: String]
    ) async -> [StepContext] {
        var restored: [StepContext] = []
        for var context in contexts {
            guard let saved = checkpoint.devices.first(where: { $0.resourceKey == context.device.resourceKey }) else {
                restored.append(context)
                continue
            }

            // Skipped when the saved value was only the placeholder a
            // deck holds until its Create Folder step runs.
            if saved.destPath != "/dev/null" {
                if let relative = saved.destRelativePath {
                    do {
                        let root = try await mountBase(cloudStoreID: saved.cloudStoreID, session: session, cache: &mountedPaths)
                        context.destDir = relative.isEmpty ? root : root.appendingPathComponent(relative)
                        context.cloudStoreID = saved.cloudStoreID
                    } catch {
                        session.log("❌ \(context.device.name): \(error.localizedDescription)")
                        session.mountError = error.localizedDescription
                        session.errors += 1
                        continue
                    }
                } else {
                    context.destDir = URL(fileURLWithPath: saved.destPath)
                    context.cloudStoreID = saved.cloudStoreID
                }
            }

            context.verifyOffload = saved.verifyOffload
            context.deleteAfterOffload = saved.deleteAfterOffload

            let files = saved.filePaths.map { URL(fileURLWithPath: $0) }
            context.files = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            let missing = files.count - context.files.count
            if missing > 0 {
                session.log("  ⚠️ \(context.device.name): \(missing) file(s) from the interrupted run are no longer on disk")
            }
            restored.append(context)
        }
        return restored
    }

    /// With "delete from device after offload" on, a file is removed from
    /// the deck the moment its copy verifies — so if the run died before
    /// that file was converted, the resumed Sync won't see it on the deck
    /// again and it would otherwise be left behind without a word.
    private func warnAboutUnconvertedLeftovers(contexts: [StepContext], convertInPlace: Bool, session: WorkflowRunSession) {
        let fm = FileManager.default
        for context in contexts where context.device.hyperDeck != nil && context.destDir.path != "/dev/null" {
            let convertedDir = convertInPlace ? context.destDir : context.destDir.appendingPathComponent("Converted")
            let entries = (try? fm.contentsOfDirectory(at: context.destDir, includingPropertiesForKeys: nil)) ?? []
            let leftovers = entries.filter { url in
                guard ConversionService.canConvert(url: url) else { return false }
                let output = convertedDir.appendingPathComponent((url.lastPathComponent as NSString).deletingPathExtension + ".mp4")
                return !fm.fileExists(atPath: output.path)
            }
            guard !leftovers.isEmpty else { continue }
            session.log("  ⚠️ \(context.device.name): \(leftovers.count) copied file(s) in \(context.destDir.lastPathComponent) haven't been converted and are no longer on the device — convert them manually if they're from the interrupted run")
        }
    }

    /// Resolves a device by name for retry, checking HyperDecks first, then
    /// Local Folders, then Cloud Stores (matched at their volume root only
    /// — a Cloud Store Folder target using a subfolder won't resolve here
    /// since its name embeds that path, so such a failure simply won't be
    /// offered a retry) — used because a failed task only remembers its
    /// device's name (see `RetryGroupKey`), not which kind of device it is.
    private func resolveTargetDevice(named name: String) -> WorkflowTargetDevice? {
        if let deck = appState.hyperDecks.first(where: { $0.name == name }) {
            return .hyperDeck(deck)
        }
        if let folder = appState.localFolders.first(where: { $0.name == name }) {
            return .localFolder(folder)
        }
        if let store = appState.cloudStores.first(where: { $0.name == name }) {
            return .cloudStore(store, path: "")
        }
        return nil
    }

    private func mountSMBVolume(location: SyncLocation) async throws -> String {
        try await SMBService.mountAndResolve(
            ip:       location.ipAddress,
            volume:   location.volumeName,
            username: location.username,
            password: location.password
        )
    }

    /// Mounts (if not already cached) the given Cloud Store, or the shared
    /// global destination when `cloudStoreID` is nil (or doesn't match any
    /// configured store), returning the local mount root. Mounts are cached
    /// per store so anything sharing a destination within one run — decks,
    /// a Create Folder step, a retry — only mounts it once.
    private func mountBase(
        cloudStoreID: UUID?, session: WorkflowRunSession, cache mountedPaths: inout [UUID?: String]
    ) async throws -> URL {
        if let storeID = cloudStoreID, let store = appState.cloudStores.first(where: { $0.id == storeID }) {
            if let cached = mountedPaths[storeID] { return URL(fileURLWithPath: cached) }
            session.log("Mounting \(store.name)...")
            let mountPath = try await SMBService.mount(store: store)
            mountedPaths[storeID] = mountPath
            session.log("✅ Mounted \(store.name) at \(mountPath)")
            return URL(fileURLWithPath: mountPath)
        }

        if let cached = mountedPaths[nil] { return URL(fileURLWithPath: cached) }
        session.log("Mounting \(appState.syncLocation.volumeName)...")
        let mountPath = try await mountSMBVolume(location: appState.syncLocation)
        appState.syncLocation.resolvedMountPath = mountPath
        mountedPaths[nil] = mountPath
        session.log("✅ Mounted at \(mountPath)")
        return URL(fileURLWithPath: mountPath)
    }

    /// Resolves a static Sync destination (global or a specific Cloud
    /// Store) for a single deck. `.createdFolder` destinations are resolved
    /// separately, when the Create Folder step they point at actually runs
    /// — see `resolveCreateFolder` and the run loop in `start`.
    private func resolveDestination(
        for deck: HyperDeck, destination: SyncDestination,
        session: WorkflowRunSession, cache mountedPaths: inout [UUID?: String]
    ) async throws -> URL {
        switch destination {
        case .global:
            _ = try await mountBase(cloudStoreID: nil, session: session, cache: &mountedPaths)
            return URL(fileURLWithPath: appState.syncLocation.recordsPath)
                .appendingPathComponent(deck.name)
        case .cloudStore(let id, let path):
            // Use the folder chosen in the Sync step exactly as selected —
            // don't nest an extra deck-name subfolder inside it.
            let base = try await mountBase(cloudStoreID: id, session: session, cache: &mountedPaths)
            return path.isEmpty ? base : base.appendingPathComponent(path)
        case .createdFolder:
            struct DestinationNotReady: LocalizedError {
                var errorDescription: String? { "Sync destination not resolved yet" }
            }
            throw DestinationNotReady()
        }
    }

    /// Creates (and returns) the folder configured by a Create Folder step.
    /// Its `{date}` token is resolved against "now" — i.e. when the step
    /// actually runs rather than when the workflow was configured — so a
    /// folder named with today's date reflects the day the run happened,
    /// including for workflows scheduled to fire overnight.
    private func resolveCreateFolder(
        cloudStoreID: UUID?, parentPath: String, nameTemplate: String,
        session: WorkflowRunSession, cache mountedPaths: inout [UUID?: String]
    ) async throws -> URL {
        let root = try await mountBase(cloudStoreID: cloudStoreID, session: session, cache: &mountedPaths)
        let base = parentPath.isEmpty ? root : root.appendingPathComponent(parentPath)
        let folderURL = base.appendingPathComponent(FolderNameEngine.resolve(nameTemplate))
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    @discardableResult
    private func addTask(
        fileName: String, deckName: String, destDir: URL,
        cloudStoreID: UUID? = nil,
        fileSizeBytes: Int64 = 0,
        in session: WorkflowRunSession
    ) -> SyncTask {
        let t = SyncTask(fileName: fileName, deckName: deckName, destDir: destDir, cloudStoreID: cloudStoreID, fileSizeBytes: fileSizeBytes)
        session.tasks.append(t)
        return t
    }

    /// Looks up a task by file + device name rather than by whichever
    /// session happens to be at hand — needed because with multiple decks
    /// converting at once, two devices can produce identically named clips
    /// (e.g. "Clip0001.mov"), and because a retried task's original entry
    /// lives in an older session, not the fresh "Retry Failed" one.
    private func taskID(forFileName fileName: String, deckName: String) -> UUID? {
        for session in appState.activeRuns {
            if let match = session.tasks.first(where: { $0.fileName == fileName && $0.deckName == deckName }) {
                return match.id
            }
        }
        return nil
    }

    /// Hashes the copy against the source on the deck. Returns true when the
    /// file is safe to carry on with (convert / delete the original); on a
    /// mismatch or failure the task is marked as an error and the copy is
    /// left in place for inspection.
    private func verifyCopy(taskID: UUID, fileName: String, deck: HyperDeck, destURL: URL,
                            session: WorkflowRunSession) async -> Bool {
        setVerification(id: taskID, .verifying)
        session.log("  🔍 Verifying \(fileName) (SHA-256)...")
        let outcome = await ChecksumService.verifyDownload(of: fileName, from: deck, at: destURL)
        switch outcome {
        case .verified(let hash):
            setVerification(id: taskID, .verified, hash: hash)
            ChecksumService.record(hash: hash, fileName: fileName, in: destURL.deletingLastPathComponent())
            session.log("  ✅ Verified \(fileName) — \(hash.prefix(12))…")
            return true
        case .mismatch:
            setVerification(id: taskID, .mismatch)
            updateTask(id: taskID, phase: .error, errorMessage: "Checksum mismatch — the copy doesn't match the source")
            session.log("  🛑 Checksum mismatch: \(fileName) — the copy on the destination differs from the deck")
            session.errors += 1
            return false
        case .failed(let reason):
            setVerification(id: taskID, .failed)
            updateTask(id: taskID, phase: .error, errorMessage: "Couldn't verify: \(reason)")
            session.log("  ⚠️ Couldn't verify \(fileName): \(reason)")
            session.errors += 1
            return false
        }
    }

    private func setVerification(id: UUID, _ state: SyncTask.Verification, hash: String? = nil) {
        for session in appState.activeRuns {
            guard let i = session.tasks.firstIndex(where: { $0.id == id }) else { continue }
            session.tasks[i].verification = state
            if let hash { session.tasks[i].sha256 = hash }
            return
        }
    }

    private func updateTask(
        id: UUID,
        phase: SyncTask.Phase? = nil,
        syncProgress: Double? = nil,
        convertProgress: Double? = nil,
        errorMessage: String? = nil
    ) {
        for session in appState.activeRuns {
            guard let i = session.tasks.firstIndex(where: { $0.id == id }) else { continue }
            if let v = phase {
                session.tasks[i].phase = v
                // Stamped here, in the one place every phase change passes
                // through, for the run's time estimate.
                if v == .converting {
                    session.tasks[i].convertStartedAt = Date()
                } else if session.tasks[i].convertStartedAt != nil, session.tasks[i].convertFinishedAt == nil {
                    session.tasks[i].convertFinishedAt = Date()
                }
            }
            if let v = syncProgress    {
                updateTransferSpeed(&session.tasks[i], newProgress: v)
                session.tasks[i].syncProgress = v
            }
            if let v = convertProgress { session.tasks[i].convertProgress = v }
            if let v = errorMessage    { session.tasks[i].errorMessage    = v }
            return
        }
    }

    /// Feeds a new `syncProgress` sample into the task's rolling speed
    /// estimate. Curl's `--progress-bar` reports in coarse (~1%) steps
    /// rather than a steady stream, so a single sample-to-sample rate would
    /// be noisy — this smooths it with a simple exponential moving average
    /// instead of reacting fully to every tick.
    private func updateTransferSpeed(_ task: inout SyncTask, newProgress: Double) {
        defer {
            task.lastProgressAt = Date()
            task.lastProgressValue = newProgress
        }
        guard task.fileSizeBytes > 0,
              let lastAt = task.lastProgressAt,
              newProgress > task.lastProgressValue else { return }

        let elapsed = Date().timeIntervalSince(lastAt)
        guard elapsed > 0 else { return }

        let deltaBytes = Double(task.fileSizeBytes) * (newProgress - task.lastProgressValue)
        let instantSpeed = deltaBytes / elapsed
        let smoothing = 0.3
        task.bytesPerSecond = task.bytesPerSecond == 0
            ? instantSpeed
            : (smoothing * instantSpeed + (1 - smoothing) * task.bytesPerSecond)
    }

    /// Clears a task back to its initial state before a retry attempt.
    private func resetTask(id: UUID) {
        for session in appState.activeRuns {
            guard let i = session.tasks.firstIndex(where: { $0.id == id }) else { continue }
            session.tasks[i].phase           = .downloading
            session.tasks[i].syncProgress    = 0
            session.tasks[i].convertProgress = 0
            session.tasks[i].errorMessage    = nil
            session.tasks[i].bytesPerSecond  = 0
            session.tasks[i].lastProgressAt    = nil
            session.tasks[i].lastProgressValue = 0
            session.tasks[i].convertStartedAt  = nil
            session.tasks[i].convertFinishedAt = nil
            return
        }
    }
}
