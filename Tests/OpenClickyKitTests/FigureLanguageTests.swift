import Foundation
import Testing
import simd
@testable import OpenClickyKit

// figure-api.js: the figure() language (docs/dsl-3d.md) as marks, run through the stand-in engine.

private func run(_ program: String) throws -> FigureProgramHarness {
    let harness = try FigureProgramHarness()
    harness.run(program)
    return harness
}

private func marks(_ harness: FigureProgramHarness, _ kind: String) -> [DrawingMark] {
    harness.marks.filter { $0.kind == kind }
}

private func doubles(_ value: JSONValue?) -> [Double] { value?.arrayValue?.compactMap(\.doubleValue) ?? [] }

private func recipe(_ mark: DrawingMark) throws -> JSONValue {
    try JSONValue.parse(mark.json["recipe"]?.stringValue ?? "null")
}

private func close(_ a: [Double], _ b: [Double], _ tolerance: Double = 0.011) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

/// Two XYZ Euler triples describe the same rotation (the same angles can be written several ways).
private func sameRotation(_ a: [Double], _ b: [Double]) -> Bool {
    guard a.count == 3, b.count == 3 else { return false }
    let qa = FigureMath.quaternion(eulerDegrees: SIMD3(Float(a[0]), Float(a[1]), Float(a[2])))
    let qb = FigureMath.quaternion(eulerDegrees: SIMD3(Float(b[0]), Float(b[1]), Float(b[2])))
    return abs(simd_dot(qa.vector, qb.vector)) > 0.99999
}

@Test func figureMarkCarriesRectangleLookAndCamera() throws {
    let h = try run(#"const f = figure(100, 50, 400, 300, { look: "illustrated", tilt: 200, spin: -3, zoom: 9, title: "Gyro" });"#)
    #expect(h.errors.isEmpty)
    let figure = try #require(marks(h, "figure").first)
    #expect(figure.id == "fig1")
    #expect(doubles(figure.json["rect"]) == [100, 50, 400, 300])
    #expect(doubles(figure.json["at"]) == [100, 50])
    #expect(figure.json["w"]?.doubleValue == 400 && figure.json["h"]?.doubleValue == 300)
    #expect(figure.json["look"]?.stringValue == "illustrated")
    #expect(figure.json["camera"]?["tilt"]?.doubleValue == 80)
    #expect(figure.json["camera"]?["spin"]?.doubleValue == 0)
    #expect(figure.json["camera"]?["zoom"]?.doubleValue == 3)
    #expect(figure.json["title"]?.stringValue == "Gyro")
    #expect(figure.json["ink"]?.stringValue == "#30333A")
    #expect(figure.duration == 0.35)
    #expect(figure.isFigureMark)
    // Engine-only hints never reach the host.
    #expect(!figure.json.jsonString().contains("__"))
}

@Test func figureWithoutRectangleIsPlacedAndWarned() throws {
    let h = try run(#"const f = figure({ tilt: 10 }); const g = figure(0, 0, 10, 10); globalThis.gIsNull = g === null;"#)
    #expect(marks(h, "figure").count == 1)
    #expect(h.warnings.contains { $0.contains("no rectangle") })
    #expect(h.warnings.contains { $0.contains("at least 40") })
    #expect(h.context.objectForKeyedSubscript("gIsNull").toBool())
}

@Test func partRecipesAreCanonicalAndHoldOnlyShapeKeys() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    f.cylinder({ r: 0.5, h: 2.123456789, at: [1, 2, 3], rot: [0, 90, 0], mat: "steel", name: "shaft", seg: 32 });
    f.cylinder({ seg: 32, h: 2.12345, r: 0.50001, at: [9, 9, 9] });
    """#)
    let parts = marks(h, "part3d")
    #expect(parts.map(\.id) == ["fig1.p1", "fig1.p2"])
    #expect(parts[0].json["recipe"]?.stringValue == #"{"h":2.1235,"r":0.5,"seg":32}"#)
    // Same shape, different keys order and placement: the same recipe text, so one cached mesh.
    #expect(parts[1].json["recipe"]?.stringValue == parts[0].json["recipe"]?.stringValue)
    #expect(doubles(parts[0].json["at"]) == [1, 2, 3])
    #expect(close(doubles(parts[0].json["rot"]), [0, 90, 0]))
    #expect(parts[0].json["name"]?.stringValue == "shaft")
    #expect(parts[0].json["n"]?.intValue == 1 && parts[1].json["n"]?.intValue == 2)
    #expect(parts[0].json["figure"]?.stringValue == "fig1")
    #expect(parts[0].json["quat"] == nil)
    #expect(parts[0].duration == 0.6)
}

@Test(arguments: [
    (#"{ mat: "paint:red" }"#, "paint", "#B23A32"),
    (#"{ mat: "red" }"#, "gloss", "#B23A32"),
    (#"{ mat: "aluminium" }"#, "aluminum", nil),
    (##"{ mat: "steel", color: "#abc" }"##, "steel", "#AABBCC"),
    (#"{ color: "teal" }"#, nil, "#2F8C88"),
    (#"{ mat: "glow", color: "orange" }"#, "glow", "#FF8A2A"),
    (#"{ mat: "Gold", color: "ink" }"#, "gold", "#30333A"),
] as [(String, String?, String?)])
func materialsParse(options: String, mat: String?, color: String?) throws {
    let h = try run("const f = figure(0, 0, 400, 300); f.box(\(options));")
    let material = try #require(marks(h, "part3d").first?.json["material"])
    #expect(material["mat"]?.stringValue == mat)
    #expect(material["color"]?.stringValue == color)
}

@Test func materialKeysClampAndGlowTakesAColour() throws {
    let h = try run(#"const f = figure(0, 0, 400, 300); f.sphere({ rough: 3, metal: -1, opacity: 0.5, glow: "red", coat: 0.4, flat: true });"#)
    let m = try #require(marks(h, "part3d").first?.json["material"])
    #expect(m["rough"]?.doubleValue == 1 && m["metal"]?.doubleValue == 0 && m["opacity"]?.doubleValue == 0.5)
    #expect(m["glow"]?.doubleValue == 1 && m["glowColor"]?.stringValue == "#FF4A3D")
    #expect(m["coat"]?.doubleValue == 0.4 && m["flat"]?.boolValue == true)
}

@Test func fromToRunsAPartBetweenTwoPoints() throws {
    let h = try run(#"const f = figure(0, 0, 400, 300); f.cylinder({ from: [0, 0, 0], to: [0, 0, 2], r: 0.1 });"#)
    let part = try #require(marks(h, "part3d").first)
    #expect(doubles(part.json["at"]) == [0, 0, 1])
    let r = try recipe(part)
    #expect(r["h"]?.doubleValue == 2)
    #expect(doubles(r["axis"]) == [0, 0, 1])
    #expect(doubles(part.json["from"]) == [0, 0, 0] && doubles(part.json["to"]) == [0, 0, 2])
}

@Test func pipesAndArrowsAreCentredOnTheirPoints() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    f.pipe({ points: [[0, 0, 0], [2, 0, 0], [2, 2, 0], [0, 2, 0]], r: 0.1 });
    f.arrow([[1, 1, 1], [3, 1, 1]]);
    f.pipe({ points: [[0, 0, 0], [1, 0, 0]], at: [5, 5, 5] });
    """#)
    let parts = marks(h, "part3d")
    #expect(doubles(parts[0].json["at"]) == [1, 1, 0])
    #expect(try recipe(parts[0])["points"]?.arrayValue?.map(doubles) == [[-1, -1, 0], [1, -1, 0], [1, 1, 0], [-1, 1, 0]])
    #expect(doubles(parts[1].json["at"]) == [2, 1, 1])
    // An explicit `at` keeps the points as they are.
    #expect(doubles(parts[2].json["at"]) == [5, 5, 5])
    #expect(try recipe(parts[2])["points"]?.arrayValue?.map(doubles) == [[0, 0, 0], [1, 0, 0]])
}

@Test func copiesAroundAnAxisMakeARing() throws {
    let h = try run(#"const f = figure(0, 0, 400, 300); const carbon = f.sphere({ r: 0.3, at: [1.4, 0, 0], copies: { count: 6, around: "y" } });"#)
    let parts = marks(h, "part3d")
    #expect(parts.count == 6)
    for (k, part) in parts.enumerated() {
        let angle = Double(k) * Double.pi / 3
        // Turning +x about +y by θ gives (cos θ, 0, −sin θ).
        #expect(close(doubles(part.json["at"]), [1.4 * cos(angle), 0, -1.4 * sin(angle)]))
        #expect(sameRotation(doubles(part.json["rot"]), [0, Double(k) * 60, 0]))
        #expect(part.json["copyOf"]?.stringValue == (k == 0 ? nil : "fig1.p1"))
        #expect(part.json["name"]?.stringValue == (k == 0 ? "carbon" : "carbon \(k + 1)"))
        #expect(part.json["recipe"]?.stringValue == #"{"r":0.3}"#)
    }
    // Copies after the first are paced quickly.
    #expect(parts[2].start - parts[1].start < 0.05)
}

@Test func copiesInARowStepAndTurn() throws {
    let h = try run(#"const f = figure(0, 0, 400, 300); f.box({ size: [0.2, 1, 0.2], copies: { count: 4, step: [0.5, 0, 0], turn: [0, 0, 10] } });"#)
    let parts = marks(h, "part3d")
    #expect(parts.map { doubles($0.json["at"]) } == [[0, 0, 0], [0.5, 0, 0], [1, 0, 0], [1.5, 0, 0]])
    #expect(parts.map { doubles($0.json["rot"])[2] } == [0, 10, 20, 30])
}

@Test func mirrorAddsReflectedCopiesWithMirroredMeshes() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    const wing = f.box({ size: [2, 0.1, 1], at: [1.5, 0, 0.2], rot: [0, 0, 15], mirror: "x", name: "wing" });
    f.cone({ at: [1, 1, 1], mirror: ["x", "z"] });
    """#)
    let parts = marks(h, "part3d")
    #expect(parts.count == 2 + 4)
    let (wing, reflected) = (parts[0], parts[1])
    #expect(doubles(reflected.json["at"]) == [-1.5, 0, 0.2])
    #expect(doubles(reflected.json["mirror"]) == [-1, 1, 1])
    #expect(reflected.json["name"]?.stringValue == "wing (mirror)")
    #expect(try recipe(reflected)["mirror"].map(doubles) == [-1, 1, 1])
    #expect(try recipe(wing)["mirror"] == nil)
    // Reflecting across x flips the sense of the z rotation.
    #expect(sameRotation(doubles(reflected.json["rot"]), [0, 0, -15]))
    let cones = parts[2...].map { doubles($0.json["at"]) }
    #expect(Set(cones.map { $0.map { Int($0) } }) == [[1, 1, 1], [-1, 1, 1], [1, 1, -1], [-1, 1, -1]])
}

@Test func cutAwaysBecomePlanes() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    f.box({ cut: true });
    f.box({ cut: "x" });
    f.box({ cut: { axis: "-y", at: 0.5 } });
    const g = figure(0, 0, 400, 300, { cut: "z" });
    g.box({});
    g.box({ cut: false });
    """#)
    let parts = marks(h, "part3d")
    #expect(doubles(parts[0].json["cut"]) == [0, 0, 1, 0])
    #expect(doubles(parts[1].json["cut"]) == [1, 0, 0, 0])
    // The removed half is where dot(n, p) > offset: here y < 0.5.
    #expect(doubles(parts[2].json["cut"]) == [0, -1, 0, -0.5])
    #expect(doubles(parts[3].json["cut"]) == [0, 0, 1, 0])
    #expect(parts[4].json["cut"] == .null)
    #expect(doubles(marks(h, "figure")[1].json["cut"]) == [0, 0, 1, 0])
}

@Test func groupsParentTheirParts() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    const arm = f.group({ at: [0, 1, 0], name: "arm" }, (g) => {
      f.box({ size: [2, 0.2, 0.2], at: [1, 0, 0] });
      f.sphere({ r: 0.2, parent: null });
    });
    f.box({ parent: arm });
    f.box({});
    """#)
    let parts = marks(h, "part3d")
    #expect(parts[0].json["kind"]?.stringValue == "group")
    #expect(parts[0].json["group"]?.boolValue == true && parts[0].json["recipe"] == nil)
    #expect(parts[0].duration == 0)
    #expect(parts[1].json["parent"]?.stringValue == "fig1.p1")
    #expect(parts[2].json["parent"]?.stringValue == "fig1.p1")
    #expect(parts[3].json["parent"]?.stringValue == "fig1.p1")
    #expect(parts[4].json["parent"] == .null)
}

@Test func variablesNameTheirParts() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    const rotor = f.cylinder({ r: 1, h: 0.2 });
    let base = f.box({ name: "stand" });
    var crank = f.box({});
    f.box({});
    var spare; spare = f.box({});
    """#)
    let parts = marks(h, "part3d")
    #expect(parts.map { $0.json["name"]?.stringValue } == ["rotor", "stand", "crank", nil, nil])
    // Without the statement hook, the plugin finds a part's variable among the program's globals.
    let registry = h.context.objectForKeyedSubscript("__figure3d")!
    #expect(registry.invokeMethod("nameOf", withArguments: ["fig1.p5"]).toString() == "spare")
    #expect(registry.invokeMethod("nameOf", withArguments: ["fig1.p3"]).toString() == "crank")
    #expect(registry.invokeMethod("nameOf", withArguments: ["fig1.p4"]).isNull)
}

@Test func motionsTargetEveryCopy() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    const blade = f.box({ copies: { count: 3, around: "z" } });
    blade.spin({ axis: "z", rpm: 30 });
    blade.orbit({ period: 4, center: [0, 1, 0] });
    blade.swing({ angle: 400 });
    blade.pulse({ amount: 3 });
    f.move(blade, { to: [1, 2, 3], secs: 2 });
    """#)
    let motions = marks(h, "motion3d")
    #expect(motions.map { $0.json["motion"]?.stringValue } == ["spin", "orbit", "swing", "pulse", "glide"])
    #expect(motions[0].json["targets"]?.arrayValue?.compactMap(\.stringValue) == ["fig1.p1", "fig1.p2", "fig1.p3"])
    #expect(doubles(motions[0].json["axis"]) == [0, 0, 1])
    #expect(motions[0].json["period"]?.doubleValue == 2)
    #expect(motions[2].json["angle"]?.doubleValue == 180)
    #expect(motions[3].json["amount"]?.doubleValue == 0.5)
    #expect(doubles(motions[4].json["to"]) == [1, 2, 3] && motions[4].json["secs"]?.doubleValue == 2)
    // f.move on a handle moves every copy, each to its own end point (here they all start at the centre).
    #expect(motions[4].json["targets"]?.arrayValue?.count == 3)
    #expect(motions[4].json["tos"]?.arrayValue?.map(doubles) == [[1, 2, 3], [1, 2, 3], [1, 2, 3]])
}

@Test func figuresBiggerThanTheCanvasAreShrunk() throws {
    let h = try run(#"const f = figure(0, 0, 9000, 400); f.box({});"#)
    let figure = try #require(marks(h, "figure").first)
    #expect(doubles(figure.json["rect"]) == [0, 0, 1440, 400])
    #expect(figure.json["w"]?.doubleValue == 1440)
    #expect(h.warnings.contains { $0.contains("bigger than the canvas") })
}

@Test func ticksRunThroughTheEnginesGuardWhenItHasOne() throws {
    // The 2D engine stops runaway loops with a guard that is only armed during a statement; ticks run between
    // statements, so an engine that offers ctx.guarded(fn, ms) gets every tick call routed through it.
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    const p = f.box({});
    f.tick((t) => { p.at = [t, 0, 0]; });
    globalThis.guardedCalls = [];
    __figure3d.guarded = (fn, ms) => { guardedCalls.push(ms); return fn(); };
    """#)
    let tick = try #require(marks(h, "tick3d").first)
    let poses = h.tickBridge.runTicks(figure: "fig1", ticks: [(tick.id, 0.5)], dt: 1.0 / 60)
    #expect(poses.count == 12 && poses[2] == 0.5)
    #expect(h.context.evaluateScript("JSON.stringify(guardedCalls)").toString() == "[50]")
}

@Test func poseWritesOutsideATickBecomeBeatTimedMotions() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    const lid = f.box({});
    lid.at = [0, 1, 0];
    lid.rot = [90, 0, 0];
    lid.show = false;
    lid.color = "red";
    globalThis.readBack = JSON.stringify(lid.at);
    """#)
    let motions = marks(h, "motion3d")
    #expect(motions.map { $0.json["motion"]?.stringValue } == ["glide", "glide", "set", "set"])
    #expect(motions[0].json["secs"]?.doubleValue == 0.35 && doubles(motions[0].json["to"]) == [0, 1, 0])
    #expect(doubles(motions[1].json["rot"]) == [90, 0, 0])
    #expect(motions[2].json["show"]?.boolValue == false)
    #expect(motions[3].json["color"]?.stringValue == "#B23A32")
    #expect(h.context.objectForKeyedSubscript("readBack").toString() == "[0,1,0]")
}

@Test func ticksPackPosesAndStopWhenTheyThrow() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    const a = f.box({});
    const b = f.sphere({});
    f.tick((t) => {
      a.at = [t, 0, 0];
      a.rot = [0, 0, 45];
      b.glow = 0.5;
      b.color = "#102030";
      f.readout({ t: t.toFixed(1) });
    });
    f.tick((t) => { if (t > 1) throw new Error("boom"); });
    """#)
    let ticks = marks(h, "tick3d")
    #expect(ticks.map(\.id) == ["fig1.t1", "fig1.t2"])
    let markCount = h.marks.count
    let bridge = h.tickBridge
    let floats = bridge.runTicks(figure: "fig1", ticks: [("fig1.t1", 0.5), ("fig1.t2", 0.5)], dt: 1.0 / 60)
    #expect(floats.count == 2 * FigureTickPose.floatsPerPose)
    #expect(Array(floats[0..<8]) == [1, 3, 0.5, 0, 0, 0, 0, 45] as [Float])  // mask: position + rotation
    #expect(floats[12] == 2 && Int(floats[13]) == 16 | 32 && floats[12 + 9] == 0.5 && floats[12 + 11] == Float(0x102030))
    #expect(bridge.takeReadouts() == ["fig1": ["t": "0.5"]])
    #expect(bridge.takeReadouts().isEmpty)
    // Pose writes inside a tick make no marks.
    h.run("")
    #expect(h.marks.count == markCount)
    // The second tick throws, is stopped with a warning, and the first keeps running.
    _ = bridge.runTicks(figure: "fig1", ticks: [("fig1.t1", 2), ("fig1.t2", 2)], dt: 1.0 / 60)
    h.run("")
    #expect(h.warnings.contains { $0.contains("fig1.t2 stopped: boom") })
    let later = bridge.runTicks(figure: "fig1", ticks: [("fig1.t1", 3), ("fig1.t2", 3)], dt: 1.0 / 60)
    #expect(later[2] == 3)
}

@Test func readoutsKeepSixKeysAndDropNulls() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    f.readout({ a: 1, b: 2.123456, c: "x", d: 4, e: 5, f: 6, g: 7 });
    f.readout({ a: null, b: "a value that is much longer than thirty-two characters" });
    """#)
    let readouts = marks(h, "readout3d")
    #expect(readouts.count == 2)
    #expect(readouts[0].json["values"]?.objectValue?.count == 6)
    #expect(readouts[0].json["values"]?["b"]?.stringValue == "2.123")
    let last = try #require(readouts[1].json["values"]?.objectValue)
    #expect(last["a"] == nil && last["b"]?.stringValue?.count == 32)
}

@Test func labelsFollowPartsOrPoints() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    const rotor = f.cylinder({});
    f.label(rotor, "rotor", { side: "left", size: 99 });
    f.label([1, 2, 3], "a point");
    f.label("p1", "by id");
    globalThis.empty = f.label(rotor, "   ");
    """#)
    let labels = marks(h, "label3d")
    #expect(labels.count == 3)
    #expect(labels[0].json["follow"]?.stringValue == "fig1.p1" && labels[0].json["side"]?.stringValue == "left")
    #expect(labels[0].json["size"]?.doubleValue == 28)
    #expect(doubles(labels[1].json["point"]) == [1, 2, 3] && labels[1].json["follow"] == .null)
    #expect(labels[2].json["follow"]?.stringValue == "fig1.p1")
    #expect(labels[0].duration > 0.4)
    #expect(h.context.objectForKeyedSubscript("empty").isNull)
}

@Test func viewMovesTheCamera() throws {
    let h = try run(#"const f = figure(0, 0, 400, 300); f.view({ tilt: -100, turn: 45, spin: 0, zoom: 0.1, target: [0, 1, 0] });"#)
    let camera = try #require(marks(h, "camera3d").first)
    #expect(camera.json["tilt"]?.doubleValue == -80)
    #expect(camera.json["turn"]?.doubleValue == 45)
    #expect(camera.json["spin"]?.doubleValue == 0)
    #expect(camera.json["zoom"]?.doubleValue == 0.5)
    #expect(doubles(camera.json["target"]) == [0, 1, 0])
    #expect(camera.json["secs"]?.doubleValue == 1)
}

@Test func lookupsAndDescriptionsForFollowUpTurns() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    const hub = f.cylinder({ r: 0.3, h: 0.2, mat: "steel" });
    f.box({ size: [1, 0.05, 0.2], at: [0.8, 0, 0], copies: { count: 8, around: "y" }, name: "blade" });
    globalThis.byNumber = f.part(1).id;
    globalThis.byShort = f.part("p2").id;
    globalThis.byName = f.part("blade 3").id;
    globalThis.missing = f.part("nope");
    globalThis.text = f.describe();
    """#)
    let ctx = h.context
    #expect(ctx.objectForKeyedSubscript("byNumber").toString() == "fig1.p1")
    #expect(ctx.objectForKeyedSubscript("byShort").toString() == "fig1.p2")
    #expect(ctx.objectForKeyedSubscript("byName").toString() == "fig1.p4")
    #expect(ctx.objectForKeyedSubscript("missing").isNull)
    let text = ctx.objectForKeyedSubscript("text").toString() ?? ""
    #expect(text.hasPrefix("3D figure fig1 (9 parts"))
    #expect(text.contains(#"fig1.p1 "hub" · cylinder"#))
    #expect(text.contains("8× fig1.p2–fig1.p9"))
    #expect(h.tickBridge.describe(figure: "fig1") == text)
}

@Test func programErrorsAreReported() throws {
    let h = try run(#"const f = figure(0, 0, 400, 300); f.box({}); f.nonsense();"#)
    #expect(h.errors.contains { $0.contains("nonsense") })
    #expect(marks(h, "part3d").count == 1)
}

@Test func harnessStripsCodeFences() throws {
    let program = "```js\nconst f = figure(0, 0, 400, 300);\nconst gear = f.gear({ teeth: 12 });\n```"
    #expect(FigureProgramHarness.prepare(program).contains(#"__figure3d.nameNext("gear");"#))
    let h = try run(program)
    #expect(h.errors.isEmpty)
    #expect(marks(h, "part3d").first?.json["name"]?.stringValue == "gear")
}

@Test func surfacesSampleAFunctionOnAGrid() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    f.surface((u, v) => [u * 2 - 1, Math.sin(u * 3) * 0.2, v * 2 - 1], { segments: 8, rows: 4, mat: "paint:blue" });
    globalThis.bad = f.surface(42);
    """#)
    let part = try #require(marks(h, "part3d").first)
    #expect(part.json["kind"]?.stringValue == "surface")
    let grid = try #require(try recipe(part)["grid"]?.arrayValue)
    #expect(grid.count == 5 && grid.allSatisfy { $0.arrayValue?.count == 9 })
    #expect(doubles(grid[4].arrayValue?[8]) == [1, 0.028, 1])
    #expect(part.json["material"]?["double"]?.boolValue == true)
    #expect(part.json["material"]?["mat"]?.stringValue == "paint")
    #expect(h.context.objectForKeyedSubscript("bad").isNull)
    #expect(h.warnings.contains { $0.contains("surface() needs") })
}

@Test func pathMotionsTravelAlongPoints() throws {
    let h = try run(#"""
    const f = figure(0, 0, 400, 300);
    const car = f.box({});
    car.path([[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]], { period: 8 });
    car.path({ points: [[0, 0, 0], [1, 1, 1]], once: true });
    car.path([[0, 0, 0]]);
    """#)
    let motions = marks(h, "motion3d")
    #expect(motions.count == 2)
    #expect(motions[0].json["motion"]?.stringValue == "path")
    #expect(motions[0].json["closed"]?.boolValue == true && motions[0].json["once"]?.boolValue == false)
    #expect(motions[0].json["points"]?.arrayValue?.count == 4 && motions[0].json["period"]?.doubleValue == 8)
    #expect(motions[1].json["once"]?.boolValue == true && motions[1].json["closed"]?.boolValue == false)
    #expect(h.warnings.contains { $0.contains("at least 2 points") })
}
