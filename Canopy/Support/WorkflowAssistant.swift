import Foundation
import FoundationModels

// MARK: - Generable draft
// What the on-device model fills in. Deliberately flat (optional fields per
// step instead of enums with payloads) — a ~3B model is far more reliable
// filling simple fields than a nested union. `WorkflowDraftBuilder` turns this
// into a real `Workflow`.

@Generable
enum DraftStepKind {
    case startRecording, stopRecording, wait, createFolder, offload
    case makeProxies, rename, transcribe, findClips, queueClips, writeCopy, webhook, copyTo, resizeForSocial, formatDrive, cleanup, notify
}

@Generable
struct WorkflowDraft {
    @Guide(description: "Short workflow name, 2-4 words")
    var name: String

    @Guide(description: "Only the steps the request asks for, in the order they should run", .maximumCount(10))
    var steps: [DraftStepKind]
}

// MARK: - Reading details from the request
// Numbers and options come from the user's own words, not from the model — a
// small model invents plausible-looking values (schedules, waits, verification)
// nobody asked for.

struct RequestDetails {
    let text: String

    init(_ request: String) {
        text = request.lowercased()
        urlInRequest = request.range(of: #"https?://[^\s"'<>]+"#, options: .regularExpression)
            .map { String(request[$0]) }
    }

    func mentions(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

    /// Deliberately avoids "shorts"/"reels"/"tiktok", which mean the *format*
    /// (Resize for Social) rather than picking the moments.
    private static let queueClipsWords = ["export queue", "add to the queue", "add them to the queue", "queue the clips", "queue them", "queue clips", "to the queue"]
    private static let writeCopyWords = ["write copy", "post copy", "caption for each", "captions for each", "write captions", "write the captions", "hashtag", "write a caption", "post text", "titles and descriptions", "write descriptions"]
    private static let webhookWords = ["webhook", "slack", "discord", "zapier", "post to a url", "send to a url", "ping a url"]
    private static let copyToWords = ["copy to", "back up to", "backup to", "second copy", "copy them to", "copy it to", "mirror", "duplicate to", "secondary drive", "second drive", "nas"]
    private static let findClipsWords = ["highlight", "best moment", "find clips", "find the clips", "find the best", "find moments", "key moments", "short-form", "social clips", "viral", "social posts", "find short"]

    /// Whether the request gives any reason to include this kind of step.
    func supports(_ kind: DraftStepKind) -> Bool {
        switch kind {
        case .startRecording, .stopRecording: return mentions(["record"])
        case .wait:        return mentions(["wait", "minute", "hour", "pause", "delay"])
        case .createFolder: return mentions(["folder", "directory"])
        case .offload:     return mentions(["offload", "copy", "download", "sync", "import", "ingest", "transfer", "clip", "footage", "card", "back up", "backup", "grab", "pull"])
        case .makeProxies: return mentions(["proxy", "proxies", "convert", "transcode", "mp4", "compress", "small version", "smaller", "low-res", "lower res", "low res", "editing cop", "edit cop"])
        case .rename:      return mentions(["rename", "name the", "naming", "called"])
        case .transcribe:  return wantsTranscript
        case .findClips:   return mentions(Self.findClipsWords) || mentions(Self.queueClipsWords)
        case .queueClips:  return mentions(Self.queueClipsWords)
        case .writeCopy:   return mentions(Self.writeCopyWords)
        case .webhook:     return mentions(Self.webhookWords)
        case .copyTo:      return mentions(Self.copyToWords)
        case .resizeForSocial: return mentions(["social", "vertical", "reel", "tiktok", "shorts", "instagram", "9:16", "square crop", "4:5"])
        case .formatDrive: return mentions(["format", "erase", "wipe", "clear the", "empty the"])
        case .cleanup:     return mentions(["delete", "clean", "remove", "older than", "old files", "purge", "clear out"])
        case .notify:      return mentions(["email", "notify", "tell me", "let me know", "alert", "message me"])
        }
    }

    /// Steps stated so plainly the model leaving one out is a miss, not a
    /// choice. Never includes destructive steps — those only ever come from
    /// the model *and* a matching request.
    var statedKinds: [DraftStepKind] {
        var kinds: [DraftStepKind] = []
        if mentions(["start recording", "begin recording", "record for", "start the recording"]) { kinds.append(.startRecording) }
        if capture(#"\b(?:make|create|new|dated|add)\b[^.,]*\bfolder"#) != nil || mentions(["folder called", "folder named"]) { kinds.append(.createFolder) }
        if mentions(["offload", "ingest", "download the", "copy the footage", "copy everything", "copy the clips", "copy new", "grab the footage", "grab the clips", "grab everything", "pull the footage", "pull the clips"]) { kinds.append(.offload) }
        if mentions(["proxy", "proxies", "small version", "low-res", "lower res", "editing cop"]) { kinds.append(.makeProxies) }
        if mentions(["rename"]) { kinds.append(.rename) }
        if wantsTranscript { kinds.append(.transcribe) }
        if mentions(Self.findClipsWords) { kinds.append(.findClips) }
        if mentions(Self.queueClipsWords) { kinds.append(.queueClips) }
        if mentions(Self.writeCopyWords) { kinds.append(.writeCopy) }
        if mentions(Self.webhookWords) { kinds.append(.webhook) }
        if mentions(Self.copyToWords) { kinds.append(.copyTo) }
        if mentions(["email me", "notify me", "let me know", "tell me when", "message me"]) { kinds.append(.notify) }
        return kinds
    }

    /// "stop after 45 minutes" / "for 2 hours".
    var stopAfterMinutes: Int? {
        minutes(matching: #"(?:stop(?:s|ping)?\s+(?:after|in)|for)\s+(\d+)\s*(minutes?|mins?|hours?|hrs?)"#)
    }

    /// "wait 10 minutes" / "after 2 hours".
    var waitMinutes: Int? {
        minutes(matching: #"(?:wait(?:s|ing)?(?:\s+for)?|pause(?:\s+for)?|then\s+after|delay(?:\s+of)?)\s+(\d+)\s*(minutes?|mins?|hours?|hrs?)"#)
    }

    /// "Captions" means subtitles unless the request is clearly about
    /// writing caption text for posts, which is Write Post Copy.
    private var wantsTranscript: Bool {
        if mentions(["transcri", "subtitle", "speech to text", "srt"]) { return true }
        return mentions(["caption"]) && !mentions(Self.writeCopyWords)
    }

    /// An http(s) address typed into the request, taken from the original
    /// text so its case is preserved.
    var urlInRequest: String?

    var webhookFormat: WebhookFormat {
        if mentions(["slack"]) { return .slack }
        if mentions(["discord"]) { return .discord }
        return .json
    }

    var deletesOriginals: Bool {
        mentions(["delete the original", "delete originals", "delete the source", "remove the original", "replace the original", "get rid of the original"])
    }

    var wantsVerification: Bool { mentions(["verif", "checksum", "hash", "integrity"]) }

    /// "older than 30 days" / "after 2 weeks".
    var retentionDays: Int? {
        if let m = capture(#"(\d+)\s*(days?|weeks?|months?)"#), let n = Int(m[0]) {
            let unit = m[1]
            return unit.hasPrefix("week") ? n * 7 : unit.hasPrefix("month") ? n * 30 : n
        }
        return nil
    }

    /// "every night at 2am", "daily at 6:30 pm", "every morning at 7".
    /// Needs both a recurrence word and a clock time so a stray "at 5" can't
    /// create a schedule. A bare hour is read from the time of day mentioned
    /// ("morning" → AM, "evening" → PM); `ambiguousTime` reports when it can't.
    var dailyTime: (hour: Int, minute: Int)? {
        guard mentions(["every", "each", "daily", "nightly", "nights", "mornings"]),
              let m = capture(#"\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?"#),
              var hour = Int(m[0]), (0...23).contains(hour) else { return nil }
        let minute = min(Int(m[1]) ?? 0, 59)
        if m[2].hasPrefix("p") {
            if hour < 12 { hour += 12 }
        } else if m[2].hasPrefix("a") {
            if hour == 12 { hour = 0 }
        } else if hour > 12 || m[1] != "" && hour == 0 {
            // already 24-hour
        } else if mentions(["morning"]) {
            if hour == 12 { hour = 0 }
        } else if mentions(["afternoon", "evening"]) {
            if hour < 12 { hour += 12 }
        } else if mentions(["night", "nightly"]) {
            hour = hour >= 6 && hour <= 11 ? hour + 12 : (hour == 12 ? 0 : hour)
        } else {
            return nil
        }
        return (hour, minute)
    }

    /// True when the request names a recurring time we couldn't pin to AM/PM.
    var ambiguousTime: Bool {
        mentions(["every", "each", "daily"]) && capture(#"\bat\s+\d{1,2}(?::\d{2})?\b"#) != nil && dailyTime == nil
    }

    var folderName: String {
        if let m = capture(#"folder\s+(?:called|named)\s+["“]?([a-z0-9 _\-]+)"#) {
            let name = m[0].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name + "_\(FolderNameEngine.dateToken)" }
        }
        return "Footage_\(FolderNameEngine.dateToken)"
    }

    /// Builds a rename pattern from what the request says should be in the name.
    var renamePattern: String {
        var parts: [String] = []
        if mentions(["project", "shoot"]) { parts.append(RenameToken.project.rawValue) }
        if mentions(["camera", " cam"]) { parts.append(RenameToken.cam.rawValue) }
        if mentions(["device"]) { parts.append(RenameToken.device.rawValue) }
        if mentions(["date", "dated"]) { parts.append(RenameToken.date.rawValue) }
        if parts.isEmpty { return "{device}_{date}_{index}" }
        return (parts + [RenameToken.index.rawValue]).joined(separator: "_")
    }

    // MARK: helpers

    private func capture(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private func minutes(matching pattern: String) -> Int? {
        guard let m = capture(pattern), let n = Int(m[0]), n > 0 else { return nil }
        return min(m[1].hasPrefix("h") ? n * 60 : n, 1440)
    }
}

// MARK: - Draft → Workflow

struct WorkflowDraftResult {
    var workflow: Workflow
    /// Things the user should know before saving (steps dropped, safety flags).
    var notes: [String]
}

enum WorkflowDraftBuilder {
    /// Converts the model's draft into a real workflow:
    /// - Steps the request gives no reason for are dropped.
    /// - Details (times, options) are read from the request, not the model.
    /// - Format Drive / Cleanup delete data, so they always ask for
    ///   confirmation before running.
    /// - An Offload after a Create Folder step is pointed at that folder.
    static func build(from draft: WorkflowDraft, request: String) -> WorkflowDraftResult {
        let details = RequestDetails(request)
        var notes: [String] = []
        var steps: [WorkflowStep] = []
        var dropped: [String] = []

        // The model picks and orders; anything the request states outright
        // that it left out is added back, and the whole list is put in a
        // sensible running order (offload before proxies before notify...).
        var kinds = draft.steps
        for kind in details.statedKinds where !kinds.contains(kind) { kinds.append(kind) }
        kinds = kinds.enumerated()
            .sorted { ($0.element.runOrder, $0.offset) < ($1.element.runOrder, $1.offset) }
            .map(\.element)

        for kind in kinds {
            guard details.supports(kind) else {
                dropped.append(title(for: kind))
                continue
            }
            switch kind {
            case .startRecording:
                steps.append(WorkflowStep(action: .controlDeck(command: .start, stopAfterMinutes: details.stopAfterMinutes)))
            case .stopRecording:
                steps.append(WorkflowStep(action: .controlDeck(command: .stop, stopAfterMinutes: nil)))
            case .wait:
                steps.append(WorkflowStep(action: .wait(minutes: details.waitMinutes ?? 60)))
            case .createFolder:
                steps.append(WorkflowStep(action: .createFolder(cloudStoreID: nil, parentPath: "", nameTemplate: details.folderName, groupByDevice: false)))
            case .offload:
                steps.append(WorkflowStep(action: .sync(destination: .global, verify: details.wantsVerification)))
            case .makeProxies:
                // The app's own default deletes the originals; a plain-language
                // request has to say so explicitly.
                steps.append(WorkflowStep(action: .convert(preset: .fast, deleteOriginal: details.deletesOriginals, maxParallelJobs: 2, convertInPlace: false)))
            case .rename:
                steps.append(WorkflowStep(action: .rename(pattern: details.renamePattern)))
            case .transcribe:
                steps.append(WorkflowStep(action: StepAction.defaultAction(for: .transcribe)))
            case .findClips:
                steps.append(WorkflowStep(action: StepAction.defaultAction(for: .findClips)))
            case .queueClips:
                steps.append(WorkflowStep(action: StepAction.defaultAction(for: .queueClips)))
            case .writeCopy:
                steps.append(WorkflowStep(action: StepAction.defaultAction(for: .writeCopy)))
            case .webhook:
                // Only a URL the request actually contains; never made up.
                steps.append(WorkflowStep(action: .webhook(url: details.urlInRequest ?? "", format: details.webhookFormat)))
            case .copyTo:
                steps.append(WorkflowStep(action: StepAction.defaultAction(for: .copyTo)))
            case .resizeForSocial:
                steps.append(WorkflowStep(action: StepAction.defaultAction(for: .reframe)))
            case .formatDrive:
                steps.append(WorkflowStep(action: .format, requiresConfirmation: true))
            case .cleanup:
                steps.append(WorkflowStep(action: .cleanup(retentionDays: details.retentionDays ?? 30), requiresConfirmation: true))
            case .notify:
                steps.append(WorkflowStep(action: .notify(header: "Workflow update", message: "", recipients: [], sendPerDrive: true)))
            }
        }

        if !dropped.isEmpty {
            notes.append("Left out \(dropped.joined(separator: ", ")) — your request didn't mention it.")
        }

        if let folderIndex = steps.firstIndex(where: { $0.kind == .createFolder }) {
            let folderID = steps[folderIndex].id
            for i in steps.indices where i > folderIndex {
                if case .sync(.global, let verify, let deleteFromDevice) = steps[i].action {
                    steps[i].action = .sync(destination: .createdFolder(stepID: folderID), verify: verify, deleteFromDevice: deleteFromDevice)
                }
            }
        }

        if details.mentions(["upload", "publish it", "publish them", "post it to", "post them to"]) {
            notes.append("Uploading is coming soon, so I left it out — the finished files are ready for you to upload yourself.")
        }
        if details.ambiguousTime {
            notes.append("Couldn't tell if the schedule time is AM or PM — set it under Schedule in the editor.")
        }
        if steps.contains(where: { step in
            if case .webhook(let url, _) = step.action { return url.isEmpty }
            return false
        }) {
            notes.append("Paste the webhook URL into the Send Webhook step.")
        }
        if steps.contains(where: { $0.kind == .copyTo }) {
            notes.append("Choose where the Copy To step should copy to — it defaults to the global destination.")
        }
        if steps.contains(where: { $0.kind == .notify }) {
            notes.append("Add recipients to the Notification step — I can't pick email addresses for you.")
        }
        if steps.contains(where: { $0.kind == .format || $0.kind == .cleanup }) {
            notes.append("Destructive steps are set to ask for confirmation before they run.")
        }

        var triggers: [ScheduleSettings] = []
        if let time = details.dailyTime {
            var trigger = ScheduleSettings()
            trigger.isEnabled = true
            trigger.mode = .daily
            trigger.hour = time.hour
            trigger.minute = time.minute
            trigger.repeatDaily = true
            triggers = [trigger]
        }

        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workflow = Workflow(name: name.isEmpty ? "New Workflow" : name, steps: steps, triggers: triggers)
        return WorkflowDraftResult(workflow: workflow, notes: notes)
    }

    private static func title(for kind: DraftStepKind) -> String {
        switch kind {
        case .startRecording: return "Start Recording"
        case .stopRecording:  return "Stop Recording"
        case .wait:           return "Wait"
        case .createFolder:   return "Create Folder"
        case .offload:        return "Offload"
        case .makeProxies:    return "Make Proxies"
        case .rename:         return "Rename"
        case .transcribe:     return "Transcribe"
        case .findClips:      return "Find Clips"
        case .queueClips:     return "Queue Clips"
        case .writeCopy:      return "Write Post Copy"
        case .webhook:        return "Send Webhook"
        case .copyTo:         return "Copy To"
        case .resizeForSocial: return "Resize for Social"
        case .formatDrive:    return "Format Drive"
        case .cleanup:        return "Cleanup"
        case .notify:         return "Notification"
        }
    }
}

// MARK: - Assistant

enum WorkflowAssistantError: LocalizedError {
    case modelUnavailable(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let why): return why
        case .emptyResult: return "I couldn't turn that into any steps. Try describing what should happen in order."
        }
    }
}

enum WorkflowAssistant {
    private static let instructions = """
    You turn a request into a workflow for Canopy, an app that offloads footage from HyperDeck recorders.
    Choose steps from: startRecording, stopRecording, wait, createFolder, offload (copy new clips from the \
    device), makeProxies (small MP4 copies), rename, transcribe (speech to text), findClips (suggest short social clips from a long video), queueClips (add those clips to the export queue), writeCopy (draft captions and hashtags for clips), webhook (send details to a URL), copyTo (make a second copy of the files somewhere else), resizeForSocial (vertical or square \
    crop for social media that keeps the subject in frame), formatDrive (erases the recorder), cleanup (deletes old files), notify (sends an email).
    Include ONLY steps the request asks for. Do not add recording, waiting, folders, or anything else that \
    was not mentioned. Keep them in the order the request describes.
    Examples:
    "offload my clips" -> offload
    "copy the footage, make proxies and email me" -> offload, makeProxies, notify
    "every night offload then delete files older than 30 days" -> offload, cleanup
    "offload and transcribe everything" -> offload, transcribe
    """

    /// nil when the on-device model is ready, otherwise a user-facing reason.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence, which the workflow builder needs."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use the workflow builder."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model. Try again in a few minutes."
        case .unavailable:
            return "The on-device model isn't available right now."
        }
    }

    static func draft(from request: String) async throws -> WorkflowDraftResult {
        if let reason = unavailableReason { throw WorkflowAssistantError.modelUnavailable(reason) }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: request, generating: WorkflowDraft.self, options: GenerationOptions(samplingMode: .greedy))
        let result = WorkflowDraftBuilder.build(from: response.content, request: request)
        guard !result.workflow.steps.isEmpty else { throw WorkflowAssistantError.emptyResult }
        return result
    }
}

private extension DraftStepKind {
    /// Natural running order of the steps.
    var runOrder: Int {
        switch self {
        case .startRecording: return 0
        case .wait:           return 1
        case .stopRecording:  return 2
        case .createFolder:   return 3
        case .offload:        return 4
        case .makeProxies:    return 5
        case .rename:         return 6
        case .transcribe:     return 7
        case .findClips:      return 8
        case .queueClips:     return 9
        case .writeCopy:      return 10
        case .resizeForSocial: return 11
        case .copyTo:         return 12
        case .formatDrive:    return 13
        case .cleanup:        return 14
        case .webhook:        return 15
        case .notify:         return 16
        }
    }
}
