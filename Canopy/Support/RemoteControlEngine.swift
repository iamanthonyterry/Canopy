import Foundation
import Combine

// MARK: - Remote Control Engine
// Owns the OSC and MIDI listeners, applies persisted settings to them, and
// matches incoming messages against the user's mappings to drive HyperDeck
// actions. A singleton (like WorkflowEngine) since there's only ever one
// live set of listeners for the app.

@MainActor
final class RemoteControlEngine: ObservableObject {
    static let shared = RemoteControlEngine()

    let osc = OSCListenerService()
    let midi = MIDIListenerService()

    private let appState = AppState.shared

    private init() {
        osc.onMessage = { [weak self] message, _ in
            self?.handle(osc: message)
        }
        midi.onMessage = { [weak self] message, _ in
            self?.handle(midi: message)
        }
    }

    /// Starts/stops each listener to match the persisted settings. Call
    /// this on launch and again whenever the user changes a setting.
    func applySettings() {
        let settings = appState.remoteControlSettings

        if settings.oscEnabled {
            osc.start(port: settings.oscPort)
        } else {
            osc.stop()
        }

        if settings.midiEnabled {
            midi.start(sourceFilter: settings.midiSourceNames)
        } else {
            midi.stop()
        }
    }

    // MARK: - Matching

    private func handle(osc message: OSCMessage) {
        // The built-in "/hyperdeck/{name}/slot/{n}/format/{fs}" scheme is
        // always active — it doesn't go through the mapping list at all,
        // so it works for every configured device/slot with zero setup.
        if let formatCommand = HyperDeckOSCAddress.parseFormatCommand(message.address) {
            executeHyperDeckFormat(formatCommand)
        } else if let command = RemoteOSCCommand.parse(message.address) {
            executeBuiltIn(command)
        }

        let matches = appState.remoteMappings.filter { mapping in
            guard mapping.isEnabled, case .osc(let address) = mapping.trigger else { return false }
            return address == message.address
        }
        matches.forEach(execute)
    }

    private func handle(midi message: MIDIMessage) {
        let matches = appState.remoteMappings.filter { mapping in
            guard mapping.isEnabled,
                  case .midi(let kind, let channel, let number) = mapping.trigger else { return false }
            return kind == message.kind && channel == message.channel && number == message.number
        }
        matches.forEach(execute)
    }

    // MARK: - Execution

    private func execute(_ mapping: RemoteMapping) {
        switch (mapping.target, mapping.action) {
        case (.hyperDeck(let deckID), .hyperDeck(let action)):
            executeHyperDeck(deckID: deckID, action: action, mapping: mapping)
        case (.switcher(let switcherID), .switcher(let action)):
            executeSwitcher(switcherID: switcherID, action: action, mapping: mapping)
        default:
            // Target/action kind mismatch — shouldn't happen since the
            // editor UI always pairs them, but guard against stale/corrupt
            // persisted data rather than silently doing nothing.
            appState.log("⚠️ Remote control \"\(mapping.name)\" has a mismatched device/action pairing")
        }
    }

    private func executeHyperDeck(deckID: UUID, action: HyperDeckRemoteAction, mapping: RemoteMapping) {
        guard let deck = appState.hyperDecks.first(where: { $0.id == deckID }) else {
            appState.log("⚠️ Remote control \"\(mapping.name)\" targets a device that no longer exists")
            return
        }
        appState.log("🎛 Remote control: \"\(mapping.name)\" → \(action.title) on \(deck.name)")
        Task { await runHyperDeckAction(action, on: deck, source: "Remote control \"\(mapping.name)\"") }
    }

    /// Shared by both the mapping-based path above and the built-in
    /// zero-setup OSC namespace below, so the actual device commands live
    /// in exactly one place.
    private func runHyperDeckAction(_ action: HyperDeckRemoteAction, on deck: HyperDeck, source: String) async {
        switch action {
        case .record:
            await HyperDeckService(host: deck.ipAddress).record()
        case .stop:
            await HyperDeckService(host: deck.ipAddress).stop()
        case .format:
            do {
                try await HyperDeckService.formatDrive(deck: deck)
            } catch {
                appState.log("❌ \(source) format failed on \(deck.name): \(error.localizedDescription)")
            }
        }
    }

    /// Handles the built-in `/hyperdeck/{name}/slot/{n}/format/{fs}` scheme
    /// (see HyperDeckOSCAddress) — resolves the device by name rather than
    /// by a pre-selected mapping, so it works for any configured HyperDeck
    /// and any of its slots without the user setting anything up first.
    private func executeHyperDeckFormat(_ command: HyperDeckOSCFormatCommand) {
        guard let deck = appState.hyperDecks.first(where: { HyperDeckOSCAddress.namesMatch($0.name, command.deviceName) }) else {
            appState.log("⚠️ OSC format command referenced unknown device \"\(command.deviceName)\"")
            return
        }
        appState.log("🎛 OSC: format slot \(command.slot) (\(command.filesystem)) on \(deck.name)")

        Task {
            do {
                try await HyperDeckService.formatDrive(deck: deck, slot: command.slot, filesystem: command.filesystem)
            } catch {
                appState.log("❌ OSC format failed on \(deck.name) slot \(command.slot): \(error.localizedDescription)")
            }
        }
    }

    private func executeSwitcher(switcherID: UUID, action: SwitcherRemoteAction, mapping: RemoteMapping) {
        guard let switcher = appState.switchers.first(where: { $0.id == switcherID }) else {
            appState.log("⚠️ Remote control \"\(mapping.name)\" targets a device that no longer exists")
            return
        }
        appState.log("🎛 Remote control: \"\(mapping.name)\" → \(action.title) on \(switcher.name)")
        Task { await runSwitcherAction(action, on: switcher, source: "Remote control \"\(mapping.name)\"") }
    }

    /// Shared by both the mapping-based path above and the built-in
    /// zero-setup OSC namespace below, so the actual device command lives
    /// in exactly one place.
    private func runSwitcherAction(_ action: SwitcherRemoteAction, on switcher: BlackmagicSwitcher, source: String) async {
        do {
            let command: ATEMControlService.Command
            switch action {
            case .cut:                        command = .cut
            case .auto:                       command = .auto
            case .programInput(let input):    command = .programInput(source: UInt16(input))
            }
            try await ATEMControlService.send(command, to: switcher.ipAddress)
        } catch {
            appState.log("❌ \(source) \(action.title) failed on \(switcher.name): \(error.localizedDescription)")
        }
    }

    /// Handles the built-in `/hyperdeck/{name}/{action}` and
    /// `/switcher/{name}/{action}` scheme (see RemoteOSCCommand) — resolves
    /// the device by name rather than a pre-selected mapping, so every
    /// configured device and action is addressable with zero setup.
    private func executeBuiltIn(_ command: RemoteOSCCommand) {
        switch command {
        case .hyperDeck(let deviceName, let action):
            guard let deck = appState.hyperDecks.first(where: { HyperDeckOSCAddress.namesMatch($0.name, deviceName) }) else {
                appState.log("⚠️ OSC command referenced unknown HyperDeck \"\(deviceName)\"")
                return
            }
            appState.log("🎛 OSC: \(action.title) on \(deck.name)")
            Task { await runHyperDeckAction(action, on: deck, source: "OSC") }

        case .switcher(let deviceName, let action):
            guard let switcher = appState.switchers.first(where: { HyperDeckOSCAddress.namesMatch($0.name, deviceName) }) else {
                appState.log("⚠️ OSC command referenced unknown switcher \"\(deviceName)\"")
                return
            }
            appState.log("🎛 OSC: \(action.title) on \(switcher.name)")
            Task { await runSwitcherAction(action, on: switcher, source: "OSC") }
        }
    }
}
