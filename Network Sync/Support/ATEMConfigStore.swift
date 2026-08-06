import Foundation

// MARK: - ATEM Config Store
//
// Persists ATEMSwitcherState snapshots to disk as one JSON file per config,
// under Application Support, namespaced by switcher so two switchers never
// collide on config names.
enum ATEMConfigStore {
    private static func directory(for switcherID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Network Sync/ATEMConfigs/\(switcherID.uuidString)", isDirectory: true)
    }

    private static func fileURL(for config: ATEMSwitcherState, switcherID: UUID) -> URL {
        directory(for: switcherID).appendingPathComponent("\(config.id.uuidString).json")
    }

    static func list(for switcherID: UUID) -> [ATEMSwitcherState] {
        let dir = directory(for: switcherID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ATEMSwitcherState.self, from: Data(contentsOf: $0)) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    static func save(_ config: ATEMSwitcherState, switcherID: UUID) throws {
        let dir = directory(for: switcherID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(config).write(to: fileURL(for: config, switcherID: switcherID))
    }

    static func delete(_ config: ATEMSwitcherState, switcherID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: config, switcherID: switcherID))
    }
}
