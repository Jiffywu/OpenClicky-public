# Guided walkthroughs and draw-to-ask

Two ways the user and Clicky point at the screen together:

- **Guided walkthroughs** (03 §6.4, §6.5, §9; parity `point-guided`, `point-onebrain`, `point-tags`): the brain names
  one control per answer, the app rings the real control and waits for the click, and the click starts the next turn
  by itself with trigger `clicked_target`. Steps the app can't watch advance with `did_step`.
- **Draw-to-ask** (03 §5.4; parity `screen-draw-to-ask`): while the talk key is held, moving the mouse paints
  highlighter ink. The marks are described in words, the text and controls under them are read, and the result rides
  with that turn as `TurnContext.highlightDescription`.

Code: `Sources/OpenClickyKit/Guided/` and `Sources/OpenClickyKit/Highlight/`. The drawing-language side is
`docs/dsl-guided.md`. Coordinates are AppKit global points (y up) unless they say pixels (screenshot, top-left
origin).

## Walkthroughs

### Placing and snapping a target (`GuidedTarget.swift`)

`GuidedTargetRequest` is what the brain asked for: an element id, a box or ring in screenshot pixels, or a global
rect, plus a label, an instruction and whether it is a hover. `GuidedScreen` (the screenshot's `CaptureGeometry`
plus the front window's `ElementSnapshot`s, e.g. `GuidedScreen(look:)`) places it and snaps it:

1. An element id is used as is (`named`).
2. Otherwise `GuidedTargetSnapper.choose` picks among clickable controls. These are HeyClicky's snapping roles (button,
   menu item, pop-up, search field, incrementor, colour well, Dock item, link, menu button, radio button, disclosure
   triangle, switch, menu bar item, checkbox, text field, cell), plus tabs and combo boxes, and toolbar-button
   subroles. Containers and anything wider than 900 pt or taller than 600 pt are skipped. The choice, in order:
   - Controls containing the requested centre. The best overlap with the requested box wins, then the smallest, so a
     button inside a table cell beats the cell unless the box is the whole cell.
   - Controls overlapping the box by at least 30% (intersection over union).
   - The nearest control within 28 pt.
   At every step an enabled control beats a disabled one.
3. Otherwise `GuidedElementLocating` asks the live Accessibility tree what is at the centre (`hit_test`;
   `AccessibilityGuidedLocator`).
4. Otherwise the brain's own box is used, as a ring with a radius of at least 28 pt.
5. Grounding, when the config chooses a model for it (see "Grounding" below): a request whose element id isn't on
   screen is placed where the grounding model clicks, and an unsnapped box moves there when the model's point lies
   outside it (`grounded` when no control is there either).

A snapped target is drawn as the control's outline and hit-tested on the control's frame plus 6 pt. A ring is
hit-tested on its box or radius plus 6 pt. `GuidedTargetLayer` draws the outline or ring, a pulse and the name pill
for an overlay or an offscreen render.

### The loop (`GuidedWalkthrough.swift`)

A pure state machine driven by inputs and ticks with explicit times. Each call returns `GuidedEffect`s:
`showTarget`, `clearTarget`, `startTurn(GuidedTurnRequest)`, `refreshCapture` or `ended(reason)`.

| From | Event | Result |
|---|---|---|
| any | `arm(target)` | `armed`, `showTarget` (refused with `ended(max_rounds)` when no automatic steps are left) |
| any | `expectManualStep(note)` (`waitForUser()`) | `manual` |
| armed | click on the target (after the grace period) | `followingUp`, `clearTarget`, `startTurn(clicked_target)` |
| armed | the pointer rests 0.6 s on a hover target | the same, noted as "rested the pointer on" |
| armed | click elsewhere | `ended(off_target)`, quietly (configurable: `offTargetEnds`) |
| armed | another app or Space comes forward (not OpenClicky itself) | `ended(stepped_away)` |
| armed | 180 s pass | `ended(expired)` |
| manual | clicks, drags, keys, scrolls or app switches, then 1.2 s of quiet | `followingUp`, `startTurn(did_step)` |
| manual | 120 s with no activity | `ended(expired)` |
| followingUp | the user acts after the 0.6 s grace | `refreshCapture` once (re-capture before answering, with `GuidedWalkthrough.freshnessNote`) |
| followingUp | `answerFinished()` with nothing armed | `ended(completed)` |
| followingUp | no answer arms, finishes or stops it for 120 s (`followUpLimit`) | `ended(expired)` |
| armed/manual | `userTurnStarted()` (talk key, typed question) | `followingUp`, target cleared, walkthrough kept |
| followingUp after `userTurnStarted()` | `userTurnCancelled()` (the chord was brushed, nothing was heard) | back to the interrupted step: `showTarget` again, or `manual` |
| any | Escape or `stop()` | `ended(stopped)` |

The step counter (`completedSteps`, `status.step`) and the walkthrough log carry across steps. A new `task()` after a
finished walkthrough starts again at step 1. `maxRounds` (12 by default; HeyClicky's server-set value is unknown)
caps automatic turns.

A `GuidedTurnRequest` holds the trigger, the step just completed, the automatic steps left, and `[App]` notes for
the brain:
- what just happened, for example: the user clicked "Export", finishing step 2;
- how many automatic steps can follow;
- the walkthrough so far, oldest first.

`request.apply(to: &input)` empties the words, sets `context.trigger` to `clicked_target` or `did_step`, and puts the
notes first. `settle` asks for the after-action capture (`ScreenLookService.lookForTurn(afterAction: true)`).

### Hooks for the voice-loop orchestrator (`GuidedWalkthroughController`, `TurnGuiding`)

The voice loop's `TurnOrchestrator` drives both features through `TurnGuiding`
(`Sources/OpenClickyKit/Orchestrator/TurnGuidance.swift`). `TurnPointingGuide` implements it over a
`GuidedWalkthroughController` and a `DrawToAskSession`; the app's `PointingOverlayModel` wraps it with the live ink,
the target ring and the pointer monitor. What the orchestrator calls, and when:

| Moment | Call | Effect |
|---|---|---|
| Talk keys down | `userTurnStarted(voice: true)` (the app: `talkKeyDown()`) | ink starts; an armed step steps aside (`userTurnStarted`) |
| Talk keys up | `pressEnded()` (`talkKeyUp()`) | the gesture waits for this turn; the ink fades |
| Brushed chord, nothing heard, no speech connection, Escape while held | `userTurnCancelled()` (`talkCancelled()`) | marks dropped; the interrupted step comes back |
| Typed question | `userTurnStarted(voice: false)` | the step steps aside (no ink) |
| Before the request of a voice or typed turn | `prepare(&input, look:)` | `drawToAsk.attach(to:layout:)`: `highlightDescription` and the inked screenshots |
| The answer's drawing begins (not for job reports) | `answerStarted(on: look)` → `DrawingSession.onMarks` | `guided.screen = look.guidedScreen`; `target()`, `hover()`, `task()`, `waitForUser()` arm as their lines are heard |
| The answer was heard and drawn (completed or failed) | `answerFinished()` | a walkthrough whose answer armed nothing is `completed` |
| Escape | `stopWalkthrough()` | `ended(stopped)`; Escape is swallowed only while a walkthrough (or a turn, a drawing…) runs |
| The menu's Stop walkthrough | `TurnOrchestrator.stopWalkthrough()` | cuts off the walkthrough's own turn if one is being prepared or said (its answer can't ring a target again), then `ended(stopped)`; a turn the user asked for goes on |
| A press that cut off the walkthrough's own turn comes to nothing | `isAwaitingNextStep` | if no step was armed before the cut, that turn is asked for again (same trigger and notes, no second settle) |

The guide's `onRequest` goes back to the orchestrator: `.turn(request)` runs `runGuidedTurn(request)` (a `.guided`
turn with no words, `context.trigger` = `clicked_target` or `did_step`, the walkthrough's notes first, and the
after-action capture `TurnScreenLooking.lookAfterAction()`); it cuts off an answer still speaking (the cut-off note
says the user went ahead with the step) and is ignored while the talk keys are held. `.refreshCapture` runs
`refreshGuidedCapture()`: if nothing of that turn has been heard yet, it starts again on a fresh screenshot with
`GuidedWalkthrough.freshnessNote` (once per step). The system prompt carries the model-facing sections of
docs/dsl-guided.md and docs/dsl-media.md (`BrainPromptOptions.guidedSteps`, `.mediaCards`; copied by
`scripts/sync-prompts.sh`).

The controller underneath, for other hosts:

```swift
let guided = GuidedWalkthroughController(locator: AccessibilityGuidedLocator(frontApp: { tracker.current }))
guided.ownBundleIdentifiers = [Bundle.main.bundleIdentifier!]
guided.onTurnRequest = { request in            // or: for await request in guided.turnRequests()
    let look = await screenLook.lookForTurn(afterAction: request.settle)
    var input = TurnInput(words: "", screenshots: look.screenshots, context: look.turnContext(), appNotes: look.appNotes)
    request.apply(to: &input)
    startTurn(input)
}
guided.onEffect = { effect in overlay.show(effect) }  // showTarget / clearTarget → GuidedTargetLayer
guided.screen = GuidedScreen(look: look)              // before each answer's drawing
session.onMarks = { guided.apply(marks: $0) }         // target(), hover(), task(), waitForUser()
// key-down: guided.userTurnStarted()   press cancelled or nothing heard: guided.userTurnCancelled()
// narration done: guided.answerFinished()   Esc / Stop button: guided.stop()
// pointer monitor: guided.handle(.mouseDown(p)), .mouseMoved(p), .mouseDragged(p), .scroll, .keyDown, .appChanged(bundleID), .spaceChanged
```

The controller ticks itself every 50 ms while a walkthrough is active. `status` gives the HUD its text
("step 2 of at most 12 · Click Export"), and `isActive` says when a walkthrough can be stopped.

In the app (`Sources/OpenClicky/Guided/`):
- `PointingOverlayModel` owns the walkthrough and draw-to-ask (a `TurnPointingGuide`) and is the voice loop's
  `TurnGuiding`.
- `GuidedPointerMonitor` feeds the global mouse, drag, scroll, key, app and Space events while a walkthrough is
  active, including while a follow-up is prepared (so acting then asks for a fresh capture, and Escape stops). It
  only observes; global monitors can't change events.
- A brushed talk chord (the talk-key tap's `voiceCancelled`, through `TurnOrchestrator.pressCancelled()`) calls
  `userTurnCancelled()`, so the target comes back; so does a press where nothing was heard.
- Each display's overlay draws the ink and the target ring (`PointingOverlayLayer`) and a step pill: "Step 2 · Export
  a PDF · Click Export · Esc to stop".
- The menu bar shows the step and a **Stop walkthrough** item. Escape stops it too.

### The buddy pointer (`BuddyGuidance.swift`)

`TurnPointingGuide.buddy` decides when the buddy arrowhead flies (the app's `BuddyPointerController`, set by
`PointingOverlayModel.attach(pointer:)`; tests and the simulator use `RecordingBuddyPointer`):

- `showTarget`: fly from the user's pointer to the target's frame (the snapped control, AppKit points), show its name,
  and park there until the step ends. A target shown again (a brushed talk key brought it back) flies again; the
  same target id shown twice does not.
- `clearTarget` after a click, an off-target click or an expiry: fly back to the user's pointer.
- The user starts a turn (talk key down, a typed question, barge-in), presses Escape or Stop, or switches apps or
  Spaces: the buddy vanishes at once. `BuddyPointerController` also cancels itself on a Space change.
- An answer's `point(x, y, "name")` ring that lands on a control from the turn's element list, or names one with
  `{element: "e12"}`, flies the buddy to that control at the mark's beat and holds 2.4 s. A parked walkthrough target
  is never replaced by such a point. The ring mark carries `pointing: true`, `pointLabel` and `element` for this.

Only the existing arrowhead art is used; there is no character art.

### Grounding (`ElementGrounding.swift`, parity `point-grounding`)

A one-shot locator for targets nothing else can place (03 §6.8). `ElementGrounder` resizes the canvas screenshot to the
nearest computer-use resolution by aspect ratio (1024×768, 1280×800 or 1366×768), asks a `GroundingModel` for one
click, and maps the answer back through the screenshot's `CaptureGeometry` (`GroundingMapping`: model pixels →
screenshot pixels → AppKit points, so Retina density and a secondary display's origin come from the capture).
`AnthropicGroundingModel` sends one Messages request with the computer tool (the toolset or the beta tool the model
takes), `max_tokens` 256, a short prompt of OpenClicky's own, and reads the first click or pointer move. A reply
without one, or "no specific element", is `.noElement`, and nothing is armed. The fallback has a 15 s limit.

It is off unless the config names a model in the optional `grounding` key (an `anthropic-messages` provider):

```json
"grounding": { "provider": "anthropic", "model": "claude-haiku-5-5" }
```

`GuidedWalkthroughController.grounding` runs it when a target's element id isn't on screen, or when no control was
found at the brain's box. While a request is in flight, `answerFinished()` waits for it, so a walkthrough isn't called
done before its step is placed. A newer step, the user's own turn or a stop drops it, and so do Escape and Stop
before anything has armed (`cancelGrounding()`), so a late answer can't bring the buddy back. An answer that comes
after the walkthrough ended (an expiry, say) is dropped; a request made after an earlier walkthrough had already
ended starts a new one, as an ordinary target does. Its tokens go to the usage
ledger under the `grounding` surface (metered as a brain-slot model). `occtl ground --image shot.png "Click Export"`
runs it on a file.

## Draw-to-ask

### Recording (`HighlightGesture.swift`)

`HighlightRecorder` turns pointer samples (about 60 a second while the talk key is held) into strokes:
- Ink starts only after the pointer has moved 8 pt from where the hold began, so talking with the key held draws
  nothing.
- Samples closer than 1.5 pt to the last one are dropped.
- A pause within 12 pt for at least 0.35 s is a dwell.
- A pause of 0.9 s ends the stroke, so the next movement starts a new mark.
- Between marks, motion faster than 2600 pt/s is travel to the next spot and leaves no ink.
- At most 8 strokes of 2400 points each.

These constants follow 03 §5.4 where it observed them. The stroke break and the travel speed are OpenClicky's own.

### Understanding the marks (`HighlightShape.swift`)

`HighlightClassifier` measures each stroke: its closure, straightness, total turning and direction reversals.

| Kind | Rule | Region it is about |
|---|---|---|
| circle | turns at least 270° and ends near its start (or turns 324° or more; a 200°+ arc that nearly closes also counts) | inside the loop |
| scribble | at least 4 reversals, and a path 2.5 times its diagonal | under it |
| underline | straight, at least 16 pt wide, rising at most 1 in 5 | the stroke plus 30 pt above it and 6 pt below (strike-through counts) |
| line | anything else | a 90 × 48 pt box at its end (what it points at); short flicks cover themselves |

### Reading what is under them (`HighlightHarvest.swift`)

`HighlightHarvester` reads Accessibility first. It probes a grid of up to 6 × 5 points plus the centre:
- **Text.** `LiveHighlightAccessibility` takes the exact line at each point through `AXRangeForPosition` →
  `AXLineForIndex` → `AXRangeForLine` → `AXStringForRange` / `AXBoundsForRange`, or falls back to static text values.
- **Controls.** It records controls with friendly kinds, labels, values and link URLs.
- **Secure fields** report nothing.

If Accessibility gave no text, it reads the turn's screenshot with on-device Vision OCR (`HighlightTextRecognizer`).
OCR crops 120 px past the region horizontally and 10 px vertically, so words cut by a mark's edge are read whole. It
keeps lines that are at least 40% inside the region. The first recognition in a freshly built binary loads Vision's
model, which took 27–38 s here (see `docs/evidence/feat-guided-and-draw-to-ask/ocr-cold-start.txt`). Call
`HighlightTextRecognizer.warmUp()` at launch. All the marks of a turn share one budget
(`HighlightHarvester.deadlines()`): Accessibility probing stops after `accessibilityBudget` (1.5 s) and OCR gets at
most the recognizer's `timeout` (3 s) after that, so a turn waits at most about 4.5 s for the words however many marks
it has.

### The description (`HighlightDescriber.swift`)

`DrawToAskSession` is the orchestrator's handle:

```swift
drawToAsk.keyDown(at: NSEvent.mouseLocation, time: now)          // with the talk key
drawToAsk.pointerMoved(to: NSEvent.mouseLocation, time: now)     // 60 Hz while held → ink.update(drawToAsk.liveStrokes)
drawToAsk.keyUp(time: now)                                       // → ink.fadeOut()
var input = TurnInput(words: transcript, screenshots: look.screenshots, context: look.turnContext())
await drawToAsk.attach(to: &input, layout: look.layout)          // highlightDescription + inked screenshots
```

`attach` uses the gesture once. For each mark it finds the screenshot, reads what is under it, and words it:
- the kind and place: "They circled an area at the top left";
- the box in screenshot pixels, so the brain can point back at it;
- any dwell;
- the words found ("Text there", noting when they were read from the screenshot);
- the controls ("button "Export"; link "Learn more" (links to …)").

Several marks are numbered in order. The overlay windows are left out of captures, so `HighlightInk.composite` draws
the yellow ink into the matching screenshots (multiplied, so the words under it stay readable). The description then
says the strokes are the user's. `HighlightInkLayer` is the live overlay ink: it follows the pointer and fades over
1 s after the key goes up.

## Simulators (no mouse, talk key or permissions)

```sh
occtl guided simulate docs/evidence/feat-guided-and-draw-to-ask/guided-export-pdf.json --out /tmp/guided
occtl highlight --demo --mark circle:330,170,250,40 --dwell 0.6 --out /tmp/marked.png
occtl highlight --screen shot.png --mark underline:100,280,270 --mark line:700,620,215,502 --json
```

- `guided simulate` plays a `GuidedScript`: the screen size, the elements with pixel boxes, and timed events
  (`answer` in the drawing language, `click`, `move`, `key`, `scroll`, `app`, `escape`, `userTurn`). It goes through
  the real engine, guided pieces and controller on a virtual clock. It prints every target (and how it snapped), every
  trigger and note, the HUD line, and every buddy flight ("buddy flies to target 1 "File" and parks → pixels […]",
  "buddy flies back", "buddy vanishes (the user started a turn)"). With `--out` it renders each armed target over a
  mock of the scripted screen; `--filmstrip buddy.png` renders the buddy's flights frame by frame.
- `highlight` plays strokes (`circle:cx,cy,r[,ry]`, `underline:x,y,w`, `line:x1,y1,x2,y2`, `scribble:x,y,w,h`,
  `path:x,y;…`) through the recorder over a screenshot or a demo page. It reads the words with OCR and prints the
  description, or the `TurnContext` JSON with `--json`. With `--out` it writes the inked screenshot, with each region
  outlined for review.

## What needs a person at the Mac

- **Accessibility permission**, for the global key and mouse monitors and for reading text and controls under marks.
  Snapping uses the element list the turn already has, so it works headlessly; only the hit-test fallback needs the
  permission.
- **The live overlay**: the ink following the pointer, and the target ring over real apps.
- **The buddy flying in the running app**: to a real target, parking, flying back after the click, and vanishing on
  Escape or a talk-key press. Its decisions are tested headlessly (`BuddyGuidanceTests`) and rendered offscreen, but
  no one has watched it over real apps.
- **End-to-end voice turns** that start themselves after a real click. The loop is wired and tested with the real
  orchestrator, drawing engine and walkthrough (`VoiceLoopGuidanceTests`) and runs headlessly in `occtl turn
  --elements … --click-target` and `--highlight …`, but no click from a real pointer monitor has started one yet.
