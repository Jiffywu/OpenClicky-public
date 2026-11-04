import AppKit
import CoreGraphics
import CoreText
import Foundation
import OpenClickyKit

/// `occtl screen …`: what OpenClicky sees (context, screenshots, Accessibility elements) and how it maps and points.
enum ScreenCommands {
    static let screen = OcctlCommand(
        name: "screen",
        usage: "screen <context|capture|elements|look|displays|map|pointer-demo> …  what OpenClicky sees and where it points"
    ) { args in
        guard let sub = args.first else { fail(help) }
        let rest = Array(args.dropFirst())
        switch sub {
        case "context": await context(rest)
        case "capture": await capture(rest)
        case "elements": try await elements(rest)
        case "look": await look(rest)
        case "displays": displays()
        case "map": try map(rest)
        case "pointer-demo": try pointerDemo(rest)
        default: fail(help)
        }
    }

    static let help = """
    Usage:
      occtl screen context [--bundle ID | --pid PID] [--no-text] [--allow-prompts] [--max-chars N] [--turn [--no-elements]] [--redact]
            front app (or the given app), window, focus, selection and the open document as JSON (no Screen Recording needed);
            --turn prints it as the brain's turn context, with the front window's elements when Accessibility allows
      occtl screen capture <out.jpg> [--cursor-only] [--long-edge N] [--quality Q] [--no-settle] [--no-cursor]
            screenshots as JPEG (needs Screen Recording for this terminal); extra screens go to out-2.jpg, …
      occtl screen elements [--bundle ID | --pid PID] [--delay S] [--find LABEL] [--lines] [--max N]
            Accessibility snapshot of the front window (needs Accessibility for this terminal)
      occtl screen look [--out out.jpg] [--no-elements] [--allow-prompts] [--redact]
            one turn's look: screenshots, context and elements gathered together, as the app does at key-up
      occtl screen displays
            display layout in AppKit and Quartz coordinates
      occtl screen map <x> <y> [--screen N] [--long-edge N]
            where a screenshot pixel lands on screen
      occtl screen pointer-demo <out.png>
            render the buddy pointer's flight, ring and label offscreen
    """

    // MARK: context

    static func context(_ args: [String]) async {
        var options = ScreenContextOptions(document: .noPrompts)
        if args.contains("--no-text") { options.document.includeText = false }
        if args.contains("--allow-prompts") {
            options.document.allowAutomationPrompt = true
            options.document.folderPolicy = .readAndRecord
        }
        if let max = value(after: "--max-chars", in: args).flatMap(Int.init) { options.document.limits.maxCharacters = max }
        var gatherer = ScreenContextGatherer.live(frontApps: FrontAppTracker(ignoring: []))
        if let app = targetApp(args) { gatherer.frontApp = { app } }
        let context = await gatherer.gather(options)
        var json = context.jsonValue
        if args.contains("--turn") {
            var snapshot: WindowElementSnapshot?
            if !args.contains("--no-elements"), let app = context.frontApp {
                snapshot = AccessibilityElementReader().snapshot(of: app, layout: context.layout)
            }
            json = [
                "turnContext": TurnContractJSON.context(context.turnContext(elements: snapshot)),
                "appNotes": .array(context.turnAppNotes.map(JSONValue.string)),
                "notes": .array(context.notes.map(JSONValue.string)),
            ]
        }
        if args.contains("--redact") { json = redact(json) }
        print(pretty(json))
    }

    // MARK: look

    static func look(_ args: [String]) async {
        var contextOptions = ScreenContextOptions(document: .noPrompts)
        if args.contains("--allow-prompts") {
            contextOptions.document.allowAutomationPrompt = true
            contextOptions.document.folderPolicy = .readAndRecord
        }
        let looker = TurnLooker.live(frontApps: FrontAppTracker(ignoring: []))
        let look = await looker.look(context: contextOptions, includeElements: !args.contains("--no-elements"))
        var shots: [JSONValue] = []
        for (index, shot) in look.screenshots.enumerated() {
            var json = TurnContractJSON.screenshot(shot)
            if let out = value(after: "--out", in: args), case .object(var object) = json {
                let url = outputURL(out, screen: index + 1)
                do {
                    try shot.jpeg.write(to: url)
                    object["file"] = .string(url.path)
                } catch {
                    object["writeError"] = .string(error.localizedDescription)
                }
                json = .object(object)
            }
            shots.append(json)
        }
        var result: [String: JSONValue] = [
            "turnContext": TurnContractJSON.context(look.turnContext()),
            "appNotes": .array(look.appNotes.map(JSONValue.string)),
            "notes": .array(look.context.notes.map(JSONValue.string)),
        ]
        if let error = look.captureError { result["captureError"] = .string(error) }
        if args.contains("--redact") { result = redact(.object(result)).objectValue ?? result }
        // Screenshot labels and sizes are OpenClicky's own, not the user's content.
        result["screenshots"] = .array(shots)
        result["elementsRead"] = .number(Double(look.elements?.elements.count ?? 0))
        result["elapsedMs"] = .number((Double(look.elapsed.components.seconds) * 1000 + Double(look.elapsed.components.attoseconds) / 1e15).rounded())
        print(pretty(.object(result)))
    }

    /// Replaces the user's content (titles, text, URLs, paths, names quoted in notes) with placeholders, keeping
    /// structure and app identity.
    static func redact(_ value: JSONValue) -> JSONValue { ContextRedaction.redact(value) }

    // MARK: capture

    static func capture(_ args: [String]) async {
        guard let path = args.first, !path.hasPrefix("--") else { fail("Usage: occtl screen capture <out.jpg> [--cursor-only] [--long-edge N] [--quality Q] [--no-settle] [--no-cursor]") }
        var options = ScreenCaptureOptions()
        if args.contains("--cursor-only") { options.displays = .cursorOnly }
        if let edge = value(after: "--long-edge", in: args).flatMap(Int.init) { options.longEdge = edge }
        if let quality = value(after: "--quality", in: args).flatMap(Double.init) { options.jpegQuality = quality }
        if args.contains("--no-settle") { options.settle = nil }
        if args.contains("--no-cursor") { options.showsCursor = false }

        let layout = DesktopLayout.current()
        let cursor = DesktopLayout.currentCursorLocation(in: layout)
        let plan = ScreenCapturePlan(layout: layout, cursor: cursor, displays: options.displays, longEdge: options.longEdge)
        let planJSON: JSONValue = .array(plan.entries.map { entry in
            ["screen": .number(Double(entry.screenNumber)), "displayID": .number(Double(entry.display.id)), "isCursorScreen": .bool(entry.isCursorScreen),
             "pixelWidth": .number(Double(entry.pixelWidth)), "pixelHeight": .number(Double(entry.pixelHeight)),
             "displayFrame": entry.display.frame.jsonValue, "scale": .number(entry.display.scale)]
        })
        guard ScreenRecordingAccess.isGranted else {
            print(pretty(["captured": false, "plan": planJSON,
                          "error": .string(ScreenCaptureError.permissionDenied.description + " (For occtl, allow the terminal app that runs it.)")]))
            exit(2)
        }
        do {
            let started = Date()
            let captures = try await ScreenCaptureKitCapturer().capture(options)
            var written: [JSONValue] = []
            for capture in captures {
                let url = outputURL(path, screen: capture.screenNumber)
                try capture.imageData.write(to: url)
                var json = capture.jsonValue
                if case .object(var object) = json {
                    object["file"] = .string(url.path)
                    json = .object(object)
                }
                written.append(json)
            }
            print(pretty(["captured": true, "elapsedMs": .number((Date().timeIntervalSince(started) * 1000).rounded()), "captures": .array(written)]))
        } catch {
            print(pretty(["captured": false, "plan": planJSON, "error": .string(String(describing: error))]))
            exit(1)
        }
    }

    /// out.jpg for screen 1, out-2.jpg for screen 2, …
    static func outputURL(_ path: String, screen: Int) -> URL {
        let url = URL(fileURLWithPath: path)
        guard screen > 1 else { return url }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(screen).\(ext)")
    }

    // MARK: elements

    static func elements(_ args: [String]) async throws {
        guard AccessibilityAccess.isTrusted else {
            print(pretty(["error": "Accessibility permission is missing for the app running occtl (System Settings → Privacy & Security → Accessibility)."]))
            exit(2)
        }
        if let delay = value(after: "--delay", in: args).flatMap(Double.init), delay > 0 {
            FileHandle.standardError.write(Data("Snapshot in \(delay)s: bring the app you want to the front…\n".utf8))
            try await Task.sleep(for: .seconds(delay))
        }
        guard let app = targetApp(args) ?? FrontAppTracker(ignoring: []).current else { fail("Couldn't tell which app is in front.") }
        var limits = AccessibilityElementReader.Limits()
        if let max = value(after: "--max", in: args).flatMap(Int.init) { limits.maxElements = max }
        let layout = DesktopLayout.current()
        guard let snapshot = AccessibilityElementReader(limits: limits).snapshot(of: app, layout: layout) else {
            print(pretty(["error": .string("\(app.name ?? "The app") has no window this process can read."), "app": app.jsonValue]))
            exit(1)
        }
        if args.contains("--lines") {
            let plan = ScreenCapturePlan(layout: layout, cursor: DesktopLayout.currentCursorLocation(in: layout), displays: .all,
                                         longEdge: CaptureSizing.modelLongEdge)
            let geometry = plan.entries.first { entry in snapshot.windowFrame.map { entry.display.frame.intersects($0) } ?? entry.isCursorScreen }
                .map { CaptureGeometry(displayFrame: $0.display.frame, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight) }
            snapshot.promptLines(in: geometry).forEach { print($0) }
            return
        }
        if let query = value(after: "--find", in: args) {
            let matches = ElementLabelMatcher.matches(for: query, in: snapshot.elements).prefix(5)
            let resolved = snapshot.resolve(label: query)
            var result: [String: JSONValue] = [
                "query": .string(query),
                "matches": .array(matches.map { ["score": .number(($0.score * 1000).rounded() / 1000), "matched": .string($0.matchedText), "element": $0.element.jsonValue] }),
            ]
            if let resolved {
                result["pointAt"] = resolved.target.point.jsonValue
                if let frame = resolved.target.frame { result["outline"] = frame.jsonValue }
            }
            print(pretty(.object(result)))
            return
        }
        print(pretty(snapshot.jsonValue))
    }

    // MARK: displays and mapping

    static func displays() {
        let layout = DesktopLayout.current()
        let cursor = DesktopLayout.currentCursorLocation(in: layout)
        print(pretty([
            "displays": .array(layout.displays.map { display in
                guard case .object(var object) = display.jsonValue else { return display.jsonValue }
                object["quartzFrame"] = layout.quartzRect(fromAppKit: display.frame).jsonValue
                object["nativePixels"] = ["width": .number(Double(display.nativePixelSize.width)), "height": .number(Double(display.nativePixelSize.height))]
                return .object(object)
            }),
            "cursor": cursor.jsonValue,
            "cursorQuartz": layout.quartzPoint(fromAppKit: cursor).jsonValue,
            "cursorDisplayID": .number(Double(layout.display(nearest: cursor)?.id ?? 0)),
        ]))
    }

    static func map(_ args: [String]) throws {
        guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else { fail("Usage: occtl screen map <x> <y> [--screen N] [--long-edge N]") }
        let layout = DesktopLayout.current()
        let plan = ScreenCapturePlan(layout: layout, cursor: DesktopLayout.currentCursorLocation(in: layout), displays: .all,
                                     longEdge: value(after: "--long-edge", in: args).flatMap(Int.init) ?? CaptureSizing.modelLongEdge)
        let number = value(after: "--screen", in: args).flatMap(Int.init)
        guard let entry = plan.entries.first(where: { $0.screenNumber == number }) ?? plan.cursorEntry ?? plan.entries.first else { fail("No displays.") }
        let geometry = CaptureGeometry(displayFrame: entry.display.frame, pixelWidth: entry.pixelWidth, pixelHeight: entry.pixelHeight)
        let pixel = CGPoint(x: x, y: y)
        let appKit = geometry.appKitPoint(fromPixel: pixel)
        print(pretty([
            "screen": .number(Double(entry.screenNumber)),
            "screenshot": ["width": .number(Double(entry.pixelWidth)), "height": .number(Double(entry.pixelHeight))],
            "pixel": pixel.jsonValue,
            "clamped": .bool(!geometry.containsPixel(pixel)),
            "displayLocal": geometry.localPoint(fromPixel: pixel).jsonValue,
            "appKitGlobal": appKit.jsonValue,
            "quartzGlobal": layout.quartzPoint(fromAppKit: appKit).jsonValue,
            "displayFrame": entry.display.frame.jsonValue,
        ]))
    }

    // MARK: pointer demo

    static func pointerDemo(_ args: [String]) throws {
        guard let path = args.first else { fail("Usage: occtl screen pointer-demo <out.png>") }
        // A pretend 640×400 display at the AppKit origin.
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        func global(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: display.maxY - y) }
        // The "Save" button the mock window draws, in display-local (y-down) points.
        let saveLocal = CGRect(x: 462, y: 300, width: 76, height: 28)
        let saveFrame = CGRect(x: saveLocal.minX, y: display.maxY - saveLocal.maxY, width: saveLocal.width, height: saveLocal.height)
        let cursor = global(110, 120)

        let toButton = PointerGesture(from: cursor, to: PointingDestination.rect(saveFrame).resolved, label: "Save", hold: 1.5)
        let edgeTarget = PointingDestination.point(global(610, 380)).resolved
        let toEdge = PointerGesture(from: cursor, to: edgeTarget, label: "Turn on Allow JavaScript from Apple Events in the Develop menu", hold: 1.5)

        func sample(_ gesture: PointerGesture, _ name: String, _ t: Double) -> (String, PointerFrame) {
            let frame = gesture.frame(at: t, cursor: cursor)
            return ("\(name) t=\(String(format: "%.2f", t))s \(frame.phase.rawValue)", frame)
        }
        let a = toButton.arrivalTime, r = toButton.returnStart ?? a
        let b = toEdge.arrivalTime
        let frames = [
            sample(toButton, "button", 0.09),
            sample(toButton, "button", toButton.timing.appear + toButton.outbound.duration * 0.35),
            sample(toButton, "button", toButton.timing.appear + toButton.outbound.duration * 0.7),
            sample(toButton, "button", a + 0.2),
            sample(toButton, "button", a + 1.2),
            sample(toButton, "button", r + toButton.returnDuration * 0.5),
            sample(toEdge, "edge", toEdge.timing.appear + toEdge.outbound.duration * 0.5),
            sample(toEdge, "edge", b + 0.9),
            sample(toEdge, "edge", (toEdge.endTime ?? b) - 0.08),
        ]
        let png = try BuddyPointerArtist.renderFilmstrip(frames: frames, display: display, columns: 3, scale: 2) { context, size in
            drawMockScreen(context, size: size, saveButton: saveLocal, path: toButton.outbound, display: display)
        }
        try png.write(to: URL(fileURLWithPath: path))
        print(pretty([
            "file": .string(path),
            "flight": ["seconds": .number((toButton.outbound.duration * 1000).rounded() / 1000),
                       "start": toButton.outbound.start.jsonValue, "control": toButton.outbound.control.jsonValue, "end": toButton.outbound.end.jsonValue],
            "gestureSeconds": .number(((toButton.endTime ?? 0) * 1000).rounded() / 1000),
        ]))
    }

    /// A plain pretend desktop: a window with text lines, a Save button and the outbound flight path dotted in.
    static func drawMockScreen(_ context: CGContext, size: CGSize, saveButton: CGRect, path: PointerFlightPath, display: CGRect) {
        context.setFillColor(CGColor(srgbRed: 0.80, green: 0.85, blue: 0.91, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let window = CGRect(x: 40, y: 40, width: 540, height: 310)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 4), blur: 14, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))
        context.addPath(CGPath(roundedRect: window, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: 30).insetBy(dx: 0.5, dy: 0.5))
        for (index, color) in [(0.99, 0.37, 0.34), (0.99, 0.74, 0.18), (0.16, 0.78, 0.25)].enumerated() {
            context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: window.minX + 12 + CGFloat(index) * 18, y: window.minY + 10, width: 11, height: 11))
        }
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.86, blue: 0.88, alpha: 1))
        for row in 0..<7 {
            let width: CGFloat = row % 3 == 2 ? 300 : 460
            context.fill(CGRect(x: window.minX + 24, y: window.minY + 56 + CGFloat(row) * 28, width: width, height: 10))
        }
        context.addPath(CGPath(roundedRect: saveButton, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        context.setStrokeColor(CGColor(srgbRed: 0.72, green: 0.73, blue: 0.76, alpha: 1))
        context.setLineWidth(1)
        context.drawPath(using: .fillStroke)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): NSFont.systemFont(ofSize: 13) as CTFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Save", attributes: attributes))
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: saveButton.minX + 23, y: saveButton.midY + 4.5)
        CTLineDraw(line, context)
        context.restoreGState()
        // The flight path, dotted, so the arc is visible in the still frames.
        context.setFillColor(CGColor(srgbRed: 0.16, green: 0.47, blue: 1, alpha: 0.35))
        for step in 0...24 {
            let p = path.position(at: Double(step) / 24)
            context.fillEllipse(in: CGRect(x: p.x - display.minX - 1.5, y: display.maxY - p.y - 1.5, width: 3, height: 3))
        }
    }

    // MARK: helpers

    /// The app named by --bundle or --pid, if either was given.
    static func targetApp(_ args: [String]) -> FrontAppInfo? {
        if let bundle = value(after: "--bundle", in: args) {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { fail("\(bundle) isn't running.") }
            return FrontAppInfo(name: running.localizedName, bundleIdentifier: running.bundleIdentifier, processIdentifier: running.processIdentifier)
        }
        if let pid = value(after: "--pid", in: args).flatMap(Int32.init) {
            let running = NSRunningApplication(processIdentifier: pid)
            return FrontAppInfo(name: running?.localizedName, bundleIdentifier: running?.bundleIdentifier, processIdentifier: pid)
        }
        return nil
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// Indented JSON with sorted keys; numbers print as short as they round-trip (JSONSerialization would print
    /// 0.54400000000000004).
    static func pretty(_ value: JSONValue, indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case .object(let object) where !object.isEmpty:
            let members = object.keys.sorted().map { "\(inner)\(JSONValue.string($0).jsonString()): \(pretty(object[$0]!, indent: inner))" }
            return "{\n" + members.joined(separator: ",\n") + "\n\(indent)}"
        case .array(let array) where !array.isEmpty:
            return "[\n" + array.map { inner + pretty($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        default:
            return value.jsonString()
        }
    }
}
