import Foundation

// Helpers for tests that wait on something happening elsewhere. The suite runs its tests in parallel, often on a
// machine that is busy compiling, so a timer or a thread can run far later than it would on an idle machine. Wait
// for the event itself, and keep any time limit a hang guard rather than part of what a test checks.

/// Polls `condition` until it holds or `limit` passes, and returns whether it held. The limit only guards against a
/// hang, so keep it generous: a busy machine can take far longer than an idle one. Runs on the caller's actor, so the
/// condition may read state isolated to it.
func waitUntil(_ limit: Duration = .seconds(10), isolation: isolated (any Actor)? = #isolation,
               _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        if ContinuousClock.now >= deadline { return condition() }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// CPU time used so far by the calling thread. Unlike the wall clock it stands still while a busy machine has the
/// thread parked, so a bound on the cost of synchronous work holds however loaded the machine is.
func threadCPUTime() -> Duration {
    .nanoseconds(Int64(clamping: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
}

/// A true/false one task sets and another reads.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
