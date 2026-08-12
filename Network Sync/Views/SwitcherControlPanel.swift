import SwiftUI

// MARK: - Switcher Control Panel
//
// A live control surface for a selected ATEM switcher: program/preview bus
// selection and Cut/Auto transitions, sent immediately over the network via
// a single persistent ATEMLiveSession for as long as this panel is on
// screen. Button highlights reflect whatever the switcher is actually
// doing — including changes made from a physical panel or another piece of
// software — since the session continuously decodes the switcher's state
// rather than polling it.
struct SwitcherControlPanel: View {
    let switcher: BlackmagicSwitcher

    @AppStorage private var inputCount: Int
    @StateObject private var session: ATEMLiveSession

    // 0-indexed M/E number. Every switcher model has at least this one, and
    // ATEMControlService/ATEMStateSession already default to it elsewhere.
    private let meIndex: UInt8 = 0

    init(switcher: BlackmagicSwitcher) {
        self.switcher = switcher
        _inputCount = AppStorage(wrappedValue: 8, "atem.\(switcher.id.uuidString).inputCount")
        _session = StateObject(wrappedValue: ATEMLiveSession(host: switcher.ipAddress))
    }

    private var currentME: MixEffectState? {
        session.state.mixEffects.first(where: { $0.index == meIndex })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                statusBanner

                busRow(title: "PROGRAM", color: .red, selected: currentME?.programInput) { source in
                    session.send(.programInput(source: source), meIndex: meIndex)
                }

                busRow(title: "PREVIEW", color: .green, selected: currentME?.previewInput) { source in
                    session.send(.previewInput(source: source), meIndex: meIndex)
                }

                transitionControls

                Stepper("Inputs shown: \(inputCount)", value: $inputCount, in: 2...20)
                    .font(.caption)
                    .frame(maxWidth: 260)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { session.connect() }
        .onDisappear { session.disconnect() }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusBanner: some View {
        if let lastError = session.lastError {
            Label(lastError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        } else if !session.isConnected {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting to switcher…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bus rows

    private func busRow(title: String, color: Color, selected: UInt16?, action: @escaping (UInt16) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).bold().foregroundStyle(color)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                ForEach(1...inputCount, id: \.self) { input in
                    let source = UInt16(input)
                    let isSelected = selected == source
                    Button {
                        action(source)
                    } label: {
                        Text("\(input)")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelected ? color : .secondary)
                    .disabled(!session.isConnected)
                }
            }
        }
    }

    // MARK: - Transition controls

    private var transitionControls: some View {
        HStack(spacing: 16) {
            Button {
                session.send(.cut, meIndex: meIndex)
            } label: {
                Text("CUT").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .disabled(!session.isConnected)

            Button {
                session.send(.auto, meIndex: meIndex)
            } label: {
                Text("AUTO").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent).tint(.blue)
            .disabled(!session.isConnected)
        }
    }
}
