import AppKit
import Foundation
import IOKit.pwr_mgt
import Network

/// What a routine run waits for and holds: a usable network, a full wake (not a dark wake, when the Mac wakes with its
/// screens off for maintenance), and a hold that keeps the Mac from idle-sleeping while the run works. The scheduler
/// asks before every due run; tests inject a fake.
public protocol RoutineRunConditions: Sendable {
    /// The network has a usable path now.
    func networkAvailable() async -> Bool
    /// The Mac is fully awake (screens can show), not in a dark wake.
    func isFullyAwake() async -> Bool
    /// Keeps the Mac from idle sleep until the hold is released; nil when it couldn't be taken.
    func keepAwake(reason: String) -> (any RoutineAwakeHold)?
}

/// A held "don't idle-sleep" assertion.
public protocol RoutineAwakeHold: Sendable {
    func release()
}

/// The Mac's own conditions: NWPathMonitor for the network, the workspace's sleep and wake notifications for the
/// wake state, and an IOKit `PreventUserIdleSystemSleep` assertion for the hold.
public final class SystemRoutineConditions: RoutineRunConditions, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.openclicky.routine-network")
    private let lock = NSLock()
    private var satisfied: Bool?

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.satisfied = path.status == .satisfied }
        }
        monitor.start(queue: queue)
        observeWake()
    }

    deinit {
        monitor.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    public func networkAvailable() async -> Bool {
        // Before the first update arrives, the monitor's current path is the best answer.
        if let known = lock.withLock({ satisfied }) { return known }
        return monitor.currentPath.status == .satisfied
    }

    public func isFullyAwake() async -> Bool {
        lock.withLock { !inDarkWake }
    }

    /// Set when the system goes to sleep and cleared by the full wake that follows. A dark wake (Power Nap,
    /// maintenance) lets this process run without the full-wake notification, so a routine that comes due then waits.
    private var inDarkWake = false
    private var observers: [NSObjectProtocol] = []

    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setDarkWake(true)
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.setDarkWake(false)
            })
        }
    }

    func setDarkWake(_ value: Bool) { lock.withLock { inDarkWake = value } }

    public func keepAwake(reason: String) -> (any RoutineAwakeHold)? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        guard result == kIOReturnSuccess else { return nil }
        return PowerAssertionHold(id: id)
    }

    final class PowerAssertionHold: RoutineAwakeHold, @unchecked Sendable {
        private let lock = NSLock()
        private var id: IOPMAssertionID?

        init(id: IOPMAssertionID) { self.id = id }

        func release() {
            guard let held = lock.withLock({ () -> IOPMAssertionID? in
                defer { id = nil }
                return id
            }) else { return }
            IOPMAssertionRelease(held)
        }

        deinit { release() }
    }
}

/// The `[Your routines]` notes: for the voice brain each turn it changes, and for every job's instructions.
public enum RoutineNotes {
    /// For the brain: every routine with its schedule, state and next run.
    public static func brainNote(_ routines: [AgentRoutine], now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard !routines.isEmpty else {
            return "[Your routines] None set up. The routines tool creates one when the user wants something done on a schedule."
        }
        var lines = ["[Your routines] Tasks that run on this Mac on a schedule while OpenClicky is open (for your eyes only; manage them with the routines tool)."]
        for routine in routines.prefix(20) { lines.append("- " + line(for: routine, now: now, timeZone: timeZone)) }
        if routines.count > 20 { lines.append("- and \(routines.count - 20) more") }
        return lines.joined(separator: "\n")
    }

    /// For a job's instructions: the current list, marking the routines that run in this job's folder.
    public static func jobNote(_ routines: [AgentRoutine], jobID: String? = nil, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard !routines.isEmpty else { return nil }
        var lines = ["# Your routines", "These routines exist now (this list is current; trust it over anything older):"]
        for routine in routines.prefix(20) {
            let own = jobID != nil && (routine.jobID == jobID || routine.agent == jobID) ? " (runs in this folder)" : ""
            lines.append("- " + line(for: routine, now: now, timeZone: timeZone) + own)
        }
        return lines.joined(separator: "\n")
    }

    static func line(for routine: AgentRoutine, now: Date, timeZone: TimeZone) -> String {
        var line = "\"\(routine.title)\" [\(routine.id)]: \(routine.schedule.phrase)"
        if routine.isPaused { line += ", paused" }
        else if let next = routine.dueAt { line += ", next \(Self.when(next, now: now, timeZone: timeZone))" }
        if routine.runCount > 0 { line += ", \(routine.runCount) run\(routine.runCount == 1 ? "" : "s")" }
        if routine.consecutiveFailures > 0 { line += ", last \(routine.consecutiveFailures) failed" }
        if let deferral = routine.deferral { line += ", \(deferral)" }
        return line
    }

    static func when(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE d MMM HH:mm"
        return date <= now ? "due now" : formatter.string(from: date)
    }
}
