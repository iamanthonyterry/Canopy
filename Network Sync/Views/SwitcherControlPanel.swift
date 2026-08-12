import SwiftUI

// MARK: - Switcher Control Panel
//
// A live control surface for a selected ATEM switcher: program/preview bus
// selection and Cut/Auto transitions, sent immediately over the network via
// ATEMControlService. Button highlights reflect whatever the switcher is
// actually doing — including changes made from a physical panel or another
// piece of software — via a state capture (ATEMStateSession) that's
// re-polled on a short interval while this panel is visible.
struct SwitcherControlPanel: View {
    let switcher: BlackmagicSwitcher
    let isOnline: Bool

    @AppStorage private var inputCount: Int
    @State private var liveState: ATEMSwitcherState?
    @State private var pendingSource: UInt16?
    @State private var isCutting = false
    @State private var isAutoTransitioning = false
    @State private var errorMessage: String?

    // 0-indexed M/E number. Every switcher model has at least this one, and
    // ATEMControlService/ATEMStateSession already default to it elsewhere.
    private let meIndex: UInt8 = 0

    init(switcher: BlackmagicSwitcher, isOnline: Bool) {
        self.switcher = switcher
        self.isOnline = isOnline
        _inputCount = AppStorage(wrappedValue: 8, "atem.\(switcher.id.uuidString).inputCount")
    }

    private var currentME: MixEffectState? {
        liveState?.mixEffects.first(where: { $0.index == meIndex })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if !isOnline {
                    Label("Switcher is offline — controls will still send, but may not reach it.", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(.orange)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }

                busRow(title: "PROGRAM", color: .red, selected: currentME?.programInput) { source in
                    send(.programInput(source: source), source: source)
                }

                busRow(title: "PREVIEW", color: .green, selected: currentME?.previewInput) { source in
                    send(.previewInput(source: source), source: source)
                }

                transitionControls

                Stepper("Inputs shown: \(inputCount)", value: $inputCount, in: 2...20)
                    .font(.caption)
                    .frame(maxWidth: 260)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task(id: switcher.ipAddress) { await pollLoop() }
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
                    .disabled(pendingSource == source)
                }
            }
        }
    }

    // MARK: - Transition controls

    private var transitionControls: some View {
        HStack(spacing: 16) {
            Button {
                Task { await sendTransition(.cut, busy: $isCutting) }
            } label: {
                Text("CUT").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .disabled(isCutting || isAutoTransitioning)

            Button {
                Task { await sendTransition(.auto, busy: $isAutoTransitioning) }
            } label: {
                Text("AUTO").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent).tint(.blue)
            .disabled(isCutting || isAutoTransitioning)
        }
    }

    // MARK: - Sending commands

    private func send(_ command: ATEMControlService.Command, source: UInt16) {
        pendingSource = source
        Task {
            defer { pendingSource = nil }
            do {
                try await ATEMControlService.send(command, meIndex: meIndex, to: switcher.ipAddress)
                errorMessage = nil
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sendTransition(_ command: ATEMControlService.Command, busy: Binding<Bool>) async {
        busy.wrappedValue = true
        defer { busy.wrappedValue = false }
        do {
            try await ATEMControlService.send(command, meIndex: meIndex, to: switcher.ipAddress)
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Live state polling

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func refresh() async {
        do {
            let state = try await ATEMStateSession.capture(from: switcher.ipAddress)
            liveState = state
            errorMessage = nil
        } catch {
            // Keep whatever was last captured on screen; only surface the
            // error once we've never managed to capture anything at all.
            if liveState == nil { errorMessage = error.localizedDescription }
        }
    }
}
