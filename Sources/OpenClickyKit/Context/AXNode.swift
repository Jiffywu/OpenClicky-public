import ApplicationServices
import CoreGraphics
import Foundation

/// Accessibility permission, checked without showing the system prompt.
public enum AccessibilityAccess {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Caps how long any single Accessibility request from this process may block on a busy app.
    public static func setMessagingTimeout(seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }
}

/// A typed handle on one Accessibility element. All positions and sizes it reports are Quartz global points
/// (top-left origin of the primary display); convert with `DesktopLayout` before mixing them with AppKit frames.
struct AXNode: @unchecked Sendable, Hashable {
    // AXUIElement is an immutable CF reference that the Accessibility API allows using from any thread.
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    // Equal when they name the same UI element (CFEqual), so tree walks can notice cycles.
    static func == (a: AXNode, b: AXNode) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }

    static func application(_ pid: pid_t) -> AXNode { AXNode(AXUIElementCreateApplication(pid)) }
    static var systemWide: AXNode { AXNode(AXUIElementCreateSystemWide()) }

    var processIdentifier: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    func raw(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? { Self.string(from: raw(attribute)) }
    func bool(_ attribute: String) -> Bool? { Self.bool(from: raw(attribute)) }
    func int(_ attribute: String) -> Int? { (raw(attribute) as? NSNumber)?.intValue }
    func node(_ attribute: String) -> AXNode? { Self.node(from: raw(attribute)) }
    func nodes(_ attribute: String) -> [AXNode] { Self.nodes(from: raw(attribute)) }

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }

    /// Position and size together, in Quartz global points.
    var quartzFrame: CGRect? {
        guard let origin = Self.point(from: raw(kAXPositionAttribute)), let size = Self.size(from: raw(kAXSizeAttribute)) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Several attributes in one round trip to the app (much faster than one call each on big trees).
    /// Attributes the element lacks are absent from the result.
    func values(_ attributes: [String]) -> [String: CFTypeRef] {
        var array: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &array) == .success,
              let values = array as? [CFTypeRef] else { return [:] }
        var result: [String: CFTypeRef] = [:]
        for (name, value) in zip(attributes, values) {
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            result[name] = value
        }
        return result
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    /// A parameterized attribute, e.g. the text of a range.
    func parameterized(_ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success else { return nil }
        return value
    }

    /// The deepest element at a Quartz global point, searched within this element's app (or system-wide).
    func element(atQuartz point: CGPoint) -> AXNode? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(element, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        return AXNode(hit)
    }

    // MARK: Decoding

    static func string(from value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! URL).absoluteString }
        if CFGetTypeID(value) == CFAttributedStringGetTypeID() { return (value as! NSAttributedString).string }
        return nil
    }

    static func bool(from value: CFTypeRef?) -> Bool? {
        guard let value else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
        return (value as? NSNumber)?.boolValue
    }

    static func point(from value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(from value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func range(from value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    static func node(from value: CFTypeRef?) -> AXNode? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXNode(value as! AXUIElement)
    }

    static func nodes(from value: CFTypeRef?) -> [AXNode] {
        guard let array = value as? [CFTypeRef] else { return [] }
        return array.compactMap { node(from: $0) }
    }
}

extension AXNode {
    /// The app's focused window, else its main window, else its first window. Only real windows count: some apps
    /// (and every app while the session is locked) answer window queries with the application element itself.
    var focusedWindow: AXNode? {
        let candidates = [node(kAXFocusedWindowAttribute), node(kAXMainWindowAttribute)].compactMap { $0 } + nodes(kAXWindowsAttribute)
        return candidates.first { $0 != self && $0.role == kAXWindowRole }
    }

    /// Chromium and Electron apps build their Accessibility tree only when asked; this asks. Harmless elsewhere.
    func enableManualAccessibility() {
        set("AXManualAccessibility", kCFBooleanTrue)
    }
}
