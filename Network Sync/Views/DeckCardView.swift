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

// MARK: - HyperDeck Detail Pane
// The right-hand settings view for a selected HyperDeck: editable device
// info, sync destination, a connection test, live transport controls,
// the file list, and device actions (refresh / delete).

struct DeckDetailPane: View {
    let deck: HyperDeck
    @EnvironmentObject var appState: AppState
    @StateObject private var workflowEngine = WorkflowEngine.shared
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @StateObject private var hyperDeck: HyperDeckService

    @State private var name: String
    @State private var ipAddress: String
    @State private var remotePath: String
    @State private var username: String
    @State private var password: String
    @State private var cloudStoreID: UUID?
    @State private var cloudStorePath: String
    @State private var capacityText: String

    @State private var files: [String] = []
    @State private var isFetchingFiles = false
    @State private var isShowingFiles = false
    @State private var showPathPicker = false
    @State private var showFolderPicker = false
    @State private var showFormatConfirm = false
    @State private var showDeleteConfirm = false
    @State private var pingTestStatus: DeckStatus = .unknown
    @State private var isTesting = false

    init(deck: HyperDeck) {
        self.deck = deck
        _hyperDeck = StateObject(wrappedValue: HyperDeckService(host: deck.ipAddress))
        _name           = State(initialValue: deck.name)
        _ipAddress      = State(initialValue: deck.ipAddress)
        _remotePath     = State(initialValue: deck.remotePath)
        _username       = State(initialValue: deck.username)
        _password       = State(initialValue: deck.password)
        _cloudStoreID   = State(initialValue: deck.cloudStoreID)
        _cloudStorePath = State(initialValue: deck.cloudStorePath)
        _capacityText   = State(initialValue: deck.capacityGB.map { String(format: "%g", $0) } ?? "")
    }

    private var liveStatus: DeckStatus { monitor.status(for: deck.ipAddress) }
    private var selectedStore: CloudStore? {
        guard let id = cloudStoreID else { return nil }
        return appState.cloudStores.first { $0.id == id }
    }
    private var isDirty: Bool {
        name != deck.name || ipAddress != deck.ipAddress || remotePath != deck.remotePath
            || username != deck.username || password != deck.password
            || cloudStoreID != deck.cloudStoreID || cloudStorePath != deck.cloudStorePath
            || capacityText != (deck.capacityGB.map { String(format: "%g", $0) } ?? "")
    }
    private var canSave: Bool { !name.isEmpty && !ipAddress.isEmpty }

    private var deckTasks: [SyncTask] {
        appState.allTasks.filter { $0.deckName == deck.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !deckTasks.isEmpty { taskProgress }

                    if liveStatus == .online {
                        HyperDeckControls(hyperDeck: hyperDeck, showFormatConfirm: $showFormatConfirm)
                            .padding(.horizontal)
                    }

                    settingsForm

                    filesSection
                        .padding(.horizontal)
                }
                .padding(.vertical, 12)
            }

            Divider()
            footer
        }
        .task { await fetchFiles() }
        .onChange(of: liveStatus) { _, newValue in
            if newValue == .online && files.isEmpty { Task { await fetchFiles() } }
        }
        .onAppear { hyperDeck.startPolling() }
        .onDisappear { hyperDeck.stopPolling() }
        .sheet(isPresented: $showPathPicker) {
            DeckPathPickerSheet(ipAddress: ipAddress, username: username, password: password) { path in
                remotePath = path
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            if let store = selectedStore {
                FolderPickerSheet(store: store) { path in
                    cloudStorePath = path
                }
                .environmentObject(appState)
            }
        }
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
        .confirmationDialog(
            "Delete \(deck.name)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { appState.deleteDeck(id: deck.id) }
            Button("Cancel", role: .cancel) {}
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
                Task { await monitor.pingNow(deck: deck); await fetchFiles() }
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
    }

    // MARK: - Settings form
    private var settingsForm: some View {
        Form {
            Section("Device Info") {
                LabeledContent("Name") {
                    TextField("e.g. ISO 1", text: $name).textFieldStyle(.roundedBorder)
                }
                LabeledContent("IP Address") {
                    TextField("192.168.x.x", text: $ipAddress).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Remote Path") {
                    HStack(spacing: 8) {
                        TextField("usb/DriveName", text: $remotePath).textFieldStyle(.roundedBorder)
                        Button {
                            showPathPicker = true
                        } label: {
                            Label("Browse…", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                LabeledContent("Media Capacity") {
                    HStack(spacing: 6) {
                        TextField("e.g. 500", text: $capacityText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("GB")
                    }
                }
            }

            Section("Credentials") {
                LabeledContent("Username") {
                    TextField("Username", text: $username).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Password") {
                    SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                }
            }

            Section("Sync Destination") {
                LabeledContent("Cloud Store") {
                    Picker("", selection: $cloudStoreID) {
                        Text("Global Default").tag(Optional<UUID>.none)
                        if !appState.cloudStores.isEmpty {
                            Divider()
                            ForEach(appState.cloudStores) { store in
                                Text(store.name).tag(Optional(store.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: cloudStoreID) { cloudStorePath = "" }
                }

                if let store = selectedStore {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(cloudStorePath.isEmpty ? "Volume root" : cloudStorePath)
                                .foregroundStyle(cloudStorePath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                showFolderPicker = true
                            } label: {
                                Label("Browse…", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    let folder = cloudStorePath.isEmpty ? "/" : "/\(cloudStorePath)"
                    Label("→ \(store.name)\(folder)", systemImage: "externaldrive.connected.to.line.below")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Uses the global sync destination from Settings.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }


            Section {
                HStack {
                    Button(action: testConnection) {
                        if isTesting {
                            ProgressView().controlSize(.small)
                            Text("Testing…")
                        } else {
                            Label("Test Connection", systemImage: "network")
                        }
                    }.disabled(ipAddress.isEmpty || isTesting)
                    Spacer()
                    if pingTestStatus != .unknown {
                        Label(
                            pingTestStatus == .online ? "Connected" : "No Response",
                            systemImage: pingTestStatus == .online ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundStyle(pingTestStatus == .online ? .green : .red)
                        .font(.subheadline)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 480)
    }

    // MARK: - Files
    @ViewBuilder private var filesSection: some View {
        DisclosureGroup(isExpanded: $isShowingFiles) {
            if isFetchingFiles {
                ProgressView().padding(.vertical, 6)
            } else if files.isEmpty {
                Text(emptyFilesMessage).font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(files, id: \.self) { file in
                        Text(file)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 4)
            }
        } label: {
            Text("Files on Deck (\(files.count))").font(.subheadline).bold()
        }
    }

    // MARK: - Footer
    private var footer: some View {
        HStack {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label("Delete Device", systemImage: "trash")
            }
            Spacer()
            Button("Save Changes") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty || !canSave)
        }
        .padding()
    }

    // MARK: - Actions
    private func save() {
        var d = deck
        d.name = name; d.ipAddress = ipAddress; d.remotePath = remotePath
        d.username = username; d.password = password
        d.cloudStoreID = cloudStoreID; d.cloudStorePath = cloudStorePath
        d.capacityGB = Double(capacityText)
        appState.updateDeck(d)
    }

    private func testConnection() {
        isTesting = true; pingTestStatus = .unknown
        Task {
            guard let port = NWEndpoint.Port(rawValue: 9993) else { isTesting = false; return }
            let conn = NWConnection(host: NWEndpoint.Host(ipAddress), port: port, using: .tcp)
            conn.start(queue: .global())
            pingTestStatus = await resolveConnectionStatus(conn)
            isTesting = false
        }
    }

    private func fetchFiles() async {
        guard liveStatus == .online else { isFetchingFiles = false; return }
        isFetchingFiles = true
        files = await FTPService.listMovFiles(on: deck)
        isFetchingFiles = false
    }

    // Explains *why* the file list is empty, matching whichever specific
    // failure the monitor detected — not just a generic fallback.
    private var emptyFilesMessage: String {
        switch liveStatus {
        case .unauthorized: "Login failed — check username/password."
        case .pathNotFound: "Remote folder not found — check the file location above."
        case .noMedia:      "No drive detected in the deck."
        default:            "No .mov files found."
        }
    }

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

