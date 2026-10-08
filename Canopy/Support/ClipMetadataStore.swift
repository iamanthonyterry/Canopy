import Foundation
import Combine

/// Persists stars and notes on individual clips, keyed by `FileNode.id`.
/// Same persistence approach as `AppState` (UserDefaults + JSON, no Core
/// Data), kept as its own store rather than folded into `AppState` since
/// it's clip-scoped data rather than app configuration.
@MainActor
final class ClipMetadataStore: ObservableObject {
    static let shared = ClipMetadataStore()

    @Published private(set) var entries: [String: ClipMetadata] = [:] {
        didSet { save() }
    }

    private let storageKey = "clipMetadata"

    private init() {
        entries = load()
    }

    // MARK: - Reads

    func metadata(for nodeID: String) -> ClipMetadata? {
        entries[nodeID]
    }

    func isStarred(_ nodeID: String) -> Bool {
        entries[nodeID]?.starred ?? false
    }

    func note(for nodeID: String) -> String {
        entries[nodeID]?.note ?? ""
    }

    /// Starred clips, most recently updated first, for the Starred view.
    var starredEntries: [(id: String, metadata: ClipMetadata)] {
        entries
            .filter { $0.value.starred }
            .map { (id: $0.key, metadata: $0.value) }
            .sorted { $0.metadata.updatedAt > $1.metadata.updatedAt }
    }

    // MARK: - Writes

    func toggleStar(node: FileNode, device: DeviceSource) {
        var metadata = snapshot(for: node, device: device)
        metadata.starred.toggle()
        metadata.updatedAt = Date()
        store(metadata, for: node.id)
    }

    func setNote(_ text: String, node: FileNode, device: DeviceSource) {
        var metadata = snapshot(for: node, device: device)
        metadata.note = text
        metadata.updatedAt = Date()
        store(metadata, for: node.id)
    }

    func label(for nodeID: String) -> ClipLabel? {
        entries[nodeID]?.label
    }

    func keywords(for nodeID: String) -> [String] {
        entries[nodeID]?.keywords ?? []
    }

    func setLabel(_ label: ClipLabel?, node: FileNode, device: DeviceSource) {
        var metadata = snapshot(for: node, device: device)
        metadata.label = label
        metadata.updatedAt = Date()
        store(metadata, for: node.id)
    }

    /// Accepts a free-form comma/newline separated string; trims, drops
    /// blanks and case-insensitive duplicates.
    func setKeywords(_ raw: String, node: FileNode, device: DeviceSource) {
        var metadata = snapshot(for: node, device: device)
        metadata.keywords = Self.parseKeywords(raw)
        metadata.updatedAt = Date()
        store(metadata, for: node.id)
    }

    static func parseKeywords(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func markers(for nodeID: String) -> [ClipMarker] {
        (entries[nodeID]?.markers ?? []).sorted { $0.time < $1.time }
    }

    func addMarker(at time: Double, node: FileNode, device: DeviceSource) {
        var metadata = snapshot(for: node, device: device)
        let label = "Marker \(metadata.markers.count + 1)"
        metadata.markers.append(ClipMarker(time: time, label: label))
        metadata.updatedAt = Date()
        store(metadata, for: node.id)
    }

    func renameMarker(_ markerID: UUID, to label: String, nodeID: String) {
        guard var metadata = entries[nodeID],
              let i = metadata.markers.firstIndex(where: { $0.id == markerID }) else { return }
        metadata.markers[i].label = label
        metadata.updatedAt = Date()
        store(metadata, for: nodeID)
    }

    func removeMarker(_ markerID: UUID, nodeID: String) {
        guard var metadata = entries[nodeID] else { return }
        metadata.markers.removeAll { $0.id == markerID }
        metadata.updatedAt = Date()
        store(metadata, for: nodeID)
    }

    /// Id-only variants for callers (the Starred view) that already have an
    /// existing entry in hand and don't necessarily have a live `FileNode`/
    /// `DeviceSource` to reconstruct one from — e.g. a clip whose device was
    /// since removed. No-ops if there's no existing entry for `id`, which
    /// only matters if it's called before the clip was ever starred/noted.
    func toggleStar(id: String) {
        guard var metadata = entries[id] else { return }
        metadata.starred.toggle()
        metadata.updatedAt = Date()
        store(metadata, for: id)
    }

    func setNote(_ text: String, id: String) {
        guard var metadata = entries[id] else { return }
        metadata.note = text
        metadata.updatedAt = Date()
        store(metadata, for: id)
    }

    /// Merges new fields onto any existing entry (so an edit doesn't clobber
    /// the other field), or starts fresh from the node/device if none exists
    /// yet. Empty entries (unstarred, no note) are dropped rather than kept
    /// around as dead weight.
    private func snapshot(for node: FileNode, device: DeviceSource) -> ClipMetadata {
        entries[node.id] ?? ClipMetadata(
            clipName: node.name,
            deviceID: device.id,
            deviceLabel: device.name,
            ftpPath: node.ftpPath,
            localURL: node.url,
            isVideo: node.isVideo,
            isImage: node.isImage,
            size: node.size,
            modified: node.modified,
            updatedAt: Date()
        )
    }

    private func store(_ metadata: ClipMetadata, for nodeID: String) {
        if metadata.isEmpty {
            entries.removeValue(forKey: nodeID)
        } else {
            entries[nodeID] = metadata
        }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() -> [String: ClipMetadata] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ClipMetadata].self, from: data)) ?? [:]
    }
}
