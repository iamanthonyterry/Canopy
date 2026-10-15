import SwiftUI

/// Displays a live elapsed-time progress bar and label for an active pipeline run.
/// The full (dashboard) layout is driven by `TimelineView` so it ticks on its
/// own internal schedule. The compact (menu-bar) layout deliberately does
/// NOT tick on a timer — see the note above `compactLayout` for why.
/// Pass `compact: true` for the slim menu-bar variant.
struct ElapsedTimeView: View {
    let startTime: Date
    var compact: Bool = false
    /// How much longer the run should take, when known (see
    /// `WorkflowRunSession.estimate`). Nil falls back to the indeterminate
    /// shimmer — e.g. a first run of steps with nothing to measure yet.
    var estimate: RunEstimate? = nil

    var body: some View {
        if compact {
            compactLayout(elapsed: Date().timeIntervalSince(startTime), now: Date())
        } else {
            TimelineView(.periodic(from: startTime, by: 1)) { context in
                fullLayout(elapsed: context.date.timeIntervalSince(startTime), now: context.date)
            }
        }
    }

    // MARK: - Full (dashboard)
    private func fullLayout(elapsed: TimeInterval, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Running", systemImage: "clock")
                    .font(.canopyCaption).bold()
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(trailingLabel(elapsed, now: now))
                    .font(.canopyMono(10, relativeTo: .caption))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progressValue(elapsed, now: now))
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
    private func compactLayout(elapsed: TimeInterval, now: Date) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: progressValue(elapsed, now: now))
                .tint(Color.accentColor)
                .frame(width: 80)
            Text(trailingLabel(elapsed, now: now))
                .font(.canopyMono(10, relativeTo: .caption2))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    // Once we have a real estimate, show actual percent-complete (elapsed
    // vs. elapsed+remaining) instead of the shimmer. Before that fall back
    // to an indeterminate-style shimmer over 60 s cycles so the bar still
    // always appears "moving". The estimate is counted down against `now`,
    // so it keeps moving between the run's own progress updates.
    private func progressValue(_ elapsed: TimeInterval, now: Date) -> Double {
        if let estimate, estimate.label(at: now) != nil {
            let remaining = estimate.remaining(at: now)
            if elapsed + remaining > 0 { return elapsed / (elapsed + remaining) }
        }
        let cycle: Double = 60
        return elapsed.truncatingRemainder(dividingBy: cycle) / cycle
    }

    private func trailingLabel(_ elapsed: TimeInterval, now: Date) -> String {
        guard let label = estimate?.label(at: now) else { return elapsedString(elapsed) }
        return "\(elapsedString(elapsed)) · \(label)"
    }

    private func elapsedString(_ elapsed: TimeInterval) -> String {
        let h = Int(elapsed) / 3600
        let m = Int(elapsed) % 3600 / 60
        let s = Int(elapsed) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
