import CoreGraphics
import Foundation
import OpenClickyKit

/// Watches the user's mouse and keyboard while a drive runs, on its own thread so Escape works even when the main
/// thread is busy. Real input stops the drive (Escape: "stopped"; anything else: "you took over") through the stop
/// switch, straight from the tap callback; clicks and keys that stop the drive are swallowed so they cannot land in
/// the middle of an action. The drive's own events carry `CGEventActuator.syntheticEventMarker` and pass untouched.
/// `UserInputPolicy` (OpenClickyKit) makes every decision; this class only plumbs events to it.
///
/// Needs Accessibility (or Input Monitoring) permission. Without it `start` throws, and the controller refuses to
/// drive: a drive the user cannot interrupt must never run. A safety timer removes the tap after
/// `maximumLifetime` in case the end of the drive is never reported, and stops a drive still running then (it could
/// no longer be interrupted).
final class TakeoverInputBlocker: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case tapUnavailable
        var description: String {
            "OpenClicky can't watch the keyboard and mouse, so it won't drive: Escape would not stop it. "
                + "Allow OpenClicky in System Settings → Privacy & Security → Accessibility."
        }
    }

    // Guarded by `lock`; the tap callback runs on the blocker's thread.
    private let lock = NSLock()
    private var policy = UserInputPolicy()
    private var stopSwitch: TakeoverStopSwitch?
    private var onStop: (@Sendable (TakeoverStopReason) -> Void)?
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var generation = 0
    private var armedAt = Date.distantPast

    let maximumLifetime: TimeInterval

    init(maximumLifetime: TimeInterval = 660) {
        self.maximumLifetime = maximumLifetime
    }

    var isRunning: Bool { lock.withLock { tap != nil } }

    /// Installs the tap. `onStop` runs (off the main thread) after the switch trips.
    func start(stop: TakeoverStopSwitch, onStop: @escaping @Sendable (TakeoverStopReason) -> Void) throws {
        self.stop()
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                    .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: takeoverInputTapCallback, userInfo: refcon) else {
            throw Failure.tapUnavailable
        }
        let current = lock.withLock { () -> Int in
            policy = UserInputPolicy()
            armedAt = Date()
            stopSwitch = stop
            self.onStop = onStop
            tap = port
            generation += 1
            return generation
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            // The port is read back under the lock rather than captured: CFMachPort is not Sendable.
            guard let self, let port = self.lock.withLock({ self.tap }),
                  let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { ready.signal(); return }
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self.lock.withLock { self.runLoop = loop }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "OpenClicky take-over input"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        DispatchQueue.global().asyncAfter(deadline: .now() + maximumLifetime) { [weak self] in
            guard let self else { return }
            let (isCurrent, stopSwitch, onStop) = self.lock.withLock { (self.generation == current, self.stopSwitch, self.onStop) }
            guard isCurrent else { return }
            // Without the tap nothing could interrupt the drive, so the drive ends with it.
            if stopSwitch?.trip(.safety) == true { onStop?(.safety) }
            self.stop()
        }
    }

    /// Removes the tap; input flows normally again.
    func stop() {
        let (port, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            let result = (tap, runLoop)
            tap = nil
            runLoop = nil
            stopSwitch = nil
            onStop = nil
            generation += 1
            return result
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    /// The tap callback's work: returns nil to swallow the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ tap }) { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let synthetic = event.getIntegerValueField(.eventSourceUserData) == CGEventActuator.syntheticEventMarker
        let kind: UserInputKind
        switch type {
        case .keyDown: kind = .keyDown(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
        case .keyUp: kind = .keyUp(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
        case .flagsChanged: kind = .modifiersChanged
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX), dy = event.getDoubleValueField(.mouseEventDeltaY)
            kind = .pointerMoved(distance: (dx * dx + dy * dy).squareRoot())
        case .scrollWheel: kind = .scroll
        default: kind = .mouseButton
        }
        let (decision, stopSwitch, onStop) = lock.withLock {
            (policy.decide(kind, synthetic: synthetic, elapsed: Date().timeIntervalSince(armedAt)), self.stopSwitch, self.onStop)
        }
        if let reason = decision.stop, stopSwitch?.trip(reason) == true {
            onStop?(reason)
        }
        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }
}

private func takeoverInputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                      refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<TakeoverInputBlocker>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
