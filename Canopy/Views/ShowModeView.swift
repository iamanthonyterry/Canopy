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
            Rectangle().fill(Color.canopyRule).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if !inProgress.isEmpty {
                        activeRunsSection
                    }
                    if !appState.hyperDecks.isEmpty {
                        hyperDeckSection
                    }
                    if !appState.cloudStores.isEmpty {
                        deviceSection(title: "Cloud Stores", devices: appState.cloudStores.map { ($0.id, $0.name, $0.ipAddress) })
                    }
                    if appState.hyperDecks.isEmpty && appState.cloudStores.isEmpty {
                        emptyState
                    }
                }
                .padding(28)
            }
        }
        .background(Color.canopyPaper)
        .onAppear { monitor.start() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Status")
                    .font(.canopyDisplay(30, weight: .bold))
                    .foregroundStyle(Color.canopyInk)
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
            .buttonStyle(.canopyPrimary)
            .controlSize(.large)
        }
        .padding(28)
    }

    // MARK: - Active runs

    private var activeRunsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Active Runs")
                .font(.canopyDisplay(20, weight: .bold))
                .foregroundStyle(Color.canopyInk)

            ForEach(inProgress) { session in
                activeRunCard(session)
            }
        }
    }

    // MARK: - HyperDeck section

    // Each card owns a live HyperDeckService (same as the dashboard's
    // DeckContentPane) so transport controls work directly from Show Mode,
    // not just a read-only status glance.
    private var hyperDeckSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("HyperDecks")
                .font(.canopyDisplay(20, weight: .bold))
                .foregroundStyle(Color.canopyInk)

            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(appState.hyperDecks) { deck in
                    ShowModeDeckCard(deck: deck)
                }
            }
        }
    }

    // MARK: - Cloud store section

    @ViewBuilder
    private func deviceSection(title: String, devices: [(UUID, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.canopyDisplay(20, weight: .bold))
                .foregroundStyle(Color.canopyInk)

            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(devices, id: \.0) { _, name, ip in
                    deviceCard(name: name, status: monitor.status(for: ip))
                }
            }
        }
    }

    private func deviceCard(name: String, status: DeckStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 8) {
                Circle().fill(statusColor(status)).frame(width: 12, height: 12)
                Text(statusLabel(status))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(statusColor(status))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.canopySageTint)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "network").font(.system(size: 44)).foregroundStyle(Color.canopySage)
            Text("No Devices Added")
                .font(.canopyDisplay(20, weight: .semibold))
                .foregroundStyle(Color.canopyInk)
            Text("Add devices from the main Dashboard to see them here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Helpers

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
                Circle().fill(session.isPaused ? Color.orange : Color.accentColor).frame(width: 16, height: 16)
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
                Button {
                    session.isPaused ? session.resume() : session.pause()
                } label: {
                    Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                }
                .buttonStyle(.bordered).controlSize(.large)
                Button(role: .destructive) {
                    engine.stop(session)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                }
                .buttonStyle(.bordered).tint(Color.canopyRust).controlSize(.large)
            }

            if let step = session.pendingConfirmationStep {
                confirmationPrompt(for: step)
            }
        }
        .padding(20)
        .background(Color.accentColor.opacity(0.08))
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
                .buttonStyle(.canopySecondary).controlSize(.large)
            Button("Continue") { session.resolveConfirmation(proceed: true) }
                .buttonStyle(.canopyPrimary).controlSize(.large)
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

/// Shared by ShowModeView's cloud store cards and ShowModeDeckCard.
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
    case .online:                                  .canopySage
    case .offline, .noMedia:                        .canopyRust
    case .unauthorized, .pathNotFound, .transcoding: .orange
    case .syncing:                                   .accentColor
    case .unknown:                                   .gray
    }
}

// MARK: - Show Mode HyperDeck Card

/// A HyperDeck's card in Show Mode: live status plus the same transport
/// controls as the dashboard, so a recording can be started/stopped without
/// leaving the show-mode screen. Owns its own HyperDeckService (mirroring
/// DeckContentPane) since Show Mode has no per-deck state of its own.
private struct ShowModeDeckCard: View {
    let deck: HyperDeck
    @EnvironmentObject var appState: AppState
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @StateObject private var hyperDeck: HyperDeckService
    @State private var showFormatConfirm = false

    init(deck: HyperDeck) {
        self.deck = deck
        _hyperDeck = StateObject(wrappedValue: HyperDeckService(host: deck.ipAddress))
    }

    private var status: DeckStatus { monitor.status(for: deck.ipAddress) }
    private var isRecording: Bool { hyperDeck.transport == .recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(deck.name)
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

            if appState.isAdmin && status == .online {
                HyperDeckControls(hyperDeck: hyperDeck, showFormatConfirm: $showFormatConfirm)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.canopySageTint)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isRecording ? Color.red.opacity(0.5) : .clear, lineWidth: 2)
        )
        .onAppear { hyperDeck.startPolling() }
        .onDisappear { hyperDeck.stopPolling() }
        .confirmationDialog(
            "Format Drive?",
            isPresented: $showFormatConfirm,
            titleVisibility: .visible
        ) {
            Button("Format", role: .destructive) {
                Task { await hyperDeck.formatDrive() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will erase all media on \(deck.name). This cannot be undone.")
        }
    }
}
