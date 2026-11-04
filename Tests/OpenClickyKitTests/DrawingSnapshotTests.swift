import Foundation
import QuartzCore
import Testing
@testable import OpenClickyKit

// Offscreen renders of the layer tree at chosen moments (DrawingSnapshot via DrawingRehearsal).

private func isInk(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.r > 150 && p.g < 140 && p.b < 140 }
private func isPaper(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.r > 235 && p.g > 235 && p.b > 235 }

// Rehearsals run on the main actor; the async tests yield between them so other suites' main-actor timers keep firing.
@MainActor
@Test func snapshotsShowThePenPartWayThroughAStroke() async throws {
    let program = "line(100, 400, 1100, 400, { tone: \"#E5484D\", wobble: 0, glow: false, size: 8 })"
    func render(at time: TimeInterval?) throws -> CGImage {
        var options = DrawingRehearsal.Options()
        options.backdrop = .color("#FFFFFF")
        options.at = time
        return try DrawingRehearsal.run(program: program, options: options).image
    }
    let before = try render(at: 0)
    await Task.yield()
    #expect(isPaper(DrawingSnapshot.pixel(before, x: 150, y: 400)))
    #expect(isPaper(DrawingSnapshot.pixel(before, x: 1050, y: 400)))

    let middle = try render(at: 0.45)
    await Task.yield()
    #expect(isInk(DrawingSnapshot.pixel(middle, x: 150, y: 400)))
    #expect(isPaper(DrawingSnapshot.pixel(middle, x: 1050, y: 400)))

    let after = try render(at: nil)
    #expect(isInk(DrawingSnapshot.pixel(after, x: 150, y: 400)))
    #expect(isInk(DrawingSnapshot.pixel(after, x: 1050, y: 400)))
    #expect(after.width == 1280 && after.height == 832)
}

@MainActor
@Test func drawingWaitsForItsSpokenLine() async throws {
    let program = """
    step(1)
    say("First we look at the left.")
    box(100, 300, 300, 200, { tone: "#E5484D", fill: "#E5484D", fillAlpha: 1, glow: false })
    step(2)
    say("Then at the right side of the screen.")
    box(800, 300, 300, 200, { tone: "#E5484D", fill: "#E5484D", fillAlpha: 1, glow: false })
    """
    var options = DrawingRehearsal.Options()
    options.backdrop = .color("#FFFFFF")
    // The first line starts at 0.6 s and lasts about 2.5 s; the second starts about 0.3 s after that.
    options.at = 2.0
    let early = try DrawingRehearsal.run(program: program, options: options)
    await Task.yield()
    #expect(isInk(DrawingSnapshot.pixel(early.image, x: 250, y: 400)))
    #expect(isPaper(DrawingSnapshot.pixel(early.image, x: 950, y: 400)))
    options.at = nil
    let late = try DrawingRehearsal.run(program: program, options: options)
    #expect(isInk(DrawingSnapshot.pixel(late.image, x: 950, y: 400)))
    #expect(late.lines.map(\.text) == ["First we look at the left.", "Then at the right side of the screen."])
    #expect(late.finishedAt != nil)
}

/// The programs rendered for Tests/Fixtures/Drawing/2d must keep running cleanly.
@MainActor
@Test func evidenceProgramsRenderWithoutErrors() async throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/Drawing/2d")
    let programs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension == "js" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    try #require(!programs.isEmpty, "no evidence programs in \(directory.path)")
    for url in programs {
        var options = DrawingRehearsal.Options()
        let name = url.lastPathComponent
        options.backdrop = name.contains("split") ? .split : .mockScreen(dark: name.contains("dark"))
        let result = try DrawingRehearsal.run(program: try String(contentsOf: url, encoding: .utf8), options: options)
        #expect(result.errors.isEmpty, "\(url.lastPathComponent): \(result.errors)")
        #expect(result.finishedAt != nil, "\(url.lastPathComponent) never finished")
        #expect(result.markCount > 5)
        await Task.yield()
    }
}

/// A flush on the main thread (DrawingSnapshot.render does one; so may any other code) used to strip the reveal
/// animations from painters built offscreen, which made painter tests fail now and then in full test runs.
@MainActor
@Test func offscreenPaintersKeepTheirAnimationsAcrossAFlush() throws {
    let clock = VirtualClock(CACurrentMediaTime() + 100_000)
    let host = try DrawingEngineHost(clock: { clock.now })
    var events = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now)))
    events += host.perform(.append("line([100, 100], [400, 300])\nwrite(100, 500, \"Hello\")\n"))
    events += host.perform(.end)
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832), clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    painter.apply(events)
    CATransaction.flush()
    _ = try DrawingSnapshot.render(CALayer(), size: CGSize(width: 8, height: 8), at: clock.now + 50)
    let ids = painter.markIDs
    #expect(ids.count == 2)
    for id in ids {
        let container = try #require(painter.layer(forMark: id))
        var animated = 0
        func walk(_ layer: CALayer) {
            animated += layer.animationKeys()?.count ?? 0
            layer.sublayers?.forEach(walk)
            if let mask = layer.mask { walk(mask) }
        }
        walk(container)
        #expect(animated > 0, "mark \(id) lost its reveal")
    }
    #expect(painter.layer.superlayer != nil)
}

/// `done` can arrive with any command's events (here, with `end`, because nothing is drawn), not only from a frame
/// drain; the rehearsal used to miss it, report "still drawing" and render a minute later than it should.
@MainActor
@Test func aRehearsalNoticesDoneWhicheverCommandReportsIt() throws {
    var options = DrawingRehearsal.Options()
    options.backdrop = .none
    let result = try DrawingRehearsal.run(program: "say(\"Nothing to draw here.\")\n", options: options)
    #expect(result.finishedAt != nil)
    #expect(result.time < 5)
}
