import SwiftUI

/// Displays a live elapsed-time progress bar and label for an active pipeline run.
/// The full (dashboard) layout is driven by `TimelineView` so it ticks on its
/// own internal schedule. The compact (menu-bar) layout deliberately does
/// NOT tick on a timer — see the note above `compactLayout` for why.
/// Pass `compact: true` for the slim menu-bar variant.
struct ElapsedTimeView: View {
    let startTime: Date
    var compact: Bool = false

    var body: some View {
        if compact {
            compactLayout(elapsed: Date().timeIntervalSince(startTime))
        } else {
            TimelineView(.periodic(from: startTime, by: 1)) { context in
                fullLayout(elapsed: context.date.timeIntervalSince(startTime))
            }
        }
    }

    // MARK: - Full (dashboard)
    private func fullLayout(elapsed: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Running", systemImage: "clock")
                    .font(.caption).bold()
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(elapsedString(elapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progressValue(elapsed))
                .tint(Color.accentColor)
                .animation(.linear(duration: 1), value: elapsed)
        }
    }

    // MARK: - Compact (menu bar)
    //
    // NOTE: This is hosted inside a `.menuBarExtraStyle(.menu)` scene, which
    // is bridged to a real NSMenu. NSMenu's tracking loop cannot safely host
    // a subtree that keeps re-rendering itself on its own schedule — a
    // previous version drove this with `TimelineView(.periodic...)`, and
    // even with animations disabled via `.transaction`, every per-second
    // tick re-entered the menu's item-update pass with no base case,
    // recursing thousands of frames deep and overflowing the stack
    // (EXC_BAD_ACCESS / "Could not determine thread index for stack guard
    // region"). This variant now computes `elapsed` once per call instead
    // of ticking on its own timer; the surrounding `MenuBarView` already
    // re-renders frequently while a run is active (task counts changing),
    // which keeps this reasonably fresh without a self-driven update loop.
    // Only `fullLayout`, rendered in a normal window, may tick and animate.
    private func compactLayout(elapsed: TimeInterval) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: progressValue(elapsed))
                .tint(Color.accentColor)
                .frame(width: 80)
            Text(elapsedString(elapsed))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    // Animate an indeterminate-style shimmer over 60 s cycles so the bar
    // always appears "moving" even though there's no real percent-complete
    // for an open-ended run.
    private func progressValue(_ elapsed: TimeInterval) -> Double {
        let cycle: Double = 60
        return elapsed.truncatingRemainder(dividingBy: cycle) / cycle
    }

    private func elapsedString(_ elapsed: TimeInterval) -> String {
        let h = Int(elapsed) / 3600
        let m = Int(elapsed) % 3600 / 60
        let s = Int(elapsed) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
