import SwiftUI

// MARK: - Dashboard Selection
// Identifies whichever device is currently selected in the left-hand list,
// so the right-hand pane knows which settings to show.
enum DashboardSelection: Hashable {
    case deck(UUID)
    case cloudStore(UUID)
}

// MARK: - DashboardView
// Home base: shows every configured device (HyperDecks, Cloud Stores) plus
// anything found on the network, all in one place.
// Two columns: the left lists every device with a settings gear button,
// and the right shows the content and controls for whichever device is
// selected — transport controls, sync progress, and its file browser.

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var workflowEngine = WorkflowEngine.shared
    @StateObject private var discovery = DeviceDiscovery()
    @ObservedObject private var monitor = ConnectionMonitor.shared

    @State private var showingAddDeck = false
    @State private var showingAddCloudStore = false
    @State private var selection: DashboardSelection?
    @State private var showMode = false

    var inProgress: [WorkflowRunSession] { appState.activeRuns.filter { !$0.isFinished } }
    var erroredMounts: [WorkflowRunSession] { appState.activeRuns.filter { $0.mountError != nil } }

    var activeCount: Int  { inProgress.flatMap(\.tasks).filter { $0.phase == .downloading || $0.phase == .converting }.count }
    var doneCount: Int    { inProgress.flatMap(\.tasks).filter { $0.phase == .done }.count }
    var errorCount: Int   { inProgress.flatMap(\.tasks).filter { $0.phase == .error }.count }


    var totalDevices: Int  { appState.hyperDecks.count + appState.cloudStores.count }

    private var hasDiscovered: Bool {
        !discovery.discoveredDecks.isEmpty || !discovery.discoveredCloudStores.isEmpty
    }

    var body: some View {
        if showMode {
            ShowModeView(onExit: { showMode = false })
        } else {
            normalDashboard
        }
    }

    private var normalDashboard: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if !erroredMounts.isEmpty {
                ForEach(erroredMounts) { session in
                    mountErrorBanner(session)
                }
                Divider()
            }

            if totalDevices == 0 && !hasDiscovered {
                emptyState
            } else {
                HStack(spacing: 0) {
                    deviceList
                        .frame(width: 300)
                    Divider()
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()
            actionBar
        }
        .sheet(isPresented: $showingAddDeck) { DeckEditSheet(deck: nil) }
        .sheet(isPresented: $showingAddCloudStore) { CloudStoreEditSheet(store: nil) }
        .onAppear { monitor.start() }
    }

    // MARK: - Mount error banner
    private func mountErrorBanner(_ session: WorkflowRunSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("\"\(session.workflow.name)\" stopped — couldn't reach storage").font(.subheadline).bold()
                Text(session.mountError ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if appState.isAdmin {
                Button {
                    Task { await workflowEngine.run(session.workflow) }
                } label: {
                    Label("Retry", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!appState.canRun(session.workflow))
            }
            Button {
                appState.dismiss(session)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
    }


    // MARK: - Header
    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dashboard").font(.title2).bold()
                    Text("\(appState.hyperDecks.count) decks · \(appState.cloudStores.count) cloud stores")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()

                if !inProgress.isEmpty {
                    HStack(spacing: 10) {
                        statPill("\(inProgress.count) running", color: .blue)
                        statPill("\(activeCount) active", color: .blue)
                        statPill("\(doneCount) done", color: .green)
                        if errorCount > 0 { statPill("\(errorCount) errors", color: .red) }
                    }
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(Color.gray.opacity(0.4)).frame(width: 9, height: 9)
                        Text("Idle").font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if appState.isAdmin {
                    scanButton

                    Button {
                        showMode = true
                    } label: {
                        Label("Show Mode", systemImage: "tv")
                    }
                    .buttonStyle(.bordered)

                    Menu {
                        Button("HyperDeck") { showingAddDeck = true }
                        Button("Cloud Store") { showingAddCloudStore = true }
                    } label: {
                        Label("Add Device", systemImage: "plus")
                    }.buttonStyle(.borderedProminent)
                }
            }

            if let earliest = inProgress.map(\.startedAt).min() {
                ElapsedTimeView(startTime: earliest)
            }
        }
        .padding()
    }


    @ViewBuilder private var scanButton: some View {
        Button {
            if discovery.isScanning { discovery.stopScanning() }
            else { discovery.startScanning() }
        } label: {
            if discovery.isScanning {
                Label("Scanning…", systemImage: "antenna.radiowaves.left.and.right")
                    .symbolEffect(.pulse)
            } else {
                Label("Scan Network", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
    }

    // MARK: - Left column: device list
    private var deviceList: some View {
        List(selection: $selection) {
            if !appState.hyperDecks.isEmpty {
                Section("HyperDecks") {
                    ForEach(appState.hyperDecks) { deck in
                        DeckListRow(deck: deck)
                            .tag(DashboardSelection.deck(deck.id))
                    }
                }
            }

            if !appState.cloudStores.isEmpty {
                Section("Cloud Stores") {
                    ForEach(appState.cloudStores) { store in
                        CloudStoreListRow(store: store)
                            .tag(DashboardSelection.cloudStore(store.id))
                    }
                }
            }

            if appState.isAdmin {
                discoveredSection
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Right column: selected device's content & controls
    @ViewBuilder private var detailPane: some View {
        switch selection {
        case .deck(let id):
            if let deck = appState.hyperDecks.first(where: { $0.id == id }) {
                DeckContentPane(deck: deck)
                    .id(deck.id)
            } else {
                emptyDetailState
            }
        case .cloudStore(let id):
            if let store = appState.cloudStores.first(where: { $0.id == id }) {
                CloudStoreContentPane(store: store)
                    .id(store.id)
            } else {
                emptyDetailState
            }
        case .none:
            emptyDetailState
        }
    }

    private var emptyDetailState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Select a device")
                .font(.headline)
            Text("Choose a device on the left to view its content and controls.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Discovered on network
    @ViewBuilder private var discoveredSection: some View {
        let newDecks = discovery.discoveredDecks.filter { d in
            !appState.hyperDecks.contains(where: { $0.ipAddress == d.ipAddress })
        }
        let newStores = discovery.discoveredCloudStores.filter { s in
            !appState.cloudStores.contains(where: { $0.ipAddress == s.ipAddress })
        }

        if !newDecks.isEmpty || !newStores.isEmpty {
            Section("Discovered on Network") {
                ForEach(newDecks) { deck in
                    DiscoveredDeviceRow(name: deck.name, ip: deck.ipAddress, icon: "server.rack") {
                        appState.addDeck(deck)
                    }
                }
                ForEach(newStores) { s in
                    DiscoveredDeviceRow(name: s.name, ip: s.ipAddress, icon: "externaldrive.badge.wifi") {
                        appState.addCloudStore(s)
                    }
                }
            }
        }
    }

    // MARK: - Empty state
    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "network").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No Devices Added").font(.title3).bold()
            Text("Scan the network or add a HyperDeck or Cloud Store.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Scan Network") { discovery.startScanning() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    // MARK: - Action bar
    private var actionBar: some View {
        VStack(spacing: 10) {
            if !inProgress.isEmpty {
                activeRunsList
            }

            HStack(spacing: 16) {
                // Last run summary
                if let last = appState.workflowRunHistory.first {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last run: \(last.workflowName) · \(last.finishedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(last.processed) processed · \(last.durationFormatted)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading)
                }

                Spacer()

                if appState.isAdmin {
                    // Retry button — visible whenever there are failed tasks
                    // worth another try, regardless of what else is running.
                    if !appState.failedTasks.isEmpty {
                        Button {
                            Task { await workflowEngine.retryFailed() }
                        } label: {
                            Label("Retry \(appState.failedTasks.count) Failed", systemImage: "arrow.counterclockwise")
                                .padding(.horizontal, 16).padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }

                    if !inProgress.isEmpty {
                        Button(role: .destructive) {
                            workflowEngine.stop()
                        } label: {
                            Label("Stop All", systemImage: "stop.fill")
                                .padding(.horizontal, 20).padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered).tint(.red)
                    }

                    runWorkflowMenu
                }

                Spacer()
            }
        }
        .padding()
    }

    // MARK: - Active runs list
    // One row per run currently in progress, each with its own live status
    // and its own Stop button — stopping one never touches the others.
    private var activeRunsList: some View {
        VStack(spacing: 6) {
            ForEach(inProgress) { session in
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.workflow.name).font(.subheadline).bold()
                        if let lastLine = session.lines.last {
                            Text(lastLine)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    ElapsedTimeView(startTime: session.startedAt, compact: true)
                    Button(role: .destructive) {
                        workflowEngine.stop(session)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered).tint(.red).controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal)
    }


    // MARK: - Run Workflow menu
    // The primary dashboard action: pick any user-defined workflow and run
    // it against its configured target devices. No workflow is baked in —
    // if none exist yet, this points the user to the Workflows tab instead.
    @ViewBuilder private var runWorkflowMenu: some View {
        let runnable = appState.workflows.filter { !$0.steps.isEmpty }

        if runnable.isEmpty {
            Label("No workflows yet — create one in Workflows", systemImage: "flowchart")
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(runnable.sorted { $0.sortOrder < $1.sortOrder }) { workflow in
                    Button(workflow.name) {
                        Task { await workflowEngine.run(workflow) }
                    }
                    .disabled(!appState.canRun(workflow))
                }
            } label: {
                Label("Run Workflow", systemImage: "play.fill")
                    .padding(.horizontal, 28).padding(.vertical, 8)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Helpers
    private func statPill(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
