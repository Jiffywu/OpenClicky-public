# The brain runtime

`BrainRuntime` (`Sources/OpenClickyKit/Brain/`) implements the turn contract's `BrainTurnRunning`
(`docs/turn-contract.md`): OpenClicky's prompt, the conversation thread, tools, and the brain-slot model. The
orchestrator hands it a `TurnInput` and plays the `TurnEvent`s it streams back.

| File | What it holds |
|---|---|
| `BrainRuntime.swift` | the actor: turn loop, prewarm, compaction scheduling, sessions, `make(factory:)` |
| `BrainPrompt.swift` | `BrainPromptAssembler` (system prompt, turn message), `BrainTurnNotes` (the `[Turn]` block), `BrainInstructions` (OpenClicky's own text) |
| `BrainThread.swift` | `BrainSessionState`, `BrainThreadItem`, `BrainPruningPolicy`, `BrainSessionStore` (disk) |
| `BrainTools.swift` | `BrainTool`, `BrainToolKind`, `ToolRegistry` and the registrations for memory, app tools, lookups, connected apps, agent jobs and take-over |
| `BrainToolRunner.swift` | one turn's tool calls: start order, cap, cancellation, synthetic results |
| `BrainWiring.swift` | `BrainWiring` (the tools, prompt options and context sources the app and `occtl` build the runtime from) and `ConnectedAppsWiring` |
| `BrainRelay.swift` | `BrainRelay`: the one brain Home's typed chat and always-on share with the voice loop |
| `BrainCompactor.swift` | folds old turns into a structured note on the brain-fast slot |
| `ProgramFenceStripper.swift` | strips ```` ``` ```` fences while the program streams |
| `Resources/prompts/draw-2d.md`, `draw-3d.md`, `draw-guided.md`, `draw-media.md` | the model-facing sections of `docs/dsl.md`, `docs/dsl-3d.md`, `docs/dsl-guided.md` (walkthrough steps) and `docs/dsl-media.md` (photo, place, quote and site-icon cards); the last two follow the 2D language unless `BrainPromptOptions.guidedSteps` / `.mediaCards` are off |

## One turn

1. The turn's notes, screenshots and words become one user message (below) appended to the thread. Old screenshots
   and document text are pruned.
2. The request is `[system prompt] + thread`, with the registry's tools, sent to the brain slot's
   `LanguageModelClient` with `PromptCacheHint.conversation`.
3. Text deltas go through `ProgramFenceStripper`, then out as `programDelta`, and through one `SayLineExtractor` for
   the whole turn, so each `say("…")` goes out as `sayLine` the moment its closing quote arrives.
4. Each tool call starts as soon as the model has written it:
   - `read`: runs; its result goes back to the model in another round. The text of every round is appended to the
     same program (the prompt asks the model to continue with the next step and never repeat a line).
   - `action`: runs; the model gets a status word, no extra round.
   - `deferredAction`: not run; the turn emits `deferredAction` and the model hears it is queued. The orchestrator
     runs it after the narration with `performDeferred(_:)` (a failure becomes an `[App]` note next turn), or drops it
     when a new turn starts.
   - `async`: started in the background; the model hears it started; a failure becomes an `[App]` note.
   Program text reaches `programDelta` a line at a time (see "Prose instead of code" below).
   Results are appended in the order the calls started, whatever order they finish in. More than
   `maxToolCallsPerTurn` calls, or a read in the last allowed round, get `tool_limit_reached` without running.
5. The reply is kept in the thread exactly as produced (fences, provider items), and every call gets a result.
6. Rounds repeat while reads need reading, up to `maxRounds` (4). Then `finished(TurnSummary)` with the program, the
   spoken lines, rounds, summed usage, time to first program text and total time; or `failed(spoken:detail:)` with a
   sentence the voice can say (rate limit, key refused, connection lost…).

**Cancellation.** Cancelling the consuming task (or starting a new turn) cancels the model stream and every running
tool. The thread still gets the partial reply and a result for each call it made: `cancelled` for calls that were
running, `never_ran` for calls that arrived after the cancel. Nothing waits for a tool that ignores cancellation.
The turn log records an `interrupted` line.

## The prompt

The system prompt is fixed for a session (byte-identical from turn to turn) and holds only what doesn't change:
persona, how to answer, pointing rules, how to explain, the 2D language, the 3D language (or a note forbidding
`figure()` when Metal isn't available), tool rules for the registered groups, the connected apps, the active skills
(`BrainPromptOptions.skills`), and the user's standing memory (`MemoryPromptSection.stableText`). Everything about the
moment goes in the newest user message:

```
[Turn] 14:05, Saturday, October 31, 2026 (America/Los_Angeles)
Canvas: W = 1200, H = 661: the screenshot of the main display, where the pointer is.
Front app: Google Chrome (com.google.Chrome)
Window: Bridge test page
Selected text: "…"
Elements on the canvas you can point at (id: kind "label" [x, y, w, h] in canvas pixels):
e5: button "Say hello" [32, 217, 71, 21]
[App] The user cut your last answer off after line 2.
<relevant memories>
[Document text, cut short]      ← its own text part, pruned from older turns
…
Screenshot 1: main display, 1200×661 pixels (the canvas you draw on).
<image>
The user said: …
```

**Context sources.** `BrainContextSources` is what the app keeps current: the skills block, notes for every turn
(`[Your jobs]` from `AgentCoordinator.brainContext()`) and whether figures work (`FigureAvailability`). Skills and
figures are read into the system prompt when a session starts; a change mid-session reaches the next turn as a
`[Skill update]` note (the new block) or an `[App]` note about figures, so the cached prefix never changes within a
session. A turn note is sent when its text changed since it was last sent in the session (by its bracket tag), and
again after a compaction. Notes that start with a bracket tag (`[Your jobs]`, `[Skill update]`, `[Always-on]`,
`[Browser]`) keep it; anything else is marked `[App]`. The app adds a `[Browser]` note (`BrowserBrainNote`): connected
(which browsers, how many profiles), not connected (a job that needs a signed-in site will raise a `chrome_setup`
request; `openclicky://settings/browser` opens the setup page), or no Chromium browser on the Mac. Its text only
changes with the connection, so the brain hears it when that changes.

**The canvas.** Programs draw in the pixels of the screenshot of the screen under the pointer (`W` × `H`). The
orchestrator should begin the drawing engine with that size as its canvas (`DrawingSession` canvas width/height =
the screenshot's pixel size, scale = display points per pixel). Element frames (global points in the contract) are
converted to those pixels in the notes, so the model can point at exact boxes.

**Keeping the copies in sync.** `scripts/sync-prompts.sh` copies the text between `<!-- prompt:start -->` and
`<!-- prompt:end -->` in `docs/dsl.md`, `docs/dsl-3d.md`, `docs/dsl-guided.md` and `docs/dsl-media.md` to
`Resources/prompts/`. `BrainSessionTests` fails while
a copy differs from its doc.

## Caching, prewarm, compaction

- Every turn's request extends the previous one: same tools, same system prompt, the old thread unchanged, new
  messages at the end. `PromptCacheHint.conversation` asks Anthropic for a breakpoint on the system prompt (which
  caches the tools too) plus automatic caching of the conversation; OpenAI dialects cache prefixes by themselves.
- Pruning breaks the prefix where it edits, so it is batched: screenshots are pruned only when `keepImages +
  imageSlack` have piled up (3 + 3), then down to the newest 3; document texts likewise (1 + 2).
- `prewarm()` (key-down) sends `[system] + thread + placeholder` with `maxOutputTokens: 1` and a breakpoint on the
  thread's last message, so the cache is warm at key-up. Only for `anthropic-messages`, and only when the last
  request is more than four minutes old (a cache entry lives about five). It is a no-op elsewhere.
- When a request's input reaches `compactionThreshold` (60k tokens), the turns before the newest
  `compactionKeepTurns` (3) are folded, on the brain-fast slot, into one note with the headings Goals, Still open,
  Decisions and corrections, Facts, Screen, Drawn. It runs after the turn; a result that comes back after the
  session ended or the folded messages changed is dropped. A result that comes back while a turn is running is held
  until that turn ends, so the thread never changes between the rounds of one turn (that would break the cache and
  the replayed thinking of a tool round). Only real user turns (the messages that carry the user's words) count as
  turn starts, so an `[App]` note added mid-turn never becomes the fold point. With too little to fold it asks again
  `compactionStep` (15k) tokens later.

## Sessions

- `~/Library/Application Support/OpenClicky/Brain/<session>/thread.json` (thread and bookkeeping, rewritten after
  every turn; screenshots are never written, a stand-in takes their place) and `turns.jsonl` (one line per round,
  prewarm, deferred action, background call, compaction, interruption, failure and session end).
- At launch the newest session (the most recently saved `thread.json`; only that file is read) is picked up if its
  last turn is younger than `idleTimeout` (30 min); an older unfinished one is ended when the next turn starts.
- After `idleTimeout` without a turn the session ends by itself. `endSession()` ends it on request. Ending marks the
  thread ended, starts a fresh one, and runs `MemoryWriter.endSession` (session note plus profile, standing context
  and how-to changes) on brain-fast with the conversation as the user said it (words, not turn notes or
  screenshots). That model call runs in the background (like HeyClicky handing the session to its server), so a turn
  that ends an idle or stale session never waits for it; `endSession()` itself waits, and
  `waitForBackgroundWork()` covers it. The fresh session's system prompt is built before those notes land, so they
  reach the prompt from the session after.
- `recordOutcome(_:)` queues an `[App]` note for the next turn.
- `BrainRuntime` adopts `ConversationSeeding`, so `TypedChatController` (the Home chat) can hand it a conversation from
  the history: completed turns become the user's words and the brain's program. The conversation it replaces is
  ended first (memory notes in the background). A seeded conversation counts as active now, and its old turns are
  left out of the memory notes (they were noted when they happened).
- History records (`TurnLogBuilder`) default their canvas to the cursor screen's size in points; brain programs are
  laid out in that screenshot's pixels, so pass `canvas:` with the pixel size when recording brain turns.

## Tools on main and their kinds

| Group | Tools | Kind |
|---|---|---|
| memory | `save_memory` / `recall_memory`, `forget_memory` | async / read |
| app tools | `calendar_find_events`, `calendar_create_event` / `copy_to_clipboard` / `open_url`, `reveal_in_finder`, `play_on_spotify` | read / action / deferred |
| lookups | `web_search`, `image_search`, `place_search`, `stock_quote` | read |
| connected apps | `read_connected_apps` | read |
| agent | `session_status`, `find_jobs` / `sessions_spawn`, `sessions_send`, `sessions_interrupt`, `sessions_answer_request` / `show_result` / `routines` | read / action / deferred / read for `list`, action otherwise |
| takeover | `offer_screen_takeover`, `start_screen_takeover`, `end_screen_takeover` (docs/takeover.md; the app registers them) | action |

**Provider-hosted web search** is plumbed but switched off. `ChatRequest.hostedTools` carries raw provider tool
entries (the Anthropic and OpenAI Responses adapters append them to `tools`), `ToolRegistry.registerHosted` holds
them, and the prompt has a rule for them. Live on Claude Haiku 5.5 the model answered in cited prose after the search,
or not at all, and the thread does not yet keep the provider's `server_tool_use` / `web_search_tool_result` blocks, so
`HostedWebSearch.brainPassesHostedTools` stays false and `web_search` runs through the lookup services (a read).
`occtl brain ask --hosted-search` turns it on for experiments.

**Prose instead of code.** Text is passed through `ProgramLineFilter` line by line: a line that reads as a plain
sentence (outside comments, template strings and open brackets, so the properties of a call or object written over
several lines pass) is held out of the program, because it can't be spoken and an
apostrophe in it would read as an unclosed string and swallow the code after it. When a round had such lines, the
runtime asks the model once, in another round, to continue the program with `say()` lines.

## Latency

A spoken answer can't wait for long thinking. `BrainRuntime.make` (and `occtl brain ask`) ask for the `low` reasoning
effort when the brain model's catalog entry lists it. On Claude Haiku 5.5 that took a diagram's first line from 9 s
to under 3 s; with a warm cache most turns start speaking in about 1 to 3 s (a cold-cache rerun in review took
4.6 s). The prompt also asks for brief planning, ready-made figure
motions over hand-written `f.tick` math, and a first sentence before any layout work (live numbers in
`docs/evidence/feat-brain-runtime/README.md`).

## Trying it

```sh
zsh -c 'source ~/.config/zsh/secrets.zsh >/dev/null 2>&1; source scripts/dev-keys.sh >/dev/null;
  .build/debug/occtl brain ask --config docs/examples/config-cheap.json --new --image shot.jpg --app Chrome "What does this page do?"'
.build/debug/occtl draw <saved program> out.png --size WxH --bg shot.jpg
.build/debug/occtl brain show
```

`occtl brain --help` lists the options (elements, document text, notes, tools, `--prewarm`, `--state`).
`--tools all` gives the brain what the app's does except jobs and take-over: memory (recall also searches the
history), lookups, the connected apps in `connectors.json` (`--connectors f.json`) and the active skills;
`--show-prompt` prints the system prompt.
`occtl brain render <program.js> <out.png> --size WxH --bg shot.jpg` draws a whole answer: the 2D marks through the
real engine and painter (`DrawingRehearsal`), and each 3D figure through `FigureProgramHarness` (so `f.tick` poses
its parts) and `FigureSnapshot`, composited at the figure's rectangle.
