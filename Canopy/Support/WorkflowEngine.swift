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

    /// Per-deck state threaded through a workflow's steps.
    private struct StepContext {
        let deck: HyperDeck
        let destDir: URL
        var files: [URL] = []
        let session: WorkflowRunSession
    }

    // MARK: - Run (all target devices)

    func run(_ workflow: Workflow) async {
        await start(workflow, decks: targetDecks(for: workflow))
    }

    // MARK: - Run (single device)
    // Runs the workflow's steps against exactly one device, regardless of
    // that workflow's own target list — used by the per-device "Run
    // Workflow" action on the Dashboard.

    func runDevice(_ workflow: Workflow, deck: HyperDeck) async {
        await start(workflow, decks: [deck])
    }

    // MARK: - Shared run loop

    private func start(_ workflow: Workflow, decks: [HyperDeck]) async {
        // The Run buttons are already disabled when this would conflict, so
        // this mainly guards races — e.g. the scheduler firing at the same
        // instant someone taps Run manually.
        guard appState.canRun(workflow) else { return }

        let session = appState.beginRun(for: workflow, deckNames: Set(decks.map(\.name)))
        session.log("▶ Workflow started: \(workflow.name)")

        guard !decks.isEmpty else {
            session.log("⚠️ No devices configured for this workflow")
            finishRun(workflow: workflow, session: session)
            return
        }

        // Each deck may point at its own Cloud Store, or fall back to the
        // shared global destination — mount every distinct store exactly
        // once and reuse the resolved path for every deck that needs it.
        // This is done up front so every deck has a ready context before
        // the step loop below starts fanning steps out across them.
        var mountedPaths: [UUID?: String] = [:]
        var contexts: [StepContext] = []

        for deck in decks {
            guard workflow.needsDestinationMount else {
                contexts.append(StepContext(deck: deck, destDir: URL(fileURLWithPath: "/dev/null"), session: session))
                continue
            }
            do {
                let destDir = try await resolveDestination(for: deck, session: session, cache: &mountedPaths)
                try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                contexts.append(StepContext(deck: deck, destDir: destDir, session: session))
            } catch {
                session.log("❌ \(deck.name): \(error.localizedDescription)")
                session.mountError = error.localizedDescription
                session.errors += 1
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

            contexts = await withTaskGroup(of: StepContext.self) { group in
                for context in contexts {
                    group.addTask {
                        var context = context
                        await self.execute(step, context: &context)
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
                deck: contexts.first?.deck ?? HyperDeck(name: "Workflow", ipAddress: "", remotePath: ""),
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
    // run, using each deck's normal destination (its Cloud Store, or the
    // shared global destination) and the app's current conversion settings.
    // Gets its own session like any other run, so it's blocked only if one
    // of those specific decks is already busy elsewhere.

    func retryFailed() async {
        let failed = appState.failedTasks
        guard !failed.isEmpty else { return }

        let deckNames = Set(failed.map(\.deckName))
        guard appState.busyDeckNames.isDisjoint(with: deckNames) else { return }

        let workflow = Workflow(name: "Retry Failed")
        let session = appState.beginRun(for: workflow, deckNames: deckNames)
        session.log("↩ Retrying \(failed.count) failed file(s)...")

        var mountedPaths: [UUID?: String] = [:]
        let byDeck = Dictionary(grouping: failed, by: \.deckName)

        for (deckName, tasks) in byDeck {
            guard let deck = appState.hyperDecks.first(where: { $0.name == deckName }) else { continue }

            let destDir: URL
            do {
                destDir = try await resolveDestination(for: deck, session: session, cache: &mountedPaths)
            } catch {
                session.log("❌ \(deck.name): \(error.localizedDescription)")
                session.mountError = error.localizedDescription
                session.errors += 1
                continue
            }

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
                var context = StepContext(deck: deck, destDir: destDir, files: toConvert, session: session)
                await runConvert(context: &context, preset: .fast, deleteOriginal: true, maxParallelJobs: 2)
            }
        }

        session.log("↩ Retry complete")
        finishRun(workflow: workflow, session: session)
        appState.pruneCleanSessions()
    }

    // MARK: - Step dispatch

    private func execute(_ step: WorkflowStep, context: inout StepContext) async {
        switch step.action {
        case .controlDeck(let command, let stopAfterMinutes):
            await runControlDeck(context: &context, command: command, stopAfterMinutes: stopAfterMinutes)
        case .wait(let minutes):
            await runWait(minutes: minutes, session: context.session)
        case .sync:
            await runSync(context: &context)
        case .convert(let preset, let deleteOriginal, let maxParallelJobs):
            await runConvert(context: &context, preset: preset, deleteOriginal: deleteOriginal, maxParallelJobs: maxParallelJobs)
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

    private func runSync(context: inout StepContext) async {
        let deck = context.deck
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
            let convertedURL = context.destDir
                .appendingPathComponent("Converted")
                .appendingPathComponent((fileName as NSString).deletingPathExtension + ".mp4")

            if FileManager.default.fileExists(atPath: convertedURL.path) {
                session.log("  ⏭ \(fileName) already processed")
                session.skipped += 1
                continue
            }

            let task = addTask(fileName: fileName, deckName: deck.name, in: session)
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

    // MARK: - Convert step

    private func runConvert(context: inout StepContext, preset: ConversionSettings.FFmpegPreset, deleteOriginal: Bool, maxParallelJobs: Int) async {
        let session = context.session
        guard !context.files.isEmpty else {
            session.log("  ⏭ Convert: no files to convert")
            return
        }

        let settings = ConversionSettings(preset: preset)

        let convertedDir = context.destDir.appendingPathComponent("Converted")
        try? FileManager.default.createDirectory(at: convertedDir, withIntermediateDirectories: true)

        let maxJobs = maxParallelJobs
        let batches = stride(from: 0, to: context.files.count, by: maxJobs).map {
            Array(context.files[$0 ..< min($0 + maxJobs, context.files.count)])
        }

        let deckName = context.deck.name
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
                deviceName: context.deck.name,
                index: index + 1
            )
            let newURL = url.deletingLastPathComponent().appendingPathComponent("\(newName).\(ext)")

            do {
                if FileManager.default.fileExists(atPath: newURL.path) {
                    try FileManager.default.removeItem(at: newURL)
                }
                try FileManager.default.moveItem(at: url, to: newURL)
                session.log("  ✏️ Renamed → \(newURL.lastPathComponent) (\(context.deck.name))")
                renamed.append(newURL)
            } catch {
                session.log("  ❌ Rename failed for \(url.lastPathComponent) (\(context.deck.name)): \(error.localizedDescription)")
                session.errors += 1
                renamed.append(url)
            }
        }

        context.files = renamed
    }

    // MARK: - Control HyperDeck step

    private func runControlDeck(context: inout StepContext, command: DeckCommand, stopAfterMinutes: Int?) async {
        let deck = context.deck
        let session = context.session
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
        session.log("  🗑 Erasing \(context.deck.name)'s drive (\(context.deck.ipAddress))...")
        do {
            try await HyperDeckService.formatDrive(deck: context.deck)
            session.log("  ✅ \(context.deck.name)'s drive erased successfully")
        } catch {
            session.log("  ❌ \(context.deck.name) drive erase failed: \(error.localizedDescription)")
            session.errors += 1
        }
    }

    // MARK: - Cleanup step

    private func runCleanup(context: inout StepContext, retentionDays: Int) async {
        let session = context.session
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let base = context.destDir
        session.log("  🧹 Cleaning \(context.deck.name)'s destination folder — removing files older than \(retentionDays) day(s)...")

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

    private func targetDecks(for workflow: Workflow) -> [HyperDeck] {
        guard !workflow.targetDeckIDs.isEmpty else { return appState.hyperDecks }
        return appState.hyperDecks.filter { workflow.targetDeckIDs.contains($0.id) }
    }

    private func mountSMBVolume(location: SyncLocation) async throws -> String {
        try await SMBService.mountAndResolve(
            ip:       location.ipAddress,
            volume:   location.volumeName,
            username: location.username,
            password: location.password
        )
    }

    /// Resolves the destination folder for a single deck: its own assigned
    /// Cloud Store + subfolder if one is set, otherwise the shared global
    /// sync destination. Mounts are cached per store so decks sharing a
    /// store (including "no store" → the global default) only mount once
    /// per run.
    private func resolveDestination(
        for deck: HyperDeck, session: WorkflowRunSession, cache mountedPaths: inout [UUID?: String]
    ) async throws -> URL {
        if let storeID = deck.cloudStoreID,
           let store = appState.cloudStores.first(where: { $0.id == storeID }) {
            let mountPath: String
            if let cached = mountedPaths[storeID] {
                mountPath = cached
            } else {
                session.log("Mounting \(store.name)...")
                mountPath = try await SMBService.mount(store: store)
                mountedPaths[storeID] = mountPath
                session.log("✅ Mounted \(store.name) at \(mountPath)")
            }
            // Use the folder the user picked in Sync Destination exactly as
            // selected — don't nest an extra deck-name subfolder inside it.
            let base = URL(fileURLWithPath: mountPath)
            return deck.cloudStorePath.isEmpty ? base : base.appendingPathComponent(deck.cloudStorePath)
        }

        // No store assigned — fall back to the shared global destination.
        let mountPath: String
        if let cached = mountedPaths[nil] {
            mountPath = cached
        } else {
            session.log("Mounting \(appState.syncLocation.volumeName)...")
            mountPath = try await mountSMBVolume(location: appState.syncLocation)
            appState.syncLocation.resolvedMountPath = mountPath
            mountedPaths[nil] = mountPath
            session.log("✅ Mounted at \(mountPath)")
        }
        return URL(fileURLWithPath: appState.syncLocation.recordsPath)
            .appendingPathComponent(deck.name)
    }

    @discardableResult
    private func addTask(fileName: String, deckName: String, in session: WorkflowRunSession) -> SyncTask {
        let t = SyncTask(fileName: fileName, deckName: deckName)
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
