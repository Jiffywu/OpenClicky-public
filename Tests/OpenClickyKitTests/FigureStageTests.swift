import CoreGraphics
import CoreText
import Foundation
import QuartzCore
import Testing
import simd
@testable import OpenClickyKit

// FigureStage, the live FigureSink: layers, mark timing, mesh loading, frames, ticks, picking, drag and click.

private final class FakeClock: @unchecked Sendable {
    var now: CFTimeInterval = 1000
}

@MainActor
private func stage(_ program: String, clock: FakeClock, base: Double? = nil) async throws -> (FigureStage, FigureProgramHarness) {
    let harness = try FigureProgramHarness()
    harness.run(program)
    #expect(harness.errors.isEmpty, "\(harness.errors)")
    let stage = FigureStage(kernel: FigureKernel(byteBudget: 32 << 20), drivesItself: false, clock: { clock.now })
    for mark in harness.marks where mark.isFigureMark {
        var json = mark.json
        if let base, case .object(var object) = json {
            object["base"] = .number(base)
            json = .object(object)
        }
        stage.apply(DrawingMark(json))
    }
    await stage.settle()
    return (stage, harness)
}

private let program = #"""
const f = figure(100, 80, 400, 300, { tilt: 0, spin: 0 });
const left = f.box({ size: [1, 1, 1], at: [-1, 0, 0] });
const right = f.sphere({ r: 0.5, at: [1, 0, 0], mat: "brass" });
f.label(left, "left block");
"""#

@MainActor
@Test func stageGivesEachFigureAMetalLayer() async throws {
    let clock = FakeClock()
    let (stage, _) = try await stage(program, clock: clock)
    #expect(stage.rendererError == nil)
    let layer = try #require(stage.layer(forFigure: "fig1"))
    #expect(layer.frame == CGRect(x: 100, y: 80, width: 400, height: 300))
    #expect(layer.sublayers?.first is CAMetalLayer)
    let metal = try #require(layer.sublayers?.first as? CAMetalLayer)
    #expect(metal.drawableSize == CGSize(width: 800, height: 600))
    #expect(!metal.isOpaque)
    #expect(stage.layer(forFigure: "fig9") == nil)
    let scene = try #require(stage.scene("fig1"))
    #expect(scene.nodes.allSatisfy { $0.mesh != nil })
}

@MainActor
@Test func marksTakeEffectAtTheirLinesTime() async throws {
    let clock = FakeClock()
    // The engine stamps marks with their line's start (`base`) and an offset (`start`).
    let (stage, harness) = try await stage(program, clock: clock, base: 2000)
    let starts = harness.marks.filter { $0.kind == "part3d" }.map(\.start)
    #expect(starts[1] > starts[0])
    let scene = try #require(stage.scene("fig1"))
    #expect(scene.node("fig1.p1")?.appearAt == 2000 + starts[0])
    clock.now = 1999
    stage.renderFrame()
    #expect(scene.frame(at: clock.now).items.isEmpty)
    clock.now = 2000 + starts[1] + 1
    stage.renderFrame()
    #expect(scene.frame(at: clock.now).items.count == 2)
}

@MainActor
@Test func marksThatOvertakeTheirFigureWait() async throws {
    let harness = try FigureProgramHarness()
    harness.run(program)
    let stage = FigureStage(kernel: FigureKernel(byteBudget: 8 << 20), drivesItself: false)
    for mark in harness.marks.reversed() where mark.isFigureMark { stage.apply(mark) }
    await stage.settle()
    #expect(stage.scene("fig1")?.nodes.count == 2)
    #expect(stage.scene("fig1")?.labels.count == 1)
}

@MainActor
@Test func clickingAPartAsksAboutIt() async throws {
    let clock = FakeClock()
    let (stage, _) = try await stage(program, clock: clock)
    var clicks: [FigureClick] = []
    stage.onPartClicked = { clicks.append($0) }
    clock.now += 5
    stage.renderFrame()
    let scene = try #require(stage.scene("fig1"))
    let frame = scene.frame(at: clock.now, viewport: CGSize(width: 400, height: 300), framing: scene.framing(at: clock.now))
    let leftPoint = frame.project([-1, 0, 0.5]), rightPoint = frame.project([1, 0, 0.45])
    #expect(stage.hitTest(figure: "fig1", at: leftPoint) == "fig1.p1")
    #expect(stage.hitTest(figure: "fig1", at: rightPoint) == "fig1.p2")
    #expect(stage.hitTest(figure: "fig1", at: CGPoint(x: 2, y: 2)) == nil)
    #expect(stage.hover(figure: "fig1", at: rightPoint) == .part("fig1.p2"))
    #expect(stage.hover(figure: "fig1", at: CGPoint(x: 2, y: 2)) == .figure)
    #expect(stage.hover(figure: "fig1", at: CGPoint(x: -20, y: 2)) == .none)

    stage.pointerDown(figure: "fig1", at: leftPoint)
    stage.pointerDragged(figure: "fig1", to: CGPoint(x: leftPoint.x + 1, y: leftPoint.y + 1))
    let click = try #require(stage.pointerUp(figure: "fig1", at: leftPoint))
    #expect(click == FigureClick(figureID: "fig1", partID: "fig1.p1", name: #"the part labelled "left block""#, isLabelled: true))
    #expect(click.question.contains(#"the part labelled "left block""#))
    #expect(scene.highlighted?.id == "fig1.p1")

    // The sphere is named after its variable (`const right = …`).
    stage.pointerDown(figure: "fig1", at: rightPoint)
    #expect(stage.pointerUp(figure: "fig1", at: rightPoint)?.name == "the right")
    #expect(clicks.count == 2)
}

@MainActor
@Test func draggingTurnsTheFigureAndPausesTheTurntable() async throws {
    let clock = FakeClock()
    let (stage, _) = try await stage(#"const f = figure(0, 0, 400, 300, { spin: 6 }); f.box({});"#, clock: clock)
    let scene = try #require(stage.scene("fig1"))
    var clicked = false
    stage.onPartClicked = { _ in clicked = true }
    for _ in 0...10 {
        stage.renderFrame()
        clock.now += 0.1
    }
    let turning = scene.spinAngle
    #expect(abs(turning - 36) < 0.5)  // 6 turns a minute is 36° a second

    stage.pointerDown(figure: "fig1", at: CGPoint(x: 200, y: 150))
    stage.pointerDragged(figure: "fig1", to: CGPoint(x: 240, y: 170))
    #expect(scene.dragYaw < -10)
    #expect(scene.dragTilt > 4)
    #expect(stage.pointerUp(figure: "fig1", at: CGPoint(x: 240, y: 170)) == nil)
    #expect(!clicked)
    // Held still for a moment after the drag, then turning again.
    for _ in 0..<10 {
        clock.now += 0.1
        stage.renderFrame()
    }
    #expect(scene.spinAngle == turning)
    for _ in 0..<40 {
        clock.now += 0.1
        stage.renderFrame()
    }
    #expect(scene.spinAngle > turning + 20)
}

@MainActor
@Test func ticksRunEveryFrameThroughTheProvider() async throws {
    let clock = FakeClock()
    let (stage, harness) = try await stage(#"""
    const f = figure(0, 0, 400, 300);
    const p = f.box({});
    f.tick((t) => { p.at = [t, 0, 0]; f.readout({ t: t.toFixed(1) }); });
    """#, clock: clock)
    let bridge = harness.tickBridge
    var calls = 0
    stage.tickProvider = { figure, ticks, dt in
        calls += 1
        return bridge.runTicks(figure: figure, ticks: ticks, dt: dt)
    }
    stage.readoutProvider = { bridge.takeReadouts() }
    let scene = try #require(stage.scene("fig1"))
    let start = scene.ticks[0].start
    clock.now = start + 1.5
    stage.renderFrame()
    #expect(calls == 1)
    #expect(scene.node("fig1.p1")?.tickPose.position.x == 1.5)
    #expect(scene.readouts.first?.value == "1.5")
}

@MainActor
@Test func removingAFigureDropsItsLayer() async throws {
    let clock = FakeClock()
    let (stage, _) = try await stage(program, clock: clock)
    let parent = CALayer()
    let layer = try #require(stage.layer(forFigure: "fig1"))
    parent.addSublayer(layer)
    stage.removeFigure("fig1")
    #expect(layer.superlayer == nil)
    #expect(stage.layer(forFigure: "fig1") == nil)
    #expect(stage.figureIDs.isEmpty)
}

@MainActor
@Test func stageRendersWhatItShows() async throws {
    let clock = FakeClock()
    let (stage, _) = try await stage(program, clock: clock)
    stage.lookOverride = .illustrated
    clock.now += 3
    stage.renderFrame()
    let image = try #require(try stage.image(figure: "fig1"))
    #expect(image.width == 800 && image.height == 600)
}

@MainActor
@Test func stillFiguresStopDrawing() async throws {
    let clock = FakeClock()
    let (stage, _) = try await stage(#"""
    const f = figure(0, 0, 300, 300, { spin: 0 });
    const a = f.box({});
    const g = figure(0, 0, 300, 300, { spin: 0 });
    const b = g.box({}); b.bob({});
    const h = figure(0, 0, 300, 300, { spin: 0 });
    const c = h.box({}); c.spin({}); c.stop();
    """#, clock: clock)
    stage.renderFrame()
    let figures = try stage.figureIDs.map { try #require(stage.figure($0)) }
    #expect(figures.allSatisfy { stage.isAnimating($0, at: clock.now) })
    clock.now += 30
    #expect(!stage.isAnimating(figures[0], at: clock.now))
    #expect(stage.isAnimating(figures[1], at: clock.now))
    #expect(!stage.isAnimating(figures[2], at: clock.now))
    // A press wakes a still figure.
    stage.pointerDown(figure: "fig1", at: CGPoint(x: 150, y: 150))
    #expect(stage.isAnimating(figures[0], at: clock.now))
}

@MainActor
@Test func meshLoadsDoNotPileUp() async throws {
    // Each part's mesh load is tracked only while it runs, so a long session doesn't keep every finished task.
    let clock = FakeClock()
    let harness = try FigureProgramHarness()
    harness.run(#"const f = figure(0, 0, 300, 300); for (let i = 0; i < 12; i++) f.sphere({ r: 0.1 + i * 0.01 });"#)
    let stage = FigureStage(kernel: FigureKernel(byteBudget: 32 << 20), drivesItself: false, clock: { clock.now })
    for mark in harness.marks where mark.isFigureMark { stage.apply(mark) }
    #expect(stage.pendingLoads == 12)
    let scene = try #require(stage.scene("fig1"))
    // Wait for the meshes without settle(), the way the live app never calls it. The limit is a hang guard: the kernel
    // builds them far more slowly on a busy machine.
    _ = await waitUntil(.seconds(30)) { scene.nodes.allSatisfy { $0.mesh != nil } }
    await Task.yield()
    #expect(scene.nodes.allSatisfy { $0.mesh != nil })
    #expect(stage.pendingLoads == 0)
}

@MainActor
@Test func figuresTooBigForATextureDrawAtALowerScale() async throws {
    // A figure 9000 points wide is 18000 pixels at 2× — over Metal's 16384 limit, which used to crash the app.
    let clock = FakeClock()
    let stage = FigureStage(kernel: FigureKernel(byteBudget: 32 << 20), drivesItself: false, clock: { clock.now })
    stage.apply(DrawingMark(try JSONValue.parse(#"{"id":"fig1","do":"figure","rect":[0,0,9000,400],"look":"studio"}"#)))
    stage.apply(DrawingMark(try JSONValue.parse(
        #"{"id":"fig1.p1","do":"part3d","figure":"fig1","n":1,"kind":"box","recipe":"{}","at":[0,0,0],"rot":[0,0,0],"scale":1,"material":{}}"#)))
    await stage.settle()
    let metal = try #require(stage.layer(forFigure: "fig1")?.sublayers?.first as? CAMetalLayer)
    #expect(metal.drawableSize.width <= FigureRenderer.maxPixelSide && metal.drawableSize.height >= 1)
    clock.now += 3
    stage.renderFrame()
    let image = try #require(try stage.image(figure: "fig1"))
    #expect(CGFloat(image.width) <= FigureRenderer.maxPixelSide)
    #expect(stage.hitTest(figure: "fig1", at: CGPoint(x: 4500, y: 200)) == "fig1.p1")
}

// MARK: - Frame pacing, the studio fallback, shadow caching and half-resolution occlusion

@MainActor
private func drawsPerSecond(_ stage: FigureStage, figure id: String, clock: FakeClock, rate: Double = 120, seconds: Double = 1) throws -> Int {
    let figure = try #require(stage.figure(id))
    let before = figure.drawCount
    for _ in 0..<Int(rate * seconds) {
        clock.now += 1 / rate
        stage.renderFrame()
    }
    return figure.drawCount - before
}

@MainActor
@Test func aTurntableOnlyFigureIsDrawnAtTheLowerRate() async throws {
    let clock = FakeClock()
    let (stage, _) = try await stage(#"const f = figure(0, 0, 300, 300, { spin: 6 }); f.box({ size: [1, 1, 1] });"#, clock: clock)
    stage.renderFrame()
    // Past the grow-in and the framing settle, only the turntable moves.
    clock.now += 10
    stage.renderFrame()
    let figure = try #require(stage.figure("fig1"))
    #expect(stage.demand(figure, at: clock.now) == .turntable)
    #expect(stage.neededFramesPerSecond(at: clock.now) == 30)
    // A 120 Hz display link delivers 120 ticks; the figure is drawn about 30 times.
    let draws = try drawsPerSecond(stage, figure: "fig1", clock: clock)
    #expect((28...31).contains(draws), "\(draws) draws")
}

@MainActor
@Test func movingPartsAreDrawnAtTheFullRateAndStillFiguresNotAtAll() async throws {
    let clock = FakeClock()
    let (moving, _) = try await stage(#"""
    const f = figure(0, 0, 300, 300, { spin: 0 });
    const wheel = f.cylinder({ r: 0.6, h: 0.2 });
    wheel.spin({ axis: "y", rpm: 20 });
    """#, clock: clock)
    clock.now += 10
    moving.renderFrame()
    let figure = try #require(moving.figure("fig1"))
    #expect(moving.demand(figure, at: clock.now) == .moving)
    #expect(moving.neededFramesPerSecond(at: clock.now) == 60)
    let draws = try drawsPerSecond(moving, figure: "fig1", clock: clock, rate: 60)
    #expect(draws >= 59)

    let still = FakeClock()
    let (quiet, _) = try await stage(#"const f = figure(0, 0, 300, 300, { spin: 0 }); f.box({ size: [1, 1, 1] });"#, clock: still)
    still.now += 10
    quiet.renderFrame()
    let figureStill = try #require(quiet.figure("fig1"))
    #expect(quiet.demand(figureStill, at: still.now) == .still)
    #expect(quiet.neededFramesPerSecond(at: still.now) == quiet.settings.idleFramesPerSecond)
    #expect(try drawsPerSecond(quiet, figure: "fig1", clock: still) == 0)
}

@MainActor
@Test func aStudioShaderFailureFallsBackToTheIllustratedLook() async throws {
    let clock = FakeClock()
    let harness = try FigureProgramHarness()
    harness.run(#"const f = figure(0, 0, 300, 300, { tilt: 10, spin: 0 }); f.box({ size: [1, 1, 1] });"#)
    let stage = FigureStage(kernel: FigureKernel(byteBudget: 32 << 20), drivesItself: false, clock: { clock.now })
    var warnings: [String] = []
    stage.onWarning = { warnings.append($0) }
    // Studio shaders that don't compile; the illustrated ones are untouched.
    stage.makeRenderer = { try FigureRenderer(device: $0, studioSource: "this is not Metal") }
    for mark in harness.marks where mark.isFigureMark { stage.apply(mark) }
    await stage.settle()
    #expect(stage.rendererError == nil)
    let renderer = try #require(stage.renderer)
    #expect(!renderer.isStudioAvailable)
    #expect(renderer.studioError != nil)
    #expect(renderer.effectiveLook(.studio) == .illustrated)
    #expect(warnings.contains { $0.contains("illustrated") })
    #expect(stage.scene("fig1")?.look == .studio)
    clock.now += 5
    stage.renderFrame()
    // The studio figure still draws, in ink: dark outline pixels around a lit body.
    let image = try #require(try stage.image(figure: "fig1"))
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var opaque = 0, ink = 0
    for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 200 {
        opaque += 1
        if Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) < 200 { ink += 1 }
    }
    #expect(opaque > 2000)
    #expect(ink > 100)
}

@MainActor
@Test func theShadowMapIsKeptWhileNothingMovesAndOcclusionRunsAtHalfSize() async throws {
    let (scene, _) = try figureScene(#"const f = figure(0, 0, 300, 200, { tilt: 10, spin: 0 }); f.box({ size: [1, 1, 1] }); f.sphere({ r: 0.4, at: [1, 0, 0] });"#)
    let renderer = try FigureRenderer()
    let frame = scene.frame(at: 5, yawOverride: 0)
    _ = try renderer.renderImage(frame, scale: 2)
    _ = try renderer.renderImage(frame, scale: 2)
    _ = try renderer.renderImage(frame, scale: 2)
    #expect(renderer.shadowPasses == 1)
    // The camera (and the light, which turns with it) moved: the map is drawn again.
    _ = try renderer.renderImage(scene.frame(at: 5, yawOverride: 30), scale: 2)
    #expect(renderer.shadowPasses == 2)
    // A 600 × 400 pixel frame computes occlusion on 300 × 200; odd sides round up.
    let even = try #require(renderer.occlusionSize(width: 600, height: 400))
    #expect(even.width == 300 && even.height == 200)
    let odd = try #require(renderer.occlusionSize(width: 601, height: 401))
    #expect(odd.width == 301 && odd.height == 201)
}

@Test func figureLabelsUseTheBundledHandFont() throws {
    let font = FigureLabelLayout.font(size: 18)
    #expect(DrawingFonts.bundled(.patrickHand) != nil)
    #expect((CTFontCopyPostScriptName(font) as String) == "PatrickHand-Regular")
    #expect(FigureLabelLayout.measure("left block", size: 18).width > 40)
}
