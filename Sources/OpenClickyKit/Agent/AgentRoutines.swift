import Foundation

/// A wall-clock time, "HH:MM".
public struct TimeOfDay: Codable, Sendable, Hashable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Parses "9:30", "09:30" or "21:05".
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    public var description: String { String(format: "%02d:%02d", hour, minute) }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = TimeOfDay(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected HH:MM, got \(text)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// When a routine runs.
public enum RoutineSchedule: Sendable, Hashable, Codable {
    /// Every N minutes (at least 1), counted from the previous scheduled run.
    case every(minutes: Int)
    /// At a time of day, on the given weekdays (0 = Sunday … 6 = Saturday), or every day when nil.
    case daily(TimeOfDay, weekdays: [Int]?)
    /// A five-field cron expression ("minute hour day-of-month month day-of-week").
    case cron(String)

    /// The first run strictly after `date`, or nil if the schedule never fires.
    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .every(let minutes):
            return date.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        case .daily(let time, let weekdays):
            let days = weekdays.map { $0.map(String.init).joined(separator: ",") } ?? "*"
            return (try? CronExpression("\(time.minute) \(time.hour) * * \(days)"))?.next(after: date, calendar: calendar)
        case .cron(let expression):
            return (try? CronExpression(expression))?.next(after: date, calendar: calendar)
        }
    }

    /// Checks the schedule can be parsed and fires at all.
    public func validate() throws {
        switch self {
        case .every(let minutes):
            guard minutes >= 1 else { throw RoutineError.invalid("Routines run at most once a minute.") }
        case .daily(_, let weekdays):
            if let weekdays, weekdays.isEmpty || weekdays.contains(where: { !(0...6).contains($0) }) {
                throw RoutineError.invalid("Weekdays are 0 (Sunday) through 6 (Saturday).")
            }
        case .cron(let expression):
            // "0 0 30 2 *" (February 30th) parses but never comes round; a routine with it would sit there silently.
            guard try CronExpression(expression).next(after: Date(), calendar: Calendar(identifier: .gregorian)) != nil else {
                throw RoutineError.invalid("\"\(expression)\" never runs: no date matches it.")
            }
        }
    }

    /// Wording for briefs and lists: "every 30 minutes", "daily at 09:00", "weekdays at 08:30".
    public var phrase: String {
        switch self {
        case .every(let minutes):
            if minutes % 1440 == 0 { return minutes == 1440 ? "every day" : "every \(minutes / 1440) days" }
            if minutes % 60 == 0 { return minutes == 60 ? "every hour" : "every \(minutes / 60) hours" }
            return minutes == 1 ? "every minute" : "every \(minutes) minutes"
        case .daily(let time, let weekdays):
            guard let weekdays else { return "daily at \(time)" }
            let set = Set(weekdays)
            if set == [1, 2, 3, 4, 5] { return "weekdays at \(time)" }
            if set == [0, 6] { return "weekends at \(time)" }
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return "\(weekdays.sorted().map { names[$0] }.joined(separator: ", ")) at \(time)"
        case .cron(let expression):
            return "on schedule \(expression)"
        }
    }

    private enum CodingKeys: String, CodingKey { case everyMinutes = "every_minutes", at, days, cron }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let minutes = try container.decodeIfPresent(Int.self, forKey: .everyMinutes) {
            self = .every(minutes: minutes)
        } else if let time = try container.decodeIfPresent(TimeOfDay.self, forKey: .at) {
            self = .daily(time, weekdays: try container.decodeIfPresent([Int].self, forKey: .days))
        } else if let cron = try container.decodeIfPresent(String.self, forKey: .cron) {
            self = .cron(cron)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A schedule needs every_minutes, at or cron."))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .every(let minutes): try container.encode(minutes, forKey: .everyMinutes)
        case .daily(let time, let weekdays):
            try container.encode(time, forKey: .at)
            try container.encodeIfPresent(weekdays, forKey: .days)
        case .cron(let expression): try container.encode(expression, forKey: .cron)
        }
    }
}

public enum RoutineError: Error, CustomStringConvertible, Equatable {
    case invalid(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .invalid(let message): message
        case .notFound(let id): "No routine \"\(id)\"."
        }
    }
}

/// A standard five-field cron expression: minute (0–59), hour (0–23), day of month (1–31), month (1–12 or
/// JAN–DEC), day of week (0–7 or SUN–SAT; 0 and 7 are Sunday). Fields take `*`, numbers, `a-b` ranges, lists and
/// `/step`. As in cron, when both day fields are restricted a day matches if either does. Also accepts
/// `@hourly`, `@daily`, `@weekly`, `@monthly` and `@yearly`.
public struct CronExpression: Sendable, Hashable {
    public let minutes: Set<Int>
    public let hours: Set<Int>
    public let daysOfMonth: Set<Int>
    public let months: Set<Int>
    public let daysOfWeek: Set<Int>
    let dayOfMonthRestricted: Bool
    let dayOfWeekRestricted: Bool

    public init(_ text: String) throws {
        let aliases = ["@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@weekly": "0 0 * * 0",
                       "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *"]
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let fields = (aliases[trimmed] ?? trimmed).split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { throw RoutineError.invalid("A cron schedule has five fields: minute hour day month weekday.") }
        minutes = try Self.parse(fields[0], range: 0...59, names: [:], label: "minute")
        hours = try Self.parse(fields[1], range: 0...23, names: [:], label: "hour")
        daysOfMonth = try Self.parse(fields[2], range: 1...31, names: [:], label: "day of month")
        let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        months = try Self.parse(fields[3], range: 1...12, names: Dictionary(uniqueKeysWithValues: monthNames.enumerated().map { ($1, $0 + 1) }), label: "month")
        let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let weekdays = try Self.parse(fields[4], range: 0...7, names: Dictionary(uniqueKeysWithValues: dayNames.enumerated().map { ($1, $0) }), label: "weekday")
        daysOfWeek = Set(weekdays.map { $0 == 7 ? 0 : $0 })
        dayOfMonthRestricted = !fields[2].hasPrefix("*")
        dayOfWeekRestricted = !fields[4].hasPrefix("*")
    }

    private static func parse(_ field: String, range: ClosedRange<Int>, names: [String: Int], label: String) throws -> Set<Int> {
        func value(_ text: Substring) throws -> Int {
            if let number = Int(text), range.contains(number) { return number }
            if let named = names[String(text)] { return named }
            throw RoutineError.invalid("\"\(text)\" isn't a valid \(label).")
        }
        var result = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2, let base = pieces.first, !base.isEmpty else { throw RoutineError.invalid("\"\(part)\" isn't a valid \(label) field.") }
            var step = 1
            if pieces.count == 2 {
                guard let parsed = Int(pieces[1]), parsed > 0 else { throw RoutineError.invalid("\"\(part)\" has a bad step.") }
                step = parsed
            }
            let lower: Int
            let upper: Int
            if base == "*" {
                lower = range.lowerBound
                upper = range.upperBound
            } else if let dash = base.firstIndex(of: "-") {
                lower = try value(base[..<dash])
                upper = try value(base[base.index(after: dash)...])
                guard lower <= upper else { throw RoutineError.invalid("\"\(part)\" is a backwards range.") }
            } else {
                lower = try value(base)
                upper = pieces.count == 2 ? range.upperBound : lower
            }
            result.formUnion(stride(from: lower, through: upper, by: step))
        }
        guard !result.isEmpty else { throw RoutineError.invalid("The \(label) field matches nothing.") }
        return result
    }

    func matchesDay(_ components: DateComponents) -> Bool {
        guard let month = components.month, months.contains(month), let day = components.day, let weekday = components.weekday else { return false }
        let domMatch = daysOfMonth.contains(day)
        let dowMatch = daysOfWeek.contains(weekday - 1)  // Calendar: 1 = Sunday
        switch (dayOfMonthRestricted, dayOfWeekRestricted) {
        case (true, true): return domMatch || dowMatch
        case (true, false): return domMatch
        case (false, true): return dowMatch
        case (false, false): return true
        }
    }

    /// The first matching minute strictly after `date`, searching up to five years ahead. Local times skipped by a
    /// daylight-saving jump don't fire.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        let sortedHours = hours.sorted()
        let sortedMinutes = minutes.sorted()
        guard var day = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: date)) else { return nil }
        for _ in 0..<(366 * 5) {
            let components = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            if matchesDay(components) {
                for hour in sortedHours {
                    for minute in sortedMinutes {
                        var wanted = DateComponents()
                        wanted.year = components.year
                        wanted.month = components.month
                        wanted.day = components.day
                        wanted.hour = hour
                        wanted.minute = minute
                        guard let candidate = calendar.date(from: wanted), candidate > date else { continue }
                        let check = calendar.dateComponents([.day, .hour, .minute], from: candidate)
                        if check.day == components.day, check.hour == hour, check.minute == minute { return candidate }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }
}

/// A task OpenClicky re-runs on a schedule while the app is open.
public struct AgentRoutine: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var task: String
    public var schedule: RoutineSchedule
    /// Run inside this kept agent (by slug), if set.
    public var agent: String?
    /// The job folder runs go to. Set by the first run; later runs continue it so they can report what changed.
    public var jobID: String?
    public var harness: HarnessKind?
    public var createdAt: Date
    public var isPaused: Bool
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    public var runCount: Int
    public var lastOutcome: AgentTurnOutcome?
    public var consecutiveFailures: Int
    /// A failed run is retried at this time (before the next scheduled run).
    public var retryAt: Date?
    /// A due run has been held back for the network since then.
    public var waitingForNetworkSince: Date?
    /// Why the latest due run was held back or ran late ("waiting for the network", "ran without a network after
    /// 15 min"); cleared once a run starts normally.
    public var deferral: String?

    public init(id: String = UUID().uuidString.lowercased().prefix(8).description, title: String, task: String, schedule: RoutineSchedule,
                agent: String? = nil, jobID: String? = nil, harness: HarnessKind? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.task = task
        self.schedule = schedule
        self.agent = agent
        self.jobID = jobID
        self.harness = harness
        self.createdAt = createdAt
        isPaused = false
        runCount = 0
        consecutiveFailures = 0
    }

    /// When this routine should next start: a pending retry, else the scheduled time.
    public var dueAt: Date? {
        guard !isPaused else { return nil }
        if let retryAt, let nextRunAt { return min(retryAt, nextRunAt) }
        return retryAt ?? nextRunAt
    }
}

/// `routines.json` in the support folder.
public struct RoutineStore: Sendable {
    public var url: URL

    public init(url: URL = AgentPaths.default.routines) { self.url = url }

    /// The file's bytes as they are now (nil when there is no file), to notice edits made by another process.
    public func rawData() -> Data? { try? Data(contentsOf: url) }

    public func load() -> [AgentRoutine] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct File: Decodable { var routines: [AgentRoutine] }
        return (try? decoder.decode(File.self, from: data).routines) ?? []
    }

    public func save(_ routines: [AgentRoutine]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        struct File: Encodable { var version = 1; var routines: [AgentRoutine] }
        try encoder.encode(File(routines: routines)).write(to: url, options: .atomic)
    }
}

/// Runs routines while the app is open. Each due routine starts once (a routine whose time passed while the app
/// was closed runs once on launch, not once per missed slot). Failed runs are retried with growing delays, but
/// never later than the next scheduled run.
public actor RoutineScheduler {
    /// Starts one run; returns the job id it went to, or throws.
    public typealias Runner = @Sendable (_ routine: AgentRoutine, _ runNumber: Int) async throws -> String

    private let store: RoutineStore
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let runner: Runner
    private let conditions: (any RoutineRunConditions)?
    /// How long a due run waits for the network before it starts anyway.
    public let networkWaitCap: TimeInterval
    /// How soon a held-back run is checked again.
    public let recheckInterval: TimeInterval
    /// Routines held back (no network, dark wake) and when to look at them again. Not persisted.
    private var heldUntil: [String: Date] = [:]
    /// The no-idle-sleep holds of routine runs in progress, released when their outcomes are recorded: one per run
    /// that hasn't reported back, oldest first, by routine id. Runs of one routine can overlap, so each run releases
    /// one hold and never another run's.
    private var awakeHolds: [String: [(token: UUID, hold: any RoutineAwakeHold)]] = [:]
    private var routines: [AgentRoutine]
    private var loop: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var changeHandlers: [UUID: AsyncStream<[AgentRoutine]>.Continuation] = [:]
    /// routines.json as this scheduler last read or wrote it.
    private var diskSnapshot: Data?

    /// - Parameters:
    ///   - conditions: the network, wake state and keep-awake hold due runs wait for; nil runs them regardless.
    ///   - networkWaitCap: how long a due run waits for the network before it starts anyway.
    ///   - recheckInterval: how soon a held-back run is looked at again.
    public init(store: RoutineStore, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() },
                conditions: (any RoutineRunConditions)? = nil, networkWaitCap: TimeInterval = 15 * 60, recheckInterval: TimeInterval = 15,
                runner: @escaping Runner) {
        self.store = store
        self.calendar = calendar
        self.now = now
        self.runner = runner
        self.conditions = conditions
        self.networkWaitCap = networkWaitCap
        self.recheckInterval = recheckInterval
        routines = store.load()
        diskSnapshot = store.rawData()
    }

    public func list() -> [AgentRoutine] {
        syncFromDisk()
        return routines
    }

    /// Picks up edits another process made to routines.json (`occtl routines` while the app runs) since this scheduler
    /// last read or wrote it. Every edit and every scheduling pass starts here, so neither side overwrites the other.
    public func syncFromDisk() {
        let data = store.rawData()
        guard data != diskSnapshot else { return }
        diskSnapshot = data
        routines = store.load()
        for continuation in changeHandlers.values { continuation.yield(routines) }
    }

    /// Live copies of the routine list after every change.
    public func changes() -> AsyncStream<[AgentRoutine]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [AgentRoutine].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        changeHandlers[id] = continuation
        continuation.yield(routines)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeHandler(id) } }
        return stream
    }

    private func removeHandler(_ id: UUID) { changeHandlers[id] = nil }

    // MARK: Editing

    @discardableResult
    public func create(title: String, task: String, schedule: RoutineSchedule, agent: String? = nil, harness: HarnessKind? = nil,
                       jobID: String? = nil) throws -> AgentRoutine {
        syncFromDisk()
        try schedule.validate()
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw RoutineError.invalid("A routine needs a task.") }
        var routine = AgentRoutine(title: title.isEmpty ? AgentJobStore.title(nil, from: task) : title, task: task, schedule: schedule,
                                   agent: agent, jobID: jobID, harness: harness, createdAt: now())
        routine.nextRunAt = schedule.nextRun(after: now(), calendar: calendar)
        routines.append(routine)
        try persist()
        return routine
    }

    @discardableResult
    public func update(_ id: String, title: String? = nil, task: String? = nil, schedule: RoutineSchedule? = nil) throws -> AgentRoutine {
        syncFromDisk()
        guard let index = routines.firstIndex(where: { $0.id == id }) else { throw RoutineError.notFound(id) }
        if let schedule {
            try schedule.validate()
            routines[index].schedule = schedule
            routines[index].nextRunAt = schedule.nextRun(after: now(), calendar: calendar)
        }
        if let title, !title.isEmpty { routines[index].title = title }
        if let task, !task.isEmpty { routines[index].task = task }
        try persist()
        return routines[index]
    }

    @discardableResult
    public func setPaused(_ id: String, _ paused: Bool) throws -> AgentRoutine {
        syncFromDisk()
        guard let index = routines.firstIndex(where: { $0.id == id }) else { throw RoutineError.notFound(id) }
        routines[index].isPaused = paused
        routines[index].retryAt = nil
        if !paused { routines[index].nextRunAt = routines[index].schedule.nextRun(after: now(), calendar: calendar) }
        try persist()
        return routines[index]
    }

    public func delete(_ id: String) throws {
        syncFromDisk()
        guard routines.contains(where: { $0.id == id }) else { throw RoutineError.notFound(id) }
        routines.removeAll { $0.id == id }
        try persist()
    }

    /// Starts a run now, outside the schedule. Returns the job id.
    @discardableResult
    public func runNow(_ id: String) async throws -> String {
        syncFromDisk()
        guard let index = routines.firstIndex(where: { $0.id == id }) else { throw RoutineError.notFound(id) }
        return try await start(index: index)
    }

    /// The job for a routine run finished.
    public func recordOutcome(routineID: String, outcome: AgentTurnOutcome) {
        if var holds = awakeHolds[routineID], !holds.isEmpty {
            holds.removeFirst().hold.release()
            awakeHolds[routineID] = holds.isEmpty ? nil : holds
        }
        noteOutcome(routineID: routineID, outcome: outcome)
    }

    private func noteOutcome(routineID: String, outcome: AgentTurnOutcome) {
        syncFromDisk()
        guard let index = routines.firstIndex(where: { $0.id == routineID }) else { return }
        routines[index].lastOutcome = outcome
        if outcome == .failed {
            routines[index].consecutiveFailures += 1
            let delay = TimeInterval(min(60, 10 * routines[index].consecutiveFailures) * 60)
            let retry = now().addingTimeInterval(delay)
            routines[index].retryAt = routines[index].nextRunAt.map { retry < $0 ? retry : nil } ?? retry
        } else {
            routines[index].consecutiveFailures = 0
            routines[index].retryAt = nil
        }
        try? persist()
    }

    // MARK: Running

    /// Starts every routine that is due. Returns the ids started.
    @discardableResult
    public func runDue() async -> [String] {
        syncFromDisk()
        let current = now()
        var started: [String] = []
        for id in routines.filter({ ($0.dueAt ?? .distantFuture) <= current && (heldUntil[$0.id] ?? .distantPast) <= current }).map(\.id) {
            guard await readyToRun(id, at: current), let index = routines.firstIndex(where: { $0.id == id }) else { continue }
            if (try? await start(index: index)) != nil { started.append(id) }
        }
        return started
    }

    /// Checks the conditions for a due run. A dark wake holds it until a full wake; no network holds it until the
    /// network is back or `networkWaitCap` has passed. Each hold is recorded on the routine.
    private func readyToRun(_ id: String, at current: Date) async -> Bool {
        guard let conditions else { return true }
        let fullyAwake = await conditions.isFullyAwake()
        let online = fullyAwake ? await conditions.networkAvailable() : true
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return false }
        var routine = routines[index]
        defer {
            if routines.indices.contains(index), routines[index].id == id, routines[index] != routine {
                routines[index] = routine
                try? persist()
            }
        }
        if !fullyAwake {
            heldUntil[id] = current.addingTimeInterval(recheckInterval)
            routine.deferral = "waiting for the Mac to wake fully (it is in a dark wake)"
            return false
        }
        if !online {
            let since = routine.waitingForNetworkSince ?? current
            routine.waitingForNetworkSince = since
            let waited = current.timeIntervalSince(since)
            if waited < networkWaitCap {
                heldUntil[id] = current.addingTimeInterval(min(recheckInterval, networkWaitCap - waited))
                routine.deferral = "waiting for the network since \(Self.clock(since))"
                return false
            }
            routine.deferral = "ran without a network after waiting \(AgentLimits.phrase(waited))"
            routine.waitingForNetworkSince = nil
        } else {
            if let since = routine.waitingForNetworkSince {
                routine.deferral = "ran \(AgentLimits.phrase(current.timeIntervalSince(since))) late, once the network was back"
            } else if routine.deferral != nil {
                routine.deferral = nil
            }
            routine.waitingForNetworkSince = nil
        }
        heldUntil[id] = nil
        return true
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func start(index: Int) async throws -> String {
        let current = now()
        var routine = routines[index]
        routine.runCount += 1
        routine.lastRunAt = current
        routine.retryAt = nil
        // A run that uses up the scheduled slot moves the schedule on; retries and manual runs don't.
        if routine.nextRunAt.map({ $0 <= current }) ?? false {
            routine.nextRunAt = nextAfter(routine, from: current)
        }
        routines[index] = routine
        try? persist()
        // Keep the Mac from idle-sleeping until the run's outcome comes back.
        let token = UUID()
        if let hold = conditions?.keepAwake(reason: "OpenClicky is running the routine \"\(routine.title)\"") {
            awakeHolds[routine.id, default: []].append((token, hold))
        }
        do {
            let jobID = try await runner(routine, routine.runCount)
            if let index = routines.firstIndex(where: { $0.id == routine.id }) {
                routines[index].jobID = jobID
                try? persist()
            }
            return jobID
        } catch {
            // Only this run's hold: a run still going (the reason it was busy) keeps its own.
            if let index = awakeHolds[routine.id]?.firstIndex(where: { $0.token == token }) {
                awakeHolds[routine.id]?.remove(at: index).hold.release()
                if awakeHolds[routine.id]?.isEmpty == true { awakeHolds[routine.id] = nil }
            }
            noteOutcome(routineID: routine.id, outcome: .failed)
            throw error
        }
    }

    /// The next scheduled time after `current`. Interval schedules keep their phase instead of drifting.
    func nextAfter(_ routine: AgentRoutine, from current: Date) -> Date? {
        if case .every(let minutes) = routine.schedule, var next = routine.nextRunAt {
            let step = TimeInterval(max(1, minutes) * 60)
            if next <= current {
                let skipped = floor(current.timeIntervalSince(next) / step) + 1
                next = next.addingTimeInterval(skipped * step)
            }
            return next
        }
        return routine.schedule.nextRun(after: current, calendar: calendar)
    }

    /// The earliest time any routine is due.
    public func nextWake() -> Date? {
        routines.compactMap { routine in
            routine.dueAt.map { due in heldUntil[routine.id].map { max($0, due) } ?? due }
        }.min()
    }

    /// Runs the schedule until `stop()`. Rechecks at least once a minute so sleep, wake and clock changes are noticed.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runDue()
                await self.sleepUntilNextCheck()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        for holds in awakeHolds.values { for entry in holds { entry.hold.release() } }
        awakeHolds.removeAll()
        wake?.resume()
        wake = nil
    }

    private func secondsUntilNextCheck() -> TimeInterval {
        guard let next = nextWake() else { return 60 }
        return min(60, max(1, next.timeIntervalSince(now())))
    }

    /// Sleeps until the next check or an edit. The wait is computed and the wake-up registered in one actor turn,
    /// so an edit can't slip in between and be missed.
    private func sleepUntilNextCheck() async {
        guard !Task.isCancelled else { return }
        let seconds = secondsUntilNextCheck()
        await withCheckedContinuation { continuation in
            wake = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self?.wakeUp()
            }
        }
    }

    private func wakeUp() {
        wake?.resume()
        wake = nil
    }

    private func persist() throws {
        try store.save(routines)
        diskSnapshot = store.rawData()
        for continuation in changeHandlers.values { continuation.yield(routines) }
        wakeUp()
    }
}
