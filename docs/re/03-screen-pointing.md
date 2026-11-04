# 03 — Screen capture, context, pointing and cursor overlay

Subsystem: how HeyClicky **sees** the user's screen (capture plus app, document and focus context) and how it **points** (the buddy cursor, rings, highlights, shapes, guided click-through walkthroughs, the pen cursor, notch and floating chrome).

Evidence base: HeyClicky 1.1.2 (build 69), `~/Developer/openclicky-evidence/HeyClicky-1.1.2-b69.app`, plus key names only from the user's data dir `~/Library/Application Support/Clicky`. All analysis was static and read-only. No network calls, and the app was not launched.

Legend used throughout:

- **OBSERVED**: seen directly in an artifact. The doc cites the artifact and the identifier or string.
- **INFERRED**: my reasoning from observed facts.
- **UNKNOWN**: can't be recovered from the client (server prompts, server logic, values the code never passes).

Method notes, so the work can be reproduced:

- Strings came from the arm64 slice (`lipo -thin arm64`), and Swift type and field names from parsing `__TEXT,__swift5_fieldmd`.
- Function bodies come from `llvm-objdump` output. `__objc_stubs` were resolved to selector names, and string xrefs were found by scanning ADRP+ADD pairs. Constants below are decoded from immediates (`mov`/`movk`/`fmov`).
- Function addresses are given as `0x…` so they can be re-verified.
- Scratch outputs are in `/tmp/openclicky-re/screen-pointing/`.

Related docs: `02-voice-pipeline.md` (voice and realtime sessions), `04-draw-2d.md` (drawing programs and the native painter), `06-agent-harness.md` (Codex agents and computer-use takeover), `07-browser-bridge.md` (Chrome extension), `08-apps-memory-ui.md` (Home, notch content, settings).

---

## 1. One-paragraph summary

When a help request starts (push-to-talk, typed notch input, draw-to-ask, a guided step, or a OneBrain turn), HeyClicky captures **every display** with ScreenCaptureKit's one-shot `SCScreenshotManager`.

- **Capture.** HeyClicky's own cursor chrome is excluded. Each display is scaled so its **long edge is 1280 px**, encoded as **JPEG at quality 0.8**, and labelled as the screen with the cursor (primary focus) or a secondary screen.
- **Context.** Along with the images, HeyClicky gathers the frontmost app and bundle ID, the browser host, and the **open document**. The document is found through `AXDocument` (a file URL) or the browser's address bar (a web page). Its full text is extracted so the model can answer about parts that are scrolled out of view.
- **Pointing.** The model points back with **inline, tag-first text lines** in screenshot-pixel coordinates: `[POINT:x,y:label:screenN]`, `[TARGET:x,y,r:label]`, `[HOVER:…]`, `[HIGHLIGHT:…]`, `[SHAPE:kind:pts:label]` and `[TYPE:x,y:label]<<<…>>>`.
- **Execution.** The app maps these back to AppKit global coordinates. It flies a blue triangle "buddy" cursor along a Bézier arc to the spot and shows a speech bubble. It draws rings, highlights and shapes on transparent per-screen panels, and for `TARGET` and `HOVER` it waits for the user's click or hover, re-captures, and asks for the next step. That loop is the guided walkthrough.
- **OneBrain mode.** In the newer OneBrain mode the same ideas are expressed as JavaScript drawing programs (`point()`, `target()`, `hover()`, `task()`, `waitForUser()`, `onScreen()`), and the native host turns their pointer marks into the same guided targets.

---

## 2. Component map

| HeyClicky type (OBSERVED, from Swift metadata or file names) | Responsibility | OpenClicky module (proposed) |
|---|---|---|
| `CompanionScreenCaptureUtility` (enum, `CompanionManager` area), struct `CompanionScreenCapture`, nested `SettleSampler` | Full-desktop multi-display capture, region capture, "screen settled" sampling | `ScreenCapture/ScreenCaptureService.swift` |
| `ClickyWindowCapturePolicy` (+ `.Role`: `ambientChrome`, `cursorChromeHiddenFromOwnCapture`, `standalonePanel`) | Registers HeyClicky windows; decides `NSWindow.sharingType`; provides the window IDs excluded from its own captures | `ScreenCapture/WindowCapturePolicy.swift` |
| `ClickySystemWindowPickerYield` (+ `.Reason`: `windowPicker`, `missionControl`), `ClickySystemWindowPickerMonitor`, `ClickyMissionControlMonitor`, `ClickyCaptureUIState` | Steps transparent overlays aside while the macOS window picker, Mission Control or Screenshot UI is up | `Overlay/SystemUIYield.swift` |
| `ElementLocationDetector` | Anthropic computer-use "where to click" grounding (1024×768, 1280×800 or 1366×768 resize) | `Pointing/ComputerUseGrounder.swift` (optional) |
| `ActiveDocumentReader`, `ActiveDocumentContext`, `ActiveDocumentReference` (`webPage(fullAddress:)` or `file(fileURL:)`), `DocumentAccessNotice` | Reads the open document's full text (file or web page) | `Context/ActiveDocumentReader.swift` |
| `ClickyUsersFrontApp` | Tracks the user's last real frontmost app (ignoring HeyClicky itself) | `Context/FrontAppTracker.swift` |
| `DictationFocusContext` (+ `SurroundingText`) | Focused AX element, its role and frame, before/selected/after text, secure flag | `Context/FocusContext.swift` |
| `ScreenAnnotationManager`, `ScreenAnnotationOverlay`/`Panel`/`CanvasView`, `AnnotationStroke`, `DwellEvent` | "Draw to ask": highlighter strokes from cursor movement while the shortcut is held | `Context/DrawToAsk.swift` |
| `AnnotationAccessibilityHarvester` | AX text and controls inside the highlighted region | `Context/AXRegionHarvester.swift` |
| `CompanionManager+ResponsePipeline.swift`, `CompanionManager+Annotation.swift` | Tag parsing, pointing, guided walkthrough loop | `Pointing/TagParser.swift`, `Pointing/GuidedWalkthrough.swift` |
| `GuidedClickTarget`, `GuidedWalkthroughLog(.Entry)`, `RealtimeWalkthroughSync` | Guided-step state, walkthrough history, beat and audio sync | `Pointing/GuidedWalkthrough.swift`, `Pointing/BeatSync.swift` |
| `OverlayWindowManager` (+ `OverlayEntry`, `ScreenFrameKey`), `OverlayWindow`, `DetachedCursorClickPanel` | One click-through overlay panel per screen; the detached-cursor click target | `Overlay/OverlayWindowManager.swift` |
| `BlueCursorView`, `OverlayCursorPerformanceController`, `OverlayCursorStageView`/`MoverView`/`FlightTriangleView`, `PerformanceCursor*`, `OverlayCursorPointingFlightPath`, `OverlayCursorSpring`, `BuddyNavigationMode` | The animated buddy cursor (triangle body, bubble, navigation) | `Overlay/BuddyCursor/*` |
| `OverlayCursorSystemVisibilityMonitor`, `SystemCursorVisibilityProbe` | Hides the buddy cursor when the system cursor is hidden or the front window is fullscreen | `Overlay/CursorVisibilityMonitor.swift` |
| `ClickyPointerEventSource`, `ClickyPointerSample`, `ClickyPointerEvaluationDriver` | Global and local mouse event fan-out, plus a rate-limited evaluation driver | `Input/PointerEventSource.swift` |
| `GuidedTargetPulseLayers`/`LayerView`, `NotchDwellRingLayers`, `MutedSpeakerCountdownRing`, `CursorThinkingDotsView`, `CursorWaveformBars`, `CursorMessageBubbleView` | Halo, ring, pulse, thinking dots, waveform, word-reveal bubble | `Overlay/Adornments/*` |
| `AnnotationShapeOverlay(View)`, `AnnotationShapeKind` (`line`, `arrow`, `circle`, `curve`, `polygon`) | Native shape and highlight overlays for the tag protocol | `Overlay/AnnotationShapes.swift` |
| `ScreenDrawingPenCursorController`, `ScreenDrawingPenFollower`, `ScreenDrawingPenHandoff` | Buddy cursor "borrowed" as a pen while drawings render; cross-screen handoff | `Overlay/PenCursor/*` (pairs with `04-draw-2d.md`) |
| `ScreenDrawingStaleWatch` (+ `WatchedWindow`) | Clears drawings when the underlying window moves or changes | `Overlay/StaleWatch.swift` |
| `ClickyTakeOverController`/`Overlay`/`ConsentCard`, `ClickyUserInputBlocker`, `ClickyBackgroundCursorControl`, `ClickyDriveNotchState` | "Let me drive": the screen glow, input blocker, Esc to stop | `Overlay/TakeOverOverlay.swift` (agent side in `06`) |
| `HandoffRegionSelectOverlayManager`/`Panel`/`CanvasView`/`DimLayers`, `HandoffPostDragActionBarView` | Drag-a-rectangle region capture with an action bar | `ScreenCapture/RegionSelectOverlay.swift` |
| `NotchWindowManager`, `NotchPresenter`, `NotchPanel`, `NotchScreenInstance`, `NotchPanelViewState`, `NotchSystemOverlayCoordinator`, `NotchHoverTickScheduler` | Notch UI, one panel per display | `Notch/*` |
| `ScreenDrawingActionButtonPanel`, `ClickyEdgeShelf*`, `DetachedClickAgainToStopPill`, `NotchVoicePill` | Floating buttons and pills | `Overlay/FloatingButtons/*` |
| `DrawnOnboardingTour`, `ClickyTourJobCards`, `OnboardingTutorialStep`/`Phase`, `CompanionManager+OnboardingTutorial.swift` | Onboarding tour, its steps and its finale | `Onboarding/*` |

Note: the task brief says "ScreenshotManager", but 1.1.2 has no such type. What it has is `CompanionScreenCaptureUtility`, which calls Apple's `SCScreenshotManager.captureImage(contentFilter:configuration:)`. OBSERVED: class ref `_OBJC_CLASS_$_SCScreenshotManager` and selector `captureImageWithFilter:configuration:completionHandler:` in the function at `0x102686c64`.

---

## 3. Permissions, entitlements, Info.plist

OBSERVED (`Contents/Info.plist`, `codesign -d --entitlements -`):

- `LSUIElement = true`: an agent app with no Dock icon by default. Setting `show_in_dock` reads "Turn off to keep HeyClicky notch only."
- `NSScreenCaptureUsageDescription`: screen recording is needed to see the screen.
- `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription` and `NSDownloadsFolderUsageDescription` share one purpose string (paraphrased): the app opens the document currently on screen so its answers can cover the entire file rather than only the visible part.
- `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` (see `02`).
- Entitlements:
  - `com.apple.security.app-sandbox = false`
  - `cs.allow-jit` (JavaScriptCore drawing)
  - `device.audio-input`, `device.camera`, `network.client`
  - `temporary-exception.mach-lookup.global-name = com.apple.screencapturekit.picker`, which allows the system content-sharing picker.

TCC permissions modelled in `CompanionManager` (OBSERVED fields `_hasAccessibilityPermission`, `_hasScreenRecordingPermission`, `_hasScreenContentPermission`, `_hasMicrophonePermission`; persisted under `persistedPermissionSnapshot.*`):

- **Screen Recording**: checked with `CGPreflightScreenCaptureAccess`, which is the only CG screen-capture permission API imported. Deep link: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture`.
- **Screen Content**: a separate step that proves capture works by taking one **test screenshot**.
  - OBSERVED strings: "Let HeyClicky take one test screenshot.", "Pick a display to finish.", "You stay in control of which display gets shared." and "Screen content is ready."
  - The log line "Screen content capture result width/height/didCapture/source" fires once per attempt.
  - INFERRED: on newer macOS this goes through the system content-sharing picker (hence the mach-lookup exception and `pendingScreenContentPickerSourceRectInScreenSpace`).
- **Accessibility**: `AXIsProcessTrusted`. Needed for app, document and focus context, text insertion, AX target snapping and the takeover.
- **Files & Folders**: used lazily when reading a document in Desktop, Documents, Downloads or iCloud Drive; denial is handled (§5.2).
- Privacy promises in the UI copy (OBSERVED): "HeyClicky only captures pixels during an explicit help request." and "I only see your screen when you press the hotkey." In other words, there is **no background screen watching**. The only continuous sampling is the short-lived settle sampler during an active guided step (§4.4).

The permission coach uses the buddy cursor to point at System Settings rows. OBSERVED: `BlueCursorView.__permissionCoach*` fields, `permissionPrimaryButtonFramesInScreenSpace`, and the strings "Drag me into the Screen Recording list." and "Flip my toggle on."

---

## 4. Screen capture

### 4.1 Full-desktop capture pipeline (OBSERVED, `CompanionScreenCaptureUtility`)

The async entry point is at `0x102685110` and takes a single `Bool` (stored at async-frame `+0x229`). Every one of the 8 call sites passes the default argument, which `0x100006ef4` hard-wires to `false`. In practice, then, the "high-res" branch is never used.

Steps, in order:

1. `SCShareableContent.getShareableContentExcludingDesktopWindows(_:onScreenWindowsOnly:completionHandler:)`. If `displays` is empty, throw "No display available for capture".
2. Read `NSEvent.mouseLocation` (AppKit global coordinates, bottom-left origin) to find the cursor's screen.
3. Build the exclusion list (`0x102688b50`):
   - Ask `ClickyWindowCapturePolicy` (`0x101df983c`) for HeyClicky's registered "hide from own capture" windows.
   - Keep the `SCWindow`s whose `owningApplication.bundleIdentifier == Bundle.main.bundleIdentifier` and whose `windowID` is in that set.
   - Make `SCContentFilter(display:excludingWindows:)` from them.
4. Map `displayID` to `NSScreen` via `deviceDescription["NSScreenNumber"]`. Use `NSScreen.frame` (AppKit space) as the display frame. If no screen matches, fall back to `SCDisplay.frame`, `width` and `height`.
5. For each display, set `isCursorScreen = frame.contains(mouseLocation)` (`0x1012f5894`).
6. Configure `SCStreamConfiguration` (`0x10002b328`), sizing by aspect:
   - Long-edge target `L`. When the Bool is `false`, `L = 1280`. When it is `true`, `L = min(2000, max(1280, Int(max(widthPt, heightPt))))`. The constants `0x500` and `0x7d0` are visible at `0x10268733c` and `0x1026874d4`.
   - `aspect = widthPt / max(1, heightPt)`.
   - Portrait: `setHeight(L)` and `setWidth(Int(L × aspect))`. Otherwise `setWidth(L)` and `setHeight(Int(L / aspect))`.
   - `showsCursor` is **left at its default (true)**, so the system pointer appears in the screenshot. OBSERVED: no `setShowsCursor:` in this function. It is called explicitly with `false` only in the settle sampler, `0x10268a4e8`.
   - Supporting UI copy: "Each turn's screenshot of the display with your cursor stays in the conversation…"
7. `SCScreenshotManager.captureImage(contentFilter:configuration:)` returns a `CGImage`.
8. Encode with `NSBitmapImageRep.representation(using: .jpeg /*3*/, properties: [.compressionFactor: 0.8])` (immediate `0x3fe999999999999a` at `0x102686d54`).
9. Label each capture (`0x102687ab8`…`0x102687eac`), in OBSERVED wording:
   - single display: `user's screen (cursor is here)`
   - multiple displays: `screen {i} of {n} — cursor is on this screen (primary focus)` or `screen {i} of {n} — secondary screen`
10. If no display produced an image, throw "Failed to capture any screen".

Data shape (OBSERVED field names, `CompanionScreenCapture`):

```swift
struct CompanionScreenCapture {
  var imageData: Data            // JPEG, q=0.8
  var label: String              // see labels above
  var isCursorScreen: Bool
  var displayWidthInPoints: Int
  var displayHeightInPoints: Int
  var displayFrame: CGRect       // AppKit global (bottom-left origin)
  var screenshotWidthInPixels: Int
  var screenshotHeightInPixels: Int
}
```

Ordering: displays are enumerated in ScreenCaptureKit order, and `{i}` is 1-based from that enumeration (INFERRED). The order is not cursor-first. The model learns the primary screen from the label instead.

### 4.2 Keeping HeyClicky out of the picture

There are two separate mechanisms (OBSERVED in `ClickyWindowCapturePolicy` around `0x101df8800`–`0x101df9c40`):

- **Own captures.** Windows registered with the role `cursorChromeHiddenFromOwnCapture` (the buddy cursor overlays) are passed to `excludingWindows:`. So the model never sees Clicky's own cursor or bubbles, while things the user drew (draw-to-ask highlighter ink) **do** show up in the screenshot.
  - OBSERVED tutorial prompt fragment: the turn's screenshot shows the user's screen "WITH the drawn highlight".
  - The developer stats HUD is described as "Hidden from screenshots, so Clicky never sees it."
- **Other apps' recordings and screen sharing.** The policy keeps three weak `NSHashTable`s, one per role.
  - When it applies the policy, a window in one particular table always gets `sharingType = .readOnly` (1).
  - Every other window gets `.readOnly` if the user's **"Show in screen recordings"** setting is on and `.none` (0) otherwise. The setting key is `show_in_screen_recordings`, with the description "Let screen sharing and recording tools capture HeyClicky."
  - INFERRED: `standalonePanel` windows (the HeyClicky window, cards) always stay capturable. `ambientChrome` and cursor chrome follow the toggle.

### 4.3 Multi-display handling

- Every display is captured on every request (§4.1), and each image carries its label and display frame.
- Tags name a target display with `:screenN`, N being the 1-based label index (INFERRED from the regex suffix `:screen(\d+)` and the labels). Without it, the cursor's screen is used.
- Overlays are **per screen**:
  - `OverlayWindowManager.overlayEntries: [OverlayEntry{window, screenFrame}]`
  - `renderedBuddyPositionsByScreenFrame: [ScreenFrameKey: CGPoint]`
  - `NotchWindowManager.notchInstancesByDisplayIdentifier`
  - `ScreenAnnotationManager.overlaysByDisplayID`
  - `HandoffRegionSelectOverlayManager.overlayWindowsByScreenID`
- The buddy is drawn only where `isCursorOnThisScreen` is true. It hands across screens with the cursor.
- Display changes trigger a rebuild with state preservation. OBSERVED: `display configuration changed`, `isRebuildingOverlayForDisplayChange`, `overlay_hide:display_rebuild_suppressed`, `lastSeenDisplayFramesByID`.
- Drawings can render on a non-cursor screen: `onScreen(n)` (§6.6) and the analytics key `drew_on_other_display`. The pen cursor then "departs" one screen and "arrives" on another (`ScreenDrawingPenHandoff`, §7.7).

### 4.4 Capture variants

| Variant | Where (OBSERVED) | Behaviour |
|---|---|---|
| Region capture | `0x102683564` | `SCStreamConfiguration.sourceRect` in display points. Size accounts for `backingScaleFactor`. Encoded **PNG**. Errors: "That region is outside the screen", "Failed to encode the region". Handoff path: "No screen contains the selected rect.", "No SCDisplay matched the owning screen.", "Failed to encode rect capture as PNG." |
| Settle sampler (`CompanionScreenCaptureUtility.SettleSampler`) | `0x102689a54`, `0x102680570` | Repeatedly captures the cursor's display at **192 px wide** (`0xc0`) with `showsCursor = false`. Compares successive thumbnails and reports "settled" when the change drops below **0.5%** (`0.005`). The cap is **1.5 s**, after which it captures anyway. Logs: "Guided follow-up: screen settled after N samples, changed=…" and "…still changing at the 1.5s cap…capturing anyway". |
| Single-window capture | `SCContentFilter(desktopIndependentWindow:)` selector present | Used to snapshot HeyClicky's own drawing canvas or card windows ("pin: no picture of the card (the canvas window could not be captured)"). |
| Realtime voice attach | `0x102d961b0` → `0x102dcbb88` | Re-scales each capture to a long edge of **768 px** (one screen) or **640 px** (more than one; `0x4088…`/`0x4084…`). Re-encodes JPEG at **q = 0.6** (`0x100977190`). Sent as `input_image` with `image_url = data:image/jpeg;base64,…` and `detail: "auto"`, item id prefix `clkyimg`, via `conversation.item.create`. Then prunes older screenshot items: "prune stale screenshot (keep-latest-1)" using `conversation.item.delete`. In drawing mode it does not attach ("drawing mode: not attaching N screenshot(s) to the voice"). |
| Computer-use grounding resize | `ElementLocationDetector`, `0x1026fff30` | Picks the closest-aspect CU resolution from **1024×768 (4:3), 1280×800 (16:10), 1366×768 (~16:9)**, default 1280×800, then maps the returned coordinate back ("mapped (…) → display-local AppKit coords"). |
| Takeover zoom | `ClickyTakeOver.swift` strings | The computer tool's `zoom` needs `[x1, y1, x2, y2]` and returns `data:image/jpeg;base64,…` (agent side, `06`). |

### 4.5 System UI compatibility (edge cases handled)

- **Screenshot app / `screencaptureui`.**
  - When `com.apple.screenshot`, `com.apple.screenshot.launcher` or `com.apple.screencaptureui` activates, HeyClicky enters a "system capture compatibility mode": overlays hide (`overlay_hide:system_capture_compatibility`), and intro video and music pause, then resume.
  - A **hard timeout** force-exits the mode "so Clicky cannot stay hidden (issue #270)".
  - Clicks on drawings are ignored while the screenshot UI is up ("click ignored: the screenshot UI is up").
  - OBSERVED fields: `systemCaptureCompatibility*`, `ClickyCaptureUIState{isCaptureUIOnScreen,isWindowSelectionActive}`, `ClickyCaptureUIWindowDescription{ownerName,layer,bounds}`. INFERRED: detected with `CGWindowListCopyWindowInfo`.
- **System window picker and Mission Control.** `ClickySystemWindowPickerYield` posts `clickySystemWindowPickerYieldDidChange`, with the log "Stepping HeyClicky's transparent windows aside (reason)". Overlay and notch managers observe it, so the full-screen transparent panels don't intercept the picker. Reasons: `windowPicker` and `missionControl`.
- **Notch versus system overlays.** `NotchSystemOverlayCoordinator` tracks Spotlight, Control Center, SystemUIServer, Notification Center and Screenshot windows (OBSERVED bundle IDs) so the notch steps aside and focus returns properly (`returnToPID`, `waitingForPointerReturn`).
- **Space changes.** On "Active Space changed" the app is "clearing stale guided annotation marks (audio keeps playing)" (`annotationVisualsSuppressedAfterSpaceChange`).
- **App switch.** If the user switches apps mid-guide, the guide steps back ("came to the front (was …)", `guidedWalkthroughForegroundAppBundleIdentifier`). The model is told to give one short sentence and no visual tag.
- **Stage Manager.** The tutorial draw step detects it ("Stage Manager is on, handing the stage to the user's app"), using the `com.apple.WindowManager` `GloballyEnabled` key.
- **Non-interactive launches.** The background path skips capture: "live screenshot skipped (non-interactive launch)".

### 4.6 Where screenshots go (routes and model slots)

| Path | Payload (OBSERVED keys) | Slot |
|---|---|---|
| Classic companion `POST {WorkerBaseURL}/v2/chat` (`ClaudeAPI.swift`) | `base64_image_data`, `image_media_type`, `image_label`, `user_prompt`, `prompt_profile` (`voice_companion`, `text_companion`, `onboarding_demo`, `onboarding_tutorial_draw`), `response_model_selection`, `open_router_custom_model`, `open_router_verbosity`, `is_provider_fallback_retry`. SSE response: `message_start`, `content_block_start`, `clicky_tool_start`, `clicky_widget`, `clicky_error`, `[DONE]` | **brain** |
| Realtime "think deeper" `POST /chat-tool-call` (`send_to_higher_model`, guided follow-ups) | `screenshots[]` with `screenshotBase64`, `screenshotWidthInPixels`, `screenshotHeightInPixels`, `screenNumber`, label; `previous_screenshots` ("earlier view: sending N previous screen(s)"); `history`; `currentUserText`; `currentMessageTimestamp`; `annotation_gesture`; `annotation_elements`; `guided_session`; `active_document`; `frontmost_browser_host`; `frontmost_app_bundle_id`; `clicky_offers`; `recent_agent_suggestions`; `connected_integrations`; `client_capabilities`; `userAttachedImages`. Response: answer text with visual tags, plus `widgets`, `agentHandoff`, `clickyOffer`, `annotationText`, `clipboardText`, and `guidedMaxRounds` (key string present) | **brain** |
| Realtime voice socket (session from `/agent/realtime/session`, see `02`) | `conversation.item.create` → `message`/`user` → `input_text` (label) + `input_image` (768/640 px, q 0.6, `detail:auto`). The voice model's tool list includes `capture_screen` ("Looking at your screen") | **voice** (a realtime speech model that accepts image input) |
| OneBrain `POST /brain/turn` (gzip; header `x-clicky-accepts-gzip`) | Turn context keys include `front_app`, `front_app_bundle_id`, `time_label`, `time_zone`, `drawing_on_screen`, `highlight`, `gesture`, `live_state`, `walkthrough_step`, `other_screens`, `screenless`, `takeover`, `attached_images`, `screenshot_files` / `screenshot_file` (screenshots by reference, with a full-image fallback: "screenshots by reference refused: sending them in full for the rest of this session"), `access_denied`, `user_context`, `max_rounds`, `turn_items`. Capability flags include `app_reads`, `brain_model`, `figures_float`. The setting `ClickyOneBrainKeepsScreensInHistory` keeps old screenshots in the thread and compaction folds them away | **brain** (screenshots + tool calls + `computer_calls`) |
| Codex agent launch | `[Codex] Attached screenshot as localImage (…)`; screenshot files are also listed as local paths ("Attached screenshot files:") | **agent** (`06`) |
| `ElementLocationDetector` | Anthropic Messages API (Info.plist `AnthropicMessagesURL`), header `anthropic-beta: computer-use-2025-11-24`, tool `computer_20251124` | **other: computer-use grounding** (§6.8) |

OBSERVED in the user's data: OneBrain threads (`OneBrain/<session>/threads/*.json`) store only text items (`message`, `reasoning`, `function_call`). User turns contain a `[This turn]` header and lines labelled `Front app:` and `Page open:`. Compaction notes have sections such as `SCREENS`, `SCREEN ACTIVITY` and `DRAWN`. Screenshots are **not** persisted locally in the thread.

---

## 5. Context gathering

### 5.1 Frontmost app and browser

- `ClickyUsersFrontApp` keeps `lastApplication: NSRunningApplication?` up to date from an activation observer, skipping HeyClicky itself.
  - It is sent as `front_app`/`front_app_bundle_id` (OneBrain) and `frontmost_app_bundle_id` (higher model).
  - It also appears in prompt text as `Front app: …` and `Page open: …`.
- **Browser detection** (OBSERVED bundle list in the ActiveDocument code, `0x101b40000`–`0x101b4a000`):
  - Safari and Safari TP; Chrome; Arc and Dia (`company.thebrowser.*`); Brave (and beta); Opera and Opera GX; Vivaldi; Firefox and Firefox Dev Edition; Edge; Zen; Aside; Perplexity Comet; ChatGPT Atlas (`com.openai.atlas`, `com.openai.chatgpt.atlas`); DuckDuckGo.
- The URL comes from the **address bar via Accessibility**, matched by identifier or description among `web_browser_address_and_search_field`, `urlandsearch`, `location_bar`, "address and search", "url field", "smart search field" and "search or enter website".
- Sent as `frontmost_browser_host`. For the agent harness it becomes the text "Context: the user currently has this page open in their browser: …"; the Chrome bridge is in `07`.
- **Window title is not sent as a dedicated field.** OBSERVED: no `window_title` key, although `AXTitle` and `AXWindows` reads exist for document and window lookups.

### 5.2 Active document (Desktop, Documents, Downloads usage strings)

`ActiveDocumentReader` (enum of static helpers):

1. Requires `AXIsProcessTrusted`. Calls `AXUIElementCreateApplication(frontPID)` and reads `AXFocusedWindow`, falling back to `AXWindows`.
2. **File**: `AXDocument` on the focused window gives a `file://` URL, which becomes `ActiveDocumentReference.file(fileURL:)`.
   - The file is read directly (hence the folder usage strings). PDF goes through PDFKit (`PDFDocument`, `page_count`); text files are read with a bounded read (`FileHandle` close is observed).
   - Kinds observed: `pdf`, `text_file`, `web_page`. Other types: UNKNOWN.
3. **Web page**: `ActiveDocumentReference.webPage(fullAddress:)`. Page text is collected from the browser's `AXWebArea` subtree (`AXStaticText`, `AXHeading`, `AXChildren`, struct `CollectedPageText`) under a **1.5 s deadline** (`0x101b461a4`).
4. Result shape (OBSERVED `ActiveDocumentContext`):

   ```swift
   struct ActiveDocumentContext {
     var kind: String            // "pdf" | "text_file" | "web_page" | …
     var reference: String       // path or URL
     var extractedText: String?
     var isTruncated: Bool       // JSON "truncated"
     var pageCount: Int?         // JSON "page_count"
     var fileAccessWasDenied: Bool // JSON "access_denied"
   }
   ```

   Sent as `active_document` to the higher model. The voice model is told (paraphrased) that the full text is available to the higher model, and that for document questions it must call `send_to_higher_model` rather than answer from the visible part of the screenshot.
5. **Timeout**: if extraction doesn't finish in time (likely blocked on a folder-consent dialog), the request goes ahead without it ("delegating without document context").
6. **Access denied**:
   - The app shows a notch `documentFolderAccessDenied` live event: "HeyClicky can't read this document" / "Allow access to your {Desktop|Documents|Downloads|iCloud Drive} folder".
   - It deep-links to `Privacy_FilesAndFolders`.
   - It counts how often the notice was shown (`clicky.documentAccess.noticeShowCount.v1`) and honours "don't show again" (`…noticeSuppressed.v1`).
   - The model is told to answer from what is visible.
7. Exact truncation length: UNKNOWN.

### 5.3 Focus and selection context

`DictationFocusContext` holds `element: AXUIElement`, `processIdentifier`, `appName`, `siteHost`, `role`, `elementFrame`, `beforeText`, `selectedText`, `afterText` and `isSecure`.

- It is built from `AXFocusedUIElement`, `AXSelectedText`, `AXSelectedTextRange`, `AXValue`, `AXNumberOfCharacters`, `AXSize`/`AXPosition`, and `AXSecureTextField`.
- Before reading, it flips `AXManualAccessibility`/`AXEnhancedUserInterface` for Electron and Chromium apps.
- It is used for dictation cleanup (keys `app_name`, `before_text`, `selected_text`, `after_text`, `single_line`, `site_host`) and for text insertion.
- **It is not attached to voice or brain turns as `selected_text`.** The brain sees selections through the screenshot (and, for draw-to-ask, the AX harvest).

### 5.4 Draw-to-ask (screen annotation as context)

**Gesture.** While the talk shortcut is held, moving the mouse paints **yellow highlighter ink** that follows the cursor. Tutorial copy: "highlight anything, then ask".

`ScreenAnnotationManager` constants (OBSERVED stores in its init at `0x102e51c40`):

| Field | Value |
|---|---|
| `strokeColor` | `NSColor.systemYellow` |
| `cursorPollInterval` | 1/60 s |
| `movementActivationThreshold` | 8 pt (ink starts only after moving 8 pt from the hold-start point) |
| `minimumPointSpacing` | 1.5 pt |
| `highlighterLineWidth` | 8 pt |
| `strokeFadeDurationSeconds` | 1.0 s |
| `activeStrokeFadeDurationSeconds` | 1.0 s |
| `dwellRadius` | 12 pt |
| `dwellMinimumDuration` | 0.35 s |

**Data.** `AnnotationStroke{points, pointTimes, startTime, endTime, dwells:[DwellEvent]}`. Pointer samples come from `ClickyPointerEventSource`.

**Window.** `ScreenAnnotationPanel` is borderless, clear, no shadow, **level 1000** (screen-saver), ignores mouse events, collection behaviour `[canJoinAllSpaces, stationary, fullScreenAuxiliary]`. One panel per display.

**Gesture description.** A natural-language summary is built from the strokes (OBSERVED fragments): "circled the …", "drew a line from the … toward the …", "drew a line across the …", "scribbled over the …", "pausing about Ns on the …", "the user drew N marks in order". It is sent as `annotation_gesture` (higher model) or `gesture`/`highlight` (OneBrain), and the model is told to treat it as exactly what the user means.

**AX harvest** (`AnnotationAccessibilityHarvester`):

- Hit-tests inside the highlighted region with `AXUIElementCopyElementAtPosition`.
- Text lines come from the parameterised attributes `AXRangeForPosition`, `AXLineForIndex`, `AXRangeForLine` and `AXStringForRange`.
- Controls are summarised with friendly role names (menu item, table cell, heading, radio button, checkbox, text field), with `(value: "…")` and `(linked from …)` when present.
- Sent as `annotation_elements` under the header "Accessibility data inside the highlighted region…". The model is told to use those exact strings and URLs.

**Visual result.** The ink is **visible in the screenshot** that goes to the model (§4.2).

### 5.5 Quiet and focus context

- `ClickyQuietContextReason` = `onCall` or `doNotDisturb`.
- `ClickyFocusModeReason` = `manuallyEnabled`, `scheduled` or `shownInMenuBar`, each with a mode identifier.
- These suppress proactive surfaces; they are not sent as screen context (see `08`).

---

## 6. Pointing: how the model's answer becomes visuals

### 6.1 Tag grammar (classic `/v2/chat` and realtime `/chat-tool-call` paths)

OBSERVED in `CompanionManager+Annotation.swift` (the regex builder at `0x101fcae00`) and `+ResponsePipeline.swift`. Coordinates are **pixels in the attached screenshot**, origin top-left. The number pattern is `-?\d+(\.\d+)?`.

The regexes are anchored per line: each visual beat line **starts** with the tag ("tag-first"), and the rest of the line is the sentence spoken for that beat. Any-tag detector: `\[(?:POINT|HIGHLIGHT|SHAPE|TARGET|HOVER):[^\]]*\]`.

| Tag | Numbers | Syntax | Meaning |
|---|---|---|---|
| `POINT` | 2 | `[POINT:x,y]`, `[POINT:x,y:label]`, `[POINT:x,y:label:screenN]`, or `[POINT:none]` | Fly the buddy cursor to (x,y) and show the label bubble. `none` means nothing to point at (analytics `point_none`). |
| `HIGHLIGHT` | 4 | `[HIGHLIGHT:a,b,c,d:label(:screenN)]` | A work-area rectangle. INFERRED convention `x,y,w,h`, matching the drawing engine's `highlight(x, y, w, h)`; `x1,y1,x2,y2` can't be excluded (UNKNOWN). |
| `TARGET` | 3 (or 2) | `[TARGET:x,y,r:label(:screenN)]` | Ring the control and **wait for the user's click**, then continue the walkthrough. If `r` is missing, a default radius is used (log "target missing radius fallback defaultRadius="). |
| `HOVER` | 3 (or 2) | `[HOVER:x,y,r:label(:screenN)]` | Like TARGET but completes when the cursor **rests** on it. |
| `SHAPE` | pairs | `[SHAPE:kind:x,y;x,y;…:label(:screenN)]`, kind ∈ `line`, `arrow`, `circle`, `curve`, `polygon` | Native shape overlay. For `circle` the convention is `cx,cy;ex,ey`: centre, then a point just outside the edge (OBSERVED in the tutorial prompt). |
| `TYPE` | 2 | `[TYPE:x,y:label(:screenN)]<<<\n…text…\n>>>` | Insert the text into the field at (x,y) "by sight" (`TextInjectionDelivery`). |

Sibling content tags handled in the same pipeline (out of scope here): `[IMAGES:…]` for image search cards (`ResponseCardOverlay.swift`).

Rules the client enforces or prompts for (paraphrased from short prompt fragments in the binary; the full server prompt is UNKNOWN):

- Use exactly one tag-first `TARGET` or `HOVER` per step, and only for an action Swift can observe (click, tap, focus, commit, hover reveal). One immediate action per TARGET sentence.
- For manual work the app can't detect (typing, dragging, sliders, choosing by taste), don't fake a target. Use `HIGHLIGHT` + `POINT` + `SHAPE:arrow`/`curve` and tell the user to say "continue".
- When `remaining click-to-advance turns` is 0, emit no `TARGET`.
- When grounding says to step back (the user switched apps), reply with one warm sentence and no tag.

### 6.2 Coordinate mapping (OBSERVED math, `0x10267ce98`)

```
cap = captures[screenN-1] ?? captures.first(where: isCursorScreen)   // selection rule INFERRED; math below OBSERVED
x' = clamp(x, 0, cap.screenshotWidthInPixels)
y' = clamp(y, 0, cap.screenshotHeightInPixels)
sx = cap.displayWidthInPoints  / cap.screenshotWidthInPixels
sy = cap.displayHeightInPoints / cap.screenshotHeightInPixels
appKitX = cap.displayFrame.minX + x' * sx
appKitY = cap.displayFrame.minY + (cap.displayHeightInPoints - y' * sy)   // flip to bottom-left
```

The result is stored in `CompanionManager._detectedElementScreenLocation`, `_detectedElementDisplayFrame` and `_detectedElementBubbleText`. Logs: "Element pointing: (x, y) → "label"", "no target screen capture", "no element". Analytics: `element_pointed` with `element_label`.

The `[TYPE]` path uses the same mapping and then refuses when the point "is outside screenshot bounds" or "has no usable AX input and is outside the focused field". In those cases the text goes to the clipboard instead (see `08` for the text-injection details).

### 6.3 Beats and speech sync (`RealtimeWalkthroughSync`)

- A higher-model answer can hold several beat lines. Each beat's visual is released when audio playback reaches that beat's share of the spoken text, minus a lead.
- OBSERVED fields: `beatFractions: [Double]`, `drawLeadFraction`, `playbackFraction`, `isFinished`, `reachWaiters[(threshold, continuation)]`, `finishWaiters`.
- Methods: `waitUntilReached(index:)` and `waitUntilFinished()`.
- Logs: "[walkthrough-sync] init beatFractions=… drawLead=…" and "release threshold=… at playbackFraction=…".
- `walkthroughPlaybackPollTask` polls the realtime player for the playback fraction.
- **Speaking.** When the app renders guided visuals itself, the tool result tells the realtime voice model to say nothing more (status `app_spoken_guidance`/`visual_guidance_shown`). The app speaks the beat lines itself through the `speak_line` path. Separately, an instruction asks the voice model to speak exactly the human instruction after `[clicky update]` and nothing else.

### 6.4 Guided walkthrough state machine (`GuidedClickTarget` and `CompanionManager+Annotation`)

OBSERVED `GuidedClickTarget` fields:

```swift
struct GuidedClickTarget {
  var id: UUID
  var screenLocation: CGPoint      // AppKit global
  var displayFrame: CGRect
  var radius: CGFloat              // floor ≈ 28 pt (constant near "guided target arm")
  var elementLabel: String?
  var spokenInstruction: String?
  var promptProfile: ClaudePromptProfile  // voiceCompanion|textCompanion|onboardingDemo|onboardingTutorialDraw
  var followUpRound: Int
  var activatedAt: Date
  var missedClickCount: Int
  var isHoverTarget: Bool
  var elementFrame: CGRect?        // set when snapped to an AX control
}
```

States (INFERRED from the logs and fields):

```
idle
 └─(answer with TARGET/HOVER)→ armed            log "guided target arm label x y radius round"
armed
 ├─ leftMouseDown inside radius/elementFrame → hit       "Guided target hit label=… distance=…pt hoverRest=false"
 ├─ cursor rests on hover target            → hit       "Guided hover-rest complete — advancing"
 ├─ click elsewhere                         → ended     "Guided target off-target click — ending guide (no nag), cursor stays parked"
 ├─ app switch / Space change               → stepped-away (quiet exit, visuals cleared)
 ├─ expiry or rounds exhausted              → ended     "Guided target expired or maxed out" / "suppress max-round"
 └─ user presses Esc / new turn             → cancelled
hit
 └→ settle: SettleSampler (≤1.5 s, Δ<0.5%) → full capture
    → POST follow-up (route /chat-tool-call in voice mode; analytics "guided_click_follow_up")
       body includes session_goal, prior_instruction, target_label, completed_steps,
       walkthrough log ("What has happened in this walkthrough so far, oldest first")
       and remaining-rounds count
    → next answer: new TARGET/HOVER (round+1) | HIGHLIGHT/POINT + "say continue" | completion line (no tag)
```

Details:

- **Post-target grace.** User activity right after a hit is ignored for a short window ("ignored … during post-target grace"). If the user acts while the follow-up is in flight, the app re-captures once before showing the next visual ("noticed user activity while waiting — will refresh"). The request then carries a freshness note telling the model the new screenshot is the only truth.
- **Max rounds.** `guidedClickTargetMaximumRounds` comes from the server (`guidedMaxRounds` / `guided_max_rounds`). Its exact value is UNKNOWN.
- **Walkthrough log.** `GuidedWalkthroughLog{entries:[{recordedAt, line, isWalkthroughActivity}], latestTask}`, with log lines "guided walkthrough step recorded" and "click recorded". Completed entries read like "Clicked guided target: …" and "Hovered guided target: …".
- **Parking.** After pointing, the buddy stays parked at the mark (`isParkedAtAnnotationMark`) until the user moves the mouse away from `annotationParkMouseBaseline`.
- **Analytics.** `annotation_walkthrough_started`, `annotation_walkthrough_completed`, `annotation_mark_shown` (`is_hover`, `radius`, `shape_kind`, `shape_point_count`, `shape_filled`, `beat_count`, `point_count`, `highlight_count`, `shape_count`, `target_count`), `screen_drawing_completed` (`target_armed`, `follow_up_round`, `display_count`, `drew_on_other_display`, …).

### 6.5 AX snapping of targets

For each TARGET or HOVER, the app looks for a real control at or near the model's point and snaps the ring to its frame.

- OBSERVED logs: `target "…": snapped to the control … from the model's …` and `kept the model's box, no control found (… ms)`.
- Role list used for snapping (OBSERVED, `0x101fe39e8` region): `AXButton`, `AXMenuItem`, `AXPopUpButton`, `AXSearchField`, `AXIncrementor`, `AXColorWell`, `AXDockItem`, `AXLink`, `AXMenuButton`, `AXRadioButton`, `AXDisclosureTriangle`, `AXToolbarButton`, `AXSwitch`, `AXMenuBarItem`, `AXCheckBox`, `AXTextField`, `AXCell`.
- Containers are skipped: `AXWebArea`, `AXScrollArea`, `AXSplitGroup`, `AXApplication`, `AXLayoutArea`, `AXList`, `AXTable`, `AXOutline`.
- Once snapped, the pulse draws as a **control outline** (`GuidedTargetPulseLayers.isControlOutline = true`, using the control's corner radius) instead of a circle.

### 6.6 OneBrain drawing-program pointers

In OneBrain mode the model writes a JS drawing program (engine in `04-draw-2d.md`). `Contents/Resources/clicky-draw-pieces.js` documents (paraphrased):

- `point(x, y, label)`: the pen rings the exact spot and names it in a pill.
- `target(x, y, w, h, label)` and `hover(…)`: identify the control by its top-left box. The app highlights the actual UI element and then waits until the user clicks it or hovers over it. The older form `(x, y, r, label)` still works.
- When the host draws pointers natively (`__hostPointers()`), the program emits an invisible marker carrying `role` (`target` or `hover`), `ring` radius, `box` and `label`. The native side turns it into a `GuidedClickTarget`.
- Walkthrough directives that draw nothing and are read from the program text:
  - `task(label)` names the how-to.
  - `waitForUser()` means the next step is manual work, so the guide waits for "continue". It replaces a target and is never combined with one.
  - `onScreen(n)` (first line only) renders on display n.
- `say("…")` lines are extracted with the regex `say\(\s*("(?:[^"\\]|\\.)*")`.
- Turn kinds include `walkthrough`, `walkthrough_step` and `tour_finale` (OBSERVED strings near the OneBrain turn code).

### 6.7 Outcome reporting to the voice model

After a higher-model answer the realtime tool result reports flags. OBSERVED log: "higher-model answered in …ms, widgets=, visuals=, pointed=, typed=, copiedToClipboard=, clipboardHandoff=, deliveryRefused=, …". Statuses: `widgets_shown`, `cursor_animated` (the buddy pointed), `visual_guidance_shown`, `text_typed`, `delivery_refused`, `copied_to_clipboard`, `routed_to_agent`.

The voice model uses these to avoid repeating or contradicting what is already on screen.

### 6.8 `ElementLocationDetector` (computer-use grounding)

OBSERVED in `0x102700444` and `0x1026fe600`:

- `POST` to the Info.plist `AnthropicMessagesURL`.
- Headers: `x-api-key`, `anthropic-version: 2023-06-01`, `anthropic-beta: computer-use-2025-11-24`.
- Body: `model`, `max_tokens = 256`, `tools = [{type: "computer_20251124", name: "computer", display_width_px, display_height_px}]`, and one user message with a base64 image plus a text prompt. Paraphrased, the prompt asks the model to click the UI element the question is about, or to answer "no specific element" for conceptual questions.
- The response is parsed for a `tool_use` input `coordinate`, which is scaled back from the CU resolution to display AppKit coordinates.
- URLSession timeouts: 15 s per request, 20 s per resource.
- Fields: `apiKey`, `apiURL`, `model`, `session`.
- Who constructs it in 1.1.2, which model it uses and where the key comes from are all UNKNOWN. It appears to be a legacy or fallback grounding path; the main path is the tag protocol.

Slot: **other: computer-use grounding**. It needs image input plus a computer-use-style tool that returns click coordinates.

---

## 7. Overlays and the buddy cursor

### 7.1 Window inventory (OBSERVED from init code; level is the `NSWindow.Level` raw value)

| Window | Style | Level | Mouse | Collection behaviour |
|---|---|---|---|---|
| `OverlayWindow` (one per screen, frame = `NSScreen.frame`) | `NSPanel` `[.borderless, .nonactivatingPanel]`, non-opaque, clear, `isFloatingPanel`, no shadow, `hidesOnDeactivate=false`, `isReleasedWhenClosed=false` | **1000** (screen saver) | `ignoresMouseEvents = true` | `[canJoinAllSpaces, transient, fullScreenAuxiliary]` |
| `DetachedCursorClickPanel` (small, at the detached buddy) | same | **1000** | receives clicks (`DetachedCursorClickCatcherView` with a tracking area) | same |
| `ScreenAnnotationPanel` (draw-to-ask ink) | borderless, clear | **1000** | ignores | `[canJoinAllSpaces, stationary, fullScreenAuxiliary]` |
| Panel built in `0x10155e254` (INFERRED: takeover glow or handoff chrome) | `[.borderless, .nonactivatingPanel]` | `CGWindowLevelForKey(kCGOverlayWindowLevelKey)` (=102) | ignores | `[canJoinAllSpaces, stationary, ignoresCycle, fullScreenAuxiliary]` |
| Response cards / place detail / paywall HUD | panels | 25 (status bar) | interactive | — |
| `ClickyEdgeShelf` (right-edge job dock) | panel | 27 | interactive | — |
| Other levels seen: 999, 101, 102, 28, 8, 4, 3, 2 | various cards and sticky windows | | | |
| `NotchPanel` (one per display) | non-activating panel; `isTemporarilyRefusingKeyStatus`; `NotchKeyboardFocusReleasePanel` used to drop key focus | UNKNOWN (must sit above the menu bar: `Surface.keepsAboveMenuBar`) | interactive | — |

The `sharingType` of every registered window is set by `ClickyWindowCapturePolicy` (§4.2).

### 7.2 Buddy cursor model

**Rendering.** A programmatic **triangle** (`CAShapeLayer`). The buddy has no image assets apart from Cat Mode atlases. It is rendered in three stages (`OverlayCursorStageRole`): `body` (the triangle and body pieces), `bubble` (speech bubble and streamed text), and `navigation` (the label bubble while pointing). Each stage is an `OverlayCursorStageView` hosting SwiftUI content in an `OverlayCursorMoverView`, driven by `OverlayCursorPerformanceController` (Core Animation; keys `cursor.follow.*`, `cursor.plan`, `cursor.flight`, `cursor.settle`, `cursor.standInFade`, `cursor.detached*`).

**Colour.** `OverlayCursorColorChoice`: `red`, `blue`, `yellow`, `green`. Setting `cursor_color` ("Sets the cursor and app accent color"), stored as `overlayCursorColorHex`. The type name `BlueCursorView` suggests blue is the default (INFERRED). **Cat Mode** (`ClickyCatModeEnabled`) swaps in sprite atlases (`catmode-red-overlay-atlas`, `catmode-red-notch-atlas`, in `Assets.car`) driven by `CompanionActorRenderer` poses (`cursor_idle`, `cursor_follow_left/right`, `point_left/right/up/down`, `guide_point`, `guide_wait`, `guide_success`, `travel_short/medium/long_left/right`, `return_home`, `celebrate`, `apologize`, …).

**Following the mouse.** `OverlayCursorSpring{response, dampingFraction}` and `OverlayCursorMoverMotion{spring, stepLifetimeSeconds, steps, plan{beginTime, stepSeconds≈1/120, positions}}`. The body trails the system pointer with a spring offset; the bubble can chase the body (`isBubbleChasingBody`).

**Navigation modes** (`BuddyNavigationMode`): `followingCursor` → `navigatingToTarget` → `pointingAtTarget` → (return) `followingCursor`. Follow rules are inputs to `PerformanceCursorFollowRuleInputs`: `buddyNavigationMode`, `isReturningToCursor`, `isParkedAtAnnotationMark`, `isCursorDetached`, `isClickyCursorDocked`, `isClickyCursorFlying`, `hasUserCompletedFirstVoiceTurn`, `voiceState` (`idle` | `listening` | `processing` | `responding`), `showStreamedCursorBubble`.

**Pointing flight** (OBSERVED in `0x102a384fc`):

```
distance = hypot(target - start)
duration = min(1.4 s, max(minDuration /*caller*/, distance / 800 pt·s⁻¹))
frames   = duration × 60            // NSTimer at 1/60 s on main run loop
path     = quadratic Bézier start → control → end
           control = midpoint, lifted by an arc height (constants 0.2 × distance and 80 pt appear; INFERRED min(0.2·d, 80))
pose(t)  = {position, rotationDegrees (faces travel direction), scale (“buddyFlightScale” swell mid-flight)}
```

On arrival the navigation bubble shows the model's label. Without a label, it shows a random phrase from `navigationPointerPhrases`: "right here!", "this one!", "over here!", "click this!", "here it is!", "found it!". The welcome bubble is "hi, im heyclicky". The triangle's resting tilt is about −35° (INFERRED from the recurring constant). Afterwards the cursor parks (§6.4) or returns (`isReturningToCursor`).

**Streamed bubble.** `CursorMessageBubbleView` reveals text word by word (`CursorMessageBubbleWordRevealModifier`), with placement from `CursorAdjacentPanelPlacement{isFlippedLeft, isFlippedAbove, originOffsetFromAnchor}`. Setting `agent_cursor_text_announcements`: "A job's reply streams in a bubble next to your cursor when it finishes."

**Thinking and voice.** `CursorThinkingDotsView` shows three dots that loop and then merge back into the triangle (`mergesIntoTriangleWhenDone`; keys `thinkingDots.gather/loop/settle/joinedPath`), holding the cursor body while thinking. `CursorWaveformBars` is a live mic-level waveform (`cursorWaveform.idleBreath`, `levelEase`).

**Docking.** Setting `dock_cursor` ("Hide floating cursor") makes the buddy fly into the notch (`isClickyDockFlightActive`, `isClickyDockSettleActive`; persisted in `clicky.cursor.docked.v1`) and back out on undock (`clickyCursorUndockFlight*`).

### 7.3 Visibility rules (`OverlayCursorSystemVisibilityMonitor`)

- Polls about every 0.1 s (tolerance 0.02) whether the **system cursor is visible**. It calls `CGCursorIsVisible`, looked up by name (OBSERVED string next to `OverlayWindow.swift`; the API is deprecated).
- It also polls `NSEvent.mouseLocation` and the time since the mouse last moved, and probes whether the **frontmost window is fullscreen** every 1 to 3 s.
- The buddy fades out (`systemCursorVisibilityOpacity`) when the system cursor is hidden (for example while typing, or during video). Subscribers receive `isBuddyVisibleForSystemCursor`.
- Other hide reasons (OBSERVED `overlay_hide:*`): `cursor_disabled`, `system_capture_compatibility`, `onboarding_reset`, `stop`, `permission_coaching`, `paywall_intro_*`, `display_rebuild_suppressed`.
- Background cursor control (`ClickyBackgroundCursorControl`) uses private WindowServer calls (`_CGSDefaultConnection` plus `CGSSetConnectionProperty("SetsCursorInBackground")`) so a background app can hide or set the system cursor. It degrades gracefully ("…unavailable: WindowServer symbols not found", "…refused by the WindowServer"). INFERRED: used while driving or detached.

### 7.4 Detached cursor (shake) and click-to-talk

- **Shake detection** (`BlueCursorView`, OBSERVED constants): within a 0.5 s sample window, at least **6 direction reversals** and at least **260 pt** of total path (noise floor 2 pt), with a 1.0 s cooldown. INFERRED: a shake detaches the buddy so it floats in place (`isCursorDetached`, `detachedCursorFloat`, animation keys `cursor.detachedEnter*`, `detachedPulse*`, `detachedHover`, `detachedExit*`).
- **Click to talk.** `DetachedCursorClickPanel` sits under the floating buddy. Clicking starts a voice turn and clicking again stops it ("click again to stop recording", `DetachedClickAgainToStopPill`). The buddy auto-reattaches after a while (`detachedCursorReattachTask`). Analytics: `cursor_detached`, `cursor_detached_click_start`, `cursor_detached_click_stop`, `cursor_detached_auto_reattach`.
- **Onboarding skip shake.** A stronger shake (1.5 s window, at least 8 reversals, at least 700 pt, 6 s cooldown) skips onboarding (`onboarding_skipped_by_shake`).

### 7.5 Halos, rings and pulses

- **Guided target ring.** `GuidedTargetPulseLayers{color, size, cornerRadius, cornerStyle, isControlOutline, isPulsing, visibility}` draws a ring or control outline with a "breathe" pulse (`guidedTargetPulse.breathe`), revealed by `guidedTargetRevealProgress`. `RenderServerGuidedTargetPulse` mirrors it for the render-server path.
- **Notch dwell ring.** `NotchDwellRingLayers` fills an arc (`notchDwellRing.fill`, `strokeEnd`) while the pointer hovers the notch. When the hover lasts long enough, the notch expands (`NotchHoverDwellState{startedAt, duration}`).
- **Countdown rings.** `NotchCountdownRingLayerView` (auto-dismiss clock) and `MutedSpeakerCountdownRing` ("Your Mac is muted" voice-reply surface).
- **Annotation highlight.** `BlueCursorView.annotationHighlightView(highlightRect:)` with animated `selectionProgress`, `scale` and `opacity`, auto-dismissed by `annotationHighlightAutoDismissWorkItem`.
- **Shapes.** `AnnotationShapeOverlayView{overlay, screenFrame, drawProgress, obstacleRects, inkColor}`. While a shape draws, the buddy traces it (`isTracingAnnotationShape`).

### 7.6 Pen cursor and pen follower (drawings)

While a drawing program renders (`04`), the buddy is **borrowed as the pen**: `isScreenDrawingPenBorrowed` and `isScreenDrawingPenOnCanvas`.

- **`ScreenDrawingPenCursorController`** runs its own triangle layer on the canvas. Fields: `containerLayer`, `triangleLayer`, `displayFrame`, `isOnCanvas`, `tintUsedForTriangle`, `standaloneTint`, `timeSource`, `strokes[{points, lengths, beginTime, duration, timing: ScreenDrawingUnitBezier}]`, `flights[{path: OverlayCursorPointingFlightPath, startTime, endTime}]`, `trajectoryPositions`/`Velocities`, `restWorkItem`. It follows each stroke's arc length over time and flies between strokes with the same Bézier flight model as pointing.
- **`ScreenDrawingPenFollower`** maps stroke progress to a pen position with smoothing: `strokePoints`, `cumulativeLengths`, `strokeStartTime`, `strokeDurationSeconds`, `penTiming`, `velocity`.
- **`ScreenDrawingPenHandoff`** moves the pen between overlay windows and screens with per-screen closures: `takeOver(center, tint)`, `handBack`, `depart(exit, seconds)`, `arrive`, `flyHome`, `returnNow`, `hideHere`. Associated state: `overlaysByScreen`, `departedScreenKey`, `awayScreenKey`, `reclaimHandlersByScreen`.
- **`ScreenDrawingStaleWatch`** clears a drawing that no longer matches the screen. Triggers: another window comes in front, the watched window moves (`WatchedWindow{windowNumber, bounds}` polled via the CG window list), scrolling past a threshold, or another app becoming frontmost.

### 7.7 Takeover ("I'll drive, you watch") overlay

This is the overlay side only; the agent and computer tool are in `06`.

- `ClickyTakeOverOverlay{panel, glowHolder, notchDriveToken, reduceMotion}` draws a screen-edge glow.
- `ClickyDriveNotchState` shows "HeyClicky is driving" with "Hands off the mouse while I drive. Esc stops me." in the notch. When the user moves the mouse: "You moved the mouse. I'm still driving."
- `ClickyUserInputBlocker` installs a `CGEventTap` (with a safety timer and generation counter) that swallows user input while acting and maps **Esc** to stop.
- If the user keeps moving the mouse, the drive pauses or hands back. Endings: `finished`, `userTookOver`, `safetyStop`, `couldNotSee`, `outOfAgentMessages`, `failed`.
- Tools: `offer_screen_takeover`, `start_screen_takeover`, `end_screen_takeover`. Consent comes first ("Offer first with offer_screen_takeover").

---

## 8. Notch UI and floating buttons

**Geometry.** One `NotchPanel` per display (`NotchScreenInstance{displayIdentifier, panel, hostingView, panelState, envelopeFrame, lastAppliedFrame}`).

- The hardware notch is located with `NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea` (OBSERVED imports) and `safeAreaInsets`.
- `NotchPanelViewState{visibleSize, notchScreenOrigin, presentationOverride, isFloatingSliver, isSuppressedForFullscreen, contentScale}`. INFERRED: displays without a notch get a floating sliver. A fullscreen app on that display suppresses the notch (fullscreen host probe, `clickyFullscreenHostDisplayChanged`).

**Presentation.** `NotchPresentation` is one of:

- `idle`
- `onboardingPinned`
- `textInput` (composer)
- `textResponse`
- `liveEvent(NotchLiveEvent)`. Screen-related cases: `activityListening`, `activityThinking`, `activitySpeaking`, `clickyDriving`, `clickyDriveConsent(id)`, `documentFolderAccessDenied(subtitle, showsDontShowAgain)`, `restingMark(isCursorDocked)`, `dockedIdle`, `handoffSent`/`Queued`, and others.

`NotchActivityPhase`: `listening`, `thinking`, `speaking`, `docked`, `dictation(label, isRecording)`, `agentMulti(count)`, `custom(label)`. Tabs (`ClickyNotchTab`): `home`, `chat`, `settings`, `document`.

**Hover and interaction.**

- `NotchHoverTickScheduler` runs pointer-driven ticks plus a housekeeping timer.
- Hovering the notch arms the dwell ring, then expands; "pointer at the top edge while tucked" is another opener.
- The chat session opens via `doubleControl`, `composerClick`, `chatTab`, `fileDrag`, `fileDrop` or `send`, and closes on `escape`, `doubleControl`, `clickElsewhere`, `dragAbandoned`, `leftChatTab`, `notchFolded` or `drawingCaption`.
- Files dropped on the notch become attachments.
- The docked strip avoids covering the frontmost app's menu items (`_dockedStripWouldCoverFrontmostAppMenuItems`).
- Mission Control keeps the notch visible when configured (`keepsNotchVisibleThroughMissionControl`).

**Floating buttons and pills.**

- `ScreenDrawingActionButtonPanel`: buttons attached to a drawing mark (`mark`, `isLink`, `isAsk`, `isFinishedAsk`, `isRetired`, `isHiddenForFullScreenCard`, `isCoveredByNotch`; single-use press latch). Used for "Show me" and the tour's question chips.
- `ScreenDrawingCardDragHandles`.
- `ClickyEdgeShelf`: right-edge dock of job cards, level 27.
- `HandoffPostDragActionBarView`: Send with text / Send with voice / Don't send yet, after a region drag.
- `DetachedClickAgainToStopPill`.
- `NotchVoicePill`.

**Region select overlay.** Per-screen dim layer with a selection border and banner. Banners: "Drag to capture screenshot · Esc or right-click to cancel", then "Pick an action below · Esc or right-click to cancel". The result is a PNG region capture (§4.4).

---

## 9. Tours and walkthroughs

- **Onboarding tutorial.** `OnboardingTutorialStep` = `micCheck`, `speakerCheck`, `voiceHello`, `clickyInterview`, `drawDemo`, `drawToAsk`, `clickyDrive`, `textMode`, `emailDraft`, `dictation`, `finale`. Phase: `inactive`, `invitePresented` or `running(step)`.
  - **`drawDemo`**: the app captures the screen and asks the brain (`prompt_profile = onboarding_tutorial_draw`) to "draw attention to something interesting". The reply must be 2–3 tag-first beat lines with at least one enclosing `[SHAPE:circle:…]` or polygon (retries otherwise). It must also avoid the tour card's rect ("your previous pick landed under the tour card"). The request includes the image dimensions, and the card rect is logged as `cardRect`.
  - **`drawToAsk`**: the user highlights something while asking (§5.4). The prompt tells the model whether the highlight is on the tour card or elsewhere.
  - **`clickyDrive`**: a scripted takeover demo in Preview ("Making your photo pop", Adjust Color) and Logic-style examples.
- **Drawn onboarding tour and finale.**
  - `DrawnOnboardingTour` uses the interview answers to draw personal "how I'd help" cards. The finale is prefetched on the finale page (`DrawnOnboardingFinalePrefetch` with a `CommitGate`), and pressing **Show me** triggers the OneBrain turn kind `tour_finale`.
  - `DrawnOnboardingNotchShowcase` pops the notch and sample integrations.
  - `ClickyTourJobCards` places job cards on screen, parks or tucks them, and adds question buttons (`ScreenDrawingActionButtonPanel`). It records `card_clicked_during_tour` and `notch_clicked_during_tour`.
  - Requests that would start work during the tour are deferred (`not_during_the_tour`).
- **Guided walkthroughs.** These are the general guided-step mechanism of §6.4. In OneBrain mode, a "walkthrough" is a drawing program with `task()` plus target, hover or `waitForUser()` steps, and each guided step is reported back with `walkthrough_step` / `did_step`.
- **Job "user steps".** `ClickyJobUserStep{step, page, doneWhenURLContains, askedAt}`, watched by `ClickyJobStepWatcher`, lets a background agent ask the user to do one step (for example sign in). It completes when the browser URL matches (cross-ref `06` and `07`).

---

## 10. Timing and latency

| Item | Value | Status |
|---|---|---|
| Screenshot long edge | 1280 px (1280–2000 only on an unused high-res flag) | OBSERVED |
| Screenshot JPEG quality | 0.8 | OBSERVED |
| Realtime image long edge / quality | 768 px (1 screen), 640 px (more than 1) / 0.6 | OBSERVED |
| Realtime screenshot retention | keep only the latest screenshot item | OBSERVED |
| Settle sampler | 192 px wide, Δ < 0.5%, cap 1.5 s, cursor hidden | OBSERVED |
| Web page text collection deadline | 1.5 s | OBSERVED (constant), INFERRED (meaning) |
| Pointer flight | duration = min(1.4 s, max(min, d/800)), 60 fps | OBSERVED |
| Draw-to-ask sampling | 60 Hz; ink after 8 pt; dwell 12 pt / 0.35 s; fade 1.0 s | OBSERVED |
| Visibility monitor | ~0.1 s poll; fullscreen probe 1–3 s | OBSERVED (constants) |
| CU grounding request | 15 s request / 20 s resource timeout; `max_tokens` 256 | OBSERVED |
| Guided target radius floor | ≈ 28 pt | OBSERVED (constant), INFERRED (meaning) |
| PTT release → realtime commit | 400 ms tail ("scheduling 400ms tail, then commit") | OBSERVED (see `02`) |

---

## 11. Edge cases the code clearly handles

- No displays → error. A partial capture is accepted. A display with no matching `NSScreen` falls back to `SCDisplay` geometry.
- Screen Recording missing → "Screen capture failed — HeyClicky may be missing Screen Recording permission…". The model answers without the screen or asks for the permission. The notch shows the permission flow.
- Tag coordinates outside the image are clamped. A missing `screenN` uses the cursor screen. A missing TARGET radius uses the default. `[POINT:none]` is valid.
- The user clicks elsewhere during a guide → the guide ends quietly ("no nag") and the next turn learns the step was probably not done.
- The user acts while the follow-up is in flight → one re-capture plus a "freshness" note. A screen that keeps changing is captured anyway after 1.5 s.
- Space or app switch → visuals are cleared, audio continues, and the guide steps back.
- Text insertion refuses secure fields, address bars, HeyClicky's own UI and multi-line text into single-line fields (newlines are collapsed). It falls back to the clipboard ("press Command-V").
- Document reads blocked by a consent dialog or a denial → proceed without the document, show a notch notice once, and allow suppressing it.
- Screenshot app, window picker and Mission Control → overlays step aside, with a hard timeout so they always come back.
- Display reconfiguration → rebuild per-screen windows while preserving buddy positions.
- Reduce Motion is honoured in cursor, takeover and onboarding animations (`accessibilityDisplayShouldReduceMotion`, `reduceMotion` fields).

---

## 12. Model slots used by this subsystem

| Use | Server route | Slot | Needed capabilities |
|---|---|---|---|
| Answer about the screen and emit pointing tags (classic text and voice companion) | `/v2/chat` | **brain** | Image input (1–N JPEGs with labels), streaming text, a stable tag grammar in screenshot pixels, optional tools/widgets |
| Realtime "think deeper", guided follow-ups, draw demo | `/chat-tool-call` | **brain** | Image input (current + previous screenshots), long context (document text), tool use, returns visuals + spoken text + optional text to type |
| Realtime voice sees the screen | realtime socket from `/agent/realtime/session` | **voice** | Realtime speech-to-speech with **image input** items and tool calling (`capture_screen`, `send_to_higher_model`) |
| OneBrain turn with screenshots, drawing programs, computer actions | `/brain/turn` | **brain** | Image input (by reference or inline), tool calling, code-like drawing output, computer-use actions |
| Element grounding | `AnthropicMessagesURL` (`/v1/messages`) | **other: computer-use grounding** | Vision + computer tool returning `{coordinate:[x,y]}` at 1024×768, 1280×800 or 1366×768 |
| Takeover driving | via OneBrain or agent (`06`) | **agent** / **brain** with computer use | Click, type, keypress, scroll, zoom on screenshots |

---

## 13. Rebuild plan (OpenClicky)

Proposed Swift modules (macOS 14.2+, non-sandboxed, matching HeyClicky's deployment target):

1. **`ScreenCapture/ScreenCaptureService.swift`**
   - `func captureAllDisplays(highRes: Bool = false) async throws -> [ScreenCapture]`
   - `func captureRegion(_ rect: CGRect) async throws -> Data /*PNG*/`
   - `func waitForSettle(cap: TimeInterval = 1.5, threshold: Double = 0.005) async -> Int`
   - Implementation: `SCShareableContent` → per-`SCDisplay` `SCContentFilter(display:excludingWindows:)` → `SCScreenshotManager.captureImage` → JPEG 0.8, long edge 1280. Labels and the `ScreenCapture` struct exactly as in §4.1. Keep `showsCursor = true` for main captures and `false` for settle samples.
2. **`ScreenCapture/WindowCapturePolicy.swift`**
   - `register(_ window: NSWindow, role: .ambientChrome | .cursorChromeHiddenFromOwnCapture | .standalonePanel)`
   - `var excludedWindowIDs: Set<CGWindowID>`
   - A `showInScreenRecordings` setting that drives `sharingType`.
3. **`ScreenCapture/RealtimeImageAdapter.swift`**: downscale to 768 or 640 px, JPEG 0.6, build `conversation.item.create` with `input_image`, keep only the latest item.
4. **`Context/`**
   - `FrontAppTracker`.
   - `BrowserURLReader`: AX address-bar heuristics plus a bundle list.
   - `ActiveDocumentReader`: `AXDocument` → PDFKit or text; `AXWebArea` text walk with a 1.5 s deadline; access-denied handling and notch notice.
   - `FocusContext`.
   - `DrawToAsk`: pointer sampling, highlighter ink panel, gesture describer.
   - `AXRegionHarvester`.
   - Combined output: a `ScreenContext` value `{captures, frontApp, browserHost, activeDocument, gesture, axElements}`.
5. **`Pointing/TagParser.swift`**: a pure parser for `POINT`, `HIGHLIGHT`, `TARGET`, `HOVER`, `SHAPE` and `TYPE` over tag-first lines. It returns `[Beat{visual: Visual, spokenText: String}]`. Accept both `x,y,r` and box forms for TARGET and HOVER; for HIGHLIGHT accept `x,y,w,h` (configurable). Unit-test against the regex shapes in §6.1.
6. **`Pointing/CoordinateMapper.swift`**: the screenshot-pixel → AppKit-global mapping of §6.2 (clamp, scale, flip, offset).
7. **`Pointing/GuidedWalkthrough.swift`**: the state machine of §6.4. Covers `GuidedClickTarget`, AX snapping (§6.5), click and hover detection via `PointerEventSource`, post-target grace, settle → re-capture → follow-up request, max rounds, quiet exits, and the walkthrough log.
8. **`Pointing/BeatSync.swift`**: `RealtimeWalkthroughSync`-style release of visuals by speech playback fraction.
9. **`Overlay/OverlayWindowManager.swift`** + **`Overlay/BuddyCursor/`**
   - Per-screen `OverlayWindow` (level 1000, click-through, `[canJoinAllSpaces, transient, fullScreenAuxiliary]`).
   - The buddy: spring follow, Bézier flight (§7.2), bubble, phrases, thinking dots, waveform, colours.
   - `CursorVisibilityMonitor`, detached mode plus `DetachedCursorClickPanel`, docking into the notch.
10. **`Overlay/Adornments/`**: target pulse ring or control outline, highlight rect, shape renderer (line, arrow, circle, curve, polygon with draw-progress), dwell and countdown rings.
11. **`Overlay/PenCursor/`**: pen controller, follower and cross-screen handoff (interface with the drawing engine in `04`), plus `StaleWatch`.
12. **`Overlay/SystemUIYield.swift`**: screenshot-UI compatibility mode with a hard timeout, window-picker and Mission Control yield, Space-change clearing.
13. **`Input/PointerEventSource.swift`**: global and local `NSEvent` monitors, a menu-tracking bridge timer (1/60 s), a rest flush, and a subscriber fan-out. **`Input/UserInputBlocker.swift`**: a `CGEventTap` with Esc to stop, for takeover.
14. **`Notch/`**: notch geometry via `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`, a per-display panel, the presentation enum of §8, hover dwell, system-overlay coordination.
15. **`Pointing/ComputerUseGrounder.swift`** (optional): CU resolution pick and coordinate back-mapping behind a provider-neutral **grounding** slot.

JS side: nothing new beyond `04`. Make sure the drawing runtime exposes `point`, `target`, `hover`, `task`, `waitForUser` and `onScreen` markers that the native host can read as guided targets.

Provider-neutral slot interfaces OpenClicky should define for this subsystem:

- `BrainSlot.respond(screens: [ScreenCapture], context: ScreenContext, transcript: String, history: …) -> AsyncStream<BrainEvent>`, emitting tag-first beat text.
- `VoiceSlot.attachImage(jpeg:label:)`.
- `GroundingSlot.locate(image:size:question:) -> CGPoint?`.

---

## 14. Unknowns and open questions (summary)

- Server-side prompts that teach the model the tag grammar (only fragments are in the client). The exact `HIGHLIGHT` number convention, and whether `screenN` is guaranteed 1-based in label order.
- The value of `guidedMaxRounds` and other server-provided limits. The full JSON response schema of `/chat-tool-call` and `/brain/turn`.
- Who constructs `ElementLocationDetector` in 1.1.2, and where its model and key come from.
- The exact `NotchPanel` window level, and which `ClickyWindowCapturePolicy` table is "always capturable".
- ActiveDocument truncation length and full file-type coverage.
- How "screenshots by reference" (`screenshot_files`) are uploaded or addressed on the OneBrain Worker.
