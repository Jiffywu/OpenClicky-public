import CoreGraphics
import Foundation

/// The buddy pointer as the pointing guide drives it (the app's `BuddyPointerController`; a recorder in tests and
/// `occtl guided simulate`). Positions are AppKit global points.
@MainActor
public protocol BuddyPointing: AnyObject {
    /// Fly from the user's pointer to `destination`, ring it and show `label`. `hold` is how long to stay; nil parks
    /// there until `release()` or `cancel()`.
    func fly(to destination: PointingDestination, label: String?, hold: TimeInterval?)
    /// Stop pointing and fly back to the user's pointer.
    func release()
    /// Vanish at once (the target is gone, or the user wants it gone).
    func cancel()
}

/// Decides when the buddy flies during guided walkthroughs and pointing answers (03 §6.4 parking, §7.2 flights):
///
/// - a walkthrough step arms a target: fly to it (the snapped control's frame) and park until the click, then fly back;
///   a target that expires or an off-target click (the walkthrough ends quietly) also sends it back;
/// - an answer's `point()` lands on a control from the turn's element list (named by id, or under the ring): fly there
///   at that mark's beat and hold briefly;
/// - the user starts a turn of their own (barge-in), presses Escape or Stop, or switches apps or Spaces: vanish.
///
/// Only the existing arrowhead buddy is used; there is no character art.
@MainActor
public final class BuddyGuidance {
    /// What the buddy is pointing at.
    public enum Flight: Sendable, Hashable {
        /// A walkthrough target, parked until the step is done.
        case target(Int)
        /// A control a drawing pointed at, held for `pointHold`.
        case element(String)
    }

    public weak var pointer: (any BuddyPointing)?
    /// How long the buddy stays at a control a drawing pointed at.
    public var pointHold: TimeInterval = 2.4
    /// How close (points) a `point()` ring's centre must be to a control to count as pointing at it.
    public var pointReach: CGFloat = 6
    public private(set) var current: Flight?
    /// The buddy flew for the walkthrough since it last vanished. A stop ends a step with `clearTarget` (fly back) and
    /// then `ended(.stopped)`; this makes that stop still vanish rather than fly back.
    private var flewForWalkthrough = false
    /// One line per decision (`occtl guided simulate`, logs).
    public var onLog: ((String) -> Void)?

    public init(pointer: (any BuddyPointing)? = nil) {
        self.pointer = pointer
    }

    // MARK: Walkthrough

    /// Every walkthrough effect, in order.
    public func handle(_ effect: GuidedEffect) {
        switch effect {
        case .showTarget(let target):
            if current == .target(target.id) { return }
            current = .target(target.id)
            flewForWalkthrough = true
            let destination = PointingDestination.rect(target.frame)
            pointer?.fly(to: destination, label: target.name, hold: nil)
            log("buddy flies to target \(target.id) \(Self.quoted(target.name)) and parks")
        case .clearTarget:
            guard case .target = current else { return }
            current = nil
            log("buddy flies back")
            pointer?.release()
        case .ended(let reason):
            switch reason {
            case .stopped, .steppedAway:
                // Escape, Stop, or the target's app or Space is gone: nothing to fly back from.
                if flewForWalkthrough, current == nil { current = .target(0) }
                vanish("walkthrough \(reason.rawValue)")
            case .offTarget, .expired, .completed, .maxRounds:
                flewForWalkthrough = false
                guard current != nil else { return }
                current = nil
                log("buddy flies back (walkthrough \(reason.rawValue))")
                pointer?.release()
            }
        case .startTurn, .refreshCapture:
            break
        }
    }

    // MARK: Drawings

    /// Marks an answer's drawing just released (their line is being heard). Walkthrough markers are left to the
    /// walkthrough (`handle(_:)` sees their target); a `point()` ring on a control flies the buddy there, unless a
    /// walkthrough target holds it.
    public func marksReleased(_ marks: [DrawingMark], screen: GuidedScreen?) {
        guard let screen else { return }
        for mark in marks where mark.json["pointing"]?.boolValue == true {
            if case .target = current { return }
            guard let (element, label) = element(for: mark, on: screen) else { continue }
            current = .element(element.id)
            pointer?.fly(to: .rect(element.frame), label: label, hold: pointHold)
            log("buddy flies to \(element.id) \(Self.quoted(label))")
        }
    }

    /// The control a `point()` mark means: the element it names (`{element: "e12"}`), else a clickable control under
    /// the ring's centre.
    func element(for mark: DrawingMark, on screen: GuidedScreen) -> (ElementSnapshot, String?)? {
        let json = mark.json
        let label = json["pointLabel"]?.stringValue
        if let id = json["element"]?.stringValue, let element = screen.elements.first(where: { $0.id == id }) {
            return (element, label ?? element.label)
        }
        guard let at = json["at"]?.arrayValue, at.count == 2, let x = at[0].doubleValue, let y = at[1].doubleValue,
              x.isFinite, y.isFinite, screen.geometry.containsPixel(CGPoint(x: x, y: y)) else { return nil }
        let center = screen.geometry.appKitPoint(fromPixel: CGPoint(x: x, y: y))
        let spot = CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2)
        guard let snap = GuidedTargetSnapper.choose(for: spot, among: screen.elements, reach: pointReach) else { return nil }
        return (snap.element, label ?? snap.element.label)
    }

    // MARK: The user

    /// The user started a turn of their own (talk key or typed question): the buddy leaves whatever it was showing.
    /// If that turn comes to nothing, the walkthrough shows its target again and the buddy flies back to it.
    public func userTurnStarted() { vanish("the user started a turn") }

    /// Escape or the Stop control.
    public func stop() { vanish("stopped") }

    private func vanish(_ why: String) {
        flewForWalkthrough = false
        guard current != nil else { return }
        current = nil
        log("buddy vanishes (\(why))")
        pointer?.cancel()
    }

    private func log(_ line: String) { onLog?(line) }

    private static func quoted(_ text: String?) -> String { text.map { "\"\($0)\"" } ?? "(no label)" }
}
