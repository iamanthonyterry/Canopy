import Foundation
import SwiftUI

// MARK: - Deck Command
// The two transport actions the "Control HyperDeck" step can send.
enum DeckCommand: String, Codable, CaseIterable, Identifiable {
    case start, stop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: return "Start Recording"
        case .stop:  return "Stop Recording"
        }
    }
}

// MARK: - Step Kind
// The catalog of step types users can drag into a workflow.
enum StepKind: String, Codable, CaseIterable, Identifiable {
    case controlDeck, wait, createFolder, sync, convert, rename, transcribe, findClips, queueClips, writeCopy, reframe, format, cleanup, notify, triggerWorkflow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controlDeck:     return "Control HyperDeck"
        case .wait:            return "Wait"
        case .createFolder:    return "Create Folder"
        case .sync:            return "Offload"
        case .convert:         return "Make Proxies"
        case .rename:          return "Rename"
        case .transcribe:      return "Transcribe"
        case .findClips:       return "Find Clips"
        case .queueClips:      return "Queue Clips"
        case .writeCopy:       return "Write Post Copy"
        case .reframe:         return "Resize for Social"
        case .format:          return "Format Drive"
        case .cleanup:         return "Cleanup"
        case .notify:          return "Notification"
        case .triggerWorkflow: return "Trigger Workflow"
        }
    }

    var subtitle: String {
        switch self {
        case .controlDeck:     return "Start or stop recording on the device"
        case .wait:            return "Pause before moving to the next step"
        case .createFolder:    return "Create a new folder, optionally named with today's date"
        case .sync:            return "Offload new clips from the device, optionally verified"
        case .convert:         return "Transcode clips to MP4 proxies"
        case .rename:          return "Rename files using a pattern"
        case .transcribe:      return "Generate a timed transcript for each clip, on this Mac"
        case .findClips:       return "Find moments in long videos that work as short social posts"
        case .queueClips:      return "Add the suggested clips to the Export Queue as trimmed items"
        case .writeCopy:       return "Draft a title, caption and hashtags for each suggested clip"
        case .reframe:         return "Crop clips to a social media size, keeping the main subject in frame"
        case .format:          return "Permanently erase the device's drive"
        case .cleanup:         return "Delete files older than N days in the destination folder"
        case .notify:          return "Send an email"
        case .triggerWorkflow: return "Start another workflow running"
        }
    }

    var icon: String {
        switch self {
        case .controlDeck:     return "record.circle"
        case .wait:            return "hourglass"
        case .createFolder:    return "folder.badge.plus"
        case .sync:            return "arrow.down.circle"
        case .convert:         return "film.stack"
        case .rename:          return "textformat"
        case .transcribe:      return "text.bubble"
        case .findClips:       return "sparkles.rectangle.stack"
        case .queueClips:      return "tray.and.arrow.up"
        case .writeCopy:       return "text.quote"
        case .reframe:         return "rectangle.portrait.crop"
        case .format:          return "externaldrive.badge.xmark"
        case .cleanup:         return "trash"
        case .notify:          return "envelope"
        case .triggerWorkflow: return "arrow.triangle.branch"
        }
    }

    var color: Color {
        switch self {
        case .controlDeck:     return .red
        case .wait:            return .indigo
        case .createFolder:    return .mint
        case .sync:            return .blue
        case .convert:         return .orange
        case .rename:          return .purple
        case .transcribe:      return .pink
        case .findClips:       return .yellow
        case .queueClips:      return .brown
        case .writeCopy:       return .mint
        case .reframe:         return .green
        case .format:          return .red
        case .cleanup:         return .gray
        case .notify:          return .teal
        case .triggerWorkflow: return .cyan
        }
    }
}

// MARK: - Post Copy Platform
/// Where a post is headed, which sets the tone, length and hashtag habits of
/// the copy the Write Post Copy step drafts.
nonisolated enum CopyPlatform: String, Codable, CaseIterable, Identifiable {
    case general, tiktok, instagram, youtube, linkedin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:   return "General"
        case .tiktok:    return "TikTok"
        case .instagram: return "Instagram Reels"
        case .youtube:   return "YouTube Shorts"
        case .linkedin:  return "LinkedIn"
        }
    }

    /// Longest caption the platform comfortably shows, in characters.
    var maxCaptionLength: Int {
        switch self {
        case .general:   return 280
        case .tiktok:    return 150
        case .instagram: return 220
        case .youtube:   return 100
        case .linkedin:  return 400
        }
    }

    var styleGuidance: String {
        switch self {
        case .general:   return "Clear and engaging."
        case .tiktok:    return "Short, punchy and casual, opening with a hook."
        case .instagram: return "Warm and personal, conversational, a little emoji is fine."
        case .youtube:   return "A short, searchable title-style line."
        case .linkedin:  return "Professional but human, with a takeaway."
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

// MARK: - Sync Destination
// Where a workflow's Sync step (and any other step needing a shared
// destination) writes its files. `.createdFolder` points at a Create Folder
// step elsewhere in the same workflow rather than storing a static path,
// since that step's folder name can depend on the date it actually runs.
enum SyncDestination: Hashable, Codable {
    case global
    case cloudStore(id: UUID, path: String)
    case createdFolder(stepID: UUID)

    var cloudStoreIDIfAny: UUID? {
        if case .cloudStore(let id, _) = self { return id }
        return nil
    }
}

// MARK: - Folder Name Engine
// Resolves the optional {date} token in a Create Folder step's name — the
// only dynamic piece a folder name needs, unlike the rename step's richer
// per-file token set.
enum FolderNameEngine {
    static let dateToken = "{date}"

    static func resolve(_ template: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let result = template.replacingOccurrences(of: dateToken, with: formatter.string(from: date))
        return result.isEmpty ? "New Folder" : result
    }
}

// MARK: - Social Format
/// Target frame shapes for the Resize for Social step. All are 1080 px on the
/// short side, which is what Instagram, TikTok, YouTube Shorts and Facebook
/// recommend.
nonisolated enum SocialFormat: String, Codable, CaseIterable, Identifiable {
    case vertical, portrait, square, landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vertical:  return "Vertical 9:16"
        case .portrait:  return "Portrait 4:5"
        case .square:    return "Square 1:1"
        case .landscape: return "Landscape 16:9"
        }
    }

    var detail: String {
        switch self {
        case .vertical:  return "Reels, TikTok, Shorts, Stories"
        case .portrait:  return "Instagram and Facebook feed"
        case .square:    return "Feed posts everywhere"
        case .landscape: return "YouTube, X, LinkedIn"
        }
    }

    var outputSize: CGSize {
        switch self {
        case .vertical:  return CGSize(width: 1080, height: 1920)
        case .portrait:  return CGSize(width: 1080, height: 1350)
        case .square:    return CGSize(width: 1080, height: 1080)
        case .landscape: return CGSize(width: 1920, height: 1080)
        }
    }

    var aspectRatio: CGFloat { outputSize.width / outputSize.height }

    /// Appended to the clip's name: `A001.mov` → `A001_9x16.mp4`.
    var fileSuffix: String {
        switch self {
        case .vertical:  return "9x16"
        case .portrait:  return "4x5"
        case .square:    return "1x1"
        case .landscape: return "16x9"
        }
    }
}

// MARK: - Step Action
// Each case carries only the configuration that step needs.
enum StepAction: Hashable {
    case controlDeck(command: DeckCommand, stopAfterMinutes: Int?)
    case wait(minutes: Int)
    /// `parentPath` is the subfolder within the chosen store (or the global
    /// destination) the new folder is created inside — empty = volume/base
    /// root. `nameTemplate` may contain `FolderNameEngine.dateToken`.
    /// `groupByDevice`, when true, makes each target device write into its
    /// own subfolder (named after the device) inside the created folder,
    /// instead of every device sharing the folder directly.
    case createFolder(cloudStoreID: UUID?, parentPath: String, nameTemplate: String, groupByDevice: Bool = false)
    /// `verify`: after each download, hash the copy and the source with
    /// SHA-256 and compare, and write a `checksums.sha256` manifest.
    case sync(destination: SyncDestination, verify: Bool = false)
    case convert(preset: ConversionSettings.FFmpegPreset, deleteOriginal: Bool, maxParallelJobs: Int, convertInPlace: Bool = false)
    case rename(pattern: String)
    /// Writes a `.transcript.json` sidecar (and optionally an `.srt`) next to
    /// each clip. `skipExisting` leaves clips that already have a transcript alone.
    case transcribe(locale: String, writeSRT: Bool, skipExisting: Bool)
    /// Suggests short-form clips from each video's transcript (transcribing
    /// first if needed) and saves them in a `.clips.json` sidecar.
    /// With `exportFormat` set, each suggested clip is also rendered as a
    /// finished post (cropped to that format, optionally captioned) into a
    /// `Social Posts` folder next to the video.
    case findClips(maxClips: Int, minSeconds: Int, maxSeconds: Int, exportFormat: SocialFormat? = nil, captions: Bool = true)
    /// Adds each video's suggested clips (from a Find Clips step) to the
    /// Export Queue as trimmed items. `minScore` skips weaker suggestions.
    case queueClips(minScore: Int)
    /// Drafts a title, caption and hashtags for each suggested clip, saved
    /// with the clip suggestions.
    case writeCopy(platform: CopyPlatform, hashtagCount: Int)
    /// Writes a cropped MP4 per clip into a `Reframed` folder. With
    /// `followSubject` the crop window tracks people (or the most salient
    /// object) through the shot; otherwise it stays centered.
    case reframe(format: SocialFormat, followSubject: Bool)
    case format
    case cleanup(retentionDays: Int)
    case notify(header: String, message: String, recipients: [NotificationRecipient], sendPerDrive: Bool)
    case triggerWorkflow(workflowID: UUID?, waitForCompletion: Bool)

    var kind: StepKind {
        switch self {
        case .controlDeck:     return .controlDeck
        case .wait:            return .wait
        case .createFolder:    return .createFolder
        case .sync:            return .sync
        case .convert:         return .convert
        case .rename:          return .rename
        case .transcribe:      return .transcribe
        case .findClips:       return .findClips
        case .queueClips:      return .queueClips
        case .writeCopy:       return .writeCopy
        case .reframe:         return .reframe
        case .format:          return .format
        case .cleanup:         return .cleanup
        case .notify:          return .notify
        case .triggerWorkflow: return .triggerWorkflow
        }
    }

    static func defaultAction(for kind: StepKind) -> StepAction {
        switch kind {
        case .controlDeck:     return .controlDeck(command: .start, stopAfterMinutes: nil)
        case .wait:            return .wait(minutes: 60)
        case .createFolder:    return .createFolder(cloudStoreID: nil, parentPath: "", nameTemplate: "New Folder_\(FolderNameEngine.dateToken)", groupByDevice: false)
        case .sync:            return .sync(destination: .global, verify: false)
        case .convert:         return .convert(preset: .fast, deleteOriginal: true, maxParallelJobs: 2, convertInPlace: false)
        case .rename:          return .rename(pattern: "{device}_{date}_{index}")
        case .transcribe:      return .transcribe(locale: Locale.current.identifier, writeSRT: true, skipExisting: true)
        case .findClips:       return .findClips(maxClips: 5, minSeconds: 20, maxSeconds: 60)
        case .queueClips:      return .queueClips(minScore: 0)
        case .writeCopy:       return .writeCopy(platform: .general, hashtagCount: 5)
        case .reframe:         return .reframe(format: .vertical, followSubject: true)
        case .format:          return .format
        case .cleanup:         return .cleanup(retentionDays: 30)
        case .notify:          return .notify(header: "Workflow update", message: "", recipients: [], sendPerDrive: true)
        case .triggerWorkflow: return .triggerWorkflow(workflowID: nil, waitForCompletion: false)
        }
    }

    /// Compact label for overviews like the workflow card's step chain —
    /// shows the actual choice made rather than just the step kind, where
    /// that choice is the interesting part (e.g. "Start Recording" instead
    /// of the generic "Control HyperDeck").
    var shortLabel: String {
        switch self {
        case .controlDeck(let command, _):
            return command.title
        default:
            return kind.title
        }
    }

    /// One-line summary shown under the step title in the editor.
    var summary: String {
        switch self {
        case .controlDeck(let command, let stopAfterMinutes):
            switch command {
            case .start:
                if let minutes = stopAfterMinutes {
                    return "Starts recording, then stops after \(minutes) minute\(minutes == 1 ? "" : "s")"
                }
                return "Starts recording and continues to the next step"
            case .stop:
                return "Stops recording on the device"
            }
        case .wait(let minutes):
            return "Waits \(WaitDurationFormatter.string(forMinutes: minutes)) before continuing"
        case .createFolder(let cloudStoreID, let parentPath, let nameTemplate, let groupByDevice):
            let resolved = FolderNameEngine.resolve(nameTemplate)
            let location = cloudStoreID == nil ? "the global destination" : "the selected cloud store"
            let folder = parentPath.isEmpty ? resolved : "\(parentPath)/\(resolved)"
            let grouping = groupByDevice ? " · one subfolder per device" : ""
            return "Creates \"\(folder)\" in \(location)\(grouping)"
        case .sync(let destination, let verify):
            let suffix = verify ? " · verified with SHA-256" : ""
            switch destination {
            case .global:
                return "Downloads any new .mov files to the global destination" + suffix
            case .cloudStore:
                return "Downloads any new .mov files to the selected cloud store" + suffix
            case .createdFolder:
                return "Downloads any new .mov files into the folder created earlier in this workflow" + suffix
            }
        case .convert(let preset, let deleteOriginal, let maxParallelJobs, let convertInPlace):
            return "\(preset.displayName) preset" + (deleteOriginal ? " · deletes original" : " · keeps original") + " · \(maxParallelJobs) parallel" + (convertInPlace ? " · converts in place" : " · saves to a Converted folder")
        case .rename(let pattern):
            return "Pattern: \(pattern)"
        case .transcribe(_, let writeSRT, let skipExisting):
            return "Transcribes on-device" + (writeSRT ? " · also writes .srt" : "") + (skipExisting ? " · skips clips already done" : "")
        case .findClips(let maxClips, let minSeconds, let maxSeconds, let exportFormat, let captions):
            var text = "Suggests up to \(maxClips) clip\(maxClips == 1 ? "" : "s") of \(minSeconds)–\(maxSeconds) seconds per video"
            if let exportFormat {
                text += " · exports \(exportFormat.title) posts" + (captions ? " with captions" : "")
            }
            return text
        case .queueClips(let minScore):
            return minScore > 0
                ? "Adds suggested clips scoring \(minScore)+ to the Export Queue"
                : "Adds every suggested clip to the Export Queue"
        case .writeCopy(let platform, let hashtagCount):
            return "\(platform.title) style · up to \(hashtagCount) hashtag\(hashtagCount == 1 ? "" : "s")"
        case .reframe(let format, let followSubject):
            return "\(format.title) · \(format.detail)" + (followSubject ? " · follows the subject" : " · centered crop")
        case .format:
            return "Erases the device's drive — cannot be undone"
        case .cleanup(let days):
            return "Deletes files older than \(days) day\(days == 1 ? "" : "s") in the destination folder"
        case .notify(let header, _, let recipients, let sendPerDrive):
            let who = recipients.isEmpty ? "no recipients set" : "\(recipients.count) recipient\(recipients.count == 1 ? "" : "s")"
            let mode = sendPerDrive ? "per drive" : "entire workflow"
            return "\"\(header)\" → \(who) (\(mode))"
        case .triggerWorkflow(let workflowID, let waitForCompletion):
            guard workflowID != nil else { return "No workflow selected" }
            return waitForCompletion
                ? "Starts the selected workflow and waits for it to finish"
                : "Starts the selected workflow and continues immediately"
        }
    }
}

// MARK: - StepAction Codable Implementation
extension StepAction: Codable {
    enum CodingKeys: String, CodingKey {
        case controlDeck, record, stopRecord, wait, createFolder, sync, convert, rename, transcribe, findClips, queueClips, writeCopy, reframe, format, cleanup, notify, triggerWorkflow
    }

    enum ControlDeckKeys: String, CodingKey {
        case command, stopAfterMinutes
    }

    // Legacy keys, kept only so workflows saved before the two record
    // steps were merged still decode correctly.
    enum RecordKeys: String, CodingKey {
        case stopAfterMinutes
    }

    enum WaitKeys: String, CodingKey {
        case minutes
    }

    enum CreateFolderKeys: String, CodingKey {
        case cloudStoreID, parentPath, nameTemplate, groupByDevice
    }

    enum SyncKeys: String, CodingKey {
        case destination, verify
        // Legacy keys, kept only so workflows saved before the Sync step
        // could point at a Create Folder step still decode correctly.
        case cloudStoreID, cloudStorePath
    }

    enum ConvertKeys: String, CodingKey {
        case preset, deleteOriginal, maxParallelJobs, convertInPlace
    }

    enum RenameKeys: String, CodingKey {
        case pattern
    }

    enum TranscribeKeys: String, CodingKey {
        case locale, writeSRT, skipExisting
    }

    enum FindClipsKeys: String, CodingKey {
        case maxClips, minSeconds, maxSeconds, exportFormat, captions
    }

    enum WriteCopyKeys: String, CodingKey {
        case platform, hashtagCount
    }

    enum QueueClipsKeys: String, CodingKey {
        case minScore
    }

    enum ReframeKeys: String, CodingKey {
        case format, followSubject
    }

    enum CleanupKeys: String, CodingKey {
        case retentionDays
    }

    enum NotifyKeys: String, CodingKey {
        case header, message, recipients, sendPerDrive
    }

    enum TriggerWorkflowKeys: String, CodingKey {
        case workflowID, waitForCompletion
    }

    private enum DummyKeys: CodingKey {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.controlDeck) {
            let nested = try container.nestedContainer(keyedBy: ControlDeckKeys.self, forKey: .controlDeck)
            let command = try nested.decode(DeckCommand.self, forKey: .command)
            let stop = try nested.decodeIfPresent(Int.self, forKey: .stopAfterMinutes)
            self = .controlDeck(command: command, stopAfterMinutes: stop)
        } else if container.contains(.record) {
            let nested = try container.nestedContainer(keyedBy: RecordKeys.self, forKey: .record)
            let stop = try nested.decodeIfPresent(Int.self, forKey: .stopAfterMinutes)
            self = .controlDeck(command: .start, stopAfterMinutes: stop)
        } else if container.contains(.stopRecord) {
            self = .controlDeck(command: .stop, stopAfterMinutes: nil)
        } else if container.contains(.wait) {
            let nested = try container.nestedContainer(keyedBy: WaitKeys.self, forKey: .wait)
            let minutes = try nested.decode(Int.self, forKey: .minutes)
            self = .wait(minutes: minutes)
        } else if container.contains(.createFolder) {
            let nested = try container.nestedContainer(keyedBy: CreateFolderKeys.self, forKey: .createFolder)
            let cloudStoreID = try nested.decodeIfPresent(UUID.self, forKey: .cloudStoreID)
            let parentPath = try nested.decodeIfPresent(String.self, forKey: .parentPath) ?? ""
            let nameTemplate = try nested.decode(String.self, forKey: .nameTemplate)
            // Pre-per-device-grouping workflows didn't store this — default to off.
            let groupByDevice = try nested.decodeIfPresent(Bool.self, forKey: .groupByDevice) ?? false
            self = .createFolder(cloudStoreID: cloudStoreID, parentPath: parentPath, nameTemplate: nameTemplate, groupByDevice: groupByDevice)
        } else if container.contains(.sync) {
            let nested = try container.nestedContainer(keyedBy: SyncKeys.self, forKey: .sync)
            let verify = try nested.decodeIfPresent(Bool.self, forKey: .verify) ?? false
            if let destination = try nested.decodeIfPresent(SyncDestination.self, forKey: .destination) {
                self = .sync(destination: destination, verify: verify)
            } else {
                // Workflows saved before the Sync step could point at a Create
                // Folder step stored a plain cloudStoreID/cloudStorePath pair.
                let cloudStoreID = try nested.decodeIfPresent(UUID.self, forKey: .cloudStoreID)
                let cloudStorePath = try nested.decodeIfPresent(String.self, forKey: .cloudStorePath) ?? ""
                if let cloudStoreID {
                    self = .sync(destination: .cloudStore(id: cloudStoreID, path: cloudStorePath), verify: verify)
                } else {
                    self = .sync(destination: .global, verify: verify)
                }
            }
        } else if container.contains(.convert) {
            let nested = try container.nestedContainer(keyedBy: ConvertKeys.self, forKey: .convert)
            let preset = try nested.decode(ConversionSettings.FFmpegPreset.self, forKey: .preset)
            let deleteOriginal = try nested.decode(Bool.self, forKey: .deleteOriginal)
            // Pre-per-step-concurrency workflows didn't store this — default to 2.
            let maxParallelJobs = try nested.decodeIfPresent(Int.self, forKey: .maxParallelJobs) ?? 2
            // Pre-convert-in-place workflows always used a "Converted" subfolder.
            let convertInPlace = try nested.decodeIfPresent(Bool.self, forKey: .convertInPlace) ?? false
            self = .convert(preset: preset, deleteOriginal: deleteOriginal, maxParallelJobs: maxParallelJobs, convertInPlace: convertInPlace)
        } else if container.contains(.rename) {
            let nested = try container.nestedContainer(keyedBy: RenameKeys.self, forKey: .rename)
            let pattern = try nested.decode(String.self, forKey: .pattern)
            self = .rename(pattern: pattern)
        } else if container.contains(.transcribe) {
            let nested = try container.nestedContainer(keyedBy: TranscribeKeys.self, forKey: .transcribe)
            let locale = try nested.decodeIfPresent(String.self, forKey: .locale) ?? Locale.current.identifier
            let writeSRT = try nested.decodeIfPresent(Bool.self, forKey: .writeSRT) ?? true
            let skipExisting = try nested.decodeIfPresent(Bool.self, forKey: .skipExisting) ?? true
            self = .transcribe(locale: locale, writeSRT: writeSRT, skipExisting: skipExisting)
        } else if container.contains(.findClips) {
            let nested = try container.nestedContainer(keyedBy: FindClipsKeys.self, forKey: .findClips)
            let maxClips = try nested.decodeIfPresent(Int.self, forKey: .maxClips) ?? 5
            let minSeconds = try nested.decodeIfPresent(Int.self, forKey: .minSeconds) ?? 20
            let maxSeconds = try nested.decodeIfPresent(Int.self, forKey: .maxSeconds) ?? 60
            let exportFormat = try nested.decodeIfPresent(SocialFormat.self, forKey: .exportFormat)
            let captions = try nested.decodeIfPresent(Bool.self, forKey: .captions) ?? true
            self = .findClips(maxClips: maxClips, minSeconds: minSeconds, maxSeconds: maxSeconds, exportFormat: exportFormat, captions: captions)
        } else if container.contains(.writeCopy) {
            let nested = try container.nestedContainer(keyedBy: WriteCopyKeys.self, forKey: .writeCopy)
            let platform = try nested.decodeIfPresent(CopyPlatform.self, forKey: .platform) ?? .general
            let count = try nested.decodeIfPresent(Int.self, forKey: .hashtagCount) ?? 5
            self = .writeCopy(platform: platform, hashtagCount: count)
        } else if container.contains(.queueClips) {
            let nested = try container.nestedContainer(keyedBy: QueueClipsKeys.self, forKey: .queueClips)
            self = .queueClips(minScore: try nested.decodeIfPresent(Int.self, forKey: .minScore) ?? 0)
        } else if container.contains(.reframe) {
            let nested = try container.nestedContainer(keyedBy: ReframeKeys.self, forKey: .reframe)
            let format = try nested.decodeIfPresent(SocialFormat.self, forKey: .format) ?? .vertical
            let followSubject = try nested.decodeIfPresent(Bool.self, forKey: .followSubject) ?? true
            self = .reframe(format: format, followSubject: followSubject)
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
        } else if container.contains(.triggerWorkflow) {
            let nested = try container.nestedContainer(keyedBy: TriggerWorkflowKeys.self, forKey: .triggerWorkflow)
            let workflowID = try nested.decodeIfPresent(UUID.self, forKey: .workflowID)
            let waitForCompletion = try nested.decodeIfPresent(Bool.self, forKey: .waitForCompletion) ?? false
            self = .triggerWorkflow(workflowID: workflowID, waitForCompletion: waitForCompletion)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown StepAction case"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .controlDeck(let command, let stop):
            var nested = container.nestedContainer(keyedBy: ControlDeckKeys.self, forKey: .controlDeck)
            try nested.encode(command, forKey: .command)
            try nested.encode(stop, forKey: .stopAfterMinutes)
        case .wait(let minutes):
            var nested = container.nestedContainer(keyedBy: WaitKeys.self, forKey: .wait)
            try nested.encode(minutes, forKey: .minutes)
        case .createFolder(let cloudStoreID, let parentPath, let nameTemplate, let groupByDevice):
            var nested = container.nestedContainer(keyedBy: CreateFolderKeys.self, forKey: .createFolder)
            try nested.encode(cloudStoreID, forKey: .cloudStoreID)
            try nested.encode(parentPath, forKey: .parentPath)
            try nested.encode(nameTemplate, forKey: .nameTemplate)
            try nested.encode(groupByDevice, forKey: .groupByDevice)
        case .sync(let destination, let verify):
            var nested = container.nestedContainer(keyedBy: SyncKeys.self, forKey: .sync)
            try nested.encode(destination, forKey: .destination)
            try nested.encode(verify, forKey: .verify)
        case .convert(let preset, let deleteOriginal, let maxParallelJobs, let convertInPlace):
            var nested = container.nestedContainer(keyedBy: ConvertKeys.self, forKey: .convert)
            try nested.encode(preset, forKey: .preset)
            try nested.encode(deleteOriginal, forKey: .deleteOriginal)
            try nested.encode(maxParallelJobs, forKey: .maxParallelJobs)
            try nested.encode(convertInPlace, forKey: .convertInPlace)
        case .rename(let pattern):
            var nested = container.nestedContainer(keyedBy: RenameKeys.self, forKey: .rename)
            try nested.encode(pattern, forKey: .pattern)
        case .transcribe(let locale, let writeSRT, let skipExisting):
            var nested = container.nestedContainer(keyedBy: TranscribeKeys.self, forKey: .transcribe)
            try nested.encode(locale, forKey: .locale)
            try nested.encode(writeSRT, forKey: .writeSRT)
            try nested.encode(skipExisting, forKey: .skipExisting)
        case .findClips(let maxClips, let minSeconds, let maxSeconds, let exportFormat, let captions):
            var nested = container.nestedContainer(keyedBy: FindClipsKeys.self, forKey: .findClips)
            try nested.encode(maxClips, forKey: .maxClips)
            try nested.encode(minSeconds, forKey: .minSeconds)
            try nested.encode(maxSeconds, forKey: .maxSeconds)
            try nested.encodeIfPresent(exportFormat, forKey: .exportFormat)
            try nested.encode(captions, forKey: .captions)
        case .writeCopy(let platform, let hashtagCount):
            var nested = container.nestedContainer(keyedBy: WriteCopyKeys.self, forKey: .writeCopy)
            try nested.encode(platform, forKey: .platform)
            try nested.encode(hashtagCount, forKey: .hashtagCount)
        case .queueClips(let minScore):
            var nested = container.nestedContainer(keyedBy: QueueClipsKeys.self, forKey: .queueClips)
            try nested.encode(minScore, forKey: .minScore)
        case .reframe(let format, let followSubject):
            var nested = container.nestedContainer(keyedBy: ReframeKeys.self, forKey: .reframe)
            try nested.encode(format, forKey: .format)
            try nested.encode(followSubject, forKey: .followSubject)
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
        case .triggerWorkflow(let workflowID, let waitForCompletion):
            var nested = container.nestedContainer(keyedBy: TriggerWorkflowKeys.self, forKey: .triggerWorkflow)
            try nested.encode(workflowID, forKey: .workflowID)
            try nested.encode(waitForCompletion, forKey: .waitForCompletion)
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
    case project = "{project}"
    case cam    = "{cam}"

    var label: String {
        switch self {
        case .name:   return "Original name"
        case .device: return "Device name"
        case .date:   return "Date (yyyyMMdd)"
        case .time:   return "Time (HHmmss)"
        case .index:  return "File number"
        case .project: return "Project / shoot name (Settings ▸ Shoot)"
        case .cam:    return "Camera label for the device (Settings ▸ Shoot)"
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
        date: Date = Date(),
        projectName: String = "",
        cameraLabel: String = ""
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
            .replacingOccurrences(of: RenameToken.project.rawValue, with: fileSafe(projectName))
            .replacingOccurrences(of: RenameToken.cam.rawValue, with: fileSafe(cameraLabel))

        return result.isEmpty ? originalName : result
    }

    /// Keeps user-typed names from introducing path separators.
    static func fileSafe(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Shoot
// Names the production the footage belongs to, and labels each device with
// a camera letter, for the {project} and {cam} rename tokens.
struct ShootProject: Codable, Equatable {
    var name: String = ""
    /// Device name → camera label (e.g. "Stage Left" → "A").
    var cameraLabels: [String: String] = [:]

    func cameraLabel(for deviceName: String) -> String { cameraLabels[deviceName] ?? "" }
}

// MARK: - Workflow Step
struct WorkflowStep: Identifiable, Hashable {
    var id = UUID()
    var action: StepAction
    /// When true, the run pauses right before this step and waits for
    /// someone to confirm it should continue.
    var requiresConfirmation: Bool = false
    var kind: StepKind { action.kind }

    init(id: UUID = UUID(), action: StepAction, requiresConfirmation: Bool = false) {
        self.id = id
        self.action = action
        self.requiresConfirmation = requiresConfirmation
    }
}

extension WorkflowStep: Codable {
    enum CodingKeys: String, CodingKey {
        case id, action, requiresConfirmation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        action = try container.decode(StepAction.self, forKey: .action)
        // Workflows saved before this feature existed won't have this key.
        requiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(action, forKey: .action)
        try container.encode(requiresConfirmation, forKey: .requiresConfirmation)
    }
}

// MARK: - Workflow Target
// Which kind of device a workflow can be pointed at. A Cloud Store target
// names a specific folder within that store (unlike a HyperDeck or Local
// Folder, a Cloud Store isn't a single preconfigured place to run — the
// same store can host any number of different folders across different
// workflows), so the path is stored on the target itself rather than
// looked up from a registered device by id.
enum WorkflowTarget: Hashable, Codable {
    case hyperDeck(UUID)
    case localFolder(UUID)
    case cloudStore(id: UUID, path: String)
}

// MARK: - Workflow
struct Workflow: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var steps: [WorkflowStep] = []
    /// Which devices this workflow runs against. Empty = all configured
    /// HyperDecks and Local Folders.
    var targets: [WorkflowTarget] = []
    /// A workflow can have any number of automatic time triggers (e.g. a
    /// daily run at 2 AM plus a separate one-time run this weekend).
    var triggers: [ScheduleSettings] = []
    var sortOrder: Int = 0

    init(
        id: UUID = UUID(),
        name: String,
        steps: [WorkflowStep] = [],
        targets: [WorkflowTarget] = [],
        triggers: [ScheduleSettings] = [],
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.steps = steps
        self.targets = targets
        self.triggers = triggers
        self.sortOrder = sortOrder
    }

    var stepsSummary: String {
        steps.isEmpty ? "No steps yet" : steps.map { $0.action.shortLabel }.joined(separator: "  →  ")
    }

    /// True if any step needs the shared sync destination mounted.
    var needsDestinationMount: Bool {
        steps.contains { ![.format, .controlDeck, .wait, .notify, .triggerWorkflow].contains($0.kind) }
    }

    /// The destination configured on this workflow's Sync step. Falls back
    /// to the global default if there's no Sync step at all — e.g. a
    /// workflow that only converts/renames files already downloaded by a
    /// previous run.
    var syncDestination: SyncDestination {
        for step in steps {
            if case .sync(let destination, _) = step.action {
                return destination
            }
        }
        return .global
    }

    /// True if this workflow will run on its own via at least one enabled trigger.
    var isScheduled: Bool { triggers.contains { $0.isEnabled } }

    var activeTriggers: [ScheduleSettings] { triggers.filter { $0.isEnabled } }

    // MARK: Codable (with migration from the old single `schedule` field)

    enum CodingKeys: String, CodingKey {
        case id, name, steps, targets, targetDeckIDs, triggers, schedule, sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        steps = try container.decodeIfPresent([WorkflowStep].self, forKey: .steps) ?? []

        if let decodedTargets = try container.decodeIfPresent([WorkflowTarget].self, forKey: .targets) {
            targets = decodedTargets
        } else {
            // Workflows saved before Local Folder targets existed only had a
            // plain list of HyperDeck UUIDs.
            let legacyDeckIDs = try container.decodeIfPresent([UUID].self, forKey: .targetDeckIDs) ?? []
            targets = legacyDeckIDs.map { .hyperDeck($0) }
        }

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
        try container.encode(targets, forKey: .targets)
        try container.encode(triggers, forKey: .triggers)
        try container.encode(sortOrder, forKey: .sortOrder)
    }
}

// MARK: - Workflow Run History (persisted)
/// One file's outcome in a finished run, kept so the offload report can be
/// produced later.
struct RunFileRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var fileName: String
    var deviceName: String
    var sizeBytes: Int64
    var succeeded: Bool
    var errorMessage: String?
    /// "verified", "mismatch", "failed", or "none" when verification was off.
    var verification: String
    var sha256: String?
    var folderPath: String
}

struct WorkflowRun: Identifiable, Codable, Hashable {
    var id = UUID()
    var workflowName: String
    var startedAt: Date
    var finishedAt: Date
    var processed: Int
    var errors: Int
    var decksProcessed: [String]
    var log: [String]
    /// Absent on runs saved before per-file records existed.
    var fileRecords: [RunFileRecord]? = nil

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    var durationFormatted: String {
        let s = Int(duration)
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        return String(format: "%d:%02d:%02d", h, m, r)
    }
}
