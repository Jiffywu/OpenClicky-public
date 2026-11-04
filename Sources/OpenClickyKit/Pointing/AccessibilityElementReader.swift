import ApplicationServices
import CoreGraphics
import Foundation

/// Walks the front window's Accessibility tree and records each visible control or text with its role, label and
/// frame. Needs Accessibility permission.
public struct AccessibilityElementReader: Sendable {
    public struct Limits: Sendable, Hashable {
        public var maxDepth: Int
        /// Tree nodes visited.
        public var maxNodes: Int
        /// Elements kept.
        public var maxElements: Int
        /// Children followed per node (long lists and tables).
        public var maxChildrenPerNode: Int
        public var deadline: Duration
        /// Keep plain text runs (static text), not just controls and headings.
        public var includeStaticText: Bool

        public init(maxDepth: Int = 40, maxNodes: Int = 4_000, maxElements: Int = 800, maxChildrenPerNode: Int = 400,
                    deadline: Duration = .milliseconds(1500), includeStaticText: Bool = true) {
            self.maxDepth = maxDepth
            self.maxNodes = maxNodes
            self.maxElements = maxElements
            self.maxChildrenPerNode = maxChildrenPerNode
            self.deadline = deadline
            self.includeStaticText = includeStaticText
        }
    }

    public var limits: Limits

    public init(limits: Limits = Limits(), messagingTimeout: Float = 0.5) {
        self.limits = limits
        AccessibilityAccess.setMessagingTimeout(seconds: messagingTimeout)
    }

    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXHelpAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
        kAXFocusedAttribute, kAXChildrenAttribute, kAXTitleUIElementAttribute,
    ]

    /// The snapshot of `app`'s focused window, or nil without permission or without a window.
    public func snapshot(of app: FrontAppInfo, layout: DesktopLayout = .current()) -> WindowElementSnapshot? {
        guard AccessibilityAccess.isTrusted else { return nil }
        let application = AXNode.application(app.processIdentifier)
        application.enableManualAccessibility()
        guard let window = application.focusedWindow else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        let windowValues = window.values([kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute])
        var windowFrameQuartz: CGRect?
        if let origin = AXNode.point(from: windowValues[kAXPositionAttribute]), let size = AXNode.size(from: windowValues[kAXSizeAttribute]) {
            windowFrameQuartz = CGRect(origin: origin, size: size)
        }

        var elements: [ElementSnapshot] = []
        var stack: [(AXNode, Int)] = [(window, 0)]
        var seen: Set<AXNode> = [window]
        var visited = 0
        var truncated = false
        while let (node, depth) = stack.popLast() {
            if visited >= limits.maxNodes || elements.count >= limits.maxElements || clock.now - start > limits.deadline {
                truncated = true
                break
            }
            visited += 1
            let values = node.values(Self.attributes)
            guard let role = AXNode.string(from: values[kAXRoleAttribute]) else { continue }
            var quartzFrame: CGRect?
            if let origin = AXNode.point(from: values[kAXPositionAttribute]), let size = AXNode.size(from: values[kAXSizeAttribute]) {
                quartzFrame = CGRect(origin: origin, size: size)
            }
            // Skip whole subtrees that are scrolled out of the window: they can't be pointed at.
            if let quartzFrame, let windowFrameQuartz, depth > 0, quartzFrame.width > 0, quartzFrame.height > 0,
               !quartzFrame.intersects(windowFrameQuartz) {
                continue
            }
            if depth > 0, let quartzFrame, quartzFrame.width >= 1, quartzFrame.height >= 1, keeps(role: role) {
                var element = ElementSnapshot(
                    id: "e\(elements.count + 1)", role: role,
                    subrole: AXNode.string(from: values[kAXSubroleAttribute]),
                    roleDescription: AXNode.string(from: values[kAXRoleDescriptionAttribute]),
                    title: AXNode.string(from: values[kAXTitleAttribute]),
                    detail: AXNode.string(from: values[kAXDescriptionAttribute]),
                    value: role == "AXSecureTextField" || AXNode.string(from: values[kAXSubroleAttribute]) == "AXSecureTextField"
                        ? nil : AXNode.string(from: values[kAXValueAttribute]).map { String($0.prefix(500)) },
                    help: AXNode.string(from: values[kAXHelpAttribute]),
                    identifier: AXNode.string(from: values[kAXIdentifierAttribute]),
                    placeholder: AXNode.string(from: values[kAXPlaceholderValueAttribute]),
                    frame: layout.appKitRect(fromQuartz: quartzFrame),
                    isEnabled: AXNode.bool(from: values[kAXEnabledAttribute]) ?? true,
                    isFocused: AXNode.bool(from: values[kAXFocusedAttribute]) ?? false,
                    depth: depth)
                // A field labeled by a separate text element ("Name: [      ]").
                if element.title == nil, element.detail == nil, let labelNode = AXNode.node(from: values[kAXTitleUIElementAttribute]) {
                    element.title = labelNode.string(kAXValueAttribute) ?? labelNode.string(kAXTitleAttribute)
                }
                if element.isActionable || element.label != nil || role == "AXImage" {
                    elements.append(element)
                }
            }
            if depth < limits.maxDepth {
                let children = AXNode.nodes(from: values[kAXChildrenAttribute])
                if children.count > limits.maxChildrenPerNode { truncated = true }
                // Reverse so the stack pops children in document order; never revisit an element (cyclic trees exist).
                let fresh = children.prefix(limits.maxChildrenPerNode).filter { seen.insert($0).inserted }
                stack += fresh.reversed().map { ($0, depth + 1) }
            }
        }
        return WindowElementSnapshot(
            app: app, windowTitle: AXNode.string(from: windowValues[kAXTitleAttribute]),
            windowFrame: windowFrameQuartz.map { layout.appKitRect(fromQuartz: $0) },
            elements: elements, isTruncated: truncated, elapsed: clock.now - start)
    }

    private func keeps(role: String) -> Bool {
        if ElementRoles.actionable.contains(role) { return true }
        switch role {
        case "AXHeading", "AXImage", "AXValueIndicator", "AXProgressIndicator", "AXLevelIndicator": return true
        case "AXStaticText": return limits.includeStaticText
        default: return false
        }
    }

    /// The element at an AppKit global point, for snapping: the deepest element there, walked up to the nearest
    /// actionable ancestor.
    public func element(at point: CGPoint, in app: FrontAppInfo, layout: DesktopLayout = .current()) -> ElementSnapshot? {
        guard AccessibilityAccess.isTrusted else { return nil }
        let quartz = layout.quartzPoint(fromAppKit: point)
        var node = AXNode.application(app.processIdentifier).element(atQuartz: quartz)
        var hops = 0
        var seen: Set<AXNode> = []
        while let current = node, hops < 8, seen.insert(current).inserted {
            let values = current.values(Self.attributes + [kAXParentAttribute])
            if let role = AXNode.string(from: values[kAXRoleAttribute]), ElementRoles.actionable.contains(role),
               let origin = AXNode.point(from: values[kAXPositionAttribute]), let size = AXNode.size(from: values[kAXSizeAttribute]) {
                return ElementSnapshot(id: "hit", role: role, subrole: AXNode.string(from: values[kAXSubroleAttribute]),
                                       title: AXNode.string(from: values[kAXTitleAttribute]), detail: AXNode.string(from: values[kAXDescriptionAttribute]),
                                       value: nil, identifier: AXNode.string(from: values[kAXIdentifierAttribute]),
                                       frame: layout.appKitRect(fromQuartz: CGRect(origin: origin, size: size)),
                                       isEnabled: AXNode.bool(from: values[kAXEnabledAttribute]) ?? true)
            }
            node = AXNode.node(from: values[kAXParentAttribute])
            hops += 1
        }
        return nil
    }
}
