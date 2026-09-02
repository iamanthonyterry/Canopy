import Foundation
import Combine
import SwiftUI

// MARK: - User Role
// Admin has full access. Content Manager is a restricted mode for operators
// who should only be able to view and trim/export video — no device setup,
// workflow automation, or other settings.
enum UserRole: String, Codable, CaseIterable, Hashable {
    case admin = "Admin"
    case contentManager = "Content Manager"

    var icon: String {
        switch self {
        case .admin:          return "person.badge.key.fill"
        case .contentManager: return "film"
        }
    }
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - Persisted State
    @Published var userRole: UserRole = .admin {
        didSet { save(userRole, key: "userRole") }
    }
    @Published var hyperDecks: [HyperDeck] = [] {
        didSet { save(hyperDecks, key: "hyperDecks") }
    }
    @Published var cloudStores: [CloudStore] = [] {
        didSet { save(cloudStores, key: "cloudStores") }
    }
    @Published var localFolders: [LocalFolder] = [] {
        didSet { save(localFolders, key: "localFolders") }
    }
    @Published var syncLocation: SyncLocation = SyncLocation() {
        didSet { save(syncLocation, key: "syncLocation") }
    }
    @Published var workflows: [Workflow] = [] {
        didSet { save(workflows, key: "workflows") }
    }
    @Published var workflowRunHistory: [WorkflowRun] = [] {
        didSet { save(workflowRunHistory, key: "workflowRunHistory") }
    }
    @Published var emailNotificationSettings: EmailNotificationSettings = EmailNotificationSettings() {
        didSet { save(emailNotificationSettings, key: "emailNotificationSettings") }
    }
    @Published var remoteControlSettings: RemoteControlSettings = RemoteControlSettings() {
        didSet { save(remoteControlSettings, key: "remoteControlSettings") }
    }
    @Published var remoteMappings: [RemoteMapping] = [] {
        didSet { save(remoteMappings, key: "remoteMappings") }
    }
    @Published var alertSettings: AlertSettings = AlertSettings() {
        didSet { save(alertSettings, key: "alertSettings") }
    }

    // MARK: - Live Pipeline State
    // Every in-progress (or just-finished-with-something-to-show) workflow
    // run gets its own session here, instead of one shared set of "current
    // run" properties — that's what lets unrelated workflows run at the
    // same time. A session is removed once it finishes cleanly; one that
    // hit a mount error or has failed tasks sticks around so the user can
    // retry or dismiss it.
    @Published var activeRuns: [WorkflowRunSession] = []

    var isAdmin: Bool { userRole == .admin }

    var isRunning: Bool { activeRuns.contains { !$0.isFinished } }
    var allTasks: [SyncTask] { activeRuns.flatMap(\.tasks) }
    var failedTasks: [SyncTask] { allTasks.filter { $0.phase == .error } }

    /// Names of devices currently in use by any in-progress run.
    var busyDeckNames: Set<String> {
        activeRuns.filter { !$0.isFinished }.reduce(into: Set<String>()) { $0.formUnion($1.deckNames) }
    }

    func targetDeviceNames(for workflow: Workflow) -> Set<String> {
        guard !workflow.targets.isEmpty else {
            return Set(hyperDecks.map(\.name) + localFolders.map(\.name))
        }
        var names: Set<String> = []
        for target in workflow.targets {
            switch target {
            case .hyperDeck(let id):
                if let deck = hyperDecks.first(where: { $0.id == id }) { names.insert(deck.name) }
            case .localFolder(let id):
                if let folder = localFolders.first(where: { $0.id == id }) { names.insert(folder.name) }
            case .cloudStore(let id, let path):
                if let store = cloudStores.first(where: { $0.id == id }) {
                    names.insert(path.isEmpty ? store.name : "\(store.name)/\(path)")
                }
            }
        }
        return names
    }

    /// False only if running this workflow right now would touch a device
    /// that's already busy in another in-progress run.
    func canRun(_ workflow: Workflow) -> Bool {
        busyDeckNames.isDisjoint(with: targetDeviceNames(for: workflow))
    }

    // MARK: - System log
    // General activity log for things that aren't tied to a specific
    // workflow run — remote control / OSC commands, scheduler activity,
    // and the like. A workflow run's own progress goes through its
    // `WorkflowRunSession` instead (see below).
    @Published var systemLog: [String] = []

    func log(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        systemLog.append("[\(ts)] \(message)")
        if systemLog.count > 200 {
            systemLog.removeFirst(systemLog.count - 200)
        }
    }


    init() {
        userRole           = load(UserRole.self,             key: "userRole")           ?? .admin
        hyperDecks         = load([HyperDeck].self,          key: "hyperDecks")         ?? []
        cloudStores        = load([CloudStore].self,         key: "cloudStores")        ?? []
        localFolders       = load([LocalFolder].self,        key: "localFolders")       ?? []
        syncLocation       = load(SyncLocation.self,         key: "syncLocation")       ?? SyncLocation()
        workflows                  = load([Workflow].self,                  key: "workflows")                  ?? []
        workflowRunHistory         = load([WorkflowRun].self,               key: "workflowRunHistory")         ?? []
        emailNotificationSettings  = load(EmailNotificationSettings.self,   key: "emailNotificationSettings")  ?? EmailNotificationSettings()
        remoteControlSettings     = load(RemoteControlSettings.self, key: "remoteControlSettings") ?? RemoteControlSettings()
        remoteMappings            = load([RemoteMapping].self,      key: "remoteMappings")         ?? []
        alertSettings             = load(AlertSettings.self,        key: "alertSettings")          ?? AlertSettings()
    }

    // MARK: - HyperDeck CRUD
    func addDeck(_ deck: HyperDeck) {
        var d = deck; d.sortOrder = hyperDecks.count
        hyperDecks.append(d)
    }
    func updateDeck(_ deck: HyperDeck) {
        guard let i = hyperDecks.firstIndex(where: { $0.id == deck.id }) else { return }
        hyperDecks[i] = deck
    }
    func deleteDeck(id: UUID) { hyperDecks.removeAll { $0.id == id } }
    func moveDeck(from: IndexSet, to: Int) {
        hyperDecks.move(fromOffsets: from, toOffset: to)
        for i in hyperDecks.indices { hyperDecks[i].sortOrder = i }
    }

    // MARK: - Cloud Store CRUD
    func addCloudStore(_ store: CloudStore) {
        var s = store; s.sortOrder = cloudStores.count
        cloudStores.append(s)
    }
    func updateCloudStore(_ store: CloudStore) {
        guard let i = cloudStores.firstIndex(where: { $0.id == store.id }) else { return }
        cloudStores[i] = store
    }
    func deleteCloudStore(id: UUID) { cloudStores.removeAll { $0.id == id } }
    func moveCloudStore(from: IndexSet, to: Int) {
        cloudStores.move(fromOffsets: from, toOffset: to)
        for i in cloudStores.indices { cloudStores[i].sortOrder = i }
    }

    // MARK: - Local Folder CRUD
    func addLocalFolder(_ folder: LocalFolder) {
        var f = folder; f.sortOrder = localFolders.count
        localFolders.append(f)
    }
    func updateLocalFolder(_ folder: LocalFolder) {
        guard let i = localFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        localFolders[i] = folder
    }
    func deleteLocalFolder(id: UUID) { localFolders.removeAll { $0.id == id } }
    func moveLocalFolder(from: IndexSet, to: Int) {
        localFolders.move(fromOffsets: from, toOffset: to)
        for i in localFolders.indices { localFolders[i].sortOrder = i }
    }

    // MARK: - Workflow CRUD
    func addWorkflow(_ workflow: Workflow) {
        var w = workflow; w.sortOrder = workflows.count
        workflows.append(w)
    }
    func updateWorkflow(_ workflow: Workflow) {
        guard let i = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        workflows[i] = workflow
    }
    func deleteWorkflow(id: UUID) { workflows.removeAll { $0.id == id } }
    func duplicateWorkflow(id: UUID) {
        guard let original = workflows.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.name) Copy"
        for i in copy.triggers.indices { copy.triggers[i].isEnabled = false }
        addWorkflow(copy)
    }
    func moveWorkflow(from: IndexSet, to: Int) {
        workflows.move(fromOffsets: from, toOffset: to)
        for i in workflows.indices { workflows[i].sortOrder = i }
    }

    // MARK: - Remote Mapping CRUD
    func addRemoteMapping(_ mapping: RemoteMapping) {
        var m = mapping; m.sortOrder = remoteMappings.count
        remoteMappings.append(m)
    }
    func updateRemoteMapping(_ mapping: RemoteMapping) {
        guard let i = remoteMappings.firstIndex(where: { $0.id == mapping.id }) else { return }
        remoteMappings[i] = mapping
    }
    func deleteRemoteMapping(id: UUID) { remoteMappings.removeAll { $0.id == id } }
    func moveRemoteMapping(from: IndexSet, to: Int) {
        remoteMappings.move(fromOffsets: from, toOffset: to)
        for i in remoteMappings.indices { remoteMappings[i].sortOrder = i }
    }

    // MARK: - Run lifecycle
    /// Starts tracking a new run, clearing out any old finished session for
    /// this same workflow first so its previous results don't linger
    /// alongside the new ones.
    func beginRun(for workflow: Workflow, deckNames: Set<String>) -> WorkflowRunSession {
        activeRuns.removeAll { $0.workflow.id == workflow.id && $0.isFinished }
        let session = WorkflowRunSession(workflow: workflow, deckNames: deckNames)
        activeRuns.append(session)
        return session
    }

    /// Marks a run finished. A session with an unresolved mount error or
    /// failed tasks stays visible (so the user can retry or dismiss it);
    /// a fully clean run is removed immediately since there's nothing left
    /// to show for it.
    func finish(_ session: WorkflowRunSession) {
        session.isFinished = true
        if session.mountError == nil && session.failedTasks.isEmpty {
            activeRuns.removeAll { $0.id == session.id }
        }
        // The shared default sync destination's resolved mount path is
        // cached globally — only clear it once every run that might be
        // relying on it has finished, so a still-running sibling doesn't
        // lose its resolved path out from under it.
        if !activeRuns.contains(where: { !$0.isFinished }) {
            syncLocation.resolvedMountPath = nil
        }
    }

    /// Removes a finished session the user has acknowledged (e.g. dismissed
    /// a mount-error banner, or retried its failed tasks to completion).
    func dismiss(_ session: WorkflowRunSession) {
        activeRuns.removeAll { $0.id == session.id }
    }

    /// Drops any finished session that no longer has anything worth
    /// showing — called after retrying failed tasks in place.
    func pruneCleanSessions() {
        activeRuns.removeAll { $0.isFinished && $0.mountError == nil && $0.failedTasks.isEmpty }
    }

    // MARK: - Backup Import
    /// Upserts everything in an imported backup by `id` — a record that
    /// matches an existing one (e.g. re-importing the same file, or a file
    /// exported from this same app) replaces it in place; anything new is
    /// appended. Returns how many devices and workflows were touched, for
    /// the confirmation shown to the user.
    @discardableResult
    func importBackup(_ result: BackupCSVService.ImportResult) -> (devices: Int, workflows: Int) {
        func upsert<T: Identifiable>(_ items: [T], into list: inout [T]) {
            for item in items {
                if let i = list.firstIndex(where: { $0.id == item.id }) {
                    list[i] = item
                } else {
                    list.append(item)
                }
            }
        }

        upsert(result.hyperDecks, into: &hyperDecks)
        upsert(result.cloudStores, into: &cloudStores)
        upsert(result.localFolders, into: &localFolders)
        upsert(result.workflows, into: &workflows)

        let deviceCount = result.hyperDecks.count + result.cloudStores.count + result.localFolders.count
        return (deviceCount, result.workflows.count)
    }

    // MARK: - Persistence
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

}
