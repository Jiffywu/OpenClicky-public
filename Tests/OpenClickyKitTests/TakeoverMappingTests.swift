import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import OpenClickyKit

private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

@Suite("Take-over coordinate mapping")
struct TakeoverMappingTests {
    @Test func screenshotPixelsScaleToQuartzPointsOnThePrimaryDisplay() throws {
        let mapper = TakeoverFixtures.observation().mapper
        // 1280 px across 1512 pt: one pixel is 1.18125 pt. The image's corners are the display's corners.
        #expect(close(try mapper.quartzPoint(for: .pixel(x: 0, y: 0)), CGPoint(x: 0, y: 0)))
        #expect(close(try mapper.quartzPoint(for: .pixel(x: 1280, y: 831)), CGPoint(x: 1512, y: 982), 0.1))
        // The center of the image is the center of the display, in Quartz (y down) as CGEvent wants.
        let center = try mapper.quartzPoint(for: .pixel(x: 640, y: 415.5))
        #expect(close(center, CGPoint(x: 756, y: 491), 0.1))
        // A point near the top of the image is near the top of the screen: small Quartz y.
        #expect(try mapper.quartzPoint(for: .pixel(x: 100, y: 10)).y < 20)
    }

    @Test func secondDisplayMapsIntoItsOwnQuartzRegion() throws {
        let mapper = TakeoverFixtures.observation(display: TakeoverFixtures.left, width: 1280, height: 720).mapper
        // The left display's top-left is Quartz (-1920, 0) (its top edge is aligned with the primary's).
        #expect(close(try mapper.quartzPoint(for: .pixel(x: 0, y: 0)), CGPoint(x: -1920, y: 0)))
        // 1280 px across 1920 pt: 1.5 pt per pixel.
        #expect(close(try mapper.quartzPoint(for: .pixel(x: 640, y: 360)), CGPoint(x: -960, y: 540)))
        let back = try #require(mapper.modelPixel(fromQuartz: CGPoint(x: -960, y: 540)))
        #expect(close(back, CGPoint(x: 640, y: 360)))
        // A point on the primary display is not on this screenshot.
        #expect(mapper.modelPixel(fromQuartz: CGPoint(x: 700, y: 400)) == nil)
    }

    @Test func roundTripsEveryPixelBackToItself() throws {
        let mapper = TakeoverFixtures.observation().mapper
        for x in stride(from: 0.0, through: 1280, by: 160) {
            for y in stride(from: 0.0, through: 831, by: 97) {
                let quartz = try mapper.quartzPoint(for: .pixel(x: x, y: y))
                let back = try #require(mapper.modelPixel(fromQuartz: quartz))
                #expect(close(back, CGPoint(x: x, y: y), 0.01))
            }
        }
    }

    @Test func answersJustPastTheEdgeArePulledInAndFurtherOnesRefused() throws {
        let mapper = TakeoverFixtures.observation().mapper
        #expect(close(try mapper.quartzPoint(for: .pixel(x: 1281.5, y: -1)), CGPoint(x: 1512, y: 0), 0.1))
        #expect(throws: DriveMappingError.outsideScreenshot(x: 1300, y: 10, width: 1280, height: 831)) {
            try mapper.quartzPoint(for: .pixel(x: 1300, y: 10))
        }
        #expect(throws: DriveMappingError.self) { try mapper.quartzPoint(for: .pixel(x: 10, y: -40)) }
    }

    @Test func elementIdsMapToTheElementCenter() throws {
        let mapper = TakeoverFixtures.observation().mapper
        // e1 is AppKit (100, 882, 80×30): center (140, 897) → Quartz y = 982 − 897 = 85.
        #expect(close(try mapper.quartzPoint(for: .element("e1")), CGPoint(x: 140, y: 85)))
        #expect(throws: DriveMappingError.unknownElement("e99")) { try mapper.quartzPoint(for: .element("e99")) }
        // An element on the other display is refused for this screenshot.
        let offscreen = DriveElement(id: "e9", role: "AXButton", label: "Far", frame: CGRect(x: -500, y: 100, width: 40, height: 20))
        let other = TakeoverFixtures.observation(elements: [offscreen]).mapper
        #expect(throws: DriveMappingError.elementOffScreen("e9")) { try other.quartzPoint(for: .element("e9")) }
    }

    @Test func resolvesActionsWithAndWithoutTargets() throws {
        let mapper = TakeoverFixtures.observation().mapper
        let cursor = CGPoint(x: 33, y: 44)
        let click = try mapper.resolve(.click(at: nil, button: .left, count: 2, modifiers: .command), cursor: cursor)
        #expect(click == .click(at: cursor, button: .left, count: 2, modifiers: .command))
        let drag = try #require(try mapper.resolve(.drag(from: .pixel(x: 0, y: 0), to: .element("e1"), modifiers: []), cursor: cursor))
        #expect(drag.points.count == 2)
        #expect(close(drag.finalPoint!, CGPoint(x: 140, y: 85)))
        #expect(try mapper.resolve(.screenshot, cursor: cursor) == nil)
        #expect(try mapper.resolve(.type(text: "hi"), cursor: cursor) == .type("hi"))
    }

    @Test func elementLinesUseScreenshotPixelsAndFlagPasswordFields() {
        let lines = TakeoverFixtures.observation().elementLines()
        #expect(lines.count == 3)
        // e1 at AppKit y 882..912 on a 982 pt display is 70..100 pt from the top → 59..85 px.
        #expect(lines[0].hasPrefix("e1 button \"Save\" [85,59,68,25]"))
        #expect(lines[2].contains("password field"))
        #expect(lines[2].contains("off limits"))
    }
}

@Suite("Take-over action parsing")
struct TakeoverActionParsingTests {
    @Test func parsesAnthropicMemberActions() throws {
        #expect(try DriveActionParser.parse(name: "left_click", input: ["coordinate": [10, 20]])
            == .click(at: .pixel(x: 10, y: 20), button: .left, count: 1, modifiers: []))
        #expect(try DriveActionParser.parse(name: "double_click", input: ["coordinate": [1, 2], "text": "shift+super"])
            == .click(at: .pixel(x: 1, y: 2), button: .left, count: 2, modifiers: [.shift, .command]))
        #expect(try DriveActionParser.parse(name: "right_click", input: [:]) == .click(at: nil, button: .right, count: 1, modifiers: []))
        #expect(try DriveActionParser.parse(name: "left_click_drag", input: ["start_coordinate": [1, 2], "coordinate": [3, 4]])
            == .drag(from: .pixel(x: 1, y: 2), to: .pixel(x: 3, y: 4), modifiers: []))
        #expect(try DriveActionParser.parse(name: "scroll", input: ["coordinate": [5, 6], "scroll_direction": "down", "scroll_amount": 4])
            == .scroll(at: .pixel(x: 5, y: 6), direction: .down, amount: 4, modifiers: []))
        #expect(try DriveActionParser.parse(name: "type", input: ["text": "hello"]) == .type(text: "hello"))
        #expect(try DriveActionParser.parse(name: "zoom", input: ["region": [10, 20, 110, 70]]) == .zoom(region: CGRect(x: 10, y: 20, width: 100, height: 50)))
        #expect(try DriveActionParser.parse(name: "wait", input: ["duration": 2]) == .wait(seconds: 2))
        #expect(try DriveActionParser.parse(name: "mouse_move", input: ["element": "e4"]) == .moveMouse(to: .element("e4")))
        let key = try DriveActionParser.parse(name: "key", input: ["text": "super+s", "repeat": 2])
        guard case .key(let combo, let count) = key else { Issue.record("not a key"); return }
        #expect(combo.modifiers == .command && combo.key.keyCode == CGKeyCode(kVK_ANSI_S) && count == 2)
    }

    @Test func rejectsMalformedActions() {
        #expect(throws: DriveActionParseError.self) { try DriveActionParser.parse(name: "left_click", input: ["coordinate": [1]]) }
        #expect(throws: DriveActionParseError.self) { try DriveActionParser.parse(name: "mouse_move", input: [:]) }
        #expect(throws: DriveActionParseError.self) { try DriveActionParser.parse(name: "scroll", input: ["scroll_direction": "sideways"]) }
        #expect(throws: DriveActionParseError.self) { try DriveActionParser.parse(name: "key", input: ["text": "hyper+q"]) }
        #expect(throws: DriveActionParseError.self) { try DriveActionParser.parse(name: "key", input: ["text": "a", "repeat": 500]) }
        #expect(throws: DriveActionParseError.self) { try DriveActionParser.parse(name: "type", input: ["text": ""]) }
        #expect(throws: DriveActionParseError.self) { try DriveActionParser.parse(name: "zoom", input: ["region": [10, 10, 5, 5]]) }
        #expect(throws: DriveActionParseError.self) { try DriveActionParser.parse(name: "left_click", input: ["text": "banana"]) }
        #expect(throws: DriveActionParseError.self) { try DriveActionParser.parse(name: "launch_rockets", input: [:]) }
        // A parse failure becomes a planned action with a problem, never a crash.
        let planned = PlannedAction.parsing(callID: "x", name: "left_click", input: ["coordinate": "here"])
        #expect(planned.action == nil && planned.problem != nil)
    }

    @Test func keyCombosAcceptXdotoolAndMacNames() throws {
        let cases: [(String, DriveModifiers, Int)] = [
            ("Return", [], kVK_Return), ("ctrl+shift+Tab", [.control, .shift], kVK_Tab), ("cmd+c", .command, kVK_ANSI_C),
            ("super+space", .command, kVK_Space), ("alt+Left", .option, kVK_LeftArrow), ("Page_Down", [], kVK_PageDown),
            ("BackSpace", [], kVK_Delete), ("Delete", [], kVK_ForwardDelete), ("F5", [], kVK_F5), ("Escape", [], kVK_Escape),
            ("super+=", .command, kVK_ANSI_Equal), ("ctrl++", .control, kVK_ANSI_Equal), ("A", [], kVK_ANSI_A),
        ]
        for (text, modifiers, code) in cases {
            let combo = try #require(KeyCombo.parse(text), "\(text)")
            #expect(combo.modifiers == modifiers, "\(text)")
            #expect(combo.key.keyCode == CGKeyCode(code), "\(text)")
        }
        #expect(KeyCombo.parse("") == nil)
        #expect(KeyCombo.parse("shift+") == nil)
        #expect(KeyCombo.parse("ctrl+nonsense") == nil)
    }
}
