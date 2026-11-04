# Drawing contract (2D engine ⇄ 3D figures ⇄ native painter ⇄ voice)

This file fixes the interfaces between parts built on separate branches. Change it only in its own PR.

## The program
The brain answers a voice turn with a small JavaScript program written in OpenClicky's own drawing language, specified in
`docs/dsl.md` (2D) and `docs/dsl-3d.md` (3D). The program streams in, and the engine runs each top-level statement as
soon as it is complete. `say("…")` lines are spoken by the voice slot (see `SayLineExtractor`); `step(n)` groups what is
drawn while a line is spoken.

## Engine (`Resources/js/draw-engine.js`, owned by the 2D milestone)
Runs inside a JavaScriptCore context created by `DrawingEngineHost` (Swift). It has no network, no files and no timers
except the host-provided ones, and each statement has a time limit.

Global entry points the host calls:
- `__engine.begin(options)` starts a program. `options` is `{ canvas: {width, height, scale}, ink: "#RRGGBB", windows: [...], screenshotSize, pace: "speech" | "now" }`.
- `__engine.append(text)`: more program text arrived.
- `__engine.end()`: the program is complete.
- `__engine.lineStarted(index, seconds)` / `__engine.lineFinished(index)`: the voice started or finished `say` line
  *index* (0-based, the same numbering as `SayLineExtractor`). `seconds` is the expected spoken duration, if known.
- `__engine.finishNow()`: draw everything still pending immediately (the voice was cut off or skipped).
- `__engine.pause()` / `__engine.resume()`: the narration paused (a gap between lines, a stall) and carried on.
- `__engine.spoken(count)`: a running count of the answer's words heard so far.
- `__engine.cancel()`.
- `__engine.patch(ref, fields)`: the host's answer to a `request` event (below): merge `fields` into the mark that
  asked and repaint it if it is already on screen (`edit: "patch"`). See `docs/dsl-media.md`.
- `__engine.drain()` returns the events since the last drain (see below). The host polls it after every call and on each frame.

Plugins: `__engine.registerModule(fn)` takes `fn(api, ctx)`, which adds functions to the program's scope. `ctx` provides
`push(mark) -> mark`, `warn(message)`, `nextId(prefix) -> string`, `currentStep() -> number`, `canvas` and `ink`, plus
`request(mark, payload) -> ref` (ask the host for data a pushed mark needs) and `onPatch(fn)` (run after the host's
answer is merged into a mark). The 3D
milestone ships `Resources/js/figure-api.js`, which calls `__engine.registerModule(...)` to add `figure()` and its
companions. The 2D engine loads every `Resources/js/*-api.js` module after itself.

## Events drained by the host
Each event is a JSON object with a `type`:
- `{type: "marks", marks: [Mark]}`: new or changed marks to paint, in drawing order.
- `{type: "remove", ids: [String]}`.
- `{type: "step", step: Int}`.
- `{type: "warning", message}` / `{type: "error", message, statement}`.
- `{type: "ask", text}`: the user clicked a drawn button; its text becomes a typed follow-up turn.
- `{type: "request", ref, mark, …}`: a plugin needs data from the host for mark `mark` (a photo, a place, a quote).
  It is sent as soon as the statement runs, ahead of the mark's beat. Answer with `patch(ref, fields)`; an
  unanswered request is harmless. Media requests are described in `docs/dsl-media.md`.
- `{type: "action", role, payload, …}`, `{type: "note", kind, text}` and `{type: "sound", at, …}`: a drawing's
  actions, notes and sound recipes (2D detail in `docs/dsl.md`). Hosts that don't use them ignore them.
- `{type: "done"}`: every mark is drawn and every timed animation has started.

## Marks
Marks are plain JSON objects. Every mark has `id` (string), `do` (kind), `step` (Int), and timing `start`/`duration` in
seconds relative to the start of its step's line. The painter uses the timing to animate the pen reveal in sync with speech.
- 2D kinds (`line`, `arrow`, `text`, `box`, `circle`, `highlight`, `paper`, `badge`, `pill`, `button`, `graph`, …) are owned
  by the 2D milestone and documented in `docs/dsl.md`.
- 3D kinds start with `figure` or end with `3d` (`figure`, `part3d`, `motion3d`, `camera3d`, `label3d`, `tick3d`,
  `readout3d`). They are owned by the 3D milestone (`docs/dsl-3d.md`). The 2D painter never interprets them; it forwards
  them to a `FigureSink`.

## Native side (Swift, `Sources/OpenClickyKit/Drawing/DrawingContracts.swift`)
- `DrawingMark`: a mark as `JSONValue`, with typed accessors for `id`, `kind`, `step`, `start` and `duration`.
- `DrawingEvent`: a decoded drained event.
- `FigureSink`: implemented by the 3D milestone. It receives 3D marks and returns the `CALayer` to place in the canvas.
- `SpeechPacing`: the orchestrator reports when each `say` line starts and finishes playing.
- The painter (2D milestone) renders marks into a `CALayer` tree. Tests and screenshots render that tree offscreen to PNG.
