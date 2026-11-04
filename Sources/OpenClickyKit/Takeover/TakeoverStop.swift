import Foundation
import os

/// Why a drive was stopped before the model finished.
public enum TakeoverStopReason: String, Sendable, Hashable, Codable {
    /// The user pressed Escape (or the overlay's Stop).
    case userPressedEscape = "user_pressed_escape"
    /// The user moved the mouse, clicked, scrolled or typed: they took the Mac back.
    case userTookOver = "user_took_over"
    /// The brain called end_screen_takeover.
    case endedByBrain = "ended_by_brain"
    /// A safety rule stopped the drive (repeated refusals, a forbidden window came up).
    case safety
    /// The app is quitting, a newer turn replaced the drive, or a test cancelled it.
    case cancelled
}

/// The hard stop for one drive. Any thread may trip it (the event tap trips it straight from its callback, so
/// Escape works even when the main thread is busy); the actuator checks it before every single event it posts and
/// the drive loop checks it between steps. The first reason wins.
public final class TakeoverStopSwitch: Sendable {
    private let state = OSAllocatedUnfairLock<TakeoverStopReason?>(initialState: nil)

    public init() {}

    /// Stops the drive. Returns true for the call that actually tripped it.
    @discardableResult
    public func trip(_ reason: TakeoverStopReason) -> Bool {
        state.withLock { current in
            guard current == nil else { return false }
            current = reason
            return true
        }
    }

    public var reason: TakeoverStopReason? { state.withLock { $0 } }
    public var isTripped: Bool { reason != nil }

    /// Clears the switch for a new drive.
    public func reset() { state.withLock { $0 = nil } }

    /// Throws `TakeoverStopped` once tripped.
    public func check() throws {
        if let reason { throw TakeoverStopped(reason: reason) }
    }
}

/// Thrown when a drive's stop switch trips in the middle of something.
public struct TakeoverStopped: Error, Sendable, Hashable, CustomStringConvertible {
    public var reason: TakeoverStopReason
    public init(reason: TakeoverStopReason) { self.reason = reason }
    public var description: String { "The drive was stopped (\(reason.rawValue))." }
}

/// Time for the drive loop, the actuator and the rate limiter. `ContinuousTiming` for real drives; tests use a
/// virtual clock that never sleeps.
public protocol DriveTiming: Sendable {
    /// Seconds on a monotonic clock.
    func now() -> Double
    /// Sleeps, throwing on cancellation.
    func sleep(seconds: Double) async throws
}

public struct ContinuousTiming: DriveTiming {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() { origin = clock.now }

    public func now() -> Double {
        let elapsed = clock.now - origin
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .milliseconds(Int((seconds * 1000).rounded())))
    }
}

/// A clock that advances only when something sleeps on it. Every sleep is recorded.
public final class VirtualTiming: DriveTiming {
    private let state = OSAllocatedUnfairLock(initialState: (now: 0.0, sleeps: [Double]()))

    public init(start: Double = 0) { state.withLock { $0.now = start } }

    public func now() -> Double { state.withLock { $0.now } }

    public func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        state.withLock {
            $0.sleeps.append(seconds)
            $0.now += max(seconds, 0)
        }
    }

    /// Moves time forward without a sleep (a slow model call, for example).
    public func advance(_ seconds: Double) { state.withLock { $0.now += seconds } }

    public var sleeps: [Double] { state.withLock { $0.sleeps } }
}

extension DriveTiming {
    /// Sleeps in short slices so a tripped stop switch ends the wait within about a tenth of a second.
    public func sleep(seconds: Double, stop: TakeoverStopSwitch, slice: Double = 0.1) async throws {
        var remaining = seconds
        while remaining > 0 {
            try stop.check()
            let chunk = min(remaining, slice)
            try await sleep(seconds: chunk)
            remaining -= chunk
        }
        try stop.check()
    }
}

/// How fast a drive may act.
public struct DriveRateLimits: Sendable, Hashable {
    /// The least time between two input actions.
    public var minimumInterval: Double
    /// Input actions allowed in any 60-second window.
    public var maximumPerMinute: Int

    public init(minimumInterval: Double = 0.15, maximumPerMinute: Int = 90) {
        self.minimumInterval = minimumInterval
        self.maximumPerMinute = maximumPerMinute
    }
}

/// Spaces out input actions: never closer than `minimumInterval`, never more than `maximumPerMinute` in a sliding
/// minute. Waiting is stop-aware.
public actor DriveRateLimiter {
    public let limits: DriveRateLimits
    private let timing: any DriveTiming
    private var history: [Double] = []

    public init(limits: DriveRateLimits = DriveRateLimits(), timing: any DriveTiming) {
        self.limits = limits
        self.timing = timing
    }

    /// Waits until the next input action may run, then records it.
    public func waitTurn(stop: TakeoverStopSwitch) async throws {
        var now = timing.now()
        if let last = history.last, now - last < limits.minimumInterval {
            try await timing.sleep(seconds: limits.minimumInterval - (now - last), stop: stop)
            now = timing.now()
        }
        history.removeAll { now - $0 >= 60 }
        if limits.maximumPerMinute > 0, history.count >= limits.maximumPerMinute, let oldest = history.first {
            try await timing.sleep(seconds: 60 - (now - oldest), stop: stop)
            now = timing.now()
            history.removeAll { now - $0 >= 60 }
        }
        history.append(now)
    }

    /// Input actions recorded in the last minute.
    public var recentCount: Int {
        let now = timing.now()
        return history.filter { now - $0 < 60 }.count
    }
}
