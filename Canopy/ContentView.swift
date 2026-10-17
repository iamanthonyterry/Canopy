import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var exportQueue = ExportQueueManager.shared
    @ObservedObject private var clipMetadata = ClipMetadataStore.shared
    @ObservedObject private var palette = CommandPaletteModel.shared
    @ObservedObject private var features = AppFeatures.shared
    @State private var selection: NavItem? = .dashboard

    enum NavItem: String, Hashable, CaseIterable {
        case dashboard    = "Dashboard"
        case workflows    = "Workflows"
        case starred      = "Starred"
        case inventory    = "Inventory"
        case socialShare  = "Social Share"
        case exportQueue  = "Export Queue"
        case history      = "History"
        case settings     = "Settings"

        var icon: String {
            switch self {
            case .dashboard:    return "play.tv"
            case .starred:      return "star.fill"
            case .inventory:    return "shippingbox"
            case .socialShare:  return "paperplane"
            case .exportQueue:  return "square.and.arrow.up.on.square"
            case .workflows:    return "flowchart"
            case .history:      return "clock.arrow.circlepath"
            case .settings:     return "gearshape"
            }
        }
    }

    // Content Managers export clips as their core job, and starring/noting
    // clips is core to deciding what to export, so both join Dashboard for
    // them even though the rest of the admin nav is hidden.
    private var visibleNavItems: [NavItem] {
        guard appState.isAdmin else { return [.dashboard, .starred, .exportQueue] }
        var items: [NavItem] = [.dashboard]
        if features.isEnabled(.workflows) { items.append(.workflows) }
        if features.isEnabled(.inventory) { items.append(.inventory) }
        if features.isEnabled(.socialShare) { items.append(.socialShare) }
        items += [.starred, .exportQueue]
        return items
    }

    private func isReachable(_ item: NavItem) -> Bool {
        item == .history || item == .settings ? appState.isAdmin : visibleNavItems.contains(item)
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                masthead

                List(visibleNavItems, id: \.self, selection: $selection) { item in
                    Label {
                        Text(item.rawValue).font(.canopySans(13, weight: .medium))
                    } icon: {
                        Image(systemName: item.icon)
                    }
                    .badge(badgeCount(for: item))
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                // Schedule status badge at bottom of sidebar
                if appState.isAdmin && !scheduledWorkflows.isEmpty {
                    Rectangle().fill(Color.canopyRule).frame(height: 1)
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.canopyCaption)
                            .foregroundStyle(Color.canopySage)
                        Text(scheduleBadgeText)
                            .font(.canopyCaption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                Rectangle().fill(Color.canopyRule).frame(height: 1)
                HStack(spacing: 0) {
                    roleSwitcher
                    Spacer(minLength: 0)
                    if appState.isAdmin {
                        bottomIconButton(.history, help: "History")
                        bottomIconButton(.settings, help: "Settings")
                            .padding(.trailing, 8)
                    }
                }
            }
            .background(Color.canopyPaper)
            .overlay(Rectangle().strokeBorder(Color.canopyRule, lineWidth: 1))
        } detail: {
            VStack(spacing: 0) {
                InterruptedRunsBanner()
                WorkflowConfirmationBanner()

                switch selection {
                case .starred:                              StarredView()
                case .exportQueue:                        ExportQueueView(embedded: true)
                case .workflows where isReachable(.workflows):    WorkflowsView()
                case .inventory where isReachable(.inventory):    InventoryView()
                case .socialShare where isReachable(.socialShare): SocialShareView()
                case .history where appState.isAdmin:      HistoryView()
                case .settings where appState.isAdmin:      SettingsView()
                default:                                    DashboardView()
                }
            }
        }
        .toolbar(removing: .title)
        .background {
            Button("Command Palette") {
                withAnimation(.easeOut(duration: 0.12)) { palette.toggle() }
            }
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .overlay {
            if palette.isPresented {
                CommandPaletteView()
                    .environmentObject(appState)
                    .transition(.opacity)
            }
        }
        .onChange(of: palette.pendingNav) {
            guard let nav = palette.pendingNav else { return }
            if isReachable(nav) { selection = nav }
            palette.pendingNav = nil
        }
        .onReceive(Publishers.CombineLatest3(InventoryStore.shared.$equipment, appState.$hyperDecks, appState.$cloudStores)) { equipment, _, _ in
            // Devices added in Canopy join the inventory record at the same address, once the inventory is loaded.
            if appState.isAdmin { LocalDevice.autoLink(appState, equipment: equipment) }
        }
        .onChange(of: appState.userRole) {
            if !isReachable(selection ?? .dashboard) {
                selection = .dashboard
            }
        }
    }

    // MARK: - Masthead
    // An editorial nameplate above the nav list — the sidebar's first
    // impression, set in the brand serif rather than stock sidebar chrome.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Canopy")
                .font(.canopyTitle)
                .foregroundStyle(Color.canopyInk)
            Text("by Roses as Humans")
                .font(.canopySans(10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 32)
        .padding(.bottom, 10)
    }

    // MARK: - Role switcher
    // Always visible regardless of role, so a Content Manager (who has no
    // access to Settings) can still switch back to Admin. This is a UI mode
    // toggle for the current operator, not an authentication boundary.
    private var roleSwitcher: some View {
        Menu {
            ForEach(UserRole.allCases, id: \.self) { role in
                Button {
                    appState.userRole = role
                } label: {
                    if role == appState.userRole {
                        Label(role.rawValue, systemImage: "checkmark")
                    } else {
                        Text(role.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: appState.userRole.icon)
                Text(appState.userRole.rawValue)
                    .font(.canopyCaption)
                Spacer()
            }
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func bottomIconButton(_ item: NavItem, help: String) -> some View {
        Button {
            selection = item
        } label: {
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .foregroundStyle(selection == item ? Color.canopySage : .secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func badgeCount(for item: NavItem) -> Int {
        switch item {
        case .exportQueue: return exportQueue.items.count
        case .starred:     return clipMetadata.starredEntries.count
        default:           return 0
        }
    }

    private var scheduledWorkflows: [Workflow] {
        appState.workflows.filter { $0.isScheduled }
    }

    private var scheduleBadgeText: String {
        if scheduledWorkflows.count == 1, let workflow = scheduledWorkflows.first {
            let active = workflow.activeTriggers
            if active.count == 1, let trigger = active.first {
                return "\(workflow.name) · \(trigger.displaySummary)"
            }
            return "\(workflow.name) (\(active.count) triggers)"
        }
        return "\(scheduledWorkflows.count) workflows scheduled"
    }
}
