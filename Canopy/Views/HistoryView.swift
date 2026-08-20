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
                        .font(.title2).bold()
                    Spacer()
                    if !appState.workflowRunHistory.isEmpty {
                        Button(role: .destructive) {
                            appState.workflowRunHistory.removeAll()
                            selectedRun = nil
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }
                .padding()
                Divider()

                if appState.workflowRunHistory.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No Runs Yet").font(.title3).bold()
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
                            .font(.title3).bold()
                    }
                    .padding()
                }
                .frame(minWidth: 400, maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Run Row
struct RunRow: View {
    let run: WorkflowRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: run.errors == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(run.errors == 0 ? .green : .orange)
                Text(run.workflowName)
                    .font(.headline)
                Spacer()
                Text(run.durationFormatted)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                statChip("\(run.processed) processed", color: .green)
                if run.errors > 0 { statChip("\(run.errors) errors", color: .red) }
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

    private func statChip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Run Detail
struct RunDetailView: View {
    let run: WorkflowRun
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                Text(run.workflowName).font(.title3).bold()

                // Header stats
                HStack(spacing: 16) {
                    statCard(value: "\(run.processed)", label: "Processed", color: .green)
                    statCard(value: "\(run.errors)",    label: "Errors",    color: run.errors > 0 ? .red : .secondary)
                    statCard(value: run.durationFormatted, label: "Duration", color: .primary)
                }

                Divider()

                // Time info
                Group {
                    labelRow("Started",  run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    labelRow("Finished", run.finishedAt.formatted(date: .abbreviated, time: .shortened))
                    labelRow("Decks",    run.decksProcessed.joined(separator: ", "))
                }

                Divider()

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
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
