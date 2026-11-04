# The voice loop

Hold the talk keys, ask, let go: OpenClicky hears you, looks at the screen, asks the brain, and speaks the answer one
line at a time while the drawing follows the voice. This page covers the turn orchestrator
(`Sources/OpenClickyKit/Orchestrator/`), the app wiring (`Sources/OpenClicky/Voice/`, `Input/`, `Overlay/`) and
`occtl turn`. The interface with the brain is in [turn-contract.md](turn-contract.md).

## One turn

```
idle ─key down─► listening ─key up─► transcribing ─► capturing ─► requesting ─► speaking (or drawing) ─► idle
                   │ mic + stt open, context prefetch,      │ screenshots    │ brain.run    │ lines → voice, program → drawing
                   │ brain.prewarm(), voice warm-up         │ + context      │              │ deferred actions after the last line
```

`TurnOrchestrator` (main actor) runs one turn at a time:

- **Key down** (`pressBegan`): cuts off the turn in progress (barge-in), opens the mic in the stt slot's format at once
  (chunks wait until the speech session is ready, so first words aren't lost), starts the stt session, prefetches the
  context, calls `brain.prewarm()` and warms the voice.
- **Key up** (`pressEnded`): ends the mic, starts the screenshots, finishes the session and waits up to
  `transcriptTimeout` (4 s) for the finals. No words: "I didn't hear anything that time." A failed or silent
  connection: "I lost the speech connection, so I couldn't hear that." A final that never comes keeps the words heard
  so far.
- **Capture**: screenshots of every display, the pointer's first, plus the context (`TurnScreenLooking`). Voice turns
  start it at key-up, so it runs while the last words are transcribed (typed, report and guided turns capture when
  they start).
- **Request**: `brain.run(TurnInput)`. `programDelta` goes to the drawing (begun on the first event, on the pointer's
  display, canvas = the screenshot's pixels); `sayLine` goes to the voice; `status` to the notch; `deferredAction`
  is held; `failed(spoken:)` is shown and said after whatever was already said.
- **Narration**: when the last line has been heard, deferred actions run in order (through
  `BrainRuntime.performDeferred`, which notes failures for the next turn), the turn goes to the history, and the
  next queued job report (if any) starts.

**Cut-offs.** A new press, Escape or a typed question stops the voice at once (`SpeechPlayer.stop()`), cancels the
brain stream and the drawing's pending strokes, drops deferred actions, and sends the brain an `[App]` note saying
which line was playing and which lines weren't heard (`NarrationOutcome.note`). The next request waits for that note.
Escape with nothing running clears a drawing left on screen; otherwise it passes through to the app.

**Typed turns** (`submitTyped`) skip listening and draw at once (`pace: now`); the answer appears in the text panel,
and is read aloud only with Settings → Voice → "Read answers to typed questions aloud". **Report turns**
(`runReportTurn(note:)`, fed by `AgentServices.onReportTurn`) run with no words, trigger `job_report` and the jobs'
note; they wait while the user is talking or another turn runs, and start once the loop is idle again (after a turn
ends, a brushed press, or Escape). Reports that waited are told together in one turn.

## Draw-to-ask, walkthroughs, take-over and media cards

- **Draw-to-ask** ([guided.md](guided.md)): the orchestrator's `Services.guidance` (`TurnGuiding`; in the app the
  overlay's `PointingOverlayModel`) gets key down, key up and cancel. Moving the mouse while the keys are held paints
  highlighter ink; before the request of that voice turn, `prepare(&input, look:)` attaches the description of the
  marks (`TurnContext.highlightDescription`) and draws the ink into the screenshots. `TurnScreenLook.layout` maps the
  ink to the screenshots.
- **Guided walkthroughs**: an answer's drawing (not a job report's) hands its marks to the guide as their lines are
  heard, so `target()` rings the real control (`TurnScreenLook.guidedScreen`: the pointer's screenshot and the front
  window's elements). A click on it, or a manual step done, starts a `.guided` turn by itself (`runGuidedTurn`:
  trigger `clicked_target` / `did_step`, the walkthrough's notes, the after-action capture `lookAfterAction()`). If
  the user keeps acting before anything of that turn is heard, it starts again on a fresh screenshot
  (`refreshGuidedCapture`). When an answer arms nothing, the walkthrough completes. Escape stops it (and is swallowed
  only while one runs); so does the menu's Stop walkthrough (`stopWalkthrough()`), which also cuts off a next step
  still being prepared or said, so its answer can't ring a target again. A brushed press or nothing heard puts the
  interrupted step back; if that press had cut off the walkthrough's own turn before it armed anything, that turn is
  asked for again (`resumeGuided`) instead of leaving the walkthrough "working out the next step" with nothing running.
- **Take-over** ([takeover.md](takeover.md#in-the-app)): its three tools are in the brain's registry; while a consent
  card is up, the user's words go to `TakeoverController.userReplied` first (`onUserWords`); a drive's report is the
  next turn's `[App]` note (`noteForNextTurn`). Drives are dry runs unless the user turns real input on in Settings →
  Voice.
- **Media cards** ([dsl-media.md](dsl-media.md)): each overlay drawing gets the `DrawingMediaResolver` over the
  lookup services, so `photo()`, `place()`, `stock()` and `source()` fill in while the answer is spoken; a new answer
  cancels the last one's lookups.

## The voice: `LineNarrator`

- Lines are synthesized one at a time, in order, through the voice slot's `SpeechOutputClient`; the
  `SpeechPlayer` plays them back to back and reports when each line actually starts and finishes reaching the
  listener. Those reports drive the drawing's `SpeechPacing` (on the audio queue, in order) and the captions.
- **Health check**: a line with no audio within `firstAudioTimeout` (5 s), or that fails before any audio, makes the
  narrator reopen the voice (`stopAll()`, `warmUp()`) and send the line again once.
- **Fallback**: if that fails too, another configured cloud voice takes over for 10 minutes (`AlternateVoice`: a
  different cloud speech provider whose credential is stored, speaking with its adapter's default model), as
  HeyClicky moves to its other cloud voice first. Only without one, or if it fails as well, the Apple voice
  (`AppleSpeechSynthesisClient`) speaks the line and everything after it for 10 minutes; the notch says
  "Speaking (Mac voice)".
- **Idle mouth.** The OpenAI Realtime voice (`OpenAIRealtimeSpeechClient`) closes its socket after 90 s without a line
  and opens it again on the next one, instead of holding it open until always-on or the app stops it.
- A line nothing could say passes as silence about as long as saying it would take, so the drawing keeps pace.
- **Pauses and spoken words** (`NarrationPacer`, ticking every 40 ms while a turn speaks): a gap after a line longer
  than 0.3 s (the next line isn't written or synthesized yet) or a stall in the playing line's audio longer than
  0.35 s pauses the drawing (`TurnDrawing.pause()`); the next line or moving audio resumes it. The words heard so far
  (from `SpeechPlayer.position()` and `CaptionWords`' timing) go to the drawing as a running count
  (`TurnDrawing.wordsSpoken`). The pen is always released before `finishNow()` or a cut-off's `cancel()`. The turn log
  says `pacing: paused (gap)`, `pacing: resumed`, `pacing: spoken N`; `TurnOrchestrator.Settings.narrationPacing` holds
  the thresholds.
- **Which screen.** A program that starts with `onScreen(n)` draws on screenshot n: program text is held until its
  start shows whether it names a screen (`DrawingScreenDirective`), then the drawing begins on that display's canvas
  (a new drawing, sized to that screenshot). A follow-up continues the drawing on the display it is on, which becomes
  the turn's canvas even if the pointer moved to another display.

## Seams

| Seam | App | Tests and `occtl turn` |
|---|---|---|
| `TurnMicrophone` | `CaptureTurnMicrophone` (MicrophoneCapture) | `SilentMicrophone` |
| stt | `VoiceEars.make(factory:)` (one stt client kept warm, fallbacks, refusal switch; see below) | `SimulatedSpeechToText` (reveals the words as audio arrives); `occtl turn --in f.wav`: `VoiceEars` with `AudioFileMicrophone` |
| `TurnScreenLooking` | `ScreenLookAdapter` (ScreenLookService) | `StillImageScreen` |
| `TurnGuiding` | `PointingOverlayModel` (ink, ring, pointer monitor) | `TurnPointingGuide` |
| brain | `BrainWiring.makeRuntime`: memory (recall also searches the history), app tools, lookups, connected apps and the Obsidian vault, agent jobs and take-over; the active skills, the `[Your jobs]` note and `FigureAvailability`. Shared with Home's typed chat and always-on through `BrainRelay` | `BrainCommands.runtime` with the same wiring (occtl) / `ScriptedBrain` (tests) |
| voice | `LineNarrator` + `SpeechPlayer` | `OfflineSpeakers` (offline engine rendered in real time to a WAV) / fake clock |
| `TurnDrawingSurfaces` | `OverlayDrawingSurfaces` (a `DrawingSession` + `FigureStage` per display) | `OffscreenDrawingSurfaces` / `RecordingSurfaces` |
| `TurnCuePlaying` | `AppCues` (CuePlayer) | none |

## What the brain knows besides the screen

`VoiceLoopController.ensureEngines()` builds the brain with `BrainWiring` (docs/brain.md), the same wiring
`occtl brain ask --tools all` uses:

- **Connected apps.** `read_connected_apps` is registered when an app in `connectors.json` (an MCP connector, the
  Obsidian vault or Composio) is ready, and the system prompt lists them (`BrainPromptOptions.connectedApps`). The
  connector tool chooser runs on brain-fast. Editing connectors in Settings rebuilds the brain before the next turn.
- **Skills.** The active skills are in the session prompt; a change mid-session is a `[Skill update]` note.
- **Jobs.** Every turn `AgentCoordinator.brainContext()` is read; the `[Your jobs]` note goes to the brain when it
  changed since it last did in that session (and again after a compaction).
- **Figures.** `figuresAvailable` follows `FigureAvailability.shared`: a Metal device, shaders that compiled, and no
  overlay `FigureStage` with a `rendererError`.
- **Earlier chats.** `recall_memory` also looks through the history (`MemoryTools(history:)`).
- **Job hand-offs.** Each job that starts and each run that comes back is written to the conversation the brain
  holds (`HistoryHandOff`, docs/history.md), and a finished job may leave a how-to in memory (`AgentHowToLearner` on
  brain-fast).

## The ears

`VoiceEars` (`Sources/OpenClickyKit/Ears/`) is the stt the app hands the orchestrator, built from the stt slot with
`VoiceEars.make(factory:)`. It is a `SpeechToTextClient`, so the orchestrator needs nothing special for it:

- **Warm connection.** One client is kept across presses (the app rebuilds it only when the slots change). While the
  ears were used in the last 15 minutes (the time of the last press is kept in the user defaults), a Gemini Live
  socket is opened ahead of key-down: when the engines are built, on wake, after every press, and every minute in
  case Gemini closed it. A press on it skips the connect and setup round trips.
- **Press audio kept.** Every chunk of the press is recorded while it streams. If the stream fails, or hasn't settled
  3 s after key-up, the recording goes to the fallbacks in one pass (6 s at most): the slot's batch side (Gemini's
  unary `gemini-3.5-transcribe`, sent the press as a WAV file; for other adapters the slot's own client again), then
  Apple Speech on device. A fallback that fails too leaves the words the stream had, if any.
- **Refusal switch.** When the slot's account refuses for billing, credit, payment or quota, or the provider doesn't
  serve the user's region (`ProviderDiagnostician`'s `regionUnsupported`), presses stream to Apple Speech on device
  (and skip fallbacks on the same account) for ten minutes, and no warm socket is opened.
- **Per press.** Interim text is the running transcript; one final settles the whole press. Each press ends with an
  `EarsPressReport` (warm or not, outcome `streamed`/`switched`/`fallback`/`partial`/`silent`/`failed`/`cancelled`,
  key down → connected / ready / first text, finish → final, the fallback used), which the orchestrator logs and puts
  in `TurnTimings.ears`.

### Dictation's ears

Dictation (fn ⌃) uses its own `VoiceEars` for the stt slot, kept while the slot stays the same
(`VoiceLoopController.makeDictationEars`, last use under `openclicky.ears.dictation.lastUsedAt.v1`). The speech
session opens at key-down alongside the microphone, so a warm socket is taken over and the press audio waits in the
ears while a cold one connects; refusals and dropped streams go to the same fallbacks. The cleanup pass on
brain-fast asks the original GPT-5 family (gpt-5, -mini, -nano) for `minimal` reasoning when the catalog lists no
efforts: at the provider default (`medium`) gpt-5-nano took over 6 s on one sentence and every live cleanup timed out
to the local tidy.

`occtl dictation run <file.wav> [--fake] [--fast] [--warm] [--json] [--config c.json]` runs one whole dictation from a
file: the dictation ears, the cleanup pass and `TextInserter` typing into a pretend TextEdit field, with the time of
each step (`docs/evidence/feat-dictation/occtl-dictation-run-*.txt`).

## Talk keys

`TalkKeyMonitor` runs a CGEventTap on its own thread (an active tap with Accessibility, listen-only with Input
Monitoring alone, NSEvent monitors otherwise; it retries every 5 s so granting the permission later works without a
relaunch). The active tap filters only modifier changes and key presses; clicks and scrolls are watched with NSEvent
monitors, which can't hold them up. Every 5 s the active tap checks that it may still filter events (macOS doesn't say
when Accessibility is taken away, and an active tap left running then can hold up input) and steps down if not.
`TalkKeyGestureMachine` (pure, tested) turns its events into gestures:

| Gesture | Default | Does |
|---|---|---|
| Hold the voice chord | ⌃⌥ | talk; shorter than 0.18 s, or another key in that time, is dropped quietly |
| Double-tap the text key | ⌃ ⌃ | open the text panel near the pointer (fires 0.32 s after the second tap) |
| Triple-tap the text key | ⌃ ⌃ ⌃ | turns always-on voice on or off ([realtime-voice.md](realtime-voice.md#in-the-app)) |
| Hold the dictation chord | fn ⌃ | routed to the dictation controller (hold, hands-free, bounce rules are dictation's) |
| Escape | | stops dictation, the text panel, always-on's reply, the turn, or clears a drawing; swallowed only then |

While always-on voice runs the orchestrator holds its turns (`holdsTurns`): the voice chord interrupts always-on's reply
instead of starting a turn, typed questions go into its conversation, a walkthrough can't start a step, and job
reports wait until it is off.

## On screen

Each display's overlay panel holds the drawing canvas (with 3D figures), the draw-to-ask ink and the walkthrough's
target ring (`PointingOverlayLayer`), the buddy pointer, the listening bubble by the pointer, the spoken caption near
the bottom, the notch pill at the top centre (state, live transcript, tool status, notices, optionally the last turn's
timings) and, while a walkthrough runs, its step pill below the notch pill on the target's display.
`OpenClicky --render-voice-snapshots <dir> [--backdrop img]` renders these offscreen.

## Timing

`TurnTimings` marks key down, key up, transcript, capture, request, first token (program text or line), first line,
first audio, first line heard, brain finished, narration finished and done, plus the ears' press report (`ears`).
`report()` prints the steps and an `ears:` line; the app logs it (subsystem `app.openclicky`, category `voice-loop`)
and Settings → Voice shows the last one. Where the time goes, and what was cut, is in [latency.md](latency.md).

## `occtl turn`

```sh
zsh -c 'source ~/.config/zsh/secrets.zsh >/dev/null 2>&1; source scripts/dev-keys.sh >/dev/null;
  .build/debug/occtl turn --config docs/examples/config-cheap.json --image shot.jpg --out-dir /tmp/turn "what does this button do"'
```

The real orchestrator, brain and voice, with a transcript for the mic and an image for the screen. Writes
`frame-line-N.png` at each line start and `frame-final.png`, `voice.wav` (never played), `timing.txt/.json`,
`events.txt` and `program.js`. `--typed [--speak]` runs a typed turn; `occtl turn --help` lists the rest.

- `--in question.wav` speaks a recording instead of a transcript: the configured stt slot hears it through the ears
  (warm socket first unless `--cold-ears`), so a real adapter runs inside the voice loop without a microphone.
  `--thinking summarized|hidden|off` overrides how the brain thinks, for comparisons.

- `--elements f.json` gives the front window's controls (ids the brain can name; guided targets snap to them), and
  `--click-target` clicks a target the answer armed, so the walkthrough's next turn starts by itself (its files are
  prefixed `followup-`). `events.txt` logs every target, trigger and note.
- `--highlight circle:cx,cy,r …` (repeatable, `occtl highlight`'s shapes, `--dwell s`) plays draw-to-ask marks as if
  drawn while the keys were held; the description (on-device OCR, warmed first) goes in `context.txt`.
- `--media live` looks up the drawing's photo, place, quote and site-icon cards.

## Not done yet

- The pen cursor. (Clicks on drawn buttons, figures and cards, follow-ups that continue the drawing, and the stale
  watch are in docs/overlay-interaction.md; none has been watched on a live screen yet.)
- Mic trouble notices and dead-air counting, muted-output handling, the start cue that waits for the mic, echo
  cancellation for always-on on speakers and quiet contexts are in docs/audio-robustness.md; push-to-talk stays on the
  plain (not echo-cancelled) engine, since the talk key already stops the voice.
- The shaders are compiled in the background at launch (`FigureAvailability.warmUp`); a figure stage whose renderer
  fails marks figures unavailable, which the brain hears at its next turn. Neither has happened on a real screen.
