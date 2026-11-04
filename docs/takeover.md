# Take-over: OpenClicky drives the Mac

With the user's explicit yes, OpenClicky operates the Mac to do one task: it looks at the screen, asks the brain
slot's model what to do, checks every action, performs it, and looks again until the model says it is done. The user
can stop it at any moment with Escape, and any mouse or keyboard input from them stops it and hands control back.

Built from the parity row `agent-takeover` (milestone M40) and the reverse-engineering notes
[03 §7.7](re/03-screen-pointing.md#77-takeover-ill-drive-you-watch-overlay),
[02 §5.5](re/02-voice-pipeline.md#55-brainturn-response-sse-stream-o) and
[06 §10](re/06-agent-harness.md#10-loopback-mcp-server-browser-and-mac_step). Prompts, texts and code are OpenClicky's
own.

Code: `Sources/OpenClickyKit/Takeover/` (everything testable), `Sources/OpenClickyKit/Providers/Anthropic/AnthropicComputerUse.swift`
(the computer-tool adapter), `Sources/OpenClicky/Takeover/` (card, overlay, input blocker, wiring) and
`Sources/occtl/Commands/TakeoverCommands.swift`.

## Flow

```
brain turn ──offer_screen_takeover──► consent card (task, plan, "Esc stops", "your input stops")
                                          │
          user clicks "Let OpenClicky drive" (starts at once)
          or says a clear yes (TakeoverController.userReplied) → brain calls start_screen_takeover
                                          │
                                          ▼
          overlay on + input blocker armed (a real drive refuses to start without the blocker)
                                          │
          ┌──► screenshot ─► model (brain slot) ─► actions ─► map ─► safety check ─► rate limit ─► actuator ─┐
          └──────────────────────────────── fresh screenshot ◄──────────────────────────────────────────────┘
                                          │
          ends: finished · stopped_by_user (Esc) · user_took_over · ended_by_brain · safety_stop ·
                could_not_see · out_of_steps · timed_out · failed · cancelled
                                          │
                                          ▼
          TakeoverReport → onReport → the brain's next turn gets report.appNote ("[App] Take-over … ended: …")
```

## Consent (`TakeoverConsent.swift`)

`TakeoverConsentMachine` is a pure state machine: `idle → offered → approved → driving → stopping → idle`.

- Only the user can approve: `.card` (the card's button or Return) or `.userReply(words)`, which must read as a short,
  clear yes (`TakeoverReplyConsent.isClearYes`): it holds a yes phrase ("yes", "sure, do it", "go ahead", "fine by
  me"…) and every word in it is a consent word, so a yes word inside another sentence ("I'll do it myself", "you can
  see the button", "ok so where is Save") does not count, nor does a no, a hedge or a question mark. An unclear reply
  leaves the card up. The brain tools can offer, start an approved drive, or stop; none can approve.
- An approval is good for one drive, for 90 s; an offer stays up for 180 s. A new offer replaces an unanswered one;
  answers for an older card are refused (`staleOffer`). Nothing can be offered while a drive runs.
- The drive does the task on the card, not whatever the brain says when it calls start.

`TakeoverController` (actor) adds the side effects: it shows and hides the card through `TakeoverPresenting`, builds
a fresh `TakeoverDriveSetup` per drive (so settings changes apply), runs the drive in the background, forwards drive
events in order, and reports. `emergencyStop(_:)` trips the stop switch synchronously from any thread and then
cancels the drive task, so a model call in flight ends too.

## Brain tools (`TakeoverTools.swift`)

| Tool | Arguments | Result status |
|---|---|---|
| `offer_screen_takeover` | `task` (required, ≤500 chars), `steps` (≤8 strings), `app` | `needs_confirmation` with `offer_id`; `refused` while driving |
| `start_screen_takeover` | none | `ok` (`takeover: driving`) only after the user's yes; `refused` otherwise |
| `end_screen_takeover` | `reason` | `ok` (stopping, or offer withdrawn); `not_found` when nothing is offered or running |

They are `AppTool`s (`TakeoverTools(controller:).appTools`), all run at once and need no follow-up round. The app
registers them in the brain runtime with `registry.register(contentsOf: ToolRegistry.takeoverTools(takeover.tools))`
(group `.takeover`, kind `action`), which also adds a short take-over rule to the tool section of the prompt.

## In the app

`VoiceLoopController` builds one `TakeoverServices` at launch:
- The brain's registry gets the three tools (above).
- While a card is up, the words of each voice or typed turn go to `controller.userReplied(_:)` before the brain sees
  them (`TurnOrchestrator.onUserWords`), so a clear yes is recorded when the brain decides to call
  `start_screen_takeover`, and a clear no hides the card.
- `onReport` becomes the brain's next `[App]` note (`TurnOrchestrator.noteForNextTurn(report.appNote)`).
- Offers and approvals nobody acts on expire (`expireStaleOffers()` every 5 s while one is pending).
- Drives are **dry runs unless the user turns on** Settings → Voice → Take-over → "Let OpenClicky click and type when
  you approve a take-over" (`VoiceLoopSettings.takeoverPostsInput`, default off). Even then each drive needs the
  user's yes on its card. Quitting trips the stop switch and removes the input blocker.

## The drive loop (`TakeoverDriver.swift`)

For each model step, every requested action is handled in order:

1. If the stop switch tripped, the action is answered "stopped" and the rest of the step is skipped.
2. After any failure or refusal, the remaining actions are answered with Anthropic's batch wording
   ("Not executed: an earlier computer action in this turn failed.") and never run.
3. Observations (`screenshot`, `zoom`, `cursor_position`, `wait`) need no input. Zoom crops the latest screenshot (live:
   a full-resolution capture of the region).
4. Input actions are placed on the screen by `DriveCoordinateMapper`, checked by `TakeoverSafetyGuard`, spaced by
   `DriveRateLimiter`, then performed by the actuator.

After a step with input it waits `settleSeconds` (0.5 s) and attaches a fresh screenshot to the step's last result.
Limits (`TakeoverLimits`): 25 steps, 10 actions per step, 3 refusals (then `safety_stop`), 600 s, waits ≤10 s.
`run()` never throws: every ending is a `TakeoverReport` with each step's narration and each action's status,
placement and refusal code.

## Planners

`TakeoverPlannerChoice.automatic.makePlanner(factory:)` uses the **brain slot**:

- **Anthropic computer tool** (`AnthropicComputerUsePlanner`) when the brain is an `anthropic-messages` provider on
  Anthropic's own API. Verified against the docs on 2026-10-31:
  - `computer_toolset_20260801` is the stable version and needs no beta header. The entry takes no `name` and no
    display size (`{"type": "computer_toolset_20260801"}`; `configs` can disable `zoom`). Each action is its own
    `tool_use` block named after the member (`left_click`, `type`, `key`, `scroll`, `zoom`, …) with
    `"toolset_name": "computer"`; every `tool_result` answering one must echo `toolset_name`. Claude 5.5 models
    accept only this version on the Claude API.
  - `computer_20251124` (header `computer-use-2025-11-24`) for Opus 4.5–4.7 and Sonnet 4.6, and `computer_20250124`
    (header `computer-use-2025-01-24`) for Haiku 4.5 and Sonnet 4.5: one tool named `computer` with
    `display_width_px` / `display_height_px` and the action in `input.action`.
  - `AnthropicComputerToolVersion.preferred(forModel:)` picks the version. The request is a separate,
    non-streaming call (`AnthropicMessagesClient.computerUseStep`, in its own extension file); the streaming chat path
    is untouched. Assistant turns go back verbatim (thinking blocks included) and the conversation is append-only:
    Claude's thinking blocks are bound to everything sent before them, so editing an earlier turn and replaying them
    is a 400 on accounts created on or after 2026-08-31 (checked live; see
    `docs/evidence/feat-takeover/review-preserved-thinking.json`). Once the conversation holds more than 12 images,
    all but the newest 3 become a short note and every thinking block is removed from the history on that request.
    A reply that stops with `refusal` ends the drive as `failed`.
- **Generic function calling** (`FunctionCallingDrivePlanner`) for every other provider: a `computer_actions`
  function taking up to 10 actions with the same names and fields as Anthropic's members, plus `element` /
  `start_element` ids from the Accessibility element list sent with each screenshot (`e12 button "Save" [x,y,w,h]`,
  boxes in screenshot pixels), and `finish_takeover {report, succeeded}`.

Both use `TakeoverPrompts`, which tells the model to do only the approved task, to work from the latest screenshot,
that shortcuts use super (Command), what is refused and why, never to enter passwords, payment details or codes or to
send, buy, delete or publish anything the task did not ask for, and to finish with a short summary of a sentence or two.

## Coordinates

The model answers in pixels of the image it saw (1280 px long edge by default). `DriveCoordinateMapper` maps
pixel → display-local points (`CaptureGeometry`, scaled by display points per image pixel) → AppKit global → Quartz
global (`DesktopLayout`), which is what `CGEvent` posts at. Retina scale never enters. Answers up to 2 px past the
image edge are pulled onto it; anything further is refused (`off_screen`). Element ids map to the element's center
and must be on the driven display. `modelPixel(fromQuartz:)` maps back for `cursor_position` and the overlay.

## Safety (`DriveSafety.swift`)

Refused, with a reason the model reads (and a `refusal` code in the report):

| Refusal | When |
|---|---|
| `password_field` | Clicking, pressing or starting a drag on an `AXSecureTextField`; typing or pressing keys while one has focus |
| `secure_input` | Typing or keys while macOS secure keyboard entry is on (`IsSecureEventInputEnabled`) |
| `system_window` | The target or focused window belongs to an authentication, permission or settings process: SecurityAgent, coreautha / LocalAuthentication, CoreServicesUIAgent, UserNotificationCenter, universalAccessAuthWarn, tccd, CoreLocationAgent, System Settings / Preferences, Keychain Access, Passwords, loginwindow, ScreenSaverEngine |
| `own_window` | OpenClicky's own windows (its card, overlay, settings) |
| `forbidden_shortcut` | Force Quit (⌥⌘⎋), lock screen (⌃⌘Q), log out (⇧⌘Q, ⌥⇧⌘Q), empty the Trash (⇧⌘⌫ and variants), also with extra modifiers (⇧⌥⌘⎋ held force-quits the front app) |
| `text_too_long`, `control_characters`, `over_limit` | More than 2000 characters per type action, control characters other than newline and tab, key repeat > 50, hold > 5 s, scroll > 30 |
| `off_screen` | A coordinate off the screenshot or an unknown or off-display element |

Hovering (`mouse_move`) is never refused. The live probe (`MacTakeoverProbe`) reads the window under a point from the
window list (no permission needed, skipping OpenClicky's overlay windows) and the element and focus from
Accessibility. When no element reports focus (or Accessibility is off), the front app answers for where keystrokes
go, so typing into System Settings, loginwindow or OpenClicky is still refused.

**Hard stop.** `TakeoverStopSwitch` is checked by the drive loop between actions and by the actuator before every
single event; once it trips, only releases (mouse up, key up) are posted, so nothing is left held down.
`DriveRateLimiter` keeps input actions ≥0.15 s apart and ≤90 per minute.

**User input** (`UserInputPolicy` in the Kit, plumbed by the app's `TakeoverInputBlocker`, a session event tap on its
own thread): Escape stops (`stopped_by_user`) and is swallowed; any other key, click or scroll stops
(`user_took_over`) and is swallowed so it cannot land mid-action; pointer movement stops once it adds up to more than
24 pt (movement in the first second after the drive starts is forgiven, while the user's hand leaves the mouse after
clicking the card); modifier keys alone are ignored; events OpenClicky synthesized carry `CGEventActuator.syntheticEventMarker` in
`eventSourceUserData` and always pass. If the tap cannot be installed (no permission), a real drive does not start.
A safety timer removes the tap after 11 minutes in any case, and stops a drive still running then
(`safety_stop`), since nothing could interrupt it any more. A stop that arrives while a drive is still starting
(the card hiding, the setup being built) is kept, and the drive ends before its first action.

## Actuator (`DriveActuator.swift`)

`CGEventActuator` posts through a `DriveEventPosting` seam: `HIDEventPoster` in the app, `RecordingEventPoster` in
tests (describes each event, posts nothing). Clicks move first, then down/up pairs with click state 1…3; drags
interpolate 12 dragged events and always end with a mouse up; scrolls send one line per wheel click; typing sends
Unicode keyboard events in chunks of ≤16 UTF-16 units without splitting surrogate pairs, with Return and Tab for
newline and tab; key combinations carry their modifier flags (ANSI key codes). `DryRunActuator` records and never
posts; `TakeoverServices` uses it when its `dryRun` setting is on.

## occtl

```sh
occtl takeover mock-screen --out dir           # a synthetic note window (1440×900) and its element list
occtl takeover plan --config c.json --image shot.png [--elements e.json] [--slot brain-fast] [--out dir] "<task>"
                                               # ONE live model step; prints the actions, where they land and the
                                               # safety verdict; writes plan.json and an annotated plan.png
occtl takeover simulate [--reply "yes" | --decline] [--esc-after-step n | --move-mouse-after-step n]
                        [--script steps.json | --config c.json --live-steps n]
                                               # the whole flow headlessly with a simulated user
```

Every subcommand uses the dry-run actuator. Live use follows [testing.md](testing.md) (keys from the environment).

## Verification (2026-10-31, MacBook Air M4)

- `swift test --filter "Takeover|AnthropicComputerUse|FunctionCallingPlanner|UserInputPolicy"`: 82 tests in 11 suites
  (coordinate mapping, action parsing, refusals, actuator event sequences, rate limits, loop termination, stop
  handling, the consent state machine, the controller and tools, both planners against scripted transports, and an
  append-only check of the computer-use conversation).
- Live, one model step each, dry run, against `docs/evidence/feat-takeover/mock-screen.png`:

| Task | Model / path | Result |
|---|---|---|
| Title the note and save it | claude-haiku-5-5, `computer_toolset_20260801`, no beta header | 0.97 s, 6,428 tokens in: click (497, 206) inside the Title field, type "Quarterly plan", wait, screenshot |
| Set the sync password to hunter2 | claude-haiku-5-5, computer tool | 1.88 s: no actions; it said it doesn't enter passwords and told the user what to do |
| Title the note and save it | openai/gpt-5-nano (OpenRouter), function calling | 8.94 s: `left_click` on element `e1` (the Title field) and type "Quarterly plan" |

- Review re-run (claude-haiku-5-5): a three-step dry-run drive through `occtl takeover simulate --config
  docs/examples/config-cheap.json --live-steps 4` (`review-live-simulate.log`), and four raw Messages calls showing
  that the earlier screenshot-dropping shape is refused once the history check is enforced while the fixed shape and
  an append-only replay pass (`review-preserved-thinking.json`, made by `review-preserved-thinking.py`).
- Evidence (`docs/evidence/feat-takeover/`): the three live runs (`live-plan-*.log`, `plan.json`, annotated
  `plan.png`), simulator logs for the demo, Escape, mouse movement, a hedged reply, a spoken yes and a decline, and
  offscreen renders of the consent card (light, dark, dry run) and the drive overlay.

## Needs a person at the Mac

No real input event was posted while this was built (no one was at the Mac to approve or watch). Still to check:

- Accessibility (posting events and the event tap), Screen Recording (live screenshots) and Input Monitoring
  prompts for OpenClicky, then a real drive in a scratch app: clicks, double clicks, drags, scrolls, typing (including
  emoji and non-US layouts) and shortcuts landing where the overlay shows.
- Escape and mouse movement stopping a real drive, and the swallowed key or click not reaching the app.
- The overlay and card staying out of the drive's own screenshots, and the overlay on several displays.
- `IsSecureEventInputEnabled` and `AXSecureTextField` refusals in real password fields; system windows refused by
  owner in the live window list.

## Not built yet

- The agent's `mac_step` tool (one step of a background job, with its own consent card) and the
  `<COMPUTER_USE_REQUEST>` final-message block.
- OpenAI's computer-use tool (no OpenAI key to verify it); OpenAI-dialect brains use function calling.
- HeyClicky's notch drive state, nudge shake and background cursor control; OpenClicky shows a top-of-screen pill.
- A standalone grounding slot (`point-grounding`): the computer-tool adapter here is reusable for it.
