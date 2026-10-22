import SwiftUI

/// The "what to look for" controls for the Find Clips workflow step.
struct ClipFocusFields: View {
    @Binding var focus: ClipFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(ClipKind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(get: { focus.kinds.contains(kind) }, set: { focus.set(kind, on: $0) }))
                }
            }
            .toggleStyle(.checkbox)
            TextField("Anything specific", text: $focus.notes, prompt: Text("Anything specific? e.g. quotes about hope"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            Text("Leave empty to find whatever stands out. Music is found by listening to the audio; everything else comes from what's said.")
                .font(.canopyCaption).foregroundStyle(.secondary)
        }
        .font(.canopyCallout)
    }
}
