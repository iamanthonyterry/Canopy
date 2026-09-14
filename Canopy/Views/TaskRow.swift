import SwiftUI

struct TaskRow: View {
    let task: SyncTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // File name + phase badge
            HStack(spacing: 6) {
                Image(systemName: phaseIcon)
                    .foregroundStyle(phaseColor)
                    .frame(width: 14)
                Text(task.deckName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(task.fileName)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(task.phase.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(phaseColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(phaseColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            // Progress bars
            switch task.phase {
            case .downloading:
                progressBar(label: "Download", value: task.syncProgress, color: .accentColor)
                if let detail = transferDetail {
                    Text(detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            case .converting:
                progressBar(label: "Download", value: 1.0, color: .accentColor.opacity(0.4))
                progressBar(label: "Convert",  value: task.convertProgress, color: .orange)
            case .done:
                ProgressView(value: 1.0).tint(.canopySage)
            case .error:
                if let msg = task.errorMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.canopyRust).font(.caption2)
                        Text(msg).font(.caption2).foregroundStyle(Color.canopyRust)
                    }
                }
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// "3.2 MB/s · ~12s left", built from whatever speed/ETA samples we
    /// have so far. Nil (nothing shown) until at least a speed sample
    /// exists — the first progress tick has no prior sample to derive a
    /// rate from.
    private var transferDetail: String? {
        guard task.bytesPerSecond > 0 else { return nil }
        let speed = ByteCountFormatter.string(fromByteCount: Int64(task.bytesPerSecond), countStyle: .binary) + "/s"
        guard let eta = task.etaSeconds else { return speed }
        return "\(speed) · ~\(Self.formatDuration(eta)) left"
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60, r = s % 60
        if m < 60 { return r == 0 ? "\(m)m" : "\(m)m \(r)s" }
        let h = m / 60, rm = m % 60
        return rm == 0 ? "\(h)h" : "\(h)h \(rm)m"
    }

    private func progressBar(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            ProgressView(value: value)
                .tint(color)
            Text("\(Int(value * 100))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private var phaseIcon: String {
        switch task.phase {
        case .queued:      return "clock"
        case .downloading: return "arrow.down.circle.fill"
        case .converting:  return "film.stack"
        case .done:        return "checkmark.circle.fill"
        case .error:       return "xmark.circle.fill"
        }
    }

    private var phaseColor: Color {
        switch task.phase {
        case .queued:      return .secondary
        case .downloading: return .accentColor
        case .converting:  return .orange
        case .done:        return .canopySage
        case .error:       return .canopyRust
        }
    }
}
