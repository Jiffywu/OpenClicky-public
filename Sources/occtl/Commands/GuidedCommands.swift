import CoreGraphics
import Foundation
import ImageIO
import OpenClickyKit
import QuartzCore

/// `occtl guided simulate` and `occtl highlight`: the guided-walkthrough loop and draw-to-ask, run headlessly with
/// scripted pointer events and synthetic strokes (no mouse, talk key, or macOS permissions needed).
enum GuidedCommands {
    static let guidedUsage = """
        Usage: occtl guided simulate <script.json> [--out DIR] [--max-rounds N] [--screen-out screen.png] [--filmstrip buddy.png]
          Plays a scripted walkthrough (docs/dsl-guided.md, "Simulator"): brain answers in the drawing language, user clicks,
          moves, keys and app switches on a virtual clock. Prints every target, trigger and note, and every buddy pointer
          flight; with --out, renders each armed target over the scripted screen as DIR/guided-step-N.png. --screen-out
          writes the scripted screen alone (to show a model what the brain would see). --filmstrip renders the buddy's
          flights over the scripted screen, frame by frame.
        """

    static let guided = OcctlCommand(name: "guided", usage: "guided simulate <script.json> [--out DIR]   run a scripted walkthrough") { args in
        guard args.first == "simulate", args.count >= 2 else { fail(guidedUsage) }
        var out: URL?
        var screenOut: URL?
        var filmstrip: URL?
        var settings = GuidedWalkthrough.Settings()
        var iterator = args.dropFirst(2).makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--out":
                guard let value = iterator.next() else { fail(guidedUsage) }
                out = URL(fileURLWithPath: value)
            case "--screen-out":
                guard let value = iterator.next() else { fail(guidedUsage) }
                screenOut = URL(fileURLWithPath: value)
            case "--filmstrip":
                guard let value = iterator.next() else { fail(guidedUsage) }
                filmstrip = URL(fileURLWithPath: value)
            case "--max-rounds":
                guard let value = iterator.next(), let rounds = Int(value), rounds > 0 else { fail("--max-rounds wants a positive number") }
                settings.maxRounds = rounds
            default: fail(guidedUsage)
            }
        }
        let script = try JSONDecoder().decode(GuidedScript.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        if let screenOut, let image = script.mockScreen() { try ImageCoding.pngData(image).write(to: screenOut) }
        let chosenSettings = settings, chosenOut = out, chosenFilmstrip = filmstrip
        let output = try await MainActor.run { () throws -> [String] in
            let result = try GuidedSimulator.run(script, settings: chosenSettings)
            var lines = result.log
            lines.append("")
            lines.append("turns started: " + (result.requests.isEmpty ? "none" : result.requests.map { "\($0.trigger.rawValue) (step \($0.step))" }.joined(separator: ", ")))
            let phase: String = switch result.phase {
            case .ended(let reason): "ended (\(reason.rawValue))"
            case .idle: "idle"
            case .armed: "waiting for a click"
            case .manual: "waiting for manual work"
            case .followingUp: "waiting for the next answer"
            }
            lines.append("final phase: \(phase)")
            let flights = result.buddy.filter { if case .fly = $0.call { true } else { false } }.count
            lines.append("buddy: \(flights) flight\(flights == 1 ? "" : "s"), \(result.buddy.count - flights) return or vanish call\(result.buddy.count - flights == 1 ? "" : "s")")
            if let url = chosenFilmstrip {
                try writeFilmstrip(result, script: script, to: url)
                lines.append("wrote \(url.relativePath)")
            }
            if let dir = chosenOut {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let backdrop = script.mockScreen()
                let display = script.geometry.displayFrame
                for (index, armed) in result.targets.enumerated() {
                    // Far in the media future, so Core Animation never retires the ring's animations before the snapshot.
                    let base = CACurrentMediaTime() + 100_000
                    let layer = GuidedTargetLayer.make(for: armed.target, display: display, begin: base)
                    let image = try DrawingSnapshot.render(layer, size: display.size, at: base + 0.7, backdrop: backdrop)
                    let url = dir.appendingPathComponent("guided-step-\(index + 1).png")
                    try DrawingSnapshot.writePNG(image, to: url)
                    lines.append("wrote \(url.relativePath)")
                }
            }
            return lines
        }
        for line in output { print(line) }
    }

    /// The buddy's flights as frames over the scripted screen: appearing at the user's pointer, mid-flight, ringing the
    /// target with its label, and on the way back when the step ends.
    @MainActor
    static func writeFilmstrip(_ result: GuidedSimulator.Result, script: GuidedScript, to url: URL) throws {
        let display = script.geometry.displayFrame
        // The user's pointer: low in the middle of the window, where a hand would rest.
        let cursor = CGPoint(x: display.midX, y: display.minY + display.height * 0.3)
        var frames: [(caption: String, frame: PointerFrame)] = []
        var index = 0
        for (offset, entry) in result.buddy.enumerated() {
            guard case .fly(let destination, let label, let hold) = entry.call, frames.count < 12 else { continue }
            index += 1
            var gesture = PointerGesture(from: cursor, to: destination.resolved, label: label, hold: hold)
            // What ended this flight: a later release or cancel, if any.
            let ending = result.buddy.dropFirst(offset + 1).first { if case .fly = $0.call { false } else { true } }
            let arrival = gesture.arrivalTime
            frames.append(("flight \(index) appears", gesture.frame(at: gesture.timing.appear * 0.6, cursor: cursor)))
            frames.append(("flight \(index) mid-flight", gesture.frame(at: gesture.timing.appear + gesture.outbound.duration * 0.5, cursor: cursor)))
            frames.append(("flight \(index) pointing", gesture.frame(at: arrival + 0.6, cursor: cursor)))
            if let ending, case .release = ending.call {
                gesture.release(at: arrival + 1)
                frames.append(("flight \(index) flies back", gesture.frame(at: arrival + 1 + gesture.returnDuration * 0.5, cursor: cursor)))
            } else if let ending, case .cancel = ending.call {
                // Cancelled: the buddy is simply gone (an empty panel).
                gesture.release(at: arrival + 1)
                frames.append(("flight \(index) vanishes (cancelled)", gesture.frame(at: (gesture.endTime ?? arrival + 3) + 1, cursor: cursor)))
            }
        }
        guard !frames.isEmpty else { fail("The script flew the buddy nowhere; no filmstrip written.") }
        let backdrop = script.mockScreen()
        let png = try BuddyPointerArtist.renderFilmstrip(frames: frames, display: display, columns: 4, scale: 1) { context, size in
            guard let backdrop else { return }
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(backdrop, in: CGRect(origin: .zero, size: size))
            context.restoreGState()
        }
        try png.write(to: url)
    }

    static let highlightUsage = """
        Usage: occtl highlight (--demo | --screen shot.png) --mark SHAPE [--mark SHAPE …] [--dwell S] [--out marked.png] [--json]
          Plays highlighter strokes as one hold of the talk key and prints the description the next turn would get.
          SHAPE (screenshot pixels, top-left origin): circle:cx,cy,r[,ry]  underline:x,y,w  line:x1,y1,x2,y2  scribble:x,y,w,h
          path:x,y;x,y;…   Text under each mark is read with on-device OCR (no Accessibility in this simulator).
        """

    static let highlight = OcctlCommand(name: "highlight", usage: "highlight --demo --mark circle:cx,cy,r   simulate draw-to-ask") { args in
        var shapes: [HighlightSimulator.Shape] = []
        var screenPath: String?
        var demo = false
        var out: URL?
        var json = false
        var dwell = 0.0
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--mark":
                guard let value = iterator.next(), let shape = HighlightSimulator.Shape(value) else { fail(highlightUsage) }
                shapes.append(shape)
            case "--screen":
                guard let value = iterator.next() else { fail(highlightUsage) }
                screenPath = value
            case "--demo": demo = true
            case "--out":
                guard let value = iterator.next() else { fail(highlightUsage) }
                out = URL(fileURLWithPath: value)
            case "--dwell":
                guard let value = iterator.next(), let seconds = Double(value), seconds >= 0 else { fail("--dwell wants seconds") }
                dwell = seconds
            case "--json": json = true
            default: fail(highlightUsage)
            }
        }
        guard !shapes.isEmpty, demo || screenPath != nil else { fail(highlightUsage) }
        let image: CGImage
        if let screenPath {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: screenPath) as CFURL, nil),
                  let loaded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Can't read \(screenPath)") }
            image = loaded
        } else {
            image = HighlightSimulator.demoScreen().image
        }
        // One display, one point per screenshot pixel.
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let layout = DesktopLayout(displays: [DisplayGeometry(id: 1, frame: frame, scale: 1, isPrimary: true)])
        let geometry = CaptureGeometry(displayFrame: frame, pixelWidth: image.width, pixelHeight: image.height)
        guard let gesture = HighlightSimulator.gesture(shapes, geometry: geometry, dwellAtEnd: dwell) else {
            fail("No ink was drawn: strokes must move at least 8 points, slower than a quick flick.")
        }
        let shot = TurnScreenshot(jpeg: try ImageCoding.jpegData(image, quality: 0.9), label: "main display", isCursorScreen: true,
                                  pixelSize: frame.size, displayFrame: frame)
        let started = Date()
        // A generous OCR timeout: the first recognition in a fresh build loads the text model (the app warms it at launch).
        let result = await DrawToAskSession.describe(gesture, screenshots: [shot], layout: layout,
                                                     harvester: HighlightHarvester(accessibility: nil, recognizer: HighlightTextRecognizer(timeout: 90)))
        let seconds = Date().timeIntervalSince(started)
        var context = TurnContext()
        context.highlightDescription = result.description.text
        if json {
            print(TurnContractJSON.context(context).jsonString())
        } else {
            for (index, item) in result.description.items.enumerated() {
                let box = item.pixelRegion.map { "[\(Int($0.minX)), \(Int($0.minY)), \(Int($0.width)), \(Int($0.height))]" } ?? "?"
                print("mark \(index + 1): \(item.mark.kind.rawValue), \(item.mark.stroke.points.count) points, region \(box), "
                      + "\(item.harvest.lines.count) line(s) read" + (item.mark.dwellSeconds > 0 ? String(format: ", dwell %.2f s", item.mark.dwellSeconds) : ""))
            }
            print(String(format: "described in %.2f s (on-device OCR)", seconds))
            print("")
            print("TurnContext.highlightDescription:")
            print(result.description.text)
        }
        if let out, let inked = try? ImageCoding.decode(result.screenshots[0].jpeg) {
            try writeMarked(inked, regions: result.description.items.compactMap(\.pixelRegion), to: out)
            if !json { print("\nwrote \(out.relativePath) (the screenshot as the brain gets it, with each mark's region outlined for review)") }
        }
    }

    /// The inked screenshot with each region outlined in dashed grey (review aid; the brain gets it without outlines).
    static func writeMarked(_ image: CGImage, regions: [CGRect], to url: URL) throws {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 0.9))
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [6, 4])
        for region in regions { context.stroke(region) }
        guard let marked = context.makeImage() else { return }
        try ImageCoding.pngData(marked).write(to: url)
    }
}
