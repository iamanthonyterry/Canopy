import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedRun: WorkflowRun?

    var body: some View {
        HSplitView {
            // Run list
            VStack(spacing: 0) {
                HStack {
                    Text("Run History")
                        .font(.canopyTitle).foregroundStyle(Color.canopyInk)
                    Spacer()
                    if !appState.workflowRunHistory.isEmpty {
                        Button(role: .destructive) {
                            appState.workflowRunHistory.removeAll()
                            selectedRun = nil
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.canopyRust)
                    }
                }
                .padding()
                Rectangle().fill(Color.canopyRule).frame(height: 1)

                if appState.workflowRunHistory.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40)).foregroundStyle(Color.canopySage)
                        Text("No Runs Yet").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                        Text("Completed workflow runs appear here.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    List(appState.workflowRunHistory, selection: $selectedRun) { run in
                        RunRow(run: run)
                            .tag(run)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 260, maxWidth: 320)

            // Run detail
            if let run = selectedRun {
                RunDetailView(run: run)
                    .frame(minWidth: 400, maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Select a run to view details")
                            .foregroundStyle(.secondary)
                            .font(.canopyTitle2)
                    }
                    .padding()
                }
                .frame(minWidth: 400, maxWidth: .infinity)
            }
        }
        .background(Color.canopyPaper)
    }
}

// MARK: - Run Row
struct RunRow: View {
    let run: WorkflowRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: run.errors == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(run.errors == 0 ? Color.canopySage : .orange)
                Text(run.workflowName)
                    .font(.headline)
                Spacer()
                Text(run.durationFormatted)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                CanopyPill(label: "\(run.processed) processed", color: .canopySage)
                if run.errors > 0 { CanopyPill(label: "\(run.errors) errors", color: .canopyRust) }
            }
            HStack(spacing: 4) {
                Text(run.startedAt, style: .date)
                Text("·")
                Text(run.startedAt, style: .time)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }
}

// MARK: - Run Detail
struct RunDetailView: View {
    let run: WorkflowRun
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                Text(run.workflowName).font(.canopyTitle2).foregroundStyle(Color.canopyInk)

                // Header stats
                HStack(spacing: 16) {
                    statCard(value: "\(run.processed)", label: "Processed", color: .canopySage)
                    statCard(value: "\(run.errors)",    label: "Errors",    color: run.errors > 0 ? .canopyRust : .secondary)
                    statCard(value: run.durationFormatted, label: "Duration", color: .primary)
                }

                Rectangle().fill(Color.canopyRule).frame(height: 1)

                // Time info
                Group {
                    labelRow("Started",  run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    labelRow("Finished", run.finishedAt.formatted(date: .abbreviated, time: .shortened))
                    labelRow("Decks",    run.decksProcessed.joined(separator: ", "))
                }

                Rectangle().fill(Color.canopyRule).frame(height: 1)

                // Log
                DisclosureGroup(isExpanded: $showLog) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(run.log, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 320)
                    .canopyCard(padding: 0, cornerRadius: 6)
                } label: {
                    HStack {
                        Label("Run Log (\(run.log.count) lines)", systemImage: "doc.text")
                            .font(.headline)
                        Spacer()
                        Button {
                            exportLog()
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(run.log.isEmpty)
                    }
                }
            }
            .padding()
        }
    }

    private func exportLog() {
        let stamp = run.startedAt.formatted(
            Date.FormatStyle().year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        ).replacingOccurrences(of: "/", with: "-")

        let panel = NSSavePanel()
        panel.title = "Export Run Log"
        panel.nameFieldStringValue = "Canopy-Run-\(stamp).log"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let header = """
        Canopy Run Log
        Workflow: \(run.workflowName)
        Started:  \(run.startedAt.formatted(date: .abbreviated, time: .standard))
        Finished: \(run.finishedAt.formatted(date: .abbreviated, time: .standard))
        Duration: \(run.durationFormatted)
        Decks:    \(run.decksProcessed.joined(separator: ", "))
        Processed: \(run.processed)  Errors: \(run.errors)

        """
        let contents = header + run.log.joined(separator: "\n")

        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func statCard(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title2).bold().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 80)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func labelRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).font(.subheadline)
        }
    }
}
