import Foundation

// MARK: - Link devices to inventory by address
// A HyperDeck or Cloud Store added in Canopy and an equipment record in the
// inventory are the same box when they share an address. This pairs them up
// without anyone choosing, but only when the answer is clear: one device and
// one record on that address, and neither already linked to something else.

extension LocalDevice {
    /// The unlinked local devices that have exactly one inventory record at their address, and that record isn't taken.
    static func addressMatches(devices: [LocalDevice], equipment: [Equipment]) -> [(device: LocalDevice, equipment: Equipment)] {
        let known = Set(equipment.map(\.id))
        let taken = Set(devices.compactMap(\.inventoryID).filter { known.contains($0) })
        func host(_ address: String) -> String? { InventoryRules.hostOf(address)?.lowercased() }

        let byHost = Dictionary(grouping: equipment.compactMap { e in host(e.ipAddress).map { ($0, e) } }, by: \.0)
        let deviceHosts = Dictionary(grouping: devices.compactMap { d in host(d.address).map { ($0, d) } }, by: \.0)

        var out: [(device: LocalDevice, equipment: Equipment)] = []
        for (h, ds) in deviceHosts {
            guard ds.count == 1, let device = ds.first?.1, device.inventoryID.map({ !known.contains($0) }) ?? true else { continue }
            guard let records = byHost[h], records.count == 1, let record = records.first?.1, !taken.contains(record.id) else { continue }
            out.append((device, record))
        }
        return out.sorted { $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending }
    }

    /// Links what matches and says what it did, one line per link. Safe to run again: it only touches unlinked devices.
    @MainActor
    @discardableResult
    static func autoLink(_ appState: AppState, equipment: [Equipment]) -> [String] {
        guard !equipment.isEmpty else { return [] }
        var lines: [String] = []
        for (device, record) in addressMatches(devices: all(appState), equipment: equipment) {
            link(appState, record: record.id, to: device)
            lines.append("\(device.name) is now linked to “\(record.name)” in the inventory (same address, \(device.address)).")
        }
        for line in lines { appState.log("Inventory: \(line)") }
        return lines
    }
}
