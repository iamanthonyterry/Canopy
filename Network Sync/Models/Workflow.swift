import Foundation
import SwiftUI

// MARK: - Step Kind
// The catalog of step types users can drag into a workflow.
enum StepKind: String, Codable, CaseIterable, Identifiable {
    case record, stopRecord, sync, convert, rename, format, cleanup, notify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record:     return "Record"
        case .stopRecord: return "Stop Record"
        case .sync:       return "Sync"
        case .convert:    return "Convert"
        case .rename:     return "Rename"
        case .format:     return "Format Drive"
        case .cleanup:    return "Cleanup"
        case .notify:     return "Notification"
        case .record:  return "Record"
        case .wait:    return "Wait"
        case .sync:    return "Sync"
        case .convert: return "Convert"
        case .rename:  return "Rename"
        case .format:  return "Format Drive"
        case .cleanup: return "Cleanup"
        case .notify:  return "Notification"
        }
    }

    var subtitle: String {
        switch self {
        case .record:     return "Start recording on the device"
        case .stopRecord: return "Stop recording on the device"
        case .sync:       return "Download new files from the device"
        case .convert:    return "Transcode files to MP4"
        case .rename:     return "Rename files using a pattern"
        case .format:     return "Permanently erase the device's drive"
        case .cleanup:    return "Delete files older than N days in the destination folder"
        case .notify:     return "Send an email"
        case .record:  return "Start recording on the device"
        case .wait:    return "Pause before moving to the next step"
        case .sync:    return "Download new files from the device"
        case .convert: return "Transcode files to MP4"
        case .rename:  return "Rename files using a pattern"
        case .format:  return "Permanently erase the device's drive"
        case .cleanup: return "Delete files older than N days in the destination folder"
        case .notify:  return "Send an email"
        }
    }

    var icon: String {
        switch self {
        case .record:     return "record.circle"
        case .stopRecord: return "stop.circle"
        case .sync:       return "arrow.down.circle"
        case .convert:    return "film.stack"
        case .rename:     return "textformat"
        case .format:     return "externaldrive.badge.xmark"
        case .cleanup:    return "trash"
        case .notify:     return "envelope"
        case .record:  return "record.circle"
        case .wait:    return "hourglass"
        case .sync:    return "arrow.down.circle"
        case .convert: return "film.stack"
        case .rename:  return "textformat"
        case .format:  return "externaldrive.badge.xmark"
        case .cleanup: return "trash"
        case .notify:  return "envelope"
        }
    }

    var color: Color {
        switch self {
        case .record:     return .red
        case .stopRecord: return .gray
        case .sync:       return .blue
        case .convert:    return .orange
        case .rename:     return .purple
        case .format:     return .red
        case .cleanup:    return .gray
        case .notify:     return .teal
        case .record:  return .red
        case .wait:    return .indigo
        case .sync:    return .blue
        case .convert: return .orange
        case .rename:  return .purple
        case .format:  return .red
        case .cleanup: return .gray
        case .notify:  return .teal
        }
    }
}

// MARK: - Wait Duration Helpers

/// Unit used by the wait step's editor UI — stored internally as minutes.
enum WaitUnit: String, CaseIterable, Identifiable {
    case minutes, hours

    var id: String { rawValue }
    var label: String { self == .minutes ? "Minutes" : "Hours" }
}

enum WaitDurationFormatter {
    /// Turns a minute count into a friendly string, e.g. "1 hour 30 minutes".
    static func string(forMinutes totalMinutes: Int) -> String {
        guard totalMinutes > 0 else { return "0 minutes" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Step Action
// Each case carries only the configuration that step needs.
enum StepAction: Hashable {
    case record(stopAfterMinutes: Int?)
    case stopRecord
    case wait(minutes: Int)
    case sync
    case convert(preset: ConversionSettings.FFmpegPreset, deleteOriginal: Bool)
    case rename(pattern: String)
    case format
    case cleanup(retentionDays: Int)
    case notify(header: String, message: String, recipients: [NotificationRecipient], sendPerDrive: Bool)

    var kind: StepKind {
        switch self {
        case .record:     return .record
        case .stopRecord: return .stopRecord
        case .sync:       return .sync
        case .convert:    return .convert
        case .rename:     return .rename
        case .format:     return .format
        case .cleanup:    return .cleanup
        case .notify:     return .notify
        case .record:   return .record
        case .wait:     return .wait
        case .sync:     return .sync
        case .convert:  return .convert
        case .rename:   return .rename
        case .format:   return .format
        case .cleanup:  return .cleanup
        case .notify:   return .notify
        }
    }

    static func defaultAction(for kind: StepKind) -> StepAction {
        switch kind {
        case .record:     return .record(stopAfterMinutes: nil)
        case .stopRecord: return .stopRecord
        case .sync:       return .sync
        case .convert:    return .convert(preset: .fast, deleteOriginal: true)
        case .rename:     return .rename(pattern: "{device}_{date}_{index}")
        case .format:     return .format
        case .cleanup:    return .cleanup(retentionDays: 30)
        case .notify:     return .notify(header: "Workflow update", message: "", recipients: [], sendPerDrive: true)
        case .record:  return .record(stopAfterMinutes: nil)
        case .wait:    return .wait(minutes: 60)
        case .sync:    return .sync
        case .convert: return .convert(preset: .fast, deleteOriginal: true)
        case .rename:  return .rename(pattern: "{device}_{date}_{index}")
        case .format:  return .format
        case .cleanup: return .cleanup(retentionDays: 30)
        case .notify:  return .notify(header: "Workflow update", message: "", recipients: [], sendPerDrive: true)
        }
    }

    /// One-line summary shown under the step title in the editor.
    var summary: String {
        switch self {
        case .record(let stopAfterMinutes):
            if let minutes = stopAfterMinutes {
                return "Records, then stops after \(minutes) minute\(minutes == 1 ? "" : "s")"
            }
            return "Starts recording and continues to the next step"
        case .stopRecord:
            return "Stops recording on the device"
        case .wait(let minutes):
            return "Waits \(WaitDurationFormatter.string(forMinutes: minutes)) before continuing"
        case .sync:
            return "Downloads any new .mov files"
        case .convert(let preset, let deleteOriginal):
            return "\(preset.displayName) preset" + (deleteOriginal ? " · deletes original" : " · keeps original")
        case .rename(let pattern):
            return "Pattern: \(pattern)"
        case .format:
            return "Erases the device's drive — cannot be undone"
        case .cleanup(let days):
            return "Deletes files older than \(days) day\(days == 1 ? "" : "s") in the destination folder"
        case .notify(let header, _, let recipients, let sendPerDrive):
            let who = recipients.isEmpty ? "no recipients set" : "\(recipients.count) recipient\(recipients.count == 1 ? "" : "s")"
            let mode = sendPerDrive ? "per drive" : "entire workflow"
            return "\"\(header)\" → \(who) (\(mode))"
        }
    }
}

// MARK: - StepAction Codable Implementation
extension StepAction: Codable {
    enum CodingKeys: String, CodingKey {
        case record, stopRecord, sync, convert, rename, format, cleanup, notify
        case record, wait, sync, convert, rename, format, cleanup, notify
    }

    enum RecordKeys: String, CodingKey {
        case stopAfterMinutes
    }

    enum WaitKeys: String, CodingKey {
        case minutes
    }

    enum ConvertKeys: String, CodingKey {
        case preset, deleteOriginal
    }

    enum RenameKeys: String, CodingKey {
        case pattern
    }

    enum CleanupKeys: String, CodingKey {
        case retentionDays
    }

    enum NotifyKeys: String, CodingKey {
        case header, message, recipients, sendPerDrive
    }

    private enum DummyKeys: CodingKey {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.record) {
            let nested = try container.nestedContainer(keyedBy: RecordKeys.self, forKey: .record)
            let stop = try nested.decodeIfPresent(Int.self, forKey: .stopAfterMinutes)
            self = .record(stopAfterMinutes: stop)
        } else if container.contains(.stopRecord) {
            self = .stopRecord
        } else if container.contains(.wait) {
            let nested = try container.nestedContainer(keyedBy: WaitKeys.self, forKey: .wait)
            let minutes = try nested.decode(Int.self, forKey: .minutes)
            self = .wait(minutes: minutes)
        } else if container.contains(.sync) {
            self = .sync
        } else if container.contains(.convert) {
            let nested = try container.nestedContainer(keyedBy: ConvertKeys.self, forKey: .convert)
            let preset = try nested.decode(ConversionSettings.FFmpegPreset.self, forKey: .preset)
            let deleteOriginal = try nested.decode(Bool.self, forKey: .deleteOriginal)
            self = .convert(preset: preset, deleteOriginal: deleteOriginal)
        } else if container.contains(.rename) {
            let nested = try container.nestedContainer(keyedBy: RenameKeys.self, forKey: .rename)
            let pattern = try nested.decode(String.self, forKey: .pattern)
            self = .rename(pattern: pattern)
        } else if container.contains(.format) {
            self = .format
        } else if container.contains(.cleanup) {
            let nested = try container.nestedContainer(keyedBy: CleanupKeys.self, forKey: .cleanup)
            let days = try nested.decode(Int.self, forKey: .retentionDays)
            self = .cleanup(retentionDays: days)
        } else if container.contains(.notify) {
            let nested = try container.nestedContainer(keyedBy: NotifyKeys.self, forKey: .notify)
            let header = try nested.decode(String.self, forKey: .header)
            let message = try nested.decode(String.self, forKey: .message)
            let recipients = try nested.decode([NotificationRecipient].self, forKey: .recipients)
            let sendPerDrive = try nested.decodeIfPresent(Bool.self, forKey: .sendPerDrive) ?? true
            self = .notify(header: header, message: message, recipients: recipients, sendPerDrive: sendPerDrive)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown StepAction case"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .record(let stop):
            var nested = container.nestedContainer(keyedBy: RecordKeys.self, forKey: .record)
            try nested.encode(stop, forKey: .stopAfterMinutes)
        case .stopRecord:
            _ = container.nestedContainer(keyedBy: DummyKeys.self, forKey: .stopRecord)
        case .wait(let minutes):
            var nested = container.nestedContainer(keyedBy: WaitKeys.self, forKey: .wait)
            try nested.encode(minutes, forKey: .minutes)
        case .sync:
            _ = container.nestedContainer(keyedBy: DummyKeys.self, forKey: .sync)
        case .convert(let preset, let deleteOriginal):
            var nested = container.nestedContainer(keyedBy: ConvertKeys.self, forKey: .convert)
            try nested.encode(preset, forKey: .preset)
            try nested.encode(deleteOriginal, forKey: .deleteOriginal)
        case .rename(let pattern):
            var nested = container.nestedContainer(keyedBy: RenameKeys.self, forKey: .rename)
            try nested.encode(pattern, forKey: .pattern)
        case .format:
            _ = container.nestedContainer(keyedBy: DummyKeys.self, forKey: .format)
        case .cleanup(let days):
            var nested = container.nestedContainer(keyedBy: CleanupKeys.self, forKey: .cleanup)
            try nested.encode(days, forKey: .retentionDays)
        case .notify(let header, let message, let recipients, let sendPerDrive):
            var nested = container.nestedContainer(keyedBy: NotifyKeys.self, forKey: .notify)
            try nested.encode(header, forKey: .header)
            try nested.encode(message, forKey: .message)
            try nested.encode(recipients, forKey: .recipients)
            try nested.encode(sendPerDrive, forKey: .sendPerDrive)
        }
    }
}

// MARK: - Rename Tokens
// Supported tokens for the rename step's pattern field.
enum RenameToken: String, CaseIterable {
    case name   = "{name}"
    case device = "{device}"
    case date   = "{date}"
    case time   = "{time}"
    case index  = "{index}"

    var label: String {
        switch self {
        case .name:   return "Original name"
        case .device: return "Device name"
        case .date:   return "Date (yyyyMMdd)"
        case .time:   return "Time (HHmmss)"
        case .index:  return "File number"
        }
    }
}

// MARK: - Rename Pattern Engine
// Single source of truth for turning a pattern + file info into a final
// name — used by both the live preview in the editor and the real run.
enum RenamePatternEngine {
    static func apply(
        pattern: String,
        originalName: String,
        deviceName: String,
        index: Int,
        date: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let dateString = formatter.string(from: date)
        formatter.dateFormat = "HHmmss"
        let timeString = formatter.string(from: date)

        let result = pattern
            .replacingOccurrences(of: RenameToken.name.rawValue, with: originalName)
            .replacingOccurrences(of: RenameToken.device.rawValue, with: deviceName)
            .replacingOccurrences(of: RenameToken.date.rawValue, with: dateString)
            .replacingOccurrences(of: RenameToken.time.rawValue, with: timeString)
            .replacingOccurrences(of: RenameToken.index.rawValue, with: String(format: "%03d", index))

        return result.isEmpty ? originalName : result
    }
}

// MARK: - Workflow Step
struct WorkflowStep: Identifiable, Codable, Hashable {
    var id = UUID()
    var action: StepAction
    var kind: StepKind { action.kind }
}

// MARK: - Workflow
struct Workflow: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var steps: [WorkflowStep] = []
    /// Which HyperDecks this workflow runs against. Empty = all configured decks.
    var targetDeckIDs: [UUID] = []
    /// A workflow can have any number of automatic time triggers (e.g. a
    /// daily run at 2 AM plus a separate one-time run this weekend).
    var triggers: [ScheduleSettings] = []
    var sortOrder: Int = 0

    init(
        id: UUID = UUID(),
        name: String,
        steps: [WorkflowStep] = [],
        targetDeckIDs: [UUID] = [],
        triggers: [ScheduleSettings] = [],
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.steps = steps
        self.targetDeckIDs = targetDeckIDs
        self.triggers = triggers
        self.sortOrder = sortOrder
    }

    var stepsSummary: String {
        steps.isEmpty ? "No steps yet" : steps.map(\.kind.title).joined(separator: "  →  ")
    }

    /// True if any step needs the shared sync destination mounted.
    var needsDestinationMount: Bool {
        steps.contains { ![.format, .record, .stopRecord, .notify].contains($0.kind) }
        steps.contains { $0.kind != .format && $0.kind != .record && $0.kind != .notify && $0.kind != .wait }
    }

    /// True if this workflow will run on its own via at least one enabled trigger.
    var isScheduled: Bool { triggers.contains { $0.isEnabled } }

    var activeTriggers: [ScheduleSettings] { triggers.filter { $0.isEnabled } }

    // MARK: Codable (with migration from the old single `schedule` field)

    enum CodingKeys: String, CodingKey {
        case id, name, steps, targetDeckIDs, triggers, schedule, sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        steps = try container.decodeIfPresent([WorkflowStep].self, forKey: .steps) ?? []
        targetDeckIDs = try container.decodeIfPresent([UUID].self, forKey: .targetDeckIDs) ?? []

        if let decodedTriggers = try container.decodeIfPresent([ScheduleSettings].self, forKey: .triggers) {
            triggers = decodedTriggers
        } else if let legacySchedule = try container.decodeIfPresent(ScheduleSettings.self, forKey: .schedule) {
            // Pre-multi-trigger workflows stored a single `schedule` object.
            triggers = [legacySchedule]
        } else {
            triggers = []
        }

        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(steps, forKey: .steps)
        try container.encode(targetDeckIDs, forKey: .targetDeckIDs)
        try container.encode(triggers, forKey: .triggers)
        try container.encode(sortOrder, forKey: .sortOrder)
    }
}

// MARK: - Workflow Run History (persisted)
struct WorkflowRun: Identifiable, Codable, Hashable {
    var id = UUID()
    var workflowName: String
    var startedAt: Date
    var finishedAt: Date
    var processed: Int
    var errors: Int
    var decksProcessed: [String]
    var log: [String]

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    var durationFormatted: String {
        let s = Int(duration)
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        return String(format: "%d:%02d:%02d", h, m, r)
    }
}
