# The notch

OpenClicky's main surface hangs from the top centre of every display: from the camera housing on Macs that have one, or
from a short sliver at the top edge on displays without one. It replaces the click-through pill the overlay used to
draw. Built from [re/03 §8](re/03-screen-pointing.md#8-notch-ui-and-floating-buttons) and
[re/08 §7.2](re/08-apps-memory-ui.md#72-notch-primary-surface); rows `shell-notch`, `screen-capture-policy`,
`screen-context`, `apps-calendar`, `agent-hud` and `voice-dictation` in [parity-status.md](parity-status.md).

## What it does

- **Folded**, the notch is just the housing. Resting the pointer on it for 0.45 s opens it (a lip grows under the
  housing while the time runs), and so does a click.
- **Open**, it has three tabs. *Home* shows the talk keys, the next meeting with its Join button, running background
  jobs, and buttons for Home, the job list and always-on voice. *Chat* is a composer: Return sends the question to the
  voice loop like the text panel does, and the answer streams in under it while it is drawn on the screen. *Settings*
  has the notch's switches and a few of the voice loop's.
- It folds on a click anywhere else, on Escape, on the chevron, or (when it opened by hovering and nothing inside was
  clicked) half a second after the pointer leaves it.
- While a voice turn runs, a notice shows, or always-on voice is hearing, thinking or speaking, the notch shows the same
  pill the overlay used to. The pill has a **Stop** while something can be stopped (`NotchStopTarget.current`, most
  urgent first): a take-over drive (the overlay's own emergency stop), an answer being prepared or spoken, or a drawing
  left on screen (the menu's Stop, `VoiceLoopController.stopTurn`), or always-on voice (its toggle).
- **Live events** are short cards under the housing, one at a time:

  | event | from | buttons |
  |---|---|---|
  | Meeting countdown | `CalendarService.upcomingMeeting`, polled every 30 s, from 5 minutes before the start until 5 minutes after | Join (call link), Directions (a real place, Apple Maps), Open (the event's page), else Calendar |
  | Job started | the agent manager's updates (new job or a new run) | Show |
  | Job needs you | an approval or question on the job, or a report that ends with a question; taken back as soon as the job stops waiting (answered in the HUD or by voice, or stopped) | Answer |
  | Job done / didn't finish | the run's report | Open (first file), Show |
  | Can't open that document | a turn's look where macOS refused the front document | Open Settings (Privacy_FilesAndFolders), then Not now or, from the second time, Don't show again |
  | Dictation on the clipboard | a dictation that couldn't type into the field, from the session's report (only when the clipboard write worked; shows the text copied) | — |
  | Your Mac's sound is off | a spoken reply finished, whole, while the default output was muted or at zero; the reply is put on the clipboard (not when the user cut it off or the brain failed) | — |
  | Routine done / didn't finish | the report of a run that a routine started (`routineID`) | Open (first file), Show |
  | Spending limit (nearing, reached, past) | `UsageLimitAlerter` on the ledger's records, once per level and day or month; the same alert is a macOS notification | Usage (Settings → Usage) |
  | A provider isn't answering | every `ProviderUnavailableError` the provider layer explains (`ProviderUnavailableFeed`), once per provider and verdict every five minutes | Check (Settings → Developer) |
  | Browser connected / disconnected | the browser bridge's list of connected extensions changing | — |
  | OpenClicky is driving (or Practising the steps, for a dry run) | a take-over drive starting; updated with each step and taken down when it ends | Stop |
  | Always-on is listening | always-on voice on and waiting (it hands over to the pill while the user speaks or it answers) | Stop |

  Job and routine cards wait out a call or a Focus in the quiet queue (`NotchLiveEvent.proactiveKind`: job reports,
  routine notices, the meeting countdown); the others are about what is happening now and show at once. A drive and a
  stopped spending limit outrank everything else; the drive and always-on cards stay up until their source takes them
  down.

  Short events last 4–14 s of *visible* time: the clock stops while the notch is open, hidden or showing a voice turn.
  More urgent ones step in front (a question beats "job done"), and the meeting countdown steps back for any short event
  and returns after it. The document notice appears at most once per document every ten minutes; its counter and
  "don't show again" are in user defaults (`openclicky.documentAccess.noticeShowCount.v1`,
  `openclicky.documentAccess.noticeSuppressed.v1`). The countdown never asks for Calendar access.
- **Stepping aside.** Twice a second the notch reads the window list (owner, level and size only, so no permission is
  needed) and hides while Spotlight, an open Control Center or Notification Center panel, a system menu extra, the
  screenshot UI, a full-screen picker or Mission Control is up. The full-screen overlays (pointer, drawings, captions)
  also hide for the screenshot UI, pickers and Mission Control. Every reason has a hard limit (30 s to 5 min) after
  which OpenClicky comes back even if the window list still shows it, until that UI actually goes away. The notch also
  hides on a display whose front app is full screen, except for a voice turn's pill (the overlay leaves the pill to
  the notch, so it is the only sign there that the keys were heard); nothing opens there and events wait. Full screen
  means one of the front app's normal windows fills the display, or, on a display with a camera housing (where a
  full-screen app sits below the housing and its window has the same frame as a zoomed one), fills everything below
  the housing while no menu-bar window is on screen there.
  Mission Control is a full-display Dock window at a level other than the Dock's own (20), and Notification Center's
  panel must sit above normal windows (its process also draws the desktop widgets), so neither persistent window can
  hide the notch and overlays until the hard limit. These rules are inferred and unchecked against the real UI.
- The panels are registered with `OwnWindowCapturePolicy` as ambient chrome, so OpenClicky's own screenshots leave them
  out.

Settings live in `~/Library/Application Support/OpenClicky/notch.json` (`interactive`, `hoverOpens`,
`meetingCountdown`, `meetingLeadMinutes`, `jobEvents`, `copiesReplyWhenMuted`). `"interactive": false` brings back the
overlay's click-through pill.

## How it is built

- `OpenClickyKit/Notch` holds everything that can run without a screen: `NotchPresenter` (the state machine; inputs
  with a time in, effects out), `NotchLiveEvent`, the sources (`MeetingCountdownMonitor`, `AgentLiveEvents`,
  `FolderAccessNotice`, `DictationLiveEvents`, `MutedReplyPolicy` with the read-only `OutputSoundProbe`),
  `SystemUIDetector`, `NotchYieldCoordinator`, `FullscreenDetector`, `NotchGeometry` and `NotchSimulator`.
- The presenter's presentation follows HeyClicky's five: `idle`, `onboardingPinned`, `textInput`, `textResponse` and
  `liveEvent`. What a display draws (`NotchSurface`) adds `hidden`, `tucked`, `activity`, `onboarding` and
  `open(tab)`.
- The app side is `Sources/OpenClicky/Notch`: `NotchController` (sources and effects), `NotchModel` (publishes only
  visible changes), `NotchWindowManager` (one `NotchPanel` per display at level 26, just above the status items;
  pointer polling at 30 Hz; click monitors; the window-list probe) and the SwiftUI views. Each surface draws at the exact
  size `NotchGeometry.contentSize(for:)` gives, and the manager lets clicks through everywhere else.
- The voice loop gained small hooks for it: `onLook`, `onTurnRecord`, `onDictationFinished`, `ask(_:)`, the notch's
  Escape claim and `capturePolicy`. `NotchController.stop()` folds the notch and removes them again.
- The panel and its views are always dark (`darkAqua`), so the composer's placeholder and the switches read on black
  in Light Mode.

## Trying it without a screen

```sh
swift build
.build/debug/occtl notch simulate docs/examples/notch-script.json   # a scripted session through the real presenter
.build/debug/occtl notch system-ui --watch 30                        # what the notch would step aside for, live
.build/debug/occtl notch meeting                                     # the countdown the calendar would give now
.build/debug/occtl notch sound                                       # is the default output muted (read only)
.build/debug/OpenClicky --render-notch-snapshots /tmp/notch          # every surface, offscreen
```

`occtl turn` also writes `notch-muted-reply.txt`: the live output state and what the notch would copy for that turn's
reply (the clipboard isn't touched).

The simulator script format is documented on `NotchScript` (pointer positions, clicks, keys, calendar events, job
updates and reports, dictation results, a denied document, a reply with the sound off, and window lists).

## Not yet

File drops on the notch, the document tab, drawing action buttons, the job edge shelf and the hand-off bar; the other
live events (microphone trouble, learned words, app updates, take-over consent, Spotify tip, morning suggestions); the docked cursor; keeping the notch through Mission Control; the text key
opening the notch composer instead of the pointer panel. With the interactive notch on, the developer "Last answer"
timings pill no longer shows (timings are still in `occtl turn` and the history).
