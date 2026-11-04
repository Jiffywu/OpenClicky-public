import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Reads the real Mac for the safety check.
///
/// - The window under a point comes from the Core Graphics window list (front to back), which names each window's
///   owner without any permission. OpenClicky's own click-through overlay windows are skipped (`ignoredWindows`).
/// - The element under a point and the focused element come from Accessibility (nil until it is trusted; a drive
///   needs Accessibility anyway to post events). When no element reports focus, the front app answers for where
///   keystrokes go.
/// - Secure keyboard entry comes from `IsSecureEventInputEnabled`.
public struct MacTakeoverProbe: TakeoverEnvironmentProbe {
    /// Window numbers to look through (OpenClicky's overlay panels).
    public var ignoredWindows: @Sendable () -> Set<Int>

    public init(ignoredWindows: @escaping @Sendable () -> Set<Int> = { [] }) {
        self.ignoredWindows = ignoredWindows
        AccessibilityAccess.setMessagingTimeout(seconds: 0.5)
    }

    public func target(atQuartz point: CGPoint) async -> DriveTargetInfo? {
        var info = Self.window(at: point, ignoring: ignoredWindows()) ?? DriveTargetInfo()
        if AccessibilityAccess.isTrusted, let node = AXNode.systemWide.element(atQuartz: point) {
            let values = node.values([kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute])
            info.role = AXNode.string(from: values[kAXRoleAttribute])
            info.subrole = AXNode.string(from: values[kAXSubroleAttribute])
            info.label = AXNode.string(from: values[kAXTitleAttribute]) ?? AXNode.string(from: values[kAXDescriptionAttribute])
            if info.ownerPID == nil, let pid = node.processIdentifier { Self.fillOwner(&info, pid: pid) }
        }
        return info == DriveTargetInfo() ? nil : info
    }

    public func focusedTarget() async -> DriveTargetInfo? {
        if AccessibilityAccess.isTrusted, let node = AXNode.systemWide.node(kAXFocusedUIElementAttribute) {
            var info = DriveTargetInfo(role: node.role, subrole: node.subrole, label: node.string(kAXTitleAttribute))
            if let pid = node.processIdentifier { Self.fillOwner(&info, pid: pid) }
            return info
        }
        let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        return Self.keyboardTarget(focused: nil, frontPID: front)
    }

    /// Where keystrokes go: the focused element when Accessibility names one, else the front app (keys still reach it
    /// when nothing reports focus or Accessibility is off, so the owner checks must still see it).
    static func keyboardTarget(focused: DriveTargetInfo?, frontPID: Int32?) -> DriveTargetInfo? {
        if let focused { return focused }
        guard let frontPID else { return nil }
        var info = DriveTargetInfo()
        fillOwner(&info, pid: frontPID)
        return info
    }

    public func isSecureInputEnabled() async -> Bool { IsSecureEventInputEnabled() }

    public func cursorLocation() async -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// The frontmost on-screen window containing a Quartz point, skipping `ignoring` and fully transparent windows.
    static func window(at point: CGPoint, ignoring: Set<Int>) -> DriveTargetInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in list {
            guard let number = window[kCGWindowNumber as String] as? Int, !ignoring.contains(number),
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary), bounds.contains(point) else { continue }
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            var info = DriveTargetInfo(ownerName: window[kCGWindowOwnerName as String] as? String,
                                       windowTitle: window[kCGWindowName as String] as? String)
            if let pid = window[kCGWindowOwnerPID as String] as? Int32 { fillOwner(&info, pid: pid) }
            return info
        }
        return nil
    }

    static func fillOwner(_ info: inout DriveTargetInfo, pid: Int32) {
        info.ownerPID = pid
        let app = NSRunningApplication(processIdentifier: pid)
        info.ownerBundleID = info.ownerBundleID ?? app?.bundleIdentifier
        info.ownerName = info.ownerName ?? app?.localizedName
    }
}

/// What the user did while a drive runs, as the input monitor sees it.
public enum UserInputKind: Sendable, Hashable {
    case keyDown(keyCode: Int64)
    case keyUp(keyCode: Int64)
    /// A modifier key alone (shift, command…).
    case modifiersChanged
    /// The pointer moved by this many points since the last event.
    case pointerMoved(distance: Double)
    case mouseButton
    case scroll
}

/// Decides what to do with each user event while a drive runs: auto-stop on any real input, with Escape as an
/// explicit stop. Pure, so the event tap's behavior is tested without one.
///
/// - Events OpenClicky synthesized (marked with `CGEventActuator.syntheticEventMarker`) pass and never stop anything.
/// - Escape stops (`userPressedEscape`) and is swallowed so the app underneath does not also get it.
/// - Any other key, click or scroll stops (`userTookOver`) and is swallowed, so a half-done action is not disturbed;
///   the user has control as soon as the monitor is removed a moment later.
/// - Pointer movement stops once it adds up to more than `moveTolerance` points (a nudge of the desk is not a
///   takeover); movement itself is never swallowed. Movement in the first `movementGraceSeconds` after the monitor
///   is armed does not count: the user's hand is still leaving the mouse after clicking the card.
/// - Modifier keys alone are ignored. After the first stop, everything passes.
public struct UserInputPolicy: Sendable, Hashable {
    public struct Decision: Sendable, Hashable {
        public var swallow: Bool
        public var stop: TakeoverStopReason?
        public static let pass = Decision(swallow: false, stop: nil)
    }

    public var moveTolerance: Double
    public var movementGraceSeconds: Double
    public private(set) var moved: Double = 0
    public private(set) var stopped: TakeoverStopReason?
    /// Key-ups to swallow because their key-down was swallowed.
    private var swallowedKeys: Set<Int64> = []

    public init(moveTolerance: Double = 24, movementGraceSeconds: Double = 1) {
        self.moveTolerance = moveTolerance
        self.movementGraceSeconds = movementGraceSeconds
    }

    /// - Parameter elapsed: seconds since the monitor was armed.
    public mutating func decide(_ kind: UserInputKind, synthetic: Bool, elapsed: Double = .infinity) -> Decision {
        if synthetic { return .pass }
        if case .keyUp(let code) = kind, swallowedKeys.remove(code) != nil { return Decision(swallow: true, stop: nil) }
        guard stopped == nil else { return .pass }
        switch kind {
        case .keyDown(let code):
            swallowedKeys.insert(code)
            let reason: TakeoverStopReason = code == Int64(kVK_Escape) ? .userPressedEscape : .userTookOver
            stopped = reason
            return Decision(swallow: true, stop: reason)
        case .keyUp, .modifiersChanged:
            return .pass
        case .pointerMoved(let distance):
            guard elapsed >= movementGraceSeconds else { return .pass }
            moved += max(distance, 0)
            guard moved > moveTolerance else { return .pass }
            stopped = .userTookOver
            return Decision(swallow: false, stop: .userTookOver)
        case .mouseButton, .scroll:
            stopped = .userTookOver
            return Decision(swallow: true, stop: .userTookOver)
        }
    }
}
