import AppKit
import CoreGraphics
import Foundation

/// One on-screen window as the window list reports it. Owner, layer and bounds need no permission (window titles
/// would need Screen Recording, and the detector doesn't use them).
public struct SystemWindowInfo: Sendable, Hashable, Codable {
    public var ownerName: String
    public var bundleID: String?
    public var pid: Int32
    /// The window level (`kCGWindowLayer`).
    public var layer: Int
    /// Quartz global points: top-left origin at the primary display.
    public var bounds: CGRect
    public var alpha: Double

    public init(ownerName: String, bundleID: String? = nil, pid: Int32 = 0, layer: Int = 0, bounds: CGRect, alpha: Double = 1) {
        self.ownerName = ownerName
        self.bundleID = bundleID
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
    }
}

/// Why the notch (and for some reasons the overlays) step aside.
public enum NotchYieldReason: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case spotlight
    case controlCenter = "control_center"
    case notificationCenter = "notification_center"
    /// A menu opened from a system menu extra.
    case systemMenu = "system_menu"
    /// The screenshot toolbar or its capture UI (⇧⌘3/4/5).
    case screenshotUI = "screenshot_ui"
    /// A full-screen window or area picker (screenshot window selection, the screen-sharing picker).
    case windowPicker = "window_picker"
    case missionControl = "mission_control"

    /// The full-screen transparent overlays step aside only for these; the rest only cover the notch.
    public var hidesOverlays: Bool { self == .screenshotUI || self == .windowPicker || self == .missionControl }

    public static func < (a: NotchYieldReason, b: NotchYieldReason) -> Bool { a.rawValue < b.rawValue }
}

/// Recognises system UI that the notch must not cover or intercept, from the window list. The rules use bundle ids,
/// layers and sizes only.
public struct SystemUIDetector: Sendable, Hashable {
    public static let spotlightIDs: Set<String> = ["com.apple.spotlight"]
    public static let controlCenterIDs: Set<String> = ["com.apple.controlcenter"]
    public static let notificationCenterIDs: Set<String> = ["com.apple.notificationcenterui"]
    public static let systemUIServerIDs: Set<String> = ["com.apple.systemuiserver"]
    public static let screenshotIDs: Set<String> = ["com.apple.screencaptureui", "com.apple.screenshot", "com.apple.screenshot.launcher"]
    public static let dockIDs: Set<String> = ["com.apple.dock"]
    /// Owner names of the screen-sharing content picker, when it runs in its own process.
    public static let pickerOwnerNames: Set<String> = ["screensharingpicker", "contentsharingpicker"]
    /// `kCGDockWindowLevel`: where the Dock's own window lives.
    public static let dockLevel = 20

    /// Taller than this is an open panel, not a menu-bar item.
    public var menuBarHeight: CGFloat
    /// A window covering this share of a display counts as full-screen.
    public var fullCoverage: CGFloat

    public init(menuBarHeight: CGFloat = 44, fullCoverage: CGFloat = 0.9) {
        self.menuBarHeight = menuBarHeight
        self.fullCoverage = fullCoverage
    }

    /// Every reason present in the window list. `displays` are Quartz display bounds.
    public func reasons(in windows: [SystemWindowInfo], displays: [CGRect]) -> Set<NotchYieldReason> {
        var found: Set<NotchYieldReason> = []
        for window in windows where window.alpha > 0.01 && window.bounds.width > 1 && window.bounds.height > 1 {
            let id = window.bundleID?.lowercased() ?? ""
            let owner = window.ownerName.lowercased().replacingOccurrences(of: " ", with: "")
            let tall = window.bounds.height > menuBarHeight
            if Self.screenshotIDs.contains(id) || owner == "screencaptureui" {
                found.insert(coversDisplay(window.bounds, displays) ? .windowPicker : .screenshotUI)
            } else if Self.pickerOwnerNames.contains(owner) {
                found.insert(.windowPicker)
            } else if Self.spotlightIDs.contains(id) || owner == "spotlight" {
                if window.bounds.height > 40 { found.insert(.spotlight) }
            } else if Self.controlCenterIDs.contains(id) || owner == "controlcenter" {
                if tall { found.insert(.controlCenter) }
            } else if Self.notificationCenterIDs.contains(id) || owner == "notificationcenter" {
                // The side panel, not a banner, and not the desktop widgets the same process draws below every window.
                if window.bounds.height > 400, window.layer > 0 { found.insert(.notificationCenter) }
            } else if Self.systemUIServerIDs.contains(id) || owner == "systemuiserver" {
                if tall { found.insert(.systemMenu) }
            } else if Self.dockIDs.contains(id) || owner == "dock" {
                // Mission Control (and the app grid) cover the display. The Dock's own window sits at the Dock level and
                // may span the whole display while only the bar is drawn, so a window at that level isn't taken for
                // Mission Control (a false positive would hide the overlays until the hard limit).
                if window.layer >= 18, window.layer != Self.dockLevel, coversDisplay(window.bounds, displays) { found.insert(.missionControl) }
            }
        }
        return found
    }

    func coversDisplay(_ bounds: CGRect, _ displays: [CGRect]) -> Bool {
        displays.contains { display in
            let overlap = display.intersection(bounds)
            guard !overlap.isNull, display.width > 0, display.height > 0 else { return false }
            return overlap.width * overlap.height >= fullCoverage * display.width * display.height
        }
    }
}

/// Finds the displays where the front app is full screen: one of its normal-level windows fills the display exactly,
/// or, on a display with a camera housing, fills everything below the housing while the menu bar is away.
public enum FullscreenDetector {
    /// `kCGMainMenuWindowLevel`: the menu bar's own window.
    public static let menuBarLevel = 24

    /// Indices into `displays` (Quartz bounds) where the app with `frontPID` has a full-screen window.
    /// `housingInsets[i]` is display i's safe-area top (the housing's height; 0 or missing without one). A full-screen
    /// app there sits below the housing, so its window is that much shorter than the display. A zoomed window has the
    /// same frame, so that form only counts while the display shows no menu bar.
    public static func fullscreenDisplays(windows: [SystemWindowInfo], displays: [CGRect], frontPID: Int32?,
                                          housingInsets: [CGFloat] = []) -> Set<Int> {
        guard let frontPID else { return [] }
        var result: Set<Int> = []
        for window in windows where window.pid == frontPID && window.layer == 0 && window.alpha > 0.01 {
            for (index, display) in displays.enumerated() {
                if approximatelyEqual(window.bounds, display) {
                    result.insert(index)
                    continue
                }
                let inset = index < housingInsets.count ? housingInsets[index] : 0
                guard inset > 0 else { continue }
                let belowHousing = CGRect(x: display.minX, y: display.minY + inset, width: display.width, height: display.height - inset)
                if approximatelyEqual(window.bounds, belowHousing), !showsMenuBar(display, windows: windows) {
                    result.insert(index)
                }
            }
        }
        return result
    }

    /// Whether the menu bar's window is on screen along the top of `display` (it isn't in a full-screen Space until
    /// the pointer reaches the top).
    static func showsMenuBar(_ display: CGRect, windows: [SystemWindowInfo]) -> Bool {
        windows.contains { window in
            window.layer == menuBarLevel && window.alpha > 0.01 && abs(window.bounds.minY - display.minY) <= 1.5
                && window.bounds.height <= 60 && window.bounds.intersection(display).width >= display.width * 0.9
        }
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1.5) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

/// Turns detected reasons into the ones to obey, with a hard limit per reason so a misread window list (or system UI
/// left open) can't keep OpenClicky hidden: once a reason has been obeyed for its limit it is ignored until it clears.
public struct NotchYieldCoordinator: Sendable, Hashable {
    public var limits: [NotchYieldReason: TimeInterval]
    private var since: [NotchYieldReason: Date] = [:]
    private var timedOut: Set<NotchYieldReason> = []

    public static let defaultLimits: [NotchYieldReason: TimeInterval] = [
        .spotlight: 120, .controlCenter: 120, .notificationCenter: 300, .systemMenu: 60,
        .screenshotUI: 45, .windowPicker: 45, .missionControl: 30,
    ]

    public init(limits: [NotchYieldReason: TimeInterval] = NotchYieldCoordinator.defaultLimits) {
        self.limits = limits
    }

    /// The reasons to obey now.
    public mutating func update(_ detected: Set<NotchYieldReason>, now: Date) -> Set<NotchYieldReason> {
        for reason in Set(since.keys).subtracting(detected) { since[reason] = nil }
        timedOut.formIntersection(detected)
        var active: Set<NotchYieldReason> = []
        for reason in detected where !timedOut.contains(reason) {
            let start = since[reason] ?? now
            since[reason] = start
            if let limit = limits[reason], now.timeIntervalSince(start) >= limit {
                timedOut.insert(reason)
            } else {
                active.insert(reason)
            }
        }
        return active
    }

    public var timedOutReasons: Set<NotchYieldReason> { timedOut }
}

/// Reads the live window list. No permission needed (titles, which would need Screen Recording, aren't read).
public enum SystemWindowList {
    @MainActor private static var bundleIDs: [Int32: String] = [:]

    @MainActor
    public static func snapshot() -> [SystemWindowInfo] {
        let raw = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return raw.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            return SystemWindowInfo(ownerName: owner, bundleID: bundleID(for: pid), pid: pid, layer: layer, bounds: bounds, alpha: alpha)
        }
    }

    @MainActor
    static func bundleID(for pid: Int32) -> String? {
        if let known = bundleIDs[pid] { return known }
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
        if bundleIDs.count > 512 { bundleIDs.removeAll() }
        bundleIDs[pid] = id
        return id
    }

    /// Quartz bounds of the active displays, in `DesktopLayout` order.
    public static func displayBounds(_ layout: DesktopLayout = .current()) -> [(id: UInt32, bounds: CGRect)] {
        layout.displays.map { ($0.id, layout.quartzRect(fromAppKit: $0.frame)) }
    }
}
