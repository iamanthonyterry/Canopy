import Foundation
import Combine

// Starts workflows when their triggers fire. Two kinds of trigger:
//
// - Clock triggers (daily / one-time) are checked by a 30-second polling
//   timer — lightweight and reliable without a background daemon or
//   LaunchAgent.
// - Event triggers react to something happening: a deck stops recording or
//   comes back online (observed through ConnectionMonitor), another workflow
//   finishes (reported by WorkflowEngine), or new clips land in a Local
//   Folder (checked on the same 30-second tick).
@MainActor
class SchedulerService: ObservableObject {
    static let shared = SchedulerService()

    private var timer: Timer?
    /// Tracks which daily triggers already fired today, keyed by trigger id
    /// (each trigger fires independently of the others on its workflow).
    private var triggersFiredToday: [UUID: Date] = [:]

    private let appState = AppState.shared
    private let workflowEngine = WorkflowEngine.shared
    private let monitor = ConnectionMonitor.shared

    // MARK: - Event state

    private var cancellables = Set<AnyCancellable>()
    private var previousRecordingHosts: Set<String> = []
    private var previousStatuses: [String: DeckStatus] = [:]

    /// When each event trigger (per device it fired for) last started a run.
    private var lastEventFire: [String: Date] = [:]

    /// An event that should start a run but couldn't yet because a device it
    /// needs was busy. Retried on every tick until it starts — it never
    /// times out, since a long offload can keep a deck busy well past the
    /// moment the next recording ends — or until its trigger is turned off
    /// or removed. Events for the same trigger and device collapse into one.
    private struct PendingFire {
        let key: String
        let triggerID: UUID
        let workflowID: UUID
        let device: WorkflowEngine.WorkflowTargetDevice?
        let reason: String
    }
    private var pending: [String: PendingFire] = [:]

    /// Per watched folder: files already handled, and files seen last tick
    /// with their size (a clip only counts once its size stops changing, so
    /// a file that's still being copied in isn't picked up half-written).
    private struct FolderWatch {
        var known: Set<String> = []
        var pendingSizes: [String: Int64] = [:]
    }
    private var folderWatches: [UUID: FolderWatch] = [:]

    private init() {
        observeDevices()
    }

    // Call at app launch and whenever any workflow's schedule changes
    func sync() {
        timer?.invalidate()
        pruneFolderWatches()
        seedFolderWatches()
        guard hasAnyScheduleEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 10
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var hasAnyScheduleEnabled: Bool {
        appState.workflows.contains { $0.isScheduled }
    }

    // MARK: - Tick
    private func tick() {
        tickWorkflowSchedules()
        tickFolderWatches()
        retryPending()
    }

    // MARK: - Clock triggers
    // Each workflow can have several triggers, evaluated independently. A
    // due trigger only fires if none of its workflow's target devices are
    // already busy in another run — if it's due but busy, it's left alone
    // (not marked as fired) so it's retried on the next tick instead of
    // being skipped for the day.
    private func tickWorkflowSchedules() {
        for workflow in appState.workflows {
            for trigger in workflow.triggers {
                guard trigger.isEnabled else { continue }

                switch trigger.mode {
                case .daily:
                    guard isDue(hour: trigger.hour, minute: trigger.minute) else {
                        if let last = triggersFiredToday[trigger.id], !Calendar.current.isDateInToday(last) {
                            triggersFiredToday.removeValue(forKey: trigger.id)
                        }
                        continue
                    }
                    guard isTodayActive(for: trigger) else { continue }
                    guard triggersFiredToday[trigger.id] == nil else { continue }
                    guard fire(workflow, reason: "Scheduled workflow triggered") else { continue }
                    triggersFiredToday[trigger.id] = Date()

                    if !trigger.repeatDaily {
                        disableTrigger(workflowID: workflow.id, triggerID: trigger.id)
                    }

                case .oneTime:
                    guard isDue(date: trigger.oneTimeDate) else { continue }
                    guard fire(workflow, reason: "Scheduled workflow triggered") else { continue }

                    // One-time triggers always turn themselves off after firing.
                    disableTrigger(workflowID: workflow.id, triggerID: trigger.id)

                case .recordingStopped, .deviceOnline, .workflowFinished, .folderChanged:
                    // Event triggers are driven by their own sources.
                    continue
                }
            }
        }
    }

    /// Starts a workflow — on one specific device if given, otherwise on all
    /// of its targets — unless a device it needs is already busy in another
    /// run, in which case it's left for the caller to retry.
    @discardableResult
    private func fire(
        _ workflow: Workflow,
        device: WorkflowEngine.WorkflowTargetDevice? = nil,
        reason: String
    ) -> Bool {
        guard appState.canRun(workflow) else { return false }
        appState.log("🕐 \(reason): \(workflow.name)")
        Task {
            if let device {
                await workflowEngine.runDevice(workflow, target: device)
            } else {
                await workflowEngine.run(workflow)
            }
        }
        return true
    }

    /// Flips a single trigger's `isEnabled` off after it fires, leaving the
    /// rest of the workflow's triggers untouched.
    private func disableTrigger(workflowID: UUID, triggerID: UUID) {
        guard var updated = appState.workflows.first(where: { $0.id == workflowID }) else { return }
        guard let index = updated.triggers.firstIndex(where: { $0.id == triggerID }) else { return }
        updated.triggers[index].isEnabled = false
        appState.updateWorkflow(updated)
    }

    private func isDue(hour: Int, minute: Int) -> Bool {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return now.hour == hour && now.minute == minute
    }

    /// Whether today's weekday is one of the days this recurring schedule
    /// is set to run on (an empty selection means every day).
    private func isTodayActive(for schedule: ScheduleSettings) -> Bool {
        guard let weekday = Weekday(rawValue: Calendar.current.component(.weekday, from: Date())) else {
            return true
        }
        return schedule.activeWeekdays.contains(weekday)
    }

    /// A one-time schedule is due once its target moment has arrived — since
    /// it disables itself immediately after firing, there's no need to guard
    /// against firing twice in the same minute.
    private func isDue(date target: Date) -> Bool {
        Date() >= target
    }

    // MARK: - Event dispatch

    /// Queues an event for a workflow and tries to start it straight away.
    /// Skipped while the trigger is still inside its cooldown.
    private func enqueue(
        _ workflow: Workflow,
        trigger: ScheduleSettings,
        device: WorkflowEngine.WorkflowTargetDevice?,
        reason: String
    ) {
        let key = "\(trigger.id.uuidString)|\(device?.name ?? "-")"
        if let last = lastEventFire[key],
           Date().timeIntervalSince(last) < Double(max(trigger.cooldownMinutes, 0)) * 60 {
            return
        }
        let event = PendingFire(
            key: key, triggerID: trigger.id, workflowID: workflow.id, device: device, reason: reason
        )
        if attempt(event) { return }
        pending[key] = event
    }

    /// Returns true once the event has been handled (started, or no longer
    /// relevant because its workflow or trigger was removed or turned off).
    private func attempt(_ event: PendingFire) -> Bool {
        guard let workflow = appState.workflows.first(where: { $0.id == event.workflowID }),
              workflow.triggers.contains(where: { $0.id == event.triggerID && $0.isEnabled }) else { return true }
        guard fire(workflow, device: event.device, reason: event.reason) else { return false }
        lastEventFire[event.key] = Date()
        return true
    }

    private func retryPending() {
        for (key, event) in pending where attempt(event) {
            pending.removeValue(forKey: key)
        }
    }

    /// Whether a workflow would normally run on this deck: one of its deck
    /// steps names it, or covers every deck.
    private func workflow(_ workflow: Workflow, covers deck: HyperDeck) -> Bool {
        workflow.usesDeck(deck.id)
    }

    // MARK: - Deck events

    private func observeDevices() {
        previousRecordingHosts = monitor.recordingHosts
        previousStatuses = monitor.statuses

        monitor.$recordingHosts
            .sink { [weak self] hosts in
                Task { @MainActor in self?.recordingHostsChanged(to: hosts) }
            }
            .store(in: &cancellables)

        monitor.$statuses
            .sink { [weak self] statuses in
                Task { @MainActor in self?.statusesChanged(to: statuses) }
            }
            .store(in: &cancellables)
    }

    private func recordingHostsChanged(to hosts: Set<String>) {
        let stopped = previousRecordingHosts.subtracting(hosts)
        previousRecordingHosts = hosts

        for host in stopped {
            // A deck that dropped off the network also stops reporting a
            // recording, and a deck can blip between polls — so confirm it's
            // still reachable and idle a moment later before acting.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self,
                      self.monitor.status(for: host) == .online,
                      !self.monitor.isRecording(host: host) else { return }
                self.dispatchDeckEvent(.recordingStopped, host: host)
            }
        }
    }

    private func statusesChanged(to statuses: [String: DeckStatus]) {
        let before = previousStatuses
        previousStatuses = statuses

        for (host, status) in statuses where status == .online {
            // Only a real recovery counts — not the first poll after launch
            // (previous status unknown), and not a device that was already online.
            guard let previous = before[host], Self.recoverable.contains(previous) else { continue }
            dispatchDeckEvent(.deviceOnline, host: host)
        }
    }

    private static let recoverable: Set<DeckStatus> = [.offline, .unauthorized, .pathNotFound, .noMedia]

    private func dispatchDeckEvent(_ mode: ScheduleMode, host: String) {
        guard let deck = appState.hyperDecks.first(where: { $0.ipAddress == host }) else { return }

        for workflow in appState.workflows {
            for trigger in workflow.triggers where trigger.isEnabled && trigger.mode == mode {
                if let deviceID = trigger.deviceID {
                    guard deviceID == deck.id else { continue }
                } else {
                    guard self.workflow(workflow, covers: deck) else { continue }
                }
                let what = mode == .recordingStopped ? "stopped recording" : "came online"
                enqueue(
                    workflow, trigger: trigger, device: .hyperDeck(deck),
                    reason: "\(deck.name) \(what) — workflow triggered"
                )
            }
        }
    }

    // MARK: - Workflow finished

    /// Called by the engine when a run ends. Runs the user stopped by hand
    /// don't count.
    func workflowFinished(_ finished: Workflow, errors: Int, wasCancelled: Bool) {
        guard !wasCancelled else { return }

        for workflow in appState.workflows where workflow.id != finished.id {
            for trigger in workflow.triggers
            where trigger.isEnabled && trigger.mode == .workflowFinished
                && trigger.sourceWorkflowID == finished.id {
                switch trigger.finishCondition {
                case .any:           break
                case .withoutErrors: guard errors == 0 else { continue }
                case .withErrors:    guard errors > 0 else { continue }
                }
                enqueue(
                    workflow, trigger: trigger, device: nil,
                    reason: "\(finished.name) finished — workflow triggered"
                )
            }
        }
    }

    // MARK: - Folder watching

    private func tickFolderWatches() {
        for workflow in appState.workflows {
            for trigger in workflow.triggers where trigger.isEnabled && trigger.mode == .folderChanged {
                guard let folderID = trigger.deviceID,
                      let folder = appState.localFolders.first(where: { $0.id == folderID }),
                      folder.exists else { continue }

                let current = Self.clipSizes(in: folder.path)

                // First look at a folder just records what's already there —
                // only clips that arrive afterwards fire the trigger.
                guard var state = folderWatches[trigger.id] else {
                    folderWatches[trigger.id] = FolderWatch(known: Set(current.keys))
                    continue
                }

                var ready: [String] = []
                for (path, size) in current where !state.known.contains(path) {
                    if state.pendingSizes[path] == size {
                        ready.append(path)
                    } else {
                        state.pendingSizes[path] = size
                    }
                }
                // Forget anything that vanished while still settling.
                state.pendingSizes = state.pendingSizes.filter { current[$0.key] != nil }
                folderWatches[trigger.id] = state

                guard !ready.isEmpty else { continue }

                let count = ready.count
                let reason = "\(count) new clip\(count == 1 ? "" : "s") in \(folder.name) — workflow triggered"
                let key = "\(trigger.id.uuidString)|\(folder.name)"
                let cooledDown = lastEventFire[key].map {
                    Date().timeIntervalSince($0) >= Double(max(trigger.cooldownMinutes, 0)) * 60
                } ?? true
                guard cooledDown else { continue }

                let event = PendingFire(
                    key: key, triggerID: trigger.id, workflowID: workflow.id,
                    device: .localFolder(folder), reason: reason
                )
                // Only mark clips as handled once a run actually started, so
                // a busy workflow picks them up on the next tick.
                if attempt(event) {
                    state.known.formUnion(ready)
                    state.pendingSizes = state.pendingSizes.filter { !ready.contains($0.key) }
                    folderWatches[trigger.id] = state
                }
            }
        }
    }

    /// Top-level convertible clips in a folder, with their sizes.
    private static func clipSizes(in path: String) -> [String: Int64] {
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [:] }

        var result: [String: Int64] = [:]
        for entry in entries where ConversionService.canConvert(url: entry) {
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            result[entry.path] = Int64(size)
        }
        return result
    }

    /// Records what's already in each watched folder the moment a trigger is
    /// saved or turned on, rather than on the first tick up to 30 seconds
    /// later — otherwise a clip dropped in right after saving would be
    /// swallowed into the baseline and never fire.
    private func seedFolderWatches() {
        for workflow in appState.workflows {
            for trigger in workflow.triggers where trigger.isEnabled && trigger.mode == .folderChanged {
                guard folderWatches[trigger.id] == nil,
                      let folderID = trigger.deviceID,
                      let folder = appState.localFolders.first(where: { $0.id == folderID }),
                      folder.exists else { continue }
                folderWatches[trigger.id] = FolderWatch(known: Set(Self.clipSizes(in: folder.path).keys))
            }
        }
    }

    /// Drops watch state for triggers that no longer exist or were turned
    /// off, so re-enabling one starts from a fresh baseline instead of
    /// firing for everything that arrived while it was off.
    private func pruneFolderWatches() {
        let active = Set(appState.workflows.flatMap { workflow in
            workflow.triggers.filter { $0.isEnabled && $0.mode == .folderChanged }.map(\.id)
        })
        folderWatches = folderWatches.filter { active.contains($0.key) }
    }
}
