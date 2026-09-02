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

        /// Non-nil only for a HyperDeck target — used to guard steps
        /// (Control HyperDeck, Format) that only make sense for a real
        /// device, and by retry to decide whether there's anything to
        /// re-download.
        var hyperDeck: HyperDeck? {
            if case .hyperDeck(let d) = self { return d }
            return nil
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
        let session: WorkflowRunSession
    }

    // MARK: - Run (all target devices)

    func run(_ workflow: Workflow) async {
        await start(workflow, targets: targetDevices(for: workflow), triggerChain: [workflow.id])
    }

    // MARK: - Run (single device)
    // Runs the workflow's steps against exactly one device, regardless of
    // that workflow's own target list — used by the per-device "Run
    // Workflow" action on the Dashboard.

    func runDevice(_ workflow: Workflow, target: WorkflowTargetDevice) async {
        await start(workflow, targets: [target], triggerChain: [workflow.id])
    }

    // MARK: - Shared run loop

    /// `triggerChain` accumulates the IDs of every workflow already running
    /// upstream in this call stack (the workflow itself, plus any that
    /// triggered it via a Trigger Workflow step) — checked before honoring
    /// another Trigger Workflow step so A → B → A can't recurse forever.
    private func start(_ workflow: Workflow, targets: [WorkflowTargetDevice], triggerChain: Set<UUID> = []) async {
        // The Run buttons are already disabled when this would conflict, so
        // this mainly guards races — e.g. the scheduler firing at the same
        // instant someone taps Run manually.
        guard appState.canRun(workflow) else { return }

        let session = appState.beginRun(for: workflow, deckNames: Set(targets.map(\.name)))
        session.log("▶ Workflow started: \(workflow.name)")

        guard !targets.isEmpty else {
            session.log("⚠️ No devices configured for this workflow")
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

        for step in workflow.steps {
            guard !session.isCancelled else { break }
            if case .notify(_, _, _, let sendPerDrive) = step.action, !sendPerDrive {
                continue
            }

            if step.requiresConfirmation {
                session.log("⏸ Paused — waiting for confirmation on \"\(step.kind.title)\"")
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

            // Create Folder runs once for the whole workflow (like the
            // destination resolution above), not once per device — so it's
            // handled here rather than fanned out through `execute`.
            if case .createFolder(let cloudStoreID, let parentPath, let nameTemplate) = step.action {
                do {
                    let folderURL = try await resolveCreateFolder(
                        cloudStoreID: cloudStoreID, parentPath: parentPath, nameTemplate: nameTemplate,
                        session: session, cache: &mountedPaths
                    )
                    session.log("📁 Created folder: \(folderURL.path)")
                    if step.id == referencedFolderStepID {
                        contexts = contexts.map {
                            var context = $0
                            // A Local Folder target always keeps its own
                            // path as destDir — it never adopts a shared
                            // created folder.
                            guard context.device.hyperDeck != nil else { return context }
                            context.destDir = folderURL
                            context.cloudStoreID = cloudStoreID
                            return context
                        }
                    }
                } catch {
                    session.log("❌ Failed to create folder: \(error.localizedDescription)")
                    session.errors += 1
                }
                continue
            }

            // Trigger Workflow runs once for the whole workflow, like Create
            // Folder above — it isn't tied to any one device's files.
            if case .triggerWorkflow(let workflowID, let waitForCompletion) = step.action {
                await runTriggerWorkflow(
                    workflowID: workflowID, waitForCompletion: waitForCompletion,
                    session: session, triggerChain: triggerChain
                )
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
        }

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
                    await runNotify(context: &workflowContext, header: header, message: message, recipients: recipients)
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
        // Release a paused confirmation prompt, if any, so the run doesn't
        // hang forever waiting for a response that will never come.
        session.resolveConfirmation(proceed: false)
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

    private func execute(_ step: WorkflowStep, context: inout StepContext, convertInPlace: Bool) async {
        switch step.action {
        case .controlDeck(let command, let stopAfterMinutes):
            await runControlDeck(context: &context, command: command, stopAfterMinutes: stopAfterMinutes)
        case .wait(let minutes):
            await runWait(minutes: minutes, session: context.session)
        case .createFolder:
            break // handled once per run, before the per-deck fan-out — see `start`
        case .triggerWorkflow:
            break // handled once per run, before the per-deck fan-out — see `start`
        case .sync:
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

    private func runSyncFromDeck(context: inout StepContext, deck: HyperDeck, convertInPlace: Bool) async {
        let session = context.session
        session.log("  📡 Scanning \(deck.name) (\(deck.ipAddress))...")

        let remoteFiles = await FTPService.listMovFiles(on: deck)
        guard !remoteFiles.isEmpty else {
            session.log("  \(deck.name): no .mov files found")
            return
        }
        session.log("  \(deck.name): \(remoteFiles.count) file(s) found")

        for fileName in remoteFiles {
            guard !session.isCancelled else { return }

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
                in: session
            )
            updateTask(id: task.id, phase: .downloading, syncProgress: 0)
            session.log("  ⬇ Downloading \(fileName)...")

            // FTPService.downloadFile already retries transient failures
            // internally (dropped connection, stalled transfer), cleaning up
            // any partial file between attempts — so a single call here
            // already reflects the outcome after those retries.
            let result = await FTPService.downloadFile(
                named: fileName, from: deck, to: destURL
            ) { [weak self] pct in Task { @MainActor in self?.updateTask(id: task.id, syncProgress: pct) } }

            guard result.success else {
                let reason = result.failureReason ?? "unknown error"
                updateTask(id: task.id, phase: .error, errorMessage: "Download failed after retries: \(reason)")
                session.log("  ❌ Download failed: \(fileName) — \(reason)")
                session.errors += 1
                continue
            }

            updateTask(id: task.id, phase: .done, syncProgress: 1)
            session.log("  ✅ Downloaded \(fileName)")
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

        let movFiles = entries
            .filter { $0.lastPathComponent.lowercased().hasSuffix(".mov") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !movFiles.isEmpty else {
            session.log("  \(name): no .mov files found")
            return
        }
        session.log("  \(name): \(movFiles.count) file(s) found")

        for fileURL in movFiles {
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

            let task = addTask(
                fileName: fileName, deckName: name,
                destDir: context.destDir, cloudStoreID: context.cloudStoreID,
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

            let results: [(input: URL, output: URL, ok: Bool)] = await withTaskGroup(of: (URL, URL, Bool).self) { group in
                for inputURL in batch {
                    group.addTask {
                        let fileName  = inputURL.lastPathComponent
                        let outputURL = convertedDir.appendingPathComponent(
                            (fileName as NSString).deletingPathExtension + ".mp4"
                        )
                        let taskID = await MainActor.run {
                            self.taskID(forFileName: fileName, deckName: deckName)
                        }
                        await MainActor.run {
                            session.log("  🎬 Converting \(fileName) (\(deckName))...")
                            if let id = taskID { self.updateTask(id: id, phase: .converting, convertProgress: 0) }
                        }

                        let ok = await ConversionService.convert(
                            input: inputURL, output: outputURL, settings: settings
                        ) { pct in
                            if let id = taskID {
                                Task { @MainActor in self.updateTask(id: id, convertProgress: pct) }
                            }
                        }

                        await MainActor.run {
                            if ok, let id = taskID { self.updateTask(id: id, phase: .done, convertProgress: 1) }
                            if !ok, let id = taskID { self.updateTask(id: id, phase: .error, errorMessage: "Conversion failed") }
                        }
                        return (inputURL, outputURL, ok)
                    }
                }
                var collected: [(URL, URL, Bool)] = []
                for await result in group { collected.append(result) }
                return collected
            }

            for (input, output, ok) in results {
                if ok {
                    session.log("  ✅ Converted → \(output.lastPathComponent) (\(deckName))")
                    session.converted += 1
                    convertedFiles.append(output)
                    if deleteOriginal { try? FileManager.default.removeItem(at: input) }
                } else {
                    session.log("  ❌ Conversion failed: \(input.lastPathComponent) (\(deckName))")
                    session.errors += 1
                    if !deleteOriginal { convertedFiles.append(input) }
                }
            }
        }

        context.files = convertedFiles
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
                index: index + 1
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

    // MARK: - Control HyperDeck step

    private func runControlDeck(context: inout StepContext, command: DeckCommand, stopAfterMinutes: Int?) async {
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

            guard let minutes = stopAfterMinutes else { return }

            session.log("  ⏳ Will stop \(deck.name) after \(minutes) minute\(minutes == 1 ? "" : "s")...")
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !session.isCancelled else { return }

            await service.stop()
            if let error = service.lastError {
                session.log("  ❌ \(deck.name) failed to stop recording: \(error)")
                session.errors += 1
            } else {
                session.log("  ⏹ \(deck.name) stopped recording")
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

        let deletedCount = await Task.detached(priority: .background) {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: base,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }

            var deleted = 0
            let urls = enumerator.compactMap { $0 as? URL }
            for url in urls {
                guard !url.hasDirectoryPath else { continue }
                if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   mod < cutoff {
                    try? fm.removeItem(at: url)
                    deleted += 1
                }
            }
            return deleted
        }.value

        session.log("  🗑 Cleanup removed \(deletedCount) old file(s)")
    }

    // MARK: - Trigger Workflow step

    /// Starts another workflow from within this one. Runs it through the
    /// normal `start` path — its own session, its own log, its own history
    /// entry — so it shows up in the Dashboard exactly like a manually or
    /// schedule-triggered run.
    private func runTriggerWorkflow(
        workflowID: UUID?, waitForCompletion: Bool,
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
        guard appState.canRun(target) else {
            session.log("  ⚠️ Trigger Workflow: \"\(target.name)\" can't start — one of its devices is already busy")
            return
        }

        let nextChain = triggerChain.union([workflowID])
        let targets = targetDevices(for: target)

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
        guard GmailAuthService.shared.isConnected else {
            session.log("  ⚠️ Notification: connect a Gmail account in Settings to send email")
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
                try await GmailSendService.send(to: [recipient.email], subject: recipientHeader, body: recipientMessage, isHTML: isHTML)
            } catch {
                let reason: String
                if case GmailSendService.SendError.requestFailed(let message) = error {
                    reason = message
                } else if case GmailSendService.SendError.notConnected = error {
                    reason = "Gmail account not connected"
                } else {
                    reason = error.localizedDescription
                }
                failed.append((recipient.email, reason))
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

    private func finishRun(workflow: Workflow, session: WorkflowRunSession) {
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
            log:            session.lines
        )
        appState.workflowRunHistory.insert(run, at: 0)
        if appState.workflowRunHistory.count > 50 {
            appState.workflowRunHistory = Array(appState.workflowRunHistory.prefix(50))
        }

        appState.finish(session)
        NotificationService.sendCompletion(converted: c, errors: e)
    }

    // MARK: - Helpers

    /// "All Devices" (an empty target list) means every configured HyperDeck
    /// and Local Folder — it deliberately excludes Cloud Store Folders,
    /// since a Cloud Store has no single fixed folder the way those two do;
    /// a Cloud Store Folder only ever runs when explicitly added as a
    /// target with its own chosen path.
    private func targetDevices(for workflow: Workflow) -> [WorkflowTargetDevice] {
        guard !workflow.targets.isEmpty else {
            return appState.hyperDecks.map(WorkflowTargetDevice.hyperDeck)
                + appState.localFolders.map(WorkflowTargetDevice.localFolder)
        }
        return workflow.targets.compactMap { target in
            switch target {
            case .hyperDeck(let id):
                return appState.hyperDecks.first { $0.id == id }.map(WorkflowTargetDevice.hyperDeck)
            case .localFolder(let id):
                return appState.localFolders.first { $0.id == id }.map(WorkflowTargetDevice.localFolder)
            case .cloudStore(let id, let path):
                return appState.cloudStores.first { $0.id == id }.map { WorkflowTargetDevice.cloudStore($0, path: path) }
            }
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
        in session: WorkflowRunSession
    ) -> SyncTask {
        let t = SyncTask(fileName: fileName, deckName: deckName, destDir: destDir, cloudStoreID: cloudStoreID)
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

    private func updateTask(
        id: UUID,
        phase: SyncTask.Phase? = nil,
        syncProgress: Double? = nil,
        convertProgress: Double? = nil,
        errorMessage: String? = nil
    ) {
        for session in appState.activeRuns {
            guard let i = session.tasks.firstIndex(where: { $0.id == id }) else { continue }
            if let v = phase           { session.tasks[i].phase           = v }
            if let v = syncProgress    { session.tasks[i].syncProgress    = v }
            if let v = convertProgress { session.tasks[i].convertProgress = v }
            if let v = errorMessage    { session.tasks[i].errorMessage    = v }
            return
        }
    }

    /// Clears a task back to its initial state before a retry attempt.
    private func resetTask(id: UUID) {
        for session in appState.activeRuns {
            guard let i = session.tasks.firstIndex(where: { $0.id == id }) else { continue }
            session.tasks[i].phase           = .downloading
            session.tasks[i].syncProgress    = 0
            session.tasks[i].convertProgress = 0
            session.tasks[i].errorMessage    = nil
            return
        }
    }
}
