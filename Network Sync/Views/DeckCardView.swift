import SwiftUI
import Network

// MARK: - Shared ping helper (package-internal)
func resolveConnectionStatus(_ conn: NWConnection) async -> DeckStatus {
    await withCheckedContinuation { continuation in
        final class ResolveState: @unchecked Sendable { var resolved = false }
        let state = ResolveState()

        conn.stateUpdateHandler = { connectionState in
            guard !state.resolved else { return }
            switch connectionState {
            case .ready:
                state.resolved = true; conn.cancel()
                continuation.resume(returning: .online)
            case .failed:
                state.resolved = true; conn.cancel()
                continuation.resume(returning: .offline)
            default: break
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            guard !state.resolved else { return }
            state.resolved = true; conn.cancel()
            continuation.resume(returning: .offline)
        }
    }
}

// MARK: - HyperDeck Content Pane
// The right-hand content + controls for a selected HyperDeck: live status,
// transport controls, sync progress, and its file browser. Device settings
// (name, IP, credentials, sync destination) live in the gear-button sheet
// on the device row instead of here.

struct DeckContentPane: View {
    let deck: HyperDeck
    @EnvironmentObject var appState: AppState
    @StateObject private var workflowEngine = WorkflowEngine.shared
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @StateObject private var hyperDeck: HyperDeckService

    @State private var showFormatConfirm = false

    init(deck: HyperDeck) {
        self.deck = deck
        _hyperDeck = StateObject(wrappedValue: HyperDeckService(host: deck.ipAddress))
    }

    private var liveStatus: DeckStatus { monitor.status(for: deck.ipAddress) }
    private var deckTasks: [SyncTask] {
        appState.allTasks.filter { $0.deckName == deck.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !deckTasks.isEmpty {
                taskProgress
                Divider()
            }

            if liveStatus == .online {
                HyperDeckControls(hyperDeck: hyperDeck, showFormatConfirm: $showFormatConfirm)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                Divider()
            }

            DeviceFilesBrowser(device: .hyperDeck(deck))
        }
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

    // MARK: - Header
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(deck.name).font(.title3).bold()
                Text(deck.ipAddress).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: liveStatus)
            Button {
                Task { await monitor.pingNow(deck: deck) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            runWorkflowMenu
        }
        .padding()
    }

    @ViewBuilder
    private var runWorkflowMenu: some View {
        if !appState.workflows.isEmpty {
            Menu {
                ForEach(appState.workflows.sorted { $0.sortOrder < $1.sortOrder }) { workflow in
                    Button(workflow.name) {
                        Task { await workflowEngine.runDevice(workflow, deck: deck) }
                    }
                    .disabled(workflow.steps.isEmpty)
                }
            } label: {
                Label("Run Workflow", systemImage: "flowchart")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .buttonStyle(.borderedProminent)
            .disabled(liveStatus != .online || appState.busyDeckNames.contains(deck.name))
        }
    }

    // MARK: - Task progress
    private var taskProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sync Progress").font(.subheadline).bold()
            ForEach(deckTasks.prefix(4)) { task in
                HStack(spacing: 6) {
                    Image(systemName: taskIcon(task.phase))
                        .font(.caption2)
                        .foregroundStyle(taskColor(task.phase))
                        .frame(width: 12)
                    Text(task.fileName)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    ProgressView(value: task.overallProgress)
                        .frame(width: 100)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }

    // MARK: - Helpers
    private func taskIcon(_ phase: SyncTask.Phase) -> String {
        switch phase {
        case .queued: "clock"
        case .downloading: "arrow.down.circle"
        case .converting: "film.stack"
        case .done: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private func taskColor(_ phase: SyncTask.Phase) -> Color {
        switch phase {
        case .queued: .secondary
        case .downloading: .blue
        case .converting: .orange
        case .done: .green
        case .error: .red
        }
    }
}

// MARK: - HyperDeck Transport Controls
// Record/stop plus a manual format action, shown while the deck is online.

struct HyperDeckControls: View {
    @ObservedObject var hyperDeck: HyperDeckService
    @Binding var showFormatConfirm: Bool

    private var isRecording: Bool { hyperDeck.transport == .recording }

    var body: some View {
        HStack(spacing: 10) {
            if isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .symbolEffect(.pulse)
                Text("REC")
                    .font(.caption).bold()
                    .foregroundStyle(.red)
            }

            Button {
                Task {
                    if isRecording { await hyperDeck.stop() }
                    else { await hyperDeck.record() }
                }
            } label: {
                if isRecording {
                    Label("Stop", systemImage: "stop.circle.fill")
                } else {
                    Label("Record", systemImage: "record.circle")
                        .foregroundStyle(.red)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(hyperDeck.isBusy)
            .animation(.easeInOut(duration: 0.2), value: isRecording)

            Spacer()

            Button { showFormatConfirm = true } label: {
                Label("Format", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(hyperDeck.isBusy)

            if hyperDeck.isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }
}
