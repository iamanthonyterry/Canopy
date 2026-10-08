import SwiftUI

/// Names the current production and gives each device a camera letter, so
/// rename patterns can use {project} and {cam}.
struct ShootSettingsView: View {
    @EnvironmentObject var appState: AppState

    private var deviceNames: [String] {
        appState.hyperDecks.map(\.name) + appState.localFolders.map(\.name)
    }

    var body: some View {
        GroupBox(label: Label("Shoot", systemImage: "film.stack")) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Project name") {
                    TextField("e.g. Spring Campaign", text: $appState.shoot.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }

                if !deviceNames.isEmpty {
                    Text("Camera labels").font(.caption).foregroundStyle(.secondary)
                    ForEach(deviceNames, id: \.self) { name in
                        LabeledContent(name) {
                            TextField("A", text: Binding(
                                get: { appState.shoot.cameraLabel(for: name) },
                                set: { appState.shoot.cameraLabels[name] = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        }
                        .font(.caption)
                    }
                }

                Text("Use {project} and {cam} in a Rename step, for example {project}_{cam}_{date}_{index}.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
        .background(Color.canopyPaper)
    }
}
