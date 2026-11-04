import Foundation
import JavaScriptCore
import Testing
import simd
@testable import OpenClickyKit

// The geometry kernel: recipe -> mesh, for every part kind (docs/dsl-3d.md §2), plus its cache and limits.

private func build(_ kind: String, _ recipe: String, kernel: FigureKernel = FigureKernel(byteBudget: 64 << 20)) throws -> FigureMesh {
    try kernel.meshNow(kind: kind, recipe: recipe)
}

private func expectBounds(_ mesh: FigureMesh, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>, tolerance: Float = 1e-3,
                          sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(simd_reduce_max(simd_abs(mesh.boundsMin - lo)) <= tolerance, "min \(mesh.boundsMin) vs \(lo)", sourceLocation: sourceLocation)
    #expect(simd_reduce_max(simd_abs(mesh.boundsMax - hi)) <= tolerance, "max \(mesh.boundsMax) vs \(hi)", sourceLocation: sourceLocation)
}

/// Every mesh must be well formed: indices in range, unit normals, faces wound the way they are shaded, samples on it.
private func expectWellFormed(_ mesh: FigureMesh, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(mesh.indices.count % 3 == 0, sourceLocation: sourceLocation)
    #expect(mesh.indices.allSatisfy { Int($0) < mesh.vertexCount }, sourceLocation: sourceLocation)
    let badNormals = (0..<mesh.vertexCount).filter { abs(simd_length(mesh.normal($0)) - 1) > 1e-3 }.count
    #expect(badNormals == 0, "\(badNormals) normals are not unit length", sourceLocation: sourceLocation)
    #expect(mesh.windingAgreement() > 0.999, "winding agrees on \(mesh.windingAgreement())", sourceLocation: sourceLocation)
    #expect(!mesh.samples.isEmpty && mesh.samples.count <= 512, sourceLocation: sourceLocation)
    for sample in mesh.samples {
        #expect(all(sample .>= mesh.boundsMin - 1e-4) && all(sample .<= mesh.boundsMax + 1e-4), sourceLocation: sourceLocation)
    }
}

// The kernel tests run one at a time. Each builds a JavaScriptCore kernel of its own and blocks its thread until the
// mesh is done; dozens at once held every thread of the shared pool that async tests run on, for seconds on a busy
// machine, so unrelated tests elsewhere in the suite ran out of time waiting for one.
@Suite(.serialized) struct FigureKernelTests {
    @Test func kernelBuildsEveryKind() throws {
        let kinds = try FigureKernel(byteBudget: 1 << 20).kinds()
        #expect(Set(kinds) == ["box", "cylinder", "cone", "tube", "lathe", "sphere", "torus", "capsule", "pipe", "spring",
                               "gear", "extrude", "blob", "poly", "arrow", "surface"])
    }

    // Surfaces of revolution have exact counts: one row of seg+1 vertices per profile point (two at a sharp corner),
    // two triangles per quad, and none where a row sits on the axis.
    @Test(arguments: [
        // kind, recipe, vertices, indices, bounds min, bounds max
        ("box", #"{"size":[2,1,0.5]}"#, 24, 36, SIMD3<Float>(-1, -0.5, -0.25), SIMD3<Float>(1, 0.5, 0.25)),
        ("cylinder", #"{"r":0.5,"h":2,"seg":32}"#, 6 * 33, 128 * 3, SIMD3<Float>(-0.5, -1, -0.5), SIMD3<Float>(0.5, 1, 0.5)),
        ("cone", #"{"r":0.5,"h":1,"seg":24}"#, 4 * 25, 48 * 3, SIMD3<Float>(-0.5, -0.5, -0.5), SIMD3<Float>(0.5, 0.5, 0.5)),
        ("tube", #"{"r":1,"inner":0.6,"h":0.5,"seg":40}"#, 8 * 41, 4 * 40 * 6, SIMD3<Float>(-1, -0.25, -1), SIMD3<Float>(1, 0.25, 1)),
        ("lathe", #"{"profile":[[0,0],[1,0],[0.5,1],[0,1]],"seg":16}"#, 6 * 17, 64 * 3, SIMD3<Float>(-1, 0, -1), SIMD3<Float>(1, 1, 1)),
        ("sphere", #"{"r":0.5,"seg":32}"#, 17 * 33, (16 * 32 * 2 - 2 * 32) * 3, SIMD3<Float>(repeating: -0.5), SIMD3<Float>(repeating: 0.5)),
        ("torus", #"{"r":1,"tube":0.2,"seg":36,"tubeSeg":12}"#, 13 * 37, 12 * 36 * 6, SIMD3<Float>(-1.2, -0.2, -1.2), SIMD3<Float>(1.2, 0.2, 1.2)),
        ("capsule", #"{"r":0.3,"h":1,"seg":16}"#, 18 * 17, (17 * 16 * 2 - 2 * 16) * 3, SIMD3<Float>(-0.3, -0.8, -0.3), SIMD3<Float>(0.3, 0.8, 0.3)),
        ("poly", #"{"faces":8,"r":1}"#, 24, 24, SIMD3<Float>(repeating: -1), SIMD3<Float>(repeating: 1)),
        ("extrude", #"{"shape":[[0,0],[1,0],[1,1],[0,1]],"depth":0.4,"round":false}"#, 24, 36, SIMD3<Float>(0, 0, -0.2), SIMD3<Float>(1, 1, 0.2)),
    ] as [(String, String, Int, Int, SIMD3<Float>, SIMD3<Float>)])
    func exactCountsAndBounds(kind: String, recipe: String, vertices: Int, indices: Int, lo: SIMD3<Float>, hi: SIMD3<Float>) throws {
        let mesh = try build(kind, recipe)
        #expect(mesh.vertexCount == vertices)
        #expect(mesh.indices.count == indices)
        expectBounds(mesh, lo, hi)
        expectWellFormed(mesh)
    }

    // Swept and generated shapes: bounds follow from the recipe; counts are checked against the per-kind limits.
    @Test(arguments: [
        ("box", #"{"size":[2,1,0.5],"round":0.1}"#, SIMD3<Float>(-1, -0.5, -0.25), SIMD3<Float>(1, 0.5, 0.25), Float(1e-3)),
        ("cylinder", #"{"r":0.5,"h":2,"round":0.05}"#, SIMD3<Float>(-0.5, -1, -0.5), SIMD3<Float>(0.5, 1, 0.5), Float(1e-3)),
        // An elbowed pipe starts with a flat cap at x = 0 and ends with one at y = 1.
        ("pipe", #"{"points":[[0,0,0],[1,0,0],[1,1,0]],"r":0.1,"smooth":false}"#, SIMD3<Float>(0, -0.1, -0.1), SIMD3<Float>(1.1, 1, 0.1), Float(2e-3)),
        ("spring", #"{"r":0.4,"h":1.5,"turns":4,"wire":0.05}"#, SIMD3<Float>(-0.45, -0.8, -0.45), SIMD3<Float>(0.45, 0.8, 0.45), Float(5e-3)),
        // Tooth tips reach r + depth/2; the face is `width` thick, centred on z = 0.
        ("gear", #"{"teeth":12,"r":1,"depth":0.2,"width":0.3}"#, SIMD3<Float>(-1.1, -1.1, -0.15), SIMD3<Float>(1.1, 1.1, 0.15), Float(6e-3)),
        ("extrude", #"{"path":"M0 0 H100 V50 H0 Z","unit":0.01,"depth":0.2}"#, SIMD3<Float>(-0.5, -0.25, -0.1), SIMD3<Float>(0.5, 0.25, 0.1), Float(1e-3)),
        ("extrude", #"{"path":"M0 0 A50 50 0 1 0 100 0 A50 50 0 1 0 0 0 Z","depth":0.1}"#, SIMD3<Float>(-0.5, -0.5, -0.05), SIMD3<Float>(0.5, 0.5, 0.05), Float(4e-3)),
        ("blob", #"{"balls":[[0,0,0,0.5],[0.8,0,0,0.4]]}"#, SIMD3<Float>(-0.5, -0.5, -0.5), SIMD3<Float>(1.2, 0.5, 0.5), Float(0.02)),
        ("blob", #"{"sticks":[[0,-1,0,0,1,0,0.3,0.1]]}"#, SIMD3<Float>(-0.3, -1.3, -0.3), SIMD3<Float>(0.3, 1.1, 0.3), Float(0.03)),
        ("arrow", #"{"points":[[0,0,0],[2,0,0]],"r":0.05}"#, SIMD3<Float>(-0.05, -0.125, -0.125), SIMD3<Float>(2, 0.125, 0.125), Float(1e-3)),
        ("cylinder", #"{"r":0.5,"h":1,"arc":180}"#, SIMD3<Float>(0, -0.5, -0.5), SIMD3<Float>(0.5, 0.5, 0.5), Float(1e-3)),
        ("cylinder", #"{"r":0.25,"h":2,"axis":"x"}"#, SIMD3<Float>(-1, -0.25, -0.25), SIMD3<Float>(1, 0.25, 0.25), Float(1e-3)),
        ("cylinder", #"{"r":0.25,"h":2,"axis":[0,0,-1]}"#, SIMD3<Float>(-0.25, -0.25, -1), SIMD3<Float>(0.25, 0.25, 1), Float(1e-3)),
        ("sphere", #"{"r":1,"stretch":[2,1,0.5]}"#, SIMD3<Float>(-2, -1, -0.5), SIMD3<Float>(2, 1, 0.5), Float(1e-3)),
        ("sphere", #"{"r":1,"dome":true}"#, SIMD3<Float>(-1, 0, -1), SIMD3<Float>(1, 1, 1), Float(1e-3)),
    ] as [(String, String, SIMD3<Float>, SIMD3<Float>, Float)])
    func sweptShapeBounds(kind: String, recipe: String, lo: SIMD3<Float>, hi: SIMD3<Float>, tolerance: Float) throws {
        let mesh = try build(kind, recipe)
        #expect(mesh.vertexCount > 8 && mesh.vertexCount <= 150_000)
        expectBounds(mesh, lo, hi, tolerance: tolerance)
        expectWellFormed(mesh)
    }

    @Test func lumpyBlobStaysNearItsRadiusAndDependsOnSeed() throws {
        let a = try build("blob", #"{"r":1,"seed":3}"#)
        let b = try build("blob", #"{"r":1,"seed":4}"#)
        for mesh in [a, b] {
            let extent = (mesh.boundsMax - mesh.boundsMin) / 2
            #expect(simd_reduce_min(extent) > 0.85 && simd_reduce_max(extent) < 1.2)
            expectWellFormed(mesh)
        }
        #expect(a.vertices != b.vertices)
    }

    @Test func thickTurnsASurfaceIntoAShell() throws {
        let cup = #"{"profile":[[0,0],[0.5,0],[0.6,1]],"seg":24}"#
        let thin = try build("lathe", cup)
        let shell = try build("lathe", #"{"profile":[[0,0],[0.5,0],[0.6,1]],"seg":24,"thick":0.05}"#)
        // An inner copy plus a rim strip: more than twice the triangles, same outside.
        #expect(shell.triangleCount > 2 * thin.triangleCount)
        // The inner copy sits inside, except where a slanted open rim leans out by up to the thickness.
        expectBounds(shell, thin.boundsMin, thin.boundsMax, tolerance: 0.05)
        #expect(shell.windingAgreement() > 0.999)
    }

    @Test func roundedEdgesStayInsideTheSharpShape() throws {
        let sharp = try build("tube", #"{"r":1,"inner":0.7,"h":0.6}"#)
        let round = try build("tube", #"{"r":1,"inner":0.7,"h":0.6,"round":0.1}"#)
        expectBounds(round, sharp.boundsMin, sharp.boundsMax, tolerance: 1e-3)
        #expect(round.vertexCount > sharp.vertexCount)
        // No vertex of the filleted ring pokes outside the outer radius or inside the bore.
        for i in 0..<round.vertexCount {
            let p = round.position(i)
            let radius = simd_length(SIMD2(p.x, p.z))
            #expect(radius <= 1.0001 && radius >= 0.6999)
        }
    }

    // MARK: - Mirrors

    @Test(arguments: [
        ("box", #"{"size":[2,1,0.5]}"#),
        ("lathe", #"{"profile":[[0,0],[1,0],[0.2,1.5]]}"#),
        ("gear", #"{"teeth":9,"r":1}"#),
        ("extrude", #"{"shape":[[0,0],[2,0],[0,1]],"depth":0.3}"#),
        ("arrow", #"{"points":[[0,0,0],[1,0.5,0],[2,0,0.4]]}"#),
    ] as [(String, String)])
    func mirroredMeshesReflectAndKeepTheirWinding(kind: String, recipe: String) throws {
        let kernel = FigureKernel(byteBudget: 64 << 20)
        let plain = try kernel.meshNow(kind: kind, recipe: recipe)
        for signs in [SIMD3<Float>(-1, 1, 1), SIMD3<Float>(1, -1, 1), SIMD3<Float>(-1, -1, 1), SIMD3<Float>(-1, -1, -1)] {
            var json = try JSONValue.parse(recipe).objectValue!
            json["mirror"] = .array([.number(Double(signs.x)), .number(Double(signs.y)), .number(Double(signs.z))])
            let mirrored = try kernel.meshNow(kind: kind, recipe: JSONValue.object(json).jsonString())
            #expect(mirrored.vertexCount == plain.vertexCount)
            // Every vertex is the reflection of the original one, and so is every normal.
            for i in stride(from: 0, to: plain.vertexCount, by: max(1, plain.vertexCount / 64)) {
                #expect(simd_distance(mirrored.position(i), plain.position(i) * signs) < 1e-5)
                #expect(simd_distance(mirrored.normal(i), plain.normal(i) * signs) < 1e-4)
            }
            let flipped = signs.x * signs.y * signs.z < 0
            // An odd number of reflections turns faces inside out unless the kernel rewinds them; it must.
            #expect(mirrored.windingAgreement() > 0.999)
            if flipped {
                let a = Int(plain.indices[0]), b = Int(plain.indices[1]), c = Int(plain.indices[2])
                #expect(Array(mirrored.indices[0...2]) == [UInt32(a), UInt32(c), UInt32(b)])
            } else {
                #expect(mirrored.indices == plain.indices)
            }
            expectBounds(mirrored, simd_min(plain.boundsMin * signs, plain.boundsMax * signs),
                         simd_max(plain.boundsMin * signs, plain.boundsMax * signs), tolerance: 1e-5)
        }
    }

    @Test func mirroredConvexMeshFacesOutward() throws {
        let kernel = FigureKernel(byteBudget: 16 << 20)
        for recipe in [#"{"size":[1,2,3],"mirror":[-1,1,1]}"#, #"{"size":[1,2,3],"stretch":[-1,1,1]}"#] {
            let box = try kernel.meshNow(kind: "box", recipe: recipe)
            #expect(box.outwardFraction() == 1)
        }
        let sphere = try kernel.meshNow(kind: "sphere", recipe: #"{"r":1,"mirror":[1,-1,1]}"#)
        #expect(sphere.outwardFraction() > 0.999)
    }

    // MARK: - Cache

    @Test func cacheIsKeyedByCanonicalRecipe() throws {
        let kernel = FigureKernel(byteBudget: 16 << 20)
        let a = try kernel.meshNow(kind: "cylinder", recipe: #"{"r":0.5,"h":2}"#)
        let b = try kernel.meshNow(kind: "cylinder", recipe: #"{ "h": 2, "r": 0.5 }"#)
        #expect(a === b)
        _ = try kernel.meshNow(kind: "cone", recipe: #"{"r":0.5,"h":2}"#)
        let stats = kernel.currentStats
        #expect(stats.builds == 2)
        #expect(stats.hits == 1)
        #expect(stats.cachedMeshes == 2)
        #expect(FigureKernel.key(kind: "box", recipe: #"{"b":1,"a":[1,2]}"#) == FigureKernel.key(kind: "box", recipe: #"{"a":[1,2],"b":1}"#))
    }

    @Test func identicalRequestsInFlightBuildOnce() async throws {
        let kernel = FigureKernel(byteBudget: 16 << 20)
        let recipe = #"{"teeth":40,"r":2}"#
        let meshes = try await withThrowingTaskGroup(of: FigureMesh.self) { group in
            for _ in 0..<20 { group.addTask { try await kernel.mesh(kind: "gear", recipe: recipe) } }
            return try await group.reduce(into: [FigureMesh]()) { $0.append($1) }
        }
        #expect(meshes.count == 20)
        #expect(meshes.allSatisfy { $0 === meshes[0] })
        #expect(kernel.currentStats.builds == 1)
    }

    @Test func failedRecipesAreNotRetried() throws {
        let kernel = FigureKernel(byteBudget: 16 << 20)
        #expect(throws: FigureKernelError.self) { try kernel.meshNow(kind: "teapot", recipe: "{}") }
        #expect(throws: FigureKernelError.self) { try kernel.meshNow(kind: "teapot", recipe: "{}") }
        #expect(kernel.currentStats.failures == 1)
        do {
            _ = try kernel.meshNow(kind: "teapot", recipe: "{}")
        } catch let error as FigureKernelError {
            #expect(error.description.contains("unknown 3D part \"teapot\""))
        }
    }

    @Test func cacheEvictsLeastRecentlyUsedPastItsBudget() throws {
        let probe = try FigureKernel(byteBudget: 64 << 20).meshNow(kind: "sphere", recipe: #"{"r":1}"#)
        // Room for about two of these meshes.
        let kernel = FigureKernel(byteBudget: probe.byteSize * 2 + 100)
        _ = try kernel.meshNow(kind: "sphere", recipe: #"{"r":1}"#)
        _ = try kernel.meshNow(kind: "sphere", recipe: #"{"r":2}"#)
        _ = kernel.cachedMesh(kind: "sphere", recipe: #"{"r":1}"#)  // r = 1 is now the most recent
        _ = try kernel.meshNow(kind: "sphere", recipe: #"{"r":3}"#)
        #expect(kernel.cachedMesh(kind: "sphere", recipe: #"{"r":1}"#) != nil)
        #expect(kernel.cachedMesh(kind: "sphere", recipe: #"{"r":2}"#) == nil)
        #expect(kernel.currentStats.cachedBytes <= probe.byteSize * 2 + 100)
    }

    // MARK: - Limits

    @Test func runawayRecipesHitTheVertexCap() throws {
        // A 400-point zigzag profile has a hard corner at every point; as a 128-segment shell it is far too detailed.
        let zigzag = (0..<400).map { "[\($0 % 2 == 0 ? 1 : 0.6),\(Double($0) * 0.01)]" }.joined(separator: ",")
        let recipe = #"{"profile":[\#(zigzag)],"seg":128,"thick":0.01}"#
        do {
            _ = try build("lathe", recipe)
            Issue.record("expected the vertex cap")
        } catch let error as FigureKernelError {
            #expect(error.description.contains("at most 150000 vertices"))
        }
    }

    @Test func blobsOfManyPrimitivesGetACoarserGrid() throws {
        // Every grid sample measures every primitive: 64 balls and 64 sticks on the finest grid (72 cells) used to take
        // about 4 s with the JIT and two minutes without it, holding up every other part on the kernel's queue.
        let balls = (0..<64).map { i in "[\(sin(Double(i)) * 2),\(cos(Double(i) * 1.3) * 2),\(sin(Double(i) * 0.7) * 2),0.4]" }
        let sticks = (0..<64).map { i in "[0,0,0,\(sin(Double(i)) * 2),\(cos(Double(i)) * 2),1,0.2,0.1]" }
        let recipe = #"{"balls":[\#(balls.joined(separator: ","))],"sticks":[\#(sticks.joined(separator: ","))],"res":72}"#
        let mesh = try build("blob", recipe)
        // On the full 72-cell grid this blob has 41 027 vertices; the budget brings it to about 20 cells.
        #expect(mesh.vertexCount < 8000)
        expectWellFormed(mesh)
        // A small blob keeps the grid it asked for.
        let small = try build("blob", #"{"balls":[[0,0,0,0.5],[0.8,0,0,0.4]],"res":72}"#)
        #expect(small.vertexCount > 6000)
    }

    @Test func extrudedOutlinesAreBoundedBeforeTriangulating() throws {
        // Holes of 2000 points each passed the per-list caps (up to 64 of them); triangulating that many outline points
        // could run for minutes on the kernel's only queue.
        let ring = (0..<2000).map { i in "[\(cos(Double(i)) * 0.001),\(sin(Double(i)) * 0.001)]" }.joined(separator: ",")
        let holes = (0..<16).map { _ in "[" + ring + "]" }.joined(separator: ",")
        let square = "[[-1,-1],[1,-1],[1,1],[-1,1]]"
        do {
            _ = try build("extrude", #"{"shape":\#(square),"holes":[\#(holes)]}"#)
            Issue.record("expected the outline limit")
        } catch let error as FigureKernelError {
            #expect(error.description.contains("at most 3000 points"))
        }
        // A path of many curves (a circle scalloped by 400 small arcs, 800 Béziers) gets fewer points per curve instead
        // of failing: at 12 per curve its outline would be 9600 points.
        let corner = { (i: Int) in String(format: "%.3f %.3f", 100 * cos(Double(i) * .pi / 200), 100 * sin(Double(i) * .pi / 200)) }
        let arcs = (1...400).map { "A1 1 0 0 0 \(corner($0 % 400))" }.joined(separator: " ")
        let scalloped = try build("extrude", #"{"path":"M\#(corner(0)) \#(arcs) Z","depth":0.2,"round":false}"#)
        #expect(scalloped.vertexCount > 4000 && scalloped.vertexCount < 4 * 3000)
    }

    @Test func pointListsAndCountsAreClamped() throws {
        // 1000 points become 200; 500 teeth become 200; absurd sizes stay finite.
        let points = (0..<1000).map { "[\(Double($0) * 0.01),0,0]" }.joined(separator: ",")
        let pipe = try build("pipe", #"{"points":[\#(points)],"r":0.01}"#)
        #expect(pipe.boundsMax.x < 2.0 + 0.02)
        let gear = try build("gear", #"{"teeth":500,"r":1}"#)
        #expect(gear.vertexCount < 150_000)
        let huge = try build("box", #"{"size":[1e9,-5,2]}"#)
        #expect(huge.boundsMax.x <= 5000.01 && huge.boundsMax.y == 2.5)
    }

    // Counts for the swept and generated kinds. Spring and gear follow from the recipe: a 4-turn spring is a tube of
    // 160 segments × 10 sides ((161 × 11) vertices) with two capped ends; a 12-tooth gear has 60 outline corners, 48
    // sharp (two columns each) and 12 smooth, each column a ring of 6 bevel vertices, plus 60 vertices on each face.
    // The rest are pinned so a change in a builder shows up here.
    @Test(arguments: [
        ("spring", #"{"r":0.4,"h":1.5,"turns":4,"wire":0.05}"#, 161 * 11 + 2 * 12, 160 * 10 * 6 + 2 * 10 * 3),
        ("gear", #"{"teeth":12,"r":1,"depth":0.2,"width":0.3}"#, (48 * 2 + 12) * 6 + 2 * 60, 60 * 5 * 6 + 2 * 58 * 3),
        ("pipe", #"{"points":[[0,0,0],[1,0,0],[1,1,0]],"r":0.1,"seg":8}"#, 677, 3504),
        ("arrow", #"{"points":[[0,0,0],[2,0,0]],"r":0.05}"#, 1269, 6408),
        ("extrude", #"{"path":"M0 0 H100 V50 H0 Z","unit":0.01,"depth":0.2}"#, 56, 132),
        ("blob", #"{"balls":[[0,0,0,0.5],[0.8,0,0,0.4]]}"#, 2832, 16980),
        ("blob", #"{"r":1,"seed":3}"#, 1212, 7260),
        ("box", #"{"size":[2,1,0.5],"round":0.1}"#, 380, 1764),
        ("cylinder", #"{"r":0.5,"h":2,"seg":32,"round":0.05}"#, 528, 2688),
    ] as [(String, String, Int, Int)])
    func sweptAndGeneratedCounts(kind: String, recipe: String, vertices: Int, indices: Int) throws {
        let mesh = try build(kind, recipe)
        #expect(mesh.vertexCount == vertices)
        #expect(mesh.indices.count == indices)
    }

    @Test func surfacesAreGridsWithHoles() throws {
        // A 9 × 5 grid of a gentle wave: 45 vertices, 8 × 4 cells of two triangles.
        let rows = (0...4).map { j in
            "[" + (0...8).map { i in "[\(Double(i) / 4 - 1),\(sin(Double(i) / 8 * 3) * 0.2),\(Double(j) / 2 - 1)]" }.joined(separator: ",") + "]"
        }
        let wave = try build("surface", #"{"grid":["# + rows.joined(separator: ",") + "]}")
        #expect(wave.vertexCount == 45 && wave.indices.count == 8 * 4 * 6)
        expectBounds(wave, [-1, 0, -1], [1, 0.2, 1], tolerance: 2e-3)
        #expect(wave.windingAgreement() > 0.999)
        // A missing sample (null) drops every triangle that touches it: cells split corner to corner keep only the two
        // triangles whose diagonal avoids the centre.
        let holed = try build("surface", #"{"grid":[[[0,0,0],[1,0,0],[2,0,0]],[[0,0,1],null,[2,0,1]],[[0,0,2],[1,0,2],[2,0,2]]]}"#)
        #expect(holed.vertexCount == 8)
        #expect(holed.indices.count == 2 * 3)
    }

    @Test func typedArraysAreReadFromTheirOwnOffset() throws {
        // JavaScriptCore hands back the start of the whole buffer; a subarray view starts byteOffset bytes in.
        let context = try #require(JSContext())
        let floats = context.evaluateScript("new Float32Array([1, 2, 3, 4, 5, 6]).subarray(3)")
        #expect(FigureKernel.floats(floats, in: context) == [4, 5, 6])
        let uints = context.evaluateScript("new Uint32Array([7, 8, 9, 10]).subarray(1, 3)")
        #expect(FigureKernel.uints(uints, in: context) == [8, 9])
    }
}

/// A figure program prewarms the kernel as its parts parse (`__host.shape3d`), so the meshes are in the LRU before the
/// stage asks for them when their lines are heard.
@MainActor
@Test func prewarmFillsTheCacheBeforeTheStageAsks() async throws {
    let kernel = FigureKernel(byteBudget: 64 << 20)
    let engine = try DrawingEngineHost(prewarmShape: { kind, recipe in kernel.prewarm(kind: kind, recipe: recipe) })
    var events = engine.perform(.begin(DrawingBeginOptions(width: 1280, height: 800, pace: .now)))
    events += engine.perform(.append(#"""
    const f = figure(600, 100, 420, 340, { spin: 0 });
    const body = f.box({ size: [1.2, 0.6, 0.8] });
    f.cylinder({ r: 0.2, h: 1, at: [0, 0.7, 0] });
    f.sphere({ r: 0.25, at: [-0.9, 0, 0] });
    f.sphere({ r: 0.25, at: [0.9, 0, 0] });
    """#))
    events += engine.perform(.end)
    events += engine.perform(.drain)
    let marks = events.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
    let parts = marks.filter { $0.kind == "part3d" && $0.json["recipe"] != nil }
    #expect(parts.count == 4)
    // Three distinct shapes (the two spheres differ only in placement): each is built once, without the stage.
    _ = await waitUntil(.seconds(30)) { kernel.currentStats.cachedMeshes >= 3 }
    let warmed = kernel.currentStats
    #expect(warmed.cachedMeshes == 3)
    #expect(warmed.builds == 3)

    // The stage now finds every mesh in the cache: nothing to load, nothing built again.
    let stage = FigureStage(kernel: kernel, drivesItself: false)
    for mark in marks where mark.isFigureMark { stage.apply(mark) }
    #expect(stage.pendingLoads == 0)
    #expect(stage.scene(marks.first { $0.kind == "figure" }!.id)?.nodes.allSatisfy { $0.mesh != nil } == true)
    #expect(kernel.currentStats.builds == 3)
    #expect(kernel.currentStats.hits >= warmed.hits + 4)
}

/// Without a prewarm hook (the default off in tests that pass nil), a program builds nothing by itself.
@MainActor
@Test func noPrewarmHookLeavesTheKernelAlone() throws {
    let engine = try DrawingEngineHost(prewarmShape: nil)
    _ = engine.perform(.begin(DrawingBeginOptions(width: 1280, height: 800, pace: .now)))
    let events = engine.perform(.append(#"const f = figure(600, 100, 420, 340); f.box({ size: [1, 1, 1] });"#))
    #expect(!events.contains { if case .error = $0 { true } else { false } })
}
