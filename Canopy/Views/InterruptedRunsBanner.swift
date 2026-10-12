import SwiftUI

// MARK: - Interrupted Runs Banner
// Shown at the top of every page when a previous launch ended mid-run — a
// crash, a power cut, a force quit. Offers to pick each run back up at the
// step it was on. It's never resumed automatically: a deck may have been
// recording or reconnected differently in the meantime, and re-running steps
// like Format or Control HyperDeck should be a person's call.
struct InterruptedRunsBanner: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var store = WorkflowCheckpointStore.shared
    @ObservedObject private var engine = WorkflowEngine.shared

    var body: some View {
        if appState.isAdmin && !store.interrupted.isEmpty {
            VStack(spacing: 1) {
                ForEach(store.interrupted) { checkpoint in
                    row(checkpoint)
                }
            }
            .background(Color.canopyRule)
        }
    }

    private func row(_ checkpoint: WorkflowCheckpoint) -> some View {
        let total = checkpoint.workflow.steps.count
        let canResume = engine.canResume(checkpoint)

        return HStack(spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\"\(checkpoint.workflow.name)\" was interrupted")
                    .font(.subheadline).bold()
                Text(detail(for: checkpoint, total: total, canResume: canResume))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Discard") { store.discard(id: checkpoint.id) }
                .buttonStyle(.canopySecondary).controlSize(.small)
                .help("Forget this run. Files it already copied or converted are left as they are.")
            Button("Resume") { Task { await engine.resume(checkpoint) } }
                .buttonStyle(.canopyPrimary).controlSize(.small)
                .disabled(!canResume)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private func detail(for checkpoint: WorkflowCheckpoint, total: Int, canResume: Bool) -> String {
        var parts: [String] = []
        if let step = checkpoint.nextStep {
            parts.append("Stopped at step \(checkpoint.nextStepIndex + 1) of \(total): \(step.kind.title)")
        } else {
            parts.append("Stopped after its last step")
        }
        parts.append(checkpoint.updatedAt.formatted(date: .abbreviated, time: .shortened))
        if !canResume { parts.append("a device it uses is busy") }
        return parts.joined(separator: " · ")
    }
}
