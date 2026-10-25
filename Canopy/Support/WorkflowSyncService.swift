import Foundation
import Combine
import CryptoKit

// MARK: - Workflows shared by a campus's Macs
// While this Mac is connected to a campus (see CampusConnection), the workflow
// list is kept on the church's website, one list per campus, so every Mac at
// that campus has the same workflows. The website only ever sees the campus key.
// Each pass compares three things for every workflow: what's on this Mac,
// what's on the website, and what both looked like at the last pass. Whichever
// side changed since then wins. If both changed, the website's copy is kept and
// this Mac's version is saved beside it as "(this Mac)" so nothing is lost.
// Deleting a workflow leaves a marker on the website so the others drop it too.
// Devices aren't synced, so a workflow's targets only mean something on a Mac
// that has the same devices set up.

@MainActor
final class WorkflowSyncService: ObservableObject {
    static let shared = WorkflowSyncService()

    @Published var isEnabled: Bool = UserDefaults.standard.object(forKey: "workflowSync.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "workflowSync.enabled")
            if isEnabled { requestSync() }
        }
    }
    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false

    /// A change here syncs within a couple of seconds; this is only how often a Mac looks for changes made elsewhere.
    private static let interval: Duration = .seconds(60)
    private static let backoff: TimeInterval = 60

    struct Meta: Codable, Equatable { var hash: String; var remoteUpdatedAt: String }

    /// One workflow as the website lists it. `definition` is only filled in for the ones that changed.
    nonisolated struct RemoteWorkflow: Decodable, Equatable {
        var id: String
        var name: String?
        var definition: String = ""
        var updatedAt: String
        var deletedAt: String?

        private enum CodingKeys: String, CodingKey { case id, name, definition, updatedAt, deletedAt }
        init(id: String, name: String? = nil, definition: String = "", updatedAt: String, deletedAt: String? = nil) {
            (self.id, self.name, self.definition, self.updatedAt, self.deletedAt) = (id, name, definition, updatedAt, deletedAt)
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            definition = try c.decodeIfPresent(String.self, forKey: .definition) ?? ""
            updatedAt = try c.decode(String.self, forKey: .updatedAt)
            deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        }
    }

    nonisolated private struct Listing: Decodable { var church: String?; var campus: String?; var workflows: [RemoteWorkflow] }
    nonisolated private struct Stamps: Decodable { struct Stamp: Decodable { var id: String; var updatedAt: String }; var stamps: [Stamp] }

    private var loop: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private var pending = false
    private var retryAfter = Date.distantPast

    private init() {}

    func start() {
        guard loop == nil else { return }
        AppState.shared.$workflows
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestSync() }
            .store(in: &bag)
        CampusConnection.shared.$key
            .removeDuplicates()
            .filter { !$0.isEmpty }
            .sink { [weak self] _ in self?.retryAfter = .distantPast; self?.requestSync() }
            .store(in: &bag)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func requestSync() { Task { await sync() } }

    // MARK: Pass

    private func sync() async {
        guard isEnabled, CampusConnection.shared.isConnected else { return }
        guard !isSyncing else { pending = true; return }
        guard Date() >= retryAfter else { return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            pending = false
            do {
                try await pass()
                lastError = nil
                lastSynced = Date()
            } catch {
                retryAfter = Date().addingTimeInterval(Self.backoff)
                lastError = error.localizedDescription
                return
            }
        } while pending
    }

    private static func encode(_ w: Workflow) -> (json: String, hash: String)? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(w) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (String(decoding: data, as: UTF8.self), hash)
    }

    private static func decode(_ json: String) -> Workflow? {
        try? JSONDecoder().decode(Workflow.self, from: Data(json.utf8))
    }

    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// What was last seen is kept per campus (not per key), so a regenerated key doesn't make every workflow look new.
    private func metaKey(_ campus: String) -> String { "workflowSync.meta.campus.\(campus)" }

    private func loadMeta(_ campus: String) -> [String: Meta] {
        UserDefaults.standard.data(forKey: metaKey(campus)).flatMap { try? JSONDecoder().decode([String: Meta].self, from: $0) } ?? [:]
    }

    private func saveMeta(_ meta: [String: Meta], _ campus: String) {
        if let data = try? JSONEncoder().encode(meta) { UserDefaults.standard.set(data, forKey: metaKey(campus)) }
    }

    /// Fetches the definitions of just these workflows (the ones new or changed since this Mac last saw them).
    private func fetchDefinitions(_ ids: [String]) async throws -> [String: String] {
        var definitions: [String: String] = [:]
        for batch in stride(from: 0, to: ids.count, by: 20).map({ Array(ids[$0..<min($0 + 20, ids.count)]) }) {
            let query = [URLQueryItem(name: "ids", value: batch.joined(separator: ","))]
            let full = try JSONDecoder().decode(Listing.self, from: try await CampusConnection.shared.call("api/workflow-sync", query: query))
            for w in full.workflows { definitions[w.id.lowercased()] = w.definition }
        }
        return definitions
    }

    private func pass() async throws {
        let connection = CampusConnection.shared
        // One cheap listing says what is there; only the new or changed workflows are fetched in full.
        let listing = try JSONDecoder().decode(Listing.self, from: try await connection.call("api/workflow-sync"))
        let campus = [listing.church, listing.campus].compactMap { $0 }.joined(separator: "-")
        let campusKey = campus.isEmpty ? "campus" : campus
        var meta = loadMeta(campusKey)
        let wanted = listing.workflows.filter { $0.deletedAt == nil && meta[$0.id.lowercased()]?.remoteUpdatedAt != $0.updatedAt }.map(\.id)
        let definitions = try await fetchDefinitions(wanted)
        let remote = listing.workflows.map { w -> RemoteWorkflow in
            var r = w; r.definition = definitions[w.id.lowercased()] ?? ""; return r
        }
        let remoteByID = Dictionary(remote.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

        // Everything from here to the end of the decisions is synchronous, so the local list can't change under it.
        let before = AppState.shared.workflows
        var workflows = before
        var toPush: [(key: String, name: String, json: String, hash: String)] = []
        var toRemove: [String] = []
        var seen = Set<String>()

        func queuePush(_ w: Workflow) {
            guard let e = Self.encode(w) else { return }
            toPush.append((Self.key(w.id), w.name, e.json, e.hash))
        }
        func adopt(_ r: RemoteWorkflow, into list: inout [Workflow], replacing id: UUID?) {
            guard let rw = Self.decode(r.definition), let e = Self.encode(rw) else { return }
            if let id, let i = list.firstIndex(where: { $0.id == id }) { list[i] = rw } else { list.append(rw) }
            meta[Self.key(rw.id)] = Meta(hash: e.hash, remoteUpdatedAt: r.updatedAt)
        }

        for w in before {
            let k = Self.key(w.id)
            seen.insert(k)
            guard let e = Self.encode(w) else { continue }
            guard let r = remoteByID[k] else { queuePush(w); continue }
            let m = meta[k]

            if r.deletedAt != nil {
                if let m, m.hash == e.hash {
                    workflows.removeAll { $0.id == w.id }
                    meta[k] = nil
                } else {
                    queuePush(w)   // edited here after it was removed elsewhere (or never synced): keep it
                }
                continue
            }

            let localChanged = m == nil || m?.hash != e.hash
            let remoteChanged = m == nil || m?.remoteUpdatedAt != r.updatedAt
            switch (localChanged, remoteChanged) {
            case (false, false):
                break
            case (true, false):
                queuePush(w)
            case (false, true):
                adopt(r, into: &workflows, replacing: w.id)
            case (true, true):
                guard let rw = Self.decode(r.definition) else { continue }   // saved by a newer Canopy; leave it be
                if Self.encode(rw)?.hash == e.hash {
                    meta[k] = Meta(hash: e.hash, remoteUpdatedAt: r.updatedAt)
                } else {
                    var copy = w
                    copy.id = UUID()
                    copy.name = "\(w.name) (this Mac)"
                    adopt(r, into: &workflows, replacing: w.id)
                    workflows.append(copy)
                    queuePush(copy)
                }
            }
        }

        for r in remote where !seen.contains(r.id.lowercased()) {
            let k = r.id.lowercased()
            if r.deletedAt != nil { meta[k] = nil; continue }
            if meta[k] != nil { toRemove.append(k); continue }   // removed here since the last pass
            adopt(r, into: &workflows, replacing: nil)
        }

        meta = meta.filter { seen.contains($0.key) || remoteByID[$0.key] != nil }
        if workflows != before { AppState.shared.workflows = workflows }
        for k in toRemove { meta[k] = nil }
        saveMeta(meta, campusKey)

        for item in toPush {
            let body: [String: Any] = ["upserts": [["id": item.key, "name": item.name, "definition": item.json]]]
            let stamps = try JSONDecoder().decode(Stamps.self, from: try await connection.post("api/workflow-sync", body))
            if let stamp = stamps.stamps.first {
                meta[item.key] = Meta(hash: item.hash, remoteUpdatedAt: stamp.updatedAt)
                saveMeta(meta, campusKey)
            }
        }

        if !toRemove.isEmpty {
            _ = try await connection.post("api/workflow-sync", ["deletes": toRemove])
        }
    }
}
