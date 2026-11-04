import Testing
@testable import OpenClickyKit

private typealias M = DictationEngagementMachine

@Test func holdThenReleaseCommitsAfterTheBounceGrace() {
    var machine = M()
    #expect(machine.handle(.chordDown(at: 10)) == [.startCapture, .engagementChanged(.holding)])
    #expect(machine.engagement == .holding)
    #expect(machine.handle(.chordUp(at: 11.2)) == [.schedule(.bounce, after: 0.06)])
    #expect(machine.engagement == .holding)
    #expect(machine.handle(.timerFired(.bounce)) == [.commit, .engagementChanged(.idle)])
    #expect(machine.engagement == .idle)
}

@Test func keyBounceDuringAHoldIsIgnored() {
    var machine = M()
    _ = machine.handle(.chordDown(at: 0))
    _ = machine.handle(.chordUp(at: 1.0))
    // The chord comes back within the grace period: still holding, nothing committed.
    #expect(machine.handle(.chordDown(at: 1.03)) == [.cancelTimer(.bounce)])
    #expect(machine.engagement == .holding)
    #expect(machine.handle(.chordUp(at: 2.0)) == [.schedule(.bounce, after: 0.06)])
    #expect(machine.handle(.timerFired(.bounce)) == [.commit, .engagementChanged(.idle)])
}

@Test func aSingleQuickTapIsDiscarded() {
    var machine = M()
    _ = machine.handle(.chordDown(at: 0))
    #expect(machine.handle(.chordUp(at: 0.1)) == [.schedule(.doubleTap, after: 0.4)])
    #expect(machine.handle(.timerFired(.doubleTap)) == [.discard, .engagementChanged(.idle)])
}

@Test func doubleTapLocksHandsFreeAndATapFinishes() {
    var machine = M()
    _ = machine.handle(.chordDown(at: 0))
    _ = machine.handle(.chordUp(at: 0.1))
    #expect(machine.handle(.chordDown(at: 0.3)) == [.cancelTimer(.doubleTap), .engagementChanged(.handsFreeLocked)])
    #expect(machine.engagement == .handsFreeLocked)
    // Letting go of the second tap does not finish.
    #expect(machine.handle(.chordUp(at: 0.4)) == [])
    #expect(machine.engagement == .handsFreeLocked)
    // A stale timer is ignored.
    #expect(machine.handle(.timerFired(.doubleTap)) == [])
    // The next press finishes at once; its release is swallowed.
    #expect(machine.handle(.chordDown(at: 9)) == [.commit, .engagementChanged(.idle)])
    #expect(machine.handle(.chordUp(at: 9.1)) == [])
    #expect(machine.engagement == .idle)
    // And the machine is ready for a new hold.
    #expect(machine.handle(.chordDown(at: 12)) == [.startCapture, .engagementChanged(.holding)])
}

@Test func doubleTapLockCanBeTurnedOff() {
    var machine = M(allowsDoubleTapLock: false)
    _ = machine.handle(.chordDown(at: 0))
    #expect(machine.handle(.chordUp(at: 0.1)) == [.discard, .engagementChanged(.idle)])
}

@Test func typingAShortcutWithTheChordDiscards() {
    var machine = M()
    _ = machine.handle(.chordDown(at: 0))
    #expect(machine.handle(.otherKey(at: 0.1)) == [.discard, .engagementChanged(.idle)])
    // After a real hold has started, other keys are ignored.
    _ = machine.handle(.chordDown(at: 5))
    #expect(machine.handle(.otherKey(at: 6)) == [])
    #expect(machine.engagement == .holding)
}

@Test func handsFreeShortcutAndCancel() {
    var machine = M()
    #expect(machine.handle(.handsFreeToggle) == [.startCapture, .engagementChanged(.handsFreeLocked)])
    #expect(machine.handle(.handsFreeToggle) == [.commit, .engagementChanged(.idle)])
    _ = machine.handle(.handsFreeToggle)
    #expect(machine.handle(.cancel) == [.discard, .engagementChanged(.idle)])
    _ = machine.handle(.chordDown(at: 0))
    _ = machine.handle(.chordUp(at: 1))
    #expect(machine.handle(.cancel) == [.cancelTimer(.bounce), .discard, .engagementChanged(.idle)])
}
