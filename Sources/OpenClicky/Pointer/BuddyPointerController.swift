import AppKit
import OpenClickyKit

/// Drives the buddy pointer: one pointing gesture at a time, shared by every display's overlay layer.
///
///     await model.pointer.point(to: .pixel(CGPoint(x: 812, y: 96), capture.geometry), label: "Share")
///
/// The buddy appears at the user's pointer, flies along an arc to the target, rings it and shows the label, holds,
/// then flies back to wherever the user's pointer is by then and fades into it. A new `point` replaces the current
/// gesture; switching Spaces cancels it (the target is no longer on screen).
@MainActor
@Observable
final class BuddyPointerController {
    private(set) var gesture: PointerGesture?
    private(set) var startedAt = Date.distantPast
    var style = BuddyPointerStyle.standard
    /// The user's pointer in AppKit global points. Replaceable for tests and demos.
    @ObservationIgnored var cursorLocation: () -> CGPoint = { NSEvent.mouseLocation }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var spaceObserver: NSObjectProtocol?

    init() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    var isActive: Bool { gesture != nil }

    /// Points at `destination` and returns when the gesture is over (or was replaced or cancelled).
    /// `hold` is how long to stay pointing; nil stays until `release()`, e.g. while waiting for the user's click.
    func point(to destination: PointingDestination, label: String?, hold: TimeInterval? = 2.4) async {
        begin(destination, label: label, hold: hold)
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Starts the gesture now, replacing any other, without waiting for it to end.
    private func begin(_ destination: PointingDestination, label: String?, hold: TimeInterval?) {
        cancel()
        generation += 1
        gesture = PointerGesture(from: cursorLocation(), to: destination.resolved, label: label, hold: hold,
                                 reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        startedAt = Date()
        scheduleFinish()
    }

    func point(toGlobal point: CGPoint, label: String?, hold: TimeInterval? = 2.4) async {
        await self.point(to: .point(point), label: label, hold: hold)
    }

    /// Outlines an element from an Accessibility snapshot; the label defaults to the element's own.
    func point(toElement element: ElementSnapshot, label: String? = nil, hold: TimeInterval? = 2.4) async {
        await point(to: .rect(element.frame), label: label ?? element.label, hold: hold)
    }

    /// Points at a pixel of a screenshot, the way a model answers.
    func point(toPixel pixel: CGPoint, in capture: ScreenCapture, label: String?, hold: TimeInterval? = 2.4) async {
        await point(to: .pixel(pixel, capture.geometry), label: label, hold: hold)
    }

    /// Resolves `query` ("the Save button") against a snapshot and points at the best match. False if nothing matched.
    @discardableResult
    func point(toLabel query: String, in snapshot: WindowElementSnapshot, label: String? = nil, hold: TimeInterval? = 2.4) async -> Bool {
        guard let match = snapshot.resolve(label: query) else { return false }
        await point(to: .rect(match.element.frame), label: label ?? match.element.label ?? query, hold: hold)
        return true
    }

    /// Stop pointing and fly back now.
    func release() {
        guard var gesture else { return }
        gesture.release(at: Date().timeIntervalSince(startedAt))
        self.gesture = gesture
        scheduleFinish()
    }

    /// Vanish immediately.
    func cancel() {
        finishTask?.cancel()
        finishTask = nil
        gesture = nil
        resumeWaiters()
    }

    /// The frame to draw at `date`, or nil when idle.
    func frame(at date: Date) -> PointerFrame? {
        gesture?.frame(at: date.timeIntervalSince(startedAt), cursor: cursorLocation())
    }

    private func scheduleFinish() {
        finishTask?.cancel()
        guard let end = gesture?.endTime else { return }
        let remaining = max(0, end - Date().timeIntervalSince(startedAt))
        let current = generation
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.finish(generation: current)
        }
    }

    private func finish(generation finished: Int) {
        guard finished == generation else { return }
        gesture = nil
        finishTask = nil
        resumeWaiters()
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// The pointing guide flies the buddy without waiting for the gesture to end (`BuddyGuidance`).
extension BuddyPointerController: BuddyPointing {
    func fly(to destination: PointingDestination, label: String?, hold: TimeInterval?) {
        // Synchronous, so a release or cancel right after it applies to this flight.
        begin(destination, label: label, hold: hold)
    }
}
