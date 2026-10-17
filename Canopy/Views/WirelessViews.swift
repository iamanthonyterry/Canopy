import SwiftUI
import Combine

// MARK: - Wireless on the dashboard and device page
// Live channel cards for every wireless receiver in the inventory that Canopy
// can talk to, and a sheet that brings channel names in the inventory and on
// the receivers into line.

extension WirelessMonitor.Target {
    /// The receivers in the inventory that can be monitored: a supported make, with an address on this network.
    @MainActor
    static func monitorable(_ equipment: [Equipment]) -> (targets: [WirelessMonitor.Target], skipped: [Equipment]) {
        var targets: [WirelessMonitor.Target] = []
        var skipped: [Equipment] = []
        for e in equipment where e.role == .wirelessReceiver {
            if let brand = WirelessBrand.detect(name: e.name, makeModel: e.makeModel), let host = e.host, isLocalAddress(host) {
                targets.append(.init(id: e.id, name: e.name, host: host, brand: brand, modelHint: "\(e.makeModel) \(e.name)"))
            } else {
                skipped.append(e)
            }
        }
        return (targets.sorted { InventoryRules.ordered($0.name, $1.name) }, skipped)
    }
}

extension InventoryStore {
    /// The inventory port that stands for a receiver's channel: the device's own output numbered the same.
    func wirelessPort(_ e: Equipment, channel: Int) -> EquipmentPort? {
        let outs = e.ownPorts.filter { $0.direction == .output }.sorted { ($0.number ?? Int.max) < ($1.number ?? Int.max) }
        return outs.first { $0.number == channel } ?? (channel - 1 < outs.count ? outs[channel - 1] : nil)
    }
}

/// Starts and stops the monitor for the receivers a view shows, so they're only watched while someone can see them.
@MainActor
final class WirelessHolder: ObservableObject {
    private var held: [String: WirelessMonitor.Target] = [:]

    func set(_ targets: [WirelessMonitor.Target], enabled: Bool) {
        let wanted = enabled ? Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) }) : [:]
        for (id, t) in held where wanted[id] != t {
            WirelessMonitor.shared.release(id)
            held[id] = nil
        }
        for (id, t) in wanted where held[id] == nil {
            WirelessMonitor.shared.retain(t)
            held[id] = t
        }
    }

    func clear() { set([], enabled: false) }
}

// MARK: - Meters and cards

private struct MeterBar: View {
    let fraction: Double?
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.canopyRule.opacity(0.6))
                if let fraction {
                    Capsule().fill(color).frame(width: max(3, g.size.width * fraction))
                }
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.2), value: fraction)
    }
}

struct WirelessChannelCard: View {
    let channel: WirelessChannel
    let inventoryName: String
    let brand: WirelessBrand

    private var live: Bool { channel.onAir }
    private var title: String {
        if !channel.name.isEmpty { return channel.name }
        return inventoryName.isEmpty ? "Channel \(channel.index)" : inventoryName
    }
    private var rfColor: Color {
        guard let f = channel.rfFraction else { return .gray }
        return f > 0.5 ? .green : f > 0.25 ? .orange : .red
    }
    private var audioColor: Color {
        guard let f = channel.audioFraction else { return .gray }
        return f > 0.93 ? .red : f > 0.8 ? .orange : .green
    }
    private var mismatch: Bool {
        !inventoryName.isEmpty && !channel.name.isEmpty
            && brand.sanitizedName(inventoryName).caseInsensitiveCompare(channel.name) != .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(live ? Color.green : Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                Text(title).font(.canopySans(13, weight: .semibold)).foregroundStyle(Color.canopyInk).lineLimit(1)
                Spacer(minLength: 4)
                if channel.muted == true { CanopyPill(label: "Muted", color: .orange) }
                if let b = channel.batteryFraction {
                    HStack(spacing: 3) {
                        Image(systemName: b > 0.6 ? "battery.100" : b > 0.4 ? "battery.50" : b > 0.2 ? "battery.25" : "battery.0")
                            .foregroundStyle(b <= 0.2 ? Color.red : b <= 0.4 ? Color.orange : Color.secondary)
                        Text(channel.batteryText.split(separator: "·").first.map(String.init) ?? "").font(.canopyCaption).foregroundStyle(.secondary)
                    }
                    .help(channel.batteryText)
                }
            }
            if mismatch {
                Text("Inventory: \(inventoryName)").font(.canopyCaption).foregroundStyle(.orange).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("RF").font(.canopyCaption).foregroundStyle(.secondary)
                    Spacer()
                    Text([channel.rfDbm.map { String(format: "%.0f dBm", $0) } ?? (live ? "" : "no signal"),
                          channel.antenna.isEmpty ? "" : "ant \(channel.antenna)"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.canopyCaption).monospacedDigit().foregroundStyle(.secondary)
                }
                MeterBar(fraction: channel.rfFraction, color: rfColor)
                HStack {
                    Text("Audio").font(.canopyCaption).foregroundStyle(.secondary)
                    Spacer()
                    Text(channel.audioDb.map { String(format: "%.0f dB", $0) } ?? "").font(.canopyCaption).monospacedDigit().foregroundStyle(.secondary)
                }
                MeterBar(fraction: channel.audioFraction, color: audioColor)
            }
            HStack {
                Text([channel.transmitterModel, channel.frequencyText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.canopyCaption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                ForEach(channel.warnings.filter { $0 != "NoLink" }, id: \.self) { w in
                    Text(w).font(.canopySans(10, weight: .semibold)).foregroundStyle(.red)
                }
            }
        }
        .padding(10)
        .background(Color.canopyPaperElevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(mismatch ? Color.orange.opacity(0.6) : Color.canopyRule, lineWidth: 1))
        .opacity(live ? 1 : 0.7)
    }
}

/// The state of one receiver and its channel cards.
struct ReceiverBlock: View {
    @ObservedObject private var monitor = WirelessMonitor.shared
    @ObservedObject private var store = InventoryStore.shared
    let target: WirelessMonitor.Target
    /// Show the receiver's name; the dashboard pane already has it as its title.
    var titled = true
    @State private var syncing = false

    var body: some View {
        let snap = monitor.snapshots[target.id]
        let equipment = store.byID[target.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if titled { Text(target.name).font(.canopySans(12, weight: .semibold)).foregroundStyle(Color.canopyInk) }
                Text("\(target.brand.label)\(snap?.model.isEmpty == false ? " \(snap!.model)" : "") · \(target.host)")
                    .font(.canopyCaption).foregroundStyle(.secondary)
                Spacer()
                if snap?.channels.isEmpty == false, equipment != nil {
                    Button("Sync names…") { syncing = true }.buttonStyle(.link).font(.canopyCaption)
                }
            }
            switch snap?.state ?? .connecting {
            case .connecting: Text("Connecting…").font(.canopyCaption).foregroundStyle(.secondary)
            case .offline(let why): Text(why).font(.canopyCaption).foregroundStyle(Color.canopyRust)
            case .live: EmptyView()
            }
            if let snap, !snap.channels.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(snap.sorted) { c in
                        WirelessChannelCard(channel: c, inventoryName: equipment.flatMap { store.wirelessPort($0, channel: c.index)?.label } ?? "", brand: target.brand)
                            .opacity(snap.state == .live ? 1 : 0.5)
                    }
                }
            }
        }
        .sheet(isPresented: $syncing) {
            if let equipment { WirelessSyncSheet(equipment: equipment, target: target) }
        }
    }
}

// MARK: - Dashboard list row and pane

/// A receiver in the dashboard's device list, beside the HyperDecks and storage.
struct WirelessListRow: View {
    @ObservedObject private var monitor = WirelessMonitor.shared
    let target: WirelessMonitor.Target

    private var snap: WirelessSnapshot? { monitor.snapshots[target.id] }
    private var onAir: Int { snap?.channels.values.filter(\.onAir).count ?? 0 }
    private var lowBattery: Bool { snap?.channels.values.contains { $0.onAir && ($0.batteryFraction ?? 1) <= 0.2 } ?? false }
    private var color: Color {
        switch snap?.state ?? .connecting {
        case .live: return .canopySage
        case .offline: return .canopyRust
        case .connecting: return .gray
        }
    }
    private var detail: String {
        switch snap?.state ?? .connecting {
        case .connecting: return "Connecting…"
        case .offline: return "Offline"
        case .live: return "\(snap?.channels.count ?? 0) ch · \(onAir) on air"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.canopyBody)
                Text("\(detail) · \(target.host)").font(.canopyCaption).foregroundStyle(.secondary)
            }
            Spacer()
            if lowBattery { Image(systemName: "battery.25").foregroundStyle(.orange).help("A transmitter's battery is low") }
        }
        .padding(.vertical, 2)
    }
}

/// What the dashboard shows when a receiver is selected: its channels, live.
struct WirelessContentPane: View {
    @ObservedObject private var monitor = WirelessMonitor.shared
    let target: WirelessMonitor.Target

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.title2).foregroundStyle(Color.canopySage)
                        .frame(width: 44, height: 44).background(Color.canopySage.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name).font(.canopyTitle).foregroundStyle(Color.canopyInk)
                        Text("Wireless receiver").font(.canopyCallout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                ReceiverBlock(target: target, titled: false)
            }
            .padding()
        }
    }
}

/// Keeps the dashboard's receivers connected while it is on screen.
struct WirelessDashboardSupport: ViewModifier {
    @ObservedObject private var account = SiteAccount.shared
    @ObservedObject private var store = InventoryStore.shared
    @StateObject private var holder = WirelessHolder()
    @AppStorage("wireless.monitor") private var monitoring = true
    let enabled: Bool

    private var targets: [WirelessMonitor.Target] { WirelessMonitor.Target.monitorable(store.equipment).targets }
    private func update() { holder.set(targets, enabled: enabled && monitoring && account.isConnected && store.level.canViewDetails) }

    func body(content: Content) -> some View {
        content
            .task(id: account.isConnected) {
                if account.isConnected && !store.loadedOnce { await store.refresh() }
            }
            .onAppear(perform: update)
            .onChange(of: targets) { update() }
            .onChange(of: monitoring) { update() }
            .onChange(of: enabled) { update() }
            .onDisappear { holder.clear() }
    }
}

// MARK: - Device page section

struct WirelessSection: View {
    @ObservedObject private var store = InventoryStore.shared
    @StateObject private var holder = WirelessHolder()
    let equipment: Equipment

    private var target: WirelessMonitor.Target? { WirelessMonitor.Target.monitorable([equipment]).targets.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live wireless").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
            if let target {
                ReceiverBlock(target: target)
            } else if WirelessBrand.detect(name: equipment.name, makeModel: equipment.makeModel) == nil {
                Text("Live monitoring supports Shure ULX-D, QLX-D and Axient Digital, Sennheiser EW-DX, and Audio-Technica 3000 and 5000 series receivers.")
                    .font(.canopyCallout).foregroundStyle(.secondary)
            } else {
                Text("Add this receiver's address on this network to watch it live.").font(.canopyCallout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .canopyCard(padding: 14)
        .onAppear { holder.set(target.map { [$0] } ?? [], enabled: store.level.canViewDetails) }
        .onChange(of: target) { holder.set(target.map { [$0] } ?? [], enabled: store.level.canViewDetails) }
        .onDisappear { holder.clear() }
    }
}

// MARK: - Name sync

struct WirelessSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var monitor = WirelessMonitor.shared
    @ObservedObject private var store = InventoryStore.shared
    let equipment: Equipment
    let target: WirelessMonitor.Target

    enum Choice: String, CaseIterable, Identifiable {
        case keep = "Keep both", useDevice = "Use device name", sendToDevice = "Send inventory name"
        var id: String { rawValue }
    }

    @State private var choices: [Int: Choice] = [:]
    @State private var confirm = false
    @State private var working = false
    @State private var results: [String] = []

    private var channels: [WirelessChannel] { monitor.snapshots[target.id]?.sorted ?? [] }
    private func inventoryName(_ c: WirelessChannel) -> String { store.wirelessPort(equipment, channel: c.index)?.label ?? "" }
    private func differs(_ c: WirelessChannel) -> Bool {
        target.brand.sanitizedName(inventoryName(c)).caseInsensitiveCompare(c.name) != .orderedSame
    }
    private var changes: Int { channels.filter { (choices[$0.index] ?? .keep) != .keep }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync channel names · \(equipment.name)").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
            Text("Channels are matched to this device's outputs by number, and the name is the output's label in the inventory. \(target.brand.label) receivers keep names to \(target.brand.nameLimit) characters.")
                .font(.canopyCallout).foregroundStyle(.secondary)
            HStack {
                Button("Use device names") { set(.useDevice) }.buttonStyle(.canopySecondary).disabled(!store.level.canEdit)
                Button("Send inventory names") { set(.sendToDevice) }.buttonStyle(.canopySecondary).disabled(!store.isAdmin)
                Button("Clear") { choices = [:] }.buttonStyle(.link)
                Spacer()
            }
            .font(.canopyCaption)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Ch").foregroundStyle(.secondary); Text("Inventory").foregroundStyle(.secondary)
                    Text("On the device").foregroundStyle(.secondary); Text("Do").foregroundStyle(.secondary)
                }
                .font(.canopyCaption)
                ForEach(channels) { c in
                    GridRow {
                        Text("\(c.index)").monospacedDigit()
                        Text(inventoryName(c).isEmpty ? "—" : inventoryName(c)).foregroundStyle(inventoryName(c).isEmpty ? .secondary : Color.canopyInk)
                        HStack(spacing: 4) {
                            Text(c.name.isEmpty ? "—" : c.name)
                            if !differs(c) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.canopySage).help("Already the same") }
                        }
                        Picker("", selection: Binding(get: { choices[c.index] ?? .keep }, set: { choices[c.index] = $0 })) {
                            Text("Keep both").tag(Choice.keep)
                            if store.level.canEdit && !c.name.isEmpty && store.wirelessPort(equipment, channel: c.index) != nil { Text("Use device name").tag(Choice.useDevice) }
                            if store.isAdmin && !inventoryName(c).isEmpty { Text("Send inventory name").tag(Choice.sendToDevice) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
            .font(.canopyCallout)
            if channels.isEmpty { Text("Waiting for the receiver to report its channels…").foregroundStyle(.secondary) }
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results, id: \.self) { Text($0).font(.canopyCaption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply \(changes) \(changes == 1 ? "change" : "changes")") {
                    if choices.values.contains(.sendToDevice) { confirm = true } else { Task { await apply() } }
                }
                .buttonStyle(.canopyPrimary).disabled(changes == 0 || working)
            }
        }
        .padding(20)
        .frame(minWidth: 560)
        .confirmationDialog("Rename channels on \(equipment.name)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Rename on the receiver") { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes the channel names on the receiver right now. The names show on its display and in other control software.")
        }
    }

    private func set(_ choice: Choice) {
        for c in channels where differs(c) {
            switch choice {
            case .useDevice where !c.name.isEmpty && store.wirelessPort(equipment, channel: c.index) != nil: choices[c.index] = .useDevice
            case .sendToDevice where !inventoryName(c).isEmpty: choices[c.index] = .sendToDevice
            default: break
            }
        }
    }

    private func apply() async {
        working = true; results = []
        defer { working = false }
        for c in channels {
            switch choices[c.index] ?? .keep {
            case .keep: continue
            case .useDevice:
                guard let port = store.wirelessPort(equipment, channel: c.index) else { continue }
                let r = await store.updatePort(port.id, label: c.name)
                results.append("Channel \(c.index): \(r.ok ? "inventory now says “\(c.name)”." : r.message)")
            case .sendToDevice:
                let r = await monitor.rename(target.id, channel: c.index, to: inventoryName(c))
                results.append("Channel \(c.index): \(r.message)")
            }
        }
        choices = [:]
    }
}
