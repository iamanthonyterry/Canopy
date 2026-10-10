import Foundation

// MARK: - Context
// What the assistant knows about the user's setup, so a request like "when
// Studio A stops recording" or "after Card Ingest finishes" can be pointed at
// a real deck or workflow. Matching is by name, in the user's own words — the
// model never picks an ID.

struct TriggerContext {
    struct Item: Hashable {
        var id: UUID
        var name: String
    }

    var decks: [Item] = []
    var folders: [Item] = []
    var workflows: [Item] = []
    /// Workflows that can't start this one: itself, and any workflow it
    /// already triggers (so the two can't be wired to each other forever).
    var ineligibleWorkflowIDs: Set<UUID> = []

    static let empty = TriggerContext()

    init(decks: [Item] = [], folders: [Item] = [], workflows: [Item] = [], ineligibleWorkflowIDs: Set<UUID> = []) {
        self.decks = decks
        self.folders = folders
        self.workflows = workflows
        self.ineligibleWorkflowIDs = ineligibleWorkflowIDs
    }

    /// `workflowID` is the workflow being edited, nil when building a new one.
    init(appState: AppState, workflowID: UUID? = nil) {
        decks = appState.hyperDecks.sorted { $0.sortOrder < $1.sortOrder }.map { Item(id: $0.id, name: $0.name) }
        folders = appState.localFolders.sorted { $0.sortOrder < $1.sortOrder }.map { Item(id: $0.id, name: $0.name) }
        workflows = appState.workflows.sorted { $0.sortOrder < $1.sortOrder }.map { Item(id: $0.id, name: $0.name) }
        var blocked: Set<UUID> = []
        if let workflowID {
            blocked.insert(workflowID)
            for candidate in appState.workflows where candidate.triggers.contains(where: {
                $0.mode == .workflowFinished && $0.sourceWorkflowID == workflowID
            }) {
                blocked.insert(candidate.id)
            }
        }
        ineligibleWorkflowIDs = blocked
    }

    /// "When Studio A stops recording" — a one-line description of a trigger.
    func describe(_ trigger: ScheduleSettings) -> String {
        func deck() -> String { decks.first { $0.id == trigger.deviceID }?.name ?? "any deck" }
        switch trigger.mode {
        case .daily:
            let days = trigger.activeWeekdays
            let when: String
            if days.count == 7 {
                when = "every day"
            } else if days == [.monday, .tuesday, .wednesday, .thursday, .friday] {
                when = "on weekdays"
            } else if days == [.saturday, .sunday] {
                when = "on weekends"
            } else {
                when = "on " + Weekday.allCases.filter { days.contains($0) }.map(\.fullLabel).joined(separator: ", ")
            }
            return "\(when) at \(trigger.displayTime)"
        case .oneTime:
            return "once on \(trigger.displayOneTimeDate)"
        case .recordingStopped:
            return "when \(deck()) stops recording"
        case .deviceOnline:
            return "when \(deck()) comes online"
        case .workflowFinished:
            let name = workflows.first { $0.id == trigger.sourceWorkflowID }?.name ?? "a workflow"
            let condition: String
            switch trigger.finishCondition {
            case .any:           condition = ""
            case .withoutErrors: condition = " without errors"
            case .withErrors:    condition = " with errors"
            }
            return "when \(name) finishes\(condition)"
        case .folderChanged:
            let name = folders.first { $0.id == trigger.deviceID }?.name ?? "a folder"
            return "when new clips arrive in \(name)"
        }
    }
}

// MARK: - What the request says about when it runs

struct TriggerIntent {
    /// Clock time for a recurring run ("every night at 2am").
    var daily: (hour: Int, minute: Int)?
    /// Days of the week a recurring run is limited to. Empty = not stated.
    var weekdays: Set<Weekday> = []
    /// A single moment ("tomorrow at 9am", "in 2 hours").
    var oneTime: Date?
    /// Fully formed event triggers, matched to the user's decks, folders and workflows.
    var events: [ScheduleSettings] = []
    /// Things the user still has to fill in or should know about.
    var notes: [String] = []

    var isEmpty: Bool { daily == nil && weekdays.isEmpty && oneTime == nil && events.isEmpty }

    /// Weekday selection to store: all seven days is the same as "every day".
    var storedWeekdays: Set<Weekday> { weekdays.count == 7 ? [] : weekdays }

    /// The triggers a brand-new workflow gets.
    func newTriggers() -> [ScheduleSettings] {
        var triggers: [ScheduleSettings] = []
        if let daily {
            var trigger = ScheduleSettings()
            trigger.isEnabled = true
            trigger.mode = .daily
            trigger.hour = daily.hour
            trigger.minute = daily.minute
            trigger.repeatDaily = true
            trigger.selectedWeekdays = storedWeekdays
            triggers.append(trigger)
        }
        if let oneTime {
            var trigger = ScheduleSettings()
            trigger.isEnabled = true
            trigger.mode = .oneTime
            trigger.oneTimeDate = oneTime
            triggers.append(trigger)
        }
        triggers += events
        return triggers
    }
}

// MARK: - Parser
// Like every other detail the assistant reads, triggers come from the user's
// words rather than the model: a small model invents plausible-looking
// schedules, and a trigger that fires when nobody asked for it runs real work.

enum WorkflowTriggerParser {
    struct Parsed {
        var intent: TriggerIntent
        /// The request with its trigger phrasing blanked out, so "when the
        /// deck stops recording" doesn't read as a Stop Recording step and
        /// "after Card Ingest finishes" doesn't read as an Offload step.
        /// Same length as the lowercased request.
        var stepText: String
    }

    static func parse(_ request: String, context: TriggerContext, now: Date, calendar: Calendar = .current) -> Parsed {
        let text = request.lowercased()
        var blanked: [NSRange] = []
        var intent = TriggerIntent()

        let recurring = isRecurring(text)

        // MARK: Clock and days
        let time = clockTime(in: text)
        if recurring {
            intent.weekdays = weekdays(in: text)
            if let time { intent.daily = time }
        }

        if !recurring {
            let (day, spans) = oneTimeDay(in: text, now: now, calendar: calendar)
            blanked += spans
            switch day {
            case .exact(let date):
                intent.oneTime = date
            case .day(let start, let explicit):
                if let time,
                   let date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: start) {
                    if date > now {
                        intent.oneTime = date
                    } else {
                        intent.notes.append("That time has already passed, so I didn't schedule a one-time run.")
                    }
                } else if hasBareClockTime(in: text) || !explicit {
                    // AM/PM trouble is surfaced by `RequestDetails.ambiguousTime`
                } else {
                    intent.notes.append("Say what time the one-time run should start — I left it unscheduled.")
                }
            case nil:
                break
            }
        }

        // MARK: Events
        parseRecordingStopped(text, context: context, into: &intent, blanked: &blanked)
        parseDeviceOnline(text, context: context, into: &intent, blanked: &blanked)
        parseWorkflowFinished(text, context: context, into: &intent, blanked: &blanked)
        parseFolderChanged(text, context: context, into: &intent, blanked: &blanked)

        return Parsed(intent: intent, stepText: blank(blanked, in: text))
    }

    // MARK: Clock time

    /// "at 2am", "at 6:30 pm", "at noon", or a bare "9pm". A bare hour is read
    /// from the time of day mentioned ("morning" → AM, "evening" → PM) and is
    /// otherwise left unresolved rather than guessed.
    static func clockTime(in text: String) -> (hour: Int, minute: Int)? {
        if let m = capture(#"\bat\s+(noon|midnight)\b"#, in: text) {
            return m[0] == "noon" ? (12, 0) : (0, 0)
        }
        let m = capture(#"\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?"#, in: text)
            ?? capture(#"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)(?![a-z])"#, in: text)
        guard let m, var hour = Int(m[0]), (0...23).contains(hour) else { return nil }
        let minute = min(Int(m[1]) ?? 0, 59)
        let has = { (words: [String]) in words.contains { text.contains($0) } }
        if m[2].hasPrefix("p") {
            if hour < 12 { hour += 12 }
        } else if m[2].hasPrefix("a") {
            if hour == 12 { hour = 0 }
        } else if hour > 12 || m[1] != "" && hour == 0 {
            // already 24-hour
        } else if has(["morning"]) {
            if hour == 12 { hour = 0 }
        } else if has(["afternoon", "evening"]) {
            if hour < 12 { hour += 12 }
        } else if has(["night", "nightly"]) {
            hour = hour >= 6 && hour <= 11 ? hour + 12 : (hour == 12 ? 0 : hour)
        } else {
            return nil
        }
        return (hour, minute)
    }

    /// A clock time is written ("at 7") but couldn't be pinned to AM or PM.
    static func hasBareClockTime(in text: String) -> Bool {
        capture(#"\bat\s+\d{1,2}(?::\d{2})?\b"#, in: text) != nil
    }

    // MARK: Recurrence and weekdays

    private static let dayPattern = #"(?:sunday|sun|monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat)"#

    static func isRecurring(_ text: String) -> Bool {
        if capture(#"\b(?:every|each|daily|nightly|nights|mornings|weekdays|weekends)\b"#, in: text) != nil { return true }
        // "on Mondays" — a plural day name is a recurrence on its own.
        return capture(#"\b(?:sundays|mondays|tuesdays|wednesdays|thursdays|fridays|saturdays)\b"#, in: text) != nil
    }

    private static let weekdayByName: [String: Weekday] = [
        "sunday": .sunday, "sun": .sunday,
        "monday": .monday, "mon": .monday,
        "tuesday": .tuesday, "tues": .tuesday, "tue": .tuesday,
        "wednesday": .wednesday, "wed": .wednesday,
        "thursday": .thursday, "thurs": .thursday, "thur": .thursday, "thu": .thursday,
        "friday": .friday, "fri": .friday,
        "saturday": .saturday, "sat": .saturday,
    ]

    /// The days a request limits a recurring run to. A bare day name only
    /// counts when something marks it as a day ("on", "every", "only", a
    /// plural, or a time of day after it) — so "call it Friday Ingest" doesn't
    /// schedule the workflow for Fridays.
    static func weekdays(in text: String) -> Set<Weekday> {
        var days: Set<Weekday> = []
        if capture(#"\b(?:weekdays?|week\s?days?|business\s+days?|work\s?days?)\b"#, in: text) != nil {
            days.formUnion([.monday, .tuesday, .wednesday, .thursday, .friday])
        }
        if capture(#"\b(?:weekends|every\s+weekend|each\s+weekend|on\s+weekends?)\b"#, in: text) != nil {
            days.formUnion([.saturday, .sunday])
        }

        let group = #"(?:\#(dayPattern))s?(?:\s*(?:,|and|&|or|through|thru|to|until|-)\s*(?:\#(dayPattern))s?)*"#
        guard let regex = try? NSRegularExpression(pattern: #"(?:(\b[a-z]+)\s+)?\b(\#(group))\b(\s+(?:morning|afternoon|evening|night)|\s+at\s+\d)?"#) else { return days }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let list = ns.substring(with: match.range(at: 2))
            let before = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            let plural = list.range(of: #"days\b"#, options: .regularExpression) != nil
            let marked = ["on", "every", "each", "next", "this", "only", "just", "from", "and", "or"].contains(before)
            let timed = match.range(at: 3).location != NSNotFound
            guard plural || marked || timed else { continue }
            days.formUnion(daySet(in: list))
        }
        return days
    }

    /// "monday through friday" → Mon…Fri, "mon, wed and fri" → those three.
    private static func daySet(in list: String) -> Set<Weekday> {
        let tokens = list.split(whereSeparator: { !$0.isLetter }).map(String.init)
        var days: [Weekday] = []
        var rangeFollows = false
        var set: Set<Weekday> = []
        for token in tokens {
            let name = token.hasSuffix("s") && weekdayByName[token] == nil ? String(token.dropLast()) : token
            if ["through", "thru", "to", "until"].contains(name) { rangeFollows = true; continue }
            guard let day = weekdayByName[name] else { continue }
            if rangeFollows, let start = days.last {
                var d = start.rawValue
                while d != day.rawValue {
                    d = d % 7 + 1
                    if let w = Weekday(rawValue: d) { set.insert(w) }
                }
                rangeFollows = false
            }
            set.insert(day)
            days.append(day)
        }
        // A "-" range survives the tokeniser as two adjacent names; read it
        // from the text itself.
        if list.contains("-"), let first = days.first, let last = days.last, days.count == 2 {
            var d = first.rawValue
            while d != last.rawValue {
                d = d % 7 + 1
                if let w = Weekday(rawValue: d) { set.insert(w) }
            }
        }
        return set
    }

    // MARK: One-time

    enum OneTimeDay {
        /// `explicit` is false for cues that are often just wording ("today's
        /// clips", a bare day name), where a missing time shouldn't nag.
        case day(Date, explicit: Bool)
        case exact(Date)
    }

    private static let monthNumbers: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// The calendar day a one-time run is meant for, or an exact moment for
    /// "in 2 hours". Never invents a day: with none stated, returns nil.
    private static func oneTimeDay(in text: String, now: Date, calendar: Calendar) -> (OneTimeDay?, [NSRange]) {
        let today = calendar.startOfDay(for: now)

        // "run this in 2 hours" — but not "stop recording in 45 minutes".
        if let (m, range) = captureWithRange(
            #"\b(?:run|start|begin|fire|kick\s+off|trigger)\b(?:\s+(?!stop|wait|pause|delay|after|for\b)\w+){0,4}?\s+(in\s+(\d+)\s*(minutes?|mins?|hours?|hrs?|days?|weeks?))\b"#, in: text),
           let n = Int(m[1]), n > 0 {
            let unit = m[2]
            let seconds: Double = unit.hasPrefix("w") ? 604_800 : unit.hasPrefix("d") ? 86_400 : unit.hasPrefix("h") ? 3_600 : 60
            return (.exact(now.addingTimeInterval(Double(n) * seconds)), [range])
        }

        if text.contains("tomorrow") {
            return (calendar.date(byAdding: .day, value: 1, to: today).map { .day($0, explicit: true) }, [])
        }
        if capture(#"\b(today|tonight|this\s+(?:morning|afternoon|evening))\b(?!['’]s)"#, in: text) != nil {
            return (.day(today, explicit: false), [])
        }
        if let m = capture(#"\bnext\s+(\#(dayPattern))\b"#, in: text), let day = weekdayByName[m[0]] {
            return (nextDay(day, after: today, calendar: calendar, includingToday: false).map { .day($0, explicit: true) }, [])
        }
        if let m = capture(#"\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b"#, in: text),
           let month = monthNumbers[String(m[0].prefix(3))], let day = Int(m[1]), (1...31).contains(day) {
            return (nextDate(month: month, day: day, from: today, calendar: calendar).map { .day($0, explicit: true) }, [])
        }
        if let m = capture(#"\b(\d{1,2})/(\d{1,2})\b"#, in: text),
           let month = Int(m[0]), let day = Int(m[1]), (1...12).contains(month), (1...31).contains(day) {
            return (nextDate(month: month, day: day, from: today, calendar: calendar).map { .day($0, explicit: true) }, [])
        }
        // "on friday at 5pm" / "friday morning" — a single day name, no recurrence.
        let days = weekdays(in: text)
        if days.count == 1, let day = days.first {
            return (nextDay(day, after: today, calendar: calendar, includingToday: true).map { .day($0, explicit: false) }, [])
        }
        return (nil, [])
    }

    private static func nextDay(_ weekday: Weekday, after today: Date, calendar: Calendar, includingToday: Bool) -> Date? {
        let start = includingToday ? 0 : 1
        for offset in start..<(start + 7) {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            if calendar.component(.weekday, from: candidate) == weekday.rawValue { return candidate }
        }
        return nil
    }

    private static func nextDate(month: Int, day: Int, from today: Date, calendar: Calendar) -> Date? {
        let year = calendar.component(.year, from: today)
        for y in [year, year + 1] {
            var parts = DateComponents()
            parts.year = y; parts.month = month; parts.day = day
            guard let date = calendar.date(from: parts),
                  calendar.component(.month, from: date) == month else { continue }
            if date >= today { return date }
        }
        return nil
    }

    // MARK: Events

    private static func parseRecordingStopped(_ text: String, context: TriggerContext, into intent: inout TriggerIntent, blanked: inout [NSRange]) {
        let cues = [
            #"\b(?:recordings?|takes?)\s+(?:stops?|stopped|ends?|ended|finish(?:es|ed)?|completes?|completed|is\s+(?:done|over|finished))"#,
            #"\b(?:stops?|stopped|finish(?:es|ed)?|ends?|ended)\s+recording\b"#,
            #"\bafter\s+(?:each|every|any)\s+(?:recording|take)\b"#,
        ]
        let spans = cues.flatMap { ranges(of: $0, in: text) }
        guard !spans.isEmpty else { return }
        blanked += spans
        addDeckEvents(.recordingStopped, text: text, context: context, into: &intent)
    }

    private static func parseDeviceOnline(_ text: String, context: TriggerContext, into intent: inout TriggerIntent, blanked: inout [NSRange]) {
        let cues = [
            #"\b(?:comes?|came|is|gets?|goes?)\s+(?:back\s+)?online\b"#,
            #"\bback\s+online\b"#,
            #"\b(?:reconnects?|reconnected)\b"#,
            #"\b(?:plugged|plug|plugs)\s+in\b"#,
            #"\bpowers?\s+on\b"#,
        ]
        let spans = cues.flatMap { ranges(of: $0, in: text) }
        guard !spans.isEmpty else { return }
        blanked += spans
        addDeckEvents(.deviceOnline, text: text, context: context, into: &intent)
    }

    /// One trigger per deck named in the request, or "any deck" when none is.
    private static func addDeckEvents(_ mode: ScheduleMode, text: String, context: TriggerContext, into intent: inout TriggerIntent) {
        let named = context.decks.filter { containsName($0.name, in: text) }
        let targets: [UUID?] = named.isEmpty ? [nil] : named.map { Optional($0.id) }
        for id in targets {
            var trigger = ScheduleSettings()
            trigger.isEnabled = true
            trigger.mode = mode
            trigger.deviceID = id
            intent.events.append(trigger)
        }
    }

    private static func parseWorkflowFinished(_ text: String, context: TriggerContext, into intent: inout TriggerIntent, blanked: inout [NSRange]) {
        let verbs = #"(?:finish(?:es|ed)?|complete(?:s|d)?|is\s+(?:done|finished|complete)|has\s+(?:finished|completed|run)|ends?|runs?|ran|succeeds?|fail(?:s|ed)?)"#
        var found = false
        var unmatched = false

        for workflow in context.workflows.sorted(by: { $0.name.count > $1.name.count }) {
            let name = NSRegularExpression.escapedPattern(for: workflow.name.lowercased())
            let pattern = #"\b(?:after|when|once|whenever|as\s+soon\s+as|every\s+time)\s+(?:the\s+|my\s+)?["“']?\#(name)["”']?(?:\s+workflow)?\s+\#(verbs)\b"#
            let spans = ranges(of: pattern, in: text)
            guard !spans.isEmpty else { continue }
            found = true
            blanked += spans
            guard !context.ineligibleWorkflowIDs.contains(workflow.id) else {
                intent.notes.append("\(workflow.name) can't start this workflow — that would make them trigger each other, so I left it out.")
                continue
            }
            var trigger = ScheduleSettings()
            trigger.isEnabled = true
            trigger.mode = .workflowFinished
            trigger.sourceWorkflowID = workflow.id
            trigger.finishCondition = finishCondition(in: text)
            if !intent.events.contains(where: { $0.mode == .workflowFinished && $0.sourceWorkflowID == workflow.id }) {
                intent.events.append(trigger)
            }
        }

        if !found {
            // "after the workflow finishes" with no name we recognise.
            let generic = #"\b(?:after|when|once)\s+(?:the\s+|my\s+|another\s+|a\s+)(?:other\s+|previous\s+|first\s+)?workflow\s+\#(verbs)\b"#
            let spans = ranges(of: generic, in: text)
            if !spans.isEmpty {
                blanked += spans
                unmatched = true
            }
        }
        if unmatched {
            intent.notes.append("Couldn't tell which workflow should start this one — add it under Starts when.")
        }
    }

    private static func finishCondition(in text: String) -> WorkflowFinishCondition {
        let clean = ["without errors", "without any errors", "no errors", "successfully", "succeeds", "succeeded", "cleanly", "without problems", "without issues"]
        if clean.contains(where: { text.contains($0) }) { return .withoutErrors }
        let failed = ["fails", "failed", "has errors", "had errors", "with errors", "hits an error", "errors out", "if it errors"]
        if failed.contains(where: { text.contains($0) }) { return .withErrors }
        return .any
    }

    private static func parseFolderChanged(_ text: String, context: TriggerContext, into intent: inout TriggerIntent, blanked: inout [NSRange]) {
        guard !context.folders.isEmpty else {
            // Still blank the cue so it isn't read as an Offload.
            let spans = ranges(of: arrivalCue(), in: text)
            if !spans.isEmpty, text.contains("folder") {
                blanked += spans
                intent.notes.append("Add a Local Folder in Devices first, then choose it under Starts when.")
            }
            return
        }

        let verb = arrivalCue()
        let lead = Self.leadWords
        var matched: [TriggerContext.Item] = []
        for folder in context.folders {
            let name = NSRegularExpression.escapedPattern(for: folder.name.lowercased())
            let after = #"\#(verb)(?:\s+(?:in|into|on|at|to|inside))?(?:\s+(?:the|my))?\s+["“']?\#(name)(?![a-z0-9])"#
            let before = #"\#(lead)\s+(?:the\s+|my\s+)?["“']?\#(name)["”']?(?:\s+folder)?\s+(?:gets|receives|has|got)\s+new\s+(?:clips?|files?|footage|media|videos?)"#
            let spans = ranges(of: after, in: text) + ranges(of: before, in: text)
            guard !spans.isEmpty else { continue }
            blanked += spans
            matched.append(folder)
        }

        if matched.isEmpty {
            // A cue and the word "folder" but no name: with exactly one Local
            // Folder there's only one thing it can mean.
            let spans = ranges(of: verb, in: text)
            guard !spans.isEmpty, text.contains("folder") else { return }
            blanked += spans
            if context.folders.count == 1 {
                matched = context.folders
            } else {
                intent.notes.append("Couldn't tell which folder to watch — choose it under Starts when.")
                return
            }
        }

        for folder in matched {
            var trigger = ScheduleSettings()
            trigger.isEnabled = true
            trigger.mode = .folderChanged
            trigger.deviceID = folder.id
            intent.events.append(trigger)
        }
    }

    private static let leadWords = #"\b(?:when|whenever|once|as\s+soon\s+as|every\s+time)\b"#

    /// "when new clips arrive", "once a file lands", "whenever something is
    /// added"… The lead word is required so "the footage is copied to the
    /// folder" describing a step can't be read as a trigger.
    private static func arrivalCue() -> String {
        #"\#(leadWords)\s+(?:[a-z0-9"“'-]+\s+){0,4}?(?:(?:new\s+)?(?:clips?|files?|footage|media|videos?|recordings?|anything|something)\s+)?(?:arrives?|lands?|shows?\s+up|appears?|(?:is|are)\s+(?:added|dropped|copied|saved))\b"#
    }

    // MARK: Regex helpers

    private static func capture(_ pattern: String, in text: String) -> [String]? {
        captureWithRange(pattern, in: text)?.0
    }

    private static func captureWithRange(_ pattern: String, in text: String) -> ([String], NSRange)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let groups = (1..<max(match.numberOfRanges, 1)).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
        return (groups, match.range(at: match.numberOfRanges > 1 ? 1 : 0))
    }

    private static func ranges(of pattern: String, in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    private static func containsName(_ name: String, in text: String) -> Bool {
        let pattern = #"(?<![a-z0-9])\#(NSRegularExpression.escapedPattern(for: name.lowercased()))(?![a-z0-9])"#
        return !ranges(of: pattern, in: text).isEmpty
    }

    private static func blank(_ spans: [NSRange], in text: String) -> String {
        guard !spans.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for span in spans where span.location != NSNotFound && NSMaxRange(span) <= result.length {
            result.replaceCharacters(in: span, with: String(repeating: " ", count: span.length))
        }
        return result as String
    }
}
