import Foundation
import Testing
@testable import OpenClickyKit

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

/// A local time in New York.
private func ny(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = newYork.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

private func show(_ date: Date?) -> String {
    guard let date else { return "never" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = newYork.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
    return formatter.string(from: date)
}

// MARK: - Schedule math

@Test func intervalSchedulesAddTheirLength() {
    let start = ny("2026-10-31 10:07")
    #expect(RoutineSchedule.every(minutes: 30).nextRun(after: start, calendar: newYork) == start.addingTimeInterval(1800))
    #expect(RoutineSchedule.every(minutes: 0).nextRun(after: start, calendar: newYork) == start.addingTimeInterval(60))
}

@Test func dailyTimesFireStrictlyAfterTheGivenMoment() {
    let daily = RoutineSchedule.daily(TimeOfDay(hour: 9, minute: 30), weekdays: nil)
    #expect(show(daily.nextRun(after: ny("2026-10-31 08:00"), calendar: newYork)) == "2026-10-31 09:30 EDT")
    #expect(show(daily.nextRun(after: ny("2026-10-31 09:30"), calendar: newYork)) == "2026-11-01 09:30 EST")
    #expect(show(daily.nextRun(after: ny("2026-12-31 23:59"), calendar: newYork)) == "2027-01-01 09:30 EST")
}

@Test func weekdaySchedulesSkipTheWeekend() {
    let weekdays = RoutineSchedule.daily(TimeOfDay(hour: 8, minute: 30), weekdays: [1, 2, 3, 4, 5])
    // Friday after the run → Monday.
    #expect(show(weekdays.nextRun(after: ny("2026-10-30 09:00"), calendar: newYork)) == "2026-11-02 08:30 EST")
    let sundays = RoutineSchedule.daily(TimeOfDay(hour: 18, minute: 0), weekdays: [0])
    #expect(show(sundays.nextRun(after: ny("2026-10-31 12:00"), calendar: newYork)) == "2026-11-01 18:00 EST")
}

@Test func cronFieldsStepsRangesAndNames() throws {
    let office = try CronExpression("*/15 9-17 * * mon-fri")
    #expect(show(office.next(after: ny("2026-10-30 17:50"), calendar: newYork)) == "2026-11-02 09:00 EST")
    #expect(show(office.next(after: ny("2026-11-02 09:00"), calendar: newYork)) == "2026-11-02 09:15 EST")
    let months = try CronExpression("0 6 1 jan,jul *")
    #expect(show(months.next(after: ny("2026-10-31 00:00"), calendar: newYork)) == "2027-01-01 06:00 EST")
    let sunday7 = try CronExpression("5 4 * * 7")
    #expect(sunday7.daysOfWeek == [0])
    #expect(try CronExpression("@daily") == CronExpression("0 0 * * *"))
    #expect(show(try CronExpression("@hourly").next(after: ny("2026-10-31 10:07"), calendar: newYork)) == "2026-10-31 11:00 EDT")
    // "a/step" runs from a to the end of the range.
    #expect(try CronExpression("10/20 * * * *").minutes == [10, 30, 50])
}

@Test func cronDayFieldsMatchEitherWhenBothAreRestricted() throws {
    // Noon on the 1st of the month OR on Mondays (standard cron).
    let either = try CronExpression("0 12 1 * mon")
    #expect(show(either.next(after: ny("2026-10-31 13:00"), calendar: newYork)) == "2026-11-01 12:00 EST")
    #expect(show(either.next(after: ny("2026-11-01 13:00"), calendar: newYork)) == "2026-11-02 12:00 EST")
    // Only day of month restricted.
    #expect(show(try CronExpression("0 0 15 * *").next(after: ny("2026-10-31 00:00"), calendar: newYork)) == "2026-11-15 00:00 EST")
}

@Test func leapDaysAndImpossibleDates() throws {
    #expect(show(try CronExpression("0 0 29 2 *").next(after: ny("2026-03-01 00:00"), calendar: newYork)) == "2028-02-29 00:00 EST")
    #expect(try CronExpression("0 0 30 2 *").next(after: ny("2026-03-01 00:00"), calendar: newYork) == nil)
}

@Test func daylightSavingGapsAreSkippedAndRepeatsFireOnce() throws {
    // 2027-03-14 02:00 doesn't exist in New York; that day has no 02:30.
    let daily = RoutineSchedule.daily(TimeOfDay(hour: 2, minute: 30), weekdays: nil)
    #expect(show(daily.nextRun(after: ny("2027-03-13 03:00"), calendar: newYork)) == "2027-03-15 02:30 EDT")
    // 2026-11-01 01:30 happens twice; the schedule fires on the first and then moves to the next day.
    let first = try #require(daily.nextRun(after: ny("2026-10-31 03:00"), calendar: newYork))
    #expect(show(first) == "2026-11-01 02:30 EST")
    let early = RoutineSchedule.daily(TimeOfDay(hour: 1, minute: 30), weekdays: nil)
    let repeated = try #require(early.nextRun(after: ny("2026-11-01 00:00"), calendar: newYork))
    #expect(show(repeated) == "2026-11-01 01:30 EDT")
    #expect(show(early.nextRun(after: repeated, calendar: newYork)) == "2026-11-02 01:30 EST")
}

@Test func badSchedulesAreRejected() {
    for bad in ["* * * *", "61 * * * *", "* 24 * * *", "5-1 * * * *", "*/0 * * * *", "* * 0 * *", "* * * 13 *", "* * * * funday", "1,,2 * * * *"] {
        #expect(throws: RoutineError.self, "\(bad)") { _ = try CronExpression(bad) }
    }
    #expect(throws: RoutineError.self) { try RoutineSchedule.daily(TimeOfDay(hour: 9, minute: 0), weekdays: [7]).validate() }
    #expect(throws: RoutineError.self) { try RoutineSchedule.daily(TimeOfDay(hour: 9, minute: 0), weekdays: []).validate() }
    #expect(throws: RoutineError.self) { try RoutineSchedule.every(minutes: 0).validate() }
    #expect(TimeOfDay("24:00") == nil)
    #expect(TimeOfDay("9:5") == TimeOfDay(hour: 9, minute: 5))
    #expect(TimeOfDay("noon") == nil)
}

@Test func schedulePhrasesAndCoding() throws {
    #expect(RoutineSchedule.every(minutes: 1).phrase == "every minute")
    #expect(RoutineSchedule.every(minutes: 90).phrase == "every 90 minutes")
    #expect(RoutineSchedule.every(minutes: 120).phrase == "every 2 hours")
    #expect(RoutineSchedule.every(minutes: 1440).phrase == "every day")
    #expect(RoutineSchedule.daily(TimeOfDay(hour: 8, minute: 30), weekdays: [5, 1, 2, 3, 4]).phrase == "weekdays at 08:30")
    #expect(RoutineSchedule.daily(TimeOfDay(hour: 10, minute: 0), weekdays: [6, 0]).phrase == "weekends at 10:00")
    #expect(RoutineSchedule.daily(TimeOfDay(hour: 7, minute: 0), weekdays: [3, 1]).phrase == "Mon, Wed at 07:00")
    for schedule: RoutineSchedule in [.every(minutes: 45), .daily(TimeOfDay(hour: 7, minute: 5), weekdays: nil),
                                      .daily(TimeOfDay(hour: 7, minute: 5), weekdays: [1, 3]), .cron("0 9 * * 1")] {
        let data = try JSONEncoder().encode(schedule)
        #expect(try JSONDecoder().decode(RoutineSchedule.self, from: data) == schedule)
    }
    #expect(String(decoding: try JSONEncoder().encode(RoutineSchedule.daily(TimeOfDay(hour: 7, minute: 5), weekdays: nil)), as: UTF8.self) == #"{"at":"07:05"}"#)
}

// MARK: - Scheduler

/// A clock the test moves by hand.
final class RoutineTestClock: @unchecked Sendable {
    private var value: Date
    private let lock = NSLock()
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
    func advance(minutes: Double) { lock.withLock { value = value.addingTimeInterval(minutes * 60) } }
}

/// Records the runner's calls.
final class RunLog: @unchecked Sendable {
    private var calls: [(String, Int)] = []
    private let lock = NSLock()
    var failNext = false
    func record(_ routine: AgentRoutine, _ run: Int) throws -> String {
        try lock.withLock {
            calls.append((routine.id, run))
            if failNext { failNext = false; throw AgentManagerError.busy("job") }
            return "job-for-\(routine.id)"
        }
    }
    var runs: [Int] { lock.withLock { calls.map(\.1) } }
}

private func makeScheduler(_ temp: AgentTempDir, clock: RoutineTestClock, log: RunLog) -> RoutineScheduler {
    RoutineScheduler(store: RoutineStore(url: temp.paths.routines), calendar: newYork, now: { clock.now }) { routine, run in
        try log.record(routine, run)
    }
}

@Test func intervalRoutinesRunWhenDueAndKeepTheirPhase() async throws {
    let temp = AgentTempDir()
    let clock = RoutineTestClock(ny("2026-10-31 10:00"))
    let log = RunLog()
    let scheduler = makeScheduler(temp, clock: clock, log: log)
    let routine = try await scheduler.create(title: "", task: "Check the build status", schedule: .every(minutes: 10))
    #expect(routine.title == "Check the build status")
    #expect(routine.nextRunAt == ny("2026-10-31 10:10"))

    clock.set(ny("2026-10-31 10:05"))
    #expect(await scheduler.runDue().isEmpty)
    clock.set(ny("2026-10-31 10:10"))
    #expect(await scheduler.runDue() == [routine.id])
    var stored = try #require(await scheduler.list().first)
    #expect(stored.nextRunAt == ny("2026-10-31 10:20"))
    #expect(stored.runCount == 1)
    #expect(stored.jobID == "job-for-\(routine.id)")

    // Asleep for a while: one catch-up run, not one per missed slot, and the 10-minute phase holds.
    clock.set(ny("2026-10-31 10:47"))
    #expect(await scheduler.runDue() == [routine.id])
    #expect(await scheduler.runDue().isEmpty)
    stored = try #require(await scheduler.list().first)
    #expect(stored.nextRunAt == ny("2026-10-31 10:50"))
    #expect(log.runs == [1, 2])
}

@Test func failedRunsRetryWithGrowingDelaysButNotPastTheNextSlot() async throws {
    let temp = AgentTempDir()
    let clock = RoutineTestClock(ny("2026-10-31 10:00"))
    let log = RunLog()
    let scheduler = makeScheduler(temp, clock: clock, log: log)
    let routine = try await scheduler.create(title: "Digest", task: "Summarize the news", schedule: .daily(TimeOfDay(hour: 11, minute: 0), weekdays: nil))

    clock.set(ny("2026-10-31 11:00"))
    log.failNext = true
    #expect(await scheduler.runDue().isEmpty)  // the runner threw
    var stored = try #require(await scheduler.list().first)
    #expect(stored.consecutiveFailures == 1)
    #expect(stored.retryAt == ny("2026-10-31 11:10"))
    #expect(stored.dueAt == ny("2026-10-31 11:10"))

    clock.set(ny("2026-10-31 11:10"))
    #expect(await scheduler.runDue() == [routine.id])
    await scheduler.recordOutcome(routineID: routine.id, outcome: .failed)
    stored = try #require(await scheduler.list().first)
    #expect(stored.consecutiveFailures == 2)
    #expect(stored.retryAt == ny("2026-10-31 11:30"))
    #expect(stored.nextRunAt == ny("2026-11-01 11:00"))  // a retry doesn't move the schedule

    await scheduler.recordOutcome(routineID: routine.id, outcome: .completed)
    stored = try #require(await scheduler.list().first)
    #expect(stored.consecutiveFailures == 0)
    #expect(stored.retryAt == nil)

    // Late in the day a retry would land after tomorrow's run; then there is no separate retry.
    clock.set(ny("2026-11-01 10:55"))
    for _ in 0..<7 { await scheduler.recordOutcome(routineID: routine.id, outcome: .failed) }
    stored = try #require(await scheduler.list().first)
    #expect(stored.retryAt == nil)
    #expect(stored.dueAt == ny("2026-11-01 11:00"))
}

@Test func pausedRoutinesWaitAndManualRunsLeaveTheScheduleAlone() async throws {
    let temp = AgentTempDir()
    let clock = RoutineTestClock(ny("2026-10-31 10:00"))
    let log = RunLog()
    let scheduler = makeScheduler(temp, clock: clock, log: log)
    let routine = try await scheduler.create(title: "Inbox", task: "Triage", schedule: .every(minutes: 60))
    try await scheduler.setPaused(routine.id, true)
    clock.set(ny("2026-10-31 12:00"))
    #expect(await scheduler.runDue().isEmpty)
    #expect(await scheduler.nextWake() == nil)

    _ = try await scheduler.runNow(routine.id)
    #expect(log.runs == [1])
    try await scheduler.setPaused(routine.id, false)
    let resumed = try #require(await scheduler.list().first)
    #expect(resumed.nextRunAt == ny("2026-10-31 13:00"))

    try await scheduler.update(routine.id, title: "Inbox zero", schedule: .cron("0 9 * * mon-fri"))
    let updated = try #require(await scheduler.list().first)
    #expect(updated.title == "Inbox zero")
    #expect(updated.nextRunAt == ny("2026-11-02 09:00"))
    await #expect(throws: RoutineError.self) { try await scheduler.update(routine.id, schedule: .cron("bad")) }
    try await scheduler.delete(routine.id)
    #expect(await scheduler.list().isEmpty)
    await #expect(throws: RoutineError.notFound(routine.id)) { try await scheduler.delete(routine.id) }
}

@Test func routinesPersistAndAMissedRunHappensOnceAfterRelaunch() async throws {
    let temp = AgentTempDir()
    let clock = RoutineTestClock(ny("2026-10-31 07:00"))
    let log = RunLog()
    let first = makeScheduler(temp, clock: clock, log: log)
    let routine = try await first.create(title: "Morning", task: "Brief me", schedule: .daily(TimeOfDay(hour: 8, minute: 0), weekdays: nil), agent: "assistant")
    let text = try String(contentsOf: temp.paths.routines, encoding: .utf8)
    #expect(text.contains(#""at" : "08:00""#))
    #expect(text.contains(#""agent" : "assistant""#))

    // The app was closed over two scheduled times; relaunched at 09:30 the next day.
    clock.set(ny("2026-11-01 09:30"))
    let second = makeScheduler(temp, clock: clock, log: log)
    #expect(await second.list().map(\.id) == [routine.id])
    #expect(await second.runDue() == [routine.id])
    #expect(await second.runDue().isEmpty)
    #expect(await second.list().first?.nextRunAt == ny("2026-11-02 08:00"))
}

@Test func createRejectsEmptyTasksAndBadSchedules() async {
    let temp = AgentTempDir()
    let scheduler = makeScheduler(temp, clock: RoutineTestClock(Date()), log: RunLog())
    await #expect(throws: RoutineError.self) { try await scheduler.create(title: "x", task: "  ", schedule: .every(minutes: 5)) }
    await #expect(throws: RoutineError.self) { try await scheduler.create(title: "x", task: "y", schedule: .cron("* *")) }
}

@Test func theSchedulerLoopRunsDueRoutinesOnItsOwn() async throws {
    let temp = AgentTempDir()
    let clock = RoutineTestClock(ny("2026-10-31 10:00"))
    let log = RunLog()
    let scheduler = makeScheduler(temp, clock: clock, log: log)
    _ = try await scheduler.create(title: "Tick", task: "Tick", schedule: .every(minutes: 1))
    await scheduler.start()
    clock.advance(minutes: 1)
    // Editing wakes the loop, which then sees the routine is due.
    _ = try await scheduler.create(title: "Other", task: "Other", schedule: .every(minutes: 600))
    // A hang guard, well short of the minute the loop would sleep if the edit didn't wake it.
    #expect(await agentEventually { log.runs.count >= 1 })
    await scheduler.stop()
}
