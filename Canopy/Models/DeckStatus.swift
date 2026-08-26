import Foundation

// MARK: - Deck Status
enum DeckStatus: String, Codable {
    case unknown, online, offline, unauthorized, pathNotFound, noMedia, syncing, transcoding
}

// MARK: - HyperDeck
struct HyperDeck: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var ipAddress: String
    var remotePath: String
    var username: String = ""
    var password: String = ""
    var sortOrder: Int = 0

    /// Capacity of the deck's installed media, in gigabytes. The HyperDeck
    /// Ethernet protocol has no command that reports raw disk capacity (only
    /// an estimated recording-time-remaining figure), so this is entered by
    /// the user and used purely to show a used/total storage indicator.
    var capacityGB: Double? = nil
}

// MARK: - Blackmagic Cloud Store
struct CloudStore: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var ipAddress: String
    var volumeName: String = ""
    var username: String = ""
    var password: String = ""
    var sortOrder: Int = 0
}

// MARK: - Local Folder / Drive
// A folder already reachable on this Mac's filesystem — an internal drive,
// a directly-attached external drive, or a share already mounted some other
// way — browsable without any network address or mount step.
struct LocalFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var sortOrder: Int = 0

    var exists: Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return ok && isDir.boolValue
    }
}

// MARK: - Sync Destination
struct SyncLocation: Codable {
    var ipAddress: String = ""
    var volumeName: String = ""
    var username: String = ""
    var password: String = ""
    var basePath: String = "ISO Records"

    /// Resolved at runtime by SMBService after mounting — NOT persisted.
    var resolvedMountPath: String? = nil

    enum CodingKeys: String, CodingKey {
        case ipAddress, volumeName, username, password, basePath
    }

    var mountPath: String { resolvedMountPath ?? "/Volumes/\(volumeName)" }
    var recordsPath: String { "\(mountPath)/\(basePath)" }
}

// MARK: - Conversion Settings
struct ConversionSettings: Codable {
    var preset: FFmpegPreset = .fast
    var maxParallelConversions: Int = 2
    var retentionDays: Int = 30

    // Legacy fields — kept for Codable compatibility with existing saved data
    var crf: Int = 23
    var audioBitrate: String = "128k"

    enum FFmpegPreset: String, Codable, CaseIterable {
        case ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow
        var displayName: String {
            switch self {
            case .ultrafast: return "Fast"
            case .superfast: return "Fast+"
            case .veryfast:  return "Balanced"
            case .faster:    return "Balanced+"
            case .fast:      return "Quality"
            case .medium:    return "High Quality"
            case .slow, .slower, .veryslow: return "Best Quality"
            }
        }
        var description: String {
            switch self {
            case .ultrafast, .superfast: return "1080p export, fastest encode"
            case .veryfast, .faster:     return "1080p export, good balance"
            case .fast:                  return "Full-resolution, hardware-accelerated"
            case .medium, .slow, .slower, .veryslow: return "Best quality, matches source resolution"
            }
        }
    }
}

// MARK: - Per-file sync task (live, in-memory only)
struct SyncTask: Identifiable {
    var id = UUID()
    var fileName: String
    var deckName: String
    var phase: Phase = .queued
    var syncProgress: Double = 0
    var convertProgress: Double = 0
    var errorMessage: String? = nil
    /// The exact folder this task synced to — carried on the task itself
    /// (rather than re-resolved from the deck or workflow) so a retry lands
    /// in the same place even if the originating Sync step's destination is
    /// a dynamically-named Create Folder step, or has since been edited.
    var destDir: URL
    /// Which cloud store `destDir` lives on, if any — used only to make
    /// sure that store is (re)mounted before a retry writes into destDir.
    var cloudStoreID: UUID? = nil

    enum Phase: String {
        case queued, downloading, converting, done, error
        var label: String { rawValue.capitalized }
    }

    var overallProgress: Double {
        switch phase {
        case .queued:      return 0
        case .downloading: return syncProgress * 0.5
        case .converting:  return 0.5 + convertProgress * 0.5
        case .done:        return 1.0
        case .error:       return 0
        }
    }
}

// MARK: - Schedule Settings

enum ScheduleMode: String, Codable, CaseIterable, Identifiable {
    case daily
    case oneTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily:   return "Daily"
        case .oneTime: return "One Time"
        }
    }
}

// Matches Calendar's `.weekday` component: 1 = Sunday ... 7 = Saturday.
enum Weekday: Int, Codable, CaseIterable, Identifiable, Hashable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    var id: Int { rawValue }

    var shortLabel: String {
        switch self {
        case .sunday:    return "Su"
        case .monday:    return "Mo"
        case .tuesday:   return "Tu"
        case .wednesday: return "We"
        case .thursday:  return "Th"
        case .friday:    return "Fr"
        case .saturday:  return "Sa"
        }
    }

    var fullLabel: String {
        switch self {
        case .sunday:    return "Sunday"
        case .monday:    return "Monday"
        case .tuesday:   return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday:  return "Thursday"
        case .friday:    return "Friday"
        case .saturday:  return "Saturday"
        }
    }
}

struct ScheduleSettings: Codable, Hashable, Identifiable {
    /// Not persisted — regenerated on every decode. Only used for SwiftUI
    /// identity and to track which trigger fired during a scheduler tick,
    /// so old saved workflows (encoded before `id` existed) still decode.
    var id = UUID()

    var isEnabled: Bool = false
    var mode: ScheduleMode = .daily

    // Daily mode
    var hour: Int = 2
    var minute: Int = 0
    var repeatDaily: Bool = true
    /// Which days of the week this recurring schedule runs on. Empty means
    /// "every day" — kept empty by default so existing workflows behave the
    /// same as before this option existed.
    var selectedWeekdays: Set<Weekday> = []

    // One-time mode — a specific calendar date + time.
    var oneTimeDate: Date = Date().addingTimeInterval(3600)

    var displayTime: String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", h, minute, ampm)
    }

    /// The days this schedule is actually active on — an empty selection is
    /// treated as "every day."
    var activeWeekdays: Set<Weekday> {
        selectedWeekdays.isEmpty ? Set(Weekday.allCases) : selectedWeekdays
    }

    var displayWeekdays: String {
        guard !selectedWeekdays.isEmpty, selectedWeekdays.count < 7 else { return "Every day" }
        return Weekday.allCases
            .filter { selectedWeekdays.contains($0) }
            .map(\.shortLabel)
            .joined(separator: ", ")
    }

    static let oneTimeDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var displayOneTimeDate: String {
        Self.oneTimeDateFormatter.string(from: oneTimeDate)
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, mode, hour, minute, repeatDaily, selectedWeekdays, oneTimeDate
    }
}
