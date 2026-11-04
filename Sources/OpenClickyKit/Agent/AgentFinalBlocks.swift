import Foundation

/// Tagged blocks an agent may add to its final message next to the `<report>` block:
///
///     <answer>{"outcome": "...", "numbers": [...]}</answer>       a structured result card
///     <routine>{"action": "create", ...}</routine>               set up or change a routine (asks the user first)
///     <wait_for>{"step": "...", "page": "..."}</wait_for>         a step only the user can do; the job waits for it
///     <learned>Topic: what worked</learned>                      up to three how-tos about the user's own setup
///
/// Tags are matched in any case with optional spaces (`< ANSWER >`, `</Wait_For>`); a block whose closing tag is missing
/// runs to the next block or `<report>`. Each block is checked on its own: a malformed one is dropped with a note in
/// `problems` and never takes the rest of the message down with it. Everything outside the blocks is `remainder`.
/// A tag the agent only mentions stays text: one inside a fenced code block, and an unclosed WAIT_FOR without JSON or
/// an unclosed LEARNED (prose like "no <wait_for> step is needed" would otherwise become a step or saved how-tos).
public struct AgentFinalBlocks: Sendable, Hashable {
    public var answer: AgentAnswer?
    public var routines: [AgentRoutineRequest] = []
    public var waitFor: AgentUserStep?
    public var learned: [AgentLearnedHowTo] = []
    /// Why a block was dropped ("ANSWER: not valid JSON").
    public var problems: [String] = []
    /// The message without the blocks.
    public var remainder: String = ""

    public static let tags = ["ANSWER", "ROUTINE", "WAIT_FOR", "LEARNED"]

    private static let tagPattern = try! NSRegularExpression(
        pattern: #"<\s*(/?)\s*(ANSWER|ROUTINE|WAIT_FOR|LEARNED)\s*>"#, options: [.caseInsensitive])
    private static let reportOpen = try! NSRegularExpression(pattern: #"<\s*report\s*>"#, options: [.caseInsensitive])
    private static let fenceLine = try! NSRegularExpression(pattern: #"^[ \t]*```[A-Za-z0-9_+.-]*[ \t]*$"#, options: [.anchorsMatchLines])

    /// The fenced code blocks in `text` (an unclosed fence runs to the end).
    static func fencedRanges(in text: String) -> [NSRange] {
        let length = (text as NSString).length
        let fences = fenceLine.matches(in: text, range: NSRange(location: 0, length: length))
        var ranges: [NSRange] = []
        var index = 0
        while index < fences.count {
            let start = fences[index].range.location
            let end = index + 1 < fences.count ? fences[index + 1].range.location + fences[index + 1].range.length : length
            ranges.append(NSRange(location: start, length: end - start))
            index += 2
        }
        return ranges
    }

    public static func extract(_ text: String, now: Date = Date()) -> AgentFinalBlocks {
        var result = AgentFinalBlocks()
        let ns = text as NSString
        let fenced = fencedRanges(in: text)
        let matches = tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { match in
            !fenced.contains { NSLocationInRange(match.range.location, $0) }
        }
        guard !matches.isEmpty else {
            result.remainder = text
            return result
        }
        var remainder = ""
        var cursor = 0
        var index = 0
        while index < matches.count {
            let match = matches[index]
            let isClose = match.range(at: 1).length > 0
            let name = ns.substring(with: match.range(at: 2)).uppercased()
            if isClose {
                // A stray closing tag: drop it, keep the text around it.
                remainder += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                cursor = match.range.location + match.range.length
                index += 1
                continue
            }
            remainder += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let contentStart = match.range.location + match.range.length
            // The matching close, or else the next opening block tag (or <report>), or the end.
            var contentEnd = ns.length
            var next = index + 1
            var afterBlock = ns.length
            var closed = false
            while next < matches.count {
                let candidate = matches[next]
                let candidateClose = candidate.range(at: 1).length > 0
                let candidateName = ns.substring(with: candidate.range(at: 2)).uppercased()
                if candidateClose, candidateName == name {
                    contentEnd = candidate.range.location
                    afterBlock = candidate.range.location + candidate.range.length
                    closed = true
                    next += 1
                    break
                }
                if !candidateClose {
                    contentEnd = candidate.range.location
                    afterBlock = candidate.range.location
                    break
                }
                next += 1
            }
            if next >= matches.count, contentEnd == ns.length {
                // Unclosed and last: stop at a <report> block if one follows.
                let tail = NSRange(location: contentStart, length: ns.length - contentStart)
                if let report = reportOpen.firstMatch(in: text, range: tail) {
                    contentEnd = report.range.location
                    afterBlock = report.range.location
                }
            }
            let content = ns.substring(with: NSRange(location: contentStart, length: max(0, contentEnd - contentStart)))
            if !closed, name == "LEARNED" || (name == "WAIT_FOR" && !content.contains("{")) {
                // A tag mentioned in prose: keep it and the text after it.
                remainder += ns.substring(with: match.range)
                cursor = contentStart
                index += 1
                continue
            }
            result.take(name, content, now: now)
            cursor = afterBlock
            index = next
            // Skip matches the block consumed.
            while index < matches.count, matches[index].range.location < cursor { index += 1 }
        }
        if cursor < ns.length { remainder += ns.substring(from: cursor) }
        result.remainder = remainder
        return result
    }

    private mutating func take(_ name: String, _ content: String, now: Date) {
        do {
            switch name {
            case "ANSWER":
                if answer != nil { problems.append("ANSWER: only the first block is used") ; return }
                answer = try AgentAnswer.parse(content)
            case "ROUTINE":
                routines.append(try AgentRoutineRequest.parse(content))
            case "WAIT_FOR":
                if waitFor != nil { problems.append("WAIT_FOR: only the first block is used"); return }
                waitFor = try AgentUserStep.parse(content, now: now)
            case "LEARNED":
                let (items, dropped) = AgentLearnedHowTo.parse(content)
                learned = Array((learned + items).prefix(AgentLearnedHowTo.maxPerReport))
                if dropped > 0 { problems.append("LEARNED: \(dropped) line(s) without \"Topic: what worked\" dropped") }
            default:
                break
            }
        } catch {
            problems.append("\(name): \(error)")
        }
    }

    /// The JSON inside a block: code fences and stray text around the object removed.
    static func jsonObject(_ content: String) throws -> JSONValue {
        var body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let end = body.range(of: "```", options: .backwards) { body = String(body[..<end.lowerBound]) }
        }
        guard let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end else {
            throw AgentBlockError("no JSON object")
        }
        guard let value = try? JSONValue.parse(String(body[start...end])), value.objectValue != nil else {
            throw AgentBlockError("not valid JSON")
        }
        return value
    }
}

public struct AgentBlockError: Error, CustomStringConvertible, Hashable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - ANSWER

/// A structured answer the result card lays out: a one-line outcome plus up to two blocks (numbers, a short list,
/// receipts for what was done, a draft to copy, or two or three choices to ask). Lengths are capped as they are
/// read, so a long value is shortened rather than dropped.
public struct AgentAnswer: Codable, Sendable, Hashable {
    public enum Better: String, Codable, Sendable { case higher, lower }

    public struct Number: Codable, Sendable, Hashable {
        /// "42", "$129", "3.4%"; at most nine characters.
        public var value: String
        public var label: String
        /// The earlier value, for a change ("was 38").
        public var was: String?
        /// The total, for progress ("of 50").
        public var of: String?
        public var better: Better?

        public init(value: String, label: String, was: String? = nil, of: String? = nil, better: Better? = nil) {
            self.value = value
            self.label = label
            self.was = was
            self.of = of
            self.better = better
        }
    }

    public struct Item: Codable, Sendable, Hashable {
        public var text: String
        public var detail: String?

        public init(text: String, detail: String? = nil) {
            self.text = text
            self.detail = detail
        }
    }

    /// Something the agent did that a tool confirmed ("Sent · the invite to Sam").
    public struct Receipt: Codable, Sendable, Hashable {
        public var did: String
        public var what: String
        public var link: String?

        public init(did: String, what: String, link: String? = nil) {
            self.did = did
            self.what = what
            self.link = link
        }
    }

    public struct Draft: Codable, Sendable, Hashable {
        public var text: String
        public var to: String?

        public init(text: String, to: String? = nil) {
            self.text = text
            self.to = to
        }
    }

    /// One of the choices the agent offers: a short answer the user can tap, or a file to pick.
    public struct Choice: Codable, Sendable, Hashable {
        public var answer: String?
        public var detail: String?
        public var file: String?

        public init(answer: String? = nil, detail: String? = nil, file: String? = nil) {
            self.answer = answer
            self.detail = detail
            self.file = file
        }

        /// What tapping it sends to the job.
        public var reply: String { answer ?? file.map { "Use \($0)" } ?? detail ?? "" }
    }

    public struct Link: Codable, Sendable, Hashable {
        public var label: String
        public var open: String

        public init(label: String, open: String) {
            self.label = label
            self.open = open
        }
    }

    public enum Block: String, Codable, Sendable, CaseIterable { case numbers, list, done, draft, ask }

    /// One line, the result first; at most 90 characters.
    public var outcome: String?
    public var numbers: [Number]?
    public var list: [Item]?
    /// The list is a ranking (best first).
    public var ranked: Bool?
    public var done: [Receipt]?
    public var draft: Draft?
    public var ask: [Choice]?
    /// A short aside, at most 70 characters.
    public var note: String?
    public var next: Link?
    /// Nothing new since the last run (a routine): the card stays small.
    public var quiet: Bool?

    public init(outcome: String? = nil, numbers: [Number]? = nil, list: [Item]? = nil, ranked: Bool? = nil, done: [Receipt]? = nil,
                draft: Draft? = nil, ask: [Choice]? = nil, note: String? = nil, next: Link? = nil, quiet: Bool? = nil) {
        self.outcome = outcome
        self.numbers = numbers
        self.list = list
        self.ranked = ranked
        self.done = done
        self.draft = draft
        self.ask = ask
        self.note = note
        self.next = next
        self.quiet = quiet
    }

    /// The blocks the card shows, at most two, in the order the agent's content implies: what was done and what to
    /// ask come before numbers, lists and drafts.
    public var blocks: [Block] {
        var found: [Block] = []
        if done?.isEmpty == false { found.append(.done) }
        if ask?.isEmpty == false { found.append(.ask) }
        if numbers?.isEmpty == false { found.append(.numbers) }
        if list?.isEmpty == false { found.append(.list) }
        if draft != nil { found.append(.draft) }
        return Array(found.prefix(2))
    }

    /// How a numbers block looks: one big figure, tiles, before-and-after changes, or progress toward a total.
    public enum NumbersLook: String, Sendable { case hero, tiles, changes, progress }

    public var numbersLook: NumbersLook? {
        guard let numbers, !numbers.isEmpty else { return nil }
        if numbers.allSatisfy({ $0.of != nil }) { return .progress }
        if numbers.contains(where: { $0.was != nil }) { return .changes }
        return numbers.count == 1 ? .hero : .tiles
    }

    public static func parse(_ content: String) throws -> AgentAnswer {
        let json = try AgentFinalBlocks.jsonObject(content)
        func text(_ value: JSONValue?, limit: Int) -> String? {
            let raw: String?
            switch value {
            case .string(let string)?: raw = string
            case .number(let number)?: raw = number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
            default: raw = nil
            }
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return AgentText.shorten(AgentText.stripCitations(trimmed), limit: limit)
        }
        var answer = AgentAnswer()
        answer.outcome = text(json["outcome"] ?? json["line"], limit: 90)
        answer.note = text(json["note"], limit: 70)
        answer.quiet = json["quiet"]?.boolValue
        answer.ranked = json["ranked"]?.boolValue
        if let items = json["numbers"]?.arrayValue {
            let parsed = items.compactMap { item -> Number? in
                guard let value = text(item["value"], limit: 9), let label = text(item["label"], limit: 40) else { return nil }
                return Number(value: value, label: label, was: text(item["was"], limit: 9), of: text(item["of"], limit: 9),
                              better: item["better"]?.stringValue.flatMap { Better(rawValue: $0.lowercased()) })
            }
            if !parsed.isEmpty { answer.numbers = Array(parsed.prefix(3)) }
        }
        if let items = json["list"]?.arrayValue {
            let parsed = items.compactMap { item -> Item? in
                if let plain = text(item, limit: 40) { return Item(text: plain) }
                guard let value = text(item["text"], limit: 40) else { return nil }
                return Item(text: value, detail: text(item["detail"], limit: 20))
            }
            if !parsed.isEmpty { answer.list = Array(parsed.prefix(4)) }
        }
        if let items = json["done"]?.arrayValue {
            let parsed = items.compactMap { item -> Receipt? in
                guard let did = text(item["did"], limit: 24), let what = text(item["what"], limit: 80) else { return nil }
                let link = item["link"]?.stringValue.flatMap { $0.hasPrefix("http://") || $0.hasPrefix("https://") || $0.hasPrefix("/") ? $0 : nil }
                return Receipt(did: did, what: what, link: link)
            }
            if !parsed.isEmpty { answer.done = Array(parsed.prefix(3)) }
        }
        if let draft = json["draft"] {
            if let body = text(draft["text"], limit: 2_000) ?? text(draft, limit: 2_000) {
                answer.draft = Draft(text: body, to: text(draft["to"], limit: 80))
            }
        }
        if let items = json["ask"]?.arrayValue {
            let parsed = items.compactMap { item -> Choice? in
                if let plain = text(item, limit: 28) { return Choice(answer: plain) }
                if let file = text(item["file"], limit: 400) { return Choice(file: file) }
                guard let reply = text(item["answer"], limit: 28) else { return nil }
                return Choice(answer: reply, detail: text(item["detail"], limit: 60))
            }
            if !parsed.isEmpty { answer.ask = Array(parsed.prefix(3)) }
        }
        if let next = json["next"], let label = text(next["label"], limit: 40), let open = text(next["open"], limit: 400) {
            answer.next = Link(label: label, open: open)
        }
        guard answer.outcome != nil || !answer.blocks.isEmpty || answer.quiet == true else {
            throw AgentBlockError("nothing usable (needs outcome or one of numbers, list, done, draft, ask)")
        }
        return answer
    }
}

// MARK: - ROUTINE

/// A routine the agent wants created or changed. OpenClicky asks the user before applying it.
public struct AgentRoutineRequest: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable { case create, update, pause, resume, delete }

    public var action: Action
    public var title: String
    public var task: String?
    public var schedule: RoutineSchedule?
    /// update: the routine's new title.
    public var newTitle: String?

    public init(action: Action, title: String, task: String? = nil, schedule: RoutineSchedule? = nil, newTitle: String? = nil) {
        self.action = action
        self.title = title
        self.task = task
        self.schedule = schedule
        self.newTitle = newTitle
    }

    /// One line for the confirmation: "Create the routine "Inbox digest", weekdays at 08:00".
    public var summary: String {
        let verb: String = switch action {
        case .create: "Create the routine"
        case .update: "Change the routine"
        case .pause: "Pause the routine"
        case .resume: "Resume the routine"
        case .delete: "Delete the routine"
        }
        var line = "\(verb) \"\(title)\""
        if let newTitle { line += " (rename to \"\(newTitle)\")" }
        if let schedule { line += ", \(schedule.phrase)" }
        return line
    }

    public static func parse(_ content: String) throws -> AgentRoutineRequest {
        let json = try AgentFinalBlocks.jsonObject(content)
        return try from(json)
    }

    /// From the block's JSON or a tool's arguments: `action`, `title`, `task`, and `every_minutes` or `at` ("HH:MM")
    /// with optional `days` (numbers 0–6, day names, "weekdays", "weekends").
    public static func from(_ json: JSONValue) throws -> AgentRoutineRequest {
        let actionText = json["action"]?.stringValue?.lowercased() ?? "create"
        guard let action = Action(rawValue: actionText) else { throw AgentBlockError("unknown action \"\(actionText)\"") }
        guard let title = json["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw AgentBlockError("needs a title")
        }
        let task = json["task"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let schedule = try Self.schedule(json)
        if action == .create {
            guard task != nil else { throw AgentBlockError("create needs a task") }
            guard schedule != nil else { throw AgentBlockError("create needs every_minutes or at") }
        }
        if let schedule { try schedule.validate() }
        return AgentRoutineRequest(action: action, title: AgentText.shorten(title, limit: 80), task: task, schedule: schedule,
                                   newTitle: json["new_title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
    }

    static func schedule(_ json: JSONValue) throws -> RoutineSchedule? {
        if let minutes = json["every_minutes"]?.intValue ?? json["every_minutes"]?.stringValue.flatMap({ Int($0) }) {
            guard (1...43_200).contains(minutes) else { throw AgentBlockError("every_minutes must be 1 to 43200") }
            return .every(minutes: minutes)
        }
        guard let at = json["at"]?.stringValue ?? json["time_of_day"]?.stringValue else { return nil }
        guard let time = TimeOfDay(at) else { throw AgentBlockError("at must be HH:MM") }
        return .daily(time, weekdays: try weekdays(json["days"]))
    }

    static func weekdays(_ value: JSONValue?) throws -> [Int]? {
        guard let value else { return nil }
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        func day(_ text: String) throws -> [Int] {
            let word = text.trimmingCharacters(in: .whitespaces).lowercased()
            switch word {
            case "daily", "every day", "everyday", "": return []
            case "weekdays": return [1, 2, 3, 4, 5]
            case "weekends": return [0, 6]
            default:
                if let number = Int(word), (0...6).contains(number) { return [number] }
                if let index = names.firstIndex(where: { word.hasPrefix($0) }) { return [index] }
                throw AgentBlockError("\"\(text)\" isn't a weekday")
            }
        }
        var days: [Int] = []
        switch value {
        case .string(let text):
            for part in text.split(separator: ",") { days += try day(String(part)) }
        case .array(let items):
            for item in items {
                if let number = item.intValue { days += try day(String(number)) } else if let text = item.stringValue { days += try day(text) }
            }
        case .null:
            return nil
        default:
            throw AgentBlockError("days must be a list")
        }
        let unique = Array(Set(days)).sorted()
        return unique.isEmpty || unique.count == 7 ? nil : unique
    }
}

// MARK: - WAIT_FOR

/// A step only the user can do (sign in, approve on their phone, pick a file) before the job can go on.
public struct AgentUserStep: Codable, Sendable, Hashable {
    public var step: String
    /// Where to do it (a URL or an app).
    public var page: String?
    /// The browser reaching a URL containing this means the step is done.
    public var doneWhenURLContains: String?
    public var askedAt: Date

    public init(step: String, page: String? = nil, doneWhenURLContains: String? = nil, askedAt: Date) {
        self.step = step
        self.page = page
        self.doneWhenURLContains = doneWhenURLContains
        self.askedAt = askedAt
    }

    public static func parse(_ content: String, now: Date) throws -> AgentUserStep {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // A plain sentence is accepted as the step.
        if !trimmed.contains("{") {
            guard !trimmed.isEmpty else { throw AgentBlockError("needs a step") }
            return AgentUserStep(step: AgentText.shorten(trimmed, limit: 300), askedAt: now)
        }
        let json = try AgentFinalBlocks.jsonObject(trimmed)
        guard let step = json["step"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !step.isEmpty else {
            throw AgentBlockError("needs a step")
        }
        return AgentUserStep(step: AgentText.shorten(step, limit: 300),
                             page: json["page"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                             doneWhenURLContains: json["done_when_url_contains"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                             askedAt: now)
    }
}

// MARK: - LEARNED

/// One thing the agent learned about the user's own setup: "Topic: what worked".
public struct AgentLearnedHowTo: Codable, Sendable, Hashable {
    public static let maxPerReport = 3

    public var topic: String
    public var detail: String

    public init(topic: String, detail: String) {
        self.topic = topic
        self.detail = detail
    }

    /// The lines that have a topic, and how many were dropped.
    static func parse(_ content: String) -> ([AgentLearnedHowTo], Int) {
        var items: [AgentLearnedHowTo] = []
        var dropped = 0
        for raw in content.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let marker = line.range(of: #"^(?:[-*•]|\d{1,2}[.)])\s+"#, options: .regularExpression) { line.removeSubrange(marker) }
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else { dropped += 1; continue }
            let topic = line[..<colon].trimmingCharacters(in: .whitespaces)
            let detail = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !topic.isEmpty, topic.count <= 60, !detail.isEmpty else { dropped += 1; continue }
            items.append(AgentLearnedHowTo(topic: AgentText.stripMarkdown(topic), detail: AgentText.shorten(detail, limit: 300)))
        }
        return (Array(items.prefix(maxPerReport)), dropped + max(0, items.count - maxPerReport))
    }
}
