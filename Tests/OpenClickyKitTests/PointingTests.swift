import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

private let elements: [ElementSnapshot] = [
    ElementSnapshot(id: "e1", role: "AXButton", title: "Save", frame: CGRect(x: 500, y: 100, width: 76, height: 28)),
    ElementSnapshot(id: "e2", role: "AXStaticText", value: "Save your work before quitting", frame: CGRect(x: 40, y: 300, width: 300, height: 18)),
    ElementSnapshot(id: "e3", role: "AXButton", title: "Save As…", frame: CGRect(x: 600, y: 100, width: 90, height: 28)),
    ElementSnapshot(id: "e4", role: "AXTextField", subrole: "AXSearchField", identifier: "searchField", placeholder: "Search",
                    frame: CGRect(x: 40, y: 400, width: 200, height: 24)),
    ElementSnapshot(id: "e5", role: "AXCheckBox", title: "Remember me", frame: CGRect(x: 40, y: 200, width: 120, height: 20)),
    ElementSnapshot(id: "e6", role: "AXButton", detail: "Share", frame: CGRect(x: 700, y: 400, width: 30, height: 30)),
    ElementSnapshot(id: "e7", role: "AXGroup", title: "Save", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
    ElementSnapshot(id: "e8", role: "AXButton", title: "Delete", frame: CGRect(x: 400, y: 100, width: 70, height: 28), isEnabled: false),
    ElementSnapshot(id: "e9", role: "AXLink", value: "Résumé builder", frame: CGRect(x: 40, y: 500, width: 140, height: 18)),
    ElementSnapshot(id: "e10", role: "AXButton", identifier: "closeButton", frame: CGRect(x: 10, y: 560, width: 14, height: 14)),
    ElementSnapshot(id: "e11", role: "AXMenuItem", title: "Share", frame: CGRect(x: 300, y: 50, width: 120, height: 20)),
    ElementSnapshot(id: "e12", role: "AXButton", title: "Offscreen", frame: CGRect(x: -500, y: 100, width: 60, height: 20)),
    ElementSnapshot(id: "e13", role: "AXCell", title: "Inbox row", frame: CGRect(x: 40, y: 600, width: 300, height: 40)),
    ElementSnapshot(id: "e14", role: "AXButton", detail: "Flag", frame: CGRect(x: 300, y: 610, width: 20, height: 20)),
]

private let snapshot = WindowElementSnapshot(app: nil, windowTitle: "Editor", windowFrame: CGRect(x: 0, y: 0, width: 800, height: 700), elements: elements)

private func best(_ query: String) -> String? { ElementLabelMatcher.bestMatch(for: query, in: elements)?.element.id }

@Suite("Element label matching")
struct ElementLabelMatcherTests {
    @Test func normalization() {
        #expect(ElementLabelMatcher.normalize("Save As…") == "save as")
        #expect(ElementLabelMatcher.normalize("  Résumé & CV!! ") == "resume and cv")
        #expect(ElementLabelMatcher.normalize("ＦＵＬＬ width") == "full width")
    }

    @Test func exactLabelsWinOverLongerOnes() {
        #expect(best("Save") == "e1")
        #expect(best("save as") == "e3")
        #expect(best("Save As...") == "e3")
    }

    @Test func kindWordsAndFillersAreHints() {
        #expect(best("the Save button") == "e1")
        #expect(best("click on Save") == "e1")
        #expect(best("search field") == "e4")
        #expect(best("Remember me checkbox") == "e5")
    }

    @Test func roleHintsBreakTies() {
        // A Share button and a Share menu item: the smaller button by default, the menu item when asked for.
        #expect(best("Share") == "e6")
        #expect(best("Share menu item") == "e11")
    }

    @Test func partialAndFoldedMatches() {
        #expect(best("Remember") == "e5")
        #expect(best("resume builder") == "e9")
        #expect(best("Close") == "e10") // from its identifier
    }

    @Test func containersNeverMatch() {
        let matches = ElementLabelMatcher.matches(for: "Save", in: elements)
        #expect(!matches.contains { $0.element.id == "e7" })
        #expect(matches.first?.matchedText == "save")
    }

    @Test func disabledControlsStillMatchButRankLower() throws {
        let delete = try #require(ElementLabelMatcher.bestMatch(for: "Delete", in: elements))
        #expect(delete.element.id == "e8")
        let save = try #require(ElementLabelMatcher.bestMatch(for: "Save", in: elements))
        #expect(delete.score < save.score)
    }

    @Test func unrelatedQueriesFindNothing() {
        #expect(ElementLabelMatcher.matches(for: "Quit everything", in: elements).isEmpty)
        #expect(ElementLabelMatcher.matches(for: "", in: elements).isEmpty)
        #expect(ElementLabelMatcher.matches(for: "the", in: elements).isEmpty)
    }

    @Test func resolvingALabelGivesAFrameAndAnAimPoint() throws {
        let resolved = try #require(snapshot.resolve(label: "Save"))
        #expect(resolved.element.id == "e1")
        #expect(resolved.target.frame == CGRect(x: 500, y: 100, width: 76, height: 28))
        #expect(abs(resolved.target.point.x - 547.12) < 0.001)
        #expect(resolved.target.point.y == 104)
        #expect(snapshot.resolve(elementID: "e4")?.element.placeholder == "Search")
        #expect(snapshot.resolve(label: "nonexistent thing") == nil)
    }

    @Test func labelsComeFromTheRightAttribute() {
        #expect(elements[0].label == "Save")
        #expect(elements[1].label == "Save your work before quitting") // static text: its value
        #expect(elements[3].label == "Search") // placeholder
        #expect(elements[5].label == "Share") // description
        #expect(elements[9].label == nil) // identifier only
        #expect(elements[3].kindName == "search field")
        #expect(elements[10].kindName == "menu item")
        #expect(ElementSnapshot(id: "x", role: "AXValueIndicator", frame: .zero).kindName == "value indicator")
    }

    @Test func promptLinesUseScreenshotPixels() {
        // A 1600×1000 pt display captured at 1280×800 px.
        let geometry = CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000), pixelWidth: 1280, pixelHeight: 800)
        let lines = snapshot.promptLines(in: geometry)
        #expect(lines.first == "e1 button \"Save\" [400,698,61,22]")
        #expect(lines.contains("e8 button \"Delete\" [320,698,56,22] disabled"))
        #expect(!lines.contains { $0.hasPrefix("e2 ") }) // plain text isn't listed
        #expect(!lines.contains { $0.hasPrefix("e7 ") }) // containers aren't
        #expect(!lines.contains { $0.hasPrefix("e10 ") }) // no label
        #expect(!lines.contains { $0.hasPrefix("e12 ") }) // off the captured display
        let global = snapshot.promptLines()
        #expect(global.contains("e12 button \"Offscreen\" [-500,100,60,20]"))
    }

    @Test func snapshotJSON() {
        let json = snapshot.jsonValue
        #expect(json["count"]?.intValue == elements.count)
        #expect(json["elements"]?.arrayValue?.first?["label"]?.stringValue == "Save")
        #expect(json["elements"]?.arrayValue?.first?["actionable"]?.boolValue == true)
    }
}

@Suite("Element snapping")
struct ElementSnapperTests {
    @Test func snapsToTheSmallestActionableElementUnderThePoint() {
        #expect(ElementSnapper.snap(CGPoint(x: 530, y: 110), in: elements)?.id == "e1")
        // Inside the big group and the button: the button.
        #expect(ElementSnapper.snap(CGPoint(x: 510, y: 120), in: elements)?.id == "e1")
        // Inside a table cell and the flag button within it: the button.
        #expect(ElementSnapper.snap(CGPoint(x: 310, y: 620), in: elements)?.id == "e14")
        #expect(ElementSnapper.snap(CGPoint(x: 100, y: 620), in: elements)?.id == "e13")
    }

    @Test func snapsToANearbyControlWithinTheRadius() {
        #expect(ElementSnapper.snap(CGPoint(x: 490, y: 114), in: elements)?.id == "e1")
        #expect(ElementSnapper.snap(CGPoint(x: 760, y: 300), in: elements) == nil)
        #expect(ElementSnapper.snap(CGPoint(x: 490, y: 114), in: elements, radius: 5) == nil)
    }
}

@Suite("Pointer flight")
struct PointerFlightTests {
    @Test func durationFollowsDistanceWithinBounds() {
        #expect(PointerFlightPath(from: .zero, to: CGPoint(x: 100, y: 0)).duration == 0.35)
        #expect(PointerFlightPath(from: .zero, to: CGPoint(x: 400, y: 0)).duration == 0.5)
        #expect(PointerFlightPath(from: .zero, to: CGPoint(x: 3000, y: 0)).duration == 1.4)
        #expect(PointerFlightPath(from: .zero, to: CGPoint(x: 3000, y: 0), duration: 0.2).duration == 0.2)
    }

    @Test func pathsStartAndEndExactlyAndBowUpward() {
        let flat = PointerFlightPath(from: .zero, to: CGPoint(x: 400, y: 0))
        #expect(flat.position(at: 0) == .zero)
        #expect(flat.position(at: 1) == CGPoint(x: 400, y: 0))
        // The arc lifts the middle by 0.2 × distance, capped at 80 pt; +y is up in AppKit space.
        #expect(flat.position(at: 0.5) == CGPoint(x: 200, y: 80))
        let long = PointerFlightPath(from: .zero, to: CGPoint(x: -1000, y: 0))
        #expect(long.position(at: 0.5).y == 80)
        let down = PointerFlightPath(from: CGPoint(x: 0, y: 500), to: CGPoint(x: 300, y: 100))
        #expect(down.position(at: 0.5).y > 300)
        // Straight down: bows sideways instead.
        let vertical = PointerFlightPath(from: .zero, to: CGPoint(x: 0, y: -300))
        #expect(abs(vertical.position(at: 0.5).x - 60) < 1e-9)
        let still = PointerFlightPath(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5))
        #expect(still.position(at: 0.5) == CGPoint(x: 5, y: 5))
    }

    @Test func easing() {
        #expect(PointerFlightPath.easeInOut(0) == 0)
        #expect(PointerFlightPath.easeInOut(1) == 1)
        #expect(PointerFlightPath.easeInOut(0.5) == 0.5)
        #expect(PointerFlightPath.easeInOut(-1) == 0)
        let samples = stride(from: 0.0, through: 1.0, by: 0.05).map(PointerFlightPath.easeInOut)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func poseTurnsTowardTravelAndSettlesAtBothEnds() {
        let path = PointerFlightPath(from: .zero, to: CGPoint(x: 800, y: 0))
        let start = path.pose(atTime: 0), end = path.pose(atTime: path.duration)
        #expect(start.rotation == 0 && end.rotation == 0)
        #expect(abs(start.scale - 1) < 1e-9 && abs(end.scale - 1) < 1e-9)
        #expect(end.position == CGPoint(x: 800, y: 0))
        let middle = path.pose(atTime: path.duration / 2)
        #expect(middle.scale > 1.2)
        // Flying right means turning the up-left resting tip clockwise by more than 90°.
        #expect(middle.rotation > .pi / 2)
    }
}

@Suite("Pointer gesture")
struct PointerGestureTests {
    let target = ResolvedPointingTarget(point: CGPoint(x: 800, y: 0), frame: CGRect(x: 780, y: -10, width: 60, height: 24))

    @Test func timelineRunsAppearFlyPointReturnVanish() {
        let gesture = PointerGesture(from: .zero, to: target, label: "Save", hold: 1)
        #expect(abs(gesture.arrivalTime - 1.18) < 1e-9)
        #expect(abs((gesture.returnStart ?? 0) - 2.18) < 1e-9)
        #expect(abs((gesture.endTime ?? 0) - 3.38) < 1e-9)
        let cursor = CGPoint(x: 50, y: 60)
        #expect(gesture.frame(at: 0.1, cursor: cursor).phase == .appearing)
        #expect(gesture.frame(at: 0.1, cursor: cursor).position == .zero)
        #expect(gesture.frame(at: 0.5, cursor: cursor).phase == .flying)
        let pointing = gesture.frame(at: 1.5, cursor: cursor)
        #expect(pointing.phase == .pointing)
        #expect(pointing.position == target.point)
        #expect(pointing.labelOpacity == 1)
        #expect(pointing.haloProgress > 0.5)
        let returning = gesture.frame(at: 2.5, cursor: cursor)
        #expect(returning.phase == .returning)
        #expect(returning.haloOpacity == 0)
        let vanishing = gesture.frame(at: 3.3, cursor: cursor)
        #expect(vanishing.phase == .vanishing)
        // The return flight ends wherever the user's pointer is now.
        #expect(vanishing.position == cursor)
        let done = gesture.frame(at: 3.5, cursor: cursor)
        #expect(done.phase == .finished && done.opacity == 0)
    }

    @Test func holdingUntilReleased() {
        var gesture = PointerGesture(from: .zero, to: target, label: nil, hold: nil)
        #expect(gesture.endTime == nil)
        #expect(gesture.frame(at: 100, cursor: .zero).phase == .pointing)
        #expect(gesture.frame(at: 100, cursor: .zero).labelOpacity == 0)
        gesture.release(at: 5)
        #expect(gesture.returnStart == 5)
        gesture.release(at: 10) // later releases don't postpone it
        #expect(gesture.returnStart == 5)
        var early = PointerGesture(from: .zero, to: target, label: "x", hold: nil)
        early.release(at: 0.3)
        #expect(early.returnStart == early.arrivalTime)
    }

    @Test func reduceMotionFadesInPlace() {
        let gesture = PointerGesture(from: .zero, to: target, label: "Here", hold: 1, reduceMotion: true)
        #expect(gesture.outbound.duration == 0)
        #expect(gesture.frame(at: 0.05, cursor: .zero).position == target.point)
        #expect(gesture.frame(at: 0.5, cursor: .zero).phase == .pointing)
        let ending = gesture.frame(at: (gesture.endTime ?? 0) - 0.05, cursor: CGPoint(x: 9, y: 9))
        #expect(ending.phase == .vanishing)
        #expect(ending.position == target.point)
    }

    @Test func blankLabelsAreDropped() {
        #expect(PointerGesture(from: .zero, to: target, label: "  ").label == nil)
    }
}

@Suite("Buddy pointer rendering")
struct BuddyPointerArtistTests {
    @Test func labelPillFlipsAwayFromEdges() {
        let canvas = CGSize(width: 640, height: 400)
        let normal = BuddyPointerArtist.labelRect("Save", tip: CGPoint(x: 100, y: 100), canvasSize: canvas)
        #expect(normal.minX > 100 && normal.minY > 100)
        let right = BuddyPointerArtist.labelRect("Save", tip: CGPoint(x: 630, y: 100), canvasSize: canvas)
        #expect(right.maxX < 630)
        let bottom = BuddyPointerArtist.labelRect("Save", tip: CGPoint(x: 100, y: 395), canvasSize: canvas)
        #expect(bottom.maxY < 395)
        let long = BuddyPointerArtist.labelRect(String(repeating: "very long label ", count: 20), tip: CGPoint(x: 100, y: 100), canvasSize: canvas)
        #expect(long.width <= 330)
    }

    @Test func paintedBoundsCoverTheBuddyAndHalo() {
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        let target = PointingDestination.rect(CGRect(x: 400, y: 50, width: 80, height: 30)).resolved
        let gesture = PointerGesture(from: CGPoint(x: 100, y: 300), to: target, label: "Save", hold: 2)
        let frame = gesture.frame(at: gesture.arrivalTime + 1, cursor: .zero)
        let bounds = BuddyPointerArtist.paintedBounds(frame, display: display, canvasSize: display.size)
        // Halo around the element (local y-down: 400 - 80 = 320 top).
        #expect(bounds.contains(CGRect(x: 395, y: 315, width: 90, height: 40)))
        #expect(bounds.contains(CGPoint(x: frame.position.x, y: 400 - frame.position.y)))
        #expect(BuddyPointerArtist.paintedBounds(gesture.frame(at: 100, cursor: .zero), display: display, canvasSize: display.size).isNull)
    }

    @Test func drawsTheBuddyWhereTheTipIs() throws {
        let width = 200, height = 160
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { raw in
            let context = try #require(CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let display = CGRect(x: 1000, y: 500, width: CGFloat(width), height: CGFloat(height))
            // Tip at local (60, 40): global (1060, 620).
            let frame = PointerFrame(phase: .pointing, position: CGPoint(x: 1060, y: 620), rotation: 0, scale: 1, opacity: 1,
                                     target: ResolvedPointingTarget(point: CGPoint(x: 1060, y: 620), frame: nil), haloProgress: 0, haloPulse: 0,
                                     haloOpacity: 0, label: nil, labelOpacity: 0)
            BuddyPointerArtist.draw(frame, in: context, display: display, canvasSize: display.size)
        }
        func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let i = (y * width + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
        // Inside the body, down-right of the tip: opaque and blue.
        let body = pixel(60 + 9, 40 + 11)
        #expect(body.a > 200 && body.b > body.r)
        // Up-left of the tip, away from the glow: empty.
        #expect(pixel(30, 10).a == 0)
    }

    @Test func filmstripRenders() throws {
        let display = CGRect(x: 0, y: 0, width: 160, height: 100)
        let gesture = PointerGesture(from: CGPoint(x: 10, y: 10), to: PointingDestination.point(CGPoint(x: 120, y: 70)).resolved, label: "Here")
        let png = try BuddyPointerArtist.renderFilmstrip(frames: [("a", gesture.frame(at: 0.4, cursor: .zero)), ("b", gesture.frame(at: 1.5, cursor: .zero))],
                                                         display: display, columns: 2, scale: 2) { context, size in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        }
        let size = try #require(ImageCoding.pixelSize(of: png))
        // Two 160-wide panels plus three 12 pt gaps, at 2x; one row of 100 + 26 caption plus two gaps.
        #expect(size.width == (160 * 2 + 36) * 2)
        #expect(size.height == (126 + 24) * 2)
    }
}
