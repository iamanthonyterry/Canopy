import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: NavItem? = .dashboard

    enum NavItem: String, Hashable, CaseIterable {
        case dashboard = "Dashboard"
        case workflows = "Workflows"
        case storage   = "View Content"
        case history   = "History"
        case settings  = "Settings"

        var icon: String {
            switch self {
            case .dashboard: return "play.tv"
            case .workflows: return "flowchart"
            case .storage:   return "externaldrive"
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
            case .storage:          StorageBrowserView()
            case .history:          HistoryView()
            case .settings:         SettingsView()
            }
        }
        .background(videoPlayerWarmUp)
    }

    // Forces AVKit's SwiftUI-representable generic metadata to be resolved
    // once, here, during ordinary app-launch view construction. Without this,
    // the first VideoPlayer a user ever creates is the one inside
    // VideoPlayerSheet's .sheet — and building that metadata for the first
    // time while the sheet's reentrant view-graph update is in flight (a
    // ToolbarReader preference pass runs concurrently with
    // SheetBridge.createSheet) can lose a race in the Swift runtime's
    // generic metadata cache, aborting with a fatalError inside
    // _AVKit_SwiftUI's getSuperclassMetadata. It only reproduces reliably in
    // optimized Release builds, not Xcode's unoptimized Debug builds, since
    // it's a timing-dependent race. Instantiating the type here — during a
    // plain, non-reentrant update at launch — resolves it once up front so
    // the sheet later just looks it up.
    private var videoPlayerWarmUp: some View {
        VideoPlayer(player: nil)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
