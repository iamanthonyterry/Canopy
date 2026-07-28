import Foundation
import Combine

// Watches the clock and runs any workflow when its scheduled time arrives.
// Uses a 30-second polling interval — lightweight and reliable without
// needing a background daemon or LaunchAgent.
@MainActor
class SchedulerService: ObservableObject {
    static let shared = SchedulerService()

    private var timer: Timer?
    /// Tracks which daily triggers already fired today, keyed by trigger id
    /// (each trigger fires independently of the others on its workflow).
    private var triggersFiredToday: [UUID: Date] = [:]

    private let appState = AppState.shared
    private let workflowEngine = WorkflowEngine.shared

    // Call at app launch and whenever any workflow's schedule changes
    func sync() {
        timer?.invalidate()
        guard hasAnyScheduleEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
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
        guard !appState.isRunning else { return }
        tickWorkflowSchedules()
    }

    // MARK: - Per-workflow schedules
    // Each workflow can have several triggers; they're evaluated independently
    // and only one run is started per tick (guarded by appState.isRunning).
    private func tickWorkflowSchedules() {
        for workflow in appState.workflows {
            guard !appState.isRunning else { return }   // only one run at a time

            for trigger in workflow.triggers {
                guard trigger.isEnabled else { continue }
                guard !appState.isRunning else { return }

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
                    triggersFiredToday[trigger.id] = Date()

                    appState.log("🕐 Scheduled workflow triggered: \(workflow.name)")
                    Task { await workflowEngine.run(workflow) }

                    if !trigger.repeatDaily {
                        disableTrigger(workflowID: workflow.id, triggerID: trigger.id)
                    }
                    return

                case .oneTime:
                    guard isDue(date: trigger.oneTimeDate) else { continue }

                    appState.log("🕐 Scheduled workflow triggered: \(workflow.name)")
                    Task { await workflowEngine.run(workflow) }

                    // One-time triggers always turn themselves off after firing.
                    disableTrigger(workflowID: workflow.id, triggerID: trigger.id)
                    return
                }
            }
        }
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
}
