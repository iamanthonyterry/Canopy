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

    var body: some View {
        NavigationSplitView {
            List(NavItem.allCases, id: \.self, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
            }
            .listStyle(.sidebar)
            .navigationTitle("Church Sync")

            // Schedule status badge at bottom of sidebar
            if !scheduledWorkflows.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text(scheduleBadgeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        } detail: {
            switch selection {
            case .dashboard, .none: DashboardView()
            case .workflows:        WorkflowsView()
            case .history:          HistoryView()
            case .settings:         SettingsView()
            }
        }
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
