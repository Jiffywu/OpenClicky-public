import CoreGraphics
import Foundation
import Testing
import OpenClickyKit
@testable import OpenClicky

/// `OverlayDrawingSurfaces` picks the overlay display for a drawing from its screenshot's display frame (Quartz, y down)
/// and the screens' frames (AppKit, y up): `onScreen(n)` lands on the display screenshot n shows.
@Suite @MainActor struct OverlayDisplayMappingTests {
    // A 1440×900 primary, a 1920×1080 display to its right (tops aligned) and a 1920×1080 display above it.
    static let primary = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2, isPrimary: true)
    static let right = DisplayGeometry(id: 2, frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080), scale: 1, isPrimary: false)
    static let above = DisplayGeometry(id: 3, frame: CGRect(x: 0, y: 900, width: 1920, height: 1080), scale: 1, isPrimary: false)
    static let layout = DesktopLayout(displays: [primary, right, above])
    static var screens: [(id: CGDirectDisplayID?, frame: CGRect)] { layout.displays.map { (id: $0.id, frame: $0.frame) } }

    @Test func eachScreenshotMapsToTheDisplayItShows() {
        // The display frames the screen capture records, in Quartz global points.
        let quartz: [(CGRect, CGDirectDisplayID)] = [
            (CGRect(x: 0, y: 0, width: 1440, height: 900), 1),
            (CGRect(x: 1440, y: 0, width: 1920, height: 1080), 2),
            (CGRect(x: 0, y: -1080, width: 1920, height: 1080), 3),
        ]
        for (frame, id) in quartz {
            #expect(OverlayDrawingSurfaces.displayID(showing: frame, layout: Self.layout, screens: Self.screens) == id, "\(frame)")
        }
        // The y flip is what tells them apart: the display above sits at a negative Quartz y.
        #expect(Self.layout.appKitRect(fromQuartz: CGRect(x: 0, y: -1080, width: 1920, height: 1080)) == Self.above.frame)
    }

    @Test func aDisplayThatMovedStillGetsTheNearestScreen() {
        // The right display was nudged 40 points down after the capture: its drawing still goes to it, not the primary.
        let moved = CGRect(x: 1440, y: 40, width: 1920, height: 1080)
        #expect(OverlayDrawingSurfaces.displayID(showing: moved, layout: Self.layout, screens: Self.screens) == 2)
        // No screens: no display.
        #expect(OverlayDrawingSurfaces.displayID(showing: moved, layout: Self.layout, screens: []) == nil)
    }
}
