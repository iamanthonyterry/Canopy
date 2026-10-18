import SwiftUI

/// A glanceable status screen meant to run on a second monitor during a live
/// service. The operator designs it as one or more named views, choosing which
/// devices sit on each and how they're laid out on a grid; the day-to-day
/// settings that live on the main Dashboard stay out of the way. Toggled
/// on/off from there; the views themselves live in AppState, so leaving Show
/// Mode always lands back exactly where you left off.
struct ShowModeView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @ObservedObject private var account = SiteAccount.shared
    @ObservedObject private var inventory = InventoryStore.shared
    @StateObject private var workflowEngine = WorkflowEngine.shared
    @StateObject private var wirelessHolder = WirelessHolder()
    @AppStorage("showMode.screen") private var selectedID = ""
    @State private var editing = false
    @State private var confirmDelete = false

    var onExit: () -> Void

    private var inProgress: [WorkflowRunSession] { appState.activeRuns.filter { !$0.isFinished } }

    private var screen: ShowScreen? {
        appState.showScreens.first { $0.id.uuidString == selectedID } ?? appState.showScreens.first
    }

    /// Wireless gear Canopy can watch; only offered once signed in with access to the inventory.
    private var wirelessTargets: [WirelessMonitor.Target] {
        guard account.isConnected, inventory.level.canViewDetails else { return [] }
        return WirelessMonitor.Target.monitorable(inventory.equipment).targets
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.canopyRule).frame(height: 1)

            if let screen {
                HStack(spacing: 0) {
                    canvas(screen)
                    if editing {
                        Rectangle().fill(Color.canopyRule).frame(width: 1)
                        editorPanel(screen)
                    }
                }
            }
        }
        .background(Color.canopyPaper)
        .onAppear {
            monitor.start()
            seedIfNeeded()
            syncWireless()
        }
        .task(id: account.isConnected) {
            if account.isConnected && !inventory.loadedOnce { await inventory.refresh() }
        }
        .onChange(of: selectedID) { syncWireless() }
        .onChange(of: appState.showScreens) { syncWireless() }
        .onChange(of: wirelessTargets) { syncWireless() }
        .onDisappear { wirelessHolder.clear() }
    }

    // MARK: - Views (screens)

    /// First launch: a view holding everything Show Mode used to show, so nothing disappears.
    private func seedIfNeeded() {
        if appState.showScreens.isEmpty {
            appState.showScreens = [.starter(decks: appState.hyperDecks, cloudStores: appState.cloudStores)]
        }
        if screen == nil { selectedID = "" }
        if let first = appState.showScreens.first, !appState.showScreens.contains(where: { $0.id.uuidString == selectedID }) {
            selectedID = first.id.uuidString
        }
    }

    private func mutate(_ id: UUID, _ change: (inout ShowScreen) -> Void) {
        guard let i = appState.showScreens.firstIndex(where: { $0.id == id }) else { return }
        change(&appState.showScreens[i])
    }

    private func addScreen() {
        let new = ShowScreen(name: "View \(appState.showScreens.count + 1)")
        appState.showScreens.append(new)
        selectedID = new.id.uuidString
    }

    private func duplicate(_ s: ShowScreen) {
        let copy = s.duplicated(named: "\(s.name) copy")
        appState.showScreens.append(copy)
        selectedID = copy.id.uuidString
    }

    private func delete(_ s: ShowScreen) {
        guard appState.showScreens.count > 1 else { return }
        appState.showScreens.removeAll { $0.id == s.id }
        selectedID = appState.showScreens.first?.id.uuidString ?? ""
    }

    /// Wireless receivers are only polled while a visible view has them on it.
    private func syncWireless() {
        let onScreen = Set((screen?.tiles ?? []).compactMap { tile -> String? in
            if case .wireless(let id) = tile.device { return id }
            return nil
        })
        wirelessHolder.set(wirelessTargets.filter { onScreen.contains($0.id) }, enabled: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Status")
                    .font(.canopyDisplay(30, weight: .bold))
                    .foregroundStyle(Color.canopyInk)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date.formatted(date: .abbreviated, time: .standard))
                        .font(.canopyMono(15))
                        .foregroundStyle(.secondary)
                }
            }
            if appState.showScreens.count > 1 || editing {
                screenPicker
            }
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.2)) { editing.toggle() }
            } label: {
                Label(editing ? "Done" : "Edit Layout", systemImage: editing ? "checkmark" : "square.grid.2x2")
                    .font(.canopySans(15, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .buttonStyle(.canopySecondary)
            .controlSize(.large)
            Button {
                onExit()
            } label: {
                Label("Exit Show Mode", systemImage: "xmark.circle.fill")
                    .font(.canopySans(15, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .buttonStyle(.canopyPrimary)
            .controlSize(.large)
        }
        .padding(28)
    }

    private var screenPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(appState.showScreens) { s in
                    let selected = s.id == screen?.id
                    Button { selectedID = s.id.uuidString } label: {
                        Text(s.name.isEmpty ? "Untitled" : s.name)
                            .font(.canopySans(16, weight: .semibold))
                            .foregroundStyle(selected ? Color.white : Color.canopyInk)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(selected ? Color.accentColor : Color.canopySageTint, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if editing {
                    Button(action: addScreen) {
                        Label("New View", systemImage: "plus")
                            .font(.canopySans(16, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .overlay(Capsule().strokeBorder(Color.canopyRule, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Canvas

    private func canvas(_ screen: ShowScreen) -> some View {
        GeometryReader { geo in
            let grid = ShowGrid(width: max(geo.size.width - 56, 200))
            let rows = max(screen.rowCount, 1) + (editing ? 2 : 0)
            ScrollView {
                ZStack(alignment: .topLeading) {
                    if editing { GridBackdrop(grid: grid, rows: rows) }
                    ForEach(screen.tiles) { tile in
                        ShowTileView(
                            tile: tile,
                            grid: grid,
                            editing: editing,
                            canPlace: { c, r, w, h in screen.canPlace(tile.id, col: c, row: r, width: w, height: h) },
                            onPlace: { c, r, w, h in mutate(screen.id) { $0.place(tile.id, col: c, row: r, width: w, height: h) } },
                            onRemove: { mutate(screen.id) { $0.remove(tile.id) } }
                        ) {
                            tileContent(tile.device)
                        }
                    }
                    if screen.tiles.isEmpty { emptyScreen }
                }
                .frame(width: grid.width, height: grid.height(rows: rows), alignment: .topLeading)
                .coordinateSpace(name: ShowGrid.space)
                .padding(28)
            }
        }
    }

    private var emptyScreen: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed").font(.system(size: 44)).foregroundStyle(Color.canopySage)
            Text("This View Is Empty")
                .font(.canopyDisplay(20, weight: .semibold))
                .foregroundStyle(Color.canopyInk)
            Text(editing ? "Add devices from the list on the right." : "Choose Edit Layout to add devices to it.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func tileContent(_ device: ShowDevice) -> some View {
        switch device {
        case .hyperDeck(let id):
            if let deck = appState.hyperDecks.first(where: { $0.id == id }) {
                ShowModeDeckCard(deck: deck)
            } else {
                missingTile("This HyperDeck was removed")
            }
        case .cloudStore(let id):
            if let store = appState.cloudStores.first(where: { $0.id == id }) {
                deviceCard(name: store.name, status: monitor.status(for: store.ipAddress))
            } else {
                missingTile("This storage device was removed")
            }
        case .wireless(let id):
            if let target = wirelessTargets.first(where: { $0.id == id }) {
                ShowWirelessTile(target: target)
            } else {
                missingTile("Wireless device unavailable. Sign in to the site to see it.")
            }
        case .activeRuns:
            ShowActiveRunsTile(runs: inProgress, engine: workflowEngine)
        }
    }

    private func deviceCard(name: String, status: DeckStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name)
                .font(.canopySans(22, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 8) {
                Circle().fill(statusColor(status)).frame(width: 12, height: 12)
                Text(statusLabel(status))
                    .font(.canopySans(17, weight: .medium))
                    .foregroundStyle(statusColor(status))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.canopySageTint)
    }

    private func missingTile(_ message: String) -> some View {
        Text(message)
            .font(.canopySans(15))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.12))
    }

    // MARK: - Editor panel

    private func editorPanel(_ screen: ShowScreen) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("View").font(.canopyDisplay(16, weight: .bold)).foregroundStyle(Color.canopyInk)
            TextField("View name", text: Binding(
                get: { screen.name },
                set: { name in mutate(screen.id) { $0.name = name } }
            ))
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("Duplicate") { duplicate(screen) }
                Spacer()
                Button("Delete", role: .destructive) { confirmDelete = true }
                    .disabled(appState.showScreens.count < 2)
            }
            .controlSize(.small)
            .confirmationDialog("Delete “\(screen.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete View", role: .destructive) { delete(screen) }
                Button("Cancel", role: .cancel) {}
            }

            Divider()
            Text("Devices").font(.canopyDisplay(16, weight: .bold)).foregroundStyle(Color.canopyInk)
            Text("Click to add or remove. Drag a tile to move it; drag its corner to resize.")
                .font(.canopyCaption).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    deviceGroup("Status", [(.activeRuns, "Active Runs", "")], on: screen)
                    deviceGroup("HyperDecks", appState.hyperDecks.map { (.hyperDeck($0.id), $0.name, $0.ipAddress) }, on: screen)
                    deviceGroup("Storage", appState.cloudStores.map { (.cloudStore($0.id), $0.name, $0.ipAddress) }, on: screen)
                    deviceGroup("Wireless", wirelessTargets.map { (.wireless($0.id), $0.name, $0.iem ? "IEM" : "Mic") }, on: screen)
                    if wirelessTargets.isEmpty {
                        Text("Wireless receivers appear here when you're signed in and they're in the inventory with an address on this network.")
                            .font(.canopyCaption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 290)
        .background(Color.canopyPaperElevated)
    }

    private func deviceGroup(_ title: String, _ devices: [(ShowDevice, String, String)], on screen: ShowScreen) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !devices.isEmpty {
                Text(title.uppercased()).font(.canopyCaption).foregroundStyle(.secondary)
                ForEach(devices, id: \.0) { device, name, detail in
                    let isOn = screen.contains(device)
                    Button {
                        mutate(screen.id) { s in
                            if isOn {
                                s.tiles.removeAll { $0.device == device }
                            } else {
                                s.add(device)
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).font(.canopyBody).foregroundStyle(Color.canopyInk)
                                if !detail.isEmpty { Text(detail).font(.canopyCaption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: isOn ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(isOn ? Color.canopySage : Color.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Grid

/// Converts between grid cells and points for a canvas of a given width.
private struct ShowGrid {
    static let space = "showCanvas"
    static let gap: CGFloat = 16
    static let rowHeight: CGFloat = 110

    let width: CGFloat

    var unit: CGFloat { (width + Self.gap) / CGFloat(ShowScreen.columns) }
    var rowPitch: CGFloat { Self.rowHeight + Self.gap }

    func height(rows: Int) -> CGFloat { max(0, CGFloat(rows) * rowPitch - Self.gap) }

    func rect(col: Int, row: Int, width w: Int, height h: Int) -> CGRect {
        CGRect(x: CGFloat(col) * unit, y: CGFloat(row) * rowPitch,
               width: CGFloat(w) * unit - Self.gap, height: CGFloat(h) * rowPitch - Self.gap)
    }

    /// Whole cells a drag of `distance` points moves by.
    func cells(_ translation: CGSize) -> (x: Int, y: Int) {
        (Int((translation.width / unit).rounded()), Int((translation.height / rowPitch).rounded()))
    }
}

/// Faint cell outlines so the grid is visible while designing.
private struct GridBackdrop: View {
    let grid: ShowGrid
    let rows: Int

    var body: some View {
        Canvas { ctx, _ in
            for row in 0..<rows {
                for col in 0..<ShowScreen.columns {
                    let r = grid.rect(col: col, row: row, width: 1, height: 1)
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Tile

/// One device on the canvas. In edit mode it can be dragged (snapping to the
/// grid), resized from its corner, or removed; a move or resize that would
/// leave the grid or land on another tile is shown in red and discarded.
private struct ShowTileView<Content: View>: View {
    let tile: ShowTile
    let grid: ShowGrid
    let editing: Bool
    let canPlace: (_ col: Int, _ row: Int, _ width: Int, _ height: Int) -> Bool
    let onPlace: (_ col: Int, _ row: Int, _ width: Int, _ height: Int) -> Void
    let onRemove: () -> Void
    @ViewBuilder let content: Content

    @State private var move: (x: Int, y: Int)?
    @State private var resize: (x: Int, y: Int)?

    private var frame: (col: Int, row: Int, width: Int, height: Int) {
        (tile.col + (move?.x ?? 0), tile.row + (move?.y ?? 0),
         max(1, tile.width + (resize?.x ?? 0)), max(1, tile.height + (resize?.y ?? 0)))
    }

    var body: some View {
        let f = frame
        let rect = grid.rect(col: f.col, row: f.row, width: f.width, height: f.height)
        let valid = canPlace(f.col, f.row, f.width, f.height)
        content
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .allowsHitTesting(!editing)
            .overlay { if editing { editChrome(valid: valid) } }
            .offset(x: rect.minX, y: rect.minY)
            .zIndex(move != nil || resize != nil ? 1 : 0)
    }

    private func editChrome(valid: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill((valid ? Color.accentColor : Color.red).opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(valid ? Color.accentColor : Color.red, lineWidth: 2))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named(ShowGrid.space))
                        .onChanged { move = grid.cells($0.translation) }
                        .onEnded { value in
                            let d = grid.cells(value.translation)
                            let f = (col: tile.col + d.x, row: tile.row + d.y)
                            if canPlace(f.col, f.row, tile.width, tile.height) { onPlace(f.col, f.row, tile.width, tile.height) }
                            move = nil
                        }
                )

            HStack {
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.canopyRust)
                }
                .buttonStyle(.plain)
                .help("Remove from this view")
            }
            .padding(8)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor, in: Circle())
                        .padding(8)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named(ShowGrid.space))
                                .onChanged { resize = grid.cells($0.translation) }
                                .onEnded { value in
                                    let d = grid.cells(value.translation)
                                    let w = max(1, tile.width + d.x), h = max(1, tile.height + d.y)
                                    if canPlace(tile.col, tile.row, w, h) { onPlace(tile.col, tile.row, w, h) }
                                    resize = nil
                                }
                        )
                        .help("Drag to resize")
                }
            }
        }
    }
}

// MARK: - Wireless and run tiles

/// A wireless receiver's live channels, scrolling if the tile is smaller than its content.
private struct ShowWirelessTile: View {
    let target: WirelessMonitor.Target

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: target.iem ? "earbuds" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(Color.canopySage)
                    Text(target.name)
                        .font(.canopySans(22, weight: .semibold))
                        .foregroundStyle(Color.canopyInk)
                        .lineLimit(1)
                }
                ReceiverBlock(target: target, titled: false)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canopySageTint)
    }
}

/// Every in-progress run, or a quiet idle line when nothing is running.
private struct ShowActiveRunsTile: View {
    let runs: [WorkflowRunSession]
    let engine: WorkflowEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Active Runs")
                    .font(.canopyDisplay(20, weight: .bold))
                    .foregroundStyle(Color.canopyInk)
                if runs.isEmpty {
                    HStack(spacing: 8) {
                        Circle().fill(Color.gray.opacity(0.4)).frame(width: 12, height: 12)
                        Text("Idle").font(.canopySans(17, weight: .medium)).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(runs) { ActiveRunCard(session: $0, engine: engine) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canopySageTint.opacity(0.5))
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
                        .font(.canopySans(24, weight: .semibold))
                    if let lastLine = session.lines.last {
                        Text(lastLine)
                            .font(.canopyMono(14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                    Text(elapsedTimeString(context.date.timeIntervalSince(session.startedAt)))
                        .font(.canopyMono(22, weight: .medium))
                }
                Button {
                    session.isPaused ? session.resume() : session.pause()
                } label: {
                    Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                        .font(.canopySans(15, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                }
                .buttonStyle(.bordered).controlSize(.large)
                Button(role: .destructive) {
                    engine.stop(session)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.canopySans(15, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                }
                .buttonStyle(.bordered).tint(Color.canopyRust).controlSize(.large)
            }

            // The confirmation prompt itself is shown by the global
            // `WorkflowConfirmationBanner` in ContentView, above whatever
            // page (including Show Mode) is on screen — no need to repeat
            // it here.
        }
        .padding(20)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
                    .font(.canopySans(22, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if isRecording {
                    Label("REC", systemImage: "circle.fill")
                        .font(.canopySans(13, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: 8) {
                Circle().fill(statusColor(status)).frame(width: 12, height: 12)
                Text(statusLabel(status))
                    .font(.canopySans(17, weight: .medium))
                    .foregroundStyle(statusColor(status))
            }

            if appState.isAdmin && status == .online {
                HyperDeckControls(hyperDeck: hyperDeck, showFormatConfirm: $showFormatConfirm)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.canopySageTint)
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
