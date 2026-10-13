import Foundation

/// How much longer a run is expected to take, as worked out at one moment.
struct RunEstimate: Equatable {
    var secondsRemaining: Double
    /// True when part of what's left has no known duration (a step that has
    /// never run before, say), so the run will take at least this long.
    var isLowerBound = false
    /// When this was worked out. Views count down from here on their own
    /// clock, since a Wait step or a long transcription publishes nothing
    /// that would otherwise refresh the figure.
    var asOf = Date()
    /// False while the run is held for a person (a confirmation prompt, or
    /// paused between steps) — nothing is getting closer to done.
    var countsDown = true

    func remaining(at date: Date) -> Double {
        guard countsDown else { return secondsRemaining }
        return max(0, secondsRemaining - date.timeIntervalSince(asOf))
    }

    /// "~12m left", "12m+ left" for a lower bound, "almost done" once the
    /// countdown has run out. Nil when there's nothing useful to say — a
    /// lower bound that has run out tells you nothing about what's left.
    func label(at date: Date) -> String? {
        let left = remaining(at: date)
        guard left >= 1 else { return isLowerBound ? nil : "almost done" }
        let duration = TaskRow.formatDuration(left)
        return isLowerBound ? "\(duration)+ left" : "~\(duration) left"
    }

    /// Several runs going at once are all done when the slowest one is.
    static func latest(of estimates: [RunEstimate]) -> RunEstimate? {
        guard var latest = estimates.max(by: { $0.secondsRemaining < $1.secondsRemaining }) else { return nil }
        latest.isLowerBound = estimates.contains(where: \.isLowerBound)
        return latest
    }
}

// MARK: - Working out an estimate

extension WorkflowRunSession {
    /// Time left across every step that hasn't finished — not just the
    /// download in flight. Each step contributes whatever is known about it:
    ///
    /// - Sync: bytes still to transfer (and re-read, when verifying) at each
    ///   device's speed. Devices download side by side, so it's the slowest
    ///   device that counts, not the sum.
    /// - Convert: time left on running encodes plus the rest at the rate
    ///   this run has been converting, spread over the encode slots.
    /// - Wait / timed recording: exactly what's left on the clock.
    /// - Everything else: how long the step took last time, scaled to this
    ///   run's footage (see `RunTimingHistory`).
    ///
    /// Nil when nothing about the remaining work is known yet.
    func estimate(at now: Date = Date()) -> RunEstimate? {
        guard !isFinished else { return nil }
        let open = stepRuns.filter { $0.status == .pending || $0.status == .awaitingConfirmation || $0.status == .running }
        guard !open.isEmpty else { return nil }

        var total = 0.0
        var hasFigure = false
        var isLowerBound = false
        func add(_ seconds: Double?) {
            guard let seconds else { isLowerBound = true; return }
            total += seconds
            hasFigure = true
        }
        func elapsed(_ run: StepRun) -> Double {
            guard run.status == .running, let start = run.startedAt else { return 0 }
            return max(0, now.timeIntervalSince(start))
        }
        func fixed(_ duration: Double, _ run: StepRun) -> Double { max(0, duration - elapsed(run)) }
        /// What the step took last time, less what it has already used. A
        /// step that has outrun that figure has an unknown amount left.
        func learned(_ run: StepRun) -> Double? {
            guard let timing = timingHistory.timing(forStep: run.step.id) else { return nil }
            var predicted = timing.seconds
            let bytes = tasks.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
            if Self.scalesWithFootage(run.step.action), timing.bytes > 0, bytes > 0 {
                predicted *= Double(bytes) / Double(timing.bytes)
            }
            let left = predicted - elapsed(run)
            if left < 0 { isLowerBound = true }
            return max(0, left)
        }

        let syncIsRunning = open.contains { $0.status == .running && $0.step.kind == .sync }
        // A Sync step that hasn't listed its files yet leaves nothing to
        // measure, for it or for the Convert step that follows.
        let filesKnown = !tasks.isEmpty && !open.contains { $0.status != .running && $0.step.kind == .sync }

        for run in open {
            switch run.step.action {
            case .wait(let minutes):
                add(fixed(Double(minutes * 60), run))

            case .controlDeck:
                add(0)

            case .sync:
                if run.status == .running, !tasks.isEmpty {
                    add(downloadSecondsByDevice(at: now).map { $0.values.max() ?? 0 })
                } else {
                    add(learned(run))
                }

            case .convert(let preset, _, let maxParallelJobs, _):
                guard filesKnown else {
                    // A pipelined pair ran as one last time too, so the Sync
                    // step's figure already covers both.
                    add(isPipelined(run.step) ? 0 : learned(run))
                    continue
                }
                guard let work = convertWork(preset: preset, maxParallelJobs: maxParallelJobs, at: now) else {
                    add(nil)
                    continue
                }
                if syncIsRunning, run.status == .running, let downloads = downloadSecondsByDevice(at: now) {
                    // Pipelined: files convert as they arrive, so the pair
                    // ends when the encodes catch up or when the last
                    // download has been converted, whichever is later. The
                    // Sync step above has already counted the downloads.
                    let lastFileConverted = downloads.map { $0.value + (work.lastDownloadByDevice[$0.key] ?? 0) }.max() ?? 0
                    add(max(work.seconds, lastFileConverted) - (downloads.values.max() ?? 0))
                } else {
                    add(work.seconds)
                }

            case .transcribe, .findClips, .exportPosts, .writeCopy, .copyTo, .reframe, .triggerWorkflow(_, true):
                add(learned(run))

            default:
                // Quick steps — a folder, a rename, a notification.
                add(learned(run) ?? 0)
            }
        }

        guard hasFigure else { return nil }
        let held = stepRuns.contains { $0.status == .awaitingConfirmation } || (isPaused && currentStepIndex == nil)
        return RunEstimate(secondsRemaining: max(0, total), isLowerBound: isLowerBound, asOf: now, countsDown: !held)
    }

    /// Seconds left on one step's own work, for its row in the step list.
    func secondsRemaining(for run: StepRun, at now: Date = Date()) -> Double? {
        guard run.status == .running, !tasks.isEmpty else { return nil }
        switch run.step.action {
        case .sync:
            return downloadSecondsByDevice(at: now).map { $0.values.max() ?? 0 }
        case .convert(let preset, _, let maxParallelJobs, _):
            return convertWork(preset: preset, maxParallelJobs: maxParallelJobs, at: now)?.seconds
        default:
            return nil
        }
    }

    private static func scalesWithFootage(_ action: StepAction) -> Bool {
        switch action {
        case .sync, .convert, .transcribe, .findClips, .exportPosts, .writeCopy, .copyTo, .reframe: return true
        default: return false
        }
    }

    /// Whether this Convert step runs interleaved with the Sync step before
    /// it — the same test the engine's run loop applies.
    private func isPipelined(_ convertStep: WorkflowStep) -> Bool {
        guard let i = workflow.steps.firstIndex(where: { $0.id == convertStep.id }), i > 0 else { return false }
        let syncStep = workflow.steps[i - 1]
        return syncStep.kind == .sync && !syncStep.requiresConfirmation && !convertStep.requiresConfirmation
    }

    // MARK: Files

    private var averageKnownSize: Double? {
        let sizes = tasks.map(\.fileSizeBytes).filter { $0 > 0 }
        guard !sizes.isEmpty else { return nil }
        return Double(sizes.reduce(0, +)) / Double(sizes.count)
    }

    /// A file whose size wasn't reported is assumed to be about as big as
    /// the ones that were, rather than counted as nothing.
    private func size(of task: SyncTask) -> Double? {
        task.fileSizeBytes > 0 ? Double(task.fileSizeBytes) : averageKnownSize
    }

    // MARK: Downloads

    private var verifiesOffload: Bool {
        workflow.steps.contains {
            if case .sync(_, let verify, let deleteFromDevice) = $0.action { return verify || deleteFromDevice }
            return false
        }
    }

    /// The speed to expect from a device: the file it's downloading now, or
    /// failing that its previous file, an earlier run, or the other devices
    /// in this run. Carrying a speed across files keeps the estimate from
    /// dropping out every time a new file starts.
    private func downloadSpeed(forDevice name: String) -> Double? {
        let measured = tasks.filter { $0.deckName == name && $0.bytesPerSecond > 0 }
        // A file's first few samples are noisy — until it has settled, the
        // file before it is the better guide.
        if let active = measured.last(where: { $0.phase == .downloading && $0.syncProgress >= 0.03 && $0.syncProgress < 1 }) {
            return active.bytesPerSecond
        }
        if let last = measured.last { return last.bytesPerSecond }
        if let earlierRun = timingHistory.downloadSpeed(forDevice: name) { return earlierRun }
        let others = tasks.map(\.bytesPerSecond).filter { $0 > 0 }
        return others.isEmpty ? nil : others.reduce(0, +) / Double(others.count)
    }

    /// Bytes this file still has to move: the rest of its download, plus a
    /// second pass over the device's copy when the offload is verified.
    private func transferBytesLeft(_ task: SyncTask, speed: Double?, at now: Date) -> Double {
        guard let size = size(of: task) else { return 0 }
        let verifyBytes = verifiesOffload ? size : 0
        guard task.phase == .downloading else { return size + verifyBytes }

        // Progress arrives in ~1% steps, so credit what has moved since the
        // last one rather than letting the figure sit still between them.
        let sinceSample = task.lastProgressAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let moved = (speed ?? 0) * sinceSample

        switch task.verification {
        case .verifying:
            return max(0, verifyBytes - moved)
        case .verified, .mismatch, .failed:
            return 0
        case .none:
            let left = size * (1 - task.syncProgress)
            return left - min(moved, size * 0.02, left) + verifyBytes
        }
    }

    /// Seconds of downloading left on each device that still has any. Nil
    /// when a device has files waiting but no speed to judge them by.
    private func downloadSecondsByDevice(at now: Date) -> [String: Double]? {
        let pending = tasks.filter { $0.phase == .queued || $0.phase == .downloading }
        var seconds: [String: Double] = [:]
        for (name, deviceTasks) in Dictionary(grouping: pending, by: \.deckName) {
            let speed = downloadSpeed(forDevice: name)
            let bytes = deviceTasks.reduce(0.0) { $0 + transferBytesLeft($1, speed: speed, at: now) }
            guard bytes > 0 else { continue }
            guard let speed, speed > 0 else { return nil }
            seconds[name] = bytes / speed
        }
        return seconds
    }

    // MARK: Conversions

    /// Encode seconds per source byte: measured from this run's finished and
    /// in-flight conversions, or remembered from an earlier run until then.
    private func convertSecondsPerByte(preset: ConversionSettings.FFmpegPreset, at now: Date) -> Double? {
        var seconds = 0.0
        var bytes = 0.0
        for task in tasks where task.fileSizeBytes > 0 {
            guard let started = task.convertStartedAt else { continue }
            if let finished = task.convertFinishedAt, task.phase == .done {
                seconds += finished.timeIntervalSince(started)
                bytes += Double(task.fileSizeBytes)
            } else if task.phase == .converting, task.convertProgress >= 0.05 {
                seconds += now.timeIntervalSince(started)
                bytes += Double(task.fileSizeBytes) * task.convertProgress
            }
        }
        if seconds > 0, bytes > 0 { return seconds / bytes }
        return timingHistory.convertSecondsPerByte(for: preset)
    }

    /// Time to convert everything not yet converted, and — per device — the
    /// encode time of the last file still to be downloaded. Nil when there's
    /// no rate to judge a waiting file by.
    private func convertWork(
        preset: ConversionSettings.FFmpegPreset, maxParallelJobs: Int, at now: Date
    ) -> (seconds: Double, lastDownloadByDevice: [String: Double])? {
        let waiting = tasks.filter { $0.phase != .error && $0.convertFinishedAt == nil }
        guard !waiting.isEmpty else { return (0, [:]) }
        let rate = convertSecondsPerByte(preset: preset, at: now)

        var perFile: [Double] = []
        var lastDownloadByDevice: [String: Double] = [:]
        for task in waiting {
            if task.phase == .converting, let started = task.convertStartedAt, task.convertProgress >= 0.05 {
                let spent = max(0, now.timeIntervalSince(started))
                perFile.append(spent * (1 - task.convertProgress) / task.convertProgress)
                continue
            }
            guard let rate else { return nil }
            let seconds = (size(of: task) ?? 0) * rate
            perFile.append(seconds)
            if task.phase == .queued || (task.phase == .downloading && task.syncProgress < 1) {
                lastDownloadByDevice[task.deckName] = seconds
            }
        }

        // Each device runs up to its own job count, all sharing the app-wide
        // encode slots — and however many slots there are, the run can't
        // finish before its longest single encode does.
        let devices = Set(waiting.map(\.deckName)).count
        let slots = max(1, min(conversionSlots, devices * max(1, maxParallelJobs)))
        let seconds = max(perFile.reduce(0, +) / Double(slots), perFile.max() ?? 0)
        return (seconds, lastDownloadByDevice)
    }

    // MARK: - Remembering this run

    /// Saves what this run measured, for the next run's estimate to start
    /// from. A stopped run is left out — its steps didn't run their course.
    func recordTimings() {
        guard !isCancelled else { return }

        let downloaded = tasks.filter { $0.bytesPerSecond > 0 && $0.fileSizeBytes > 0 }
        for (name, deviceTasks) in Dictionary(grouping: downloaded, by: \.deckName) {
            let bytes = deviceTasks.reduce(0.0) { $0 + Double($1.fileSizeBytes) }
            let seconds = deviceTasks.reduce(0.0) { $0 + Double($1.fileSizeBytes) / $1.bytesPerSecond }
            if seconds > 0 { timingHistory.recordDownloadSpeed(bytes / seconds, forDevice: name) }
        }

        let totalBytes = tasks.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        for run in stepRuns where run.status == .done {
            guard let started = run.startedAt, let finished = run.finishedAt else { continue }
            timingHistory.recordStep(run.step.id, seconds: finished.timeIntervalSince(started), bytes: totalBytes)

            guard case .convert(let preset, _, _, _) = run.step.action else { continue }
            var seconds = 0.0
            var bytes = 0.0
            for task in tasks where task.phase == .done && task.fileSizeBytes > 0 {
                guard let from = task.convertStartedAt, let to = task.convertFinishedAt else { continue }
                seconds += to.timeIntervalSince(from)
                bytes += Double(task.fileSizeBytes)
            }
            if bytes > 0 { timingHistory.recordConvert(secondsPerByte: seconds / bytes, for: preset) }
        }
    }
}
