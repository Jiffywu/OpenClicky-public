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
