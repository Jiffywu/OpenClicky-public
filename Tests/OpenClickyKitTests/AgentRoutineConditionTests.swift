import Foundation
import Testing
@testable import OpenClickyKit

// Routines wait for the network (up to a cap, with the reason recorded), hold off during a dark wake, and keep the Mac
// from idle-sleeping while a run works. The conditions are injected.

/// Conditions a test sets, and a record of the keep-awake holds.
final class FakeRoutineConditions: RoutineRunConditions, @unchecked Sendable {
    private let lock = NSLock()
    private var _online = true
    private var _awake = true
    private var _held: [String] = []
    private var _released = 0

    var online: Bool { get { lock.withLock { _online } } set { lock.withLock { _online = newValue } } }
    var awake: Bool { get { lock.withLock { _awake } } set { lock.withLock { _awake = newValue } } }
    var held: [String] { lock.withLock { _held } }
    var released: Int { lock.withLock { _released } }
    var holding: Int { lock.withLock { _held.count - _released } }

    func networkAvailable() async -> Bool { online }
    func isFullyAwake() async -> Bool { awake }

    func keepAwake(reason: String) -> (any RoutineAwakeHold)? {
        lock.withLock { _held.append(reason) }
        return Hold(owner: self)
    }

    fileprivate func didRelease() { lock.withLock { _released += 1 } }

    final class Hold: RoutineAwakeHold, @unchecked Sendable {
        private let owner: FakeRoutineConditions
        private let lock = NSLock()
        private var done = false
        init(owner: FakeRoutineConditions) { self.owner = owner }
        func release() {
            guard lock.withLock({ () -> Bool in defer { done = true }; return !done }) else { return }
            owner.didRelease()
        }
    }
}

/// A clock a test moves.
final class ConditionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Run ids a runner was asked for.
final class ConditionRunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    var ids: [String] { lock.withLock { _ids } }
    func add(_ id: String) { lock.withLock { _ids.append(id) } }
}

@Suite struct AgentRoutineConditionTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func scheduler(_ temp: AgentTempDir, _ clock: ConditionClock, _ conditions: FakeRoutineConditions, runs: ConditionRunLog) -> RoutineScheduler {
        RoutineScheduler(store: RoutineStore(url: temp.paths.routines), now: { clock.now }, conditions: conditions,
                         networkWaitCap: 600, recheckInterval: 15) { routine, _ in
            runs.add(routine.id)
            return "job-\(routine.id)"
        }
    }

    @Test func aDueRunWaitsForTheNetworkAndRunsWhenItIsBack() async throws {
        let temp = AgentTempDir(), clock = ConditionClock(start), conditions = FakeRoutineConditions(), runs = ConditionRunLog()
        let routines = scheduler(temp, clock, conditions, runs: runs)
        let routine = try await routines.create(title: "Digest", task: "Summarize", schedule: .every(minutes: 30))
        conditions.online = false
        clock.advance(30 * 60)

        #expect(await routines.runDue().isEmpty)
        var stored = try #require(RoutineStore(url: temp.paths.routines).load().first)
        #expect(stored.waitingForNetworkSince == clock.now)
        #expect(stored.deferral?.hasPrefix("waiting for the network since") == true)
        // Held back: the next check is the recheck, not a busy loop on the overdue time.
        #expect(await routines.nextWake() == clock.now.addingTimeInterval(15))
        clock.advance(5)
        #expect(await routines.runDue().isEmpty)  // not rechecked before the interval

        clock.advance(55)
        conditions.online = true
        #expect(await routines.runDue() == [routine.id])
        stored = try #require(RoutineStore(url: temp.paths.routines).load().first)
        #expect(stored.waitingForNetworkSince == nil)
        #expect(stored.deferral == "ran 60 seconds late, once the network was back")
        #expect(stored.runCount == 1)
    }

    @Test func afterTheCapItRunsWithoutANetworkAndSaysSo() async throws {
        let temp = AgentTempDir(), clock = ConditionClock(start), conditions = FakeRoutineConditions(), runs = ConditionRunLog()
        let routines = scheduler(temp, clock, conditions, runs: runs)
        let routine = try await routines.create(title: "Digest", task: "Summarize", schedule: .every(minutes: 30))
        conditions.online = false
        clock.advance(30 * 60)
        for _ in 0..<60 {
            if !(await routines.runDue()).isEmpty { break }
            clock.advance(15)
        }
        #expect(runs.ids == [routine.id])
        let stored = try #require(RoutineStore(url: temp.paths.routines).load().first)
        #expect(stored.deferral == "ran without a network after waiting 10 minutes")
        #expect(stored.waitingForNetworkSince == nil)
    }

    @Test func aDarkWakeHoldsRunsUntilAFullWake() async throws {
        let temp = AgentTempDir(), clock = ConditionClock(start), conditions = FakeRoutineConditions(), runs = ConditionRunLog()
        let routines = scheduler(temp, clock, conditions, runs: runs)
        let routine = try await routines.create(title: "Digest", task: "Summarize", schedule: .every(minutes: 30))
        conditions.awake = false
        conditions.online = false  // not even asked in a dark wake
        clock.advance(30 * 60)
        #expect(await routines.runDue().isEmpty)
        #expect(RoutineStore(url: temp.paths.routines).load().first?.deferral == "waiting for the Mac to wake fully (it is in a dark wake)")
        #expect(RoutineStore(url: temp.paths.routines).load().first?.waitingForNetworkSince == nil)
        clock.advance(4 * 3600)
        #expect(await routines.runDue().isEmpty)
        #expect(runs.ids.isEmpty)

        conditions.awake = true
        conditions.online = true
        clock.advance(15)
        #expect(await routines.runDue() == [routine.id])
        // One run for the missed slots, and the schedule moves past now.
        let stored = try #require(RoutineStore(url: temp.paths.routines).load().first)
        #expect(stored.runCount == 1)
        #expect(stored.deferral == nil)
        #expect((stored.nextRunAt ?? .distantPast) > clock.now)
    }

    @Test func aRunKeepsTheMacAwakeUntilItsOutcomeComesBack() async throws {
        let temp = AgentTempDir(), clock = ConditionClock(start), conditions = FakeRoutineConditions(), runs = ConditionRunLog()
        let routines = scheduler(temp, clock, conditions, runs: runs)
        let routine = try await routines.create(title: "Digest", task: "Summarize", schedule: .every(minutes: 30))
        clock.advance(30 * 60)
        #expect(await routines.runDue() == [routine.id])
        #expect(conditions.held == ["OpenClicky is running the routine \"Digest\""])
        #expect(conditions.holding == 1)
        await routines.recordOutcome(routineID: routine.id, outcome: .completed)
        #expect(conditions.holding == 0)

        // A manual run holds too, and stopping the scheduler lets go of everything.
        _ = try await routines.runNow(routine.id)
        #expect(conditions.holding == 1)
        await routines.stop()
        #expect(conditions.holding == 0)
    }

    @Test func aRunThatCannotStartReleasesItsHold() async throws {
        let temp = AgentTempDir(), clock = ConditionClock(start), conditions = FakeRoutineConditions()
        struct Busy: Error {}
        let routines = RoutineScheduler(store: RoutineStore(url: temp.paths.routines), now: { clock.now }, conditions: conditions) { _, _ in
            throw Busy()
        }
        let routine = try await routines.create(title: "Digest", task: "Summarize", schedule: .every(minutes: 30))
        await #expect(throws: Busy.self) { try await routines.runNow(routine.id) }
        #expect(conditions.held.count == 1 && conditions.holding == 0)
    }

    @Test func overlappingRunsEachKeepTheirOwnHold() async throws {
        let temp = AgentTempDir(), clock = ConditionClock(start), conditions = FakeRoutineConditions()
        struct Busy: Error {}
        let started = ConditionRunLog()
        // The first run starts; the second finds it still going (a job-bound routine's run is busy).
        let routines = RoutineScheduler(store: RoutineStore(url: temp.paths.routines), now: { clock.now }, conditions: conditions) { routine, _ in
            if !started.ids.isEmpty { throw Busy() }
            started.add(routine.id)
            return "job-1"
        }
        let routine = try await routines.create(title: "Digest", task: "Summarize", schedule: .every(minutes: 10))
        _ = try await routines.runNow(routine.id)
        #expect(conditions.holding == 1)
        await #expect(throws: Busy.self) { try await routines.runNow(routine.id) }
        // The run still going keeps the Mac awake until its own outcome comes back.
        #expect(conditions.holding == 1)
        await routines.recordOutcome(routineID: routine.id, outcome: .completed)
        #expect(conditions.holding == 0)

        // Two runs that both started (spawned jobs) hold until both report.
        let spawned = RoutineScheduler(store: RoutineStore(url: temp.paths.routines), now: { clock.now }, conditions: conditions) { _, run in "job-\(run)" }
        let other = try await spawned.create(title: "Fares", task: "Check", schedule: .every(minutes: 10))
        _ = try await spawned.runNow(other.id)
        _ = try await spawned.runNow(other.id)
        #expect(conditions.holding == 2)
        await spawned.recordOutcome(routineID: other.id, outcome: .completed)
        #expect(conditions.holding == 1)
        await spawned.recordOutcome(routineID: other.id, outcome: .completed)
        #expect(conditions.holding == 0)
    }

    @Test func routineNotesListWhatExistsForTheBrainAndForJobs() async throws {
        let temp = AgentTempDir(), clock = ConditionClock(start), conditions = FakeRoutineConditions(), runs = ConditionRunLog()
        let routines = scheduler(temp, clock, conditions, runs: runs)
        #expect(RoutineNotes.brainNote([], now: clock.now).hasPrefix("[Your routines] None set up."))
        #expect(RoutineNotes.jobNote([]) == nil)
        let digest = try await routines.create(title: "Digest", task: "Summarize", schedule: .every(minutes: 60), jobID: "job-1")
        let paused = try await routines.create(title: "Fares", task: "Check fares", schedule: .daily(TimeOfDay(hour: 8, minute: 0), weekdays: [1, 2, 3, 4, 5]))
        try await routines.setPaused(paused.id, true)
        let list = await routines.list()
        let utc = TimeZone(identifier: "UTC")!
        let brain = RoutineNotes.brainNote(list, now: clock.now, timeZone: utc)
        #expect(brain.hasPrefix("[Your routines] Tasks that run on this Mac on a schedule"))
        #expect(brain.contains("- \"Digest\" [\(digest.id)]: every hour, next 09:00"))
        #expect(brain.contains("- \"Fares\" [\(paused.id)]: weekdays at 08:00, paused"))
        let job = try #require(RoutineNotes.jobNote(list, jobID: "job-1", now: clock.now, timeZone: utc))
        #expect(job.contains("\"Digest\" [\(digest.id)]: every hour, next 09:00 (runs in this folder)"))
        #expect(!job.contains("Fares\" [\(paused.id)]: weekdays at 08:00, paused (runs in this folder)"))
    }
}
