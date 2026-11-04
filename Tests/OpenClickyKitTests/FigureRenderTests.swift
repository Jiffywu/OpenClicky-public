import CoreGraphics
import Foundation
import Metal
import Testing
import simd
@testable import OpenClickyKit

// The Metal renderer: both looks, the shadow-only ground, glass, picking through the id buffer, the cut-face bit, and
// the committed evidence renders.

private struct Pixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        rgba = bytes
    }

    /// (r, g, b, a) at a pixel, top-left origin.
    subscript(x: Int, y: Int) -> SIMD4<Int> {
        let o = (y * width + x) * 4
        return SIMD4(Int(rgba[o]), Int(rgba[o + 1]), Int(rgba[o + 2]), Int(rgba[o + 3]))
    }

    func count(where predicate: (SIMD4<Int>) -> Bool) -> Int {
        var n = 0
        for y in 0..<height { for x in 0..<width where predicate(self[x, y]) { n += 1 } }
        return n
    }
}

private let twoBoxes = #"""
const f = figure(0, 0, 400, 300, { tilt: 0, spin: 0 });
f.box({ size: [1, 1, 1], at: [-1, 0, 0], color: "red" });
f.box({ size: [1, 1, 1], at: [1, 0, 0], color: "blue" });
"""#

@Test func pickingFindsThePartUnderAPoint() throws {
    let (scene, _) = try figureScene(twoBoxes)
    let renderer = try FigureRenderer()
    let frame = scene.frame(at: 5, yawOverride: 0)
    let left = frame.project([-1, 0, 0.5]), right = frame.project([1, 0, 0.5])
    #expect(renderer.pick(frame, scale: 2, at: left) == 1)
    #expect(renderer.pick(frame, scale: 2, at: right) == 2)
    #expect(renderer.pick(frame, scale: 2, at: CGPoint(x: 3, y: 3)) == 0)
    #expect(renderer.pick(frame, scale: 2, at: CGPoint(x: -5, y: 900)) == 0)
    // Turned half way round, the boxes swap sides.
    let back = scene.frame(at: 5, yawOverride: 180)
    #expect(renderer.pick(back, scale: 2, at: left) == 2)
    let grid = renderer.idGrid(frame, scale: 1)
    #expect(grid.width == 400 && grid.height == 300)
    #expect(Set(grid.ids) == [0, 1, 2])
}

@Test func cutFacesSetTheHighBitOfTheirId() throws {
    let (scene, _) = try figureScene(#"const f = figure(0, 0, 300, 300, { tilt: 0, spin: 0 }); f.sphere({ r: 1, cut: true, mat: "steel" });"#)
    let renderer = try FigureRenderer()
    let frame = scene.frame(at: 5, yawOverride: 0)
    let grid = renderer.idGrid(frame, scale: 1)
    let center = grid.ids[150 * grid.width + 150]
    // The near half is cut away, so the middle shows the inside of the far half: the cut face.
    #expect(center == 0x8000_0001)
    #expect(renderer.pick(frame, scale: 1, at: CGPoint(x: 150, y: 150)) == 1)
    // Seen from the side, the outside of the remaining half is ordinary surface.
    let side = scene.frame(at: 5, yawOverride: 90)
    let sideGrid = renderer.idGrid(side, scale: 1)
    let rim = side.project([0, 0, -0.9])
    #expect(sideGrid.ids[Int(rim.y) * sideGrid.width + Int(rim.x)] == 1)
}

@Test(arguments: FigureLook.allCases)
func bothLooksDrawTheFigure(look: FigureLook) throws {
    let (scene, _) = try figureScene(twoBoxes)
    scene.setLook(look)
    let renderer = try FigureRenderer()
    let frame = scene.frame(at: 5, yawOverride: 30)
    let pixels = Pixels(try renderer.renderImage(frame, scale: 1))
    let covered = pixels.count { $0.w > 250 }
    #expect(covered > 4000)
    // The red box is reddish where it shows.
    let left = frame.project([-1, 0, 0.5])
    let red = pixels[Int(left.x), Int(left.y)]
    #expect(red.x > red.z + 40)
    if look == .illustrated {
        // Ink outline: near-black pixels in the ink colour around the silhouette.
        let ink = pixels.count { $0.w > 200 && $0.x < 90 && $0.y < 90 && $0.z < 100 }
        #expect(ink > 300)
    }
}

@Test func studioGroundShowsOnlyTheShadow() throws {
    let (scene, _) = try figureScene(#"const f = figure(0, 0, 400, 400, { tilt: 30, spin: 0 }); f.sphere({ r: 1, at: [0, 1.2, 0], mat: "plastic" });"#)
    let renderer = try FigureRenderer()
    let frame = scene.frame(at: 5, yawOverride: 0)
    let pixels = Pixels(try renderer.renderImage(frame, scale: 1))
    // Under the ball: a soft, see-through, dark shadow; away from it the ground is fully transparent.
    let below = frame.project([0, frame.groundY, 0.4])
    let shadow = pixels[Int(below.x), Int(below.y)]
    #expect(shadow.w > 10 && shadow.w < 200)
    #expect(shadow.x < 60)
    #expect(pixels[2, 398].w == 0 && pixels[398, 2].w == 0)
}

@Test func glassIsSeeThrough() throws {
    let (scene, _) = try figureScene(#"const f = figure(0, 0, 300, 300, { tilt: 0, spin: 0 }); f.sphere({ r: 1, mat: "glass" });"#)
    let renderer = try FigureRenderer()
    let frame = scene.frame(at: 5, yawOverride: 0)
    let pixels = Pixels(try renderer.renderImage(frame, scale: 1))
    let middle = pixels[150, 150]
    #expect(middle.w > 0 && middle.w < 200)
}

@Test func shadersCompileFromResourceSource() throws {
    let source = try FigureRenderer.shaderSource()
    let device = try #require(MTLCreateSystemDefaultDevice())
    let library = try device.makeLibrary(source: source, options: nil)
    let functions = Set(library.functionNames)
    for function in ["fig_vertex", "fig_fullscreen_vertex", "fig_studio_fragment", "fig_studio_cut_fragment", "fig_toon_fragment",
                     "fig_toon_cut_fragment", "fig_id_fragment", "fig_id_cut_fragment", "fig_outline_fragment",
                     "fig_shadow_vertex", "fig_shadow_fragment", "fig_normal_depth_fragment", "fig_ao_fragment",
                     "fig_ao_blur_fragment", "fig_ground_vertex", "fig_ground_fragment", "fig_env_bake", "fig_env_prefilter",
                     "fig_env_irradiance"] {
        #expect(functions.contains(function), "missing \(function)")
    }
}

// MARK: - Evidence

/// Tests/Fixtures/Drawing/3d, found from this file's path.
private let evidenceDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/Fixtures/Drawing/3d")

// One program at a time: each builds its own kernel and renders both looks, blocking its thread throughout (see
// FigureKernelTests).
@Suite(.serialized) struct FigureEvidenceRenders {
    /// Renders the fixture programs in both looks. OPENCLICKY_WRITE_EVIDENCE=1 writes local PNGs under .build/evidence.
    @Test(arguments: ["gyroscope", "piston-engine", "molecule", "gear-train"])
    func evidenceProgramsRenderInBothLooks(name: String) throws {
        let program = try String(contentsOf: evidenceDirectory.appendingPathComponent("\(name).js"), encoding: .utf8)
        let harness = try FigureProgramHarness()
        let marks = harness.run(program)
        #expect(harness.errors.isEmpty, "\(harness.errors)")
        #expect(harness.warnings.isEmpty, "\(harness.warnings)")
        let bridge = harness.tickBridge
        let renderer = try FigureRenderer()
        for look in FigureLook.allCases {
            var options = FigureSnapshot.Options()
            options.look = look
            let result = try FigureSnapshot.render(
                marks: marks, options: options, renderer: renderer,
                tick: { bridge.runTicks(figure: $0, ticks: $1, dt: $2) }, readouts: { bridge.takeReadouts() })
            #expect(result.failures.isEmpty, "\(result.failures)")
            let parts = result.scene.nodes.filter { !$0.isGroup }
            #expect(parts.allSatisfy { $0.mesh != nil })
            #expect(result.frame.items.count == parts.count)
            let pixels = Pixels(result.image)
            // The figure covers a good share of the picture and differs from the paper.
            let paper = SIMD4(247, 244, 237, 255)
            let drawn = pixels.count { simd_reduce_max(simd_abs($0 &- paper)) > 24 }
            #expect(Double(drawn) / Double(pixels.width * pixels.height) > 0.06, "\(name) \(look): \(drawn) pixels")
            if ProcessInfo.processInfo.environment["OPENCLICKY_WRITE_EVIDENCE"] == "1", let png = FigureSnapshot.pngData(result.image) {
                let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent(".build/evidence/figures", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent("\(name)-\(look.rawValue).png"))
            }
        }
    }
}

@Test func shaderWarmUpCompilesInTheBackground() async throws {
    let error: (any Error)? = await withCheckedContinuation { continuation in
        FigureRenderer.warmUpShaders { continuation.resume(returning: $0) }
    }
    #expect(error == nil)
}

@Test func hugeViewportsRenderAtALowerScaleAndStillPick() throws {
    let (scene, _) = try figureScene(twoBoxes)
    let renderer = try FigureRenderer()
    let frame = scene.frame(at: 5, viewport: CGSize(width: 20000, height: 300), yawOverride: 0)
    let size = FigureRenderer.pixelSize(frame, scale: 2)
    #expect(size.width == 8192 && size.height == 123)
    let image = try renderer.renderImage(frame, scale: 2)
    #expect(image.width == 8192)
    #expect(renderer.pick(frame, scale: 2, at: frame.project([-1, 0, 0.5])) == 1)
    #expect(renderer.pick(frame, scale: 2, at: frame.project([1, 0, 0.5])) == 2)
    #expect(renderer.pick(frame, scale: 2, at: CGPoint(x: CGFloat.nan, y: 10)) == 0)
}
