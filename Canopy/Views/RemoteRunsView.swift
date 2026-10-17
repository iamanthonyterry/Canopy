import SwiftUI

// MARK: - Runs on other computers
// What's running (or just finished) on this person's other computers. Runs
// from Macs on the same network arrive over Bonjour (see PeerPresenceService)
// and are shown as soon as they start; the same runs, and ones from computers
// elsewhere, also come through the website sign-in with every step's progress
// (see RemoteRunsService). A run seen both ways is shown once. This also makes
// clear why a Run button is disabled and who to talk to. Hidden when nothing
// is running elsewhere.

struct RemoteRunsBanner: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var remote = RemoteRunsService.shared

    var body: some View {
        let lan = appState.remoteRuns
        let lanIDs = Set(lan.map { $0.run.id.uuidString.lowercased() })
        let cloud = remote.runs.filter { !lanIDs.contains($0.id.lowercased()) }
        if !lan.isEmpty || !cloud.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(lan, id: \.run.id) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\"\(item.run.workflowName)\" \(item.run.isPaused ? "paused" : "running") on \(item.computer)")
                                .font(.canopySubheadline).bold()
                            Text("\(item.run.deviceNames.joined(separator: ", ")) · step \(min(item.run.completedSteps + 1, item.run.totalSteps)) of \(item.run.totalSteps)")
                                .font(.canopyCaption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                ForEach(cloud) { RemoteRunRow(run: $0) }
            }
            .padding(.horizontal).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.canopyRust.opacity(0.08))
            Rectangle().fill(Color.canopyRule).frame(height: 1)
        }
    }
}

private struct RemoteRunRow: View {
    let run: RemoteRun

    private var verb: String {
        if run.isStale { return "last reported" }
        switch run.status {
        case "paused":  return "paused"
        case "waiting": return "waiting for confirmation"
        case "done":    return "finished"
        case "stopped": return "stopped"
        case "failed":  return "failed"
        default:        return "running"
        }
    }

    var body: some View {
        // Re-evaluated every few seconds so the time left and "last reported" keep moving.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let steps = run.steps ?? []
            let index = run.currentStepIndex
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: run.isFinished ? "checkmark.circle" : run.isStale ? "moon.zzz" : "desktopcomputer")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\"\(run.workflow)\" \(verb) on \(run.computer)")
                            .font(.canopySubheadline).bold()
                        Text(summary(steps: steps, index: index))
                            .font(.canopyCaption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !run.isFinished, !steps.isEmpty {
                    ProgressView(value: Double(steps.filter { $0.status == "done" || $0.status == "skipped" }.count), total: Double(steps.count))
                        .tint(Color.canopySage)
                    if let i = index {
                        HStack(spacing: 8) {
                            Text(steps[i].title).font(.canopyCaption)
                            if let p = steps[i].progress {
                                ProgressView(value: p).frame(maxWidth: 160)
                            }
                            if let d = steps[i].detail, !d.isEmpty {
                                Text(d).font(.canopyCaption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if run.isStale, let last = run.lastUpdate {
                    Text("No update since \(last.formatted(date: .omitted, time: .shortened)) — that computer may be asleep or offline.")
                        .font(.canopyCaption).foregroundStyle(Color.canopyRust)
                } else if let line = run.lastLine, !line.isEmpty, !run.isFinished {
                    Text(line).font(.canopyCaption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func summary(steps: [RemoteRun.Step], index: Int?) -> String {
        var parts: [String] = []
        if let devices = run.devices, !devices.isEmpty { parts.append(devices.joined(separator: ", ")) }
        if !run.isFinished, !steps.isEmpty {
            let done = steps.filter { $0.status == "done" || $0.status == "skipped" }.count
            parts.append("step \(min((index ?? done) + 1, steps.count)) of \(steps.count)")
        }
        if let total = run.filesTotal, total > 0 { parts.append("\(run.filesDone ?? 0) of \(total) files") }
        if let errors = run.errors, errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
        if !run.isFinished, !run.isStale, run.status == "running", let left = timeLeft {
            parts.append("~\(TaskRow.formatDuration(left)) left")
        }
        return parts.joined(separator: " · ")
    }

    /// The estimate was true when that computer last reported, so count down from then.
    private var timeLeft: Double? {
        guard let remaining = run.remainingSeconds else { return nil }
        let age = run.lastUpdate.map { Date().timeIntervalSince($0) } ?? 0
        let left = remaining - max(0, age)
        return left >= 1 ? left : nil
    }
}
