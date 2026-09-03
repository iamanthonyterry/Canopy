import SwiftUI
import AppKit

// MARK: - Export Queue View
// Shows every clip queued for batch export — whole files added from a
// folder browser's multi-select, or trimmed clips added from the video
// player — and runs them all against one chosen destination folder.
struct ExportQueueView: View {
    /// When true, this renders as a full-pane page (e.g. the Dashboard's
    /// Export Queue selection) instead of a fixed-size dismissible sheet —
    /// no Close button, and it fills whatever space its container gives it.
    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = ExportQueueManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            rule
            if manager.items.isEmpty {
                emptyState
            } else {
                list
            }
            rule
            footer
        }
        .frame(minWidth: embedded ? 0 : 480, minHeight: embedded ? 0 : 420)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .background(Color.canopyPaper)
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.and.arrow.up.on.square.fill").foregroundStyle(.tint)
            Text("Export Queue").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
            Spacer()
            if !embedded {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
    }

    // MARK: - Hairline rule
    private var rule: some View {
        Rectangle().fill(Color.canopyRule).frame(height: 1)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(Color.canopySage)
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
                    .buttonStyle(.canopyPrimary)
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
                CanopyPill(label: item.phase.label, color: phaseColor)

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
                    Text(msg).font(.caption2).foregroundStyle(Color.canopyRust)
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
        case .downloading: return .accentColor
        case .exporting:   return .orange
        case .done:        return .canopySage
        case .error:       return .canopyRust
        }
    }
}
