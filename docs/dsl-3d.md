# OpenClicky 3D figures: the `figure()` language

This is the reference for the 3D half of OpenClicky's drawing language. The brain writes it; `Resources/js/figure-api.js`
implements it on top of the 2D engine (`docs/drawing-contract.md`). The 2D language is in `docs/dsl.md`.
The section between the `prompt` markers goes into the brain's instructions as written (copied by
`scripts/sync-prompts.sh`).

<!-- prompt:start -->
A figure is a small 3D model standing in a rectangle on the screen. It turns slowly on a turntable, the user can drag it
to look around, and clicking a part asks the assistant about that part. Each part is one statement, so the model grows
piece by piece while the voice explains it.

```js
say("Here's a gyroscope.");
const f = figure(640, 160, 520, 420, { look: "studio", tilt: 20 });
const rotor = f.cylinder({ r: 0.9, h: 0.18, round: 0.03, axis: "z", mat: "brass" });
f.torus({ r: 1.25, tube: 0.04, mat: "steel" });
f.torus({ r: 1.25, tube: 0.04, mat: "steel", rot: [90, 0, 0] });
f.cylinder({ from: [0, -1.6, 0], to: [0, 1.6, 0], r: 0.05, mat: "chrome" });
rotor.spin({ axis: "z", rpm: 90 });
f.label(rotor, "rotor");
```

Coordinates are figure units: **y up, x right, z toward the viewer**. Size the model to roughly 1–4 units; the camera fits
whatever you build. Angles are degrees. Times are seconds.

## 1. The figure

```js
const f = figure(x, y, w, h, options)
```

`x, y, w, h` is the rectangle in canvas pixels (top-left origin, same as 2D marks). `w` and `h` must be at least 40;
a rectangle bigger than the canvas is shrunk to fit it (with a warning).
`figure(options)` without a rectangle places a default-sized figure on the right half of the canvas and warns.

| option | meaning | default |
|---|---|---|
| `look` | `"studio"` (photographic: soft shadows, reflections, glass) or `"illustrated"` (flat two-tone colour with an ink outline) | `"studio"` |
| `tilt` | camera elevation, −80..80 | 18 |
| `turn` | starting yaw from the front, −180..180 | 0 |
| `spin` | turntable speed in turns per minute, 0..12; 0 holds still | 2 |
| `zoom` | 0.5..3, multiplies the fitted size | 1 |
| `fov` | vertical field of view, 15..70 | 30 |
| `cut` | a cut-away applied to every part made after this (see §4) | none |
| `title` | short caption for the card the painter may draw behind the figure | none |
| `card` | `true` always stands the figure on paper, `false` never; omitted lets the painter decide | auto |

A figure with a cut-away sways back and forth around its starting view instead of turning all the way, so the opening
stays in sight.

## 2. Parts

Every constructor takes one options object and returns a **part handle**. Keys fall into three groups: *shape keys*
(the table below plus the common ones), *placement keys* (§3) and *material keys* (§5). Shape keys define the mesh;
two parts with the same shape keys share one cached mesh no matter where they are placed.

| constructor | shape keys (defaults) | stands along |
|---|---|---|
| `f.box` | `size: [w, h, d]` (1, 1, 1), `round` corner radius | — |
| `f.cylinder` | `r` (0.5), `top` radius at the top (= `r`; 0 makes a point), `h` (1), `open` (no end caps) | y |
| `f.cone` | `r` (0.5), `h` (1) | y |
| `f.tube` | hollow cylinder: `r` outer (0.5), `inner` (0.8·r), `h` (1) | y |
| `f.lathe` | `profile: [[radius, y], …]` turned around y (2..400 points); `closed: true` joins the last point to the first (a ring cross-section); `crease` (40) is the angle in degrees above which a profile corner stays sharp | y |
| `f.sphere` | `r` (0.5), `dome: true` gives a half sphere, flat side down | y |
| `f.torus` | `r` ring radius (1), `tube` thickness radius (0.2), `tubeSeg` (24) segments around the tube | y (hole) |
| `f.capsule` | `r` (0.3), `h` straight length between the round ends (1) | y |
| `f.pipe` | `points: [[x,y,z], …]` (2..200), `r` (0.08), `closed`, `smooth` (true: a curve through the points; false: straight runs with rounded elbows) | — |
| `f.spring` | `r` coil radius (0.4), `h` (1.5), `turns` (8), `wire` radius (0.05) | y |
| `f.gear` | `teeth` (16; 6..200), `r` pitch radius (1), `depth` tooth depth (0.15·r), `width` face thickness (0.3), `hole` axle radius (0); edges are slightly rounded unless `round: 0` | z |
| `f.extrude` | `shape: [[x,y], …]` outline (+ `holes: [[[x,y], …], …]`) **or** `path: "M0 0 L1 0 …"` SVG path data (M L H V C S Q T A Z, absolute and relative) scaled by `unit` (0.01; y is flipped so up is up, and the result is centred); `depth` (0.3); edges are slightly rounded unless `round: false`. An outline (with its holes) may have at most 3000 points; curves get fewer points each when there are many | z |
| `f.blob` | soft organic shapes: `balls: [[x,y,z,r], …]` and/or `sticks: [[x1,y1,z1, x2,y2,z2, r1, r2], …]` (≤ 64 each; also `{at, r}` and `{from, to, r, r2}`) melted together with `smooth` (0.5·mean radius); `res` (44) grid cells along the longest side (a blob of many balls and sticks gets fewer, so it still builds in a few seconds). Without balls or sticks: a lumpy rock of radius `r` (1), or `size: [x, y, z]`, with `lumps` (0.12), `seed` (1) and `squash` (1, height) | — |
| `f.poly` | regular polyhedron: `faces` 4, 6, 8, 12 or 20 (20), `r` (0.5), `detail` (0..3; subdivides toward a sphere) | y |
| `f.arrow` | `points` (or `from`/`to`), `r` shaft radius (0.04), `head` length (5·r), `headR` (2.5·r) | — |
| `f.surface(fn, o)` | a sheet `fn(u, v) → [x, y, z]` sampled over `u` and `v` (each [0, 1]) in `segments` (48; 4..160) × `rows` (16; 2..80) steps; or `o.grid`, rows of points. Both sides show (`double` defaults to true); a sample that throws or isn't a point leaves a hole | — |

Common shape keys, accepted by every kind where they make sense:

| key | meaning |
|---|---|
| `axis` | point the part's natural axis somewhere else: `"x"`, `"-z"`, or a vector `[x, y, z]` |
| `round` | rounded edges, radius in figure units. Round parts get a filleted outline; boxes get rounded corners |
| `seg` | segments around (8..128); the default looks smooth |
| `arc` | partial sweep in degrees (1..360) for round parts and tori; the open sides are capped |
| `thick` | turn a surface into a shell this thick (inward), e.g. a cup from a lathe |

Vertex budget: a part may have at most 150 000 vertices; point lists are capped as listed.

## 3. Placement

| key | meaning |
|---|---|
| `at: [x, y, z]` | position of the part's centre (in its parent's space) |
| `rot: [rx, ry, rz]` | rotation in degrees, applied X then Y then Z |
| `scale` | a number scales uniformly; `[sx, sy, sz]` stretches the mesh along the part's own axes |
| `from: [..], to: [..]` | for cylinder, cone, tube, capsule, spring and arrow: run the part between two points (sets `at`, `h` and `axis`) |
| `parent` | a group or part handle (or its id); the part moves with it |
| `name` | what clicks and follow-up turns call the part (≤ 40 chars) |
| `mirror` | `"x"`, `"z"` or `["x", "z"]`: also place reflected copies across those planes through the parent's origin |
| `copies` | `{count, around: "y", center: [0,0,0], arc: 360}` repeats the part around an axis; `{count, step: [dx,dy,dz], turn: [rx,ry,rz]}` repeats it in a row. Count ≤ 240 |
| `cut` | cut-away, see §4 |

`mirror` and `copies` combine: copies are made first, then every copy is mirrored. The handle refers to the first
placement; `handle.copies` lists every placement's id.

Pipes and arrows given only `points` are centred on their points, so `at` is where they really are.

### Groups

```js
const arm = f.group({ at: [0, 1, 0], rot: [0, 0, 20], name: "arm" });
f.box({ size: [2, 0.2, 0.2], at: [1, 0, 0], parent: arm });
f.group({ at: [0, 0, 0] }, (g) => { f.sphere({ r: 0.3 }); });  // parts made inside default to parent g
arm.spin({ axis: "y", rpm: 10 });
```

## 4. Cut-aways

`cut` removes half of a part to show its inside. The cut face is drawn solid with cross-hatching, the way a technical
section drawing shows it.

- `cut: true` removes the half nearest the viewer (`"z"`).
- `cut: "x"`, `"-y"`, … removes the half on that side of the part's parent origin.
- `cut: {axis: "x", at: 0.2}` puts the plane at x = 0.2.
- `cut: false` exempts a part from a figure-level `cut`.

## 5. Materials

`mat` picks a real-world look; `color` tints it. `mat: "paint:red"` is shorthand for `{mat: "paint", color: "red"}`.
An unknown `mat` word is read as a colour on glossy plastic.

| mat | look |
|---|---|
| `steel`, `chrome`, `aluminum` (`alu`), `titanium`, `iron` | metals from polished to cast |
| `brass`, `copper`, `gold` | warm metals |
| `plastic`, `gloss`, `matte`, `rubber` | dielectrics from shiny to soft |
| `paint` | car paint: colour under a clear coat |
| `ceramic`, `wood`, `paper` | everyday surfaces |
| `glass`, `water` | see-through, reflective at grazing angles |
| `glow` | a lamp or LED; keeps its colour and lights up in both looks |

Material keys: `color` (a name below or `#RRGGBB`), `rough` (0..1), `metal` (0..1), `opacity` (0..1), `glow` (0..1
intensity, or a colour name), `coat` (clear coat 0..1), `sheen` (0..1), `flat` (faceted shading), `double` (show the
inside of open surfaces).

Colour names (muted, photographic): `red`, `orange`, `yellow`, `green`, `teal`, `blue`, `navy`, `purple`, `pink`,
`brown`, `tan`, `cream`, `white`, `grey` (`gray`), `charcoal`, `black`, `silver`, `ink` (the figure's ink colour).
Glows use brighter versions of the same names.

## 6. Motion

Part handles animate. Each motion starts when its statement's line is spoken.

| method | meaning | defaults |
|---|---|---|
| `p.spin({axis, rpm, period, pivot})` | turn continuously about an axis through the part's centre (or `pivot`) | axis y, 30 rpm |
| `p.orbit({center, axis, period})` | travel around a centre | axis y, period 6 |
| `p.swing({axis, angle, period, pivot})` | swing back and forth like a pendulum | axis z, 25°, period 2 |
| `p.bob({axis, amount, period})` | float up and down | y, 0.1, period 2 |
| `p.pulse({amount, period})` | breathe in size | 0.08, period 1 |
| `p.path(points, {period, closed, once})` | travel along a smooth curve through `points` (in the parent's space) at an even speed; `once` makes one pass and stays at the end | period 6, closed unless `once` |
| `p.glide({to, rot, secs})` (or `f.move(p, {...})`) | glide to a new position/rotation once, then stay. The part goes exactly there; its copies move by the same offset and turn in place by the same turn (mirrored copies as mirror images) | secs 0.8 |
| `p.stop()` | stop every motion on the part | |

Pose properties read and write the part's current state: `p.at`, `p.rot`, `p.scale`, `p.show` (bool), `p.glow` (0..1),
`p.color`. Outside a tick, writing `p.at` or `p.rot` glides there in 0.35 s on the current line; the others switch at
once.

### Per-frame ticks

```js
const crank = f.cylinder({ r: 0.6, h: 0.2, axis: "z", mat: "steel" });
const piston = f.cylinder({ r: 0.4, h: 0.6, mat: "alu" });
f.tick((t, dt) => {
  const a = t * 4;                    // radians
  crank.rot = [0, 0, a * 57.3];
  piston.at = [0, 1.2 + 0.5 * Math.cos(a), 0];
  f.readout({ angle: Math.round(a * 57.3 % 360) + "°" });
});
```

`f.tick(fn)` calls `fn(t, dt)` every frame once its line has started (`t` = seconds since then). Inside a tick, pose
writes set this frame's pose directly. A tick is removed when it throws, or when it runs over 8 ms on more than a few frames.

## 7. Camera

`f.view({tilt, turn, zoom, spin, fov, target: [x,y,z], secs})` moves the camera (gliding over `secs`, default 1). `spin:
0` stops the turntable; `turn` swings to a yaw relative to the front.

## 8. Labels and readouts

- `f.label(target, text, {side: "left" | "right", size})` writes a label beside the model with a leader line to
  `target`, a part handle or a point `[x, y, z]`. Text ≤ 60 characters; size 13..28 (17).
- `f.readout({key: value, …})` shows a small live panel of up to 6 values in the figure's corner. Call it again (in a tick
  for live numbers) to update; `null` removes a key.

## 9. Lookups

- `f.part(idOrName)` returns the handle of an earlier part (`"fig1.p3"`, `3`, or its name).
- Variables are the natural way to refer to parts later in the program: `const rotor = f.cylinder(...)`.

<!-- prompt:end -->

## 10. Marks (for engine and painter implementers)

The plugin emits these marks through `ctx.push`. Ids are `<fig>` for the figure (`fig1`, from `ctx.nextId('fig')`),
`<fig>.p<n>` for parts, `<fig>.l<n>` labels, `<fig>.m<n>` motions, `<fig>.c<n>` camera moves, `<fig>.t<n>` ticks and
`<fig>.r<n>` readouts. Every mark has `id`, `do` and `step`; the engine sets `start` and `duration` from the pacing
hints `__dur` (seconds to draw) and `__adv` (seconds before the next mark of the line may start), which it strips.
The engine rounds numbers to 2 decimals, so rotations travel as XYZ Euler degrees, never as quaternions.

```
figure    { at:[x,y], w, h, rect:[x,y,w,h], look, ink, camera:{tilt,turn,spin,zoom,fov}, cut?, title?, card? }
part3d    { figure, n, kind, recipe:"<canonical JSON>", at:[3], rot:[3], scale, parent, name?, mirror?,
            material:{mat, color:"#RRGGBB", rough?, metal?, opacity?, glow?, glowColor?, coat?, sheen?, flat?, double?},
            cut:[nx,ny,nz,offset]|null, copyOf?, group?, from?, to? }
motion3d  { figure, target, targets:[ids], tos?:[[3]], rots?:[[3]], motion: spin|orbit|swing|bob|pulse|path|glide|set|stop, axis?, period?,
            amount?, angle?, center?, pivot?, points?, closed?, once?, to?, rot?, secs?, show?, glow?, color?, scale? }
camera3d  { figure, tilt?, turn?, spin?, zoom?, fov?, target?, secs }
label3d   { figure, text, point:[3]|null, follow:partId|null, side, size }
tick3d    { figure }
readout3d { figure, values:{key: "text"} }
```

Pacing: a figure takes 0.35 s, a part 0.6 s (the next one starts 0.12 s later; copies 0.03 s later, so a ring of 80
blades builds in a few seconds), a label 0.4 s plus 15 ms a character; groups, motions, camera moves, ticks and
readouts take no time. A mark takes effect at `base + start` on the host clock (`base` is when its line started).

`recipe` is the shape keys as JSON with sorted keys and numbers rounded to 4 decimals; the kernel caches meshes by it,
so twenty identical bolts are built once. `n` is the part's 1-based number in its figure; the renderer uses it as the
picking id. A cut plane's normal points at the removed half (`dot(n, p) > offset` is cut away), in the parent's space.

### The plugin's globals (`globalThis.__figure3d`)

- `runTicks(figureId, [[tickId, seconds], …], dt)` runs the figure's started ticks and returns a `Float32Array` of 12
  floats per part with a tick pose: `[n, mask, x, y, z, rx, ry, rz, scale, glow, shown, rgb]` (mask bits 1 position,
  2 rotation, 4 scale, 8 show, 16 glow, 32 colour; `rgb` is 0xRRGGBB). Poses persist, so every pose ever set is sent
  each frame.
- `takeReadouts()` returns the readouts ticks changed since the last call as JSON text `{figureId: {key: text}}`, or
  null.
- `describe(figureId)` gives one line per part for follow-up turns (runs of copies collapse to `8× fig1.p2–fig1.p9`).
- `nameNext(name)`: the next part made takes this name. An engine's statement transformer can call it before a
  statement like `const rotor = f.cylinder(…)` so the part is called "rotor".
- `nameOf(partId)` returns a part's name, or the program variable holding its handle (the engine runs programs at global
  scope), or null.

A glide of a part with copies carries `tos` / `rots`: one end position / rotation per entry of `targets`, so every copy
keeps its place in the row, ring or mirror.

**Engine hook for ticks (optional).** Tick functions are program code that runs between statements, when the 2D
engine's runaway-loop guard (`__lp()` in every loop and function body) is disarmed and stops the first call it sees.
If the engine's plugin `ctx` offers `guarded(fn, ms)` (run `fn` with the guard armed for `ms` milliseconds and return
its value), `runTicks` routes every tick call through it with a 50 ms limit. Until the engine has it, ticks in the real
engine stop after a few hundred frames.

## 11. Host integration (Swift)

- **Kernel.** `FigureKernel.shared` builds meshes in its own JavaScriptCore context (`three-slice.js`, a geometry-only
  three.js r187 build made by `scripts/build-three-kernel.sh`, plus our `three-kernel.js`) on a background queue.
  Meshes are cached by kind + canonical recipe in a byte-budgeted LRU; identical requests in flight build once; a recipe
  that failed is not retried; the context is released after 90 s idle. The builders avoid per-sample allocation, so they
  stay fast without the JIT (a 200-tooth gear builds in under 0.1 s). The drawing engine prewarms it: as a program's
  `figure()` part parses, figure-api.js calls `ctx.prewarmShape(kind, recipe)`, which reaches the host's
  `__host.shape3d` (`DrawingEngineHost(prewarmShape:)`, by default `FigureKernel.shared.prewarm`), so the mesh is usually
  in the cache before the part's line is heard. Each distinct shape is sent once per figure.
- **Live figures.** `FigureStage` is the `FigureSink`: the 2D painter forwards every 3D mark to `apply(_:)` and places
  `layer(forFigure:)` at the figure's rectangle (layer coordinates, top-left origin). Each figure is a `CAMetalLayer` with
  a label overlay. Wire `tickProvider` and `readoutProvider` to `FigureTickBridge` on the drawing engine's context,
  `variableName` to `__figure3d.nameOf`, and forward pointer events from the canvas's click-catching panel to
  `pointerDown`, `pointerDragged` and `pointerUp`: a drag turns the figure (the turntable rests for 2.5 s after), and a
  press without travel picks a part through the id buffer and calls `onPartClicked` with a `FigureClick`, whose `question`
  becomes the typed follow-up turn. `hover(figure:at:)` says whether the pointer is over a part (pointing hand) or the
  figure (open hand). Frames come from the display's `CADisplayLink` (`NSScreen.displayLink`, macOS 14; set
  `displayID` to the figure's display; a timer stands in without a screen): 60 fps while parts move, grow in or follow
  the hand, 30 fps while only the turntable turns (a turntable-only figure also skips frames to hold that rate), and a
  15 fps idle check while every figure is still, when nothing is redrawn. Labels are written in the bundled Patrick
  Hand face, like the 2D words. The overlay's `DrawingDisplayCanvas` and `DrawingPointerRouter` do all of this
  (docs/overlay-interaction.md), and a follow-up turn reads each figure's `describe()` lines.
- **Renderer.** `FigureRenderer` compiles `Resources/metal/*.metal` at run time with `makeLibrary(source:)`; call
  `FigureRenderer.warmUpShaders()` at launch so the first figure finds them in the system's shader cache. The studio
  look bakes a procedural photo studio into cube maps once, then draws a soft shadow map, screen-space ambient
  occlusion, GGX shading with clear coat, sheen, glass and glow, hatched cut faces and a ground that shows only the
  shadow. The shadow map is kept while the light (which turns with the camera) and every shadow caster stay put, and the
  occlusion is computed at half resolution. The illustrated look draws two-tone colour, then inks every pixel near a
  change of part id. The studio shaders compile separately from the illustrated ones: if they fail, studio figures are
  drawn in the illustrated look (`FigureRenderer.studioError`, a stage warning). If no Metal device works or the core
  shaders fail, `FigureStage.rendererError` says so and figures draw nothing; `FigureAvailability` then tells the brain
  not to draw 3D and keeps that verdict for this build (an app-defaults entry keyed by version, build number and the
  executable's date), including when a launch-time compile never finished. A new build tries again.
- **Offscreen.** `FigureSnapshot.render(marks:options:)` and `occtl figure <program.js> <out.png> [--look studio|illustrated]
  [--angle deg] [--time s] [--scale n] [--size WxH] [--background none|#RRGGBB] [--figure id] [--no-labels]` run a
  program through `FigureProgramHarness` (a stand-in engine with the same plugin contract) and write a PNG.
