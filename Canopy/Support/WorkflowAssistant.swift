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

// MARK: - Generable edit
// For changing a workflow that already exists. The model only says *what*
// kind of change and to *which* step kind; `WorkflowEditBuilder` applies it.

@Generable
enum DraftEditAction {
    /// Add a new step.
    case add
    /// Remove every step of that kind.
    case remove
    /// Move an existing step to a different place.
    case move
    /// Change a setting on an existing step (wait length, verification, days to keep, URL…).
    case update
}

@Generable
enum DraftPlacement {
    /// Where that step would normally run — use this unless the request says where.
    case automatic
    case start, end, before, after
}

@Generable
struct DraftEdit {
    var action: DraftEditAction
    var step: DraftStepKind

    @Guide(description: "For add and move: where it goes. Use automatic unless the request names a position.")
    var placement: DraftPlacement

    @Guide(description: "Only when placement is before or after: the existing step it goes next to")
    var relativeTo: DraftStepKind?
}

@Generable
struct WorkflowEditDraft {
    @Guide(description: "Only the changes the request asks for, in order. Empty if it asks for no change to the steps.", .maximumCount(8))
    var edits: [DraftEdit]
}

// MARK: - Reading details from the request
// Numbers and options come from the user's own words, not from the model — a
// small model invents plausible-looking values (schedules, waits, verification)
// nobody asked for.

struct RequestDetails {
    /// The whole request, lowercased.
    let text: String
    /// The request with the phrasing that says *when* it runs blanked out —
    /// what step detection reads, so "when the deck stops recording" isn't a
    /// Stop Recording step and "after Card Ingest finishes" isn't an Offload.
    let stepText: String
    /// "delete the transcripts when it's done" (true), "keep the
    /// transcripts" (false), or nil when the request doesn't say. Read here
    /// because the phrase is blanked out of `stepText`, so its "delete"
    /// isn't mistaken for a Cleanup step.
    let deletesTranscripts: Bool?
    /// What the request says about when the workflow starts.
    let schedule: TriggerIntent
    let context: TriggerContext

    init(_ request: String, context: TriggerContext = .empty, now: Date = Date()) {
        let parsed = WorkflowTriggerParser.parse(request, context: context, now: now)
        text = request.lowercased()
        let transcriptDeletion = Self.transcriptDeletion(in: parsed.stepText)
        deletesTranscripts = transcriptDeletion.value
        stepText = transcriptDeletion.remaining
        schedule = parsed.intent
        self.context = context
        urlInRequest = request.range(of: #"https?://[^\s"'<>]+"#, options: .regularExpression)
            .map { String(request[$0]) }
    }

    func mentions(_ words: [String]) -> Bool { words.contains { stepText.contains($0) } }

    // MARK: Decks and folders

    private func names(_ name: String, after lead: String = "") -> Bool {
        let pattern = lead + #"(?<![a-z0-9])"# + NSRegularExpression.escapedPattern(for: name.lowercased()) + #"(?![a-z0-9])"#
        return stepText.range(of: pattern, options: .regularExpression) != nil
    }

    /// The HyperDecks the request points its deck steps at: the ones it
    /// names, or every deck for "all decks" / "every HyperDeck". Nil when it
    /// doesn't say. A deck named only as the thing a trigger watches ("when
    /// Studio A stops recording") isn't taken as a change to the steps.
    var statedDecks: DeckSelection? {
        let triggerLead = #"\b(?:when|whenever|once|after|if|as\s+soon\s+as)\s+(?:the\s+)?"#
        let named = context.decks.filter { deck in
            guard names(deck.name) else { return false }
            let watched = schedule.events.contains { $0.deviceID == deck.id }
            return !(watched && names(deck.name, after: triggerLead))
        }
        if !named.isEmpty { return .only(named.map(\.id)) }
        let everyDeck = #"\b(?:all|every|each|both)\s+(?:of\s+)?(?:the\s+|my\s+)?(?:hyper\s?decks?|decks?|recorders?|devices?)\b"#
        return stepText.range(of: everyDeck, options: .regularExpression) != nil ? .all : nil
    }

    /// What a brand-new deck step uses when the request doesn't say: the
    /// deck a trigger is watching, or the only deck there is. Otherwise
    /// none — the choice is left to the user.
    var decksForNewSteps: DeckSelection {
        if let statedDecks { return statedDecks }
        let watched = schedule.events.compactMap(\.deviceID).filter { id in context.decks.contains { $0.id == id } }
        if !watched.isEmpty { return .only(watched) }
        if context.decks.count == 1 { return .only([context.decks[0].id]) }
        return .only([])
    }

    /// Local Folders the request says to work in ("transcribe everything in
    /// Sunday Services"), plus any a trigger is watching. A folder that's
    /// only somewhere to copy *to* doesn't count.
    var foldersToProcess: [TriggerContext.Item] {
        let lead = #"\b(?:in|on|from|inside|within)\s+(?:the\s+|my\s+)?"#
        return context.folders.filter { folder in
            names(folder.name, after: lead)
                || schedule.events.contains { $0.deviceID == folder.id }
        }
    }

    private static let transcriptNoun = #"(?:(?:new|temporary|temp|generated|those|these|the|any|all|its|their|my)\s+){0,3}(?:transcripts?|transcriptions?|transcript\s+files?|subtitles?|srt(?:\s+files?)?)"#

    /// Finds a statement about what happens to the transcript files and
    /// returns it with that phrase blanked out of the text.
    private static func transcriptDeletion(in text: String) -> (value: Bool?, remaining: String) {
        let dontDelete = #"\b(?:don'?t|do\s+not|never)\s+(?:delete|remove|discard|clear|get\s+rid\s+of|throw\s+away)\s+\#(transcriptNoun)"#
        let keep = #"\b(?:keep|save|retain|leave)\s+(?:around\s+)?\#(transcriptNoun)"#
        let drop = #"\b(?:delete|remove|discard|clear(?:\s+out)?|erase|get\s+rid\s+of|throw\s+(?:away|out)|trash|clean\s+up)\s+\#(transcriptNoun)|\b(?:don'?t|do\s+not|no\s+need\s+to)\s+(?:keep|save|retain|leave)\s+(?:around\s+)?\#(transcriptNoun)|\b(?:temporary|temp|throwaway|disposable)\s+(?:transcripts?|transcriptions?)\b"#
        for (pattern, value) in [(dontDelete, false), (drop, true), (keep, false)] {
            guard let range = text.range(of: pattern, options: .regularExpression) else { continue }
            var remaining = text
            remaining.replaceSubrange(range, with: String(repeating: " ", count: text.distance(from: range.lowerBound, to: range.upperBound)))
            return (value, remaining)
        }
        return (nil, text)
    }

    /// Deliberately avoids "shorts"/"reels"/"tiktok", which mean the *format*
    /// (Resize for Social) rather than picking the moments.
    private static let queueClipsWords = ["export queue", "add to the queue", "add them to the queue", "queue the clips", "queue them", "queue clips", "to the queue", "queue only", "queue the best", "queue the top"]
    private static let writeCopyWords = ["write copy", "post copy", "caption for each", "captions for each", "write captions", "write the captions", "hashtag", "write a caption", "post text", "titles and descriptions", "write descriptions"]
    private static let webhookWords = ["webhook", "slack", "discord", "zapier", "post to a url", "send to a url", "ping a url"]
    private static let copyToWords = ["copy to", "back up to", "backup to", "second copy", "copy them to", "copy it to", "mirror", "duplicate to", "secondary drive", "second drive", "nas"]
    private static let findClipsWords = ["highlight", "best moment", "find clips", "find the clips", "find the best", "find moments", "key moments", "short-form", "social clips", "viral", "social posts", "find short",
                                         "funny moments", "emotional moments", "speaker quotes", "best quotes", "find quotes", "find the quotes"]

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
        case .resizeForSocial: return mentions(["social", "vertical", "reel", "tiktok", "shorts", "instagram", "9:16", "square crop", "4:5", "resize", "reframe", "aspect ratio", "16:9", "1:1"])
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

    var wantsVerification: Bool {
        mentions(["verif", "checksum", "hash", "integrity"]) && !negatesVerification
    }

    /// "without verification", "skip verifying", "don't verify".
    var negatesVerification: Bool {
        mentions(["without verif", "no verif", "skip verif", "don't verify", "do not verify", "turn off verif", "without a checksum", "without checksum"])
    }

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
    var dailyTime: (hour: Int, minute: Int)? { schedule.daily }

    /// True when the request names a time to start at that couldn't be pinned
    /// to AM or PM — for a recurring run or a dated one-time run.
    var ambiguousTime: Bool {
        let dated = WorkflowTriggerParser.isRecurring(text) || schedule.oneTime != nil
            || text.contains("tomorrow") || text.contains("tonight") || text.contains("next ")
        return dated && WorkflowTriggerParser.hasBareClockTime(in: text)
            && WorkflowTriggerParser.clockTime(in: text) == nil
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

    /// "remove the schedule" / "only run it manually".
    var removesSchedule: Bool {
        let words = ["remove the schedule", "remove the trigger", "no schedule", "no longer run on a schedule", "stop running every", "run it manually", "only run manually", "manual only", "turn off the schedule", "unschedule", "delete the schedule"]
        return words.contains { text.contains($0) }
    }

    /// Days of the week were named but no time to run at (and no half-written
    /// time that `ambiguousTime` already reports).
    var needsTimeForDays: Bool {
        schedule.daily == nil && !schedule.weekdays.isEmpty
            && !WorkflowTriggerParser.hasBareClockTime(in: text)
    }

    /// "also run it…", "add another schedule" — a new trigger rather than a
    /// change to the one it already has.
    var addsAnotherTrigger: Bool {
        ["also", "another", "additionally", "as well", "in addition", "on top of"].contains { text.contains($0) }
    }

    /// "rename the workflow to Friday Ingest" / "call this workflow Friday Ingest".
    var newWorkflowName: String? {
        guard let m = capture(#"(?:rename|call|name)\s+(?:the|this|my)\s+workflow\s+(?:to\s+|as\s+)?["“]?([a-z0-9][a-z0-9 _\-]{0,40})"#) else { return nil }
        let raw = m[0].trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw
    }

    /// Whether the request refers to this kind of step by name, for removing
    /// or changing one — looser than `supports`, which decides whether a
    /// request *wants a new one*.
    func refersTo(_ kind: DraftStepKind) -> Bool {
        let words: [String]
        switch kind {
        case .startRecording, .stopRecording: words = ["record"]
        case .wait:        words = ["wait", "delay", "pause"]
        case .createFolder: words = ["folder"]
        case .offload:     words = ["offload", "sync", "download", "copy", "ingest", "import", "verif"]
        case .makeProxies: words = ["proxy", "proxies", "convert", "transcode"]
        case .rename:      words = ["rename", "naming", "file name", "filename"]
        case .transcribe:  words = ["transcri", "subtitle", "caption"]
        case .findClips:   words = ["find clips", "highlight", "moments", "clips"]
        case .queueClips:  words = ["queue"]
        case .writeCopy:   words = ["post copy", "caption", "hashtag", "copy"]
        case .webhook:     words = ["webhook", "slack", "discord", "zapier", "url"]
        case .copyTo:      words = ["copy to", "second copy", "backup", "back up", "mirror"]
        case .resizeForSocial: words = ["resize", "social", "vertical", "reframe", "crop"]
        case .formatDrive: words = ["format", "erase", "wipe"]
        case .cleanup:     words = ["cleanup", "clean up", "delete", "older than", "retention", "days"]
        case .notify:      words = ["notif", "email", "alert", "message"]
        }
        return mentions(words)
    }

    // MARK: helpers

    private func capture(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stepText, range: NSRange(stepText.startIndex..., in: stepText)) else { return nil }
        return (1..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: stepText).map { String(stepText[$0]) } ?? ""
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
    static func build(
        from draft: WorkflowDraft, request: String,
        context: TriggerContext = .empty, now: Date = Date()
    ) -> WorkflowDraftResult {
        let details = RequestDetails(request, context: context, now: now)
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

        let kept = Set(kinds.filter { details.supports($0) })
        for kind in kinds {
            guard details.supports(kind) else {
                dropped.append(title(for: kind))
                continue
            }
            steps.append(makeStep(kind, details: details, alongside: kept))
        }
        applyWorkflowName(draft.name, to: &steps)
        for i in steps.indices where steps[i].kind.usesHyperDeck { steps[i].decks = details.decksForNewSteps }

        if !dropped.isEmpty {
            notes.append("Left out \(dropped.joined(separator: ", ")) — your request didn't mention it.")
        }

        linkOffloadsToCreatedFolder(&steps)
        notes += followUpNotes(for: steps, details: details)
        notes += settingsNotes(for: steps, details: details)
        notes += WorkflowEfficiency.advisories(for: steps)

        let triggers = details.schedule.newTriggers()
        notes += details.schedule.notes
        if details.needsTimeForDays {
            notes.append("Say what time it should run on those days — I didn't schedule it.")
        }

        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folders = details.foldersToProcess
        if !folders.isEmpty {
            notes.append("Set to process the files in \(folders.map(\.name).joined(separator: ", ")).")
        }
        let workflow = Workflow(
            name: name.isEmpty ? "New Workflow" : name, steps: steps,
            targets: folders.map { .localFolder($0.id) }, triggers: triggers
        )
        return WorkflowDraftResult(workflow: workflow, notes: notes)
    }

    /// One new step for a kind. Settings come from what the request says
    /// about how the step should run; where it says nothing, from the
    /// efficient choice for this workflow and this Mac, and otherwise the
    /// step's own default. `alongside` is every step kind being built with it.
    static func makeStep(_ kind: DraftStepKind, details: RequestDetails, alongside: Set<DraftStepKind> = []) -> WorkflowStep {
        switch kind {
        case .startRecording:
            return WorkflowStep(action: .controlDeck(command: .start, stopAfterMinutes: details.stopAfterMinutes))
        case .stopRecording:
            return WorkflowStep(action: .controlDeck(command: .stop, stopAfterMinutes: nil))
        case .wait:
            return WorkflowStep(action: .wait(minutes: details.waitMinutes ?? 60))
        case .createFolder:
            return WorkflowStep(action: .createFolder(
                cloudStoreID: nil, parentPath: "", nameTemplate: details.folderName,
                groupByDevice: details.groupsByDevice ?? WorkflowEfficiency.hasSeveralDecks(details.context)))
        case .offload:
            return WorkflowStep(action: .sync(destination: .global, verify: details.wantsVerification))
        case .makeProxies:
            // The app's own default deletes the originals; a plain-language
            // request has to say so explicitly. When it does, the proxy
            // replaces the original in place rather than also leaving a
            // second copy in a Converted folder.
            let deletes = details.deletesOriginals && !details.keepsOriginals
            return WorkflowStep(action: .convert(
                preset: details.proxyPreset ?? .fast,
                deleteOriginal: deletes,
                maxParallelJobs: details.parallelJobs ?? WorkflowEfficiency.parallelJobs,
                convertInPlace: details.convertsInPlace ?? deletes))
        case .rename:
            return WorkflowStep(action: .rename(pattern: details.renamePattern))
        case .transcribe:
            return WorkflowStep(action: .transcribe(
                locale: details.transcriptionLocale ?? Locale.current.identifier,
                writeSRT: details.writesSRT ?? true,
                skipExisting: details.skipsExistingTranscripts ?? true,
                deleteWhenDone: details.deletesTranscripts ?? false))
        case .findClips:
            let lengths = details.clipLengths
            var minSeconds = lengths.min ?? 20
            var maxSeconds = lengths.max ?? 60
            // Only one end stated: keep the other end sensible around it.
            if lengths.max != nil, lengths.min == nil, minSeconds >= maxSeconds { minSeconds = max(10, maxSeconds / 2) }
            if lengths.min != nil, lengths.max == nil, maxSeconds <= minSeconds { maxSeconds = min(180, minSeconds * 2) }
            // A Resize for Social step already produces the cropped clips, so
            // rendering finished posts here as well would do the work twice.
            let export: SocialFormat? = details.wantsFinishedPosts && !alongside.contains(.resizeForSocial)
                ? (details.postFormat ?? .vertical) : nil
            return WorkflowStep(action: .findClips(
                maxClips: details.clipCount ?? 5, minSeconds: minSeconds, maxSeconds: maxSeconds,
                exportFormat: export, captions: details.captionsOnPosts ?? true,
                focus: details.clipFocus ?? ClipFocus()))
        case .queueClips:
            return WorkflowStep(action: .queueClips(minScore: details.minClipScore ?? 0))
        case .writeCopy:
            return WorkflowStep(action: .writeCopy(
                platform: details.copyPlatform ?? .general, hashtagCount: details.hashtagCount ?? 5))
        case .webhook:
            // Only a URL the request actually contains; never made up.
            return WorkflowStep(action: .webhook(url: details.urlInRequest ?? "", format: details.webhookFormat))
        case .copyTo:
            return WorkflowStep(action: .copyTo(
                destination: .global, verify: details.copyVerifies ?? true,
                includeSidecars: details.copyIncludesSidecars ?? true))
        case .resizeForSocial:
            return WorkflowStep(action: .reframe(
                format: details.postFormat ?? .vertical, followSubject: details.followsSubject ?? true))
        case .formatDrive:
            return WorkflowStep(action: .format, requiresConfirmation: true)
        case .cleanup:
            return WorkflowStep(action: .cleanup(retentionDays: details.retentionDays ?? 30), requiresConfirmation: true)
        case .notify:
            // With several decks, one email per deck is the noisy choice
            // unless the request asks for it.
            let perDrive = details.notifiesPerDrive ?? !WorkflowEfficiency.hasSeveralDecks(details.context)
            return WorkflowStep(action: .notify(header: "Workflow update", message: "", recipients: [], sendPerDrive: perDrive))
        }
    }

    /// A notification's subject line defaults to the workflow's name, so the
    /// email says which workflow it came from.
    static func applyWorkflowName(_ name: String, to steps: inout [WorkflowStep]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for i in steps.indices {
            if case .notify(let header, let message, let recipients, let perDrive) = steps[i].action,
               header == "Workflow update" {
                steps[i].action = .notify(header: trimmed, message: message, recipients: recipients, sendPerDrive: perDrive)
            }
        }
    }

    /// The settings that differ from a step's defaults, so the user can see
    /// what was decided for them. Only the kinds whose settings are inferred.
    static func settingsNotes(for steps: [WorkflowStep], details: RequestDetails) -> [String] {
        var notes: [String] = []
        let inferred: Set<StepKind> = [.convert, .transcribe, .findClips, .queueClips, .writeCopy, .copyTo, .reframe, .notify, .createFolder]
        for step in steps where inferred.contains(step.kind) {
            guard !isDefault(step.action) else { continue }
            notes.append("\(step.kind.title): \(step.action.summary)")
        }
        if details.postFormatCount > 1, steps.contains(where: { $0.kind == .reframe }) {
            notes.append("Resize for Social makes one format per step — I used the first one you named; add another step for the rest.")
        }
        return notes
    }

    /// Whether an action is exactly what the step would have by default (apart
    /// from settings that are never inferred, like the transcription language
    /// the Mac already uses).
    private static func isDefault(_ action: StepAction) -> Bool {
        switch action {
        case .convert(let preset, let delete, let jobs, let inPlace):
            return preset == .fast && !delete && !inPlace && jobs == WorkflowEfficiency.parallelJobs
        case .transcribe(let locale, let srt, let skip, let deleteWhenDone):
            return locale == Locale.current.identifier && srt && skip && !deleteWhenDone
        case .createFolder(_, _, _, let group):
            return !group
        case .notify(_, _, _, let perDrive):
            return perDrive
        default:
            return action == StepAction.defaultAction(for: action.kind)
        }
    }

    /// Points global-destination Offloads that follow a Create Folder step at it.
    static func linkOffloadsToCreatedFolder(_ steps: inout [WorkflowStep]) {
        guard let folderIndex = steps.firstIndex(where: { $0.kind == .createFolder }) else { return }
        let folderID = steps[folderIndex].id
        for i in steps.indices where i > folderIndex {
            if case .sync(.global, let verify, let deleteFromDevice) = steps[i].action {
                steps[i].action = .sync(destination: .createdFolder(stepID: folderID), verify: verify, deleteFromDevice: deleteFromDevice)
            }
        }
    }

    /// What the user still has to fill in for the given (new) steps.
    static func followUpNotes(for steps: [WorkflowStep], details: RequestDetails) -> [String] {
        var notes: [String] = []
        if details.mentions(["upload", "publish it", "publish them", "post it to", "post them to"]) {
            notes.append("Uploading is coming soon, so I left it out — the finished files are ready for you to upload yourself.")
        }
        if details.ambiguousTime {
            notes.append("Couldn't tell if the schedule time is AM or PM — set it under Starts when.")
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
        let deckSteps = steps.filter { $0.kind.usesHyperDeck }
        let unset = deckSteps.filter { $0.decks.isNone }
        if let chosen = deckSteps.first(where: { !$0.decks.isNone }) {
            notes.append("HyperDeck steps use \(details.context.describe(chosen.decks)).")
        }
        if !unset.isEmpty, !details.context.decks.isEmpty {
            let titles = unset.map(\.action.shortLabel).joined(separator: ", ")
            notes.append("Choose which HyperDecks \(titles) should use — none are selected yet.")
        }
        return notes
    }

    static func title(for kind: DraftStepKind) -> String {
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

// MARK: - Edit → Workflow

enum WorkflowEditBuilder {
    /// Applies the model's edits to an existing workflow's steps and triggers.
    /// - Anything the request doesn't refer to is left alone.
    /// - New steps and their details are built the same way as for a draft.
    /// - Schedules, renames and step settings are read from the request text.
    static func apply(
        _ draft: WorkflowEditDraft, to workflow: Workflow, request: String,
        context: TriggerContext = .empty, now: Date = Date()
    ) -> WorkflowDraftResult {
        let details = RequestDetails(request, context: context, now: now)
        var result = workflow
        var notes: [String] = []
        var summary: [String] = []
        var added: [WorkflowStep] = []
        var addedFolder = false

        // Decks and folders: read straight from the request, never from the
        // model. Naming a deck re-points the deck steps the request talks
        // about — or all of them, when it doesn't single any out.
        var redirected: Set<UUID> = []
        if let decks = details.statedDecks {
            let deckSteps = result.steps.indices.filter { result.steps[$0].kind.usesHyperDeck }
            let singledOut = deckSteps.filter { i in
                DraftStepKind(step: result.steps[i]).map(details.refersTo) == true
            }
            for i in singledOut.isEmpty ? deckSteps : singledOut where result.steps[i].decks != decks {
                result.steps[i].decks = decks
                redirected.insert(result.steps[i].id)
            }
            if !redirected.isEmpty {
                let titles = result.steps.filter { redirected.contains($0.id) }.map(\.action.shortLabel)
                summary.append("Set \(titles.joined(separator: ", ")) to use \(context.describe(decks))")
            }
        }
        for folder in details.foldersToProcess where !result.targets.contains(.localFolder(folder.id)) {
            result.targets.append(.localFolder(folder.id))
            summary.append("Added \(folder.name) to the folders it processes")
        }

        for edit in draft.edits {
            let title = WorkflowDraftBuilder.title(for: edit.step)
            switch edit.action {
            case .add:
                guard details.supports(edit.step) else {
                    notes.append("Didn't add \(title) — your request didn't mention it.")
                    continue
                }
                let siblings = Set(result.steps.compactMap { DraftStepKind(step: $0) })
                var step = WorkflowDraftBuilder.makeStep(edit.step, details: details, alongside: siblings.union([edit.step]))
                if step.kind.usesHyperDeck { step.decks = details.decksForNewSteps }
                let index = insertionIndex(for: edit, in: result.steps)
                result.steps.insert(step, at: index)
                added.append(step)
                if step.kind == .createFolder { addedFolder = true }
                summary.append("Added \(title)")

            case .remove:
                guard details.refersTo(edit.step) else {
                    notes.append("Kept \(title) — your request didn't mention it.")
                    continue
                }
                let before = result.steps.count
                result.steps.removeAll { edit.step.matches($0) }
                let removed = before - result.steps.count
                if removed > 0 { summary.append("Removed \(title)\(removed > 1 ? " (\(removed) steps)" : "")") }
                else { notes.append("There's no \(title) step to remove.") }

            case .move:
                guard details.refersTo(edit.step),
                      let from = result.steps.firstIndex(where: { edit.step.matches($0) }) else {
                    notes.append("Couldn't find \(title) to move.")
                    continue
                }
                guard edit.placement != .automatic else { continue }
                let step = result.steps.remove(at: from)
                let index = insertionIndex(for: edit, in: result.steps)
                result.steps.insert(step, at: index)
                summary.append("Moved \(title)")

            case .update:
                guard details.refersTo(edit.step) else { continue }
                var changed = false
                var wasRedirected = false
                for i in result.steps.indices where edit.step.matches(result.steps[i]) {
                    if update(&result.steps[i], details: details) { changed = true }
                    if redirected.contains(result.steps[i].id) { wasRedirected = true }
                }
                if changed { summary.append("Updated \(title)") }
                else if !wasRedirected { notes.append("Couldn't tell what to change on \(title) — open it to adjust.") }
            }
        }

        if addedFolder {
            // Only a folder this edit just added: re-pointing offloads at a
            // folder the user already had would change settings they chose.
            WorkflowDraftBuilder.linkOffloadsToCreatedFolder(&result.steps)
        }

        // Triggers: read straight from the request, never from the model.
        applyTriggers(details, to: &result, summary: &summary, notes: &notes)

        if let name = details.newWorkflowName, name.caseInsensitiveCompare(result.name) != .orderedSame {
            result.name = name
            summary.append("Renamed to \(name)")
        }

        if details.wantsOptimization {
            summary += WorkflowEfficiency.optimize(&result, context: context)
            notes += WorkflowEfficiency.advisories(for: result.steps)
        }

        notes += WorkflowDraftBuilder.followUpNotes(for: added, details: details)
        notes += WorkflowDraftBuilder.settingsNotes(for: added, details: details)
        return WorkflowDraftResult(workflow: result, notes: summary + notes)
    }

    /// Adds or changes the workflow's triggers from what the request says.
    /// - A new time changes the existing daily trigger, unless the request
    ///   says "also"/"another", in which case it's added beside it.
    /// - Days alone ("only on weekdays") limit the daily triggers it has.
    /// - One-time and event triggers are added, skipping any it already has.
    private static func applyTriggers(
        _ details: RequestDetails, to workflow: inout Workflow,
        summary: inout [String], notes: inout [String]
    ) {
        let intent = details.schedule
        let context = details.context

        if details.removesSchedule, !workflow.triggers.isEmpty {
            workflow.triggers.removeAll()
            summary.append("Removed the schedule")
            return
        }

        if let time = intent.daily {
            let dailyIndexes = workflow.triggers.indices.filter { workflow.triggers[$0].mode == .daily }
            let wantedDays = intent.weekdays.isEmpty ? Set(Weekday.allCases) : intent.weekdays
            let duplicate = dailyIndexes.contains {
                let t = workflow.triggers[$0]
                return t.hour == time.hour && t.minute == time.minute && t.activeWeekdays == wantedDays
            }
            if let i = dailyIndexes.first, !details.addsAnotherTrigger {
                workflow.triggers[i].hour = time.hour
                workflow.triggers[i].minute = time.minute
                workflow.triggers[i].isEnabled = true
                if !intent.weekdays.isEmpty { workflow.triggers[i].selectedWeekdays = intent.storedWeekdays }
                summary.append("Changed the schedule to \(context.describe(workflow.triggers[i]))")
            } else if !duplicate {
                var trigger = ScheduleSettings()
                trigger.isEnabled = true
                trigger.mode = .daily
                trigger.hour = time.hour
                trigger.minute = time.minute
                trigger.repeatDaily = true
                trigger.selectedWeekdays = intent.storedWeekdays
                workflow.triggers.append(trigger)
                summary.append("Scheduled \(context.describe(trigger))")
            }
        } else if !intent.weekdays.isEmpty {
            let dailyIndexes = workflow.triggers.indices.filter { workflow.triggers[$0].mode == .daily }
            if dailyIndexes.isEmpty {
                if details.needsTimeForDays {
                    notes.append("Say what time it should run on those days — it has no daily schedule yet.")
                }
            } else {
                for i in dailyIndexes { workflow.triggers[i].selectedWeekdays = intent.storedWeekdays }
                summary.append("Limited the schedule to run \(context.describe(workflow.triggers[dailyIndexes[0]]))")
            }
        }

        if let date = intent.oneTime {
            let exists = workflow.triggers.contains {
                $0.mode == .oneTime && abs($0.oneTimeDate.timeIntervalSince(date)) < 60
            }
            if !exists {
                var trigger = ScheduleSettings()
                trigger.isEnabled = true
                trigger.mode = .oneTime
                trigger.oneTimeDate = date
                workflow.triggers.append(trigger)
                summary.append("Scheduled it to run \(context.describe(trigger))")
            }
        }

        for event in intent.events {
            if let i = workflow.triggers.firstIndex(where: {
                $0.mode == event.mode && $0.deviceID == event.deviceID && $0.sourceWorkflowID == event.sourceWorkflowID
            }) {
                if event.mode == .workflowFinished { workflow.triggers[i].finishCondition = event.finishCondition }
                if !workflow.triggers[i].isEnabled {
                    workflow.triggers[i].isEnabled = true
                    summary.append("Turned the trigger back on: \(context.describe(workflow.triggers[i]))")
                }
            } else {
                workflow.triggers.append(event)
                summary.append("Starts \(context.describe(event))")
            }
        }

        notes += intent.notes
    }

    /// Where a step should land: next to the step it's relative to, at an
    /// end, or — by default — after the last step that normally runs before it.
    private static func insertionIndex(for edit: DraftEdit, in steps: [WorkflowStep]) -> Int {
        switch edit.placement {
        case .start: return 0
        case .end:   return steps.count
        case .before, .after:
            if let other = edit.relativeTo,
               let i = steps.firstIndex(where: { other.matches($0) }) {
                return edit.placement == .before ? i : i + 1
            }
            fallthrough
        case .automatic:
            let order = edit.step.runOrder
            let lastBefore = steps.lastIndex { step in
                DraftStepKind(step: step).map { $0.runOrder <= order } ?? false
            }
            return lastBefore.map { $0 + 1 } ?? 0
        }
    }

    /// Applies whichever setting the request states to one existing step.
    private static func update(_ step: inout WorkflowStep, details: RequestDetails) -> Bool {
        switch step.action {
        case .wait:
            guard let minutes = details.waitMinutes ?? details.stopAfterMinutes else { return false }
            step.action = .wait(minutes: minutes)
            return true
        case .cleanup:
            guard let days = details.retentionDays else { return false }
            step.action = .cleanup(retentionDays: days)
            return true
        case .sync(let destination, let verify, let deleteFromDevice):
            if details.mentions(["without verif", "no verif", "skip verif", "don't verify", "turn off verif"]) {
                step.action = .sync(destination: destination, verify: false, deleteFromDevice: deleteFromDevice)
                return true
            }
            if details.wantsVerification {
                step.action = .sync(destination: destination, verify: true, deleteFromDevice: deleteFromDevice)
                return verify == false
            }
            return false
        case .controlDeck(let command, _):
            guard command == .start, let minutes = details.stopAfterMinutes else { return false }
            step.action = .controlDeck(command: command, stopAfterMinutes: minutes)
            return true
        case .webhook(_, let format):
            guard let url = details.urlInRequest else { return false }
            step.action = .webhook(url: url, format: format)
            return true
        case .rename:
            step.action = .rename(pattern: details.renamePattern)
            return true
        case .convert(let preset, let delete, let jobs, let inPlace):
            let newDelete = details.keepsOriginals ? false : (details.deletesOriginals ? true : delete)
            let new = StepAction.convert(
                preset: details.proxyPreset ?? preset, deleteOriginal: newDelete,
                maxParallelJobs: details.parallelJobs ?? jobs, convertInPlace: details.convertsInPlace ?? inPlace)
            return set(&step, to: new)
        case .transcribe(let locale, let srt, let skip, let deleteWhenDone):
            let new = StepAction.transcribe(
                locale: details.transcriptionLocale ?? locale, writeSRT: details.writesSRT ?? srt,
                skipExisting: details.skipsExistingTranscripts ?? skip,
                deleteWhenDone: details.deletesTranscripts ?? deleteWhenDone)
            return set(&step, to: new)
        case .findClips(let count, let minS, let maxS, let format, let captions, let focus):
            let lengths = details.clipLengths
            var newMin = lengths.min ?? minS
            var newMax = lengths.max ?? maxS
            if newMin >= newMax {
                if lengths.max != nil { newMin = max(10, newMax / 2) } else { newMax = min(180, newMin * 2) }
            }
            let newFormat = details.wantsFinishedPosts ? (details.postFormat ?? format ?? .vertical) : format
            let new = StepAction.findClips(
                maxClips: details.clipCount ?? count, minSeconds: newMin, maxSeconds: newMax,
                exportFormat: newFormat, captions: details.captionsOnPosts ?? captions,
                focus: details.clipFocus ?? focus)
            return set(&step, to: new)
        case .queueClips(let score):
            return set(&step, to: .queueClips(minScore: details.minClipScore ?? score))
        case .writeCopy(let platform, let tags):
            return set(&step, to: .writeCopy(
                platform: details.copyPlatform ?? platform, hashtagCount: details.hashtagCount ?? tags))
        case .copyTo(let destination, let verify, let sidecars):
            return set(&step, to: .copyTo(
                destination: destination, verify: details.copyVerifies ?? (details.wantsVerification ? true : verify),
                includeSidecars: details.copyIncludesSidecars ?? sidecars))
        case .reframe(let format, let follow):
            return set(&step, to: .reframe(
                format: details.postFormat ?? format, followSubject: details.followsSubject ?? follow))
        case .notify(let header, let message, let recipients, let perDrive):
            return set(&step, to: .notify(
                header: header, message: message, recipients: recipients,
                sendPerDrive: details.notifiesPerDrive ?? perDrive))
        case .createFolder(let store, let path, let name, let group):
            return set(&step, to: .createFolder(
                cloudStoreID: store, parentPath: path, nameTemplate: name,
                groupByDevice: details.groupsByDevice ?? group))
        default:
            return false
        }
    }

    /// Replaces a step's action, reporting whether anything actually changed.
    private static func set(_ step: inout WorkflowStep, to action: StepAction) -> Bool {
        guard step.action != action else { return false }
        step.action = action
        return true
    }
}

// MARK: - Assistant

enum WorkflowAssistantError: LocalizedError {
    case modelUnavailable(String)
    case emptyResult
    case noChange

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let why): return why
        case .emptyResult: return "I couldn't turn that into any steps. Try describing what should happen in order."
        case .noChange: return "I couldn't find a change to make. Try naming the step, like \"remove the wait\" or \"add an email at the end\"."
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
    Words about WHEN it starts are not steps: times, days of the week, "tomorrow", "when the recording \
    stops", "when the deck comes online", "after another workflow finishes", "when new clips arrive".
    Examples:
    "offload my clips" -> offload
    "copy the footage, make proxies and email me" -> offload, makeProxies, notify
    "every night offload then delete files older than 30 days" -> offload, cleanup
    "when the deck stops recording, offload and make proxies" -> offload, makeProxies
    "every weekday at 6pm, offload" -> offload
    "offload and transcribe everything" -> offload, transcribe
    """

    /// nil when a model is ready to answer, otherwise a user-facing reason.
    static var unavailableReason: String? { AIModels.shared.unavailableReason }

    private static let editInstructions = """
    You change an existing workflow for Canopy, an app that offloads footage from HyperDeck recorders.
    You are given the workflow's current steps and a request to change it. List ONLY the changes the \
    request asks for. Do not change anything it doesn't mention.
    Actions: add (a new step), remove (delete a step), move (change where a step runs), update (change a \
    setting on a step, such as how long to wait, verification, days to keep files, proxy quality, how many \
    clips or how long they are, the social format, the language, or one summary email instead of one per drive).
    Which HyperDecks or folders it uses is not a step change: return no edits for it.
    Step names: startRecording, stopRecording, wait, createFolder, offload, makeProxies, rename, transcribe, \
    findClips, queueClips, writeCopy, webhook, copyTo, resizeForSocial, formatDrive, cleanup, notify.
    Use placement automatic unless the request says where. A change to when the workflow starts (a time, \
    days of the week, a one-time run, "when recording stops", "when it comes online", "after another \
    workflow finishes", "when new clips arrive") or to the workflow's name is not a step change: return no \
    edits for it.
    Examples:
    steps: offload. "add a notification" -> add notify, automatic
    steps: offload, makeProxies, notify. "remove the proxies" -> remove makeProxies
    steps: offload, wait. "make the wait 30 minutes" -> update wait
    steps: offload, makeProxies. "make the proxies smaller" -> update makeProxies
    steps: findClips, resizeForSocial. "only 3 clips under 30 seconds" -> update findClips
    steps: offload, notify. "send one summary email" -> update notify
    steps: offload, makeProxies. "do the proxies before the offload" -> move makeProxies, before, relativeTo offload
    steps: offload, cleanup. "run every night at 2am" -> no edits
    steps: offload. "only run it on weekdays" -> no edits
    steps: offload, notify. "start it when the deck stops recording" -> no edits
    steps: offload, formatDrive. "only use Studio B" -> no edits
    """

    /// Applies a plain-language change to an existing workflow.
    static func edit(
        _ workflow: Workflow, request: String, context: TriggerContext = .empty
    ) async throws -> WorkflowDraftResult {
        if let reason = unavailableReason { throw WorkflowAssistantError.modelUnavailable(reason) }

        let current = workflow.steps.isEmpty
            ? "(no steps yet)"
            : workflow.steps.compactMap { DraftStepKind(step: $0)?.promptName }.joined(separator: ", ")
        let prompt = "Current steps: \(current)\nRequest: \(request)"

        let edits = try await AIModels.shared.generate(
            WorkflowEditDraft.self, instructions: editInstructions, prompt: prompt)
        let result = WorkflowEditBuilder.apply(edits, to: workflow, request: request, context: context)
        guard result.workflow.steps != workflow.steps
                || result.workflow.targets != workflow.targets
                || result.workflow.triggers != workflow.triggers
                || result.workflow.name != workflow.name else {
            throw WorkflowAssistantError.noChange
        }
        return result
    }

    static func draft(from request: String, context: TriggerContext = .empty) async throws -> WorkflowDraftResult {
        if let reason = unavailableReason { throw WorkflowAssistantError.modelUnavailable(reason) }

        let draft = try await AIModels.shared.generate(
            WorkflowDraft.self, instructions: instructions, prompt: request)
        let result = WorkflowDraftBuilder.build(from: draft, request: request, context: context)
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

@MainActor
extension DraftStepKind {
    /// The draft kind that describes an existing step, if there is one.
    init?(step: WorkflowStep) {
        switch step.action {
        case .controlDeck(let command, _): self = command == .start ? .startRecording : .stopRecording
        default:
            switch step.kind {
            case .wait:         self = .wait
            case .createFolder: self = .createFolder
            case .sync:         self = .offload
            case .convert:      self = .makeProxies
            case .rename:       self = .rename
            case .transcribe:   self = .transcribe
            case .findClips:    self = .findClips
            case .queueClips:   self = .queueClips
            case .writeCopy:    self = .writeCopy
            case .webhook:      self = .webhook
            case .copyTo:       self = .copyTo
            case .reframe:      self = .resizeForSocial
            case .format:       self = .formatDrive
            case .cleanup:      self = .cleanup
            case .notify:       self = .notify
            case .controlDeck, .upload, .triggerWorkflow: return nil
            }
        }
    }

    func matches(_ step: WorkflowStep) -> Bool { DraftStepKind(step: step) == self }

    var promptName: String {
        switch self {
        case .startRecording: return "startRecording"
        case .stopRecording:  return "stopRecording"
        case .wait:           return "wait"
        case .createFolder:   return "createFolder"
        case .offload:        return "offload"
        case .makeProxies:    return "makeProxies"
        case .rename:         return "rename"
        case .transcribe:     return "transcribe"
        case .findClips:      return "findClips"
        case .queueClips:     return "queueClips"
        case .writeCopy:      return "writeCopy"
        case .webhook:        return "webhook"
        case .copyTo:         return "copyTo"
        case .resizeForSocial: return "resizeForSocial"
        case .formatDrive:    return "formatDrive"
        case .cleanup:        return "cleanup"
        case .notify:         return "notify"
        }
    }
}
