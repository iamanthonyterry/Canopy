import Foundation

// MARK: - Settings stated in the request
// Layer one of deciding a step's settings: whatever the request says about
// *how* a step should run. Like the other details the assistant reads, these
// come from the user's own words — never from the model — and every value is
// clamped to what the step's editor allows. nil means "not stated", which
// leaves the step at its default (or at the efficiency choice below).

extension RequestDetails {
    // MARK: Make Proxies

    /// "small proxies", "high quality", "best quality", "balanced".
    var proxyPreset: ConversionSettings.FFmpegPreset? {
        if firstMatch(#"\b(?:best|highest|maximum)\s+quality\b"#) != nil { return .slow }
        if firstMatch(#"\bhigh(?:-|\s)?(?:quality|res(?:olution)?)\b|\bfull(?:-|\s)?(?:quality|res(?:olution)?)\b|\b(?:same|source)\s+resolution\b"#) != nil { return .medium }
        if firstMatch(#"\bbalanced\b"#) != nil { return .veryfast }
        if firstMatch(#"\b(?:small|smaller|tiny|lightweight|low(?:-|\s)?res(?:olution)?|lower\s+res(?:olution)?|quick|quickly|preview|rough|draft|dailies)\b|\bfast(?:est)?\s+(?:proxies|encode|convert\w*|export)"#) != nil { return .superfast }
        return nil
    }

    /// "two at a time", "one by one", "as fast as possible".
    var parallelJobs: Int? {
        if let m = firstMatch(#"\b(\d)\s+(?:at\s+a\s+time|at\s+once|in\s+parallel|parallel\s+jobs?|jobs?|simultaneous(?:ly)?|concurrent(?:ly)?)\b"#),
           let n = Int(m[0]) {
            return min(max(n, 1), 8)
        }
        if firstMatch(#"\bone\s+at\s+a\s+time\b|\bone\s+by\s+one\b|\bsequential(?:ly)?\b|\bserially\b|\bgentle\s+on\b|\bdon'?t\s+(?:slow|overload|hog)"#) != nil { return 1 }
        if firstMatch(#"\bas\s+fast\s+as\s+(?:possible|you\s+can)\b|\bfull\s+speed\b|\bmax(?:imum)?\s+speed\b|\ball\s+at\s+once\b|\bin\s+parallel\b"#) != nil { return 4 }
        return nil
    }

    /// "convert in place" / "put them in a separate Converted folder".
    var convertsInPlace: Bool? {
        if firstMatch(#"\bin\s+place\b|\bsame\s+folder\b|\bnext\s+to\s+the\s+originals?\b"#) != nil { return true }
        if firstMatch(#"\bconverted\s+folder\b|\bseparate\s+folder\b"#) != nil { return false }
        return nil
    }

    /// "keep the originals" — the opposite of `deletesOriginals`.
    var keepsOriginals: Bool {
        firstMatch(#"\bkeep\s+(?:the\s+)?originals?\b|\b(?:don'?t|do\s+not)\s+(?:delete|remove|replace)\s+(?:the\s+)?(?:originals?|source)\b|\bwithout\s+(?:deleting|removing)\b"#) != nil
    }

    // MARK: Transcribe

    private static let languages: [(pattern: String, locale: String)] = [
        ("british|uk english", "en-GB"), ("english", "en-US"), ("spanish", "es-ES"), ("french", "fr-FR"),
        ("german", "de-DE"), ("italian", "it-IT"), ("portuguese", "pt-BR"), ("japanese", "ja-JP"),
        ("korean", "ko-KR"), ("chinese|mandarin", "zh-CN"),
    ]

    /// "transcribe the Spanish interviews", "French audio". Only when the
    /// language is clearly the *spoken* one, so "subtitles in French" (a
    /// translation) isn't misread.
    var transcriptionLocale: String? {
        for (pattern, locale) in Self.languages {
            let spoken = #"\b(?:transcri\w*|spoken\s+in|speaking|recorded\s+in)\s+(?:\w+\s+){0,3}?(?:in\s+)?(?:\#(pattern))\b|\b(?:\#(pattern))\s+(?:audio|speech|interviews?|dialogue|dialog|footage|speakers?|narration|voice)\b"#
            if firstMatch(spoken) != nil { return locale }
        }
        return nil
    }

    /// "no subtitles", "just the transcript".
    var writesSRT: Bool? {
        firstMatch(#"\b(?:no|without)\s+(?:an?\s+)?(?:srt|subtitles?)\b|\btranscripts?\s+only\b|\bjust\s+the\s+transcripts?\b|\bjson\s+only\b"#) != nil ? false : nil
    }

    var skipsExistingTranscripts: Bool? {
        firstMatch(#"\bre-?transcribe\b|\btranscribe\s+(?:them\s+)?again\b|\bredo\s+the\s+transcripts?\b|\boverwrite\s+(?:the\s+)?transcripts?\b"#) != nil ? false : nil
    }

    // MARK: Find Clips

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]
    private static let numberPattern = #"\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten"#

    private func number(_ token: String) -> Int? { Int(token) ?? Self.numberWords[token] }

    /// "top 3 moments", "5 best clips".
    var clipCount: Int? {
        let np = Self.numberPattern
        let noUnit = #"(?!\s*(?:seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?|months?|%))"#
        if let m = firstMatch(#"\b(?:top|best|first|up\s+to|max(?:imum)?(?:\s+of)?)\s+(\#(np))\b\#(noUnit)"#), let n = number(m[0]) {
            return min(max(n, 1), 10)
        }
        if let m = firstMatch(#"\b(\#(np))\s+(?:(?:best|top|short|social|viral|good|key)\s+)*(?:clips?|moments?|highlights?|shorts|reels?|snippets?)\b"#),
           let n = number(m[0]) {
            return min(max(n, 1), 10)
        }
        return nil
    }

    /// "under 30 seconds", "between 15 and 45 seconds", "at least 20 seconds",
    /// "under a minute". Each end is nil unless stated; both are clamped to
    /// what the editor allows and kept in order.
    var clipLengths: (min: Int?, max: Int?) {
        var lo: Int?
        var hi: Int?
        let sec = #"(?:seconds?|secs?|s)\b"#
        if let m = firstMatch(#"\b(\d{1,3})\s*(?:-|–|to|and)\s*(\d{1,3})\s*\#(sec)"#),
           let a = Int(m[0]), let b = Int(m[1]), a < b {
            lo = a; hi = b
        }
        if hi == nil, let m = firstMatch(#"\b(?:under|less\s+than|shorter\s+than|no\s+longer\s+than|no\s+more\s+than|at\s+most|up\s+to|within|below|max(?:imum)?(?:\s+of)?)\s+(\d{1,3})\s*\#(sec)"#),
           let n = Int(m[0]) {
            hi = n
        }
        if hi == nil, firstMatch(#"\b(?:clip|short|reel|moment|highlight|snippet|post)"#) != nil,
           let m = firstMatch(#"\b(?:under|less\s+than|shorter\s+than|no\s+longer\s+than|at\s+most|up\s+to|within|max(?:imum)?(?:\s+of)?)\s+(a|one|1|2|two|3|three)\s+minutes?\b"#) {
            let minutes = ["a": 1, "one": 1, "1": 1, "2": 2, "two": 2, "3": 3, "three": 3][m[0]] ?? 1
            hi = minutes * 60
        }
        if lo == nil, let m = firstMatch(#"\b(?:at\s+least|longer\s+than|more\s+than|over|above|minimum(?:\s+of)?|min(?:imum)?|no\s+shorter\s+than)\s+(\d{1,3})\s*\#(sec)"#),
           let n = Int(m[0]) {
            lo = n
        }
        if let l = lo { lo = min(max(l, 10), 120) }
        if let h = hi { hi = min(max(h, 15), 180) }
        if let l = lo, let h = hi, l >= h { lo = max(10, h - 10) }
        return (lo, hi)
    }

    private static let clipKindPatterns: [(kind: ClipKind, pattern: String)] = [
        (.quotes, #"\bquot(?:es?|able)\b|\bone(?:-|\s)liners?\b|\bsound\s?bites?\b"#),
        // "Instagram stories" is a place to post, not a kind of moment.
        (.stories, #"(?<!instagram\s)(?<!facebook\s)(?<!ig\s)\b(?:stor(?:y|ies)|anecdotes?|testimon(?:y|ies))\b"#),
        (.teaching, #"\b(?:tips?|advice|lessons?|teaching|takeaways?|how(?:-|\s)to)\b"#),
        (.funny, #"\b(?:funny|funniest|jokes?|humou?r|laughs?|bloopers?)\b"#),
        (.emotional, #"\b(?:emotional|heartfelt|inspiring|inspirational|tear(?:-|\s)?jerk\w*)\b"#),
        (.music, #"\b(?:music|musical|songs?|singing|sung)\b"#),
    ]

    /// "find the speaker quotes", "just the songs and funny moments". nil
    /// when the request names no kind of moment.
    var clipFocus: ClipFocus? {
        let kinds = Self.clipKindPatterns.filter { firstMatch($0.pattern) != nil }.map(\.kind)
        return kinds.isEmpty ? nil : ClipFocus(kinds: kinds)
    }

    /// "ready to post", "burn in the captions" — wants finished, rendered
    /// posts rather than only the suggestions.
    var wantsFinishedPosts: Bool {
        mentions(["finished posts", "ready to post", "ready-to-post", "post-ready", "burn in", "burned in", "burned-in",
                  "captioned", "export the clips", "export the posts", "export posts", "render the clips", "render the posts"])
    }

    /// "without captions".
    var captionsOnPosts: Bool? {
        firstMatch(#"\b(?:no|without)\s+(?:burned(?:-|\s)?in\s+|burnt(?:-|\s)?in\s+)?captions?\b|\bdon'?t\s+burn\b"#) != nil ? false : nil
    }

    /// "scoring above 70", "only the best ones".
    var minClipScore: Int? {
        if let m = firstMatch(#"\b(?:scor\w*|rated|rating)\s+(?:of\s+|above\s+|over\s+|at\s+least\s+|higher\s+than\s+)?(\d{1,3})\b"#),
           let n = Int(m[0]) {
            return min(max((n + 2) / 5 * 5, 0), 100)
        }
        if let m = firstMatch(#"\babove\s+(\d{2,3})\b(?!\s*(?:seconds?|secs?|s\b|minutes?|mins?))"#), let n = Int(m[0]) {
            return min(max((n + 2) / 5 * 5, 0), 100)
        }
        if firstMatch(#"\bonly\s+the\s+(?:best|strongest|top|good)\b|\bbest\s+ones\s+only\b|\bhigh(?:-|\s)?scor"#) != nil { return 70 }
        return nil
    }

    // MARK: Social formats and copy

    /// The first social format the request names. "TikTok", "Reels", "9:16"
    /// → vertical; "4:5", "Instagram feed" → portrait; "square"; "YouTube
    /// video", "16:9" → landscape.
    var postFormat: SocialFormat? {
        let patterns: [(SocialFormat, String)] = [
            (.vertical, #"\b(?:vertical|9:16|tiktok|reels?|shorts|stories)\b"#),
            (.portrait, #"\b(?:4:5|portrait|instagram\s+feed|facebook\s+feed|instagram\s+posts?)\b"#),
            (.square, #"\b(?:square|1:1)\b"#),
            (.landscape, #"\b(?:landscape|16:9|horizontal|widescreen|youtube\s+video|linkedin\s+video)\b"#),
        ]
        var best: (SocialFormat, Int)?
        for (format, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: stepText, range: NSRange(stepText.startIndex..., in: stepText)) else { continue }
            if best == nil || match.range.location < best!.1 { best = (format, match.range.location) }
        }
        return best?.0
    }

    /// How many different social formats the request names.
    var postFormatCount: Int {
        let patterns = [#"\b(?:vertical|9:16|tiktok|reels?|shorts|stories)\b"#,
                        #"\b(?:4:5|portrait|instagram\s+feed|facebook\s+feed|instagram\s+posts?)\b"#,
                        #"\b(?:square|1:1)\b"#,
                        #"\b(?:landscape|16:9|horizontal|widescreen)\b"#]
        return patterns.filter { firstMatch($0) != nil }.count
    }

    /// "for TikTok" — only when exactly one platform is named.
    var copyPlatform: CopyPlatform? {
        let platforms: [(CopyPlatform, String)] = [
            (.tiktok, #"\btiktok\b"#),
            (.instagram, #"\b(?:instagram|reels?)\b"#),
            (.youtube, #"\b(?:youtube|shorts)\b"#),
            (.linkedin, #"\blinkedin\b"#),
        ]
        let named = platforms.filter { firstMatch($0.1) != nil }
        return named.count == 1 ? named[0].0 : nil
    }

    /// "3 hashtags", "no hashtags".
    var hashtagCount: Int? {
        if firstMatch(#"\b(?:no|without)\s+hashtags?\b"#) != nil { return 0 }
        if let m = firstMatch(#"\b(\d{1,2})\s+hashtags?\b"#), let n = Int(m[0]) { return min(max(n, 0), 10) }
        return nil
    }

    /// "center crop", "don't track the subject".
    var followsSubject: Bool? {
        if firstMatch(#"\bcent(?:er|re)(?:d|ed)?\s+crop\b|\bcent(?:er|re)(?:d|ed)\b|\b(?:don'?t|do\s+not|no|without)\s+track(?:ing)?\b|\bstatic\s+crop\b"#) != nil { return false }
        if firstMatch(#"\bfollow(?:s|ing)?\s+the\s+subject\b|\btrack(?:s|ing)?\s+(?:the\s+)?(?:subject|person|people|face)\b|\bkeep\s+the\s+subject\b"#) != nil { return true }
        return nil
    }

    // MARK: Copy To, Notification, Create Folder

    var copyVerifies: Bool? {
        firstMatch(#"\b(?:without|no|skip)\s+verif\w*\b|\bdon'?t\s+verify\b"#) != nil && mentions(["copy", "back up", "backup", "mirror", "second"]) ? false : nil
    }

    /// "just the videos", "without transcripts".
    var copyIncludesSidecars: Bool? {
        firstMatch(#"\bjust\s+the\s+(?:videos?|video\s+files|clips)\b|\b(?:videos?|video\s+files)\s+only\b|\bwithout\s+(?:the\s+)?(?:transcripts?|sidecars?)\b|\bno\s+sidecars?\b"#) != nil ? false : nil
    }

    /// "one summary email" vs "an email per drive".
    var notifiesPerDrive: Bool? {
        if firstMatch(#"\bone\s+(?:summary\s+)?(?:e-?mail|notification|message|summary)\b|\bsingle\s+(?:summary\s+)?(?:e-?mail|notification|message)\b|\bsummary\s+(?:e-?mail|notification)\b|\b(?:once|when)\s+(?:everything|all)\b|\bentire\s+workflow\b|\ball\s+(?:the\s+)?(?:drives|decks|cards)\s+(?:are\s+)?(?:done|finished)\b"#) != nil { return false }
        if firstMatch(#"\bper\s+(?:drive|deck|card|camera)\b|\beach\s+(?:drive|deck|card|camera)\b|\bfor\s+every\s+(?:drive|deck|card|camera)\b"#) != nil { return true }
        return nil
    }

    /// "a folder per camera", "each deck in its own subfolder".
    var groupsByDevice: Bool? {
        firstMatch(#"\b(?:per|each|every|by)\s+(?:camera|deck|drive|device|card)\b|\b(?:own|separate)\s+(?:sub)?folders?\b|\bsub-?folders?\s+(?:for|per)\s+(?:each|every)\b"#) != nil ? true : nil
    }

    // MARK: Whole-workflow

    /// "make it faster", "optimize this".
    var wantsOptimization: Bool {
        mentions(["faster", "more efficient", "efficient", "optimi", "speed up", "speed it up", "streamline", "quicker", "make it quick"])
    }

    // MARK: helpers

    func firstMatch(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stepText, range: NSRange(stepText.startIndex..., in: stepText)) else { return nil }
        return (1..<max(match.numberOfRanges, 1)).map { i in
            Range(match.range(at: i), in: stepText).map { String(stepText[$0]) } ?? ""
        }
    }
}

// MARK: - Efficiency
// Layer two: choices that make the workflow cheaper to run without changing
// what it produces, made from the workflow's own shape and this Mac. Nothing
// here deletes, overwrites or lowers the quality of an output — those only
// ever come from the request.

enum WorkflowEfficiency {
    /// Encodes per device. A global limiter caps the total across devices, so
    /// raising this can't oversubscribe the machine — it only keeps a single
    /// deck from leaving cores idle.
    static var parallelJobs: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return cores >= 12 ? 4 : cores >= 8 ? 3 : 2
    }

    /// With more than one deck, a clip name can repeat across decks, and a
    /// run is one email per deck unless told otherwise.
    static func hasSeveralDecks(_ context: TriggerContext) -> Bool { context.decks.count > 1 }

    /// Things a workflow's layout costs it that the user may not realise.
    /// Advice only — it never rearranges a workflow they built.
    static func advisories(for steps: [WorkflowStep]) -> [String] {
        var notes: [String] = []
        if let s = steps.firstIndex(where: { $0.kind == .sync }),
           let c = steps.firstIndex(where: { $0.kind == .convert }), c > s {
            if c != s + 1 {
                notes.append("Offload and Make Proxies aren't next to each other, so proxies wait for every download to finish instead of starting as each file lands.")
            } else if steps[s].requiresConfirmation || steps[c].requiresConfirmation {
                notes.append("A confirmation on Offload or Make Proxies stops the two from overlapping — proxies only start after the pause.")
            }
        }
        if steps.contains(where: { $0.kind == .findClips }),
           let t = steps.first(where: { $0.kind == .transcribe }),
           case .transcribe(_, let writeSRT, _, _) = t.action, !writeSRT {
            notes.append("Find Clips transcribes any clip that has no transcript, so the Transcribe step is only needed if you want the transcripts for other uses.")
        }
        return notes
    }

    /// "Make it faster": raises settings that are leaving speed or effort on
    /// the table. Returns what it changed.
    static func optimize(_ workflow: inout Workflow, context: TriggerContext) -> [String] {
        var changes: [String] = []
        let jobs = parallelJobs
        for i in workflow.steps.indices {
            switch workflow.steps[i].action {
            case .convert(let preset, let delete, let current, let inPlace) where current < jobs:
                workflow.steps[i].action = .convert(preset: preset, deleteOriginal: delete, maxParallelJobs: jobs, convertInPlace: inPlace)
                changes.append("Make Proxies now runs \(jobs) at a time (was \(current))")
            case .transcribe(let locale, let srt, false, let deleteWhenDone):
                workflow.steps[i].action = .transcribe(locale: locale, writeSRT: srt, skipExisting: true, deleteWhenDone: deleteWhenDone)
                changes.append("Transcribe now skips clips that already have a transcript")
            case .notify(let header, let message, let recipients, true) where hasSeveralDecks(context):
                workflow.steps[i].action = .notify(header: header, message: message, recipients: recipients, sendPerDrive: false)
                changes.append("Notification sends one summary instead of one per drive")
            case .createFolder(let store, let path, let name, false) where hasSeveralDecks(context):
                workflow.steps[i].action = .createFolder(cloudStoreID: store, parentPath: path, nameTemplate: name, groupByDevice: true)
                changes.append("Create Folder keeps each deck's clips in its own subfolder")
            default:
                break
            }
        }
        return changes
    }
}
