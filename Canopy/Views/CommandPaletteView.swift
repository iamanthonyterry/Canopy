import SwiftUI
import Combine

// MARK: - Command Palette (⌘K)
// One keyboard-driven box to jump anywhere: sections, devices, clips that
// have a star/note/marker, and to run workflows. Navigation requests are
// published through `CommandPaletteModel` and picked up by ContentView,
// DashboardView and StarredView, so the palette doesn't need to know how
// any of those screens are built.

@MainActor
final class CommandPaletteModel: ObservableObject {
    static let shared = CommandPaletteModel()

    @Published var isPresented = false
    @Published var pendingNav: ContentView.NavItem?
    @Published var pendingDevice: DashboardSelection?
    @Published var pendingClipID: String?

    func toggle() { isPresented.toggle() }
}

/// Case-insensitive match: exact-prefix beats substring beats in-order
/// subsequence. Returns nil for no match; lower scores rank first.
enum CommandPaletteSearch {
    static func score(query: String, title: String) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let t = title.lowercased()
        if t.hasPrefix(q) { return 0 }
        if t.contains(q) { return 1 }
        var idx = t.startIndex
        for ch in q {
            guard let found = t[idx...].firstIndex(of: ch) else { return nil }
            idx = t.index(after: found)
        }
        return 2
    }
}

private struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let group: String
    let run: () -> Void
}

struct CommandPaletteView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var model = CommandPaletteModel.shared
    @ObservedObject private var clips = ClipMetadataStore.shared

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var items: [PaletteItem] {
        var all: [PaletteItem] = []
        let nav: [ContentView.NavItem] = appState.isAdmin
            ? ContentView.NavItem.allCases : [.dashboard, .starred, .exportQueue]
        for item in nav {
            all.append(PaletteItem(id: "nav-\(item.rawValue)", title: item.rawValue, subtitle: "Go to",
                                   icon: item.icon, group: "Go To") { model.pendingNav = item })
        }
        for deck in appState.hyperDecks where appState.isAdmin {
            all.append(PaletteItem(id: "deck-\(deck.id)", title: deck.name, subtitle: "HyperDeck",
                                   icon: "record.circle", group: "Devices") {
                model.pendingNav = .dashboard; model.pendingDevice = .deck(deck.id) })
        }
        for store in appState.cloudStores {
            all.append(PaletteItem(id: "store-\(store.id)", title: store.name, subtitle: "Network storage",
                                   icon: "externaldrive.connected.to.line.below", group: "Devices") {
                model.pendingNav = .dashboard; model.pendingDevice = .cloudStore(store.id) })
        }
        for folder in appState.localFolders {
            all.append(PaletteItem(id: "folder-\(folder.id)", title: folder.name, subtitle: "Local folder",
                                   icon: "folder", group: "Devices") {
                model.pendingNav = .dashboard; model.pendingDevice = .localFolder(folder.id) })
        }
        if appState.isAdmin {
            for workflow in appState.workflows.filter({ !$0.steps.isEmpty }) where appState.canRun(workflow) {
                all.append(PaletteItem(id: "wf-\(workflow.id)", title: "Run \(workflow.name)", subtitle: "Workflow",
                                       icon: "play.fill", group: "Workflows") {
                    Task { await WorkflowEngine.shared.runFromUI(workflow) } })
            }
        }
        for (id, meta) in clips.entries where meta.isVideo || meta.isImage {
            let detail = meta.starred ? "Starred clip · \(meta.deviceLabel)" : "Clip · \(meta.deviceLabel)"
            all.append(PaletteItem(id: "clip-\(id)", title: meta.clipName, subtitle: detail,
                                   icon: meta.starred ? "star.fill" : (meta.isVideo ? "film" : "photo"),
                                   group: "Clips") {
                model.pendingNav = .starred; model.pendingClipID = id })
        }
        return all
    }

    private var results: [PaletteItem] {
        let q = query
        let scored = items.compactMap { item -> (PaletteItem, Int)? in
            CommandPaletteSearch.score(query: q, title: item.title).map { (item, $0) }
        }
        // Stable: keep the natural group order within equal scores.
        let sorted = q.isEmpty ? scored : scored.enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element)
        return Array(sorted.prefix(12).map(\.0))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Jump to a device, clip, or action…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit { runHighlighted() }
                }
                .padding(14)
                Rectangle().fill(Color.canopyRule).frame(height: 1)

                let rows = results
                if rows.isEmpty {
                    Text("No matches").foregroundStyle(.secondary).padding(20)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                                    row(item, selected: index == highlighted)
                                        .id(item.id)
                                        .onTapGesture { run(item) }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: highlighted) {
                            if rows.indices.contains(highlighted) {
                                proxy.scrollTo(rows[highlighted].id)
                            }
                        }
                    }
                }
            }
            .frame(width: 520)
            .background(Color.canopyPaperElevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.canopyRule, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .padding(.top, 90)
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .onAppear { query = ""; highlighted = 0; focused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 20)
                .foregroundStyle(selected ? Color.white : Color.canopySage)
            Text(item.title).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(item.subtitle).font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .foregroundStyle(selected ? Color.white : Color.canopyInk)
        .background(selected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    private func runHighlighted() {
        let rows = results
        if rows.indices.contains(highlighted) { run(rows[highlighted]) }
    }

    private func run(_ item: PaletteItem) {
        dismiss()
        item.run()
    }

    private func dismiss() { model.isPresented = false }
}
