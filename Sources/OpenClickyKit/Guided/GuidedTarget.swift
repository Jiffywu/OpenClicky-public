import CoreGraphics
import Foundation

// Guided walkthroughs (03 §6.4, §6.5, §9): the brain names one control for the user to click (or rest the pointer
// on), the app rings the real control and waits, and the click starts the next turn by itself. This file turns what
// the brain named into a target on the screen, snapped to the nearest Accessibility element.

/// What the brain asked the user to click or hover, before it is placed on the screen.
public struct GuidedTargetRequest: Sendable, Hashable {
    public enum Place: Sendable, Hashable {
        /// An element from the turn's element list ("e12").
        case element(String)
        /// A box in the screenshot's pixels (the drawing canvas), top-left origin.
        case pixelRect(CGRect)
        /// A ring around a pixel: centre and radius in pixels (nil radius: the default).
        case pixelRing(center: CGPoint, radius: CGFloat?)
        /// A rectangle already in AppKit global points.
        case globalRect(CGRect)
    }

    public var place: Place
    public var label: String?
    /// The sentence that asked for it ("Click Export in the File menu.").
    public var instruction: String?
    /// Done when the pointer rests on it, not when it is clicked.
    public var isHover: Bool

    public init(_ place: Place, label: String? = nil, instruction: String? = nil, isHover: Bool = false) {
        self.place = place
        self.label = label
        self.instruction = instruction
        self.isHover = isHover
    }
}

/// A target on the screen, in AppKit global points (bottom-left origin, y up), ready to be shown and hit-tested.
public struct GuidedTarget: Sendable, Hashable {
    public var id: Int
    public var label: String?
    public var instruction: String?
    public var isHover: Bool
    /// Where the brain said the control is.
    public var requestedFrame: CGRect
    /// The control the target snapped to, when one was found.
    public var element: ElementSnapshot?
    /// Why it snapped (or didn't).
    public var snap: GuidedSnap.Reason
    /// The smallest radius a ring target gets, so small or slightly-off answers are still easy to hit.
    public var minimumRadius: CGFloat

    public init(id: Int, label: String?, instruction: String? = nil, isHover: Bool = false, requestedFrame: CGRect,
                element: ElementSnapshot? = nil, snap: GuidedSnap.Reason = .none, minimumRadius: CGFloat = 28) {
        self.id = id
        self.label = label
        self.instruction = instruction
        self.isHover = isHover
        self.requestedFrame = requestedFrame
        self.element = element
        self.snap = snap
        self.minimumRadius = minimumRadius
    }

    /// The frame shown and hit-tested: the snapped control's, else the requested one.
    public var frame: CGRect { element?.frame ?? requestedFrame }
    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    /// Drawn as the control's outline when snapped, as a ring otherwise.
    public var isControlOutline: Bool { element != nil }
    public var radius: CGFloat { max(minimumRadius, hypot(frame.width, frame.height) / 2) }
    /// The words to show and say: the brain's label, else the control's own.
    public var name: String? { label ?? element?.label }

    /// Whether a click at `point` (AppKit global) counts. A snapped control counts within `slop` points of its frame;
    /// a ring counts within its radius or its box.
    public func contains(_ point: CGPoint, slop: CGFloat = 6) -> Bool {
        if let element { return element.frame.insetBy(dx: -slop, dy: -slop).contains(point) }
        if requestedFrame.insetBy(dx: -slop, dy: -slop).contains(point) { return true }
        return hypot(point.x - center.x, point.y - center.y) <= radius + slop
    }

    /// Points from `point` to the target (0 inside).
    public func distance(to point: CGPoint) -> CGFloat { DesktopLayout.distance(from: point, to: frame) }
}

/// The screen the brain answered about: the drawing canvas is this screenshot's pixels, and `elements` are the front
/// window's controls (AppKit global frames) the brain can name by id.
public struct GuidedScreen: Sendable, Hashable {
    public var geometry: CaptureGeometry
    public var elements: [ElementSnapshot]
    /// The screenshot itself (JPEG or PNG of `geometry`'s pixels), for grounding a target nothing else can place.
    public var screenshot: Data?

    public init(geometry: CaptureGeometry, elements: [ElementSnapshot] = [], screenshot: Data? = nil) {
        self.geometry = geometry
        self.elements = elements
        self.screenshot = screenshot
    }

    /// The pointer's screenshot and the front window's elements from a turn's look.
    public init?(look: TurnLook) {
        guard let capture = look.orderedCaptures.first else { return nil }
        self.init(geometry: capture.geometry, elements: look.elements?.elements ?? [])
    }

    /// Where a request points, in AppKit global points, and the element it names directly (by id), if any.
    public func frame(for place: GuidedTargetRequest.Place, defaultRadius: CGFloat = 24) -> (frame: CGRect, element: ElementSnapshot?)? {
        switch place {
        case .element(let id):
            guard let element = elements.first(where: { $0.id == id }) else { return nil }
            return (element.frame, element)
        case .pixelRect(let rect):
            let standard = rect.standardized
            guard standard.minX.isFinite, standard.minY.isFinite, standard.width.isFinite, standard.height.isFinite else { return nil }
            return (geometry.appKitRect(fromPixelRect: standard), nil)
        case .pixelRing(let center, let radius):
            guard center.x.isFinite, center.y.isFinite else { return nil }
            let r = max(4, (radius.map { abs($0) } ?? defaultRadius))
            return (geometry.appKitRect(fromPixelRect: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)), nil)
        case .globalRect(let rect):
            return (rect.standardized, nil)
        }
    }
}

/// How a target was matched to a real control.
public struct GuidedSnap: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable {
        /// The brain named the element by id.
        case named
        /// The control contains the centre of what the brain pointed at.
        case containsCenter = "contains_center"
        /// The control overlaps the brain's box well.
        case overlaps
        /// The nearest control within reach.
        case nearby
        /// Found by asking Accessibility what is at the point.
        case hitTest = "hit_test"
        /// Placed where a computer-use model said the control is (grounding), with no control there to snap to.
        case grounded
        /// No control was close enough: the brain's own box is used.
        case none
    }

    public var element: ElementSnapshot
    public var reason: Reason
    /// Points from the requested centre to the control (0 inside).
    public var distance: CGFloat
    /// Intersection over union with the requested box.
    public var overlap: CGFloat
}

/// Picks the control a guided target means (03 §6.5): a real control at or near the brain's box, so the ring outlines
/// the actual button and a click on any part of it counts.
public enum GuidedTargetSnapper {
    /// Controls a click can complete a step on: the roles HeyClicky snaps to (03 §6.5), plus tabs and combo boxes.
    public static let clickableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXPopUpButton", "AXSearchField", "AXIncrementor", "AXColorWell", "AXDockItem", "AXLink",
        "AXMenuButton", "AXRadioButton", "AXDisclosureTriangle", "AXSwitch", "AXMenuBarItem", "AXCheckBox", "AXTextField",
        "AXCell", "AXTab", "AXComboBox",
    ]
    /// Subroles that make an element clickable whatever its role (toolbar buttons in some apps).
    public static let clickableSubroles: Set<String> = ["AXToolbarButton", "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXSearchField"]

    public static func isClickable(_ element: ElementSnapshot) -> Bool {
        guard element.frame.width >= 2, element.frame.height >= 2 else { return false }
        if ElementRoles.containers.contains(element.role) { return false }
        // Whole rows of a list, sidebars, web areas sized like a page: never a single step's target.
        if element.frame.width > 900 || element.frame.height > 600 { return false }
        return clickableRoles.contains(element.role) || element.subrole.map(clickableSubroles.contains) == true
    }

    /// The control `requested` (AppKit global) means, or nil when none is within `reach` points.
    ///
    /// In order: controls containing the requested centre (the one that best overlaps the box wins, then the smallest:
    /// a button inside a table cell beats the cell), then controls overlapping the box by at least 30%, then the
    /// nearest control within `reach`. Enabled controls beat disabled ones at every step.
    public static func choose(for requested: CGRect, among elements: [ElementSnapshot], reach: CGFloat = 28) -> GuidedSnap? {
        let center = CGPoint(x: requested.midX, y: requested.midY)
        let candidates = elements.filter(isClickable)
        func area(_ e: ElementSnapshot) -> CGFloat { e.frame.width * e.frame.height }
        func iou(_ e: ElementSnapshot) -> CGFloat {
            let inter = e.frame.intersection(requested)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
            let union = area(e) + requested.width * requested.height - inter.width * inter.height
            return union > 0 ? inter.width * inter.height / union : 0
        }
        func better(_ a: ElementSnapshot, _ b: ElementSnapshot) -> Bool {
            if a.isEnabled != b.isEnabled { return a.isEnabled }
            let oa = iou(a), ob = iou(b)
            if abs(oa - ob) > 0.05 { return oa > ob }
            if area(a) != area(b) { return area(a) < area(b) }
            return a.id < b.id
        }
        func snap(_ e: ElementSnapshot, _ reason: GuidedSnap.Reason) -> GuidedSnap {
            GuidedSnap(element: e, reason: reason, distance: DesktopLayout.distance(from: center, to: e.frame), overlap: iou(e))
        }
        let containing = candidates.filter { $0.frame.insetBy(dx: -2, dy: -2).contains(center) }
        if let best = containing.sorted(by: better).first { return snap(best, .containsCenter) }
        let overlapping = candidates.filter { iou($0) >= 0.3 }
        if let best = overlapping.sorted(by: better).first { return snap(best, .overlaps) }
        let near = candidates.map { ($0, DesktopLayout.distance(from: center, to: $0.frame)) }.filter { $0.1 <= reach }
        let nearest = near.sorted { a, b in
            if a.0.isEnabled != b.0.isEnabled { return a.0.isEnabled }
            if abs(a.1 - b.1) > 0.5 { return a.1 < b.1 }
            return area(a.0) < area(b.0)
        }.first
        return nearest.map { snap($0.0, .nearby) }
    }
}

/// Asks the live Accessibility tree what control is at a point, when the turn's element list has nothing there.
public protocol GuidedElementLocating: Sendable {
    func element(at point: CGPoint) -> ElementSnapshot?
}

/// The front app's control under a point, via `AXUIElementCopyElementAtPosition` (needs Accessibility permission).
public struct AccessibilityGuidedLocator: GuidedElementLocating {
    public var frontApp: @Sendable () -> FrontAppInfo?
    public var reader: AccessibilityElementReader

    public init(frontApp: @escaping @Sendable () -> FrontAppInfo?, reader: AccessibilityElementReader = AccessibilityElementReader()) {
        self.frontApp = frontApp
        self.reader = reader
    }

    public func element(at point: CGPoint) -> ElementSnapshot? {
        guard let app = frontApp() else { return nil }
        return reader.element(at: point, in: app).flatMap { GuidedTargetSnapper.isClickable($0) ? $0 : nil }
    }
}

extension GuidedScreen {
    /// Place a request on the screen and snap it to a control: the named element, else the best control from the
    /// element list, else whatever Accessibility reports at the centre (`locator`), else the brain's own box.
    public func target(for request: GuidedTargetRequest, id: Int, locator: (any GuidedElementLocating)? = nil,
                       reach: CGFloat = 28, minimumRadius: CGFloat = 28) -> GuidedTarget? {
        guard let placed = frame(for: request.place) else { return nil }
        var target = GuidedTarget(id: id, label: request.label, instruction: request.instruction, isHover: request.isHover,
                                  requestedFrame: placed.frame, minimumRadius: minimumRadius)
        if let named = placed.element {
            target.element = named
            target.snap = .named
        } else if let snap = GuidedTargetSnapper.choose(for: placed.frame, among: elements, reach: reach) {
            target.element = snap.element
            target.snap = snap.reason
        } else if let hit = locator?.element(at: CGPoint(x: placed.frame.midX, y: placed.frame.midY)) {
            target.element = hit
            target.snap = .hitTest
        }
        return target
    }
}

/// Places a guided target on a screenshot when nothing else can (`ElementGrounder` over a computer-use model).
public protocol GuidedTargetGrounding: Sendable {
    /// Where `question` points on `screen` (its `screenshot`), or nil when grounding failed.
    func locate(_ question: String, on screen: GuidedScreen) async -> GroundingResult?
}

extension ElementGrounder: GuidedTargetGrounding {
    public func locate(_ question: String, on screen: GuidedScreen) async -> GroundingResult? {
        guard let screenshot = screen.screenshot else { return nil }
        return try? await locate(question, screenshot: screenshot, geometry: screen.geometry)
    }
}
