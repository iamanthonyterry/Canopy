import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: NavItem? = .dashboard

    enum NavItem: String, Hashable, CaseIterable {
        case dashboard = "Dashboard"
        case workflows = "Workflows"
        case history   = "History"
        case settings  = "Settings"

        var icon: String {
            switch self {
            case .dashboard: return "play.tv"
            case .workflows: return "flowchart"
            case .history:   return "clock.arrow.circlepath"
            case .settings:  return "gearshape"
            }
        }
    }

    private var visibleNavItems: [NavItem] {
        appState.isAdmin ? NavItem.allCases : [.dashboard]
    }

    var body: some View {
        NavigationSplitView {
            List(visibleNavItems, id: \.self, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
            }
            .listStyle(.sidebar)
            .navigationTitle("Canopy")

            // Schedule status badge at bottom of sidebar
            if appState.isAdmin && !scheduledWorkflows.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                    Text(scheduleBadgeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()
            roleSwitcher
        } detail: {
            switch selection {
            case .workflows where appState.isAdmin: WorkflowsView()
            case .history where appState.isAdmin:    HistoryView()
            case .settings where appState.isAdmin:    SettingsView()
            default:                                  DashboardView()
            }
        }
        .onChange(of: appState.userRole) {
            if !visibleNavItems.contains(selection ?? .dashboard) {
                selection = .dashboard
            }
        }
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
                    .font(.caption)
                Spacer()
            }
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var scheduledWorkflows: [Workflow] {
        appState.workflows.filter { $0.isScheduled }
    }

    private var scheduleBadgeText: String {
        if scheduledWorkflows.count == 1, let workflow = scheduledWorkflows.first {
            let active = workflow.activeTriggers
            if active.count == 1, let trigger = active.first {
                return "\(workflow.name) at \(trigger.mode == .oneTime ? trigger.displayOneTimeDate : trigger.displayTime)"
            }
            return "\(workflow.name) (\(active.count) triggers)"
        }
        return "\(scheduledWorkflows.count) workflows scheduled"
    }
}
