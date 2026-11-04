import CoreGraphics
import Foundation
import Testing
import simd
@testable import OpenClickyKit

// FigureScene: the native model built from 3D marks (motions, ticks, framing, camera, labels, click names).

/// Run a program and build its first figure's scene with every mark applied at time 0 and meshes built.
func figureScene(_ program: String, kernel: FigureKernel = .shared, meshes: Bool = true) throws -> (FigureScene, FigureProgramHarness) {
    let harness = try FigureProgramHarness()
    harness.run(program)
    #expect(harness.errors.isEmpty, "\(harness.errors)")
    let figure = try #require(harness.marks.first { $0.kind == "figure" })
    let scene = FigureScene(mark: figure, at: 0)
    for mark in harness.marks where mark.isFigureMark && mark.kind != "figure" {
        if let node = scene.apply(mark, at: 0), meshes, let recipe = node.recipe {
            node.mesh = try kernel.meshNow(kind: node.kind, recipe: recipe)
        }
    }
    return (scene, harness)
}

private func position(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }

private func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-3) -> Bool { simd_distance(a, b) <= tolerance }

@Test func spinTurnsAPartAboutItsOwnCentre() throws {
    let (scene, _) = try figureScene(#"const f = figure(0, 0, 400, 300); const p = f.box({ at: [1, 0, 0] }); p.spin({ axis: "y", period: 4 });"#)
    let node = try #require(scene.node("fig1.p1"))
    let pose = node.localPose(at: 1, includeGrow: false)
    #expect(near(position(pose.matrix), [1, 0, 0]))
    // A quarter turn about +y sends the box's +x axis to −z.
    #expect(near((pose.matrix * SIMD4(1, 0, 0, 0)).xyz, [0, 0, -1]))
}

@Test func orbitBobGlideAndPulseMoveParts() throws {
    let (scene, _) = try figureScene(#"""
    const f = figure(0, 0, 400, 300);
    const moon = f.sphere({ at: [1, 0, 0] }); moon.orbit({ period: 4 });
    const buoy = f.sphere({}); buoy.bob({ amount: 0.1, period: 2 });
    const lift = f.box({}); f.move(lift, { to: [0, 2, 0], secs: 1 });
    const heart = f.sphere({}); heart.pulse({ amount: 0.2, period: 4 });
    """#)
    #expect(near(position(scene.node("fig1.p1")!.localPose(at: 1, includeGrow: false).matrix), [0, 0, -1]))
    #expect(near(position(scene.node("fig1.p2")!.localPose(at: 0.5, includeGrow: false).matrix), [0, 0.1, 0]))
    #expect(near(position(scene.node("fig1.p3")!.localPose(at: 0.5, includeGrow: false).matrix), [0, 1, 0]))
    #expect(near(position(scene.node("fig1.p3")!.localPose(at: 5, includeGrow: false).matrix), [0, 2, 0]))
    let pulse = scene.node("fig1.p4")!.localPose(at: 1, includeGrow: false).matrix
    #expect(abs(simd_length(pulse.columns.0.xyz) - 1.2) < 1e-3)
}

@Test func mirroredCopiesMoveAsMirrorImages() throws {
    let (scene, _) = try figureScene(#"const f = figure(0, 0, 400, 300); const fan = f.box({ at: [1, 0, 0], mirror: "x" }); fan.spin({ axis: "y", period: 4 });"#)
    let original = scene.node("fig1.p1")!.localPose(at: 1, includeGrow: false).matrix
    let mirrored = scene.node("fig1.p2")!.localPose(at: 1, includeGrow: false).matrix
    // The copy's mesh is mirrored in x; with the reflection S, the copy's pose must equal S · pose · S.
    let s = simd_float4x4(diagonal: [-1, 1, 1, 1])
    let expected = s * original * s
    for c in 0..<4 { #expect(simd_distance(mirrored[c], expected[c]) < 1e-4) }
}

@Test func groupsCarryTheirParts() throws {
    let (scene, _) = try figureScene(#"""
    const f = figure(0, 0, 400, 300);
    const arm = f.group({ at: [0, 1, 0], rot: [0, 0, 90] });
    f.box({ at: [1, 0, 0], parent: arm });
    """#)
    let world = scene.worldPoses(at: 1, includeGrow: false)
    // (1, 0, 0) turned 90° about z is (0, 1, 0); plus the group's offset.
    #expect(near(position(world["fig1.p2"]!.matrix), [0, 2, 0]))
}

@Test func partsGrowInWhenTheirTimeComes() throws {
    let harness = try FigureProgramHarness()
    harness.run(#"const f = figure(0, 0, 400, 300); f.box({});"#)
    let scene = FigureScene(mark: harness.marks[0], at: 0)
    let node = try #require(scene.apply(harness.marks[1], at: 2))
    #expect(node.localPose(at: 1, includeGrow: true).matrix.columns.0.x == 0)
    let early = node.localPose(at: 2.1, includeGrow: true).matrix.columns.0.x
    #expect(early > 0 && early < 1)
    #expect(abs(node.localPose(at: 4, includeGrow: true).matrix.columns.0.x - 1) < 1e-4)
}

@Test func tickPosesOverrideMotions() throws {
    let (scene, _) = try figureScene(#"const f = figure(0, 0, 400, 300); const a = f.box({ color: "red" }); a.spin({});"#)
    var floats = [Float](repeating: 0, count: FigureTickPose.floatsPerPose)
    floats[0] = 1
    floats[1] = Float(1 | 2 | 8 | 32)
    floats[2] = 3; floats[3] = 4; floats[4] = 5
    floats[7] = 90
    floats[10] = 0
    floats[11] = Float(0x00FF00)
    scene.applyTickPoses(floats)
    let pose = scene.node("fig1.p1")!.localPose(at: 3, includeGrow: false)
    #expect(near(position(pose.matrix), [3, 4, 5]))
    #expect(near((pose.matrix * SIMD4(1, 0, 0, 0)).xyz, [0, 1, 0]))
    #expect(!pose.shown)
    #expect(near(pose.color, [0, 1, 0]))
    // A hidden part is not drawn.
    #expect(scene.frame(at: 3).items.isEmpty)
}

@Test func framingFitsTheObjectAndCameraLooksAtIt() throws {
    let (scene, _) = try figureScene(#"const f = figure(0, 0, 400, 400, { tilt: 0 }); f.sphere({ r: 1, at: [2, 0, 0] });"#)
    let fit = try #require(scene.framing(at: 1))
    #expect(near(fit.center, [2, 0, 0], 0.01))
    #expect(abs(fit.radius - 1) < 0.02)
    let frame = scene.frame(at: 1, yawOverride: 0, insets: .zero)
    let center = frame.project([2, 0, 0])
    #expect(abs(center.x - 200) < 1 && abs(center.y - 200) < 1)
    let bounds = try #require(frame.objectBounds)
    #expect(bounds.minX > 0 && bounds.maxX < 400 && bounds.width > 150)
    // Room kept for labels on the left moves the object right.
    let shifted = scene.frame(at: 1, yawOverride: 0, insets: FigureInsets(left: 100))
    #expect(abs(shifted.project([2, 0, 0]).x - 250) < 1)
}

@Test func cameraMovesGlide() throws {
    let (scene, _) = try figureScene(#"const f = figure(0, 0, 400, 300, { tilt: 10 }); f.box({}); f.view({ tilt: 50, secs: 2 });"#)
    #expect(scene.camera(at: 0).tilt == 10)
    #expect(abs(scene.camera(at: 1).tilt - 30) < 0.01)
    #expect(scene.camera(at: 3).tilt == 50)
}

@Test func turntableSwaysWhenCutAway() throws {
    let (solid, _) = try figureScene(#"const f = figure(0, 0, 400, 300, { spin: 6 }); f.box({});"#, meshes: false)
    let (cut, _) = try figureScene(#"const f = figure(0, 0, 400, 300, { spin: 6 }); f.box({ cut: true });"#, meshes: false)
    for scene in [solid, cut] {
        var t = 0.0
        while t < 20 { scene.advance(to: t); t += 0.1 }
    }
    // 6 turns a minute for ~20 s is two full turns; a cut-away figure only sways around the front.
    #expect(solid.spinAngle > 700)
    var largest: Float = 0
    for step in 0..<200 { largest = max(largest, abs(cut.yaw(at: Double(step) * 0.1))) }
    #expect(largest < 45)
}

@Test func clicksAreNamedForTheBrain() throws {
    let (scene, _) = try figureScene(#"""
    const f = figure(0, 0, 400, 300);
    const crank = f.group({});
    f.cylinder({ r: 0.6, h: 0.2, parent: crank, mat: "iron" });
    const blade = f.box({ copies: { count: 3, around: "y" } });
    f.gear({ mat: "brass" });
    f.box({});
    f.label(crank, "crankshaft");
    f.label(blade, "fan blade");
    """#)
    #expect(scene.clickName(for: "fig1.p2").name == #"a piece of the part labelled "crankshaft""#)
    #expect(scene.clickName(for: "fig1.p3") == (#"the part labelled "fan blade""#, true))
    #expect(scene.clickName(for: "fig1.p4").name == #"one of the parts labelled "fan blade""#)
    #expect(scene.clickName(for: "fig1.p6") == ("this brass gear", false))
    #expect(scene.clickName(for: "fig1.p7").name == "this block")
    #expect(scene.clickName(for: "fig1.p7", variableName: { $0 == "fig1.p7" ? "lid" : nil }).name == "the lid")
}

@Test func labelsSitBesideTheObjectWithoutOverlapping() throws {
    let (scene, _) = try figureScene(#"""
    const f = figure(0, 0, 520, 400, { tilt: 15 });
    const parts = [];
    for (let i = 0; i < 6; i++) parts.push(f.sphere({ r: 0.25, at: [Math.cos(i) * 1.2, i * 0.15 - 0.4, Math.sin(i) * 1.2] }));
    parts.forEach((p, i) => f.label(p, "part number " + i, { side: i % 2 ? "left" : "right" }));
    f.label([0, 0, 0], "the middle");
    """#)
    let frame = scene.frame(at: 5, yawOverride: 0)
    let placements = FigureLabelLayout.layout(scene.labels, frame: frame, time: 5)
    #expect(placements.count == 7)
    let viewport = CGRect(origin: .zero, size: frame.viewport)
    let object = try #require(frame.objectBounds)
    for (i, p) in placements.enumerated() {
        #expect(viewport.contains(p.box), "\(p.text) at \(p.box)")
        #expect(p.box.maxX <= object.minX + 1 || p.box.minX >= object.maxX - 1, "\(p.text) overlaps the object")
        if i < 6 { #expect(p.side == (i % 2 == 1 ? .left : .right)) }
        for q in placements[(i + 1)...] where q.side == p.side {
            #expect(!p.box.intersects(q.box), "\(p.text) overlaps \(q.text)")
        }
        #expect(p.progress == 1)
    }
}

@Test func pathMotionMovesAtAnEvenSpeed() throws {
    let (scene, _) = try figureScene(#"""
    const f = figure(0, 0, 400, 300);
    const a = f.box({}); a.path([[0, 0, 0], [2, 0, 0], [4, 0, 0]], { once: true, period: 4 });
    const b = f.box({}); b.path([[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]], { period: 8 });
    """#, meshes: false)
    let a = try #require(scene.node("fig1.p1")), b = try #require(scene.node("fig1.p2"))
    #expect(near(position(a.localPose(at: 1, includeGrow: false).matrix), [1, 0, 0], 0.01))
    #expect(near(position(a.localPose(at: 2, includeGrow: false).matrix), [2, 0, 0], 0.01))
    // Once: it stays at the end.
    #expect(near(position(b.localPose(at: 0, includeGrow: false).matrix), [0, 0, 0], 0.01))
    #expect(near(position(a.localPose(at: 9, includeGrow: false).matrix), [4, 0, 0], 0.01))
    // Round and round: back at the start after a full period, passing every corner on the way.
    #expect(near(position(b.localPose(at: 8, includeGrow: false).matrix), [0, 0, 0], 0.01))
    let curve = FigureCurve(points: [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]], closed: true)
    let corners: [SIMD3<Float>] = [[2, 0, 0], [2, 0, 2], [0, 0, 2]]
    for corner in corners {
        let closest = (0...400).map { simd_distance(curve.point(at: Float($0) / 400), corner) }.min()!
        #expect(closest < 0.02)
    }
    // Even speed: equal steps of fraction cover nearly equal distances.
    let steps = (0..<20).map { simd_distance(curve.point(at: Float($0) / 20), curve.point(at: Float($0 + 1) / 20)) }
    #expect(steps.max()! - steps.min()! < 0.05 * curve.length / 20 + 0.01)
}

@Test func glidingAPartMovesItsCopiesWithIt() throws {
    // A row of three copies, mirrored in x: gliding the handle must keep the row and the mirror image, not pile every
    // copy onto the one target point.
    let (scene, harness) = try figureScene(#"""
    const f = figure(0, 0, 400, 300);
    const post = f.box({ size: [0.2, 1, 0.2], at: [1, 0, 0], copies: { count: 3, step: [0, 0, 1] }, mirror: "x" });
    post.glide({ to: [1, 2, 0], rot: [0, 0, 30], secs: 1 });
    """#)
    let ids = (1...6).map { "fig1.p\($0)" }
    let glide = try #require(harness.marks.first { $0.kind == "motion3d" })
    #expect(glide.json["targets"]?.arrayValue?.compactMap(\.stringValue) == ids)
    let ends = ids.map { position(scene.node($0)!.localPose(at: 5, includeGrow: false).matrix) }
    #expect(near(ends[0], [1, 2, 0]) && near(ends[1], [1, 2, 1]) && near(ends[2], [1, 2, 2]))
    #expect(near(ends[3], [-1, 2, 0]) && near(ends[4], [-1, 2, 1]) && near(ends[5], [-1, 2, 2]))
    // The mirrored copies turn the other way: their pose is S · pose · S of the originals.
    let s = simd_float4x4(diagonal: [-1, 1, 1, 1])
    for k in 0..<3 {
        let original = scene.node(ids[k])!.localPose(at: 5, includeGrow: false).matrix
        let mirrored = scene.node(ids[k + 3])!.localPose(at: 5, includeGrow: false).matrix
        let expected = s * original * s
        for c in 0..<4 { #expect(simd_distance(mirrored[c], expected[c]) < 1e-3) }
    }
    // The handle's own part goes exactly where it was told.
    let turned = scene.node(ids[0])!.localPose(at: 5, includeGrow: false).matrix
    #expect(near((turned * SIMD4(1, 0, 0, 0)).xyz, [cos(.pi / 6), sin(.pi / 6), 0]))
}

@Test func tickPosesWithBadNumbersAreSkipped() throws {
    // The packed poses come from program JavaScript; NaN, infinities and huge values must not trap.
    let (scene, _) = try figureScene(#"const f = figure(0, 0, 400, 300); f.box({}); f.box({});"#)
    let good: [Float] = [2, 1, 3, 0, 0, 0, 0, 0, 1, 0, 1, 0]
    let bad: [[Float]] = [
        [.nan, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0],
        [1, .infinity, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0],
        [1e30, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0],
        [1, 1, .nan, 0, 0, 0, 0, 0, 1, 0, 1, 0],
        [1, -1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0],
    ]
    scene.applyTickPoses(bad.flatMap { $0 } + good)
    #expect(scene.node("fig1.p1")?.tickPose.mask == 0)
    #expect(scene.node("fig1.p2")?.tickPose.position == [3, 0, 0])
    scene.applyTickPoses([1, 32, 0, 0, 0, 0, 0, 0, 1, 0, 1, 3e7])
    #expect(scene.node("fig1.p1")?.tickPose.color == FigureColor.linear(FigureColor.srgb(rgb24: 0xFFFFFF)))
}
