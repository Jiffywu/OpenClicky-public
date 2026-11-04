# 04 — 2D drawing engine, pieces and native painter

Status: clean-room behavioural spec, reconstructed from HeyClicky 1.1.2 (build 69).
Scope: the 2D screen-drawing system. This covers the program language the model writes, the JavaScript engine that turns a program into timed marks, Clicky's "pieces" library, the speech-paced streaming runtime, the 1.6 live editor, the JavaScriptCore bridge, the render-record protocol, and the Swift Core Animation painter, text shaper and captions.
Out of scope (separate docs): the 3D stage (`scene3d`, `figure`, Metal kernel), the voice/realtime pipeline, the photo search backend, drawing sounds, and the agent harness. This doc only lists where those subsystems connect to this one.

Evidence legend:
- **OBSERVED**: seen in an artifact. The path and identifier are given.
- **INFERRED**: my reasoning from observed facts.
- **UNKNOWN**: the client artifacts can't answer it (server-side prompts, exact Swift algorithms in stripped code).

Artifact abbreviations:
- `ENG` = `Contents/Resources/clicky-draw-engine.js` (header: "lab engine 1.6", `VERSION = '1.6'`)
- `PCS` = `Contents/Resources/clicky-draw-pieces.js`
- `NAT` = `Contents/Resources/clicky-draw-native.js`
- `BIN` = `Contents/MacOS/HeyClicky` (stripped; evidence is the `strings` dump, Swift reflection names, and mangled type names)
- `DATA` = `~/Library/Application Support/Clicky`

---

## 1. Architecture at a glance

```
 brain LLM (streams a ```js program: step()/say()/marks)
        │  accumulated code text
        ▼
 ScreenDrawingCanvas / ScreenDrawingNativeEngine (Swift)
        │  clickyCanvas.feed({code, done})            ◄── line(k) / lineLength(k,s) from the voice
        ▼
 JavaScriptCore context (one per canvas)
   NAT  clicky-draw-native.js  ── SVG-DOM shim, timers, clickyCanvas API, __drainRender
   ENG  clicky-draw-engine.js  ── ClickyDraw: runner → layout → pacer → SVG painter → editor
   PCS  clicky-draw-pieces.js  ── prepended to every program (label, ring, paper, …)
        │  __drainRender() → JSON render ops   (after every call into JS and every timer)
        ▼
 ScreenDrawingNativePainter (Swift)  → CALayer tree on a transparent overlay window
   ScreenDrawingTextShaper (Core Text)  ScreenDrawingSVGPath  ScreenDrawingTurbulence (wash)
   ScreenDrawingCSSColor  ScreenDrawingUnitBezier  ScreenDrawingWindowChrome
        │ pen strokes / mark timings
        ▼
 ScreenDrawingPenCursor / PenFollower (cursor rides the pen), SoundPlayer, ActionButtons,
 CardDragHandles, PinnedCards, StaleWatch, LiveCaption / NativeCaption
```

OBSERVED (`NAT` header comment, paraphrased): the engine emits SVG, and since JavaScriptCore has no browser, `NAT` implements only the minimal subset of SVG DOM behaviour the painter needs and logs every paint operation. After each call the app collects that log (`__drainRender`) and replays it as Core Animation layers. Measurements such as text width and path length are supplied by the app, which lays text out with Core Text.

There is a second Swift scene and renderer, `ClickyCanvasScene`, `ClickyCanvasRenderer`, `ClickyCanvasBaker` and `ClickyCanvasView` (OBSERVED in `BIN` type names). It is Metal-based: the shader functions `canvas_plane_vertex`, `canvas_reveal_coverage_fragment` and `canvas_reveal_depth_fragment`, the labels "Clicky canvas stroke coverage" and "Clicky canvas reveal map", and a `SettledFrameCache`. Its node vocabulary mirrors the painter's (`ClickyCanvasPenMask`, `ClickyCanvasGlyphInk`, `ClickyCanvasGlow`, `ClickyCanvasPenStroke`) and it reads the same attribute names (`fadein`, `multiply`, the `text-before-edge` baselines, `editStrokeEnd`). INFERRED: the Metal path consumes the same render-op stream as the Core Animation painter, and it either is used for in-app surfaces (chat drawing rows, recorded video, recents) or is a newer replacement. Which surface uses which renderer is UNKNOWN. OpenClicky should build the Core Animation painter first and keep the op stream renderer-agnostic.

---

## 2. Coordinate system, units and the canvas

- The canvas is the screenshot. A program draws in screenshot units, x to the right and y down, origin at the top-left of the target display. OBSERVED: `PCS` says the canvas is "about 1280 units wide". Stored programs in `DATA/OneBrain/<user>/<thread>.jsonl` (`code` field) declare `W = 1280, H = 832`.
- The `W` and `H` globals are available to programs, for example `api.W` and `api.H` in `ENG` `makeApi`.
- Points versus units. `clickyCanvas.beginStream({w, h, width})` sets `__canvasUnitPoints = width / w`, which is screen points per canvas unit. The pieces size everything that marks the real screen in points via `__pt(v) = v / __canvasUnitPoints`, so pills, badges and the screen pen look the same on every display. Paper cards, text sizes in programs and graph pieces use raw canvas units.
- Surfaces (`spec.surface`). `'card'` (default) and `'sky'` are lab surfaces; on `'sky'` the default ink is white. `'none'` is the transparent screen overlay that the app uses, and only there does the readable-ink logic run (section 9.6).
- Display choice. The first program line may call `onScreen(n)` to target display n (OBSERVED regex string `onScreen(` in `BIN`; log lines "the program drew on display …: moving the drawing there").

---

## 3. The program the model writes

### 3.1 Shape of a program

OBSERVED from stored programs (`DATA/OneBrain/...jsonl`, `code` field) and `BIN` instruction strings: the brain answers with one ```` ```js ```` block. The block is a sequence of beats. Each beat is `step(n)`, then `say("one short spoken line")`, then the mark calls drawn while that line is spoken. Ordinary JavaScript is allowed: `const`, arrow-function helpers, `for` loops, arithmetic, and destructuring of the boxes that pieces return.

Typical frequencies in the user's 32 stored programs: `say` (136), `step` (83), and the 3D figure calls; among the 2D calls `text`, `rect`, `line`, `dot`, `ellipse`, `paper`, `curve`, `label`, `button`, `ring`, `arrow`, `poly`, `seen`, `startOver`, `circle`, `erase`, `noted`, `frame`, `photo`, `trace`, `point`, `highlight`, `plan`, `sfx`, `check`, and `task`.

The API is described to the model in a server-side file. `PCS` header comment: "worker/src/draw/screenDrawSkill.ts — keep the two in sync". **UNKNOWN**: its exact wording, examples and rules.

### 3.2 How a program is executed (summary; details in section 7)

1. The app prepends the pieces source, plus the code of earlier turns on the same card, to the model's code.
2. Statements run one at a time as each complete statement arrives (incremental execution).
3. Each API call pushes one or more marks: plain JSON objects with a `do` kind.
4. `say(text)` records a line at the current mark index. Marks after it belong to that line.
5. A stream layer runs layout checks and holds marks until their line is spoken. It then spreads them across the line's audio duration.
6. The painter turns each released mark into SVG elements with CSS-like animations. The native shim records those elements and Swift draws them.

---

## 4. Program API reference

The functions are grouped by where they are defined. All calls are made inside a `with (api)` scope, so they are bare names. Every mark-making call accepts a trailing options object `o`. Its keys are merged into the mark (section 5). Return value: the mark object unless stated otherwise.

### 4.1 Engine primitives (`ENG` `makeApi`)

| Call | Mark produced | Notes |
|---|---|---|
| `line(pts, o)` | `{do:'line', pts}` | `pts` is `[[x,y],…]`. Smoothed with Catmull-Rom unless `smooth:false`. |
| `curve(pts, o)` | `{do:'line', pts, smooth:true}` | |
| `arrow(pts, o)` | `{do:'arrow', pts}` | Shaft plus a two-barb head; `o.bend`, `o.head`, `o.headAngle`, `o.label`. |
| `circle(x, y, r, o)` | `{do:'circle', at:[x,y], r}` | |
| `ellipse(x, y, rx, ry, o)` | `{do:'ellipse', at, rx, ry}` | `o.rot` is in radians, or in degrees if its absolute value is over 6.3. |
| `rect(x, y, w, h, o)` | `{do:'rect', at, w, h}` | `o.r` sets the corner radius. |
| `poly(pts, o)` | `{do:'poly', pts}` | Closed unless `close:false`. |
| `path(d, o)` | `{do:'path', d}` | An SVG path string. A multi-`M` path is drawn piece by piece. |
| `text(x, y, text, o)` | `{do:'text', at, text[, link]}` | y is the baseline. `\n` makes multiple lines. URLs are shortened (section 4.1.1). |
| `dot(x, y, r, o)` | `{do:'dot', at, r}` | A filled disc that pops in. |
| `highlight(x, y, w, h, o)` | `{do:'highlight', at, w, h}` | A marker band. A non-numeric first argument makes it an edit (section 4.6). |
| `image(x, y, w, h, o)` | `{do:'image', at, w, h}` | A real photo that the app finds for `o.query` (section 13.9). |
| `molecule(smiles, x, y, w, h, o)` | `{do:'molecule', smiles, at, w, h}` | Needs SmilesDrawer in the page. OBSERVED: no SmilesDrawer in `BIN`, so natively it only reports the error "molecule piece needs SmilesDrawer". |
| `__window(x, y, w, h, o)` | `{do:'window', at, w, h}` | Internal: a native little Mac window. Only the pieces call it. |
| `scene3d(...)`, `figure(...)` | `stage3d`/`part3d`/`label3d`/`motion3d`/`camera3d`/`tick3d` | 3D. See the 3D doc. 2D-relevant: the stage places itself on paper or on a host window (section 9.9). |

#### 4.1.1 Links in text (OBSERVED `ENG` `linkedText`)

Markdown links `[label](https://…)` are shown as their label. Bare URLs longer than 32 characters are shown as their host plus `/…`. The first URL is kept on the mark as `link`, and the app makes those words clickable. `NAT` reports them as `link` actions.

#### 4.1.2 Math and geometry helpers (all deterministic)

- Constants and Math functions: `W`, `H`, `PI`, `sin cos tan asin acos atan atan2 sinh cosh tanh abs min max sqrt cbrt round floor ceil trunc sign pow exp log log2 log10 hypot`.
- Helpers: `range(n)`, `lerp(a, b, t)`, `polar(cx, cy, r, a)`, `add`, `sub`, `mul(p, k)`, `mid(a, b)`, `along(a, b, t)`, `dist`, `angle`, `perp(a, b)` (unit normal), `rotate(p, c, a)`.
- `Math` is a copy of Math whose `random` is a seeded LCG (seed `20260925`), so the same program always draws the same picture. `random` is the same function.
- Every tone name (`ink`, `coral`, …) is also defined as a global equal to its own name, so `tone: leaf` works without quotes.

### 4.2 Narration and structure

| Call | Effect |
|---|---|
| `step(n)` | Sets the current beat number. Later marks get `step:n`. |
| `say(text)` | Records `{text, at: markCount, step[, turn]}` and arms a cue, so the next non-edit mark gets `say:text`. |
| `seen(text)`, `noted(text)` | Draw nothing. The app reads them from the program text: `seen` is what the screen shows the user doing, and `noted` is a fact about the user (OBSERVED comment "One brain: seen(…) … and noted(…)"). |
| `plan(text)` (PCS) | Draws nothing. The picture Clicky intends to draw. The parts list skips comments that start with "plan". |
| `lessonTitle(text)` (PCS) | Draws nothing. The app extracts it with a regex (OBSERVED in `BIN`) to name a saved lesson. |
| `task(label)`, `waitForUser()`, `onScreen(n)` (PCS) | Walkthrough markers read by the app (OBSERVED regexes in `BIN`). |
| `__turn(n, keep)` | Inserted by the canvas host only (the model never emits it). Opens turn n on the existing card with the step counter back at 1, and discards any marks at index `keep` or later from previous turns that had not been painted yet (for example after an interruption). |

### 4.3 Engine pieces with anchors

#### `graph(x, y, w, h, o)` → handle `g`

Options: `x:[min,max]`, `y:[min,max]` (default `[0,10]`), `xTicks`/`yTicks` (a list of values or `[value,label]` pairs, or `true` for automatic "nice" ticks), `ticks` (automatic on both axes), `grid`, `xLabel`, `yLabel`, `labelSize`, `tone`.

What it draws:
- Two arrow axes. Each axis sits at data zero when the range spans zero, otherwise at the box edge.
- Tick marks with grey 14-unit labels. Big numbers are shortened to "80k" and "1.5M".
- Optional faint grey gridlines (alpha 0.4).
- Axis titles.

The handle:
- `g.box`, `g.origin`.
- `g.x(v)`, `g.y(v)`, `g.at(u, v)`: data to canvas.
- `g.plot(fnOrPoints, po)` → series. A function is sampled `po.samples` times (default 64) between `from` and `to`. A list of points is joined straight when it has 8 points or fewer, otherwise as a smooth curve; `po.smooth` or `po.straight` forces the choice. Segments outside the range are clipped by bisection. `po.label` puts the series name at the end or start, kept on the card and off the x axis. `po.tone` defaults to blue and `po.size` to 4.
- `g.line(p1, p2, po)`: a straight series.
- `g.shift(series, dx, dy, po)`: copies a series shifted in data units, and draws an ink arrow between the two curves' midpoints unless `arrow:false`.
- `g.cross(s1, s2)` → the first data point where the two series intersect, or null with a warning.
- `g.point(a, b, po)` or `g.point([a,b], po)`: a dot, with optional dashed `guides` to both axes, `xTick`/`yTick` labels, and a `label`. Returns the canvas point with `.data`.

Series objects carry `{data, tone, size, straight, label, start, end, mid, midData, pts, y(u), at(u)}`. Every mark the graph draws is tagged `piece:'graph'`.

#### `timeline(x, y, w, events, o)` → handle

`events` is a list of `[date, label, shown]` or `{date|at, label|text, show}` or bare dates.

What it draws:
- An arrow along the line.
- For each event: a tick, a coral dot (`dotTone`), a date label and a wrapped event label.

Layout:
- Numeric dates are spaced proportionally (`from`, `to`), unless `even:true` spaces them evenly.
- Marks are pushed apart to at least `minGap`: 96 by default, 70 when alternating. A warning says when dates had to be spread.
- `slots` is `'above'` (default: picture above, words below), `'below'`, or `'alternate'`.

Returns `{marks/events:[{date, label, x, y, at, slot:{x,y,w,h,cx,cy}}], at(date), slot(i), start, end}`. Picture slots let the program put a photo or sketch beside each event. Marks are tagged `piece:'timeline'`.

### 4.4 Clicky's screen-marking pieces (`PCS`, all in Clicky's ink)

Shared constants:
- The screen pen is an even 3.5 pt line (`taper:0`) with a soft glow `[0.65 opacity, 12 pt blur]`.
- Name pills use 12 pt system-font words on a pastel "Aqua gel" capsule.

| Call | Behaviour |
|---|---|
| `point(x, y, name)` | Rings the exact spot (12 pt radius, wobble 0.4) with a 3 pt centre dot, and names it in a pill. |
| `target(x, y, w, h, name)` / `hover(...)` | The control to click or hover. A box form and an older form `(x, y, r, name)`. When the host draws pointers (`__hostDrawsPointers`, always true natively), the call emits only an invisible dot carrying `role`, `ring` (radius), `box` and `label`. The app draws the click-wait ring and waits for the click or hover. Otherwise it draws a dashed rounded outline or ring plus a pill. |
| `frame(x, y, w, h, name, {r})` | An area: a 7% ink tint (`fill`) plus a dashed rounded outline (8 pt dashes, 5 pt gaps), named. Natively both marks carry `marquee:[x,y,w,h,radius]`, and the app drags the frame open from its top-left corner like a selection (0.55 s). Corner radius: `o.r`, else a pill for wide-short things (w > 2.5·h and h < 60 pt), else 8 pt. |
| `ring(x, y, w, h, name, {r})` | A loop around one thing. Things up to 56 pt on their short side become pills or round loops; bigger things become a hand-drawn rounded box with a 12% corner (8–18 pt). The loop overshoots its start by one segment. Uses the hand bow `bow:'pen'`. |
| `ink(pts, {arrow, curve, label, …})` | A free screen-pen stroke. With `arrow` it gets the old walkthrough head (16 pt, half-angle π/7). |
| `inkCircle(x, y, r, o)` | A screen-pen circle. |
| `write(x, y, text, o)` | Free handwriting (size 24) whose colour comes from `__inkFor` over its own box. |
| `label(x, y, text, o)` / `tag(...)` | A name pill anchored by its upper-left corner at (x, y); `anchor:'middle'` centres it horizontally instead. Clamped to the canvas and stepped off figures. A pill that collides with an earlier pill steps down, then up (up to 3 pill heights). Returns its box. |
| `num(x, y, n, o)` | A numbered gel badge (radius 9 pt) with the digit centred by its ink, not its box. A "1" gets a small optical nudge. A badge at the start of a row on a whiteboard snaps to the board's left edge. |
| `underline(x, y, w)` | A 3 pt line 3 pt below the letters' bottom. |
| `connect(a, b, {label})` | A curved ink arrow (`bend 0.2`) between two things on screen. |
| `trace(pts, {straight, fill, label})` | Encloses an oddly shaped area with a closed loop. `straight` keeps corners with hand-bowed edges (`jitter 2`). `fill:true` adds an 18% tint. |
| `check(x, y, s)` / `cross(x, y, s)` / `strike(x, y, w)` | A tick, an X, or a strike-through line. |
| `scroll(x, y, dir, name)` | A double-chevron arrow with a default label "scroll up" or "scroll down". |
| `cheer(x, y, face)` | At most one per drawing: a kaomoji in a pill. |
| `spotlight(x, y, w, h, {pad, r, alpha})` | Dims the whole screen (`#0B0D11` at 0.84) except a rounded hole. Built as an even-odd style path (outer rect clockwise, hole reversed). `role:'stage'`. With no box it dims everything. |

Pill placement (`__nameMark`):
- Candidates: above, below, right and left of the mark, then the corners, then a far ring.
- A candidate is dropped if it is off the canvas, on an existing pill, or on another marked box.
- Among the rest, the winner is the calmest spot: the host's busy score (`__busyFor`) plus a small distance penalty (0.004 per rank) and a 0.02 penalty for the far ring.

### 4.5 Paper, cards and photos (`PCS`)

"Paper only on calm space" (OBSERVED `PCS` header): paper is for an explanation card, never for naming something on screen.

| Call | Behaviour |
|---|---|
| `paper(x, y, w, h, {title, heading, subtitle, board, grid})` | A little Mac window whose writing area is the given box. The title bar holds the title, or the heading if it is 5 words or fewer. Heading: 26-unit title style. Subtitle: 18-unit grey. Returns the area below the heading `{x, y, w, h}`. Registers the board for `sources()`. |
| `sticky(x, y, text, color, {size, tilt, textSize})` | A sticky note (default 170 square, tilt −2°) with a folded corner, a two-layer soft shadow, a tape strip, and words fitted inside. Colours come from the paper tones `butter mint peach lilac sky white news`. |
| `receipt(x, y, title, items, {w, board, title})` | A window with a title and a numbered list (line height 30). |
| `clipping(x, y, w, title, body, source, {h})` | A window with a title, grey body text, and the source in the title bar. |
| `photo(x, y, w, h, query, caption, {tilt, web, from, subtitle, noPeople})` | A polaroid: a shadow, a print in the paper tone, a real image, tape, a handwritten caption, and an optional grey subtitle, all rotated by `tilt` (default −2°). Builds the image query (section 13.9). The same `from` page is used only once. Returns `{box}` of the whole print. |
| `tie(fromPoint, photoOrBox, {bend})` | A thin felt-pen curved arrow from a row of words to its photo, stopping 6 pt short of the box. Carries `tieTo`, so the painter moves the arrow's tail to the measured end of that row's text (section 9.8). |
| `source(x, y, domain, words, {size})` | A favicon (`favicon: host` query) plus grey words. |
| `sources(x, y, [[domain, name], …], {size, maxWidth})` | One grey "Sources" credit line with duplicates removed. Placed under the nearest whiteboard's writing area; the window grows to hold it. With no board it sits on its own small paper plate (`sourcePlate:true`), or is hidden when the app sets `__hideLoneSources` (typed answers). |
| `legend(x, y, [[tone, words], …])` | A row of dot keys (`role:'key'`, so their colours are never contrast-adjusted). Returns its width. |
| `jobTicket(x, y, {...})`, `dreamMedal(x, y, big, {...})` | Welcome-tour-only cards: a ticket with a stub and photo or icon plus a docked button, and a medallion with rays and a ribbon. |

Window construction (`__win`):
- The writing box grows outward by a 24 pt pad, plus a 28 pt title bar above it, with a 10 pt corner radius.
- Natively (`__hostDrawsWindows`) it is one `window` mark: `{header, pad, inner:[x,y,w,h], title, board:'grid'|'dots'|'plain', bg, tint, tintAlpha, role:'paper', snd}`. The app paints the chrome.
- In a lab build it is drawn from shapes: shadow, dark rim, sheet, grey title bar with an ink wash, divider, and the red and green buttons.

Paper steps aside from 3D figures (`clearOfFigures`). A 3D figure on busy screen asks the pieces for a window card (`__card3d`).

### 4.6 Actions the app performs (`PCS`; invisible marks)

These draw an invisible host dot (`fillAlpha:0, outline:false`) carrying `role` and `payload`. The app acts when the dot's line is heard. `NAT` lists them as `actions` (section 11.3).

| Call | role | payload |
|---|---|---|
| `typeText(x, y, text)` | `type` | text. The caret goes to x, y. Falls back to the clipboard. Never presses Return. |
| `copyText(text)` | `copy` | text |
| `openPage(url)` | `open` | url (last beat only) |
| `button(x, y, text, action)` or `button(photoOrBox, text, action)` | `button` | JSON `{text, kind:'open'|'copy'|'ask'|'handoff'|'card', value}`, plus `box` |
| `handOff({task, label, clicky|newClicky})` | `handoff` | JSON |
| `sfx(name)` | `sfx` | one of `tada ding nope stamp sparkle whoosh boing page-turn` |
| `tourJob`, `tuckJobs`, `showNotch`, `fadeAway`, `nextQuestions` | `tourjob` / `tourtuck` / `tournotch` / `tourfade` / `tourasks` | welcome-tour only |

Button geometry:
- Width is the pill width plus 1.6 × the 13 pt text size; height is 1.25 × the pill height.
- The anchored form centres the button on the bottom edge of the photo or row (price-tag style).
- The free form is moved to the nearest spot clear of `__inkBoxes()` and the pills.
- Natively the app draws the real button (`__hostDrawsButtons`) and the JS draws nothing.

### 4.7 Edits as program calls (1.6; `ENG`)

These push `{do:'edit', op}` marks. An edit is paced like a stroke: it happens while the `say()` line before it is heard.

| Call | op |
|---|---|
| `erase(id)` | `{op:'erase', id}` |
| `recolor(id, colorOrObj)` | `{op:'recolor', id, color | fill | line | tone}` |
| `restyle(id, o)` | `{op:'restyle', id, size|width, dash, brush, style|font, weight, color…}` |
| `move(id, dx, dy)` / `moveTo(id, x, y)` / `scale(id, k)` | glide or scale ops |
| `highlight(id, color)` | `{op:'highlight', id, color}`, a coral marker on an existing part |
| `startOver()` | Erases (animates out) all marks already on the card, then treats the remaining statements as a brand-new drawing. |

`id` forms: a part id (`'p3'`, or the number 3), a list `'p3,p5'` or `['p3','p5']`, a mark id `'m12'`, or a range `'m12-m15'`. Ids come from the card state text (section 10.1). Without an id the call warns "… needs a part id like "p3"".

Host-only ops, used through `live().edit()` and not callable from programs: `redraw` (with `code`), `add` (with `code`), `undo`, and the reported-only `say`, `new` and `none`.

---

## 5. The mark data model

A mark is a plain JSON object (functions are stripped by `clean()` so it can cross a worker boundary or be serialised).

### 5.1 Geometry and kind
`do` (`line arrow circle ellipse rect poly path text dot highlight image window molecule edit stage3d part3d label3d motion3d camera3d tick3d`), `pts`, `at`, `r`, `rx`, `ry`, `w`, `h`, `d`, `text`, `smiles`, `op` (edits).

### 5.2 Style options (author-settable)
| Key | Meaning / default |
|---|---|
| `tone` | Stroke or text colour: a tone name or hex. Default `ink`. A filled shape with no `tone` gets an edge 32% darker than its fill, 1.6 wide. |
| `size` | Stroke width (default from `brush`), or text size (default title 24, body 17, caps 14, hand 20). |
| `brush` | `pen` 2.8/α1, `marker` 8/α0.9, `pencil` 1.8/α0.85 with grain, `brush` 6/α0.95. |
| `alpha` | Stroke opacity (overrides the brush's). |
| `fill`, `fillAlpha` | Wash fill colour and opacity (default 1). |
| `outline:false` | Fill only. |
| `wash:false` | Crisp fill with no watercolour displacement (pills, badges, paper). |
| `smooth` | Catmull-Rom smoothing (`curve`, or `poly` with `smooth:true`). |
| `wobble` | Hand wobble amount. Line default 0.6 when unsmoothed, ellipse 1, poly 0.7. 0 means ruler-straight. |
| `bow:'pen'`, `jitter` | Screen-pen bow: each edge bends once to one side. `jitter` moves corners by up to that many points. |
| `taper` | 1 = felt-pen taper and swell (default). 0 = even width with round caps (the screen pen). |
| `dash`, `dashGap` | Dashed `line`/`arrow`. `true`, or the dash length (default max(8, 3·size)); gap defaults to 0.75·dash. |
| `head`, `headAngle` | Arrow head length (default max(9, 3·size)) and half-angle (default 0.5 rad). |
| `bend` | Arrow bow: a fraction of length, or canvas units when >1. `true` = 0.15. Clamped to 0.6 with a warning. |
| `label`, `labelSize`, `labelDx`, `labelDy` | Words over an arrow's midpoint. |
| `glow:[opacity, radius]` | A real blurred shadow in the stroke's own colour (painted by the app; `data-glow`). |
| `r` (rect) | Corner radius. |
| `close:false` (poly) | Open polyline. |
| `style` | Text face: `hand`, `title` (600 weight), `body`, `caps` (upper-case, hair-spaced, 600), `mono`, `ui` (system font, sized in points), `serif`. |
| `weight`, `anchor` (`start`/`middle`/`end`), `rot` (degrees), `baseline`, `top`, `lineHeight` (default 1.3), `wrap` (max width), `fit:[w,h]` (wrap and shrink to fit) | text layout |
| `place:false` | Don't nudge this text off other labels or shapes. |
| `knockout:false` | No ground-coloured halo behind words. |
| `under:true` | Draw in the under layer and skip layout checks. |
| `together:true` | Shares its start time with the following mark rather than preceding it, so layered gel fills pop in as a single unit. |
| `query`, `r`, `rot` (image) | Photo search query, corner radius, rotation in degrees. |

### 5.3 Semantic and host keys (set by pieces)
- `role`: `point target hover type copy open handoff button sfx tourjob tourtuck tourasks tournotch tourfade ring frame label num underline connect trace check cross strike scroll cheer paper photo source key tie stage`.
- `payload`, `ring`, `box`, `label`.
- `marquee:[x,y,w,h,r]`, `snd` (sound id on landing), `onWindow:[x,y]` (belongs to a window's writing area), `sourceLine`, `sourceSize`, `sourcePlate`, `tieTo:[x,y,w,h,gap,pad]`, `link`, `piece` (`graph`/`timeline`).
- Window keys: `header pad inner title board bg tint tintAlpha`.

### 5.4 Bookkeeping keys (engine-set)
- `step`, `turn`, `say` (the cue text on the first mark after a `say`).
- Edit and stream state: `__est` (the edit's estimated duration), `__xf:[k, tx, ty]` (the uniform-scale-plus-translate transform an edit gave it), `__dash` (dash on closed shapes, set only by edits), `__erased`, `__skip`, `__dropped`, `__passed`, `__tied`, `__aligned`, `__result` (an edit's outcome), and `_t`/`_pace` (a precomputed schedule).
- `shift` (translation for `path` marks, used by layout).

### 5.5 Identity
- Mark index i is the order of creation within the card's whole program, including pieces. Its display id is `m<i>`.
- Marks created by editor ops start at `EDIT_BASE = 2000`.
- Parts are named `p1, p2, …` in program order; parts added by edits are `x1, x2, …` (section 10.1).
- Hard limit: 2000 marks per run. Past it, the program throws "too many marks (the limit is 2000)".

---

## 6. Colours

OBSERVED `ENG` `TONES`. The named palette:

`ink #30333A`, `white #FFFFFF`, `grey #7E838D`, `butter #FFD84D`, `sun #FFB930`, `orange #FF9A3C`, `peach #FFB59A`, `coral #F2706B`, `red #E5484D`, `pink #F59AB5`, `lilac #A897F5`, `violet #6E5BD8`, `sky #5AA8F5`, `blue #1F5FCC`, `mint #7ED6A0`, `leaf #3E9E5C`, `brown #A0673D`, `tan #D9A877`, `cream #FFF3D6`.

Any other string is passed through as a CSS colour. Swift parses CSS colours, including the full named-colour table and `transparent`, in `ScreenDrawingCSSColor` (OBSERVED colour table in `BIN`).

Edit colour words (`normColor`): yellow, gold and golden map to sun; purple to violet; green to leaf; light blue and skyblue to sky; navy to blue; black to ink; gray to grey; beige to cream; rose and magenta to pink; salmon to peach; lime to mint; teal and turquoise to fixed hexes. `darker()` maps each tone to a deeper neighbour, for example coral to red, or scales an arbitrary hex by 0.62.

**Clicky's ink** is the user's cursor colour. Swift passes it to `beginStream({ink})`; the default is `#3380FF`. It is accepted only as `#RRGGBB` and upper-cased. Pieces compute per-ink palettes:

| ink | gel top / mid / low / rim | paper card / news / print | title-bar wash |
|---|---|---|---|
| `#3380FF` blue | EDF4FF / A2C7FF / A2D2F7 / 221898 | EFF2F6 / E8ECF1 / E9EEF4 | `#0F7FFF` @ 0.08 |
| `#FF4C4C` red | FFF1EF / FFB8B0 / FFC8C0 / 7A1E1E | F9EFEA / F2E7E2 / F5E9E4 | `#FF5A4C` @ 0.08 |
| `#D4A017` yellow | FFF8E2 / FFDF8A / FFE9A8 / 6E4E00 | FAF5EA / F3EEE4 / F4EEDF | `#FEEA3D` @ 0.12 |
| `#26C281` green | EFFBF2 / C9F0CF / B4E8C5 / 17603F | EFF4EB / E7EEE3 / E9F1E5 | `#26C281` @ 0.10 |
| other | mixes toward white 0.9/0.55/0.5, rim toward black 0.55 | cream mixed 5% toward the ink | ink @ 0.09 |

Fixed hexes:
- Free words on screen use `#FFFFFF` (light) and `#15171C` (dark).
- Pill words use `#FEFEFE` (off-white on purpose, so the canvas doesn't halo them). Gel words use `#15171C`.
- The shadow colour is `#1C1E24`.
- Screen-pen base halos (`NAT` `SCREEN_PEN_BASE_HALO`): white ink gets two navy halo bands (0.16 at width 7, 0.45 at width 3); `#15171C` ink gets two white bands (0.35 at 7, 0.85 at 3).
- 3D `figure()` uses a separate "real" palette (`REAL_TONES`); see the 3D doc.

---

## 7. Execution model and sandboxing

### 7.1 Statement boundaries (`statementEnds`, `statementScanner`)

The scanner walks the code once and tracks bracket depth, line and block comments, and string literals (single quotes, double quotes, backticks, with escapes). A boundary is placed after a `;`, newline or `}` at depth 0 only if all of these hold:
- there is more code after it;
- the next character is not one that continues an expression (`. ? : + - * / & | , ) ]`);
- the statement doesn't end with an operator or opener (`= + - * / & | , ( [ { : ?`);
- a `}` is not followed by `else`.

The streaming scanner caches boundaries for append-only input and only re-checks the last one (a trailing `} e` may still become `} else`). This keeps it linear: the code comment notes an earlier version that was quadratic, at 200 ms per attribution on a 12 KB program.

### 7.2 Source transform (`transform`)

Before execution, at each statement start:
- Top-level `const`/`let` are rewritten to `var`. This keeps bindings alive across streamed chunks and lets a later turn reuse a name that an earlier turn already declared.
- `function name(` where `name` is an API function is rewritten to `var name = function…`, so a helper with the same name as a drawing call shadows it.
- A 3D-part assignment (`const piston = f.cyl(...)`) gets a `__name3d("piston");` call inserted before it.
- A guard prevents rewriting the same statement twice when two starts skip comments to the same place (OBSERVED fix comment).

### 7.3 Runners

- **`runCode(code, w, h, {budgetMs, knownEnds})`** (whole program). The whole transformed program is wrapped in `with (api) { … }` and compiled with the `Function` constructor.
  - On a syntax error it compiles the longest parseable prefix of complete statements. The error reads "syntax error after line N: …".
  - On a runtime error it keeps the marks drawn so far. The error reads "code stopped at line N: … (kept the K marks before it)".
  - Returns the marks array with `.error`, `.says` and `.warnings` attached.
- **`Session(w, h, {budgetMs, incremental})`** (live).
  - Holds one persistent generator whose body is `with (__api) { loop { chunk = yield; try eval(chunk) } }`. Each update evaluates only the new delta, transformed.
  - A `SyntaxError` while not done means the statement is still incomplete: nothing happens, and it waits for more code.
  - Any other error switches the session to `'full'` mode. Every later update re-runs the whole prefix with `runCode`. The fallback reason is recorded.
  - `update(full, done)` resets when the input isn't append-only. It returns only the new marks, says and warnings since the last emit.
- **`attribute(code)`** → `[{s, e, n0, n1}]`. Returns one record per top-level statement giving its source offsets (`s`, `e`) and the first/last mark index it generated (`n0`, `n1`). Execution mirrors `live`, one statement at a time.
- **`exec(base, frag)`**. Runs `base` and then `frag` in one session with a 1200 ms budget (in-page) or the worker limit, and returns only the fragment's marks. Used by the `add` and `redraw` edits so the program's helpers are in scope.
- **`runnablePrefix(code)`**. Binary-searches for the longest prefix of complete statements that runs without error. Used when continuing a turn after a failed program.

### 7.4 Limits and determinism

- At most 2000 marks.
- A deadline is checked on every mark push when `budgetMs` is set ("the program ran too long"). An infinite loop that pushes no marks is not caught by this check.
- Up to 40 distinct warnings per run.
- Seeded `Math.random`, and a per-mark wobble RNG seeded from `(mark.id or '') + index`. The same program always wobbles the same way.

### 7.5 Web Worker sandbox (lab or browser hosts; `ENG` `WorkerRunner`)

- `live(spec, host, {sandbox:'worker', timeLimit})` runs the runner inside a Blob Worker built from the runner's own source text.
- Before running user code, the worker deletes or freezes these globals: `fetch XMLHttpRequest WebSocket EventSource WebTransport importScripts indexedDB caches BroadcastChannel Worker SharedWorker postMessage close setTimeout setInterval navigator location Request Response Notification FileReader FileReaderSync`.
- Messages: `init{w,h,budgetMs}` → `ready`; `run{id, code, done}` → `result{marks, says, warnings, error, mode}`; `exec`; `attrib`.
- Each chunk has a watchdog (default 1500 ms). On expiry the worker is terminated with "the drawing program ran longer than … and was stopped (kept what it drew before)". The in-worker budget is 0.8 × the limit.
- Only one job is in flight. A newer prefix replaces a queued one.
- Edits in a sandboxed drawing use a fresh throwaway worker per `exec` or `attrib`.

### 7.6 Native sandbox (the app)

OBSERVED in the `NAT` header (paraphrased): the program runs in JavaScriptCore without network or filesystem access, and the `__host*` functions are its only route into native code. The worker path is not used natively: there is no `Worker` in JSC, so `Stream` falls back to the synchronous Session. INFERRED from `NAT` `beginStream`: no `budgetMs` is passed, so the native per-chunk deadline is off. Any time limit must come from Swift, and the Swift side is UNKNOWN.

- Entitlement `com.apple.security.cs.allow-jit` (OBSERVED codesign).
- The user default `ClickyJavaScriptJIT` and the env var `JSC_useJIT` (OBSERVED strings) toggle the JSC JIT. INFERRED: a kill switch that lets the app run JSC in interpreter mode.
- **OpenClicky must add a hard wall-clock limit natively.** See the Rebuild plan.

---

## 8. Stream: layout, pacing and timing (`ENG` `Stream`, `Layout`, `Pacer`)

### 8.1 Pipeline per `update(code, done)`

1. Scan statement ends. Only code up to the last complete statement is run (all of it when `done`).
2. The runner returns new marks and new `say` lines.
3. `ingest` interleaves says and marks by index. Each say opens a line. Each mark goes through the layout check, gets its natural duration, and is logged.
4. Unpaced: marks are drawn immediately as a batch. Paced: marks are given to the Pacer, and a timer releases them when due.
5. New say texts are returned (and passed to `onSay`). The app sends them to the voice.

### 8.2 Line ownership rule

A `say()` claims every mark produced after it until the next `say()` appears. If a step draws marks before its first `say()`, those marks are attached to that first `say()`. A step containing no `say()` at all is merged into the preceding line. Marks from edits follow the same ownership rule.

### 8.3 Natural timing per mark (`natural`, at pace 1)

`penDur(len) = clamp(base + len/per, min, max)`.
- Engine default `PEN`: per 600, base 0, min 0.14 s, max 0.7 s.
- Native `SCREEN_PEN`: per 1400, base 0.25, min 0.3, max 1.4 s, ease `cubic-bezier(.35,.2,.55,.95)`, wash on, `washMaxArea 60000`.

`dur` is how long the ink animates. `adv` is how long until the next mark may start.

| kind | dur | adv |
|---|---|---|
| line | penDur(length). Dashed: min(0.9, 0.2 + len/900). Marquee: 0.55 | 0.7·dur (marquee 0.44) |
| arrow | penDur + 0.16 | penDur + 0.10 |
| circle / ellipse | penDur(π(rx+ry)·1.06), or 0.3 with no outline | 0.7·dur |
| rect | penDur(perimeter), or 0.3 | 0.7·dur |
| poly | penDur(closed length). Marquee tint: 0.55 | 0.7·dur (marquee tint 0) |
| path | penDur(length) for absolute paths, 0.4 for paths with relative commands | 0.7·dur |
| dot | 0.25 | 0.06 |
| highlight | 0.35 | 0.245 |
| text / label3d | 0.4 + 0.015·chars | 0.7·(0.35 + 0.012·chars) |
| image | 0.5 | 0.3 |
| window | 0.45 | 0.3 |
| molecule | 0.6 | 0.42 |
| stage3d / part3d | 0.35 / 0.65 | 0.12 |
| motion3d, camera3d, tick3d, turn edit | 0 | 0 |
| edit | estimate (section 10.3) | same |

`together:true` sets `adv = 0`. With `sequential` (native: on), every inked mark except fills and dots waits for the previous stroke to finish: `adv = max(adv, dur + 0.03)`. 3D copies and groups are exempt.

### 8.4 Pacer algorithm (speech-paced drawing)

Parameters. Engine defaults → native `SCREEN_PACING`:
- `wps` 2.6 words/s (estimate mode).
- `gap` 0.25 s between lines (0 when `continuous`).
- `lead` 0.08 s, `tail` 0.12 s.
- `minPace` (FAST) 0.35 → 0.8; `maxSlow` 2 → 1.4; `maxSpread` ∞ → 1.25; `rushPace` = FAST → 0.1.
- `sequential` → true.

Line times:
- `speech:'estimate'`: each line starts at max(its arrival, previous line end + gap) and lasts words/wps.
- `speech:'external'` (native): the host reports `lineStart(k, t)` and `lineEnd(k, t)`, or `spoken(nWords)` for continuous narration. An unknown end is estimated from words/wps. The minimum line length is 0.2 s.

Planning, for each line's group of items starting at the cursor:
- `ws = max(cursor, lineStart + lead)`, `avail = lineEnd − tail − ws`.
- `A` = sum of `adv` over all but the last item, `dl` = the last item's `dur`, `f = avail / (A + dl)`.
- A line that may still receive marks (not closed) caps `f` at 1.3.
- If `f < FAST`, the line is overloaded or began late. Both stroke time and gap time are compressed together (floor `RUSH`) so the drawing for that line finishes when its speech does and does not push back the following line.
- Otherwise the stroke pace is `min(f, SLOW)` and the gap spread is `f`. On a closed line whose `f > SLOW`, the gaps absorb the rest. Because the spread is capped at `maxSpread`, leftover time collects as one idle stretch after the line's last mark rather than as gaps between the parts of a single object.
- Each item gets a start time `t` and a pace `p`. The anim duration multiplier is `max(p, 0.35)`.

Release: `due(now)` releases items whose `t ≤ now + 4 ms`, in order. A timer is armed for the next due time. Items whose line is unknown (`line === undefined`) block everything after them.

Controls:
- `finishNow()` (rush): everything left is drawn now in order at pace 0.35, with gaps of 0.12·adv. The voice carries on.
- `pause()` holds the pen after the current stroke. Code keeps arriving. `resume()` replays held draws.
- `dropPending()`: when the user interrupts, marks not yet drawn are dropped for good. It returns the first dropped index, which becomes `keep` for `__turn`.
- `reopen(code)` accepts more code after done (a continued turn). `rebase(code, count)` restarts the runner on a good prefix after a failed program.

### 8.5 Pen flight before a mark (painter, paced live only)

Clicky's cursor flies to each mark. The first mark waits 0.45 s. A later mark whose centre is more than 110 units from the previous mark's centre waits `min(0.55, 0.2 + distance/2400)` s, and later marks never start before it lands. Invisible action dots and buttons don't fly.

### 8.6 Layout check (`Layout`, causal: it decides as each mark arrives)

- **Containers**: rect, circle/ellipse, closed poly and window shapes at least 36×22 in size, under 40% of the canvas, with an outline or a fill of at least 0.5.
- **Labelling**: a text labels the most recent container that contains its centre. The first 24 characters become the container's label.
- **Clash**: two labelled containers partly overlap when all of these hold:
  - the overlap (sampled on a 14×14 grid) is between 10% of the smaller shape and 80% of either shape;
  - they are the same kind and not polygons;
  - the size ratio is at least 0.2.
  So intended nesting, edge contact, badges on boxes and shapes of different kinds are fine.
- **Nudge**: on a clash, the later box is searched for the nearest free offset. Candidates are 8 directions in 8-unit rings up to 22% of min(W, H), plus "just past the other box" on each side. A spot must be:
  - inside the canvas with a 6-unit margin;
  - not clashing with any container, and overlapping no container by more than 12% of its own area;
  - free of strokes within 4 units;
  - not over 8% of earlier filled areas;
  - not covering 30% of any text.
  If found, the box moves and so do the following marks of the same step inside its old bounds. Lines and arrows move only their points near the box. The warning reads "moved a box dx,dy so it no longer covers the box "…"". Otherwise it warns about the overlap.
- **Opaque cover**: a filled shape (alpha ≥ 0.7) from a later step that covers 20–80% of a labelled shape is warned about.
- Edits feed the layout: `startOver` resets it, and `erase` forgets the erased marks.

---

## 9. The SVG painter (`ENG` `surfaceFor`)

This is the reference renderer. Natively, the same code runs against the `NAT` DOM shim and Swift reproduces its output (section 13).

### 9.1 Layers and IDs
- One root `<svg viewBox="0 0 W H">`.
- Groups in paint order: `#under` (fills and washes), `#main` (pen strokes), `#hl` (highlights), `#words` (text), plus a hidden `#__probe` group for measuring.
- `<defs>` holds the filters and pen masks. Element ids are prefixed per card (`cd<N>_`).

Filters in the defs template:
- `wash`: fractal-noise turbulence (base frequency 0.035, 2 octaves, seed 3) driving a displacement map of scale 3.5. It gives the soft uneven watercolour edge.
- `grain`: high-frequency noise used as an alpha mask for the pencil brush.

### 9.2 Stroke algorithm
1. Build the centreline.
   - Lines: Catmull-Rom (`catmull`); straight runs are sampled about every 4 units, at most 30 per segment; two-point lines are densified every 12.
   - `smooth:false`: hand segments (`handSegments`). Each edge is subdivided about every 5 units and bowed by a sine.
     - Default bow: random, up to min(3.2, 3% of length) × wobble.
     - `bow:'pen'`: 3% of the length in points, clamped to 2–7 pt (edges under 24 pt bow 3%), on a random side, scaled by 0.6–1.0.
     - `jitter` moves the corners by up to that many points.
   - Ellipses (`ellipsePts`): at least 28 points, a random start angle, 1.06 turns when outlined (the pen overshoots), radius modulated by 1.8%·sin 2a + 1.2%·sin 3a times wobble, plus a 2% outward drift.
2. Outline polygon (`outline`). The tapered pen is about half-width·pressure.
   - Pressure ramps from 0.35 to 1 over min(30% of the length, 5·size) at each end, with a ±3% sinusoidal swell (period about 44 units).
   - `taper:0` gives an even width with 8-step round caps (`evenOutline`).
3. Reveal mask. A `<mask>` contains the centreline as a white stroke 2·size + 4 wide with `pathLength=1`, a dash of `1 1`, and the `pen` animation. The filled outline path references it. Its duration is `penDur(centreline length)`.
4. Halo. If `PEN.halo` has an entry for the stroke colour, one or more halo copies of the outline are drawn under it (`data-halo='1'`).
5. Glow. If `m.glow = [opacity, radius]`, the ink path carries `data-glow="op radius"` and the app adds a blurred shadow in the ink colour.

Dashes: the smoothed centreline is cut into dash pieces (`dashes`). Each piece is its own masked stroke with taper 0.3 (or 0). The starts are staggered across `span = min(0.9, 0.2 + len/900)`.

Arrow heads:
- The direction is taken from the tip and the sample 6 points back.
- Each barb is `head` long at ±`headAngle`, drawn as one stroke with taper 0.4 (0 for the screen pen) after the shaft (the clock advances by the shaft's duration).
- Bend: a three-point Catmull through a midpoint offset perpendicular by k·length.
- An optional label in hand style sits 8 units above the midpoint and fades in after the head.

### 9.3 Shapes
- **rect**: sharp corners are hand-bowed and the pen runs a little past the start (min(6, 6% of the width)). Rounded corners use 7-point arcs.
- **poly**: the outline is either smoothed or hand-bowed.
- **path**: split at each `M`. Each piece is sampled at 40–400 points through `getTotalLength`/`getPointAtLength` (the app answers these). Relative `m` jumps are detected by sample-distance spikes. A degenerate piece becomes a small dot that pops. The wash uses the raw `d`.
- **fill** (`wash`): a path in the fill colour with `fill-opacity = fillAlpha`.
  - The wash filter applies when wash is enabled globally, the mark doesn't set `wash:false`, and the bounding area is at most `washMaxArea`.
  - Circle fills use a calmer wobble (0.5) and a different seed.
  - Animation: `fadein` 0.35 s, starting 0.18 s after the outline starts (immediately when there is no outline).
  - A marquee tint uses the `marquee` animation instead.
- **dot**: `<circle>` with `pop` 0.25 s.
- **highlight**: a quadratic-bowed band. The tone defaults to butter, opacity 0.72, multiply blend on non-sky surfaces. The `swipe` animation (0.35 s) runs from its left edge.

### 9.4 Text (`case 'text'`)
- Face selection (`faceFor`): Patrick Hand for every handwritten style (title is drawn at weight 600). `ui` uses the system font, `serif` uses Georgia/Times. If the host sets `__clickyCardType = true` (Library cards), everything except `ui` uses Barlow.
- Minimum size: 13 units, or 8 pt for `ui` (converted through units). A smaller size is raised with a warning.
- Wrap: when `wrap` or `fit[0]` is set and the text is one line, a greedy word wrap uses real glyph widths (`getComputedTextLength`, answered by Core Text).
- Multi-line text uses `<tspan x dy=size·lineHeight>`. When `fit`/`wrap` applies and `baseline` is auto, the block is vertically centred on y. `baseline:'alphabetic'` or `top:true` keeps the first baseline on y (the pieces' `__TOP` relies on this).
- Fit: while the bounding box exceeds `fit`, the size is multiplied by 0.92, down to min(8, min size). A warning fires if the text shrank below 70%.
- Knockout halo (section 9.6) via `stroke` and `paint-order: stroke`.
- Label dodge (`placeLabel`). Skipped for `place:false`, multi-line texts and editor repaints.
  - The text is first clamped inside a 4-unit margin.
  - If its middle band (20–80% of its height) hits another text, or shapes crossing its central band cover more than 20% of it, it tries 40 candidate offsets. These are 5 rings × 8 directions, stepping 35% of its width + 6 horizontally and 0.9 × its height vertically, sorted with vertical distance weighted 1.6. It takes the first free one.
  - A shape that fully encloses the label (its container) never pushes it. Halos, `tie` arrows and paper are ignored.
- Animation: `write`, duration 0.4 + 0.015 per character.

### 9.5 Images, windows, molecules
- `image` becomes a custom `<photo x y width height data-query data-radius data-rotate>` with `fadein` 0.5 s. The app finds and paints the photo.
- `window` becomes a custom `<window x y width height data-header data-title data-board data-bg data-tint data-tint-alpha>` with `fadein` 0.45 s. The app paints the chrome and board.
- Windows grow (`fitWindowsTo`). After each non-window mark is painted, its real box is compared with every window. The mark belongs to a window if:
  - it is tagged with `onWindow`, or
  - at least 40% of it is on the window, or
  - its centre is on the window, or
  - it is a row up to 120 tall that spans the window horizontally and starts within 48 units below its bottom.
  If the mark reaches past the window's padding, that side grows (never past the title bar or 2 units from the canvas edge). The window element's x/y/width/height change, so the app redraws it.
- Sources alignment: credit marks tagged `onWindow` move right to the window's content-left edge, and down below the lowest content plus max(24, pad).

### 9.6 Readable ink (`readableColour`, `knockoutFor`). Only on `surface:'none'`.
Skipped for `image window 3D highlight molecule edit` and for `role` `paper` or `key`.
1. **Ground**: the last card or filled shape (alpha ≥ 0.8) drawn under the mark's centre. Windows count with their live, possibly grown, box. Otherwise the brightness of an 8-unit band around the mark box (not its inside), sampled from the screenshot through `__lumFor`.
2. **Needed contrast** in relative luminance: lines 0.2; words 0.3 on light grounds (> 0.58) and 0.45 on dark ones.
3. If the contrast falls short:
   - A chromatic colour (channel spread > 40) keeps its hue. It steps darker on light grounds, or toward white on dark ones, in 5% steps from 10% to 85%.
   - Otherwise it becomes `#15171C` on light grounds; on dark grounds `#C9CDD4` for lightish words or `#FFFFFF`.
4. **Knockout**: words on a card or filled ground get a stroke halo in the colour actually under them (the card colour, blended with any tinted fills drawn over it), width max(5, 0.45·size). Lines passing behind therefore stop short of the letters. Exceptions: `role:'cheer'`, `under`, `knockout:false`.

### 9.7 Window grounds and surfaces
`noteGround`:
- Every window, and every fill with alpha ≥ 0.8, is pushed as a ground `[box, luma, cardColour?, order]`.
- Every hex fill with alpha ≥ 0.08 is also recorded as a surface for knockout blending.
- Only paper-role fills at full opacity give a card colour to match. Other fills lend only their brightness.

### 9.8 Tie snapping (`snapTie`)
When a `tie` arrow is first painted, the painter looks for the drawn text on the same row as the requested start: centre within max(text height, 20) vertically, starting on the near side, not a photo, tie or source. It takes the farthest-reaching such text, starts the arrow 8 units past its end (or before its start when pointing left), and re-aims at the box edge plus the gap.

### 9.9 Figure placement (2D side of 3D; `standStage`)
A figure's rectangle is checked against the screen in 64-unit tiles through `__busyFor`. A tile is busy above 0.02.
- If at least 8% of the tiles are busy, the figure stands on a card. It uses a pieces window when one is available (`__card3d`), otherwise the stage's own paper.
- A figure placed on a program's paper window stands on that window, whose board becomes plain.
- In Stream mode (`__figuresFloat()`), figures always float.
- The stage ink is `__inkFor` over the rectangle when the figure floats, and `ink` on paper.

### 9.10 Report and finish checks
`finish()` adds warnings for any element running off the canvas and for pairs of text boxes overlapping by more than 3×4 units. It de-duplicates warnings, keeps at most 14, and sets `report.duration`. Report shape: `{marks, errors[], warnings[], engine:'1.6', overlaps, duration, shapeOverlaps, nudged, covered, sandboxed, mode}`.

Per-mark placement: `placed[i] = [start, end]` in seconds since the card was created. `startsIn(i)` gives `[seconds from now until start, duration]`; sounds and buttons use it.

---

## 10. Live editing (engine 1.6 `Editor`)

### 10.1 Parts and the state text the brain reads (`describe`, `stateText`)
A **part** is one of:
- a run of statements under the program's own comment ("// Big bushy tail");
- one text mark;
- one piece call (a helper the program defined, or `graph`, `timeline`, `molecule`);
- a block of consecutive statements not separated by an empty line.

A blank line ends a section. A new step or turn starts a new part. Edit statements never belong to a part. Helpers defined before `codeStart` (Clicky's own pieces) are not listed.

Descriptions come from, in order: the heading comment plus any trailing comment, "highlight behind "…"", the piece name with its first string argument and screen zone (for example `top-left` or `centre`), or a kind summary.

`stateText` output, line by line (OBSERVED formats, paraphrased):
- A header: card size and axis convention, an optional "Asked for" request quote, and a status. Status is one of: finished, paused mid-way, still being drawn, or a host-supplied status. The native `state()` passes one that says the drawing is finished and fully on screen when continuing a turn.
- "Helpers the program defined (callable in code): …", listing up to 12.
- A note listing 3D figures by constant name and stage id.
- For each step: a "Step n" header, or "Turn t, step n" when several turns exist, plus what Clicky said in that step (up to 170 characters).
- One line per part: `  p3 <desc up to 70 chars> [x,y,w,h]: <mark list>`, with "(not drawn yet)" when its marks are pending. Mark lists:
  - piece calls: "N marks (mA–mB), also says "…"";
  - runs of identical marks: "3× dot coral (m4–m6)";
  - text: `text <style> <size> <tone>` plus the words.
- "Added by edits:" before the `x` parts.
- A footer: newest part, last changed, and what the user is pointing at.
- `maxChars` (native: 12000): when the text is over the limit, first parts list only their mark ranges, then the oldest parts are summarised in one line "(N older parts not listed: p1–p62)".

### 10.2 Ops (`core`, `apply`, `applyNow`)
| op | Semantics |
|---|---|
| `recolor` | `color`, `fill`, `line`/`tone`. A bare colour on a filled shape sets the fill, and the outline becomes `darker(color)` if it had its own tone. For 3D parts it changes the material colour. Repainted (section 10.3). |
| `restyle` | Text: `style`/`font` (aliases handwriting, rounded, bold, plain, sans, typewriter, code), `size` 13–72, `weight`. Shapes: `width`/`size` 1–14, `dash` (sets `__dash` on closed shapes), `brush`. 3D labels: size 15–28. |
| `move` / `moveTo` | Glides each mark's `__xf` by dx, dy, or so the group's centre lands at x, y, then keeps it on the card. |
| `scale` | k is clamped to 0.25–4, and never grows a thing past the card. With `each !== false`, each separate cluster scales in place: marks whose boxes touch with 6% slack form one cluster. 3D parts change `scale3` instead. |
| `erase` | Un-draws the targeted marks in reverse order, newest first. Text and fills fade out. |
| `redraw` | Runs `code` after the program, erases the target and paints the new marks at the same depth. A single part keeps its id through an override map. |
| `add` | Runs `code` and paints the result as a new part `xN` on top. |
| `highlight` | Per cluster: words get a marker band (pad 6×2); thin line clusters get a 13-wide marker trace at α 0.5 along their points; anything else gets a loose ellipse 12% bigger + 12, wobble 1.6, width 4.5. Default colour coral. Creates part `xN`. |
| `startOver` | Erases everything before this mark with the brisk stagger. |
| `undo` | Pops a closure from the history stack that restores the snapshot (style fields, `__xf`, erased flags) and repaints. |

Program edits (`applyNow`) affect only marks before the edit's own index. This is a fix: a follow-up that erased "p1" and redrew in the same spot had erased its own new card. Unknown ids throw "unknown id …". If nothing is left to change, the op errors. The error is reported as a warning such as "erase("p3") changed nothing: …" and recorded in `m.__result`.

### 10.3 Edit timings
- Erase: 0.4 s per mark, staggered min(0.05, 0.5/(n−1)). Brisk (startOver, drops): min(0.03, 0.3/(n−1)).
- Repaint: re-runs `paint` at 0.55 pace with the mark's original seed, so it wobbles identically, at the same z-order (`placeByKey`). Old strokes are lifted after the new ones finish; text, dots, molecules and highlights cross-fade instead.
- Glide: 0.5 s, ease `cubic-bezier(.455,.03,.515,.955)`.
- Highlight op: 0.6 s. Empty ops: 0.05 s (0.02 for startOver).
- `planMark` estimates each edit when it arrives (`__est`), so the pacer can budget it, and tells the layout what is gone.

### 10.4 Card interaction (used by the app's drag handles)
- `cardsNow()`:
  - Card marks are: `role` paper or photo, any non-source image, or 3D (3D excluded from dragging).
  - Card marks that touch (2-unit slack) are grouped into cards.
  - Each other visible mark rides on the smallest card under it: its centre is on the card with 12-unit slack, or (if it is not a pointing mark) at least 40% of it is on the card.
  - Tie arrows never ride.
  - Each card reports its window chrome: `{mark, box, header, scale, zoomed, title, has3D}`.
- `moveMarks(ms, dx, dy)` applies an instant translate and remembers the set as a user card, so it never merges with what it was dropped on.
- `zoomMarks(ms, [k, dx, dy] | null)` is full-screen and restore, a 0.4 s glide.
- `dropMarks(ms)` closes a card; a 3D stage takes its parts with it.
- `keepNotesOnly()`: called when what lies beneath a completed drawing has changed. Screen-pointing marks are removed, while cards and their contents remain. If there are no cards it returns `kept:0`, and the host clears everything.
- `dropPointing()`: the screen changed mid-answer. Only pointing marks go.
- Pointing roles (`POINTING_ROLES`): `point target hover type ring frame underline check cross strike scroll label num connect trace`, plus every `highlight`.
- `inkCount()` counts drawn marks excluding invisible host dots. `visibleCount()` includes them.

---

## 11. The native bridge (`NAT`)

### 11.1 DOM shim
- `Element` supports `tagName`, `attributes`, `childNodes`, `style` (a Proxy recording camelCase props), `dataset`, `appendChild/insertBefore/removeChild/remove`, `textContent`, `querySelector(All)` (`#id` or tag only, comma lists), `innerHTML` setter (a tiny well-formed-tag parser used only for the surface template), `classList`, `ownerSVGElement`, and `getAttribute/setAttribute/hasAttribute/removeAttribute`.
- Geometry is answered by the host:
  - `getBBox()`: text goes to `__host.textBox(JSON textDescription)`, a path to `pathBox(d)`, a circle is computed locally, a group is the union of its children.
  - `getComputedTextLength()` goes to `textWidth(family, size, weight, text)`.
  - `getTotalLength()` and `getPointAtLength(l)` go to `pathLength(d)` and `pathPoint(d, l)`.
- `document` provides `createElementNS`, `getElementById`, and `fonts.ready`.
- Globals: `window` and `self` are global. `performance.now()` is `__host.now()·1000`. Timers: `setTimeout`/`setInterval` go to `__host.schedule(id, seconds)`, Swift calls `__fireTimer(id)` back, and `clearTimeout` goes to `__host.cancel(id)`. `console` goes to `__host.log`.
- Animation parsing: a `style.animation` string `"name dur delay timing both"` is parsed into `{name, dur, delay, fn:[x1,y1,x2,y2], at: host now}`. Keywords `linear`, `ease`, `ease-in`, `ease-out` and `ease-in-out` map to their standard cubic Béziers.
- Dirty tracking: the "unit" is the element directly under a render group (`under/main/hl/words`) or under `<defs>`. Any change marks its unit dirty. After an element has been sent (`__sent`), changes become patches instead of rebuilds:
  - opacity → `prop opacity`;
  - `strokeDashoffset` on a mask path → `prop dash`;
  - `animation:none` → `stop`;
  - a `<g>` transform → `prop transform`;
  - moving a sent unit into a fresh `<g>` → `wrap`.

### 11.2 `__host` functions (Swift → JS context). OBSERVED names in `NAT` and `BIN`.
| Function | Signature (INFERRED types) | Purpose |
|---|---|---|
| `now()` | → seconds (CACurrentMediaTime base) | engine clock |
| `schedule(id, seconds)` / `cancel(id)` | | timers; Swift calls `__fireTimer(id)` |
| `log(message)` | | diagnostics |
| `textWidth(family, size, weight, text)` | → number | advance width via Core Text |
| `textBox(json)` | → `[x, y, w, h]` | box of a `<text>` description (font, anchor, baseline, lines) |
| `pathLength(d)` / `pathPoint(d, len)` / `pathBox(d)` | → number / `[x,y]` / `[x,y,w,h]` | SVG path measurement |
| `inkFor(x, y, w, h)` | → `'#FFFFFF'` or `'#15171C'` | readable free-ink colour over that screenshot region |
| `busyFor(x, y, w, h)` | → 0..1 | how much text or controls are under a region |
| `lumFor(x, y, w, h)` | → 0..1 or −1 | mean luminance of a screenshot region (−1 when unknown) |
| `figuresFloat()` | → bool | Stream mode: 3D figures float |
| `shape3d(kind, recipe)` | | warm the 3D kernel (3D doc) |
| `caption(json or '')` | | debug subtitle chips (section 13.4) |
| `markSound(i, json)` | | the sound recipe for mark i |
| `buttonReady(i, delaySeconds)` | | show the real button for mark i |

Globals that `NAT` sets for the engine and pieces:
- `__clickyInk`, `__canvasUnitPoints`.
- `__inkFor`, `__busyFor`, `__lumFor` (proxies), `__figuresFloat`, `__shape3d`.
- `__hostDrawsPointers`, `__hostDrawsButtons`, `__hostDrawsWindows`, `__hostDrawsMarquee` (all true).
- `__clickyInTick3d`.
- `__clickyMotion(items, at, dur, ease)`: edits declare a whole tween once instead of per-frame style changes.
- `__hideLoneSources` is set by the app (OBSERVED string in `BIN`).

### 11.3 `clickyCanvas` API (JS → called by Swift). OBSERVED method names in `BIN`.
| Method | Args → return | Behaviour |
|---|---|---|
| `setPieces(source)` | → true | Stores the pieces source. It is prepended to every program. |
| `beginStream({w, h, width, subtitles, ink})` | → true | Clears; sets ink, scale and `SCREEN_PEN`; opens `ClickyDraw.live` with `pace:'speech', speech:'external', codeStart = pieces.length+1` plus `SCREEN_PACING`. |
| `feed({code, done})` | → analysis JSON | Runs `pieces + earlierCode + code`, starts heard lines in the engine, and analyses the complete statements (cached per program). |
| `line(k)` | → bool | Voice started line k. Ends the previous line if its length is unknown, releases the earlier beats' buttons, and refreshes subtitles. |
| `lineLength(k, seconds)` | → bool | Audio length of line k, which becomes the engine's `lineEnd`. |
| `finish()` | → bool | Narration done. Ends the last line and releases all buttons. |
| `isFinished()`, `now()` | | |
| `timeline()` | → JSON `{lines:[{k,text,start,length}], statements:[{label, line, state:'waiting'|'drawing'|'done', first, end, drawnMarks, marks}], frames:null}` | diagnostics |
| `state()` | → string or null | The card state text for the brain (`drawnOnly`, maxChars 12000). |
| `continueStream({subtitles})` | → JSON `{firstLine, marks, code}` | Keeps the card for a new turn (section 11.5). |
| `keepNotesOnly()` / `dropPointing()` | → JSON | section 10.4 |
| `cards()` | → JSON `[{box:[x,y,w,h], marks, units:[node n], window}]` | Draggable cards and the painted unit numbers that follow the pointer. |
| `closeCard({marks})` → `{closed, left}`; `zoomCard({marks, to})`; `moveCard({marks, dx, dy})` | | user card actions |
| `buttonSpot({box, gap, avoid})` | → `[x,y,w,h]` | Moves a real button off the drawing's words: down first, then up, then sideways (sideways counts double); photo and button text is ignored. |
| `markBox({i})` | → `[x,y,w,h]` or null | where mark i really is now |
| `tick3d({stage, ticks, dt})` | → Float32Array | 3D (see the 3D doc) |
| `renderWhole({w, h, width, code, ink})` | → report JSON | Renders a complete program in one pass using the engine's internal timing, with no voice (lab, replays). |
| `clear()` | → true | |

**Analysis JSON** returned by `feed`:

`{lines:[string], actions:[{role, x, y, r, box, label, text, line, i}], marks, inked, picture, firstLine, error, warnings[≤5], pointingLines:[k], cardLines:[k]}`

- `actions`: one entry per `photo` (with `box` and `text` = query; the app starts searching as soon as it is written), per `link`, and per pointer or action role (`point target hover type copy open handoff button tourjob tourtuck tourasks tournotch tourfade`). The `line` field is the beat that triggers it.
- `inked`: marks excluding invisible host dots.
- `picture`: a real picture worth keeping in chat. True when there is a card mark other than a lone sources plate, or at least 3 free sketch strokes that are not pointing, text or highlight.
- `pointingLines` / `cardLines`: classify each beat as screen-pointing or card-drawing. When the screen changes during an answer, the app keeps narrating only the beats that are still valid on the new screen.

### 11.4 Buttons wait for their beat
A `button` or a linked `text` mark is queued when drawn. It is released (`__host.buttonReady(i, delay + 0.15 s)`) when every mark of its beat has been drawn, when the next line starts, or when the drawing finishes. A button never shows before the card it sits on.

### 11.5 Continuing a drawing (multi-turn)
`continueStream()` calls the engine's `continueTurn()`:
1. Drop pending marks.
2. If the old run fell back to full mode after an error, cut the program back to its runnable prefix and erase the marks past it.
3. Reopen the stream.
4. Compute the next turn number.

The kept code (without the pieces) plus `__turn(n, keep);` becomes `earlierCode`. The next `feed` sends only the new turn's code, and the line numbering continues from `firstLine`. Replaying `earlierCode + newCode` whole draws the same card, because `__turn`'s `keep` drops the same undrawn marks (`dropUndrawn`).

### 11.6 Sound recipes (`soundOf`; the player is another subsystem)
Each drawn mark sends `markSound(i, {texture, events:[{id, at, end?}], delay, dur})`.
- Textures:
  - `felt`: a stroke on the screen;
  - `pencil`: a stroke on a card;
  - `writing`: text that is not a pill;
  - `eraser`: an erase edit.
- Events:
  - from a mark's `snd` (`tape` at +0.12 s);
  - from roles: `type-keys`, `copy-tick`, `target-ping`;
  - from kinds: `build-3d`, `highlighter`;
  - from edits: `slide` (move/scale), `page-clear` (startOver), `highlighter`;
  - `pen-flick` near the end of an arrow;
  - `sfx` accents.
- Pill pops (`gel-pop`, `badge-pop`, `boing`, `button-appear`) come from the first gel layer's `snd`.
- The file names match bundled wavs (`badge-pop-1.wav`, `eraser-bed-1.wav`, …).

---

## 12. Render record format (`__drainRender`)

Swift calls `__drainRender()` after every call into the context and after every timer fire. It returns `''` when nothing changed, otherwise a JSON array of ops in this order:

1. `{op:'remove', n}`: a painted unit left the card.
2. `{op:'wrap', g, child}`: unit `child`, already painted, now sits inside a new group `g` (moved or scaled by an edit).
3. `{op:'set', group, before, node}`: a new or rebuilt unit. `group` is `'defs'|'under'|'main'|'hl'|'words'`. `before` is the node number of the already-painted sibling to insert before, or null to append. Defs (masks) are emitted first because paths refer to them.
4. Patches in order:
   - `{op:'prop', key:'opacity'|'transform'|'dash', value, n | mask}`;
   - `{op:'stop', n | mask}`: jump the animations to their end;
   - `{op:'motion', begin, dur, fn:[4], items:[{key:'opacity'|'dash'|'transform', from, to, n | mask}]}`. `begin` is absolute host seconds. A transform value is `[scale, tx, ty]`; dash 0→1 runs the pen backwards.

`node` (serialised element):

`{n, tag, a:{attributes}, k?: mark index, anim?: {name, dur, delay, fn, at}, st?: {camelCase style props}, text?: textDescription, ch?: [child nodes]}`

`textDescription`: `{family, size, weight, anchor, baseline, x, y, lines:[{x|null, dy, text}]}`

Patch targets are `{n}` (node number) or `{mask: "<mask id>"}` for a pen-mask path.

Tags and the attributes the painter must honour:
| tag | attributes |
|---|---|
| `mask` (defs) | `id maskUnits x y width height`. Child `path` attributes: `d stroke stroke-width stroke-linecap stroke-linejoin pathLength=1 stroke-dasharray`, with anim `pen`. |
| `path` | `d fill fill-opacity stroke stroke-opacity stroke-width stroke-linejoin stroke-linecap stroke-dasharray mask=url(#id) filter=url(#wash)|url(#grain) transform data-halo data-glow data-marquee data-marquee-handle style(mix-blend-mode:multiply)` |
| `circle` | `cx cy r fill` |
| `text` / `tspan` | `x y dy fill font-family font-size font-weight text-anchor dominant-baseline transform stroke stroke-width stroke-linejoin paint-order data-knockout data-knockout-width` |
| `g`, nested `svg` | `transform`, `viewBox` |
| `photo` | `x y width height data-query data-radius data-rotate` |
| `window` | `x y width height data-header data-title data-board data-bg data-tint data-tint-alpha` |
| `scene3d part3d label3d tick3d motion3d camera3d` | `data-*` (3D doc) |
| `filter` children in defs | `feTurbulence feDisplacementMap feColorMatrix feComposite` (the painter implements wash and grain natively) |

Animation names, with INFERRED native meaning since their keyframes live in the host and Swift stores short strings inline:
- `pen`: mask stroke end goes 0→1 on the timing curve.
- `fadein`: opacity 0→1.
- `pop`: scale up from 0 about the centre.
- `swipe`: scale-x 0→1 from the band's left edge (`transformOrigin`).
- `write`: left-to-right letter reveal (`makeTextLayer` has a nested `Letter` type and returns pen strokes).
- `marquee`: the frame grows from its top-left corner.
- `grow`: a 3D part appears.
- `set`: instant.

Durations are already multiplied by max(pace, 0.35). All animations use fill-mode both: hidden before they begin, held after.

---

## 13. Swift side

The `BIN` is stripped, so type and field names come from Swift reflection strings and algorithms are INFERRED from the JS contract. Source paths are OBSERVED as `leanring-buddy/ScreenDrawing/Native/*.swift`.

### 13.1 `ScreenDrawingNativeEngine`
- Owns a `JSContext` and these fields (OBSERVED): `painter`, `context`, `timerTokens`, `screenshotPixels`, `screenshotSize`, `onCaption`, `onButtonReady`, `onRenderOps`, `pendingMarkSounds`, `lastAmbientSoundTime`, `lastAccentSoundTime`, `lastSoundTimeByID`, `onSoundsScheduled`. A nested type `MarkSound` holds `texture`, `events`, `fallbackBeginTime` and `fallbackDuration`; sound events hold `soundID`, `offset` and `fromEnd`.
- Load order (INFERRED from strings "clicky-draw-native", "clicky-draw-engine", "clicky-draw-pieces" and the error texts "native engine: the engine did not load" and "clicky-draw-pieces.js is missing"):
  1. Install `__host`.
  2. Evaluate `NAT`, then `ENG`. `ENG` defines `ClickyDraw` on the global.
  3. Call `clickyCanvas.setPieces(piecesSource)`.
- Error reporting: "native engine JavaScript error: …" and "engine error in program: …".
- Diagnostics: per-call timing statistics (`typicalMs`, p95, `worstMs`, `worstAt`).
- Screenshot pixels back `inkFor`, `busyFor` and `lumFor`. INFERRED:
  - `lumFor` = mean relative luminance of the region;
  - `inkFor` = white when that mean is dark, `#15171C` otherwise;
  - `busyFor` = a text/control density measure (edge or contrast density, or an accessibility-derived mask). The exact algorithm is UNKNOWN.
- Self test (OBSERVED program text in `BIN`): a two-beat program that draws a sun of rays, a tag, a sticky saying the canvas works, and an ink arrow. Failure messages mention capturing the screen and the Screen Recording permission.

### 13.2 `ScreenDrawingNativePainter` (Core Animation)
Fields (OBSERVED): `penStrokes`, `stageLayer`, `canvasLayer`, `groupLayers`, `canvasSize`, `pointsPerUnit`, `backingScale`, `maskDefinitions`, `unitLayers`, `lastMaskedContainerByGroup`, `generation`, `pendingMaskRemovals`, `maskRemovalTimer`, `containersByMask`, `glowContainersByUnit`, `stages3D`, `stageMemberOwners`, `stageMembers`, `onPenStrokes`, `onMarkTimings`, `onStage3DAdded`, `photoImageProvider`, `onStage3DRemoved`, `onStage3DTick`, `removesFinishedPenMasks`, `textShaper`, `washQueue`, `cardDragLayers`, `isolationHiddenLayers`, `fullScreenBackdrop`.

Nested types: `AnimationSpec`, `MaskDefinition`, `UnitResult`, `MarqueeBox`, `TextLine`, `TextLayout`, `TextGlow` (`radius origin shaped syntheticBoldStrokeWidth tightColor tightRadius wideColor wideRadius wideOffsetY bitmap center`).

CALayer marker keys (OBSERVED strings): `clickyGlowContainer`, `clickyGlowRadius`, `clickyMaskedContainer`, `clickyMaskID`, `clickyWrapper`, `clickyWindow`, `clickyEditTransform-`, `clickyEditOpacity`, `clickyEditStrokeEnd`, `clickyHasTransformMotion`, `multiplyBlendMode`, `photoArrives`, `penTurn`. The wash queue label is "com.humansongs.clicky.screen-drawing.wash".

Mapping (INFERRED; it is the contract any reimplementation must satisfy):
- Group layers `under`, `main`, `hl` and `words` sit under a canvas layer scaled by points per unit (y-down).
- Masked ink: the outline path is a `CAShapeLayer` filled with the ink. Its mask is a `CAShapeLayer` stroking the centreline with a `strokeEnd` animation 0→1 (`pen`), using `CAMediaTimingFunction(controlPoints:)` from `fn`, `beginTime = at + delay` on the media clock, and fill mode both. Consecutive strokes that share a mask container are batched (`lastMaskedContainerByGroup`). Finished masks are removed for performance (`removesFinishedPenMasks`, `pendingMaskRemovals`).
- Halo copies become sibling shape layers. `data-glow` puts the ink layer in a glow container whose shadow is the ink colour with the given opacity and radius in points.
- Wash fills: a turbulence displacement is computed off the main thread (`ScreenDrawingTurbulence`, `washQueue`, `pendingWashImages`) and the fill is swapped for a displaced bitmap. Areas over `washMaxArea` (60000) stay crisp.
- `mix-blend-mode:multiply` becomes a multiply compositing filter.
- `marquee` becomes `MarqueeBox`: the frame's dashed rounded rect and tint grow from the top-left over 0.55 s, with a spring per the code comment.
- `window` becomes `ScreenDrawingWindowChrome` (`Button`, `GrowthPart`; layer names `clickyWindowBorderLine`, `clickyWindowTitle`, `clickyWindowTitleBar`, `clickyWindowInside`). Boards are grid, dots or plain on `data-bg`, with a title-bar tint. Interactive close, full-screen ("Full screen") and pin ("Pin to the side of the screen") buttons appear on hover via `ScreenDrawingCardDragHandles`.
- `photo` becomes an image layer filled when `ScreenDrawingPhotoLoader` returns, with a corner radius and a rotation in degrees.
- Edits: `wrap` adds a wrapper layer; `prop transform` sets an affine `[k,0,0,k,tx,ty]`; `prop dash` sets the mask's stroke end; `motion` adds `CABasicAnimation`s with absolute begin times; `stop` removes animations and keeps model values.
- Reports pen strokes (`ScreenDrawingNativePenStroke`: `points`, `beginTime`, `duration`, `timing`, `lateResolver`, `endTime`) and mark timings (`ScreenDrawingNativeMarkTiming`) to the cursor and sound systems.

### 13.3 `ScreenDrawingTextShaper` (Core Text)
- Types: `ShapedLine`, `BitmapRun`, `FontMetrics`. Function `shape(_:font:key:) → ShapedLine` takes a `CTFont`, with a nested `SetGlyph`.
- Bundled fonts registered (OBSERVED in Resources and `BIN`): `ClickyDraw-PatrickHand.ttf`, and `ClickyDraw-Barlow-Regular`, `-Medium` and `-SemiBold` (Barlow under the OFL).
- Family resolution (OBSERVED strings): `patrick hand`, `barlow`, `system-ui` → `.AppleSystemUIFont`, `sans-serif` → Helvetica, `monospace` → Courier, `cursive` → Apple Chancery, `fantasy` → Papyrus, `georgia`, `times new roman`; emoji fall back to `AppleColorEmoji`. A missing font logs "native engine: font … .ttf is missing".
- Weight 600 or more on single-weight Patrick Hand is drawn as synthetic bold with a stroke (`syntheticBoldStrokeWidth`).
- Answers `textWidth` and `textBox`. It handles anchors and the dominant baselines `auto`, `alphabetic`, `middle`, `central`, `hanging`, `mathematical`, `text-before-edge`, `text-top`, `before-edge`, `text-after-edge`, `text-bottom`, `after-edge` and `ideographic` (OBSERVED strings).
- `TextGlow`: words in white or near-black loose on the screen get a two-level glow (a tight inner and a wide offset outer, pre-rendered to a bitmap) instead of CSS shadows. INFERRED from the `SCREEN_PEN_BASE_HALO` values.
- Words are revealed letter by letter for `write` (`makeTextLayer` returns the layer plus the pen strokes the cursor follows).

### 13.4 Captions
- `ScreenDrawingNativeCaption` (field `lastJSON`) draws the debug subtitle from `__host.caption(json)`: `{header:"beat k of N · t s / len s", text: line text, chips:[{label, state:'waiting'|'drawing'|'done', late}]}`. Labels come from `shortStatement`: the callee name plus its first quoted words (up to 33 characters), or "for loop". The subtitle refreshes every 120 ms while a line is heard. The preference is `ClickyScreenDrawingSubtitles`.
- `ScreenDrawingLiveCaption` (fields `currentWords`, `isShowing`, `hideWorkItem`) shows the spoken words. Preference `ClickyScreenDrawingVoiceCaptions`. The source of word timing is the voice subsystem (UNKNOWN detail).

### 13.5 `ScreenDrawingClock`
Fields `isLive`, `isPaused`, `origin`, `heldTime`, `events`, `nextToken`, `wakeTimer`; nested `Event`. INFERRED: it implements `__host.schedule`, `cancel` and `now` on `CACurrentMediaTime`, with a pausable offset (`heldTime`), and wakes the JS context with `__fireTimer`.

### 13.6 Helpers
- `ScreenDrawingCSSColor`: CSS colour parser.
- `ScreenDrawingSVGPath` (`Segment`, `Measure`, `NumberScanner`): parses `M L H V C S Q T A Z`, absolute and relative (INFERRED from path usage), and answers length, point-at-length and bbox.
- `ScreenDrawingUnitBezier`: CSS cubic-Bézier solver, used for the cursor following the pen on the same curve.

### 13.7 Cursor and pen
`ScreenDrawingPenCursor`, `ScreenDrawingPenCursorController` (`Stroke`, `Flight`), `ScreenDrawingPenFollower`, `ScreenDrawingPenHandoff`, and the flags `isScreenDrawingPenOnCanvas` / `isScreenDrawingPenBorrowed`. Clicky's cursor flies on an arc to each mark (matching the engine's flight wait, section 8.5) and rides the pen tip along each stroke's centreline with the stroke's timing. Cursor detail belongs to the cursor doc.

### 13.8 The canvas window (`ScreenDrawingCanvas`, `ScreenDrawingStaleWatch`)
- A transparent overlay per display. Log fields: visible, onScreen, screen, level, sharing (window sharing type).
- It ignores the mouse except over cards and buttons.
- `StaleWatch` watches for another app coming to the front, window moves, Space changes and the screenshot UI. On a change it calls `dropPointing()` (still narrating) or `keepNotesOnly()` (finished), or clears everything. Logs: "the screen changed under the drawing (…): its pointing marks left, the picture stays".
- `ScreenDrawingPinnedCards`: pinned and full-size card viewers. `ScreenDrawingActionButtons` (`ScreenDrawingActionButtonPanel`, a SwiftUI gel button): real buttons.

### 13.9 Photos (interface only)
`data-query` grammar, assembled in `PCS`:
- an optional `nopeople: ` prefix (skip hits showing people);
- then one of: `page: <url> :: <name>` (use the article's preview image), `web: <name>` (web search only), `favicon: <host>` (site icon, turned grey), or a plain `<name>`.

`ScreenDrawingPhotoLoader` downloads with a capped size, a redirect guard and public hosts only (OBSERVED "photo refused (not a public host)"), and uses the user agent "Mozilla/5.0 (Macintosh) HeyClicky". Search goes through the server's `image-search` (`ImageSearchAPI`; response keys `images[].source_url/full_url/thumbnail_url/page_url`, `subject_photo`). The request schema is UNKNOWN.

---

## 14. Look and style rules (consolidated)

1. **Ink is the cursor colour**: every mark that points at the real screen uses it. It glows softly in its own colour (65% opacity, 12 pt blur) with an even 3.5 pt line and round caps (`taper 0`), like the old walkthrough.
2. **Names are pills**: an Aqua gel capsule in the ink's pastel palette with a dark rim, white gloss and 12 pt semibold system-font dark words. Pills never overlap each other or the marks they name, and sit on the calmest nearby spot.
3. **Steps are numbered gel badges** (radius 9 pt, 700 weight digit).
4. **Regions are dashed frames** (8 pt on, 5 pt off) with a 7% ink tint, dragged open from the top-left like a selection.
5. **Rings hug their target**: pills for thin things, round for small things, rounded boxes for big ones. Each long side bends once, and the pen runs past the start.
6. **Paper only on calm space**: explanation cards are little Mac windows in a cursor-tinted matte paper tone with a grid, dots or plain board, a 28 pt title bar, a 24 pt pad and a 10 pt radius. Sticky notes and polaroids tilt −2° with tape in the gel tone. Cards step aside from 3D figures and from busy screen.
7. **Felt pen on paper, screen pen on screen**: paper strokes use the tapered felt pen and no glow; tie arrows are thin felt-pen arrows.
8. **Handwriting everywhere** (Patrick Hand); the system font only for pills, badges and buttons; Barlow for Library cards; Georgia for the "morning paper".
9. **Readable ink** (`__inkFor`, `readableColour`): free words choose white or near-black from the screenshot. Coloured ink keeps its hue but deepens or lightens until the contrast is enough. Words on cards wear a knockout halo in the card colour.
10. **Crisp versus watercolour**: fills get a turbulence-displaced wash, except pills, badges, paper and windows (`wash:false`) and large areas.
11. **Grey is the secondary text tone** (subtitles, labels, sources). The pieces' `ink` tone is a soft near-black (`#30333A`).
12. **One cheer at most**, only on a last beat and never on errors.

---

## 15. Timing and latency summary

| Item | Value |
|---|---|
| First ink after a statement completes | Unpaced: immediately (clock = now + 0.05 s). Paced: when its line is heard, + 0.08 s lead + the cursor flight (0–0.55 s; 0.45 s for the first mark). |
| Screen pen stroke duration | 0.3–1.4 s, 0.25 s + length/1400 |
| Line fitting | Stroke pace 0.8–1.4× natural, rushing down to 0.1× when crowded; gaps stretch up to 1.25× |
| Speech estimate (no host timing) | 2.6 words/s with 0.25 s between lines |
| Edits | erase 0.4 s per mark with stagger; glide 0.5 s; repaint at 0.55 pace; highlight 0.6 s |
| Button appear | after its beat's last mark ends + 0.15 s |
| Subtitle refresh | 120 ms |
| Worker chunk limit (lab) | 1500 ms (in-worker deadline 1200 ms) |
| Edit fragment budget (in-page) | 1200 ms |
| 3D tick budget | 8 ms per tick; stopped after more than 5 slow frames |

---

## 16. Permissions and entitlements
- **Screen Recording** (`NSScreenCaptureUsageDescription`): the screenshot is the canvas coordinate space and the source for `inkFor`, `busyFor` and `lumFor`. The self test fails without it.
- **Accessibility** (INFERRED): `StaleWatch` reads AX roles (`AXButton`, `AXWebArea`, … listed near it in `BIN`), and the `typeText` action needs AX.
- `com.apple.security.cs.allow-jit` for JavaScriptCore. The app is not sandboxed (`app-sandbox false`).
- Network client, for photos only. The JS context has no network.

---

## 17. Edge cases the code explicitly handles
- A partial statement while streaming: a parse error means "wait". A runtime error falls back to whole-program re-runs, keeping the marks drawn so far.
- A trailing `}` followed by `else` arriving later: the scanner re-checks its last boundary.
- The same statement reached from two comment-skipping starts is not rewritten twice.
- `const` redeclared by a later turn: handled because top-level `const`/`let` become `var`.
- A helper named like an API call shadows it.
- Edits can't touch marks the program draws after the edit, which protects a redrawn card.
- Marks erased before they were drawn are skipped (`__skip`). Un-erase can repaint them.
- A user interruption: undrawn marks are dropped and the same drop is replayed in whole renders (`__turn keep`).
- Too-small text is raised to its minimum. Over-long text is shrunk with a warning. Long URLs are shortened.
- Windows grow to hold overflowing rows and late sources lines. Sources align to the content's left edge.
- Labels dodge other labels and crossing shapes, but not their containers; paragraphs never move.
- Tie arrows re-snap to the real end of their row's words.
- Contrast: grey words on dark apps become a light grey, not invisible. Legend keys keep their exact colours.
- Buttons never sit on words (`buttonSpot`) and never appear before their card.
- A screen change mid-answer or after the answer keeps cards and drops pointing marks.
- Molecules without SmilesDrawer produce an error, not a crash.
- 3D figures never get paper laid over them; paper steps aside.
- Closing, zooming and moving cards keep their riders, and a moved card never re-merges.

---

## 18. Model and server slot mapping

The 2D engine itself calls no model. It connects to these slots:

| Part | Slot | Capabilities needed |
|---|---|---|
| Writing the drawing program | **brain** | A multimodal LLM with screenshot input (it places marks in screenshot pixel coordinates). Streaming text output, so code can be executed statement by statement. Long structured output (a JS block with beats). Follows a large API skill prompt. Receives `clickyCanvas.state()` text on follow-ups to edit by part id. Must produce `say()` lines early, because voice latency depends on it. |
| Speaking `say()` lines | **voice** | Streaming TTS or realtime speech per line, with per-line start events (`line(k)`) and the audio duration (`lineLength(k, s)`), ideally known before the line ends, so strokes can be fitted. Optional word progress for `spoken(n)`. |
| Photos for `photo()`/`image`/`source` | **other: image-search** | Web image search by name (Wikipedia or web), article preview by page URL, favicons by host, and a people/face filter. Server-mediated (`image-search`). |
| Seen/noted facts, lessons | none (the app parses program text) | |

---

## 19. Rebuild plan (OpenClicky)

Clean-room. Re-derive the algorithms from this spec. Do not copy HeyClicky JS.

### 19.1 JavaScript (run inside JavaScriptCore; also testable in Node or a browser)
1. `Draw/engine/runner.js`: statement scanner (append-aware), source transform, the `Session` incremental generator, `runCode` whole-program runner with prefix recovery, `attribute`, `exec`, `runnablePrefix`, seeded RNG, the 2000-mark limit and a deadline check.
2. `Draw/engine/api.js`: primitives (section 4.1), math helpers, `step`/`say`/`seen`/`noted`, edit calls, `graph`, `timeline`, `__inkBoxes`, `clearOfFigures`. Hooks for a separate 3D module.
3. `Draw/engine/geometry.js`: Catmull-Rom, densify, dashes, hand segments (default and pen bow, jitter), wobbly ellipse, tapered and even outlines, path sampling via host functions.
4. `Draw/engine/layout.js`: the causal box-clash checker and nudger (section 8.6).
5. `Draw/engine/timing.js`: the `natural()` table, the pen config (`setPen`), edit estimates.
6. `Draw/engine/pacer.js` and `stream.js`: speech pacing (section 8.4), line ownership, pause, resume, finishNow, dropPending, reopen, rebase, turns.
7. `Draw/engine/painter-svg.js`: the SVG emitter (sections 9.1–9.10): layers, masks, washes, text wrap, fit and dodge, knockout, readable ink, windows that grow, tie snapping, the report.
8. `Draw/engine/editor.js`: parts, the state text, ops and undo, cards, keepNotesOnly, dropPointing.
9. `Draw/pieces.js`: OpenClicky's own pieces with the same names and signatures (section 4.4–4.6) so the brain prompt can target them. Keep the per-ink palette table configurable.
10. `Draw/native/bridge.js`: DOM shim, timer shim, `clickyCanvas` facade, analysis JSON, button gating, sound recipes, `__drainRender`, `__clickyMotion`.
11. Tests: golden JSON for render ops of fixed programs. Determinism tests (same program gives the same ops). Pacer unit tests with a fake clock. Statement-scanner fuzzing against streamed prefixes.

### 19.2 Swift
1. `DrawingEngineHost` (≈ `ScreenDrawingNativeEngine`):
   - Owns `JSVirtualMachine` and `JSContext` on a dedicated serial queue. Installs `__host`. Loads bridge, engine and pieces.
   - Drains after every call and every timer.
   - **Hard wall-clock watchdog** on each `feed`. Options: a public `JSContextGroupSetExecutionTimeLimit` equivalent is not available, so run the context on its own thread and terminate or recreate it on timeout, or add loop-guards in the transform. Add a JIT kill switch too.
2. `DrawingClock`: media-time clock, pausable; schedule and cancel for `__fireTimer`.
3. `DrawingRenderOp` (Codable enum: remove, wrap, set, prop, stop, motion) and `DrawingNode` (tag, attributes, anim, style, text, children).
4. `DrawingPainterCA`: applies ops to a CALayer tree:
   - masked strokes with `strokeEnd` animation;
   - halos and glows;
   - multiply blending;
   - pop, fade, swipe, write and marquee;
   - wrappers and motions;
   - mask cleanup;
   - pen-stroke and mark-timing callbacks.
5. `DrawingTextShaper`: Core Text shaping, metrics, `textWidth` and `textBox` with anchors and baselines, synthetic bold, emoji fallback, per-letter layers, glow bitmaps. Bundle Patrick Hand and Barlow (both OFL; verify licences).
6. `SVGPathGeometry`: parse, flatten, length, point-at-length, bbox.
7. `CSSColor` and `UnitBezier`.
8. `WashRenderer`: turbulence noise and displacement on a background queue, with an area cap.
9. `WindowChromeLayer`: title bar, board (grid, dots, plain), tint, live resize on `set`.
10. `ScreenSampler`: a screenshot-backed `inkFor`/`busyFor`/`lumFor`. Define busy as the fraction of the region covered by text and controls; a first pass can use local contrast and edge density over 8–16 px tiles.
11. `DrawingCanvasWindow`: one transparent `NSPanel` per display. Click-through except cards and buttons. Choose the sharing type deliberately.
12. `DrawingCoordinator`: brain stream to `feed`; analysis lines to voice; voice events to `line` and `lineLength`; actions to the photo loader, typing, clipboard, open and hand-off; button gating; continue and clear; stale-screen handling.
13. `DrawingCaptions`: debug beat or chip subtitles and spoken-word captions.
14. `CardInteraction`: drag, close, zoom and pin handles from `cards()`.

### 19.3 Order of work
1. Runner + api + SVG painter in Node, with golden tests.
2. JSC host + bridge + CA painter for lines, shapes, text and dots.
3. Pacer + voice hooks.
4. Pieces (screen marking).
5. Windows and paper.
6. Readable ink and screen sampler.
7. Editor and follow-up state.
8. Cards, buttons, sounds and captions.

---

## 20. Unknowns
- The server-side drawing skill prompt (`worker/src/draw/screenDrawSkill.ts`), and how the brain's stream is split into the ```` ```js ```` program versus other output.
- Exact Swift algorithms for `busyFor`, `inkFor` thresholds, the native wash look and the `write` letter reveal.
- Whether the Metal `ClickyCanvas*` renderer or the Core Animation painter draws the live overlay in 1.1.2, and where each is used.
- Any native per-chunk execution limit for model code (none is set in `NAT`).
- The `image-search` request schema and its full path (relative name only).
