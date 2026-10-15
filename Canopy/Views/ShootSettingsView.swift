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
                        .frame(minWidth: 120, maxWidth: 220)
                }

                if !deviceNames.isEmpty {
                    Text("Camera labels").font(.canopyCaption).foregroundStyle(.secondary)
                    ForEach(deviceNames, id: \.self) { name in
                        LabeledContent(name) {
                            TextField("A", text: Binding(
                                get: { appState.shoot.cameraLabel(for: name) },
                                set: { appState.shoot.cameraLabels[name] = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        }
                        .font(.canopyCaption)
                    }
                }

                Text("Use {project} and {cam} in a Rename step, for example {project}_{cam}_{date}_{index}.")
                    .font(.canopyCaption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
        .background(Color.canopyPaper)
    }
}
