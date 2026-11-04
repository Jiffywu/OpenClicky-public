import AppKit
import ApplicationServices
import Foundation

/// Reads the focused text field through the Accessibility API. Needs Accessibility permission for this process
/// (for `occtl`, the terminal app that runs it). Never prompts; callers check `isTrusted` and explain.
public final class AccessibilityFocusReader: FocusReading, @unchecked Sendable {
    public struct Options: Sendable {
        /// Ask Chromium and Electron apps to expose their web content (sets `AXManualAccessibility`).
        public var enableWebAccessibility: Bool
        public var window: SurroundingTextWindow
        /// Seconds to wait for a slow app before an AX call gives up.
        public var messagingTimeout: Float
        /// Values longer than this (UTF-16 units) are read as a window around the selection, not whole.
        public var maxWholeValueLength: Int

        public init(enableWebAccessibility: Bool = true, window: SurroundingTextWindow = SurroundingTextWindow(),
                    messagingTimeout: Float = 0.3, maxWholeValueLength: Int = 40_000) {
            self.enableWebAccessibility = enableWebAccessibility
            self.window = window
            self.messagingTimeout = messagingTimeout
            self.maxWholeValueLength = maxWholeValueLength
        }
    }

    public let options: Options
    private let lock = NSLock()
    private var enabledProcesses: Set<pid_t> = []

    public init(options: Options = Options()) { self.options = options }

    /// Whether this process may use Accessibility. Does not prompt.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public func captureFocus() -> Result<CapturedFocus, FocusReadError> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, options.messagingTimeout)

        var app: AXUIElement? = AX.element(systemWide, "AXFocusedApplication")
        if app == nil, let front = NSWorkspace.shared.frontmostApplication {
            app = AXUIElementCreateApplication(front.processIdentifier)
        }
        guard let app else { return .failure(.noFocusedApplication) }
        AXUIElementSetMessagingTimeout(app, options.messagingTimeout)
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        let running = NSRunningApplication(processIdentifier: pid)
        let bundleID = running?.bundleIdentifier
        let appName = running?.localizedName

        var justEnabled = false
        if options.enableWebAccessibility,
           AppTraits.needsManualAccessibility(bundleID: bundleID, bundleURL: running?.bundleURL) {
            justEnabled = enableWebAccessibility(app: app, pid: pid, isChromiumBrowser: bundleID.map(AppTraits.chromiumBrowsers.contains) ?? false)
        }

        var focused: AXUIElement? = AX.element(app, "AXFocusedUIElement")
        if focused == nil && justEnabled {
            // The app builds its tree on request; give it a moment once.
            Thread.sleep(forTimeInterval: 0.08)
            focused = AX.element(app, "AXFocusedUIElement")
        }
        if focused == nil { focused = AX.element(systemWide, "AXFocusedUIElement") }
        guard let element = focused else { return .failure(.noFocusedElement(appName: appName, processID: pid)) }
        AXUIElementSetMessagingTimeout(element, options.messagingTimeout)

        let snapshot = snapshot(of: element, appName: appName, bundleID: bundleID, pid: pid)
        let context = FocusContext(snapshot: snapshot, window: options.window)
        return .success(CapturedFocus(context: context, element: FocusElement(element)))
    }

    /// The element's current value, for verifying an insertion and for learning corrections.
    public func value(of element: FocusElement) -> String? {
        guard CFGetTypeID(element.raw as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return AX.string(element.raw as! AXUIElement, "AXValue")
    }

    func snapshot(of element: AXUIElement, appName: String?, bundleID: String?, pid: pid_t) -> FocusSnapshot {
        var s = FocusSnapshot(appName: appName, bundleID: bundleID, processID: pid)
        s.role = AX.string(element, "AXRole")
        s.subrole = AX.string(element, "AXSubrole")
        s.roleDescription = AX.string(element, "AXRoleDescription")
        s.selection = AX.range(element, "AXSelectedTextRange")
        s.characterCount = AX.int(element, "AXNumberOfCharacters")
        s.isValueSettable = AX.isSettable(element, "AXValue")
        s.isSelectedTextSettable = AX.isSettable(element, "AXSelectedText")
        if let origin = AX.point(element, "AXPosition"), let size = AX.size(element, "AXSize") {
            s.frame = FocusFrame(x: origin.x, y: origin.y, width: size.width, height: size.height)
        }
        let secure = s.subrole == "AXSecureTextField"
        if !secure {
            s.selectedText = AX.string(element, "AXSelectedText")
            if let count = s.characterCount, count > options.maxWholeValueLength, let selection = s.selection {
                let beforeStart = max(0, selection.location - options.window.before)
                s.windowBefore = AX.string(element, forRange: UTF16Range(location: beforeStart, length: selection.location - beforeStart))
                let afterLength = min(options.window.after, max(0, count - selection.end))
                s.windowAfter = AX.string(element, forRange: UTF16Range(location: selection.end, length: afterLength))
            } else {
                s.value = AX.string(element, "AXValue")
            }
        }
        if AppTraits.isBrowser(bundleID) { s.url = webAreaURL(above: element) }
        return s
    }

    /// Chromium and Electron build their Accessibility tree only for assistive clients that ask. Returns true the
    /// first time a process is switched on.
    private func enableWebAccessibility(app: AXUIElement, pid: pid_t, isChromiumBrowser: Bool) -> Bool {
        let already = lock.withLock { enabledProcesses.contains(pid) }
        if already { return false }
        var result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if result != .success && isChromiumBrowser {
            result = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        lock.withLock { _ = enabledProcesses.insert(pid) }
        return result == .success
    }

    /// The page URL of the web area that contains the element, if any.
    private func webAreaURL(above element: AXUIElement) -> URL? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return nil }
            if AX.string(node, "AXRole") == "AXWebArea" {
                if let url = AX.copy(node, "AXURL") as? URL { return url }
                if let text = AX.string(node, "AXURL") { return URL(string: text) }
                return nil
            }
            current = AX.element(node, "AXParent")
        }
        return nil
    }
}

/// Small typed wrappers over the C Accessibility API.
enum AX {
    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute) else { return nil }
        if let text = value as? String { return text }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        (copy(element, attribute) as? NSNumber)?.intValue
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String, type: AXValueType) -> AXValue? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        return AXValueGetType(axValue) == type ? axValue : nil
    }

    static func range(_ element: AXUIElement, _ attribute: String) -> UTF16Range? {
        guard let value = axValue(element, attribute, type: .cfRange) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return UTF16Range(location: range.location, length: range.length)
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(element, attribute, type: .cgPoint) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(element, attribute, type: .cgSize) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    static func string(_ element: AXUIElement, forRange range: UTF16Range) -> String? {
        guard range.length > 0 else { return "" }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, parameter, &value) == .success
        else { return nil }
        return value as? String
    }

    static func setRange(_ element: AXUIElement, _ attribute: String, _ range: UTF16Range) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }
}
