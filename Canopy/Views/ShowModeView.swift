import SwiftUI

/// A simplified, glanceable status view meant to run on a second monitor
/// during a live service — just device health and active recordings in
/// large text, none of the day-to-day settings that live on the main
/// Dashboard. Toggled on/off from there; owns none of that state itself,
/// so leaving Show Mode always lands back exactly where you left off.
struct ShowModeView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @StateObject private var workflowEngine = WorkflowEngine.shared

    var onExit: () -> Void

    private var inProgress: [WorkflowRunSession] { appState.activeRuns.filter { !$0.isFinished } }
    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 20)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if !inProgress.isEmpty {
                        activeRunsSection
                    }
                    if !appState.hyperDecks.isEmpty {
                        deviceSection(title: "HyperDecks", ipAddresses: appState.hyperDecks.map { ($0.id, $0.name, $0.ipAddress, true) })
                    }
                    if !appState.cloudStores.isEmpty {
                        deviceSection(title: "Cloud Stores", ipAddresses: appState.cloudStores.map { ($0.id, $0.name, $0.ipAddress, false) })
                    }
                    if appState.hyperDecks.isEmpty && appState.cloudStores.isEmpty {
                        emptyState
                    }
                }
                .padding(28)
            }
        }
        .onAppear { monitor.start() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Status")
                    .font(.system(size: 30, weight: .bold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date.formatted(date: .abbreviated, time: .standard))
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                onExit()
            } label: {
                Label("Exit Show Mode", systemImage: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(28)
    }

    // MARK: - Active runs

    private var activeRunsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Active Runs")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.secondary)

            ForEach(inProgress) { session in
                activeRunCard(session)
            }
        }
    }

    // MARK: - Device section

    // `canRecord` distinguishes HyperDecks (which get a REC badge when
    // ConnectionMonitor reports them recording) from cloud stores, which
    // have no recording concept of their own.
    @ViewBuilder
    private func deviceSection(title: String, ipAddresses: [(UUID, String, String, Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(ipAddresses, id: \.0) { _, name, ip, canRecord in
                    deviceCard(name: name, status: monitor.status(for: ip),
                               isRecording: canRecord && monitor.isRecording(host: ip))
                }
            }
        }
    }

    private func deviceCard(name: String, status: DeckStatus, isRecording: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if isRecording {
                    Label("REC", systemImage: "circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: 8) {
                Circle().fill(statusColor(status)).frame(width: 12, height: 12)
                Text(statusLabel(status))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(statusColor(status))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isRecording ? Color.red.opacity(0.5) : .clear, lineWidth: 2)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "network").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No Devices Added")
                .font(.system(size: 20, weight: .semibold))
            Text("Add devices from the main Dashboard to see them here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Helpers

    private func statusLabel(_ status: DeckStatus) -> String {
        switch status {
        case .online:       "Online"
        case .offline:      "Offline"
        case .unauthorized: "Login Issue"
        case .pathNotFound: "Path Not Found"
        case .noMedia:      "No Media"
        case .syncing:      "Syncing"
        case .transcoding:  "Converting"
        case .unknown:      "Checking…"
        }
    }

    private func statusColor(_ status: DeckStatus) -> Color {
        switch status {
        case .online:                                  .green
        case .offline, .noMedia:                        .red
        case .unauthorized, .pathNotFound, .transcoding: .orange
        case .syncing:                                   .blue
        case .unknown:                                   .gray
        }
    }

    private func activeRunCard(_ session: WorkflowRunSession) -> some View {
        ActiveRunCard(session: session, engine: workflowEngine)
    }
}

// MARK: - Active Run Card

/// One in-progress run's status, sized for glancing at from across a room.
/// Its own view (not a helper method on ShowModeView) so it observes the
/// session directly and the confirmation prompt appears the moment a step
/// pauses.
private struct ActiveRunCard: View {
    @ObservedObject var session: WorkflowRunSession
    let engine: WorkflowEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                Circle().fill(.blue).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.workflow.name)
                        .font(.system(size: 24, weight: .semibold))
                    if let lastLine = session.lines.last {
                        Text(lastLine)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                    Text(elapsedTimeString(context.date.timeIntervalSince(session.startedAt)))
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                }
                Button(role: .destructive) {
                    engine.stop(session)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                }
                .buttonStyle(.bordered).tint(.red).controlSize(.large)
            }

            if let step = session.pendingConfirmationStep {
                confirmationPrompt(for: step)
            }
        }
        .padding(20)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func confirmationPrompt(for step: WorkflowStep) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Confirm \"\(step.kind.title)\"?")
                    .font(.system(size: 17, weight: .semibold))
                Text(step.action.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Stop") { session.resolveConfirmation(proceed: false) }
                .buttonStyle(.bordered).controlSize(.large)
            Button("Continue") { session.resolveConfirmation(proceed: true) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(16)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Shared by ShowModeView and ActiveRunCard.
private func elapsedTimeString(_ elapsed: TimeInterval) -> String {
    let h = Int(elapsed) / 3600
    let m = Int(elapsed) % 3600 / 60
    let s = Int(elapsed) % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
