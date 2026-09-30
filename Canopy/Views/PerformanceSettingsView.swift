import SwiftUI

/// Caps how many hardware video encodes run at once across every deck in a
/// workflow (see ConversionSlotLimiter). A per-workflow Convert step also
/// has its own "parallel jobs" setting, but this is the app-wide ceiling
/// underneath all of them combined — a property of this Mac's hardware,
/// not of any one workflow.
struct PerformanceSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        GroupBox(label: Label("Conversion Performance", systemImage: "cpu")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Simultaneous Conversions").font(.caption)
                    Spacer()
                    Stepper(
                        "\(appState.maxConcurrentConversions)",
                        value: $appState.maxConcurrentConversions, in: 1...8
                    )
                    .frame(width: 140)
                    .font(.caption)
                }

                Text("Caps how many clips convert at once across every deck in a workflow. Higher isn't always faster — most Macs only have a couple of hardware encoder slots, so raising this past what your Mac can actually run in parallel can make conversions slower, not faster.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
        .background(Color.canopyPaper)
    }
}
