# Drawing language: guided steps

How an answer becomes one step of a walkthrough: the brain names the control the user should click (or rest the
pointer on) next, and the app waits for it and starts the next turn by itself. The calls live in
`Sources/OpenClickyKit/Resources/js/guided-api.js`, a plugin registered with `__engine.registerModule`. They draw
nothing: each pushes an invisible marker mark that the app reads when its line is spoken. The native side
(snapping, the click loop, triggers, draw-to-ask) is described in `docs/guided.md`.

1. **For the model**: the section between the `prompt` markers goes into the brain's instructions after the 2D
   language (`docs/dsl.md`).
2. **For the native side**: the marker marks.

---

<!-- prompt:start -->
## Walking the user through a task

When the user asks how to do something on screen, guide them one step at a time instead of listing every step.

- `task("Export the report as a PDF")`: name the task once, at the top of the first answer (repeat it in later steps).
- `target(x, y, w, h, "Export")`: the one control to click next, as a box around it (top-left corner, width, height)
  in screenshot pixels. If the turn lists the window's elements, `target("e12", "Export")` names one by id and is
  more exact. The app rings the real control, waits for the click, and then starts your next turn by itself with a
  fresh screenshot, so say only this step ("Click Export, top right.") and stop.
- `hover(x, y, w, h, "Preview")`: the same, for something that reacts when the pointer rests on it.
- `waitForUser("Type your name in the box")`: the next step is work the app can't watch (typing, dragging a slider,
  choosing by taste). The next turn starts once the user has done something and paused, or when they say "continue".

Rules:
- At most one `target()`, `hover()` or `waitForUser()` per answer, and never a target together with
  `waitForUser()`. One action per step.
- Only target things a single click (or hover) completes: buttons, menus and menu items, tabs, checkboxes, links.
- Typing is manual work. When the step is to enter text, use `waitForUser("Type …")` and show the field with
  `point()` or `region()`; don't `target()` the field, because the click alone would start the next turn while the
  user is still typing. Never put a click and typing in one step.
- You can still point with `point()`, `callout()` or `region()` in the same answer to show context.
- In a turn that started by itself (the notes say the user clicked the target or did the step), check the new
  screenshot first. If the step worked, give the next one; if it didn't, help them finish it.
- When the task is done, say so in one short sentence and use none of these calls. When the notes say no automatic
  steps are left, finish in words.

```js
task("Export the report as a PDF")
step(1)
say("First, open the File menu at the top left.")
target(66, 0, 50, 26, "File")
```
<!-- prompt:end -->

---

## Marker marks

The engine releases these like any other mark (at their line's beat); the painter draws nothing for them.

| `do` | Fields | Read by the app as |
|---|---|---|
| `target` / `hover` | `role`, `label`, `box: [x, y, w, h]` (canvas units = screenshot pixels), or `element: "e12"`, or `ring` (radius, with `at` the centre) for the `(x, y, r, name)` form; `instruction` from `{say: …}` | `GuidedMarker.target(GuidedTargetRequest)` |
| `task` | `label` | `GuidedMarker.task` |
| `wait` | `note` | `GuidedMarker.wait` |

Warnings: a second target in one answer is skipped ("one target() or hover() per answer"); a target together with
`waitForUser()` warns; an element id must look like `e12`.

`DrawingSession.onMarks` hands released marks to `GuidedWalkthroughController.apply(marks:)`, which arms the target
when its line is heard. `GuidedMarker(mark:)` decodes a single mark.

The classic tag grammar (`[TARGET:x,y,r:label]`, `[HOVER:…]`, 03 §6.1) arms the same targets through
`PointingTagParser` and `PointingVisual.guidedRequest`.
