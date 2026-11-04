import CoreGraphics
import Testing
@testable import OpenClickyKit

/// A built-in Retina panel as primary, a 1x monitor to its left (top edges aligned), a 1x monitor above and shifted
/// left, and a portrait monitor to the right that hangs below the primary.
///
///                  ┌──────────── above ────────────┐
///                  │ (-300, 982) 2560×1440 @1      │
///  ┌──── left ─────┼───────┬──────────┬────────────┘
///  │ (-1920,-98)   │ main  │ portrait │
///  │ 1920×1080 @1  │ @2    │ (1512,-938) 1080×1920
///  └───────────────┴───────┘          │
private let main = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isPrimary: true)
private let left = DisplayGeometry(id: 2, frame: CGRect(x: -1920, y: -98, width: 1920, height: 1080), scale: 1, isPrimary: false)
private let above = DisplayGeometry(id: 3, frame: CGRect(x: -300, y: 982, width: 2560, height: 1440), scale: 1, isPrimary: false)
private let portrait = DisplayGeometry(id: 4, frame: CGRect(x: 1512, y: -938, width: 1080, height: 1920), scale: 1, isPrimary: false)
private let layout = DesktopLayout(displays: [main, left, above, portrait])

private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

private func close(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.01) -> Bool {
    close(a.origin, b.origin, tolerance) && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

@Suite("Desktop layout")
struct DesktopLayoutTests {
    @Test func quartzAndAppKitFlipAroundThePrimaryDisplay() {
        #expect(layout.primaryHeight == 982)
        // The left display's top-left corner is Quartz (-1920, 0): its top is aligned with the primary's.
        #expect(layout.quartzRect(fromAppKit: left.frame) == CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        // The display above has a negative Quartz y.
        #expect(layout.quartzRect(fromAppKit: above.frame) == CGRect(x: -300, y: -1440, width: 2560, height: 1440))
        #expect(layout.quartzRect(fromAppKit: portrait.frame) == CGRect(x: 1512, y: 0, width: 1080, height: 1920))
        #expect(layout.quartzPoint(fromAppKit: CGPoint(x: 10, y: 982)) == CGPoint(x: 10, y: 0))
    }

    @Test func conversionsRoundTripOnEveryDisplay() {
        for display in layout.displays {
            for fx in [0.0, 0.25, 0.5, 0.999] {
                for fy in [0.0, 0.33, 0.75, 0.999] {
                    let p = CGPoint(x: display.frame.minX + display.frame.width * fx, y: display.frame.minY + display.frame.height * fy)
                    #expect(close(layout.appKitPoint(fromQuartz: layout.quartzPoint(fromAppKit: p)), p, 1e-9))
                    #expect(layout.display(containing: p)?.id == display.id)
                    let local = layout.localPoint(fromAppKit: p, in: display)
                    #expect(close(layout.appKitPoint(fromLocal: local, in: display), p))
                }
            }
            let rect = CGRect(x: display.frame.minX + 40, y: display.frame.minY + 30, width: 120, height: 44)
            #expect(layout.appKitRect(fromQuartz: layout.quartzRect(fromAppKit: rect)) == rect)
        }
    }

    @Test func displayLookupHandlesNegativeOriginsAndGaps() {
        #expect(layout.display(containing: CGPoint(x: -1, y: 500))?.id == left.id)
        #expect(layout.display(containing: CGPoint(x: -200, y: 2000))?.id == above.id)
        #expect(layout.display(containing: CGPoint(x: 2000, y: -900))?.id == portrait.id)
        // Below the left and primary displays there's nothing; the nearest display wins.
        let gap = CGPoint(x: 700, y: -400)
        #expect(layout.display(containing: gap) == nil)
        #expect(layout.display(nearest: gap)?.id == main.id)
        #expect(layout.display(nearest: CGPoint(x: -2500, y: 100))?.id == left.id)
    }

    @Test func localPointsAreTopLeftOrigin() {
        // The left display's top-left (AppKit (-1920, 982)) is local (0, 0); its bottom-right is (1920, 1080).
        #expect(layout.localPoint(fromAppKit: CGPoint(x: -1920, y: 982), in: left) == .zero)
        #expect(layout.localPoint(fromAppKit: CGPoint(x: 0, y: -98), in: left) == CGPoint(x: 1920, y: 1080))
        #expect(layout.localRect(fromAppKit: CGRect(x: 1512, y: 902, width: 100, height: 80), in: portrait) == CGRect(x: 0, y: 0, width: 100, height: 80))
    }

    @Test func readingOrderIsLeftToRightThenTopToBottom() {
        #expect(layout.readingOrder.map(\.id) == [2, 3, 1, 4])
        #expect(layout.primary?.id == 1)
        #expect(close(layout.bounds, CGRect(x: -1920, y: -938, width: 4512, height: 3360)))
    }

    @Test func nativePixelsFollowTheScale() {
        #expect(main.nativePixelSize == CGSize(width: 3024, height: 1964))
        #expect(left.nativePixelSize == CGSize(width: 1920, height: 1080))
    }
}

@Suite("Screenshot pixel mapping")
struct CaptureGeometryTests {
    @Test func retinaPanelPixelsMapToPoints() {
        // 1512×982 pt @2x captured at 1280×831 px: one pixel is 1.18125 pt across.
        let g = CaptureGeometry(displayFrame: main.frame, pixelWidth: 1280, pixelHeight: 831)
        #expect(abs(g.pointsPerPixelX - 1.18125) < 1e-9)
        #expect(close(g.appKitPoint(fromPixel: .zero), CGPoint(x: 0, y: 982)))
        #expect(close(g.appKitPoint(fromPixel: CGPoint(x: 1280, y: 831)), CGPoint(x: 1512, y: 0)))
        #expect(close(g.appKitPoint(fromPixel: CGPoint(x: 640, y: 415.5)), CGPoint(x: 756, y: 491)))
        #expect(close(g.localPoint(fromPixel: CGPoint(x: 640, y: 415.5)), CGPoint(x: 756, y: 491)))
    }

    @Test func negativeOriginDisplayMapsCorrectly() {
        let g = CaptureGeometry(displayFrame: left.frame, pixelWidth: 1280, pixelHeight: 720)
        #expect(close(g.appKitPoint(fromPixel: .zero), CGPoint(x: -1920, y: 982)))
        #expect(close(g.appKitPoint(fromPixel: CGPoint(x: 1280, y: 720)), CGPoint(x: 0, y: -98)))
        #expect(close(g.appKitPoint(fromPixel: CGPoint(x: 640, y: 360)), CGPoint(x: -960, y: 442)))
        // And to Quartz, where AX lives: the centre of the left display.
        #expect(close(g.quartzPoint(fromPixel: CGPoint(x: 640, y: 360), layout: layout), CGPoint(x: -960, y: 540)))
    }

    @Test func pixelsRoundTripThroughGlobalSpaceOnEveryDisplay() {
        for display in layout.displays {
            let size = CaptureSizing.pixelSize(pointSize: display.frame.size, scale: display.scale)
            let g = CaptureGeometry(displayFrame: display.frame, pixelWidth: size.width, pixelHeight: size.height)
            for pixel in [CGPoint(x: 0, y: 0), CGPoint(x: 13, y: 377), CGPoint(x: size.width / 2, y: size.height / 3), CGPoint(x: size.width, y: size.height)] {
                let global = g.appKitPoint(fromPixel: pixel)
                // Edge pixels land on shared seams; only interior ones must belong to this display.
                if pixel.x > 0, pixel.y > 0, pixel.x < CGFloat(size.width), pixel.y < CGFloat(size.height) {
                    #expect(layout.display(containing: global)?.id == display.id)
                }
                let back = g.pixel(fromAppKit: global)
                #expect(back.map { close($0, pixel, 0.001) } == true)
                let quartz = g.quartzPoint(fromPixel: pixel, layout: layout)
                #expect(g.pixel(fromQuartz: quartz, layout: layout).map { close($0, pixel, 0.001) } == true)
            }
        }
    }

    @Test func outOfRangePixelsAreClamped() {
        let g = CaptureGeometry(displayFrame: above.frame, pixelWidth: 1280, pixelHeight: 720)
        #expect(!g.containsPixel(CGPoint(x: -4, y: 10)))
        #expect(close(g.appKitPoint(fromPixel: CGPoint(x: -4, y: -9)), CGPoint(x: -300, y: 2422)))
        #expect(close(g.appKitPoint(fromPixel: CGPoint(x: 5000, y: 5000)), CGPoint(x: 2260, y: 982)))
    }

    @Test func pointsOnOtherDisplaysHaveNoPixel() {
        let g = CaptureGeometry(displayFrame: main.frame, pixelWidth: 1280, pixelHeight: 831)
        #expect(g.pixel(fromAppKit: CGPoint(x: -10, y: 400)) == nil)
        #expect(g.pixel(fromAppKit: CGPoint(x: 1600, y: -10)) == nil)
    }

    @Test func rectsConvertBothWays() {
        // An Accessibility frame on the display above: Quartz (100, -1000) 200×50.
        let g = CaptureGeometry(displayFrame: above.frame, pixelWidth: 1280, pixelHeight: 720)
        let quartz = CGRect(x: 100, y: -1000, width: 200, height: 50)
        let pixels = g.pixelRect(fromQuartzRect: quartz, layout: layout)
        // Local: x = 100 - (-300) = 400 pt, y = 1000 - 1440... top of display is Quartz -1440, so y = 440 pt. Half scale.
        #expect(close(pixels, CGRect(x: 200, y: 220, width: 100, height: 25)))
        let appKit = g.appKitRect(fromPixelRect: pixels)
        #expect(close(appKit, layout.appKitRect(fromQuartz: quartz)))
        #expect(g.visiblePixelRect(CGRect(x: -50, y: -50, width: 40, height: 40)) == nil)
        #expect(g.visiblePixelRect(CGRect(x: 1250, y: 700, width: 100, height: 100)) == CGRect(x: 1250, y: 700, width: 30, height: 20))
    }

    @Test func pointingDestinationsResolveToGlobalPoints() {
        let g = CaptureGeometry(displayFrame: portrait.frame, pixelWidth: 720, pixelHeight: 1280)
        let resolved = PointingDestination.pixel(CGPoint(x: 360, y: 640), g).resolved
        #expect(close(resolved.point, CGPoint(x: 2052, y: 22)))
        #expect(resolved.frame == nil)
        let box = PointingDestination.pixelRect(CGRect(x: 0, y: 0, width: 72, height: 16), g).resolved
        #expect(close(box.frame ?? .null, CGRect(x: 1512, y: 958, width: 108, height: 24)))
        // Small controls: aim at the lower edge, just right of centre, so the text stays visible.
        #expect(close(box.point, CGPoint(x: 1566 + 10, y: 958 + 4)))
        let big = PointingDestination.rect(CGRect(x: 0, y: 0, width: 400, height: 300)).resolved
        #expect(big.point == CGPoint(x: 200, y: 150))
    }
}

@Suite("Capture plan")
struct ScreenCapturePlanTests {
    @Test func numbersScreensInReadingOrderAndFlagsThePointer() {
        let plan = ScreenCapturePlan(layout: layout, cursor: CGPoint(x: 700, y: 400), displays: .all, longEdge: 1280)
        #expect(plan.entries.map(\.display.id) == [2, 3, 1, 4])
        #expect(plan.entries.map(\.screenNumber) == [1, 2, 3, 4])
        #expect(plan.entries.allSatisfy { $0.screenCount == 4 })
        #expect(plan.cursorEntry?.display.id == 1)
        #expect(plan.entries.filter(\.isCursorScreen).count == 1)
        let sizes = plan.entries.map { "\($0.pixelWidth)x\($0.pixelHeight)" }
        #expect(sizes == ["1280x720", "1280x720", "1280x831", "720x1280"])
    }

    @Test func cursorOnlyCapturesOneScreen() {
        let plan = ScreenCapturePlan(layout: layout, cursor: CGPoint(x: -200, y: 1500), displays: .cursorOnly, longEdge: 1280)
        #expect(plan.entries.count == 1)
        #expect(plan.entries.first?.display.id == 3)
        #expect(plan.entries.first?.screenNumber == 1)
        #expect(plan.entries.first?.screenCount == 1)
    }

    @Test func skipsDisplaysTheCapturerCantSee() {
        let plan = ScreenCapturePlan(layout: layout, cursor: CGPoint(x: -500, y: 300), displays: .all, longEdge: 1280, capturable: [1, 4])
        #expect(plan.entries.map(\.display.id) == [1, 4])
        // The pointer is on the left display, which can't be captured; the nearest capturable one takes the flag.
        #expect(plan.cursorEntry?.display.id == 1)
    }

    @Test func pointerInAGapPicksTheNearestDisplay() {
        let plan = ScreenCapturePlan(layout: layout, cursor: CGPoint(x: 700, y: -400), displays: .all, longEdge: 1280)
        #expect(plan.cursorEntry?.display.id == 1)
    }
}
