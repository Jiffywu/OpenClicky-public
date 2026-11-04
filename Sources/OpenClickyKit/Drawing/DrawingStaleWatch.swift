import AppKit
import CoreGraphics
import Foundation

/// A window as the window server lists it, front to back. Bounds and owners need no permission (titles would).
public struct ScreenWindow: Sendable, Hashable {
    public var number: Int
    public var ownerPID: Int32
    public var ownerName: String
    /// The window level: 0 for ordinary app windows; menus, the Dock and panels sit higher.
    public var layer: Int
    /// Global Quartz points: origin at the top-left of the main display, y down.
    public var bounds: CGRect
    public var alpha: Double

    public init(number: Int, ownerPID: Int32, ownerName: String = "", layer: Int = 0, bounds: CGRect, alpha: Double = 1) {
        self.number = number
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
    }

    /// The windows on screen now, front to back.
    public static func onScreen() -> [ScreenWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int, let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return ScreenWindow(number: number, ownerPID: pid, ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                                layer: info[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds,
                                alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }
}

/// Why a drawing no longer matches the screen under it.
public enum DrawingStaleReason: Sendable, Hashable, CustomStringConvertible {
    /// The user switched to another app.
    case appChanged(String)
    /// The window the drawing was made over moved or changed size.
    case windowMoved
    case windowClosed
    /// Another window came in front of it.
    case covered(by: String)
    /// Scrolled over it by this many points.
    case scrolled(Double)
    /// The user went to another Space.
    case spaceChanged

    public var description: String {
        switch self {
        case .appChanged(let app): "switched to \(app)"
        case .windowMoved: "its window moved or resized"
        case .windowClosed: "its window closed"
        case .covered(let app): "covered by a window of \(app.isEmpty ? "another app" : app)"
        case .scrolled(let points): "scrolled \(Int(points.rounded())) points over it"
        case .spaceChanged: "the Space changed"
        }
    }
}

/// Decides when a drawing no longer matches the screen under it. It is armed with the windows on screen when the
/// drawing starts: the watched window is the front app's frontmost ordinary window over the drawing's area. Then the
/// drawing is stale when that window moves, resizes or closes, a new window covers enough of it, the user scrolls it
/// past a threshold, another app comes to the front, or the Space changes. OpenClicky's own windows never count.
/// Pure logic: `DrawingStaleMonitor` feeds it the live window list, app switches and scroll events.
public struct DrawingStaleWatch: Sendable {
    public struct Settings: Sendable, Hashable {
        /// Points a window may shift (a shadow, a resize animation settling) before it counts as moved.
        public var moveTolerance: CGFloat
        /// The share of the watched window (where the drawing is) a new window must cover.
        public var coveredFraction: Double
        /// Points of scrolling over the watched window before the content under the drawing has moved too far.
        public var scrollThreshold: Double

        public init(moveTolerance: CGFloat = 8, coveredFraction: Double = 0.25, scrollThreshold: Double = 80) {
            self.moveTolerance = moveTolerance
            self.coveredFraction = coveredFraction
            self.scrollThreshold = scrollThreshold
        }
    }

    /// Where the drawing is, in global Quartz points (its display).
    public let area: CGRect
    public let frontPID: Int32?
    /// The window the drawing was made over, if any (none over the desktop).
    public let watched: ScreenWindow?
    public let ignoredPIDs: Set<Int32>
    public let settings: Settings
    /// Windows already in front of the watched one when the watch began.
    private let coveringAtStart: Set<Int>
    public private(set) var scrolled: Double = 0
    /// The first reason the drawing went stale; later checks repeat it.
    public private(set) var reason: DrawingStaleReason?

    public init(windows: [ScreenWindow], frontPID: Int32?, area: CGRect, ignoring: Set<Int32> = [], settings: Settings = Settings()) {
        self.area = area
        self.frontPID = frontPID
        self.ignoredPIDs = ignoring
        self.settings = settings
        let index = windows.firstIndex { window in
            window.layer == 0 && window.alpha > 0 && window.ownerPID == frontPID && !ignoring.contains(window.ownerPID)
                && window.bounds.intersects(area)
        }
        watched = index.map { windows[$0] }
        if let index, let watched {
            let target = watched.bounds.intersection(area)
            coveringAtStart = Set(windows[..<index].filter { $0.layer == 0 && $0.bounds.intersects(target) }.map(\.number))
        } else {
            coveringAtStart = []
        }
    }

    /// Checks the windows now on screen (front to back) and the app in front. Returns why the drawing is stale, or nil.
    public mutating func check(windows: [ScreenWindow], frontPID: Int32?, frontName: String? = nil) -> DrawingStaleReason? {
        if let reason { return reason }
        reason = evaluate(windows: windows, frontPID: frontPID, frontName: frontName)
        return reason
    }

    private func evaluate(windows: [ScreenWindow], frontPID: Int32?, frontName: String?) -> DrawingStaleReason? {
        if let frontPID, frontPID != self.frontPID, !ignoredPIDs.contains(frontPID) {
            let name = frontName ?? windows.first { $0.ownerPID == frontPID }?.ownerName
            return .appChanged(name.flatMap { $0.isEmpty ? nil : $0 } ?? "another app")
        }
        guard let watched else { return nil }
        guard let index = windows.firstIndex(where: { $0.number == watched.number }) else { return .windowClosed }
        let now = windows[index].bounds
        let tolerance = settings.moveTolerance
        if abs(now.minX - watched.bounds.minX) > tolerance || abs(now.minY - watched.bounds.minY) > tolerance
            || abs(now.width - watched.bounds.width) > tolerance || abs(now.height - watched.bounds.height) > tolerance {
            return .windowMoved
        }
        let target = now.intersection(area)
        let targetArea = target.width * target.height
        guard targetArea > 0 else { return nil }
        for window in windows[..<index] where window.layer == 0 && window.alpha > 0 && !ignoredPIDs.contains(window.ownerPID)
            && !coveringAtStart.contains(window.number) {
            let overlap = window.bounds.intersection(target)
            guard !overlap.isNull else { continue }
            if Double(overlap.width * overlap.height) >= settings.coveredFraction * Double(targetArea) {
                return .covered(by: window.ownerName)
            }
        }
        return nil
    }

    /// The user scrolled by (dx, dy) points with the pointer at `point` (global Quartz points). Scrolling elsewhere
    /// doesn't move what is under the drawing.
    public mutating func scroll(dx: Double, dy: Double, at point: CGPoint) -> DrawingStaleReason? {
        if let reason { return reason }
        let over = watched.map { $0.bounds.intersection(area) } ?? area
        guard over.contains(point) else { return nil }
        scrolled += abs(dx) + abs(dy)
        if scrolled >= settings.scrollThreshold { reason = .scrolled(scrolled) }
        return reason
    }

    public mutating func spaceChanged() -> DrawingStaleReason {
        if let reason { return reason }
        reason = .spaceChanged
        return .spaceChanged
    }
}

/// Runs a `DrawingStaleWatch` against the live screen: polls the window list and the front app a few times a second,
/// listens for Space changes, and watches scrolling in other apps (a global scroll monitor needs no permission). Tests
/// and `occtl overlay` give it fake sources and call `poll()` and `scrolled` themselves.
@MainActor
public final class DrawingStaleMonitor {
    public struct Sources {
        public var windows: () -> [ScreenWindow]
        public var frontApp: () -> (pid: Int32, name: String)?

        public init(windows: @escaping () -> [ScreenWindow], frontApp: @escaping () -> (pid: Int32, name: String)?) {
            self.windows = windows
            self.frontApp = frontApp
        }

        public static var live: Sources {
            Sources(windows: { ScreenWindow.onScreen() }, frontApp: {
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return (app.processIdentifier, app.localizedName ?? app.bundleIdentifier ?? "")
            })
        }
    }

    public var settings = DrawingStaleWatch.Settings()
    public var pollInterval: TimeInterval = 0.25
    /// The drawing went stale (once per arming).
    public var onStale: ((DrawingStaleReason) -> Void)?
    public private(set) var watch: DrawingStaleWatch?
    private let sources: Sources
    private let ignoring: Set<Int32>
    private let observesSystem: Bool
    private var timer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var scrollMonitor: Any?

    /// `observesSystem` false leaves out the timer, the Space observer and the scroll monitor (tests drive it).
    public init(sources: Sources = .live, ignoring: Set<Int32> = [ProcessInfo.processInfo.processIdentifier], observesSystem: Bool = true) {
        self.sources = sources
        self.ignoring = ignoring
        self.observesSystem = observesSystem
    }

    public var isArmed: Bool { watch != nil }

    /// Starts watching the screen as it is now, for a drawing over `area` (global Quartz points).
    public func arm(area: CGRect) {
        let front = sources.frontApp()
        watch = DrawingStaleWatch(windows: sources.windows(), frontPID: front?.pid, area: area, ignoring: ignoring, settings: settings)
        guard observesSystem else { return }
        if timer == nil {
            let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.spaceChanged() }
            }
        }
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
                let precise = event.hasPreciseScrollingDeltas
                MainActor.assumeIsolated {
                    // Global AppKit point (y up from the main display's bottom) → Quartz (y down from its top).
                    let location = NSEvent.mouseLocation
                    let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
                    let point = CGPoint(x: location.x, y: mainHeight - location.y)
                    // A wheel notch scrolls about 10 points.
                    self?.scrolled(dx: precise ? dx : dx * 10, dy: precise ? dy : dy * 10, at: point)
                }
            }
        }
    }

    /// Stops watching.
    public func disarm() {
        watch = nil
        timer?.invalidate()
        timer = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    /// One check of the windows and the front app.
    public func poll() {
        guard var watch else { return }
        let front = sources.frontApp()
        let reason = watch.check(windows: sources.windows(), frontPID: front?.pid, frontName: front?.name)
        self.watch = watch
        if let reason { fire(reason) }
    }

    public func scrolled(dx: Double, dy: Double, at point: CGPoint) {
        guard var watch else { return }
        let reason = watch.scroll(dx: dx, dy: dy, at: point)
        self.watch = watch
        if let reason { fire(reason) }
    }

    public func spaceChanged() {
        guard var watch else { return }
        let reason = watch.spaceChanged()
        self.watch = watch
        fire(reason)
    }

    private func fire(_ reason: DrawingStaleReason) {
        disarm()
        onStale?(reason)
    }
}
