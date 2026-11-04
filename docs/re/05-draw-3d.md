# 05: 3D figures (kernel and Metal stage)

Clean-room reverse-engineering notes for HeyClicky 1.1.2 (build 69). This document covers the system that turns a drawing program's `figure()` and `scene3d()` calls into a lit, turning, clickable 3D model on the user's screen. It describes behavior, architecture, interfaces and data shapes in our own words. It contains no HeyClicky prompt text, JavaScript bodies or shader code.

Evidence tags:

- **OBSERVED**: seen in an artifact. The path and identifier or string are cited.
- **INFERRED**: our reasoning from observed facts.
- **UNKNOWN**: cannot be recovered from the client.

Artifact abbreviations:

| Short name | Path |
|---|---|
| `engine.js` | `HeyClicky-1.1.2-b69.app/Contents/Resources/clicky-draw-engine.js` |
| `native.js` | `.../Resources/clicky-draw-native.js` |
| `pieces.js` | `.../Resources/clicky-draw-pieces.js` |
| `parts.js` | `.../Resources/clicky-three-parts.js` (the 3D kernel) |
| `three.js` | `.../Resources/clicky-three.js` (three.js 0.186.1 slice) |
| `bin` | `.../Contents/MacOS/HeyClicky`, arm64 slice. Evidence comes from strings, Swift reflection field names, and a few disassembled constant tables. |

---

## 1. Summary

The 3D system has five layers.

1. **Authoring API** (`engine.js`, OBSERVED). A program authored by the voice brain calls `figure(x, y, w, h, o)` or the older `scene3d(...)`. Each call emits plain-data marks: `stage3d`, `part3d`, `label3d`, `motion3d`, `camera3d` and `tick3d`. Each figure part is its own statement and mark. Each mark carries a canonical JSON recipe for its shape.
2. **3D kernel** (`parts.js` plus `ClickyThreeKernel.swift`, OBSERVED). A separate JavaScriptCore context on a background serial queue. It runs a three.js geometry slice and builds a recipe into typed arrays: positions, normals, uvs, indices and framing samples. Results are cached by `kind + canonical recipe`. The engine asks the kernel to start building a part when the part's statement runs, before its beat is drawn.
3. **Scene model** (`DaVinci3DScene`, `DaVinci3DNode`, `DaVinci3DMaterial`, OBSERVED type and field names). This layer holds the native node tree: pose layers, motions, the turntable camera, framing and refit, labels and silhouettes, and material presets.
4. **Metal renderers** (OBSERVED shader source embedded in `bin`). There are two looks:
   - **Illustrated** (`davinci_*`), used by `scene3d()`: two-tone toon shading plus an ink outline found from a per-pixel part-id grid. The same id grid drives picking.
   - **Studio** (`studio_*`), used by `figure()`: GGX PBR, baked studio environment and irradiance cubemaps (compute kernels), a shadow map, half-resolution SSAO with a blur, clearcoat, sheen, glass, glow, hatched cut-away faces, AgX or Neutral tone mapping, and a ground that shows only the object's shadow.
5. **Stage** (`ScreenDrawing3DStage`, `ScreenDrawing3DHandle`, `ScreenDrawing3DRenderers`, OBSERVED). A `CAMetalLayer` inside the drawing canvas, driven by a display link. It draws the paper sheet, the label words (hand font), and leader lines with dots. A small click-catching panel over the figure supports drag-to-orbit and click-to-ask.

No part of this subsystem calls a model on HeyClicky's server. The figure program comes from the **brain** slot (section 2).

```
brain turn (code string) ──► engine.js Session (statement by statement)
     │ marks: stage3d/part3d/label3d/motion3d/camera3d/tick3d
     │ __shape3d(kind, recipeJSON) ───────────────► ClickyThreeKernel (JSContext "Clicky 3D kernel",
     │                                              queue com.humansongs.clicky.three-kernel)
     ▼                                              clickyThreeBuild(kind, recipe) -> typed arrays (cached)
SVG-like element tree (scene3d/part3d/... with data-* JSON)            │
     ▼                                                                 ▼
ScreenDrawingNativePainter ─► ScreenDrawing3DStage ─► DaVinci3DScene (nodes, motions, camera, labels)
                                     │  display link per frame:
                                     │  ticks (JS tick3d) ► turn scene ► object+outline ► labels ► paper ► words ► leaders
                                     ▼
                     DaVinci3DRenderer (illustrated)  or  DaVinci3DStudioRenderer (studio)
                     ScreenDrawing3DHandle (NSPanel) ◄─ mouse: drag = orbit, click = pick ► "What's this?" turn
```

---

## 2. Model slots and server dependency

| Concern | Slot | Notes |
|---|---|---|
| Writing the figure program (JS calling `figure()`, parts, `tick`, labels) | **brain** (multimodal LLM with image input and tool calling) | OBSERVED: user history `Clicky/OneBrain/<id>/<thread>.jsonl` records of `kind: "round"` carry a `code` field with `figure(...)` programs, and `usage.reported_model` is `gpt-6.1-sol`. The brain must emit long, syntactically valid JS that can be parsed statement by statement while it streams. It must reason about 3D coordinates in world units (y up, x right, z toward the viewer). |
| Teaching the brain the `figure()` language | brain (system prompt) | UNKNOWN. The figure API reference is not present in the app bundle, `ClickyModelInstructions.md` or `clicky-harness`. It is server-side. The client only adds a gating line when 3D is unavailable (section 9.6). |
| Clicking a part to ask about it | brain | OBSERVED strings in `bin`: `What's this? (I just clicked `, ` on the 3D model you drew.)`, `the part labelled "`, and the log `3D figure: the user clicked "`. A click becomes a new user turn for the brain. |
| Geometry, rendering, motion | none (on device) | Everything else runs locally in JavaScriptCore and Metal. |

The brain's capabilities for this slot:

- streaming code output
- awareness of the canvas pixel size and the screenshot, to place the rectangle
- a follow-up turn that gets the card-state text (section 3.13) so it can build on an existing figure by part id or variable name

---

## 3. Authoring API in `engine.js` (OBSERVED unless noted)

### 3.1 Shared placement: `standStage(x, y, w, h, o, look)`

Both `figure()` and `scene3d()` call this.

- Stage ids are `st1`, `st2`, and so on. Part ids are `<sid>p<n>`, label ids `<sid>l<n>`, and tick ids `<sid>t<n>`. Numbering is sequential per stage.
- **Busy test.** The rectangle is cut into 64-px tiles. Each tile asks the host `__busyFor(x, y, w, h)`. A tile with a score above 0.02 is busy. The figure stands on paper when at least 8% of tiles are busy. `o.card === true` forces paper and `o.card === false` forbids it.
- **Host card.** If at least 60% of the rectangle lies on a `window` mark that the program drew (`paper()` and similar), the figure stands on that card. The smallest such card wins. That card's board becomes `plain`, and the stage draws no paper of its own.
- **Stream mode.** If `__figuresFloat()` returns true, the figure always floats with no card. The host reads this through `HOST.figuresFloat`.
- **Windowed card.** When the figure is busy and the app draws windows (`__card3d` is set by `pieces.js`), the engine calls `__card3d(x, y, w, h, o)`. That draws a real window card titled `o.title`, with `board: o.board || 'plain'` and a footer. The stage then draws no paper.
- **Stage paper.** Otherwise a busy figure gets `card = rect padded by 10 px`, clamped 4 px inside the canvas. The stage paints that paper itself (sheet, shadow and tape) and shrinks it to fit the object and its labels.
- **Ink.** On paper or a card the ink is `TONES.ink` (`#30333A`). When floating, the ink is whatever `HOST.inkFor(rect)` says reads well there. The default is `#FFFFFF`.
- **Camera.** `stage3d.camera = { tilt, fov, spin }`:
  - tilt: clamped to −80..80 degrees, default 15
  - fov: default 35
  - spin: clamped to 0.5..2, default 0.7, so a figure never stands still

  A comment says the old rate of 0.3 was about 80 s per turn. INFERRED: spin unit ≈ 15°/s, so 0.7 ≈ 34 s per turn.
- `stageBoxes` records every figure rectangle. `api.clearOfFigures(px, py, pw, ph)` moves later paper pieces next to a figure, never on top of it. It warns when it moves something or when there is no calm spot.

### 3.2 `figure(x, y, w, h, o)` → figure handle `f`

- `o`: `tilt`, `fov`, `spin`, `card`, `title`, `board`. The stage mark gets `look: 'studio'`.
- `figure({...})` with no rectangle is placed at (0.5·W, 0.14·H) with size (min(620, 0.44·W), min(480, 0.66·H)), and a warning is logged.
- The call fails with a warning when x, y, w or h is not finite, or when w or h is below 24.
- `f = { id: sid, kind: 'figure', ...methods }`.

**Part constructors.** `f.box`, `f.cyl`, `f.cylinder` (an alias for `cyl`), `f.cone`, `f.tube`, `f.lathe`, `f.sphere`, `f.torus`, `f.capsule`, `f.pipe`, `f.spring`, `f.gear`, `f.extrude`, `f.blob`, `f.poly` and `f.arrow` (`FIGURE_PARTS`). There are also `f.surface(fn, op)` and `f.group(fn?, op)`. `f.arrow(points, op)` and `f.arrow({points, ...})` are both accepted.

**Op keys.** Each part op object is split three ways:

1. **Place keys** (`FIGURE_PLACE_KEYS`): `at` or `pos`, `rot` or `rotate` (Euler XYZ degrees), `scale`, `parent`, `name`, `mat`, `from`, `to`, `mirror`, `copies`, `around`, `cut`. These place the part and never enter the shape recipe.
2. **Material keys** (`MATERIAL_KEYS`): `color`, `roughness`, `metalness`, `emissive`, `emissiveIntensity`, `opacity`, `double`, `flat`, `bands`, `colors`, `glow`.
3. **Everything else** goes into the **recipe** that the kernel builds from (section 4.4).

**Colours.** `figure()` maps Clicky's colour names through `REAL_TONES`, which are realistic photo colours. `scene3d()` and 2D marks use the vivid `TONES`. The exceptions are `emissive` and a `glow:` tint, which stay vivid. A hex value passes through unchanged. The two palettes:

| name | TONES (vivid) | REAL_TONES (figure) |
|---|---|---|
| ink | #30333A | #2C2E33 |
| white | #FFFFFF | #E8E6E1 |
| grey | #7E838D | #8B8E93 |
| butter | #FFD84D | #E0C477 |
| sun | #FFB930 | #D6A83C |
| orange | #FF9A3C | #C9692E |
| peach | #FFB59A | #D8A287 |
| coral | #F2706B | #C1604F |
| red | #E5484D | #A8352D |
| pink | #F59AB5 | #C7848F |
| lilac | #A897F5 | #9E92C0 |
| violet | #6E5BD8 | #5D4D90 |
| sky | #5AA8F5 | #8AAFCC |
| blue | #1F5FCC | #2F5689 |
| mint | #7ED6A0 | #94BCA2 |
| leaf | #3E9E5C | #53794A |
| brown | #A0673D | #6D4A2F |
| tan | #D9A877 | #B9946F |
| cream | #FFF3D6 | #E4D9C2 |

**`mat`.** Forms: `'steel'`, `'glass'`, `'paint:red'`, `'glow:orange'`, or a bare colour.

- The kind must be one of `FIGURE_MATERIALS`: steel, alu, aluminum, aluminium, titanium, chrome, brass, copper, gold, iron, black, rubber, glass, water, wood, ceramic, paper, gloss, paint, plastic, soft, matte, metal, glow.
- An unknown word becomes `gloss` tinted with that word, so `mat: 'red'` means glossy red.
- The material mark gets `mat` and `tint`.
- Section 5.3 gives the native presets.

### 3.3 Placement transforms (applied in this order)

1. **`from`/`to`** (cyl, cylinder, capsule, cone, tube only). Sets `pos` to the midpoint, `recipe.h` to the length, and `recipe.axis` to the unit direction. `from` and `to` are kept in `params` for the card description.
2. **Double-turn guard.** Models sometimes give both `axis` and a `rot` that points the part the same way. If the part is a round part (cyl, cylinder, cone, tube, lathe, sphere, torus, capsule, spring, gear, poly) or an extrusion, a check runs. When the axis differs from the part's natural axis and `rot` applied to the natural axis already lands on `axis`, the part is turned only once:
   - from/to parts drop `rot`
   - extrusions drop `axis`
   - others take the rotated direction as `axis` and drop `rot`

   A warning is logged. Natural axes are +y for most parts and +z for gear and extrude (`FIGURE_STANDS_ALONG`).
3. **Stretch remap.** An array `scale: [sx, sy, sz]` becomes `recipe.stretch`, which is baked into the geometry. If `rot` is made only of right angles, the stretch is remapped so each value applies along the figure's own x, y or z rather than the part's local axes. A number `scale` becomes the node's uniform `scale3`.
4. **Arrow and pipe recentre.** When no `at`/`pos` is given, `pos` becomes the mean of the points and the points become relative to it. Labels, picking and framing then find the part where it really is.
5. **`cut`.** Forms: `true`, `'x'`, `'-y'`, `{axis, at}`. It becomes `material.cut = [nx, ny, nz, offset]`, where n is the unit normal pointing at the half that is **removed**. `cut: true` means z and also sets `material.cutFacing = true`, so the stage turns the plane with the camera and the near half is always removed. `at` is a coordinate along the axis.
6. **Copies.**
   - `copies: { count ≤ 200, step [dx,dy,dz], turn [rx,ry,rz] }` makes a row. Copy i adds i·step and i·turn.
   - `around: { count ≤ 240, axis, center, arc (±360, default 360) }` repeats every placement so far around an axis. The gap is arc/count for a full circle, otherwise arc/(count−1). Rotations compose as quaternions and convert back to XYZ Euler degrees.
   - `mirror: 'x'` or `['x','z']` adds every non-empty combination of reflections. A reflected copy has a negated position on the reflected axes. Each Euler angle is multiplied by the signs of the other two axes. The recipe gets `mirror: [±1, ±1, ±1]`, so the kernel builds a mirrored mesh.
   - Groups take no copies.
7. **Emit.** Each placement becomes one `part3d` mark with:
   - `recipe = JSON.stringify(canonical3(recipe))`. Keys are sorted, numbers are rounded to 4 decimals, non-finite numbers and functions are dropped, and `undefined` array items become null.
   - `copyOf` on every copy after the first.
   - names `name`, `name 2`, `name 3`, …, or `name mirror`.

   Unless the kind is `group`, the engine calls `__shape3d(kind, recipeJSON)` right away so the kernel can start building before the beat is drawn.

**Naming by variable.** Before each top-level statement, the statement transformer (`transform`) checks the pattern `const|let|var NAME = X.<partKind>(`. When it matches, it inserts `__name3d("NAME")` before the statement. The next part mark created at that position takes the name unless `name:` was given. Names are capped at 40 characters.

### 3.4 Part handle (returned by every constructor; it refers to the first placement)

`{ id, kind: 'part', name }` plus:

**Motions.** Each method pushes a `motion3d` mark `{ stage, op: { target, kind, ...fields } }`:

| method | fields (defaults) |
|---|---|
| `spin(op)` | axis (y; also accepts 'x', '-z' or a vector), period 6 s |
| `bob(op)` | axis (y), amount 0.1, period 3 s |
| `orbit(op)` | axis (y), center [0,0,0], period 8 s |
| `path(points, op)` | at least 2 points; `closed` is true unless `once`; period 6 s; `once: true` makes a single pass along the path and then holds at the final point |
| `pulse(op)` | amount 0.08, clamped to ±0.5; period 1 s |

**Pose properties** (getters and setters): `pos`, `rot` (degrees), `scale` (≥ 0), `show` (bool), `glow` (0..1), `color` (a name or hex; REAL_TONES mapping).

- Inside a tick function (`globalThis.__clickyInTick3d === true`), a write sets this frame's pose in `sink.anim[partId]`.
- Outside a tick, a write becomes a beat-timed motion. For `pos` and `rot` that is a `tween` lasting 0.35 s. For the others it is a `set`, an instant switch at that beat. The comment says this keeps the change in step with the spoken line.
- Getters return the latest tick pose, then the planned value, then the mark's initial value.

### 3.5 Figure-level methods

| method | behavior |
|---|---|
| `f.label(pointOrPart, text, op)` | Pushes `label3d { id, stage, point: [x,y,z] or null, follow: partId or null, text (≤ 60 chars), side: 'left' or 'right' or null, size 15..28 (default 19), tone (default stage ink) }`. Empty text returns null. |
| `f.tick(fn)` | Pushes `tick3d { id, stage }`. The function `fn(t, dt)` is stored in `sink.ticks[id]` and is not part of the mark. It runs every frame after its beat is drawn, with `t` = seconds since then. |
| `f.readout(values)` | Holds at most 6 keys. Keys are capped at 24 characters and values at 32. A null value deletes the key. Stored in `sink.readouts[sid]`; never a mark. UNKNOWN consumer: nothing in `native.js` reads `readouts`, and no stage field mentions it. It may be unwired in this build. |
| `f.move(part, {to, rot, secs})` | A one-shot `tween` with a period of `secs` (default 0.8, minimum 0.05). |
| `f.view(op)` and `f.camera(op)` | Pushes `camera3d { stage, op: { tilt (±80), fov, spin (unclamped here, so 0 stops turning), target [x,y,z], turn (±180 degrees from the front), zoom (0.5..3) } }`. |
| `f.build(fn, {parent})` | Runs `fn(f)` with a default parent. |
| `f.part(id)` | Gets a handle for an earlier part. Accepts `'st1p3'`, `'p3'` or `3`. |
| `f.group(fn?, op)` | A `part3d` of kind `group` with no geometry. Parts made inside `fn`, or given `parent`, move with it. |
| `f.surface(fn, op)` | Samples `fn(u, v)` → [x,y,z]. `segments` is 4..160 (default 80) and `rows` is 2..80 (default 16), over ranges `u` and `v` (default [0,1]). Produces `(rows+1) × (segments+1)` points rounded to 3 decimals, sent as `recipe.grid`. |

### 3.6 Legacy `scene3d(x, y, w, h, build, o)` (illustrated look)

- `build(s)` receives a stage object `s` with:
  - `sphere({r:1})`, `box({size:[1,1,1], radius:0})`, `cylinder({r:.5,h:1})`, `cone`, `torus({r:1,tube:.25})`
  - `ring({inner:1, outer:1.5})`, `capsule({r:.3,h:1})`
  - `tube(points, {r:.08, closed:false})`: a tube along points, unlike figure's hollow `tube`
  - `lathe(profile)`, `extrude(d, {depth:.3, unit:.01})`, `surface(fn)`, `group(fn)`
  - `camera`, `label`, `build`, `part`
- Part marks carry `params` (no recipe and no `three` flag), `pos`, `rotate3`, `scale3` (a number), and `material` in vivid TONES.
- Handles support `spin`, `bob`, `orbit`, `path` and `pulse`. They have no pose properties and no tick.
- INFERRED: legacy kinds are built natively in Swift by `DaVinci3DGeometry`, using `DaVinci3DCatmullRomCurve`, `DaVinci3DPathFlattener` and `DaVinci3DEarClipping`. These marks carry no recipe. The kernel's `SHAPES.cylinder` alias exists "for the old scene3d names".

### 3.7 Mark schemas (plain data that crosses to native)

```
stage3d  { do, id:"st1", at:[x,y], w, h, ink:"#RRGGBB", card:[x,y,w,h]|null, cardWindow:[x,y,w,h]|undefined,
           camera:{tilt,fov,spin}, look?:"studio", step, turn?, say? }
part3d   { do, id:"st1p4", stage:"st1", kind, three?:true, recipe?:"<canonical JSON>", params:{...shape keys},
           pos:[x,y,z], rotate3:[deg,deg,deg], scale3:number, material:{...MATERIAL_KEYS, mat?, tint?, cut?, cutFacing?},
           parent:"st1p2"|null, name?, copyOf? }
label3d  { do, id:"st1l1", stage, point:[x,y,z]|null, follow:"st1p3"|null, text, side, size, tone }
motion3d { do, stage, op:{ target, kind: spin|bob|orbit|path|pulse|tween|set, axis?, period?, amount?, center?,
           points?, closed?, once?, to?, rot?, scale?, show?, glow?, color? } }
camera3d { do, stage, op:{ tilt?, fov?, spin?, target?, turn?, zoom? } }
tick3d   { do, id:"st1t1", stage }
```

### 3.8 Element serialization to the native painter (OBSERVED in the `engine.js` renderer and `bin` strings)

The engine renders marks into an element tree. The native painter (`ScreenDrawingNativePainter.swift`) reads it:

| Element | Attributes / payload | Start animation |
|---|---|---|
| `scene3d` | `id`, `x`, `y`, `width`, `height`, `data-ink`, `data-camera` (JSON), `data-card` ("x y w h"), `data-canvas` ("W H"), `data-look` ("studio" or null) | `fadein` 0.35 s |
| `part3d` | `data-stage`, plus `data-part` JSON with id, kind, params, at, rotate, scale, material, parent, three, recipe and name | `grow` 0.65 s |
| `label3d` | `data-stage`, plus `data-label` JSON with id, point, follow, text and side. Also `fill`, `font-family` (hand font) and `font-size`. | `write`, lasting 0.4 + 0.015·chars s |
| `tick3d` | `data-stage`, `data-tick` | `set` 0.01 s |
| `motion3d`, `camera3d` | `data-stage`, `data-op` (JSON) | `set` 0.01 s |

When a figure lands on a program card, that card's `data-board` becomes `plain`, even if the card is already on screen.

### 3.9 Beat pacing and sounds

Times are in seconds.

| Mark | Duration | Advance before the next mark |
|---|---|---|
| `stage3d` | 0.35 | 0.12 |
| `part3d` | 0.65 | 0.12 |
| `label3d` | 0.4 + 0.015·n | 0.7·(0.35 + 0.012·n) |
| `motion3d`, `camera3d`, `tick3d` | 0 | 0 |

- In the screen canvas's sequential mode, ink strokes take turns. Part copies (`copyOf`) and groups are exempt, so they keep the parts' quick rhythm. A comment describes a turbofan with 80+ blades that used to take 25 s.
- `part3d` emits the sound event `build-3d` (`native.js`).
- The ink check (`NO_INK_CHECK`) skips all 3D marks.

### 3.10 Live run, tick bridge and pose packing

- `Session` (live incremental execution) and `runCode` both keep `sink.ticks` (tick id → fn) and `sink.anim` (part id → pose). These are exposed as the non-enumerable `marks.live3d` and `session.live3d`.
- The host calls `clickyCanvas.tick3d({ stage, ticks, dt })` (`native.js`) once per stage frame:
  - `ticks` is `[[tickId, secondsSinceBeat], ...]` for the ticks the stage has started.
  - Each function runs with `__clickyInTick3d = true`, using `dt` (default 1/60).
  - A tick that throws is deleted. The error is logged as `tick <id> stopped: <msg>`.
  - A tick slower than **8 ms** gets a strike. After more than **5** strikes it is deleted (`too slow`).
  - Return value: one `Float32Array` with **14 floats per part** that has any pose set: `[partNumber, mask, px, py, pz, rx, ry, rz (deg), scale, shown 0/1, glow, r, g, b]`.
    - Mask bits: 1 pos, 2 rot, 4 scale, 8 show, 16 glow, 32 colour.
    - Colour is set only if it is a `#RRGGBB` hex. It is sent as sRGB 0..1.
    - Poses persist, so every pose ever set is re-sent each frame.
- Swift side (OBSERVED field types): `ScreenDrawing3DStage.ticks: [String: Double]` (tick id → start time) and `tickProvider: ((String, [(String, Double)], Double) -> [Float]?)?`. The stage applies the floats to `DaVinci3DNode.tickPosition`, `tickRotation`, `tickScale`, `isHiddenByTick`, `tickGlow` and `tickColor`, and records `DaVinci3DScene.tickedPartIDs`.

### 3.11 Edits on 3D marks

- **Recolor** (`recolorMark`) replaces `part3d.material.color`. A figure part uses REAL_TONES, a legacy part uses TONES. The stage swaps the part in place under the same id.
- **Restyle** clamps a label's size to 15..28.
- A Swift string `[{"op":"remove","n":` appears next to the stage code. INFERRED: erase or remove ops are applied per part.

### 3.12 The card-state text that follow-up turns see

`describe3dPart` gives each part one line:

- optional name, then kind
- `r`, `h`, `size`, `inner`, `outer`, `tube` and `depth`
- `from … to …`, or `N points`, or `profile of N points`
- `at [..]` and `rotate [..]`
- colour, `mat` and tint name
- `in <parent>`

Runs of identical parts collapse to `N× st1p5–st1p20 …`. A header line, prefixed `3D figures`, lists each `scene3d` constant and reminds the model (paraphrased) that these figures already exist in the card's code and should be extended, not redrawn. `markLabel` names the other marks, for example `3D figure st1`, `3D motion spin on st1p3` and `3D tick (runs the mechanism every frame)`.

### 3.13 Click to ask

**OBSERVED.** `ScreenDrawing3DClick { name: String, partID: String?, isLabelled: Bool }` and `ScreenDrawing3DStage.onPartClicked`. The strings `this part`, `the striped `, `block`, `ball`, `golden`, `light blue`, `mint`, `tan`, `red`, `pink` and `white` sit next to the stage code.

**INFERRED behavior.**

1. A click without drag travel picks a part.
2. The click gets a name. If the part is labelled, the name is `the part labelled "<label>"`. Otherwise it is the part's variable name, or a description built from its colour or stripes and a kind noun (box → block, sphere → ball), or `this part`.
3. The app logs `3D figure: the user clicked "<name>" (part <id>)`.
4. The app sends the brain a user turn: `What's this? (I just clicked <name> on the 3D model you drew.)`.

The strings `drawing_3d_part` and `figure_part`, which sit among the realtime turn keys, probably tag that turn (UNKNOWN wire use).

---

## 4. The 3D kernel

### 4.1 Runtime (`ClickyThreeKernel.swift`, OBSERVED strings and fields)

- **Context.** Its own `JSContext` named `Clicky 3D kernel`, on serial dispatch queue `com.humansongs.clicky.three-kernel`. It never shares the drawing engine's context.
- **Loading.** It loads the `clicky-three` resource and then `clicky-three-parts`. On failure it reports `3d_kernel_load_failed`, `<name>.js is missing`, `<name>.js failed to load: …` or `clickyThreeBuild is missing`. It keeps `buildFunction: JSValue?` (the global `clickyThreeBuild`) and a `loadFailed` flag.
- **Fields.** `queue`, `lock: NSLock`, `shapes: [String: <entry>]`, `useOrder: [String]` (LRU), `cachedBytes`, `cachedPositionIndexBytes`, `failed: Set<String>`, `queued: Set<String>`, `context`, `buildFunction`, `loadFailed` and `idleRelease`. INFERRED meanings:
  - the cache key is kind plus canonical recipe
  - the cache is LRU and capped by bytes
  - a key that failed is never retried
  - `queued` collapses duplicate requests (twenty identical bolts build once)
  - `idleRelease` tears down the JSContext after a quiet period to free memory

  The byte budget and idle time are UNKNOWN.
- **Result keys.** It reads `positions`, `normals`, `uvs`, `indices` and `samples` from the returned object. Errors are logged as `3D kernel: <kind> failed: <message>`.
- **JIT.** A comment in `parts.js` says the kernel runs **without the JIT**, so its algorithms avoid allocating per sample. OBSERVED: the user-defaults key `ClickyJavaScriptJIT` sits next to `JSC_useJIT` in `bin`. INFERRED: JIT is off by default and toggled by that default. The app does have the `com.apple.security.cs.allow-jit` entitlement.
- **Two entry points.** One is a prewarm request from `HOST.shape3d(kind, recipe)`, called by the engine's `__shape3d`. The other is a fetch when the stage creates the node for a `part3d` with `three: true`. INFERRED: if the mesh is not ready, the node waits; `ScreenFrameLog.Frame.building` flags those frames, and the part grows in once its mesh arrives.

`three.js` (OBSERVED header) is generated by `scripts/clicky-three/build.mjs` from three.js 0.186.1 `three.core.js` with esbuild 0.28.1. It sets `globalThis.ClickyThreeLib` and exports:

ArcCurve, Box3, BoxGeometry, BufferAttribute, BufferGeometry, CapsuleGeometry, CatmullRomCurve3, CircleGeometry, Color, ConeGeometry, ConvexGeometry, CubicBezierCurve3, Curve, CurvePath, CylinderGeometry, DodecahedronGeometry, EllipseCurve, Euler, ExtrudeGeometry, Float32BufferAttribute, IcosahedronGeometry, LatheGeometry, LineCurve3, MathUtils, Matrix3, Matrix4, OctahedronGeometry, ParametricGeometry, Path, PlaneGeometry, PolyhedronGeometry, QuadraticBezierCurve3, Quaternion, REVISION, RingGeometry, RoundedBoxGeometry, Shape, ShapeGeometry, ShapePath, ShapeUtils, SimplexNoise, Sphere, SphereGeometry, SplineCurve, TetrahedronGeometry, TorusGeometry, TorusKnotGeometry, TubeGeometry, Uint32BufferAttribute, Vector2, Vector3, Vector4, mergeVertices, toCreasedNormals.

three.js is MIT-licensed. OpenClicky may build its own slice from upstream.

### 4.2 Kernel JS interface (`parts.js`)

- `globalThis.clickyThreeKinds`: the list of shape kinds.
- `globalThis.clickyThreeBuild(kind, recipeJSON)` → `{ positions: Float32Array, normals: Float32Array, uvs: Float32Array|null, indices: Uint32Array, samples: Float32Array }`. It throws `unknown 3D part "<kind>"` or `part too detailed (<n> vertices)`.
- **Pipeline:**
  1. Parse the recipe.
  2. Run `SHAPES[kind](recipe)`.
  3. If `thick > 0`, apply solidify with thickness `min(thick, 10)`.
  4. Multiply each axis of `stretch` by the sign of `mirror` on that axis, and scale the geometry by the result.
  5. If the scale's determinant is negative, rewind the triangles so they still face outward. The stage culls back faces.
  6. Pack the result.
- **Packing:**
  - computes normals if missing
  - throws when there are more than `MAX_VERTICES = 120000` vertices
  - generates indices for non-indexed geometry
  - picks up to **600 framing samples**: first the min and max vertex on each axis, then vertices at an even stride

### 4.3 Common recipe fields

| key | meaning |
|---|---|
| `axis` | `'x'`, `'-z'` (regex `[+-]?[xyz]`), or a vector. The part, built along its natural axis, is rotated by the shortest-arc quaternion to point that way. |
| `bevel` | Rounded edges. Round parts become a lathe of their outline, with each chosen corner replaced by a 4-step quadratic Bézier tangent to both edges (`BEVEL_STEPS = 4`). The radius is clamped per kind. Values ≤ 0.0005 mean sharp. |
| `seg` | Radial segments (per-kind clamp). Lathe-based bevels use `seg` with a default of 64 (8..128). |
| `arc` | Partial sweep in degrees, 1..360. |
| `thick` | Solidify (section 4.5). |
| `stretch` | `[sx, sy, sz]` uneven scale, baked in. |
| `mirror` | `[±1, ±1, ±1]` reflection, baked in, with rewinding. |

### 4.4 Every kind and its recipe

Defaults are in parentheses. `pos()` means at least 1e-4.

| kind | natural axis | fields and construction |
|---|---|---|
| `box` | — | `size [w,h,d]` or `w`,`h`,`d` (1 each). Corner radius from `r`, falling back to `bevel`, clamped to 0.45·min side. If r > 0.0005, a RoundedBox with 3 segments; otherwise a box. |
| `cyl` / `cylinder` | y | `r` (0.5), `top` (top radius, defaults to r; 0 means a pointed top), `h` (1), `seg` (48; 3..128), `arc`, `open` (no caps, disables bevel), `bevel` (≤ 0.45·min(r, top or r) and ≤ 0.45·h). With a bevel: a lathe of the profile bottom-centre → bottom rim → top rim → top-centre, rounding both rims (only the bottom one when top = 0). |
| `cone` | y | `r` (0.5), `h` (1), `seg` (48), `bevel` (≤ 0.45·min(r,h)), which rounds only the base rim. |
| `tube` | y | Hollow cylinder: `r` (1), `inner` (0.8·r, clamped 0..0.999·r), `h` (1), `bevel` (≤ 0.45·min(r−inner, h)). A lathe of the ring cross-section; the bevel rounds the four outer corners. |
| `arrow` | — | `points` (≤ 200; default (0,0,0)→(1,0,0)), `r` shaft radius (0.04), `head` length (5·r, at most 60% of the curve length), `headR` (2.6·r). Centripetal Catmull-Rom (tension 0.2). The shaft is a tube up to the head start: 48 resampled points, segments = clamp(length/r·2, 16, 400), 12 radial. The head is a 24-segment cone along the final direction. A small sphere caps the start. All pieces are merged. |
| `lathe` | y | `profile [[x,y],…]` (≤ 400; x clamped ≥ 0; a default square profile), `seg` (64; 8..128). |
| `sphere` | y | `r` (0.5), `seg` (48; 8..128). Height segments are 2/3·seg (6..96). `dome: true` keeps the top hemisphere. |
| `torus` | y (hole) | `r` (1), `tube` (0.2), 24 × 72 segments, `arc`. three.js builds the torus in the xy plane; it is turned so it lies flat with its hole along y. |
| `capsule` | y | `r` (0.3), `h` (1, straight length ≥ 0), 8 cap segments, 24 radial. |
| `pipe` | — | `points` (≤ 200; default (0,0,0)→(0,1,0)), `closed` (needs ≥ 3 points), `r` (0.1), `seg` radial (16; 4..32). Tubular segments = clamp(24·points, 24, 2400). |
| `spring` | y | `r` coil radius (0.5), `h` (2), `coils` (8; 0.25..60), `wire` (0.06). A helix tube with clamp(40·coils, 16, 2400) segments and 10 radial. |
| `gear` | z | `teeth` (16; 6..200), `r` (1), `tooth` depth (0.14·r; 0.02·r..0.5·r), `w` thickness (0.3), `hole` axle radius (used if 0 < hole < r − depth), `bevel` (default min(0.02, 0.2·w); explicit values clamped to 0.45·w and 0.45·depth). The outline has square teeth (4 vertices per tooth, alternating r and r − depth). Extruded with a 2-segment bevel and 4 curve segments, centred on z. |
| `extrude` | z | Either `shape [[x,y],…]` (≤ 2000 points, ≥ 3; default triangle) plus `holes`, or `d` SVG path data (≤ 20000 chars) scaled by `unit` (0.01) with y flipped. Path commands M L H V C S Q T A Z, absolute and relative. Arcs are converted to cubic Béziers via the SVG centre parameterisation. Holes come from winding (`toShapes(true)`). `depth` (0.3). `bevel`: `false` means none; a number is clamped to ≤ 0.45·depth with 3 segments; the default is min(0.015, 0.2·depth) with 2 segments. 12 curve segments, centred on z. |
| `blob` | — | **Soft mode**, when `balls` or `sticks` is given (section 4.5). **Lumpy mode** otherwise: an icosphere of `detail` (5; 2..8), welded, displaced radially by `lumps` (0.12; 0..0.22) times a seeded product of three sines (`seed`, 1), and scaled by `size [x,y,z]` or by `r` (1) with `squash` on y. |
| `poly` | y | `faces` 4, 6, 8, 12 or 20 (default 20; any other value gives an icosahedron), `r` (0.5), `detail` (0..3). faces = 6 gives a cube of side 1.15·r. |
| `surface` | — | `grid`: rows of [x,y,z]. Needs ≥ 2 rows and ≥ 2 columns; the shortest row sets the column count. uv = (i/(cols−1), j/(rows−1)). Two triangles per cell, computed normals. Falls back to a 1×1 plane. |

### 4.5 Kernel algorithms (described in our own words)

- **Solidify (`thick`).** Mirrors Blender's Solidify modifier.
  1. Weld vertices by rounding positions to 1e-5.
  2. Accumulate area-weighted face normals per welded point.
  3. Make an inner copy pushed inward along those normals by `thick`, with flipped normals and reversed winding.
  4. Find open edges (edges used by exactly one triangle) and join each to its inner copy with a two-triangle rim strip.
  5. Merge the three pieces.

  A closed mesh becomes hollow, which shows when it is cut.
- **Soft shapes (`blob` with balls and sticks).**
  - **Inputs.**
    - Balls: `[x,y,z,r]` or `{at, r}`.
    - Sticks: `[x1,y1,z1,x2,y2,z2,r,r2]`, `[[a],[b],r,r2]` or `{from, to, r, r2}`.
    - At most 64 of each. Sticks are capsules whose radius tapers from r to r2.
  - **Field.** A signed distance field: the smooth minimum of each primitive's distance, with blend width `k` = `blend` (default 0.5 × mean radius, clamped 0..4 × mean). It is stored in a flat Float64 array with 13 slots per primitive.
  - **Grid.** The bounding box (plus a margin) is divided into **48 cells along the longest side**.
  - **Meshing.** Naive surface nets.
    - Traversal is hierarchical in 8-cell blocks, halving to 4, 2 and 1.
    - A block is skipped when all its corners are on one side and the nearest |field| is more than half the block's diagonal times a Lipschitz bound. The bound is 1 for balls, slightly more for tapered sticks, times 1.05.
    - Each block keeps only the primitives that can reach it (a "focus" list per depth).
    - A crossed cell gets one vertex: the mean of its edge crossings. Its normal comes from a 4-sample tetrahedral gradient of the field.
    - Quads are built around each crossed grid edge and wound outward.
  - **Speed.** A comment gives about 60 ms for a four-primitive heart without the JIT.
- **SVG path parser.** Tokenises letters and numbers and keeps the current point and the reflected control point for S and T. A guard stops after 20000 tokens, and the parser bails out on a non-finite point.
- **Framing samples.** At most 600 points, used by the stage's camera fit (section 5.4).

### 4.6 Native mesh format (OBSERVED reflection)

- `DaVinci3DVertex { position, normal, uv, color }`. It matches the shaders' `VertexIn`: packed float3 + float3 + float2 + float4 = **48 bytes** interleaved. INFERRED: the kernel output is interleaved in Swift, with the default colour white.
- `DaVinci3DMesh { bufferIdentity: BufferIdentity (class, holds positionIndices), vertices: [DaVinci3DVertex], indices: [UInt32], samplePoints: [SIMD3<Float>] }`.
- INFERRED: `positionIndices` is a second index buffer in which every vertex is replaced by the first vertex at the same position. Depth, id and shadow passes then draw a crack-free welded surface, so normal and uv seams don't show up as false ink seams.
- The class identity keys the renderer's GPU buffer cache (`MeshBuffers { owner (weak), vertices, indices, positionIndices: MTLBuffer, count }`). The cache is pruned when it grows (`meshBufferCountAtLastPrune`).

---

## 5. Native scene model (OBSERVED type and field names; semantics INFERRED)

### 5.1 `DaVinci3DScene`

- **Identity:** `id`, `rect`.
- **Camera:** `camera: CameraSettings { distance, tilt, fieldOfView, spin, fits, zoom }`.
- **Nodes:** `nodes: [String: Node]`, `rootNodes`, `motions: [Motion]`, `labels: [Label]`.
- **Orbit:** `orbitTarget`, `orbitRadius`, `orbitTheta` (yaw), `orbitPhi` (pitch).
- **Drag:** `dragThetaDelta`, `dragPhiDelta`, `isUserDragging`.
- **Framing:** `framing`, `objectBox`, `settledExtentTarget` and `settledExtent` (the fit eases toward the target), `settledLeft` and `settledRight` (silhouette arrays for label placement), `framingRevision`, `needsRefit`, `lastTravelRefitTime`, `lastTickRefitTime`, `tickEnvelope` (the union of the extents that ticked parts reach, so tick motion doesn't make the zoom pump), `nearPlane`, `farPlane`.
- **Turntable:** `spinScale`, `restingYaw`, `hasRestingView`, `hasViewerFacingCut`, `swayStartTime`, `frontSwing: (start, from, to, speed, duration)?`.
- **Other:** `highlightStarts: [String: Double]`, `tickedPartIDs`, `labelAnchorWorld: [String: SIMD3]`.
- **JSON keys it parses** (OBSERVED strings near `DaVinci3DScene.swift`): `scene`, `camera`, `distance`, `tilt`, `fov`, `spin`, `fit`, `zoom`, `material`, `three`, `rotate`, `duration`, `parent`, `surface`, `recipe`, `cone`, `torus`, `ring`, `lathe`, `extrude`, `unit`, `inner`, `outer`, `axis`, `period`, `amount`, `orbit`, `bob`, `pulse`, `rot`, `tween`.

### 5.2 `DaVinci3DNode` (class)

- **Identity:** `id`, `kind`, `name`, `creationOrder`, `mesh?`, `material`, `parent`, `children`.
- **Pose layers.** The final local transform is base × motion × tick:
  - `basePosition`, `baseRotation (simd_quatf)`: from the mark
  - `position`, `rotation`: after motions
  - `tickPosition?`, `tickRotation?`, `tickScale`, `isHiddenByTick`, `tickGlow`, `tickColor?`: per-frame JS poses
- **Scale:** `fullScale` (from `scale3`), `growScale` (the grow-in from 0 to 1 over `growDuration`, starting at `growStart`; matches the 0.65 s `grow`), `pulseScale`.
- **Highlight:** `highlight` (a brief brightening; trigger UNKNOWN, perhaps a label being written or a click).
- **Framing cache:** `framingPosition`, `framingRotation`, `framingSamples`, `framingSamplesMatrix`, `framingBoxMinimum`, `framingBoxMaximum`, `framingReaches`, `framingReachesKey`.

### 5.3 `DaVinci3DMaterial` and studio presets

Fields:

- `color` (SIMD4), `roughness`, `metalness`, `emissive` (SIMD4), `opacity`
- `isDoubleSided`, `isFlatShaded`, `usesVertexColors`
- `bands: [SIMD4]` (stripes; ≤ 16 reach the GPU)
- `clearcoat`, `clearcoatRoughness`, `sheen`, `isGlass`
- `cutPlane` (SIMD4 normal + offset), `cutFacesViewer`

The `mat` presets come from disassembling the preset switch: the name string, then the default hex, then stored floats. The tint replaces the default colour when one is given. Unset fields are 0.

| mat | default colour | metalness | roughness | extras |
|---|---|---|---|---|
| steel | #C2C8CF | 0.95 | 0.24 | |
| alu / aluminum / aluminium | #D3D5D6 | 0.55 | 0.55 | |
| titanium | #8E99A8 | 0.85 | 0.34 | |
| chrome | #EEF2F6 | 1.0 | 0.08 | |
| brass | #D2A64C | 0.95 | 0.30 | |
| copper | #CC7F55 | 0.95 | 0.30 | |
| gold | #F2C14E | 1.0 | 0.22 | |
| iron | #5E636B | 0.45 | 0.70 | |
| black | #33373D | 0.10 | 0.40 | clearcoat 0.4 |
| rubber | #34383D | 0 | 0.85 | sheen 0.3 |
| glass | #DCEBFA | 0 | 0.06 | clearcoat 1.0, opacity 0.28 (glass pipeline) |
| water | #3F7390 | 0 | 0.05 | clearcoat 1.0, opacity 0.72 |
| wood | #C99A68 | 0 | 0.70 | |
| ceramic | #F5F0E6 | 0 | 0.25 | clearcoat 0.6 |
| paper | #FAF7F0 | 0 | 0.95 | |
| paint | #5AA8F5 | 0.05 | 0.40 | clearcoat 0.5 |
| plastic | #5AA8F5 | 0 | 0.50 | clearcoat 0.2 |
| soft / matte | #5AA8F5 | 0 | 0.85 | sheen 0.35 |
| metal | #C9D1DC | 0.65 | 0.30 | clearcoat 0.3 |
| glow | #FF9A3C | 0 | 0.40 | emissive from colour (a constant of 1.2 is applied; INFERRED intensity) |
| gloss (default / unknown) | #B9BEC4 | 0 | 0.42 | clearcoat 0.3, clearcoat roughness 0.25 |

The table rows are OBSERVED constants. The mapping from stack offsets to fields is INFERRED from struct order: color +0, roughness +16, metalness +20, opacity +48, clearcoat +64, clearcoat roughness +68, sheen +72.

`#C9A15E` sits next to the `color` key in the same function. INFERRED: it is the fallback part colour when there is no `mat` and no `color`.

### 5.4 Camera, turntable, interaction and framing (INFERRED from fields, env flags and engine comments)

- **Projection.** Perspective with `fieldOfView` (default 35°). The camera orbits `orbitTarget` at `(theta, phi, radius)`.
  - `tilt` sets the elevation, in degrees.
  - `turn` swings yaw to a target relative to the front through `frontSwing`, an eased swing with a start, from, to, speed and duration.
  - `zoom` (0.5..3) scales the fitted distance.
  - `fits`/`fit` turns auto-fit on or off.
  - `distance` is an explicit radius.
- **Auto-turn.** Yaw advances at `spin × spinScale`. `view({spin: 0})` stops it.
  - `restingYaw`, `hasRestingView` and `CANVAS_3D_REST_YAW`: after the user lets go, or when a held-still period ends (`heldStillSince`, `turnRestartedAt`, `hasBegunRestingSwing`), the stage swings to a resting yaw.
  - `CANVAS_3D_KEEP_TURNING` disables resting.
  - `CANVAS_3D_TURN_FPS` caps the frame rate while only the turntable is moving, through `preferredFrameRateRange`. Exact timings are UNKNOWN.
- **Cut sway.** A figure with a cut sways back and forth instead of turning all the way, so the opening stays visible (`hasViewerFacingCut`, `swayStartTime`, `CANVAS_3D_CUT_SWAY`). With `cutFacing`, the cut plane turns with the camera yaw.
- **Fitting.**
  - Each node's framing samples are transformed by its world matrix.
  - The projected extent of the samples sets the camera distance that fits the object inside `objectRect`. Labels go in the margins.
  - Refit runs when parts are added (`needsRefit`, `framingRevision`), with throttling while parts travel along a path (`lastTravelRefitTime`) and while ticks move them (`lastTickRefitTime` with `tickEnvelope`).
  - `settledExtent` eases toward its target, so the zoom glides.
  - An optimisation skips "inner" parts that cannot change the outline. `CANVAS_REFIT_VERIFY` cross-checks it. Its log lines include `refit: skipping inner parts changed the outline` and `refit: a part's framing samples differ from the one-by-one ones`.
- **Silhouette.** `Silhouette { lowX, highX, lowY, highY, left: [Float], right: [Float] }` holds per-row left and right extents of the projected object. Labels use it to sit just beside the object.

### 5.5 Motions (`DaVinci3DScene.Motion`)

Fields: `node`, `kind`, `axis`, `period`, `amount`, `center`, `path` (`DaVinci3DCatmullRomCurve { points, closed, arcLengths }`), `start`, `basePosition`, `baseRotation`, `spinPivot`, `once`, `targetPosition`, `targetRotation`, `setShown`, `setGlow`, `setColor`, `setScale`.

| kind | behavior at elapsed time t since the beat |
|---|---|
| `spin` | Rotates 360° per `period` about `axis` through `spinPivot`, the part's own centre. |
| `bob` | Translates along `axis` by `amount · sin(2πt/period)`. |
| `orbit` | Revolves the part's position about `center` around `axis`, once per `period`. |
| `path` | Moves at constant speed along the Catmull-Rom curve, using the arc-length table. It loops when closed and holds at the end when `once`. |
| `pulse` | `pulseScale = 1 + amount · (a periodic swell)` over `period`. |
| `tween` | Eases from the pose at the start to `targetPosition` and/or `targetRotation` over `period` (0.35 s for property writes, 0.8 s by default for `move`), then stays. |
| `set` | Sets `show`, `glow`, `color` or `scale` at the beat. |

### 5.6 Labels and leaders

- **Scene label.** `Label { id, text, point, followedNodeID, style, start, carrier }`.
- **Placement output.** `DaVinci3DLabelPlacement { id, text, style, start, point, anchor, objectLeft, objectRight }`.
- **Stage label.** `Stage.Label { id, text, size, oneLineWidth, twoLines (first, second), start, duration, requestedSlot, slot, fitting { lines, size, width }, writtenBox, shownBox, unit, follow }`, where `Slot` is left, right, top or bottom.
- **Layout.** `layOutLabels(time:) -> [LabelLayout { index, slot, fitting, box, point }]`.
  - Each label's anchor is projected from its point, or from the part it follows. The anchor is the part's framing centre (`labelAnchorWorld`).
  - The label takes the requested side, or the nearer side.
  - It wraps to two lines when needed.
  - Overlaps along a margin are resolved by the static `spread(wishes:lengths:gap:low:high:)`. That function does 1D de-overlap: it merges colliding labels into `Cluster`s and centres each cluster on its members' wishes, inside the bounds.
- **Drawing.** Text uses the 2D canvas renderer (`ClickyCanvasRenderer`, `ClickyCanvasScene`) in **Patrick Hand** (OBSERVED: `'Patrick Hand', cursive`, `above`, `below`). Labels glide when the object turns (`labelsAreGliding`, `relayoutAfterTurn`).
- **Leaders and dots.** Drawn as capsules (section 7.3).

---

## 6. The stage (`ScreenDrawing3DStage`, OBSERVED fields)

### 6.1 Components

- **`ScreenDrawing3DStage`** (NSObject subclass), with these fields:
  - **Geometry:** `identifier`, `layer: CALayer`, `metalLayer: CAMetalLayer`, `displayLink: CADisplayLink?`, `scene`, `rect`, `objectRect`, `outerRect`, `labelArea`, `paperArea`, `devicePixelsPerUnit`, `backingScale`.
  - **Ink and labels:** `ink`, lazy `inkRGBA` and `haloRGBA`, `labels`, `labelAnchors`, `words` (`ClickyCanvasScene`), `wordsFrameCache`, `nextWordUnit`, `labelsWearFlags`.
  - **Paper:** `cardShown`, `cardShownTime`, `cardWanted`, `cardWantedRevision`. The paper eases to cover the object plus its labels.
  - **Look and ticks:** `look: Look { illustrated, studio }`, `ticks`, `tickProvider`, `lastTickTime`.
  - **Timing and turntable:** `heldStillSince`, `turnRestartedAt`, `hasBegunRestingSwing`, `viewYaw`, `lastFrameTimestamp`, `simulatedTime`, `now: () -> Double`.
  - **Interaction:** `interactiveRect`, `onInteractiveRectChange`, `placement: CGAffineTransform` (canvas units to screen; follows card move and zoom), `onPartClicked`, `lastLayout`, `pressPoint`, `lastDragPoint`, `dragTravel`, `isDragging`, `userTookControl`, `lastHandTime`, `relayoutAfterTurn`, `viewExtent`, `lastBoxEaseTime`.
- **`ScreenDrawing3DRenderers`** (shared): `device`, `commandQueue`, `objects: DaVinci3DRenderer`, `words: ClickyCanvasRenderer`, `overlayPipeline`, `underSheetPipeline`, `overSheetPipeline`. It also holds the instance structs `Sheet { center, halfSize, angle, cornerRadius, color }` and `Capsule { a, b, radius, haloWidth, color, halo }`.
- **`ScreenDrawing3DHandle`**: `stage` (weak), `panel: HandlePanel` (a private NSPanel subclass), `displayFrame`, `pointsPerUnit`, `canvasWindow` (weak). `HandleView { handle, trackingArea }` receives `mouseDown`, `mouseDragged`, `mouseUp`, `mouseMoved`, `mouseEntered` and `mouseExited`. The selectors `openHandCursor`, `closedHandCursor` and `pointingHandCursor` are present. INFERRED: the canvas window ignores mouse events, so a small panel floats over the stage's `interactiveRect` to make the figure draggable and clickable.
- **`ScreenDrawing3DShaderWarmup`**: compiles the Metal sources ahead of time. `newLibraryWithSource:options:completionHandler:` is present.
- **`ScreenFrameLog`**: enabled by `CANVAS_3D_PROFILE`. Per frame it records `stage`, `linkTime`, `target`, `tickStart`, `drawableWait`, `cpuEnd`, `gpuStart`, `gpuEnd`, `presented`, `building` and `rate`. It reports `3D frame (N frames): … total %.3f ms` or `no 3D frames`.

### 6.2 Per-frame pipeline (OBSERVED profile phase names, in order)

1. `wait for drawable`: `nextDrawable` on the CAMetalLayer.
2. `figure ticks`: call the JS `tick3d` through `tickProvider` and apply the poses.
3. `turn the scene`: advance the turntable or sway, the drag inertia and resting swing, motions, grow-in, pulse and highlight; refit when needed.
4. `object + outline`: the Metal render (section 7 or 8).
5. `label layout`.
6. `paper`: sheet instances.
7. `label words`: the hand-font text.
8. `leaders and dots`: capsule instances.

### 6.3 Interaction state machine (INFERRED)

```
idle(auto-turn) --mouseDown--> pressed(pressPoint)
pressed --drag travel > threshold--> dragging (closedHand cursor; theta/phi follow the drag; userTookControl = true)
pressed --mouseUp without travel--> click: pick id at point -> ScreenDrawing3DClick -> onPartClicked -> brain turn
dragging --mouseUp--> released (lastHandTime) --after a quiet period--> resting swing / auto-turn resumes
hover over figure: openHand cursor; hover over a pickable part: pointingHand (INFERRED)
```

Scroll-wheel handling exists in the binary (`scrollWheel:`). Whether it zooms the figure is UNKNOWN.

### 6.4 Device selection and failure gating (OBSERVED strings)

- The stage tries the default GPU first. If it fails, it tries the others (`isLowPower`, `isHeadless`, `isRemovable` are queried) and logs `3D renderer: <gpu> after the default GPU failed`.
- When every GPU fails, it logs `3d_renderer_unavailable` with `gpus=[…] tried=[…]`.
- It then sets the user default `clicky.screenDrawing.3dUnavailableBuild.v1`. INFERRED: the value is the build number, so the next build retries.
- The brain is then told (paraphrased) that this Mac cannot render 3D, so `figure()` and `scene3d()` are off-limits and it should use a 2D drawing or a photo instead.
- If the studio renderer alone fails (`3d_studio_renderer_unavailable`, `3D studio shaders failed to compile: …`), INFERRED: the figure falls back to the illustrated look.

### 6.5 Environment and debug flags (OBSERVED names; defaults from disassembly where noted)

| flag | effect |
|---|---|
| `CANVAS_3D_STYLE=physical` | Illustrated renderer uses its physical (three.js-like) lighting instead of toon. |
| `CANVAS_3D_SILHOUETTE` | Outline pen for object against nothing. Default 0.9; probably a multiplier, unit UNKNOWN. |
| `CANVAS_3D_SEAM` | Seam pen between parts. Default 0.6. |
| `CANVAS_3D_SEAM_STRENGTH` | Seam opacity. Default 1.0. |
| `CANVAS_3D_SEAM_SHADE` | Seam shade factor of the part colour. Default 0.6. |
| `CANVAS_3D_REST_YAW`, `CANVAS_3D_KEEP_TURNING`, `CANVAS_3D_TURN_FPS`, `CANVAS_3D_CUT_SWAY` | Turntable behavior. |
| `CANVAS_3D_PROFILE` | Frame log. |
| `CANVAS_DUMP_STAGE` | Dump the stage to `.png`. |
| `CANVAS_REFIT_VERIFY` | Verify the refit optimisation. |
| `CANVAS_STUDIO_TONEMAP` (`neutral`), `_POWER`, `_SAT`, `_ROOM`, `_KEY`, `_RIM`, `_ENV`, `_EXPOSURE`, `_GROUND`, `_SOFT`, `_AO_RADIUS`, `_AO` | Override studio `Look` fields. |
| `CANVAS_STUDIO_DEBUG` (`depth`, `shadow`, occlusion) | Debug outputs (section 8.4). |

---

## 7. Illustrated look (`DaVinci3DRenderer`, `davinci_*`)

### 7.1 Resources (OBSERVED fields)

- `device`, `commandQueue`
- `opaquePipeline`, `pickingPipeline`, `uncutIDPipeline?`
- `depthWriting`, `depthReadOnly`
- `meshBuffers`
- `multisampleTexture` (MSAA colour), `depthTexture`
- `outlinePipeline`, `inkAndSeamPipeline`
- `opaqueIDTexture`, `clearIDTexture`, `idDepthTexture` (uint id grids)
- `edgeNeighboursCache (reach, table)`
- Errors: `RendererError.pipeline(String)`, `.noDevice`
- `InkOutline { color, width, seamWidth?, seamStrength, seamShade? }`

### 7.2 Uniforms (field names OBSERVED; component meanings INFERRED from the shader)

- `VertexIn` (buffer 0): packed position, normal, uv and colour (48 bytes).
- `FrameUniforms` (buffer 1): `viewProjection`, `eye` (camera position), `style`. `style.x > 0.5` selects the illustrated toon; `style.yzw` is the light direction.
- `ObjectUniforms` (buffer 2):
  - `model`, `normalMatrix0..2` (three float4 columns)
  - `baseColor`, `emissive`
  - `surface`: x roughness, y metalness, z opacity, w band count
  - `flags`: x uses vertex colours, y flat shaded (normal from screen derivatives, turned toward the eye), z double-sided (back faces flip their normal)
  - `cut`: xyz normal, w offset. Active when |n|² > 0.25. A fragment is removed when dot(world, n) > w.
  - `bands[16]`
- Picking id: `uint` at buffer 3.

### 7.3 Passes and shading (described)

- **`davinci_vertex`.** Transforms to world and clip space, passes the world position, the normal (through the normal matrix), uv and colour.
- **`davinci_fragment`.**
  - Base colour = `baseColor`, times the vertex colour if flagged, times a band colour. The band index is `floor((1 − uv.y) · bandCount)`, so stripes run along v.
  - Roughness gets a geometric-AA term: it is raised by how fast the normal changes across the pixel.
  - **Illustrated branch:**
    - Two tones: the full colour where lit, and a cool darker shade where not, with a narrow smooth edge around the terminator.
    - The shade multiplier is bluish, and deeper for metal.
    - There is an extra slight darkening far past the terminator.
    - A small tight white highlight on glossy parts is tied to roughness and metalness.
    - Emissive is added.
    - Output is in sRGB, with alpha = base alpha × opacity.
  - **Physical branch** (`CANVAS_3D_STYLE=physical`): three.js-style lighting.
    - A hemisphere fill: sky white × 1.2, ground about #3a4658 × 1.2.
    - A key light 2.2 from (3, 5, 4).
    - A blue rim light 0.9 from (−4, 2, −4).
    - Lambert diffuse plus GGX specular (Smith-correlated visibility, Schlick Fresnel).
- **ID passes.** `davinci_picking_fragment` writes the part id.
  - On a cut part, fragments beyond the plane are discarded.
  - Back faces seen through the opening (single-sided parts) write `id | 0x80000000`, so the pen outlines the cut face too.
  - `davinci_uncut_id_fragment` is the cheaper variant for uncut parts (a constant id, no discard).
  - Opaque parts draw into `opaqueIDTexture` and see-through parts into `clearIDTexture`. Id 0 means nothing.
- **Outline.** A full-screen triangle (`davinci_outline_vertex`).
  - For each pixel, `nearestEdges` walks a precomputed table of neighbour offsets `(dx, dy, distance)` sorted by ring distance (`edgeNeighbours`, cached per reach). Reads are batched 4 at a time.
  - It finds the distance to the nearest change of id against "nothing" (the **silhouette**) and between two parts (a **seam**), in either grid.
  - `davinci_outline_fragment` coverage = max(silhouette coverage by `halfWidth`, `seamStrength` × seam coverage by `seamHalfWidth`), antialiased over one pixel. The ink colour is premultiplied.
  - `davinci_ink_and_seam_fragment` does it in one pass with **dual-source blending**: ink over the image, with seams drawn as a darkening of each part's own colour (`seamShade`) rather than black.
  - `OutlineUniforms { color, halfWidth, seamHalfWidth, seamStrength, seamShade }`, plus buffers for the neighbour table, its count and a `readsClear` flag.
- **INFERRED pass order:**
  1. MSAA colour and depth for opaque parts (depth writing).
  2. Transparent parts back to front (depth read-only), sorted by `DaVinci3DDrawItem { node, mesh, material, modelMatrix, depth, order }`.
  3. Resolve.
  4. Id pass(es) with `idDepthTexture`.
  5. Outline pass over the resolved colour.
- **Picking.** INFERRED: the CPU reads the id texture at the click pixel, masks off the high bit, and maps the id to a node (probably creation order + 1). The studio renderer has no id pipeline of its own, so INFERRED: picking always uses this renderer's id pass.

---

## 8. Studio look (`DaVinci3DStudioRenderer`, `studio_*`)

### 8.1 Resources (OBSERVED fields)

- **Pipelines:** `opaquePipeline` (function constant `studioMayCut = true`), `solidPipeline` (`studioMayCut = false`, no discard path), `glassPipeline` (blended), `groundPipeline`, `shadowPipeline`, `shadowCutPipeline`, `distancePipeline`, `uncutDistancePipeline?`, `occlusionPipeline`, `occlusionBlurPipeline`.
- **Compute:** `environmentBake`, `irradianceBake`.
- **Textures:** `distanceTexture` and `distanceDepthTexture` (half resolution), `rawOcclusionTexture`, `occlusionTexture`, `noOcclusion` (a white fallback), `environment` (cube with mips), `irradiance` (cube).
- **Depth states:** `depthWriting`, `depthReading`, `shadowDepth`.
- **Shadow cache:** `shadowCaches: [ObjectIdentifier: ShadowCache { scene (weak), texture, drawnFrom: [Float] }]`. The shadow map is reused while its inputs are unchanged.
- **Samplers:** `environmentSampler`, `shadowSampler` (compare).
- **State:** `isEnvironmentBaked`.
- **Errors:** `StudioError.shaders(String)`, `.pipeline(String)`, `.resources`.

### 8.2 `Look` defaults (OBSERVED float constants from disassembly; field order from reflection)

| field | base default | when AgX is active |
|---|---|---|
| keyIntensity | 2.4 | — |
| rimIntensity | 0.55 | — |
| environmentIntensity | 0.9 | — |
| exposure | 1.0 | **1.7** |
| groundShadowOpacity | 0.3 | — |
| shadowSoftness | 1.6 | — |
| occlusionRadius | 0.2 (world units) | — |
| occlusionStrength | 2.2 | — |
| toneMapping | `agx` (`neutral` via `CANVAS_STUDIO_TONEMAP`) | — |
| lookPower | 1.0 | **1.3** |
| lookSaturation | 1.0 | **1.365** |
| roomLevel | 0.85 | **0.3** |

AgX is the default, so the effective studio look is exposure 1.7, power 1.3, saturation 1.365 and room 0.3. The shader comment explains the dark room: a darker room gives metals readable light and dark bands. Each field can be overridden by its `CANVAS_STUDIO_*` variable.

### 8.3 Uniforms (OBSERVED names; components INFERRED from shader use)

`Frame` (buffer 1):

| field | components |
|---|---|
| `viewProjection`, `lightViewProjection` | Camera, and an orthographic overhead key light. The direction toward the light is read from the third row. |
| `eye` | Camera position. |
| `key` | xyz key-light direction; w converts light-space depth to world height (used for the ground contact shadow). |
| `keyColor` | Key radiance (intensity × colour). |
| `rim` | xyz rim direction; w is the debug mode (1 shadow visibility, 2 ambient occlusion). |
| `rimColor` | Rim radiance. |
| `environment` | x = cos(yaw), y = sin(yaw): the studio turns with the camera. z = environment strength, w = exposure. |
| `shadow` | x shadow-map texel/disk scale, y depth bias, z normal-offset distance, w softness. |
| `ground` | x height (y), y and z centre (x, z), w half-size. |
| `groundColor` | rgb, a = shadow opacity. |
| `occlusion` | x radius (world), y strength, z enabled, w depth-debug. |
| `target` | Orbit target (bookkeeping; not read by the shown stages). |
| `viewForward`, `rayBase`, `rayStepX`, `rayStepY` | Rebuild a world point from a half-resolution pixel and its linear depth. |
| `grade` | x = AgX on, y = power, z = saturation. |
| `cutHatch` | x = hatch spacing (world units). |

`Object` (buffer 2) has the same fields as the illustrated `ObjectUniforms`, plus `coat`: x clearcoat, y clearcoat roughness, z sheen, w is-glass.

### 8.4 Passes (order INFERRED from resources and shader inputs)

1. **Environment bake** (once, compute; `isEnvironmentBaked`).
   - `studio_bake_environment` writes a cube map with a mip chain.
   - Level 0 is the procedural studio radiance. The studio is a white room: ceiling, walls and a darker floor, scaled by `room`. It has **four softboxes**: a large warm key up-left-front, a tall thin strip to the right, an overhead panel, and a cool strip behind.
   - Each higher level is a GGX prefilter of that radiance (split-sum, N = V = R, 192 Hammersley samples) at roughness = level/(levels−1). The shader samples up to mip 6, so there are 7 levels.
   - `studio_bake_irradiance` writes a diffuse cube from 512 cosine-weighted samples, pre-divided by pi (stored as average radiance) so that shading only needs one multiply with the diffuse albedo.
2. **Shadow map.** Depth-only from `lightViewProjection`. `studio_shadow_vertex` handles solid parts. `studio_shadow_cut_vertex` with `studio_shadow_cut_fragment` handles cut parts, which cast only from the half that remains. The map is cached per scene in `ShadowCache` and redrawn only when `drawnFrom` (the inputs) changes.
3. **Linear-depth pass** at half resolution.
   - `studio_distance_fragment` writes depth along `viewForward` and discards the removed half of cut parts. `studio_uncut_distance_fragment` handles the rest.
   - Per a source comment (paraphrased), the hardware depth buffer's values are too concentrated near 1.0 to reconstruct positions accurately, hence the separate pass.
4. **SSAO** (`studio_fullscreen_vertex` with `studio_occlusion_fragment`), at half resolution.
   - The surface normal comes from the nearer neighbour on each side.
   - Reach in pixels = world radius / pixel footprint, clamped to 2..36.
   - 12 taps on a golden-angle spiral, rotated per pixel by a 4×4 ordered pattern.
   - Each tap counts by how far it rises above the surface, with distance falloff and a small bias.
   - Result = saturate(1 − strength · mean).
   - Then `studio_occlusion_blur_fragment`: a 4×4 box average that keeps only neighbours on the same surface (world distance < radius/4).
   - The main pass upsamples it with depth-aware bilinear weights (`occlusionAt`).
5. **Main colour pass.**
   - **Ground** (`studio_ground_vertex` and `studio_ground_fragment`): a horizontal quad at the object's base, half-size `ground.w`. It shows **only the shadow**:
     - 12-tap disk samples of the shadow map
     - each occluder weighted by its height above the ground (fades out for parts high above, such as a wing or chain)
     - radial fade from 55% to 100% of the half-size
     - alpha = shade × ground opacity
     - The ground is otherwise transparent, so the screen shows through.
   - **Opaque parts** (`studio_vertex` with `studio_fragment`), using `opaquePipeline` for parts that may be cut and `solidPipeline` for the rest.
   - **Glass parts** last, blended and probably sorted back to front, with no depth write.
6. Outline: UNKNOWN whether studio figures also get the ink outline. The `object + outline` phase covers both looks.

### 8.5 `studio_fragment` shading (described)

- **Ambient occlusion.** Read from the AO map when enabled. Glass gets none.
- **Cut-away.**
  - If the part is cut (`studioMayCut` and an active plane), find where the eye ray meets the cut plane.
  - Draw fine diagonal **hatch lines** there, spaced by `cutHatch.x` and antialiased with `fwidth`. They are computed before branching because they need derivatives.
  - Discard the removed half.
  - A back face of a single-sided part seen through the opening is shaded as the **cut face**: the part colour lightened about 22% toward white, darkened by AO and by the hatch lines, tone-mapped and exposed. This is a textbook sectioned-metal look.
- **Surface.**
  - Flat or double-sided normal handling as in the illustrated look, plus bands and vertex colours.
  - Geometric-AA roughness, with a floor of 0.045.
  - Diffuse colour = base × (1 − metalness). F0 = mix(0.04, base, metalness).
- **Direct light.**
  - Key: GGX plus Lambert. The key term is darkened by the shadow (`shadowVisibility`).
    - Normal-offset lookup that grows at grazing angles.
    - 12-tap Poisson disk with comparison sampling.
    - Past the terminator, a smooth facing term takes over from the map, which avoids streaks on curved parts.
    - The shadow dims the key (to 55%), never cuts it off, and AO dims it a little.
  - Rim: GGX plus Lambert, unshadowed.
- **Image-based light.**
  - Diffuse from the irradiance cube.
  - Specular from the prefiltered cube at mip = roughness × 6, using the analytic environment BRDF approximation.
  - Both cube lookups are rotated into the studio frame by the camera yaw (`turnIntoStudio`).
  - Fill is reduced where the key shadow falls and by AO.
  - The total is scaled by environment strength.
- **Sheen** (rubber, cloth, skin). Adds rim-weighted, slightly whitened colour, ∝ (1 − N·V)³.
- **Clearcoat.** A second GGX lobe (F0 0.04, coat roughness) from the key and the environment, blended over the base by coat × Fresnel.
- **Glow** (emissive). The lamp keeps its hue, which avoids tone mapping washing orange out to peach. Colour = max(lit colour scaled down by glow, normalised emissive capped at 0.9), plus a facing-ratio core. The final colour mixes tone-mapped with un-tone-mapped output by glow.
- **Glass.** No shadows. Reflection is mixed in by Fresnel. Alpha rises toward 1 at grazing angles and where bright highlights are.
- **Tone mapping.**
  - AgX: three.js/Filament port with Rec.2020 inset, log2 range −12.47..+4.03 EV, polynomial sigmoid, then Blender-style power and saturation look, outset, back to linear sRGB.
  - Or Khronos PBR Neutral.
  - Exposure (`environment.w`) is applied first. Output is encoded to sRGB.
- **Debug.** `rim.w = 1` outputs shadow visibility and `rim.w = 2` outputs AO. `occlusion.w` outputs a reach pattern.

---

## 9. Overlays, paper and words (`ScreenDrawing3DStage.swift` shaders)

- **`stage_overlay_vertex` / `stage_overlay_fragment`.** Instanced capsules (`Capsule { a, b, radius, haloWidth, color, halo }`), used for **leader lines and anchor dots**.
  - Each instance is a screen-space quad around the segment, padded by radius, halo and 1.5 px.
  - The fragment takes the distance to the segment and gives an antialiased core plus a halo underneath (premultiplied).
  - `targetSize` converts pixel coordinates to NDC.
- **`stage_sheet_vertex` / `stage_sheet_fragment`.** Instanced rotated rounded rectangles (`Sheet { center, halfSize, angle, cornerRadius, color }`), with antialiased signed-distance edges. Two pipelines exist:
  - `underSheetPipeline`: INFERRED to draw the paper, its shadow, and anything under the object.
  - `overSheetPipeline`: INFERRED to draw the tape strips over the paper's corners.
- **Words.** The label text is rendered by the shared 2D canvas renderer (`words: ClickyCanvasRenderer`) into the same frame.

---

## 10. Permissions and entitlements

- **Metal.** No entitlement needed. The shader source is compiled at run time with `newLibraryWithSource`; OpenClicky can precompile a `.metallib` instead.
- **JavaScriptCore.** HeyClicky has `com.apple.security.cs.allow-jit` (OBSERVED), and the app sandbox is off. The kernel is written to run without the JIT.
- **Screen content.** No extra permission for 3D itself. The busy and ink tests (`__busyFor`, `__inkFor`) read the screenshot that the canvas subsystem already captured.
- **Mouse.** Requires a non-activating panel over the figure. No Accessibility permission is needed for the panel's own events.

---

## 11. Edge cases the code handles (OBSERVED)

- An axis given as a string (`'x'`, `'-z'`) is accepted everywhere. Earlier code dropped it to y, which made fans spin about the wrong axis.
- A part turned twice (by axis and by an equivalent `rot`) is drawn turned once.
- A right-angle `rot` combined with a stretch scales along the figure's axes.
- Arrows and pipes without `at` are recentred on their points.
- A runaway recipe is blocked by vertex caps (120000) and per-kind clamps: points ≤ 200, profile ≤ 400, shape ≤ 2000, path data ≤ 20000 chars, balls and sticks ≤ 64, copies ≤ 200, around ≤ 240.
- Mirrors and negative stretch rewind the triangles, so culling stays correct.
- A syntax error mid-stream waits for more code. A run-time error falls back to re-running the whole program.
- A tick that throws or runs slowly is stopped. Pose writes outside a tick are timed to the beat.
- A `figure()` call without a rectangle gets a default placement.
- When the GPU fails, other GPUs are tried, then the brain is told not to draw 3D.
- Copies and groups don't slow the per-stroke pacing.
- A figure placed on a program card turns that card's board plain instead of drawing a second window.

---

## 12. Rebuild plan for OpenClicky

### 12.1 JavaScript

| module | responsibility |
|---|---|
| `draw/figure3d.js` | Implements `figure()` and `scene3d()` on top of the 2D engine's mark sink. It covers: `standStage` placement rules; part constructors; place, material and shape key splitting; `mat` parsing; REAL_TONES and TONES mapping; `from`/`to`, the double-turn guard, the stretch remap, recentring, cut, copies, around and mirror; canonical recipe JSON; `__name3d` naming via the statement transformer; part handles (motions and pose properties with tick-or-beat semantics); `label`, `tick`, `readout`, `move`, `view`/`camera`, `build`, `part`, `group` and `surface`; the mark schemas in section 3.7; beat timings; and the card-state description. |
| `draw/three-kernel/entry.js`, built to `openclicky-three.js` | Our own esbuild slice of upstream three.js (MIT), exporting the classes the kernel needs. |
| `draw/three-kernel/parts.js` | `openclickyThreeBuild(kind, recipeJSON)` and `openclickyThreeKinds`, implementing section 4.4. Also: bevel by rounded lathe outlines, solidify, soft shapes with sparse surface nets, the SVG path parser, stretch, mirror and rewind, `MAX_VERTICES`, 600 framing samples, and typed-array packing. Keep the recipe format byte-compatible with section 4.4 so the brain prompt stays portable. |
| `draw/native-bridge` additions | `__shape3d` → host prewarm; `__figuresFloat`; `tick3d({stage, ticks, dt})` with the 14-float pose packing and the 8 ms / 5-strike policy; `build-3d` sound event. |

### 12.2 Swift

| module | responsibility |
|---|---|
| `ThreeKernel.swift` | A singleton. Owns a `JSContext` on a serial queue. Loads the two scripts. Provides `prewarm(kind:recipe:)` and `mesh(kind:recipe:completion:)`. Keeps an LRU byte-budgeted cache keyed by `kind + "\u{1}" + recipe`, a failed set, de-duplication of in-flight requests, and idle teardown. Interleaves the arrays into 48-byte vertices and builds the welded `positionIndices`. |
| `Scene3D/Scene3DModel.swift` | `Scene3D`, `Node3D` (base, motion and tick pose layers; grow, pulse and highlight), `Material3D`, `Motion3D` (spin, bob, orbit, path, pulse, tween, set), `CameraSettings3D`, `Label3D`, and a Catmull-Rom curve with an arc-length table. |
| `Scene3D/MaterialPresets.swift` | The table in section 5.3, plus tint override and REAL_TONES handling. |
| `Scene3D/LegacyGeometry.swift` | Either native builders for the `scene3d` kinds (sphere, box, cylinder, cone, torus, ring, capsule, tube-along-points, lathe, extrude with path flattening and ear clipping, surface), or, recommended, a route that sends them through the kernel by translating params into recipes (`tube` → `pipe`, `ring` → a thin `tube`). |
| `Scene3D/Framing.swift` | Transform the framing samples, compute the fitted distance and the eased extent, track the tick envelope, apply refit throttles, and compute the silhouette rows for labels. |
| `Render3D/Render3DDevice.swift` | GPU selection with fallback, async shader warmup, and the "3D unavailable" flag that feeds the brain's capability text. |
| `Render3D/IllustratedRenderer.swift` + `Illustrated.metal` | Toon and physical fragment, MSAA, the transparent sort, the id passes (opaque and clear, cut-face high bit), the neighbour-table outline, and the dual-source ink-and-seam variant. |
| `Render3D/StudioRenderer.swift` + `Studio.metal` | Environment and irradiance bake kernels, the cached shadow map, the half-resolution linear-depth pass, SSAO with blur, the main PBR fragment (clearcoat, sheen, glow, glass, cut hatching), AgX and Neutral tone mapping, the shadow-only ground, and the `Look` struct with the defaults from section 8.2 and environment overrides. |
| `Render3D/Picking.swift` | Read back the id at a pixel (a 1×1 blit to a shared buffer), mask off the high bit, and map to a node. |
| `Stage3D/Stage3DView.swift` | `CAMetalLayer` in the canvas layer tree, a display link with a frame-rate range, the per-frame pipeline in section 6.2, the paper card easing, the label layout with `spread`, the words via the 2D text renderer, leaders and dots, and the profile log. |
| `Stage3D/Stage3DHandlePanel.swift` | A non-activating `NSPanel` over the interactive rect, with a tracking area, cursors, drag-to-orbit, click-to-pick, and resting and auto-turn timers. |
| `Stage3D/Stage3DBridge.swift` | Parses the `scene3d`, `part3d`, `label3d`, `motion3d`, `camera3d` and `tick3d` elements, schedules them by their animation start times, connects `tickProvider` to the JS `tick3d`, and forwards part clicks to the conversation layer as the "What's this?" brain turn. |
| `Stage3D/Overlay.metal` | Capsule and sheet instanced SDF pipelines. |

### 12.3 Brain-slot requirements (for the prompt owners)

- A drawing-language reference for `figure()` that matches section 3: kinds, keys, materials, motions, tick, labels, view.
- The canvas size, so the brain can place the figure rectangle.
- The card-state text for follow-ups.
- The click turn format.
- A capability line when 3D is unavailable.

### 12.4 Verification

- **Golden tests for kernel recipes.** Vertex and index counts, bounding boxes, and that reflected copies have outward winding.
- **Snapshot renders** of a fixed figure in both looks: a gyroscope with a cut casing and glass.
- **Tick bridge round trip.** Pose mask decoding.
- **Picking.** A click on a known pixel returns the expected part id, including the cut face.
- **Performance budget.** A frame of 2 ms CPU and 4 ms GPU at 60 fps on M-series for a figure of about 200 parts (INFERRED target). Kernel builds of 60–200 ms run off the main thread.

---

## 13. Unknowns and open questions

- The server-side prompt that teaches the brain `figure()`, including its version and the examples it uses (UNKNOWN; not in the client).
- The exact numeric constants for:
  - turntable speed scale, rest delay and resting yaw
  - drag sensitivity and the click-versus-drag threshold
  - grow easing
  - outline pen widths in pixels
  - the kernel cache byte budget and idle-release interval

  The binary is stripped; only some constant tables were decoded.
- Whether studio figures also draw the ink outline.
- Who consumes `f.readout()` values.
- Whether legacy `scene3d` parts are built natively in Swift or partly routed through the kernel.
- The exact wire format and tag (`drawing_3d_part` or `figure_part`) of the click-to-ask turn.
- Whether the scroll wheel zooms a figure.
