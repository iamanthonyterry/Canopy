import ChurchKitAuth
import Foundation
import Combine
import CryptoKit

// MARK: - Workflows that follow the sign-in
// While this Mac is signed in with the church's website (see SiteAccount), the
// workflow list is kept in the church's `canopy_workflows` table, one row per
// workflow per person, so every computer signed in as that person has the same
// workflows. Each pass compares three things for every workflow: what's on
// this Mac, what's in the table, and what both looked like at the last pass.
// Whichever side changed since then wins. If both changed, the website's copy
// is kept and this Mac's version is saved beside it as "(this Mac)" so nothing
// is lost. Deleting a workflow leaves a marker in the table so the others drop
// it too. Devices aren't synced, so a workflow's targets only mean something on
// a computer that has the same devices set up.

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

    private static let interval: Duration = .seconds(20)
    private static let backoff: TimeInterval = 60
    /// Removed workflows' markers are cleared after this long.
    private static let keepDeleted: TimeInterval = 60 * 24 * 3600

    private struct Meta: Codable, Equatable { var hash: String; var remoteUpdatedAt: String }

    nonisolated private struct RemoteWorkflow: Decodable {
        var id: String
        var definition: String
        var updatedAt: String
        var deletedAt: String?
    }

    private var loop: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private var pending = false
    private var retryAfter = Date.distantPast
    private var tidiedFor: String?

    private init() {}

    func start() {
        guard loop == nil else { return }
        AppState.shared.$workflows
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestSync() }
            .store(in: &bag)
        SiteAccount.shared.$client
            .compactMap { $0 }
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
        guard isEnabled, let db = SiteAccount.shared.client else { return }
        guard !isSyncing else { pending = true; return }
        guard Date() >= retryAfter else { return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            pending = false
            do {
                try await pass(db)
                lastError = nil
                lastSynced = Date()
            } catch {
                let e = error as? SupabaseError
                if e?.status == 401 { SiteAccount.shared.sessionExpired(); return }
                retryAfter = Date().addingTimeInterval(Self.backoff)
                lastError = e?.code == "PGRST205" || e?.status == 404
                    ? "Workflow sync isn't set up on your church's database yet."
                    : error.localizedDescription
                return
            }
        } while pending
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

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

    private func metaKey(_ userID: String) -> String { "workflowSync.meta.\(userID)" }

    private func loadMeta(_ userID: String) -> [String: Meta] {
        UserDefaults.standard.data(forKey: metaKey(userID)).flatMap { try? JSONDecoder().decode([String: Meta].self, from: $0) } ?? [:]
    }

    private func saveMeta(_ meta: [String: Meta], _ userID: String) {
        if let data = try? JSONEncoder().encode(meta) { UserDefaults.standard.set(data, forKey: metaKey(userID)) }
    }

    private func pass(_ db: SupabaseClient) async throws {
        let uid = db.session.userID
        var meta = loadMeta(uid)

        if tidiedFor != uid {
            let cutoff = Self.iso.string(from: Date().addingTimeInterval(-Self.keepDeleted))
            try await db.delete("canopy_workflows", [.eq("user_id", uid), .lt("deleted_at", cutoff)])
            tidiedFor = uid
        }

        let remote = try await db.select("canopy_workflows", "id,definition,updated_at,deleted_at", [.eq("user_id", uid)], as: RemoteWorkflow.self)
        let remoteByID = Dictionary(remote.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

        // Everything from here to the end of the decisions is synchronous, so the local list can't change under it.
        let before = AppState.shared.workflows
        var workflows = before
        var toPush: [(key: String, json: String, hash: String, name: String)] = []
        var toRemove: [String] = []
        var seen = Set<String>()

        func queuePush(_ w: Workflow) {
            guard let e = Self.encode(w) else { return }
            toPush.append((Self.key(w.id), e.json, e.hash, w.name))
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
        saveMeta(meta, uid)

        for item in toPush {
            let row: [String: Any?] = ["user_id": uid, "id": item.key, "name": item.name, "definition": item.json, "deleted_at": nil]
            let data = try await db.upsert("canopy_workflows", row, onConflict: "user_id,id", returning: "updated_at")
            nonisolated struct Stamp: Decodable { var updatedAt: String }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let stamp = try? decoder.decode([Stamp].self, from: data).first {
                meta[item.key] = Meta(hash: item.hash, remoteUpdatedAt: stamp.updatedAt)
                saveMeta(meta, uid)
            }
        }

        if !toRemove.isEmpty {
            try await db.update("canopy_workflows", ["deleted_at": Self.iso.string(from: Date())],
                                [.eq("user_id", uid), .in("id", toRemove)])
        }
    }
}
