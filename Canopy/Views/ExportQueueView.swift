import SwiftUI
import AppKit

// MARK: - Export Queue View
// Shows every clip queued for batch export — whole files added from a
// folder browser's multi-select, or trimmed clips added from the video
// player — and runs them all against one chosen destination folder.
struct ExportQueueView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = ExportQueueManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if manager.items.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.and.arrow.up.on.square.fill").foregroundStyle(.tint)
            Text("Export Queue").font(.title3).bold()
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No clips queued").foregroundStyle(.secondary)
            Text("Select clips in a folder and tap “Add to Queue”, or queue a trimmed clip from the video player.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(manager.items) { item in
                    ExportQueueRow(item: item, onRemove: { manager.remove(id: item.id) })
                    Divider()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if manager.isRunning {
                ProgressView().controlSize(.small)
                Text("Exporting \(manager.activeCount) remaining…")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { manager.cancel() }
            } else {
                Text("\(manager.items.count) clip\(manager.items.count == 1 ? "" : "s") queued")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Completed") { manager.clearCompleted() }
                    .disabled(!manager.items.contains { $0.phase == .done || $0.phase == .error })
                Button("Export All…") { chooseDestinationAndStart() }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.pendingCount == 0)
            }
        }
        .padding()
    }

    private func chooseDestinationAndStart() {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Destination"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { await manager.start(destination: destination) }
    }
}

// MARK: - Export Queue Row

private struct ExportQueueRow: View {
    let item: ExportQueueItem
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.phase.icon)
                    .foregroundStyle(phaseColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(item.node.name)
                            .lineLimit(1).truncationMode(.middle)
                        if item.isTrimmed {
                            Text("Trimmed")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    Text(item.deviceName)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.phase.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(phaseColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(phaseColor.opacity(0.12))
                    .clipShape(Capsule())

                if item.phase == .queued || item.phase == .done || item.phase == .error {
                    Button { onRemove() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }

            switch item.phase {
            case .downloading, .exporting:
                ProgressView(value: item.progress).tint(phaseColor)
            case .error:
                if let msg = item.errorMessage {
                    Text(msg).font(.caption2).foregroundStyle(.red)
                }
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var phaseColor: Color {
        switch item.phase {
        case .queued:      return .secondary
        case .downloading: return .blue
        case .exporting:   return .orange
        case .done:        return .green
        case .error:       return .red
        }
    }
}
