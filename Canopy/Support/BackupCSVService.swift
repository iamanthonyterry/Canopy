import Foundation

// MARK: - Backup CSV Service
// Exports/imports Workflows + Device Settings (HyperDecks, Cloud Stores,
// Local Folders) as a single CSV file, so they can be backed up or copied
// to another machine. One row per device or workflow; a leading `type`
// column tells each row apart. Nested data (a workflow's steps and
// triggers) is stored as a JSON string inside its own CSV cell rather than
// flattened into columns, since CSV has no native way to express that
// structure — quoting handles the embedded commas/quotes just fine.
//
// Every row carries the record's original `id`. That's what lets a
// workflow's step data (e.g. a Sync step's `cloudStoreID`) keep pointing at
// the right device after a round trip: import upserts by id rather than by
// name, so re-importing the same file — or a file exported from this same
// app — reproduces the exact same references instead of silently breaking
// them. `targetDeviceNames` is exported purely so the file reads sensibly
// if opened in a spreadsheet; only `targetDeviceIDs` is used on import.
enum BackupCSVService {

    // MARK: - Row kinds

    private enum RowType: String {
        case hyperDeck, cloudStore, localFolder, workflow
    }

    private static let columns = [
        "id", "type", "name", "ipAddress", "remotePath", "volumeName", "path",
        "username", "password", "capacityGB", "targetDeviceNames", "targetDeviceIDs", "targets",
        "triggers", "steps", "sortOrder", "kind"
    ]

    // MARK: - Export

    static func export(
        hyperDecks: [HyperDeck],
        cloudStores: [CloudStore],
        localFolders: [LocalFolder],
        workflows: [Workflow],
        includeCredentials: Bool
    ) -> String {
        var rows: [[String]] = [columns]

        for deck in hyperDecks {
            rows.append(row(
                id: deck.id, type: .hyperDeck, name: deck.name, ipAddress: deck.ipAddress,
                remotePath: deck.remotePath,
                username: includeCredentials ? deck.username : "",
                password: includeCredentials ? deck.password : "",
                capacityGB: deck.capacityGB.map { String($0) } ?? "",
                sortOrder: deck.sortOrder
            ))
        }

        for store in cloudStores {
            rows.append(row(
                id: store.id, type: .cloudStore, name: store.name, ipAddress: store.ipAddress,
                volumeName: store.volumeName,
                username: includeCredentials ? store.username : "",
                password: includeCredentials ? store.password : "",
                sortOrder: store.sortOrder, kind: store.kind.rawValue
            ))
        }

        for folder in localFolders {
            rows.append(row(id: folder.id, type: .localFolder, name: folder.name, path: folder.path, sortOrder: folder.sortOrder))
        }

        let deckNamesByID = Dictionary(uniqueKeysWithValues: hyperDecks.map { ($0.id, $0.name) })
        let folderNamesByID = Dictionary(uniqueKeysWithValues: localFolders.map { ($0.id, $0.name) })
        let storeNamesByID = Dictionary(uniqueKeysWithValues: cloudStores.map { ($0.id, $0.name) })
        let encoder = JSONEncoder()
        for workflow in workflows {
            let targetNames = workflow.targets.compactMap { target -> String? in
                switch target {
                case .hyperDeck(let id):   return deckNamesByID[id]
                case .localFolder(let id): return folderNamesByID[id]
                case .cloudStore(let id, let path):
                    guard let storeName = storeNamesByID[id] else { return nil }
                    return path.isEmpty ? storeName : "\(storeName)/\(path)"
                }
            }
            // Legacy column, kept only so an older app version reading this
            // file still sees a HyperDeck-only target list.
            let legacyDeckIDs = workflow.targets.compactMap { target -> UUID? in
                if case .hyperDeck(let id) = target { return id }
                return nil
            }
            let targetsJSON = (try? encoder.encode(workflow.targets)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let triggersJSON = (try? encoder.encode(workflow.triggers)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let stepsJSON = (try? encoder.encode(workflow.steps)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            rows.append(row(
                id: workflow.id, type: .workflow, name: workflow.name,
                targetDeviceNames: targetNames.joined(separator: ", "),
                targetDeviceIDs: legacyDeckIDs.map(\.uuidString).joined(separator: ","),
                targets: targetsJSON,
                triggers: triggersJSON, steps: stepsJSON, sortOrder: workflow.sortOrder
            ))
        }

        return rows.map(encodeCSVRow).joined(separator: "\r\n") + "\r\n"
    }

    private static func row(
        id: UUID, type: RowType, name: String = "", ipAddress: String = "", remotePath: String = "",
        volumeName: String = "", path: String = "", username: String = "", password: String = "",
        capacityGB: String = "", targetDeviceNames: String = "", targetDeviceIDs: String = "", targets: String = "",
        triggers: String = "", steps: String = "", sortOrder: Int = 0, kind: String = ""
    ) -> [String] {
        [id.uuidString, type.rawValue, name, ipAddress, remotePath, volumeName, path, username, password,
         capacityGB, targetDeviceNames, targetDeviceIDs, targets, triggers, steps, String(sortOrder), kind]
    }

    // MARK: - Import

    struct ImportResult {
        var hyperDecks: [HyperDeck] = []
        var cloudStores: [CloudStore] = []
        var localFolders: [LocalFolder] = []
        var workflows: [Workflow] = []
    }

    enum ImportError: LocalizedError {
        case emptyFile
        case missingHeader

        var errorDescription: String? {
            switch self {
            case .emptyFile:     return "The file is empty."
            case .missingHeader: return "This doesn't look like a Canopy backup CSV — the header row is missing or unrecognized."
            }
        }
    }

    static func importCSV(_ text: String) throws -> ImportResult {
        let allRows = decodeCSV(text)
        guard !allRows.isEmpty else { throw ImportError.emptyFile }
        guard let header = allRows.first, header.contains("type") else { throw ImportError.missingHeader }

        let colIndex = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        func field(_ row: [String], _ name: String) -> String {
            guard let i = colIndex[name], i < row.count else { return "" }
            return row[i]
        }

        var result = ImportResult()
        let decoder = JSONDecoder()

        for row in allRows.dropFirst() where !row.isEmpty {
            guard let type = RowType(rawValue: field(row, "type")) else { continue }
            let id = UUID(uuidString: field(row, "id")) ?? UUID()
            let sortOrder = Int(field(row, "sortOrder")) ?? 0

            switch type {
            case .hyperDeck:
                result.hyperDecks.append(HyperDeck(
                    id: id, name: field(row, "name"), ipAddress: field(row, "ipAddress"),
                    remotePath: field(row, "remotePath"), username: field(row, "username"),
                    password: field(row, "password"), sortOrder: sortOrder,
                    capacityGB: Double(field(row, "capacityGB"))
                ))
            case .cloudStore:
                let kind = CloudStore.Kind(rawValue: field(row, "kind")) ?? .blackmagicCloudStore
                result.cloudStores.append(CloudStore(
                    id: id, name: field(row, "name"), ipAddress: field(row, "ipAddress"),
                    volumeName: field(row, "volumeName"), username: field(row, "username"),
                    password: field(row, "password"), sortOrder: sortOrder, kind: kind
                ))
            case .localFolder:
                result.localFolders.append(LocalFolder(id: id, name: field(row, "name"), path: field(row, "path"), sortOrder: sortOrder))
            case .workflow:
                let targetsData = Data(field(row, "targets").utf8)
                let targets: [WorkflowTarget]
                if let decoded = try? decoder.decode([WorkflowTarget].self, from: targetsData), !decoded.isEmpty {
                    targets = decoded
                } else {
                    // Older backup files only had a HyperDeck-only targetDeviceIDs column.
                    targets = field(row, "targetDeviceIDs")
                        .split(separator: ",")
                        .compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
                        .map { .hyperDeck($0) }
                }

                let triggersData = Data(field(row, "triggers").utf8)
                let stepsData = Data(field(row, "steps").utf8)
                let triggers = (try? decoder.decode([ScheduleSettings].self, from: triggersData)) ?? []
                let steps = (try? decoder.decode([WorkflowStep].self, from: stepsData)) ?? []

                result.workflows.append(Workflow(
                    id: id, name: field(row, "name"), steps: steps, targets: targets,
                    triggers: triggers, sortOrder: sortOrder
                ))
            }
        }

        return result
    }

    // MARK: - RFC 4180-ish CSV encode/decode
    // Minimal but correct: quotes any field containing a comma, quote, or
    // newline, doubling embedded quotes. That's all these rows ever need —
    // the nested JSON cells are the only fields likely to contain commas.

    private static func encodeCSVRow(_ fields: [String]) -> String {
        fields.map(encodeCSVField).joined(separator: ",")
    }

    private static func encodeCSVField(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // Walks Unicode scalars rather than Characters — Swift's `Character`
    // is an extended grapheme cluster, and "\r\n" collapses into a single
    // Character that matches neither `"\r"` nor `"\n"`, which would merge
    // every row in the file into one.
    private static func decodeCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let ch = scalars[i]
            i += 1
            if inQuotes {
                if ch == "\"" {
                    if i < scalars.count && scalars[i] == "\"" {
                        field.unicodeScalars.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                case "\r":
                    if i < scalars.count && scalars[i] == "\n" { i += 1 }
                    row.append(field); field = ""
                    rows.append(row); row = []
                default:
                    field.unicodeScalars.append(ch)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}
