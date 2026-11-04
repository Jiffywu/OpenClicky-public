import ApplicationServices
import CoreGraphics
import Foundation

/// What the context gatherer reads from the Accessibility tree. A protocol so tests can stand in for live apps.
public protocol AccessibilityContextSource: Sendable {
    var isTrusted: Bool { get }
    /// The app's focused window (title, frame, `AXDocument`). Falls back to the window list without Accessibility.
    func focusedWindow(pid: Int32, layout: DesktopLayout) -> FocusedWindowInfo?
    /// The focused control and its selection. Secure fields report only that they are secure.
    func focusedElement(pid: Int32, layout: DesktopLayout, valuePreviewCharacters: Int) -> FocusedElementInfo?
    /// The address a browser window's address bar shows.
    func browserAddress(pid: Int32) -> String?
    /// The visible text of the browser's web area, collected until the deadline or the character cap.
    func webPageText(pid: Int32, deadline: Duration, maxCharacters: Int) -> (text: String, truncated: Bool)?
}

/// Tells an address bar from other text fields by what browsers call it in their Accessibility tree.
public enum AddressBarHeuristics {
    static let fieldRoles: Set<String> = ["AXTextField", "AXComboBox", "AXSearchField"]
    static let phrases = ["address", "url", "urlbar", "location", "omnibox", "search or enter", "search or type", "enter website", "smart search"]

    public static func isAddressField(role: String?, identifier: String?, description: String?, title: String?, placeholder: String?) -> Bool {
        guard let role, fieldRoles.contains(role) else { return false }
        let haystack = [identifier, description, title, placeholder].compactMap { $0?.lowercased() }
            .map { $0.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ") }
        return haystack.contains { text in
            phrases.contains { phrase in
                // Whole words only, so "curl" or "allocation" don't count.
                text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b", options: .regularExpression) != nil
            }
        }
    }
}

/// Reads context from the live Accessibility tree. Every call is bounded (messaging timeout, node and time limits) so a
/// busy or huge app can't stall a turn.
public struct LiveAccessibilityContext: AccessibilityContextSource {
    public init(messagingTimeout: Float = 0.5) {
        AccessibilityAccess.setMessagingTimeout(seconds: messagingTimeout)
    }

    public var isTrusted: Bool { AccessibilityAccess.isTrusted }

    public func focusedWindow(pid: Int32, layout: DesktopLayout) -> FocusedWindowInfo? {
        if isTrusted, let window = AXNode.application(pid).focusedWindow {
            let values = window.values([kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXDocumentAttribute])
            var frame: CGRect?
            if let origin = AXNode.point(from: values[kAXPositionAttribute]), let size = AXNode.size(from: values[kAXSizeAttribute]) {
                frame = layout.appKitRect(fromQuartz: CGRect(origin: origin, size: size))
            }
            let document = AXNode.string(from: values[kAXDocumentAttribute]).flatMap(Self.documentURL)
            return FocusedWindowInfo(title: AXNode.string(from: values[kAXTitleAttribute]), frame: frame, documentURL: document, source: .accessibility)
        }
        return WindowListReader.frontWindow(pid: pid, layout: layout)
    }

    /// `AXDocument` is usually a file URL string; a few apps give a bare path.
    static func documentURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        return URL(string: trimmed)
    }

    public func focusedElement(pid: Int32, layout: DesktopLayout, valuePreviewCharacters: Int) -> FocusedElementInfo? {
        guard isTrusted else { return nil }
        let app = AXNode.application(pid)
        var element = app.node(kAXFocusedUIElementAttribute)
        if element == nil {
            app.enableManualAccessibility()
            element = app.node(kAXFocusedUIElementAttribute)
        }
        // The app element itself is not a focused control (apps answer with it when nothing has focus).
        guard let element, element != app else { return nil }
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                     kAXPlaceholderValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXTitleUIElementAttribute, kAXNumberOfCharactersAttribute]
        let values = element.values(names)
        let role = AXNode.string(from: values[kAXRoleAttribute])
        let subrole = AXNode.string(from: values[kAXSubroleAttribute])
        let isSecure = subrole == kAXSecureTextFieldSubrole || role == "AXSecureTextField"
        var info = FocusedElementInfo(role: role, subrole: subrole, roleDescription: AXNode.string(from: values[kAXRoleDescriptionAttribute]),
                                      placeholder: AXNode.string(from: values[kAXPlaceholderValueAttribute]), isSecure: isSecure)
        info.label = [AXNode.string(from: values[kAXTitleAttribute]), AXNode.string(from: values[kAXDescriptionAttribute]),
                      AXNode.node(from: values[kAXTitleUIElementAttribute]).flatMap { $0.string(kAXValueAttribute) ?? $0.string(kAXTitleAttribute) }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        if let origin = AXNode.point(from: values[kAXPositionAttribute]), let size = AXNode.size(from: values[kAXSizeAttribute]) {
            info.frame = layout.appKitRect(fromQuartz: CGRect(origin: origin, size: size))
        }
        guard !isSecure else { return info }
        if let selected = element.string(kAXSelectedTextAttribute), !selected.isEmpty { info.selectedText = selected }
        if valuePreviewCharacters > 0, let value = element.string(kAXValueAttribute) {
            info.valueLength = (values[kAXNumberOfCharactersAttribute] as? NSNumber)?.intValue ?? value.count
            info.valuePreview = value.count > valuePreviewCharacters ? String(value.prefix(valuePreviewCharacters)) : value
        }
        return info
    }

    /// How long the address-bar search may take: every Accessibility call can wait out the messaging timeout on a
    /// busy browser, so the node limit alone doesn't bound it.
    static let addressSearchBudget: Duration = .seconds(1)

    public func browserAddress(pid: Int32) -> String? {
        guard isTrusted, let window = AXNode.application(pid).focusedWindow else { return nil }
        let names = [kAXRoleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute,
                     kAXValueAttribute, kAXChildrenAttribute]
        var address: String?
        _ = BoundedTreeSearch.breadthFirst(from: window, maxNodes: 600, maxDepth: 14, until: ContinuousClock.now + Self.addressSearchBudget) { node in
            let values = node.values(names)
            let role = AXNode.string(from: values[kAXRoleAttribute])
            if role == "AXWebArea" { return .skip } // page content, not browser chrome
            if AddressBarHeuristics.isAddressField(role: role, identifier: AXNode.string(from: values[kAXIdentifierAttribute]),
                                                   description: AXNode.string(from: values[kAXDescriptionAttribute]),
                                                   title: AXNode.string(from: values[kAXTitleAttribute]),
                                                   placeholder: AXNode.string(from: values[kAXPlaceholderValueAttribute])),
               let value = AXNode.string(from: values[kAXValueAttribute]), let found = ReadableText.normalizedAddress(value) {
                address = found
                return .found
            }
            return .descend(AXNode.nodes(from: values[kAXChildrenAttribute]))
        }
        return address
    }

    public func webPageText(pid: Int32, deadline: Duration, maxCharacters: Int) -> (text: String, truncated: Bool)? {
        guard isTrusted else { return nil }
        let app = AXNode.application(pid)
        app.enableManualAccessibility()
        guard let window = app.focusedWindow else { return nil }
        let clock = ContinuousClock()
        let end = clock.now + deadline
        guard let webArea = Self.findWebArea(in: window, until: end) else { return nil }
        var collector = WebTextCollector(maxCharacters: maxCharacters)
        var stack: [AXNode] = [webArea]
        var seen: Set<AXNode> = [webArea]
        let names = [kAXRoleAttribute, kAXValueAttribute, kAXPositionAttribute, kAXChildrenAttribute]
        var cutShort = false
        while let node = stack.popLast() {
            if clock.now > end || collector.isFull { cutShort = true; break }
            let values = node.values(names)
            let role = AXNode.string(from: values[kAXRoleAttribute])
            if role == "AXStaticText", let text = AXNode.string(from: values[kAXValueAttribute]) {
                collector.add(text, top: AXNode.point(from: values[kAXPositionAttribute])?.y)
            }
            // Depth-first in document order.
            stack += AXNode.nodes(from: values[kAXChildrenAttribute]).filter { seen.insert($0).inserted }.reversed()
        }
        let text = ReadableText.clean(collector.text)
        guard !text.isEmpty else { return nil }
        let cut = ReadableText.truncate(text, maxCharacters: maxCharacters)
        return (cut.text, cut.truncated || cutShort)
    }

    private static func findWebArea(in window: AXNode, until end: ContinuousClock.Instant) -> AXNode? {
        BoundedTreeSearch.breadthFirst(from: window, maxNodes: 2_000, maxDepth: 20, until: end) { node in
            let values = node.values([kAXRoleAttribute, kAXChildrenAttribute])
            if AXNode.string(from: values[kAXRoleAttribute]) == "AXWebArea" { return .found }
            return .descend(AXNode.nodes(from: values[kAXChildrenAttribute]))
        }
    }
}

/// Breadth-first search of an Accessibility-like tree that stops at a node count, a depth and a deadline, and never
/// visits a node twice (some apps report cyclic trees).
enum BoundedTreeSearch {
    enum Step<Node> {
        /// This is the node being searched for.
        case found
        /// Not it, and nothing below it either.
        case skip
        /// Not it; search these children.
        case descend([Node])
    }

    static func breadthFirst<Node: Hashable>(from root: Node, maxNodes: Int, maxDepth: Int, until end: ContinuousClock.Instant,
                                             now: () -> ContinuousClock.Instant = { ContinuousClock.now },
                                             visit: (Node) -> Step<Node>) -> Node? {
        var queue: [(node: Node, depth: Int)] = [(root, 0)]
        var head = 0
        var seen: Set<Node> = [root]
        while head < queue.count, head < maxNodes, now() < end {
            let (node, depth) = queue[head]
            head += 1
            switch visit(node) {
            case .found: return node
            case .skip: continue
            case .descend(let children):
                guard depth < maxDepth else { continue }
                for child in children where seen.insert(child).inserted { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }
}

/// Joins static-text runs into lines: runs on the same visual line get a space, a new line starts a new line.
struct WebTextCollector {
    let maxCharacters: Int
    private(set) var text = ""
    /// `text.count`, kept as runs are added: counting a long string after every node would eat the walk's deadline.
    private(set) var characterCount = 0
    private var lastTop: CGFloat?

    init(maxCharacters: Int) { self.maxCharacters = maxCharacters }

    var isFull: Bool { characterCount > maxCharacters }

    mutating func add(_ run: String, top: CGFloat?) {
        let trimmed = run.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !text.isEmpty {
            if let top, let lastTop, abs(top - lastTop) < 4 { text += " " } else { text += "\n" }
            characterCount += 1
        }
        text += trimmed
        // Exact unless a run starts with a combining mark (it then joins the space before it): fine for a cap.
        characterCount += trimmed.count
        lastTop = top ?? lastTop
    }
}

/// The front window from the window server's list: bounds always, title only with Screen Recording permission.
public enum WindowListReader {
    public static func frontWindow(pid: Int32, layout: DesktopLayout) -> FocusedWindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        // The list is front to back; the first normal-layer window of the app is its frontmost.
        for entry in list {
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
            var frame: CGRect?
            if let bounds = entry[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds) {
                frame = layout.appKitRect(fromQuartz: rect)
            }
            let title = (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return FocusedWindowInfo(title: title, frame: frame, source: .windowList)
        }
        return nil
    }
}
