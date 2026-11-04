# OpenClicky drawing language (2D)

The brain answers a voice turn with a short JavaScript program in this language. The program is spoken and drawn at
the same time: each `say("…")` line goes to the voice as soon as its closing quote streams in, and the marks after it
are drawn while that line is heard. This file has two parts:

1. **For the model**: the section between the `prompt` markers is written to be pasted into the brain's instructions.
2. **For the native side**: the marks the engine emits, its pacing rules, and its host interface. The contract between
   the parts is `docs/drawing-contract.md`; this file is the 2D detail behind it.

Engine: `Sources/OpenClickyKit/Resources/js/draw-engine.js` (core) and `draw-pieces.js` (screen and explanation pieces).

---

<!-- prompt:start -->
## Drawing on the user's screen

Answer with one ```js block. It is a small program that you speak and draw at the same time.

**Beats.** Split the answer into beats. Open a beat with `step(n)` and one short `say("…")` sentence, and follow it
with the marks that should appear while the user hears it. Keep each sentence under about 15 words. Put the most important mark
first in its beat. Two to six beats is typical.

**Coordinates.** The canvas is the screenshot you were given: `W` × `H` units, x to the right, y down, origin at the
top-left. Point at things where they are in the screenshot. Sizes of words and paper are in the same units; the
on-screen pen, name pills and number badges scale to the real display by themselves.

**Other screens.** With more than one screenshot, the turn notes say which one is the canvas. To draw on another one,
make `onScreen(n)` the very first statement (n is the screenshot's number); then `W`, `H` and every coordinate are that
screenshot's pixels. Leave it out to draw on the canvas.

**Ordinary JavaScript works**: `const`, arrow-function helpers, loops, arithmetic, `Math` (its `random` is seeded, so a
rerun gives an identical drawing). Programs can't reach the internet, files or timers, and each statement must finish
within a fraction of a second.

### Pointing at the screen (in Clicky's ink, which glows)
- `point(x, y, "name")`: ring an exact spot and name it. When the spot is an element from the turn's list, add
  `{element: "e12"}` and the user's pointer flies to that control too.
- `callout(x, y, "words", {side})`: words in a pill with an arrow to the spot. `side`: `"left"`, `"right"`, `"above"`,
  `"below"`, `"above-left"`, … (it picks a calm side if you don't).
- `region(x, y, w, h, "name")`: a dashed frame with a light tint around an area.
- `underline(x, y, w)`, `check(x, y)`, `cross(x, y)`: under words, a tick, an X.
- `pill(x, y, "name")`: a name in a gel pill (top-left at x, y; `{align: "center"}` centres it). Pills step aside
  from each other.
- `badge(x, y, n)`: a numbered step badge centred on x, y.
- `highlight(x, y, w, h)`: a highlighter band (yellow by default) behind words already on screen.
- `ring(x, y, w, h, "name")`: a loop around one control. `connect(a, b, {label})`: a curved arrow between two things.
  `trace([[x, y], …], {fill: true, label})`: a loop around an odd shape. `strike(x, y, w)`, `scroll(x, y, "down")`,
  `spotlight(x, y, w, h)` (dims everything else).

### Drawing with the pen
- `line(x1, y1, x2, y2)`, `line([x, y], [x, y], …)`, `curve([x, y], [x, y], [x, y])` (smooth through the points).
- `arrow(from, to, {label, bend})`: `bend: 0.2` bows it; `both: true` puts heads on both ends.
- `box(x, y, w, h, {label})`, `circle(cx, cy, r, {label})`, `ellipse(cx, cy, rx, ry)`, `dot(x, y)`.
  A `label` is written inside. Labelled boxes that would half-cover each other are moved apart.
- `text(x, y, "words", {size, align, wrap})`: crisp words, top-left at x, y. `write(x, y, "words")`: handwriting,
  written letter by letter. `\n` starts a new line; `wrap: 300` wraps at that width; `fit: [w, h]` shrinks to fit.
  `[label](https://…)` in the words makes a link the user can click.
- `path("M 10 10 C 40 0 80 0 100 30 Z", {fill})` (SVG path data), `poly([[x, y], …], {fill, label})` (closed).
- Options on any mark: `tone` (a colour), `size` (pen width or word size), `dash: true`, `fill: "sky"` with
  `fillAlpha`, `glow: false`, `name: "server"` (name the part for later edits).
- Colours: `dark grey white black yellow orange red pink purple blue sky teal green mint brown cream`, or `"#RRGGBB"`.
  Leave `tone` out to draw in Clicky's ink. Ink is adjusted automatically so it stays readable on light or dark screens.

### Explaining on paper (only on calm, empty space; never over the thing you are naming)
- `const card = paper(x, y, w, h, {title, board})` → the writing area inside the card (`card.x`, `card.y`, `card.w`,
  `card.h`). `board`: `"plain"`, `"grid"` or `"dots"`. Draw the explanation inside that area.
- `const g = graph(x, y, w, h, {x: [0, 10], y: [0, 100], xLabel, yLabel, grid: true})`, then `g.plot(x => x * x,
  {tone, label})`, `g.plot([[0, 1], [5, 9]])`, `g.point(3, 9, {label, guides: true})`; `g.at(u, v)` gives canvas
  coordinates for data values.
- `timeline(x, y, w, [[1990, "Web"], [2007, "Phones"]], {alternate: true})`.
- `button(x, y, "Show me an example")`: a button the user can click; its words (or `{ask: "…"}`) become their next
  question. End with one to three buttons when a follow-up is likely. `{open: url}`, `{copy: "…"}` or
  `{handoff: "task"}` make it open a page, copy words or start a background job; `button(photo, "Buy", …)` hangs it
  from the bottom of a card.
- `sticky(x, y, "words", "mint")`, `receipt(x, y, "Title", ["step", …])`, `clipping(x, y, w, "Title", "body",
  "site.com")`, `legend(x, y, [["red", "hot"], …])`, `sources(x, y, [["site.com", "Name"], …])`, `tie([x, y], photo)`
  (a thin arrow from a row of words to its picture).

### Doing things and noting things
These happen when their line is heard: `typeText(x, y, "words")` types into the field that has the caret (it can't
click, and never presses Return; use it only when the user asked you to type and the caret is in that field),
`copyText("…")`, `openPage(url)` (once per answer), `handOff({task, label})` (a background agent does it),
`sfx("tada")` (tada, ding, nope, stamp, sparkle, whoosh, boing, page-turn). These draw nothing: `seen("…")` (what the
user is doing), `noted("…")` (a lasting fact about the user; it is remembered), `plan("…")`, `lessonTitle("…")`.

### Every drawing call returns a handle
`{id, part, x, y, w, h, cx, cy, left, right, top, bottom}`, so you can attach things: `arrow([a.right, a.cy],
[b.left, b.cy])`. Helpers: `mid(p, q)`, `dist(p, q)`, `polar(cx, cy, r, degrees)`, `lerp(a, b, t)`, `range(n)`,
`measure("words", size)`.

### Changing what is already drawn
Each top-level statement that draws is one part: `p1`, `p2`, … in order (or the `name` you gave it). On a follow-up
turn you are shown the parts on the card, with the variable that holds each one in brackets: your new program continues
the same drawing, so those variables still work (`server.cx`). Edits happen while the line before them is spoken:
- `erase("p3")`, `erase("p3,p5")`, `erase("m12-m15")` (marks), `clear()`
- `move("p2", dx, dy)`, `moveTo("p2", x, y)` (centre), `recolor("p2", "red")`, `scale("p2", 1.5)`
- `restyle("p2", {size, style, dash, tone})`: words change size or face (`hand`, `title`, `ui`, `bold`, `mono`);
  strokes change width or dash
- `startOver()`: erase everything drawn so far and draw afresh
- `highlight("p4")`: mark an existing part with the highlighter
- `undo()`: take back the last edit

### Example
```js
step(1)
say("This is the Share button, top right.")
callout(1180, 52, "Share", {side: "below-left"})
step(2)
say("Your files live in this sidebar.")
region(20, 90, 230, 600, "Files")
step(3)
say("Here is what happens when you share.")
const card = paper(620, 300, 520, 330, {title: "Sharing", board: "grid"})
const you = box(card.x + 10, card.y + 30, 150, 80, {label: "You"})
const friend = box(card.x + 320, card.y + 30, 150, 80, {label: "Friend"})
arrow([you.right + 8, you.cy], [friend.left - 8, friend.cy], {label: "link"})
write(card.x + 10, card.y + 160, "They can view, not edit.")
button(card.x + 10, card.y + 230, "How do I let them edit?")
```
<!-- prompt:end -->

---

## Pacing (how the drawing follows the voice)

- **Line numbering.** `say` lines are numbered 0, 1, 2, … in the order their string literals appear in the program
  text, exactly as `SayLineExtractor` numbers them for the voice (comments, other strings, member calls such as
  `obj.say(…)` and template strings with `${…}` are not lines). A `say` inside a helper is numbered where the helper
  is written; when the helper runs, its marks join that line. A `say` that runs again (a loop) adds nothing new. A
  `say` whose words aren't a plain literal can't be spoken ahead of time; the engine warns.
- **Ownership.** Each mark is drawn during exactly one spoken line. Once a `say` has run, the marks that follow are
  drawn while it is heard. Marks that open a step, ahead of its first `say`, wait for that `say`; a step that never
  speaks lends its marks to the latest line. With no `say` anywhere, everything is drawn straight away.
- **Speech pace** (`pace: "speech"`, the default). A line's marks are held until the host reports
  `lineStarted(index, seconds)`. They are then laid out over the line: each mark has a natural pen time (`duration`)
  and a gap before the next mark may start; the engine stretches or compresses both so the line's marks finish just
  before the line ends (pen times run between 0.3× and 1.35× natural, gaps between 0.15× and 1.25×). While a line may still
  receive marks it is not stretched past natural speed. Without `seconds`, a line lasts its words at 2.6 words a
  second. `lineFinished(index)` closes the line; later marks for it are rushed.
- **Now pace** (`pace: "now"`): marks are drawn as soon as their statement has run, one after another.
- **`finishNow()`**: everything still held is drawn immediately at 0.35× natural time (the voice was cut off or
  skipped).
- **`pause()` / `resume()`**: the pen holds after the strokes already under way; program text keeps arriving and is
  run. The engine and the painter keep a drawing clock that is the host clock less the time spent paused, so marks
  paced after `resume()` land as if no time had passed (`DrawingSession.pause()` pauses both; the painter freezes its
  layer tree with `speed = 0`).
- **`spoken(count)`**: for a voice that reports a running count of words spoken (continuous narration) instead of line
  events: a line starts when the count passes its first word and finishes when it passes its last; line lengths come
  from the measured words-per-second (`DrawingSession.wordsSpoken(_:)`).
- **Who calls them.** In a push-to-talk turn `NarrationPacer` (`TurnOrchestrator`) watches the narration: a gap after
  a line (no next line within 0.3 s, while the brain still writes it or the voice still synthesizes it) or a stall in
  the line's audio (no progress for 0.35 s) pauses the drawing, and the next line or moving audio resumes it; the
  words heard so far (`CaptionWords` timing within the line, from `SpeechPlayer.position()`, never the line's last word
  before it ends) go to `spoken`. Always-on drawings (`RealtimeBrainDrawing`) begin in speech pace and are paced by
  the realtime reply as it plays: seconds of reply audio heard become a running word count, and what is left is drawn
  once the reply has been heard (or none came within 6 s).
- **Actions** (`typeText`, `copyText`, `openPage`, `handOff`, `sfx`) are invisible marks: when their moment in the line
  comes the engine sends an `action` event and the host acts (`DrawingActionPerformer`).
- **Natural times** (seconds, screen pen): strokes take `0.22 + length_in_points / 1500`, clamped to 0.25–1.2; an
  arrow adds 0.14 for its head; dashed lines `0.2 + length / 1000` up to 0.9; dots 0.22; crisp words 0.25–0.6;
  handwriting `0.25 + 0.045 × characters` up to 2.6; highlights 0.35; regions 0.5; pills and badges 0.32; buttons 0.3;
  paper 0.45; edits 0.3–1.2.

## Marks (what the painter receives)

Every mark has the contract fields `id`, `do`, `step`, `start`, `duration`, plus:
- `base`: host-clock seconds when the mark's line started (the painter animates from `base + start`).
- `line`: the say line index that owns it (−1 when the program never speaks).
- `part`: the part id (`p1`, …), and `name` when the program named the part.
- `turn`: the turn number on a kept card (2 and later).
- `xf: [k, tx, ty]`: uniform scale and translation applied by edits (canvas units).
- `edit`: set when an existing mark is sent again by an edit: `"move"` (glide to the new `xf`, scaling included),
  `"restyle"` (repaint in a new colour, size, face or dash), `"grow"` (a paper card that grew; `from: [x, y, w, h]` is
  its old box and the painter glides it out, keeping its place under what is drawn on it), `"patch"` (host data).

Lengths are canvas units; the painter multiplies by the canvas `scale` to get points. Colours are `#RRGGBB`.

| `do` | Fields | Painted as |
|---|---|---|
| `line` | `pts`, `smooth`, `tone`, `size`, `alpha`, `dash: [on, off]`, `glow: [opacity, radius pt]`, `segs` (several separate strokes), `closed` with `fill`, `fillAlpha` (polygons and closed paths), `role` | stroke revealed by the pen; a closed outline's wash fades in under it |
| `arrow` | as `line`, plus `head` and optional `tail` (three points each) | shaft, then the head |
| `box` | `at`, `w`, `h`, `r`, `pts` (hand-drawn outline), `fill`, `fillAlpha`, `outline: false`, `dash` | fill fades in under the pen outline |
| `circle` | `at` (centre), `rx`, `ry`, `pts`, fill fields | as `box` |
| `dot` | `at`, `r`, `tone` | pops in |
| `text` | `at` (top-left), `w`, `h`, `text`, `lines`, `lh`, `size`, `style` (`hand`, `title`, `ui`, `bold`, `mono`), `align`, `reveal` (`write` or `fade`), `halo`, `link` (http or https) | Core Text outlines; handwriting is wiped in left to right, line by line; linked words are underlined and clickable |
| `highlight` | `at`, `w`, `h`, `tone`, `alpha` | a band swiped in from the left, under everything |
| `region` | `at`, `w`, `h`, `r`, `dash`, `fillAlpha`, `tone`, `glow` | dashed frame and tint grown from the top-left |
| `pill` | `at`, `w`, `h`, `text`, `size`, `tone` (gel base), `color` (word colour) | gel capsule that pops in |
| `badge` | `at` (centre), `r`, `text`, `size`, `tone`, `color` | gel disc with the number centred |
| `button` | as `pill`, plus `ask` (the follow-up question), or `action` (`open`, `copy`, `handoff`, `card`) and `value` | gel button with a shadow; clicking it sends an `ask` event, or an `action` event for its action |
| `paper` | `at`, `w`, `h`, `title`, `board` (`plain`, `grid`, `dots`), `header`, `pad`, `paper` (sheet colour), `tone` | a little window card with a title bar |
| `graph` | `at`, `w`, `h`, `origin`, `grid` (segments `[x1, y1, x2, y2]`), `piece: "graph"` | faint grid (axes, ticks and labels are ordinary marks) |
| `spotlight` | `at`, `w`, `h` (the canvas), `hole: [x, y, w, h]`, `r`, `tone`, `alpha` | the screen dimmed except a rounded hole, under every other mark |
| `sticky` | `at`, `w`, `h`, `paper`, `tilt` (degrees), `text`, `lines`, `size`, `lh`, `tone` | a tilted square note with a folded corner, tape and its words |
| `figure…`, `…3d` | owned by the 3D milestone (`docs/dsl-3d.md`) | forwarded to the `FigureSink` |

Screen ink (marks not on paper) defaults to Clicky's ink at 3.5 pt, haloed in the same hue. Marks drawn on
a paper card use a thinner dark pen without glow. Free words on the screen get a thin halo in the opposite brightness.

## Layout and readable ink

- **Words on a card** (anchored on a paper card) wrap at the card's writing width plus half its padding, and shrink
  only when one word is wider than that room; words anchored at the card's edge step inward.
- **Cards grow** to hold what is drawn on them (a mark whose centre is on the card, whose top edge hangs from it, or
  that is mostly on it): the bottom, right or left edge moves out (never the title bar, never past the canvas). A card
  already on screen glides to its new size just before the mark that needed the room (an `edit: "grow"` mark).
- **Labels of lines and arrows** sit beside their stroke, never on it: above a flat stroke, to one side of a steep
  one, at the middle or sliding along it, wherever they cross no stroke or words and stay on the stroke's card.
- **Loose words** keep off words, pills and labels and off the strokes already drawn, and stay on their card. A later
  stroke that would cross loose words (or an arrow's label) moves them aside first (gliding if already drawn).
- **Names beside what they name.** `point()` and the other pieces measure the thing on the screen around the spot
  (the run of text and control edges it sits in, from `__host.busy`) and put the name pill beside the whole of it,
  never on it, with a short leader back to it. A later ring or callout that lands on an earlier name pill moves the
  pill aside (its leader follows). A region's name slides along the frame's top or bottom edge to a calm spot.
- **Time.** Placement that searches for spots stops searching once a statement has used more than half of its time
  limit (a loop writing dozens of labels keeps the spots it asked for instead of being stopped).
- **Labelled containers** (boxes, circles, regions and paper with a label or title) that would partly cover another
  labelled container (between 8% and 92% of the smaller one, and neither inside the other) are moved to the nearest
  free spot within 30% of the canvas, with a warning. Nesting is left alone.
- **Loose words** step off earlier loose words. **Pills, callouts and buttons** pick the calmest candidate spot: the
  least covered by earlier marks and, when the host knows the screen, by its text and controls (`__host.busy`).
- **Readable ink.** The ground under a mark is the last solid fill or card drawn there, else the screen brightness
  around it (`__host.lum`). Words need a 4:1 contrast (5.5:1 on dark grounds) and strokes 2.6:1. A coloured ink keeps its hue and steps darker
  or lighter; a grey ink becomes near-black or white. `contrast: false` keeps a colour exactly.

## Engine interface (beyond the contract)

`__engine.begin(options)` also accepts `keep: true` (keep the card for a follow-up turn: part ids continue, edits
can reach earlier parts and the program's variables stay; marks the last program never drew are dropped), `timeLimit`
(seconds per statement, default 0.4), `screen` (the 1-based number of the screenshot the host drew it on, which
`onScreen(n)` is checked against) and `afterError: "cut" | "skip"` (below). Other entry points:

| Call | Purpose |
|---|---|
| `runNext()` with `stepwise = true` | the host runs one statement per call so its watchdog limits each one |
| `recover()` | after the host's watchdog stopped a statement: report it and end the program there (below) |
| `click(id)` | the user clicked button mark `id` or linked words: an ask button queues `{type: "ask", text}` (`card: true` for a card button); open, copy and hand-off buttons and links queue `{type: "action", …, click: true}` |
| `patch(ref, fields)` | the host's answer to a plugin's `request` event: merges `fields` into that mark and resends it with `edit: "patch"` if it is already on screen (`docs/dsl-media.md`) |
| `describe(options?)` | the card as text for a follow-up turn: each part's id, name, kinds, words and box. With `{drawnOnly: true}` only marks on screen (and each part's program variable, in brackets; figure parts are left to the figure's own description); `maxChars` folds the oldest parts into one line |
| `cardsJSON()` | the cards on screen (paper, media cards, figures) and the marks riding on each, for the overlay's handles (docs/overlay-interaction.md) |
| `moveCard(ids, dx, dy)` / `closeCard(ids)` | the user dragged or closed a card: its marks move or leave at once |
| `dropScreenMarks()` | what lies under the drawing is no longer what it was drawn over: marks on no card go (also those still waiting for their line), cards stay; returns `{kept, dropped}` |
| `pause()`, `resume()` | hold the pen and carry on (above); `pausedTotal()` is the drawing clock's lag |
| `spoken(count)` | the voice has spoken `count` words of the answer so far (above) |
| `continueTurn()` | keep the card for a follow-up: marks never drawn are dropped for good, and JSON `{turn, keep, firstLine, marks, dropped, code}` comes back; `code` is the card's code so far (only the runnable prefix of a program that failed) with `__turn(n, keep)` markers, so replaying it whole draws the same card. Then `begin({keep: true})` |
| `reportJSON()` | the end-of-drawing report (below) as a JSON list of sentences; `[]` until the drawing is done |
| `summary()` | JSON `{lessonTitle, notes: [{kind, text}], actions}` |
| `beats()` | the line being heard for the debug captions: JSON `{line, of, text, elapsed, length, chips: [{label, state: waiting \| drawing \| done, late}]}`; a chip is one statement of the line, labelled with what it calls and its first quoted words |
| `lines()` | the say lines found so far, in `SayLineExtractor` numbering |
| `drainJSON()` | `drain()` as a JSON string |
| `sealGlobals()` | after loading modules: takes `__engine` and `__host` off the global object, freezes the language's own objects, and from then on removes globals created by programs at the next `begin` |

Host functions (`__host`, installed by `DrawingEngineHost`): `now()`, `log(message)`, `textWidth(text, size, style)`
(Core Text), `lum(x, y, w, h)` (mean relative luminance of the screen, or −1) and `busy(x, y, w, h)` (share of the
area covered by text and controls, or −1).

`__engine` and `__host` exist only while scripts load. Plugins must call `__engine.registerModule` at load time and
keep `ctx` for later; once sealed, the host reaches the engine through its own reference and program code reaches
neither (not through `globalThis`, `this` or `Function("return this")()`). Otherwise a program could click its own
buttons and start turns the user never asked for.

Plugins get the contract's `ctx` plus `ctx.onBegin(fn)` (called on every `begin`), `ctx.guarded(fn, ms)` (run
program code between statements, such as a figure's per-frame tick, with the runaway-loop guard armed for `ms`
milliseconds; `figure-api.js` uses it), `ctx.request(mark, payload)` and `ctx.onPatch(fn)` (data from the host;
`docs/dsl-media.md`) and `ctx.util`, the helpers the 2D pieces use. A plugin may push a 3D mark again under the same id (or push the same object again) to change it; the
engine re-sends it as a changed mark. Any other mark with a missing or taken id gets a fresh one.

## Events beyond the contract

- `{type: "action", role, payload, mark, at?, click?}`: `role` is `type` (payload: words; `at` the caret spot),
  `copy` (words), `open` (an http or https URL), `handoff` (`{task, label?}`) or `sfx` (a sound name). Sent when the
  line reaches the action, or at once with `click: true` when a button or linked words were clicked. Swift:
  `DrawingEvent.action(DrawingAction)`; `DrawingActionPerformer` acts (typing never presses Return and falls back to
  the clipboard; a spoken answer opens one page at most; clicks may always open).
- `{type: "note", kind, text}`: `seen`, `noted` or `lesson` (`plan` is kept in `summary()` only). The app saves
  `noted` facts to memory.
- `{type: "sound", at, dur, texture?, events: [{id, at}], mark}`: a sound recipe (below), handed over after the marks
  of the same drain.

## Sound recipes

Each released mark and edit has a recipe: a **texture** that lasts as long as the pen moves (`felt` for screen strokes,
`pencil` on a card, `writing` for words, `eraser` for erasing) and **accents** at offsets (`gel-pop` for pills,
`badge-pop`, `button-appear`, `paper` and `tape` for cards and notes, `tap` for dots, `highlighter`, `pen-flick` at an
arrow's head, `slide` for moves and growth, `page-clear` for `startOver()`, `type-keys` and `copy-tick` for actions,
`target-ping` for guided targets, and the `sfx()` accents). `DrawingSounds` synthesizes them in code (filtered noise
for textures, short tones for accents; no sound files); `DrawingSoundPlayer` plays them at their moment, one texture
at a time and accents at least 50 ms apart; `occtl draw … --sound out.wav` mixes a drawing's sounds into a WAV file.
The app plays them unless Settings → Voice → "Play drawing sounds" is off.

## Native side

- `DrawingSession` (main actor) wires a `DrawingEngineHost` to a `DrawingPainter` for the overlay. Program text goes in
  through `begin`, `append` and `end`. It is the contract's `SpeechPacing`, so the voice reports lines straight to it.
  It drains the engine about 60 times a second while drawing, and `click(at:)` turns a click on a drawn button into an
  `ask` event. Buttons count only once they have begun to appear. A late `done` from a drawing that was cancelled
  and replaced does not end the new one, and `clear()` also removes marks that were already on their way.
  `click(at:)` also opens linked words (`DrawingPainter.clickableID(at:)`); `pause()`, `resume()`,
  `wordsSpoken(_:)`, `continueTurn()` and `beats()` reach the engine calls above.
  `onMarks` sees the live drawing's marks as they are released (guided targets arm then; `docs/dsl-guided.md`), not
  ones still arriving after `cancel()`, `clear()` or a newer `begin`, and `patch(ref, fields)`
  answers a plugin's `request` event (`docs/dsl-media.md`).
- `DrawingEngineHost.withContext { context in … }` runs code on the engine's queue with its JavaScriptCore context. The
  3D milestone's `FigureTickBridge(context:)` runs a figure's ticks and readouts that way, once per frame, for
  `FigureStage.tickProvider` and `readoutProvider`.
- `DrawingRehearsal` plays a program against a simulated voice on a virtual clock and snapshots it with
  `DrawingSnapshot`. `occtl draw <program.js> <out.png> [--size WxH] [--at seconds] [--ink #RRGGBB] [--bg …]` uses it.
- Offscreen, with no window, hand the painter's layer to `DrawingSnapshot.adopt(_:)` before painting (rehearsals do).
  Core Animation strips the animations of layers outside any render context whenever a transaction is flushed.

## Limits

- 2000 marks per card; 40 distinct warnings.
- Positions and sizes must be numbers: a call given `NaN`, `Infinity` or a non-number where a coordinate belongs
  warns and draws nothing (points that aren't numbers are dropped from a line). Released 2D marks keep every number
  within ±100,000 units; paper is never larger than the canvas; a text mark holds at most 4000 characters, 200
  wrapped lines and a 400-unit size; a line at most 5000 points; a graph axis at most 100 ticks.
- Each top-level statement has a wall-clock limit (0.4 s by default). Loops and function bodies are rewritten with a
  guard that stops them at the limit; JavaScriptCore's execution watchdog (when available) stops anything else, such
  as code built with `Function(…)`.
- **Longest runnable prefix.** A statement that fails (it can't parse, throws, or runs past the time limit) is reported
  as an `error` and ends the program there: what that statement drew before failing is taken back, later statements
  only have their `say()` lines counted (so the voice's line numbering is unchanged), and `continueTurn()` keeps only
  the prefix, so replaying a kept card draws exactly what is on screen. One warning says the drawing stopped. Hosts
  that prefer to skip a failing statement and carry on begin with `afterError: "skip"`
  (`DrawingBeginOptions.continuesAfterErrors`).
- **End-of-drawing report.** When the drawing is done the engine checks what it drew: a mark running more than 2 units
  off the canvas, and words overlapping other words by more than 3×4 units, each become a warning (at most 14). The
  card keeps the list (`reportJSON()`, `DrawingEngineHost.report()`), and `describe()` ends with it ("Problems in this
  drawing"), so a follow-up turn is shown what to fix.
- **`onScreen(n)`** as a program's first statement draws on screenshot n instead of the canvas (the host reads it from
  the streamed text before the drawing begins: `DrawingScreenDirective`, `TurnOrchestrator`); anywhere else, or naming
  a screenshot the turn doesn't have, it only warns. A follow-up turn's canvas is the screenshot of the display its
  drawing is on, even when the pointer is on another one (`TurnInput.canvasIndex`).
- `fetch`, `XMLHttpRequest`, `WebSocket`, `EventSource`, `importScripts`, `require`, timers and workers throw; the
  context has no network or file access to begin with.
- The language's own objects are frozen and their global names fixed: `Object.prototype.x = 1`,
  `Array.prototype.map = …` or `globalThis.JSON = null` quietly change nothing, so one program can't break the engine
  or the programs after it. A program's own helpers may still reuse drawing names (`function box() {…}`).
