import SwiftUI

/// Settings section for switching whole app sections on or off.
struct FeatureSettingsView: View {
    @ObservedObject private var features = AppFeatures.shared

    var body: some View {
        GroupBox(label: Label("Sections", systemImage: "switch.2")) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AppFeature.allCases) { feature in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: features.binding(for: feature)) {
                            Label(feature.title, systemImage: feature.icon).font(.canopyCaption)
                        }
                        Text(feature.summary)
                            .font(.canopyCaption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 20)
                    }
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
        .background(Color.canopyPaper)
    }
}
