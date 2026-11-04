# Touching a drawing: buttons, figures, cards, follow-ups and the stale watch

OpenClicky's overlay sits above every app and ignores the mouse, so the apps underneath keep working. A drawing can
still be used. Drawn buttons ask their question. A 3D figure turns when dragged, and a click on a part asks about that
part. Cards (a paper, a photo or other media card, a figure) can be dragged by their body and closed with the close
box in their top-right corner. The next question sees the drawing still on screen and can change it. When the screen
changes under the drawing, the marks that pointed at it go away by themselves.

## Pieces

| piece | where | what it does |
|---|---|---|
| `DrawingDisplayCanvas` | `OpenClickyKit/Drawing` | One display's drawing: the live `DrawingSession`, its `FigureStage`, the pointer router and the media lookups. It continues the drawing for a follow-up (`drawing(for:image:continuing:)`), describes it (`describeOnScreen`) and handles a changed screen (`screenChanged`). The app's `OverlayDrawingSurfaces` keeps one per display. `CanvasDrawingSurfaces` wraps one offscreen canvas for `occtl overlay` and tests. |
| `DrawingPointerRouter` | `OpenClickyKit/Drawing` | Turns pointer events at a point on the drawing (the display's points, y down) into what they mean. It lists the regions that take the pointer (`regions()`: cards, figures, buttons that have started to appear), the target under a point (close box, then button, then figure, then the smallest card), the cursor (`hover`), and the outcome of a press. It needs no window. |
| `DrawingHandles`, `DrawingHandlePanel`, `DrawingHandleView` | `OpenClickyKit/Drawing` | Keep one invisible, borderless, non-activating panel over each region, one level above the overlay. Each panel's view maps its mouse events to drawing points and hands them to the display's router. It shows the router's cursor and draws a hovered card's close box. Clicks never activate OpenClicky or take focus from the app in front. The panels are synced 10 times a second, and the cards are re-read from the engine every 0.3 s. When the overlay steps aside for system UI (`AppModel.setOverlayHidden`), `isHidden` takes the panels off screen too. |
| engine card actions | `draw-engine.js`, `DrawingEngineHost.interact`, `DrawingSession+Interaction` | `cardsJSON()` lists each card and the marks riding on it. `moveCard(ids, dx, dy)` moves marks at once and keeps them on the canvas. `closeCard(ids)` removes marks at once; a figure takes its parts with it. `dropScreenMarks()` removes marks that ride on no card and keeps the cards. `describe({drawnOnly, maxChars})` gives the follow-up text. Only the host can call these: `sealGlobals()` keeps them out of program code's reach. |
| `DrawingStaleWatch`, `DrawingStaleMonitor` | `OpenClickyKit/Drawing` | Decide when the screen no longer matches the drawing, and watch the live screen for it. |

A **card** is a `paper`, a media card (`photo`, `place`, `stock`, …: marks laid out as containers, except `region`),
or a `figure`. Other marks ride on the smallest card under them: their centre is on it (12 units of slack), or at
least 40% of them is on it. A card at least 60% inside a bigger card rides on that card. Marks that ride on no card
mark the screen itself.

## The pointer

| over | cursor | press |
|---|---|---|
| a drawn button | pointing hand | Click (at most 4 points of travel, released over the button): the engine's `click(id)` sends `ask`, which becomes a typed turn. |
| a figure part | pointing hand | Click: `FigureStage` picks the part and names it: its label, its `name`, the program variable holding it (`__figure3d.nameOf`, wired as `variableName`), or its kind and material. The question "Tell me about the … in the 3D figure you just drew." becomes a typed turn. |
| a figure elsewhere | open hand | Drag (over 4 points): the figure turns. The turntable rests 2.5 s after you let go. |
| a card's body | open hand (closed while dragging) | Drag (over 4 points): the card's marks follow the pointer at once (`DrawingPainter.previewOffset`). On release the engine moves them, kept on the canvas. A card carrying a figure doesn't drag. |
| a card's close box | pointing hand | Click: the card and everything on it leave the screen. |

These thresholds are OpenClicky's own (4-point click and drag slop, 18-point close box inset 6 points). They still
need tuning on a real screen.

## Follow-ups

- At the start of each of the user's own turns (voice or typed), the orchestrator sets `TurnContext.drawingOnScreen`
  to `TurnDrawingSurfaces.describeOnScreen(for:)` for the turn's screenshot. That text is the parts actually drawn:
  ids, names, kinds, words and boxes. Each part also shows, in brackets, the program variable that still holds it.
  Then come the `describe()` lines of each figure on screen. The whole text is at most 12,000 characters, with the
  oldest parts folded into one line. The brain reads it under "Your drawing still on screen" in its turn notes.
- A turn is shown the drawing only when its program will continue it: the same display and canvas size, something
  drawn (`DrawingDisplayCanvas.continues`). A follow-up on another display, a walkthrough step and a job report start
  a new drawing, so they are shown nothing; otherwise the brain would edit parts its new drawing doesn't have.
- The user's own voice and typed turns, including a drawn button's ask and a figure click, continue the drawing:
  `continuingDrawing(for:image:)` returns the session on that display with `keep`. The engine keeps the card, its
  part numbering and the program's variables. Marks the last answer never got to draw (it was cut off) are dropped
  for good, and an erase that never happened leaves its marks on screen. A new screenshot size starts a new drawing,
  and so does each turn of a guided walkthrough or a job report.
- The prompt tells the brain to edit the drawing by part id. When the new answer is about something else, it starts
  with `clear()`.
- When the voice is done and the drawing still holds marks, `finishNow()` draws them at once. This covers marks waiting
  for a line that never came: a program without `say()`, or a line the narrator never started. An interruption
  (a new press, Escape, a typed question) still calls `cancel()`, so what wasn't drawn is dropped.

## The stale watch

The watch is armed each time a drawing starts on a display. It notes the front app and the front app's frontmost
ordinary window over the display (the CG window list gives bounds and owners without any permission). The drawing
is stale when:

| trigger | rule |
|---|---|
| the window moves, resizes or closes | more than 8 points |
| another window covers it | a new ordinary window covers at least 25% of the watched window's area on that display; windows already in front at arming don't count |
| the user scrolls it | at least 80 points of scrolling over the watched window (a global scroll monitor needs no permission; a wheel notch counts as 10 points) |
| another app comes to the front | any app except OpenClicky itself, such as the typed-question panel or Home |
| the Space changes | `NSWorkspace.activeSpaceDidChangeNotification` |

The monitor polls the window list 4 times a second. When the drawing goes stale, `dropScreenMarks()` removes the
marks that ride on no card, including those still waiting for their line, and the cards stay. With no card left, a
finished drawing is cleared. An answer still being drawn is never cut off by the watch (its voice is still talking):
its loose marks go, what it sends after the change is drawn, and when it finishes the same rule runs once more over
the whole drawing. A new answer started in the meantime is drawn for the screen as it is then, so that last pass is
skipped. HeyClicky keeps loose marks that don't point at anything. OpenClicky has no pointing roles on its marks, so
every loose mark goes.

## `occtl overlay`

`occtl overlay --out-dir d (--program p.js | --ask "words") [actions…]` draws on an offscreen `DrawingDisplayCanvas`,
the same way the overlay does. It then performs each action, in order, as synthesized `NSEvent`s on the handle panels
(`DrawingHandles(showsPanels: false)`, never shown). The actions are `--hover`, `--click`, `--drag`, `--click-button`,
`--click-part`, `--turn-figure`, `--drag-card`, `--close-card`, `--then "words"` (a typed follow-up through the real
`TurnOrchestrator`), `--stale nudge|move|cover|scroll|app|space` (a synthetic window list) and `--wait`. With
`--config`, the questions that clicks ask become real turns. After each step it writes `frame-N.png` with the handle
panels outlined, `state-N.txt` (what the next turn would read), `turn-N.txt` (each brain turn's words, the drawing
it was shown and its program) and `events.txt`. Run `occtl overlay --help` for the details.

## Not done

- No one has watched any of this on a live screen yet. Still unchecked: real clicks through the handle panels, the
  cursors (a background app setting the cursor), card dragging under a real pointer, the window server sending clicks
  to a nearly transparent panel, and the live stale monitor.
- There is no card zoom or pin and no full-screen card viewer (HeyClicky's card window chrome). Cards are dragged by
  their whole body, not a header.
- The pen cursor that rides along strokes (`overlay-pen`) doesn't exist yet.
- A click on a figure part becomes a plain typed turn. HeyClicky's turn tag for it (`figure_part` or
  `drawing_3d_part`) isn't known.
