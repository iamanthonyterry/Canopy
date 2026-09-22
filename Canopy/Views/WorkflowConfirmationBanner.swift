import SwiftUI

// MARK: - Global Workflow Confirmation Banner
// A `.requiresConfirmation` step pauses its run until the user responds —
// but the user might be looking at Dashboard, History, whatever, not the
// Workflows tab. This sits above the page content in ContentView so the
// prompt is visible (and answerable) no matter where they are, instead of
// only when they happen to be on Workflows.
struct WorkflowConfirmationBanner: View {
    @EnvironmentObject var appState: AppState

    private var pending: [WorkflowRunSession] {
        appState.activeRuns.filter { !$0.isFinished && $0.pendingConfirmationStep != nil }
    }

    var body: some View {
        if !pending.isEmpty {
            VStack(spacing: 1) {
                ForEach(pending) { session in
                    if let step = session.pendingConfirmationStep {
                        row(session: session, step: step)
                    }
                }
            }
            .background(Color.canopyRule)
        }
    }

    private func row(session: WorkflowRunSession, step: WorkflowStep) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\"\(session.workflow.name)\" — confirm \"\(step.kind.title)\"?")
                    .font(.subheadline).bold()
                Text(step.action.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Stop") { session.resolveConfirmation(proceed: false) }
                .buttonStyle(.canopySecondary).controlSize(.small)
            Button("Continue") { session.resolveConfirmation(proceed: true) }
                .buttonStyle(.canopyPrimary).controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}
