# 01: HeyClicky type and source-file map

Subsystem: whole-app map of Swift source files, module types, bundle anatomy, permissions, resources and feature areas.
Target: HeyClicky 1.1.2 (build 69), bundle id `com.humansongs.clicky`, git branch `changelog/v1.1.2`, commit short SHA `9bd03d487` (from `Contents/Resources/ClickyBuildInfo.plist`).
Purpose: give the OpenClicky clean-room rebuild one index of every feature area, so the other subsystem docs (02 and later) can be checked for coverage.

Evidence labels used throughout:

- **OBSERVED**: seen directly in an artifact. The path and identifier are cited.
- **INFERRED**: my reasoning from names, neighbouring strings, or field layouts.
- **UNKNOWN**: the client cannot show it, for example server-side prompts, model routing, or pricing logic.

Secrets policy: this document gives Info.plist key *names* only. The values of `PostHogAPIKey`, `SentryDSN`, `SupabaseAnonKey`, `BrowserBridge/connection.json` and `CodexHome/auth.json` were not copied.

---

## 0. Method (how this map was built)

| Step | Tool | Output (scratch, not part of the repo) |
|---|---|---|
| Thin the universal binary | `lipo -thin arm64` | `/tmp/openclicky-re/type-map/HeyClicky.arm64` |
| String dump | `strings -n 6` | 109,314 lines |
| Source-file IDs | grep `HeyClicky/<Name>.swift` | **268** distinct `#fileID` strings |
| Full build paths | grep `/Users/nilesh/conductor/workspaces/clicky-closed/louisville-v1/leanring-buddy/...` | 29 `#file` paths that show the folder layout, plus 4 extra file names |
| Symbol table | `nm` | Only 4,953 symbols. The binary is stripped, so `nm` does **not** expose HeyClicky types |
| Type metadata | Custom read-only Mach-O parser over `__TEXT,__swift5_types`, `__swift5_protos` and field descriptors | 2,663 HeyClicky module types (1,903 unique top-level names) with field or enum-case names |
| Demangle | `xcrun swift-demangle` | Used for `_TtC9HeyClicky…` class names (337 Obj-C-visible classes) |
| Linkage, entitlements, plist | `otool -L`, `codesign -d --entitlements -`, `plutil -p`, `xcrun assetutil --info` | See sections 1 to 5 |
| File purposes | Cluster of `__cstring` literals around each `HeyClicky/X.swift` ID, plus type and field names | Purpose column in section 8 |

Why reflection metadata matters: `nm` is useless on this stripped binary, but Swift keeps nominal type descriptors for runtime reflection. These descriptors give type names, nesting, kind (class, struct, enum or protocol), superclass, and every stored-property or enum-case name. Field names such as `ClickyRoutine.intervalSeconds` and enum cases such as `PaywallReason.quotaExceeded` are the backbone of the data-shape descriptions below.

Module statistics (OBSERVED, arm64):

| Kind | All (incl. nested) | Top-level |
|---|---|---|
| struct | 1,413 | 1,082 |
| enum | 847 | 471 |
| class | 396 | 344 |
| protocol | 7 | 7 |
| file-private (anonymous-context) types | 735 | — |

The 7 module protocols are `AgentHarnessRuntime`, `OneBrainSpeechSocket`, `BuddyStreamingTranscriptionSession`, `BuddyTranscriptionProvider`, `PermissionDriver`, `PermissionGuideAssistant` and `RealtimeAudioPlaybackSink`. These are the natural seams for provider abstraction.

Caveat: the 268 `#fileID` strings only appear for files that use `fatalError`, `precondition`, `Logger` file capture and similar. Many types live in files that do not emit an ID, for example `OneBrainClient`, `ScreenDrawingClient`, `BuddyDictationManager`, `CodexProcessManager`, `CodexHomeManager` and `SupabaseAuthManager`'s helpers. So 268 is a lower bound on the file count. Four more file names appear only as full `#file` paths: `AVAudioPlayerNode+CatchingPlay.swift`, `CodexHomeSpaceCaches.swift`, `ScreenDrawing/Native/ClickyThreeKernel.swift` and `ScreenDrawing/ScreenDrawingSoundPlayer.swift`.

---

## 1. Bundle anatomy

| Path | What it is | Notes |
|---|---|---|
| `Contents/MacOS/HeyClicky` | Main app, universal x86_64 + arm64, ~122 MB, Swift/SwiftUI/AppKit | Xcode project name is `leanring-buddy` (sic). The `@main` type is `leanring_buddyApp`. Signed "Developer ID Application: Farzain Majeed (2UDAY4J48G)", hardened runtime |
| `Contents/Helpers/ClickyBrowserHost` | Universal Swift CLI, ~225 KB, links only Foundation/CFNetwork | Chrome **native-messaging host**. OBSERVED strings: `chrome-extension://`, `http://127.0.0.1:`, `Library/Application Support/Clicky/BrowserBridge`, `ClickyBrowserExtensionID.txt`. INFERRED behaviour: relays extension messages to a loopback HTTP server in the app, using `BrowserBridge/connection.json` (keys `port`, `token`). No entitlements |
| `Contents/Helpers/clicky-harness` | Universal ~132 MB **Bun 1.4.1 single-file executable** | OBSERVED: `Bun v1.4.1 (macOS arm64)`, `$bunfs/root/clicky-harness-arm64`, `node_modules/@earendil-works/pi-coding-agent`, `@silvia-odwyer/photon-node` (wasm image ops). Main binary string: "pi-coding-agent 0.87.1". Entitlements: `cs.allow-jit`, `cs.allow-unsigned-executable-memory`. This is the "h1" agent harness runner (see §8.11) |
| `Contents/Frameworks/Sparkle.framework` | Sparkle **2.9.6** (Autoupdate, Updater.app, Downloader.xpc, Installer.xpc) | Feed `SUFeedURL`; EdDSA key `SUPublicEDKey` |
| `Contents/Frameworks/Sentry.framework` | Sentry Cocoa **8.58.1** | DSN in `SentryDSN` |
| `Contents/Resources/PostHog_PostHog.bundle` | PostHog iOS/macOS SDK resource bundle (SDK statically linked; vendored libwebp for session replay) | Host `PostHogHost` |
| `Contents/Resources/PLCrashReporter_CrashReporter.bundle` | PLCrashReporter resources (used by PostHog crash-report processing) | |
| `Contents/Resources/` | 193 entries; see §5 | **No `CodexRuntime/` directory in this build**, see below |

**Bundled Codex runtime is absent (OBSERVED).** The binary still names a `CodexRuntime` resource and has the error case `bundledCodexRuntimeMissing`, with the user message "HeyClicky's bundled Codex runtime is missing from this build." It also has a fallback that finds a `codex` CLI on the Mac and launches `/usr/bin/env node`. Neither the frozen snapshot nor the installed `~/Applications/HeyClicky.app` (also 1.1.2/69) contains `Resources/CodexRuntime`. INFERRED: in 1.1.2 the default agent runtime is the `clicky-harness` ("h1") path, and the Codex app-server path only works when a Codex CLI is present. Doc 0x (agent) should confirm.

Build facts (OBSERVED, Info.plist): `LSMinimumSystemVersion` 14.2, `DTSDKName` macosx27.0, `DTXcode` 2710, `LSUIElement` true (no Dock icon by default, menu-bar/notch agent app; `ClickyDockWindowContent` and setting `_isClickyDockIconEnabled` add an optional Dock presence), `NSSupportsSuddenTermination` and `NSSupportsAutomaticTermination` false.

---

## 2. Info.plist (OBSERVED, `Contents/Info.plist`)

### 2.1 URL schemes

| `CFBundleURLName` | Schemes | Used for (INFERRED from strings) |
|---|---|---|
| `com.humansongs.clicky.auth` | `clicky`, `heyclicky` | Supabase OAuth sign-in callback (`auth_callback`, `ClickySignInCallbackGuard`), referral deep links (`clicky.referral.pendingDeepLinkCode.v1`), integration OAuth returns (`AgentIntegrationReturnDestination`), Stripe-style checkout return (`checkout_returned`) |

### 2.2 Privacy usage descriptions

| Key | Gist of the text (paraphrased) |
|---|---|
| `NSMicrophoneUsageDescription` | lets you talk to it |
| `NSSpeechRecognitionUsageDescription` | transcribes your voice (Apple Speech fallback) |
| `NSScreenCaptureUsageDescription` | needs screen recording to see your screen |
| `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription` | opens the on-screen document so answers can cover all of it, not just the visible part |

No camera, contacts, calendar, location or Apple Events usage strings are present, but see entitlements and frameworks below.

### 2.3 App configuration keys (names only)

| Key | Meaning |
|---|---|
| `WorkerBaseURL`, `CodexWorkerBaseURL` | both `https://api.heyclicky.com`, the "Worker" backend |
| `SupabaseURL`, `SupabaseAnonKey` | Supabase auth project (`mrpvynsdsnimuisyhkow`) |
| `OpenAIChatCompletionsURL` | `https://api.openai.com/v1/chat/completions` (direct-provider path in `OpenAIAPI.swift`; probably legacy, see §10) |
| `AnthropicMessagesURL` | `https://api.anthropic.com/v1/messages` (computer-use grounding in `ElementLocationDetector.swift`; see §10) |
| `PostHogAPIKey`, `PostHogHost` | analytics (`us.i.posthog.com`) |
| `SentryDSN` | crash and error reporting |
| `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, `SUScheduledCheckInterval` (3600 s) | Sparkle hourly checks, auto-install |

`AppBundleConfiguration.swift` reads these keys and lets `localhost` / `127.0.0.1` overrides apply for development (OBSERVED: neighbouring strings).

---

## 3. Entitlements and runtime permissions

### 3.1 Code-signing entitlements (OBSERVED, `codesign -d --entitlements -`)

| Binary | Entitlement | Why (INFERRED) |
|---|---|---|
| HeyClicky | `com.apple.security.app-sandbox` = false | Not sandboxed: it spawns agents, drives other apps through AX/CGEvent, and writes to `~/Library/Application Support/Clicky` |
| HeyClicky | `cs.allow-jit` | JavaScriptCore runs the drawing engine (`clicky-draw-*.js`, three.js kernel) |
| HeyClicky | `device.audio-input` | microphone |
| HeyClicky | `device.camera` | Declared; `camera_in_use` appears only as a call-presence signal (`ClickyCallPresenceDetector`). No camera capture code was found |
| HeyClicky | `network.client` | all networking |
| HeyClicky | `temporary-exception.mach-lookup.global-name` = `com.apple.screencapturekit.picker` | Talks to the ScreenCaptureKit content picker (permission kind `screenContent`) |
| clicky-harness | `cs.allow-jit`, `cs.allow-unsigned-executable-memory` | Bun/JavaScriptCore JIT |
| ClickyBrowserHost | none | — |

### 3.2 TCC permissions the app manages (OBSERVED: `PermissionKind` cases)

`microphone`, `accessibility`, `screenRecording`, `screenContent` (the ScreenCaptureKit picker grant). The app also probes:

- Automation (Apple Events) per target app. `AgentPermissionInspector` probes Pages, Numbers, TextEdit and Preview, with the `Privacy_Automation` deep link.
- Files & Folders. `CompanionManager+DiscoveryChannel` / `+EarlyStopRefund` hold the folder-access recovery notice with the `Privacy_FilesAndFolders` deep link.
- Speech Recognition (Apple fallback).

`com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission` is a leftover defaults key from the open-source ancestor.

---

## 4. Linked frameworks (OBSERVED, `otool -L` arm64) and what each implies

| Framework | Feature that uses it (INFERRED) |
|---|---|
| SwiftUI, AppKit, Combine, QuartzCore, CoreAnimation (`CoreAnimation*` types) | All UI; heavy custom `CALayer` animation ("render server" loops) |
| ScreenCaptureKit, CoreMedia, CoreMediaIO, CoreImage, ImageIO, Vision | Screen capture, screenshot encoding, OCR or element hints (`Vision`) |
| AVFoundation, AVFAudio, AudioToolbox, CoreAudio | Mic capture, duplex engine with echo cancellation (`aec_active`), playback, recording drawing videos |
| Speech | `AppleSpeechTranscriptionProvider` fallback STT |
| ApplicationServices, Carbon, IOKit | AX API, CGEvent taps (push-to-talk, Escape interrupt, input blocker), hotkeys, `CGSSetConnectionProperty` background-cursor trick |
| JavaScriptCore | Drawing engine (`clicky-draw-engine.js`, `clicky-draw-native.js`, `clicky-draw-pieces.js`) and 3D kernel (`clicky-three.js`, `clicky-three-parts.js`) |
| Metal, MetalKit, ModelIO (weak), Spatial (weak) | `DaVinci3D*` renderer, `ScreenDrawing3DStage`, `ClickyCanvasRenderer`, lesson print warp. Shader source is embedded as text and compiled at runtime |
| WebKit | `HomeSpaceWebPageSnapshotter`, HTML artifact previews, `ClickyBrowserSetup.html` |
| PDFKit, QuickLookUI, QuickLookThumbnailing | Document previews (`HomeSpacePDFPreview`, `HomeSpaceQuickLookPreview`), active-document reading |
| Charts | `HomeSpaceReplyChart`, referral money chart |
| `_MapKit_SwiftUI` | `PlaceWidget` / `PlaceDetailOverlay` maps |
| EventKit, Contacts, Photos | Weak-signal integrations (Apple Reminders/Calendar, contacts, photos for ink "polaroids"). No usage strings, so access is attempted only on demand. INFERRED |
| Network, SystemConfiguration | Loopback HTTP servers (MCP, OAuth callback, browser bridge) and network reachability for routines |
| CryptoKit, Security | PKCE (`code_verifier`), keychain (`ClickyKeychainStore`) |
| ServiceManagement | Launch at login |
| CoreData | INFERRED: PostHog / Sentry internals; no HeyClicky CoreData model found |
| MetricKit (weak), OSLog | Diagnostics |
| Symbols | SF Symbols effects |
| libcompression, libz | `ClickyRequestCompression` (gzip request bodies, header `x-clicky-accepts-gzip`), XLSX unzip (`SpreadsheetZipArchive`) |

---

## 5. Resources inventory (OBSERVED, `Contents/Resources`)

| Group | Files | Used by |
|---|---|---|
| Drawing engine JS | `clicky-draw-engine.js` (257 KB), `clicky-draw-pieces.js` (65 KB), `clicky-draw-native.js` (50 KB) | `ScreenDrawingNativeEngine` / `ScreenDrawingCanvas` in JavaScriptCore |
| 3D kernel JS | `clicky-three.js` (426 KB, three.js 0.186.1 slice), `clicky-three-parts.js` (41 KB) | `ClickyThreeKernel` (strings `clickyThreeBuild`, `3d_kernel_load_failed`) |
| Drawing fonts | `ClickyDraw-Barlow-{Regular,Medium,SemiBold}.ttf`, `ClickyDraw-PatrickHand.ttf`, `ClickyDraw-Barlow-OFL.txt` | Handwritten captions, ink notes |
| Agent configuration | `ClickyModelInstructions.md` (copied into `CodexHome/clicky-model-instructions.md`), `ClickyCodexModelCatalog.json` (14 models: `gpt-6-luna`, `gpt-6-sol`, `gpt-6.1-sol`, `gpt-6-astra`, `gpt-5.6-*`, `gpt-daybreak-*`, `gpt-5.5`, `gpt-5.4*`, `gpt-5.2`, `codex-auto-review`; Codex `model_catalog_json` schema) | `CodexHomeManager` |
| Bundled agent skills | `ClickyBundledSkills/{clicky-browser,vercel-deploy}` | Synced into `CodexHome/skills/` |
| Integration skills | `ClickyIntegrationSkills/{clickup,dropbox,gmail,googledocs,googletasks,hubspot,jira,linear,microsoft_teams,outlook,salesforce}/SKILL.md` | Activated per connected Composio toolkit |
| Hermes skill docs (vendored, MIT, per `ATTRIBUTION.md`) | `airtable.md`, `apple-notes.md`, `apple-reminders.md`, `blender.md`, `claude-code.md`, `claude-design.md`, `codex.md`, `excalidraw.md`, `findmy.md`, `github-*.md` (5), `google-workspace.md`, `imessage.md`, `linear.md`, `maps.md`, `notion.md`, `obsidian.md`, `ocr-and-documents.md`, `polymarket.md`, `powerpoint.md`, `spotify.md`, `youtube-content.md` | `HermesSkillCatalog`, the pre-sign-in "what should it be good at" picker |
| Browser | `ClickyBrowserExtensionID.txt` (Chrome Web Store id `bphdnlcghkpiaoiplkhfofpfboddahce`), `ClickyBrowserSetup.html` | `ClickyBrowserBridge`, `ClickyChromeSetupFlow` |
| Videos | `onboarding-intro-v2.mp4` (44 MB), `paywall-intro-v2.mp4` (26 MB), `clicky-drive-sample.mp4`, `clicky-spatial-demo.mp4`; remote HLS on `stream.mux.com` | Onboarding, paywall, tutorial |
| Music | `ff.m4a` (5.7 MB onboarding music), `eshop.mp3`, `enter.mp3` | Onboarding tutorial |
| Voice previews | `realtime-voice-preview-{alloy,ash,ballad,cedar,coral,echo,marin,sage,shimmer,verse}.mp3` (OpenAI voices); `gemini-voice-preview-*.mp3` (30 Gemini voices: achernar … zubenelgenubi); `voice-preview-{bright,bubbly,cheerful,expert,fun,gentle,hope,kid,lumen,original,polished,smooth,techy}.mp3` (persona styles) | `RealtimeVoiceCatalog`, `VoicePreviewStore` |
| UI sounds (80 `.wav`) | Agent cues (`agent-launch/-done/-close/-needs-you`), text chat (`clicky-text-open/-send/-receive/-close`), drawing beds and accents (`pencil-paper-bed`, `pen-screen-bed`, `eraser-bed`, `handwriting-bed`, `highlighter`, `pen-flick`, `stamp`, `tape`, `sticky-press`, `paper-place`, `photo-drop`, `build-3d`, `sparkle`, `whoosh`, `slide`), feedback (`ding`, `tada`, `nope`, `boing`, `gel-pop`, `badge-pop`, `copy-tick`, `type-keys`, `target-ping`, `tapback-thumbs-up`), reveals (`reveal-boot`, `home-reveal`, `hatching`), `skill-up/-down`, `connection-question`, `clicky-question`, `clicky-surprised` | `ClickyChimeWarmer`, `ScreenDrawingSoundPlayer` |
| Images | `AppIcon.icns`, `Assets.car` (55 named images: integration logos, onboarding screenshots such as `onboarding-keychain-allow-prompt`, `codex-*` screenshots, `ClickyCharacters` sheet 1678×937, `catmode-red-notch-atlas` / `-overlay-atlas` sprite atlases, referral sample avatars), `steve.jpg`, `clicky-preview-photo.jpg`, `codex-add-project.png` | Various |
| Developer leftovers | `AGENTS.md` (internal notes about the ancestor's `FloatingSessionButton.swift`, `ContentView.swift`, `ScreenshotManager.swift`), `LICENSE`, `ATTRIBUTION.md` | Not used at runtime |

---

## 6. Original source layout (OBSERVED from `#file` paths)

Root: `leanring-buddy/` (the Xcode target folder). Subfolders seen:

| Folder | Example files |
|---|---|
| `AgentHarness/` | `AgentHarnessRunnerRuntime.swift` |
| `ClickyCanvas/` | `ClickyCanvasRenderer.swift` |
| `HomeSpace/` | `HomeSpaceCoworkTranscript.swift`, `HomeSpaceSettingsContent.swift` |
| `Ink/Model/`, `Ink/Views/` | `ClickyInkNoteStore.swift`, `ClickyInkActionsStore.swift` |
| `Lessons/` | `ClickyRecentDrawings.swift` |
| `Notch/Window/` | `HeyClickyWindow.swift`, `HeyClickyWindowOpeningFlight.swift` |
| `OneBrain/` | `OneBrainGeminiTranscriber.swift`, `ClickyTourJobCards.swift` |
| `Performance/HUD/` | `CodexLaunchFlightLayerPlayer.swift`, `CoreAnimationVoiceWaveform.swift` |
| `ScreenDrawing/`, `ScreenDrawing/Native/` | `ScreenDrawingPinnedCards.swift`, `ClickyThreeKernel.swift`, `ScreenDrawingLiveCaption.swift` |
| (root) | `leanring_buddyApp.swift`, `OverlayWindow.swift`, `PermissionGuideAssistant.swift`, `RealtimeMicrophoneCapture.swift`, … |

SPM dependencies (OBSERVED, DerivedData `SourcePackages/checkouts`): `posthog-ios` (with vendored libwebp), `sentry-cocoa`, Sparkle. No other third-party Swift packages are visible.

---

## 7. Feature-area index (the rows)

Each row is one top-level, user-facing feature area. Columns:

- **Class**: `built-in` means everything runs on the client; `server-mediated` means the core logic or model sits behind api.heyclicky.com; `mixed` means both; `out-of-scope` means commercial plumbing OpenClicky need not copy.
- **Slot**: the typed model slot the area uses (`stt`, `voice`, `brain`, `agent`, `other:<name>`, `none`).

| # | id | Feature area | What the user sees | Class | Slot |
|---|---|---|---|---|---|
| 1 | `app-shell` | App shell and orchestration | Menu-bar/notch agent; one god-object (`CompanionManager`, 475 stored properties) wires everything; remote config | mixed | none |
| 2 | `notch-shell` | Notch UI | Panel hanging from the MacBook notch with tabs Home, Chat, Settings, Document; activity pill (listening, thinking, speaking, agent progress); transient surfaces | built-in | none |
| 3 | `hotkeys-input` | Global shortcuts | Hold-to-talk, text trigger, dictation hold, hands-free dictation toggle; double-tap modifier triggers; Escape to interrupt | built-in | none |
| 4 | `stt-mic` | Microphone and speech input ("ears") | Mic selection and failover, Bluetooth handling, streaming transcription of the push-to-talk press | mixed | stt |
| 5 | `voice-brain` | One Brain voice turns | Push-to-talk question about the screen gets a spoken and/or drawn answer; tool calls; session compaction; stats HUD | server-mediated | brain |
| 6 | `realtime-voice` | Voice output ("mouth") and voice picker | Low-latency spoken replies in a chosen voice and speed; always-on voice mode; voice previews | server-mediated | voice |
| 7 | `text-chat-widgets` | Typed chat and answer cards | Type into the notch; streamed answer; inline widgets (places, stocks, image gallery); response cards | server-mediated | brain |
| 8 | `lookup-tools` | Server lookup tools | Place search and photos, image search, stock quotes, web search, Spotify search, Google Calendar events | server-mediated | other:search-apis |
| 9 | `screen-drawing` | On-screen drawing and explanation | Hand-drawn pen strokes, captions, highlights, sticky cards, photos and 3D models drawn over the screen in sync with narration | mixed | brain |
| 10 | `drawings-library` | Saved drawings ("lessons") | Save a drawing, replay it inline or full screen, print it to a polaroid, export a video to Downloads | built-in | none |
| 11 | `pointing-annotation` | Cursor companion, pointing and guided walkthroughs | Animated companion cursor flies to UI elements, bubbles, circles or arrows, "click here" guided steps | mixed | other:grounding |
| 12 | `screen-context` | Screen and document context | ScreenCaptureKit screenshots, active document and browser page readers, capture-exclusion policy, call and focus detection | built-in | none |
| 13 | `dictation` | System-wide dictation | Hold a key, speak, cleaned-up text is typed into the focused field; learned corrections; custom vocabulary | server-mediated | stt (+ other:text-cleanup) |
| 14 | `agent-runtime` | Background agents ("Clickys" and "jobs") | Named persistent agents run multi-step jobs in project folders through Codex app-server or the bundled harness; turn leases; cost ledger | server-mediated | agent |
| 15 | `agent-output-ui` | Agent output surfaces (ink notes, edge deck, cards) | Jobs show as hand-drawn "ink" note pages, cards docked at the screen edge, arc progress card, sticky notes, result cards | built-in | none |
| 16 | `take-over-drive` | Computer use ("HeyClicky is driving") | Offers, then takes over mouse and keyboard to do steps in apps, with a consent card and user-input blocker | mixed | brain (+ agent) |
| 17 | `browser-bridge` | Chrome extension bridge | Connects the user's Chrome-family browser through an extension and native host, so agents act in signed-in sites | built-in | none |
| 18 | `integrations-connectors` | Connected apps and custom MCP connectors | Composio-managed app connections (Gmail, Calendar, Notion …), custom MCP servers with OAuth, Obsidian vault, contextual "connect X?" suggestions | server-mediated | other:tool-gateway |
| 19 | `skills-powerups` | Skills library ("power-ups") | Browse, activate and create skills that shape answers and agents; team sharing | mixed | other:skill-authoring |
| 20 | `routines-proactive` | Routines, crons, proactive suggestions, morning brief, meetings | Recurring agent jobs, suggested agents and tasks, "good morning" drawn brief, meeting countdowns, notifications | mixed | agent (+ other:suggestions) |
| 21 | `home-window` | Home space and HeyClicky window | Main window: suggestions page, conversations and transcripts, artifact previews, all settings pages | mixed | none |
| 22 | `file-previews` | Document viewers | Markdown viewer, XLSX/CSV grid viewer, PDF, QuickLook, web snapshots, animated images | built-in | none |
| 23 | `handoff` | Hand-off to another app | Attach to a target app (Claude, ChatGPT, terminals…), select screen regions, speak, deliver text + images by paste and Return | built-in | none |
| 24 | `onboarding-permissions` | Onboarding, tutorial and permission coaching | Pre-sign-in intro, interview, drawn tour, step tutorial, starter plan; permission guide that points at System Settings toggles | mixed | other:onboarding-plan |
| 25 | `character-persona` | Characters and portraits | Cloud-shaped companion faces, portrait packs (hair, outfits, expressions), sprite actor states, cat mode | built-in | none |
| 26 | `memory-profile` | Memory and user profile | Server memory profile, local `about-the-user.md`, learned how-tos, standing context for agents | mixed | other:memory |
| 27 | `account-auth` | Sign-in and account | Google sign-in through Supabase, keychain tokens, account deletion | server-mediated | none |
| 28 | `billing` | Plans, paywall and usage | Pro/Max plans, quotas per surface (messages, agents, dictation), extra-usage approval, early-stop refund | out-of-scope | none |
| 29 | `referral` | Referral programme | Referral codes, earnings estimator, payouts | out-of-scope | none |
| 30 | `updates` | App updates | Sparkle with idle-time install policy and "app updated" notice | built-in | none |
| 31 | `telemetry-diagnostics` | Analytics, tracing, crash and bug reports | PostHog events plus `$ai_*` LLM traces, Sentry, diagnostics report, error reporting to the Worker | out-of-scope | none |
| 32 | `audio-feedback` | Sounds and system audio | Chimes, drawing sound beds, temporary unmute of a muted Mac to speak a reply | built-in | none |
| 33 | `ui-kit` | Design system | `DS` buttons, paper / sketch / gel component kits, Core Animation loop hosts | built-in | none |

---

## 8. Feature-grouped file and type tables

Per area: files with a one-line purpose, then key types and data shapes. Field and case names are OBSERVED from reflection metadata. Purposes are INFERRED from names and neighbouring strings unless marked otherwise.

### 8.1 `app-shell`: App shell and orchestration

| File | Purpose |
|---|---|
| `leanring_buddyApp.swift` | SwiftUI `@main` app and `CompanionAppDelegate` bootstrap |
| `CompanionManager.swift` | Central `@MainActor` coordinator. It owns voice state, Codex tasks, routines, integrations, permissions, onboarding, notch and overlay managers, update state and every feature flag. Split by extensions below |
| `CompanionManager+NotchSurfaces.swift` | Decides which transient notch surface to show (notices, suggestions, meetings…) |
| `CompanionManager+ResponsePipeline.swift` | Common path from a user turn (voice or typed) to response presentation |
| `AppBundleConfiguration.swift` | Reads Info.plist service URLs and keys, with dev overrides |
| `AppRemoteConfig.swift` | Fetches `/app-config` (`ClickyAppRemoteConfigV1`): community links (WhatsApp, Reddit), feature-request and changelog URLs |
| `WindowPositionManager.swift` | Legacy window placement and System Settings deep-link helpers (AX main window, minimize button) |
| `GeneratedAssetSymbols.swift` | Xcode-generated asset catalog symbols |

Key types: `CompanionManager` (nested `CompanionConversationTurn`, `NotchHoverDwellState`, `ScreenDrawingClearing`, `PendingPermissionSystemPromptHandoff`), `CompanionAppDelegate`, `AppRemoteConfigManager`, `RuntimeConfig`, `ClickyInstallLocation`/`InstallLocationSection` (offer to move into /Applications), `ClickyHelpMenuItems`, `AppStateSection`.

`CompanionVoiceState` cases: `idle`, `listening`, `processing`, `responding`.

### 8.2 `notch-shell`: Notch UI

| File | Purpose |
|---|---|
| `NotchWindowManager.swift` | Creates the per-screen `NotchPanel`, tracks displays and fullscreen hosts, hands activation back to the previous app |
| `NotchPresenter.swift` | State machine for `NotchPresentation` (`liveEvent`, `idle`, `onboardingPinned`, `textInput`, `textResponse`) |
| `NotchRootView.swift` | Root SwiftUI view; context menu (Check for Updates, Log Out, "Read answers aloud" toggle) |
| `ClickyNotchTabs.swift` | Tab bar `ClickyNotchTab` = `home`, `chat`, `settings`, `document` |
| `NotchSettingsTab.swift` | Compact settings inside the notch |
| `NotchActivitySurface.swift` | Activity pill; `NotchActivityPhase` = `custom`, `agentMulti`, `dictation`, `listening`, `thinking`, `speaking`, `docked` |
| `NotchAgentSurface.swift` | Running-agent strip ("Agent working", "Using …") |
| `NotchAgentFileIndex.swift` | Index of files an agent produced, for the notch peek |
| `NotchHeyClickyPeekSurface.swift` | Peek header: connected apps, monthly usage, update and upgrade buttons |
| `NotchHeyClickyChatTextRow.swift`, `NotchHeyClickyChatDrawingRow.swift`, `NotchHeyClickyChatHandOffRow.swift` | Chat rows for text replies, saved drawings, and hand-offs ("Typed into …", "Copied to your clipboard") |
| `NotchChatResize.swift` | Resizable chat (`clicky.notch.chatSize.v1`) |
| `NotchTextInputSurface.swift`, `NotchTextResponseSurface.swift` | Typed composer and streamed reply with auto-dismiss countdown |
| `NotchDocumentViewer.swift` | Document tab viewer ("Open in its app") |
| `NotchDictationClipboardSurface.swift`, `NotchDictionaryLearnedSurface.swift`, `NotchMicrophoneTroubleSurface.swift`, `NotchMorningSuggestionsSurface.swift`, `NotchHandoffSurface.swift` | Transient notices: dictation fell back to the clipboard, a word was learned, mic trouble, morning suggestions, hand-off status |
| `ClickyNotchUpdateSurface.swift` | Agent job update cards in the notch ("Didn't finish", "Routine: …", file previews) |
| `NotchSystemOverlayCoordinator.swift` | Hides or yields when system UIs are up (Spotlight, Control Center, screenshot UI) |
| `NotchCornerGlowRenderServer.swift`, `NotchLoopLayers.swift`, `NotchHoverTickScheduler.swift`, `NotchStripPerformanceSupport.swift`, `NotchGelActionButtonStyle.swift` | Glow, marquee and loop animations, hover ticking, gel buttons |

Key types: `NotchPanel` (NSPanel), `NotchKeyboardFocusReleasePanel`, `NotchScreenGeometry`, `NotchVisibleSurfaces`, `NotchLiveEvent`, `NotchMeetingCountdownSurface`, `NotchUseCaseCarousel`, `NotchSignedOutPlaceholder`, `NotchVoicePill`, `NotchSkillPinnedSurface`, `NotchSpotifyVoiceTipSurface`, `NotchSidecarLearningSuggestionSurface`, `NotchIntegrationSuggestionSurface`, `NotchMutedSpeakerVoiceReplySurface`, `NotchAppUpdatedSurface`.

### 8.3 `hotkeys-input`: Global shortcuts

| File | Purpose |
|---|---|
| `ClickyHotkeyConfiguration.swift` | Four shortcut slots stored as `clicky.hotkeys.<slot>.v1`. A trigger is a hold-combo or a double-tapped modifier. Keys: `triggerKind`, `keyCode`, `modifierMaskRawValue` |
| `ClickyHotkeyRecorder.swift` | Recorder UI; modifier-only rule ("Shortcuts use only … and fn, not letters") |
| `CompanionManager+EscapeInterrupt.swift` | CGEvent tap on its own thread; Escape interrupts speech, drawing or agent follow-ups |

Enums: `ClickyShortcutSlot` = `voiceHold`, `textTrigger`, `dictationHold`, `handsFreeDictation`; `ClickyShortcutTriggerKind` = `holdCombo`, `doubleTapModifier`; `RecordingStartSource` = `hotkey`, `detachedClick`, `inlineAgentFollowUp`. Default combos seen in strings: ctrl+option(+space), shift+control(+space), shift+fn. Other types: `GlobalPushToTalkShortcutMonitor`, `ModifierDoubleTapDetector`, `ClickyModifierFlagsChangeMonitor`, `EscapeInterruptTapContext`.

### 8.4 `stt-mic`: Microphone and speech input

| File | Purpose |
|---|---|
| `RealtimeMicrophoneCapture.swift` | Mic capture for voice turns; device selection, Bluetooth "held mic" handling, failover to the built-in mic |
| `ClickyAudioBufferConversion.swift` | PCM format conversion and resampling (`PCM16MonoResampler`, `ClickyFormatKeyedAudioConverter`); `ClickyAudioTopologyMonitor` (output, transport, headphones, lid closed) |
| `OneBrainGeminiTranscriber.swift` | Streaming STT for One Brain presses over a Gemini Live socket, using a server-minted token (`/brain/ears/token`). On refusal it falls back for 10 minutes |
| `AppleSpeechTranscriptionProvider.swift` | On-device `SFSpeechRecognizer` fallback provider |
| `AVAudioPlayerNode+CatchingPlay.swift` | Wraps player start to catch Obj-C exceptions |

Key types: `BuddyTranscriptionProvider` / `BuddyStreamingTranscriptionSession` (protocols), `BuddyTranscriptionProviderFactory`, `BuddyMicrophoneCaptureInput`, `DuplexMicrophoneCaptureProcessor`, `ClickyMicrophonePreferences` (`__clicky_microphone_system_default__`, `__clicky_microphone_automatic__`), `ClickyMicrophoneTestController`, `MicrophoneTroubleNotice`, `CaptureSessionSafeTeardown`.

Deepgram note: no `deepgram` string exists anywhere in the 1.1.2 binary (OBSERVED, case-insensitive grep of both slices). The `/deepgram-token` route belongs to an older build. In this version STT is Gemini Live (ears) plus server batch `/brain/ears/transcribe`, `/v2/dictation/transcribe`, and the Apple Speech fallback.

### 8.5 `voice-brain`: One Brain voice turns

| File | Purpose |
|---|---|
| `OneBrainVoice.swift` | The voice brain session. Holds `sessionID`, the thread of turns, screenshots per session, canvas size, "code of drawing on screen", page reads, compaction state, prewarm, idle session end, mic failover. Posts to `/brain/turn`, `/brain/compact`, `/brain/prewarm`, `/brain/session-end` |
| `OneBrainToolCalls.swift` | Executes tool calls the brain returns. Seen names: `find_jobs`, `show_result`, `file_read`, `offer_screen_takeover`, `start_screen_takeover`, `end_screen_takeover`, routines and library tools. Logs `one_brain_turn_timing` (release→transcript→request→first token→first line, in ms) |
| `OneBrainJobReports.swift` | "Report turn": the brain speaks short lines about finished background jobs ("[Job ready] …") |
| `OneBrainStatsHUD.swift` | Developer HUD: tokens sent, cache hit or miss, compaction threshold, time to first token |
| `ClickyTourJobCards.swift` (in `OneBrain/`) | Planned job cards offered during the drawn onboarding tour |
| `CompanionManager+RealtimeVoice.swift` | Glues push-to-talk, the brain and the voice mouth; follow-up routing to agents |

Key types: `OneBrainClient`, `OneBrainModelChoice` (`sol`, `solMedium`, `solFast`, `solUltrafast`, `solUltrafastMedium`, `solUltrafastHigh`, `terraFastMedium`, `haiku`, `sonnet`, `opus`, `deepSeekMedium`, `deepSeekHigh`), `OneBrainCompactionPolicy`, `OneBrainPrewarmPolicy`, `OneBrainToolCallPolicy`, `OneBrainToolRunner`, `OneBrainSpeechSocket` (protocol), `OneBrainSpeechTranscript`, `OneBrainTranscriptWaiter`, `OneBrainTurnTiming`, `OneBrainSayLines`, `OneBrainJobIDs`, `OneBrainClickyAnnouncement`, `ClickyVoiceRoutingReport`.

Client capability flags sent with brain turns (OBSERVED near `/brain/ears/token`): `async_tools`, `saves_drawings`, `library_items`, `routines_tool`, `find_jobs_tool`, `figures_float`, `app_reads`, `brain_model`.

Model ids (OBSERVED): `gpt-6.1-sol`, `gpt-6.1-sol-fast`, `-ultrafast`, `-ultrafast-medium`, `-ultrafast-high`, `gpt-6.1-sol-medium`, `gpt-6.1-terra-fast-medium`, `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`, `deepseek-v4.1-flash-medium`, `deepseek-v4.1-flash-high`.

### 8.6 `realtime-voice`: Voice output and voice picker

| File | Purpose |
|---|---|
| `RealtimeVoiceClient.swift` | Gets an ephemeral session from `/agent/realtime/session`, then opens `wss://api.openai.com/v1/realtime?model=…` (`gpt-realtime-2.1` or `-mini`). Also drives Gemini TTS lines. Handles the duplex upgrade budget and mic changes |
| `GeminiMouthProtocol.swift` | Gemini Live "mouth": `BidiGenerateContentConstrained` socket with model `gemini-3.8-flash-lite-tts`, voices `gemini:<Name>`; `GeminiMouthTurnLedger` |
| `RealtimeDuplexAudioEngine.swift` | Full-duplex `AVAudioEngine` with voice processing (AEC) for always-on mode |
| `RealtimePlayer.swift` | Streams PCM deltas to output (`RealtimeAudioPlaybackSink`) |
| `RealtimeProviderAvailabilityDiagnosis.swift` | Detects region blocks and unreachable providers (probes `api.openai.com/v1/models`) and explains them to the user |
| `VoicePreviewStore.swift` | Prefetches and caches voice previews (`/agent/realtime/voice-preview` → `Clicky/VoicePreviews`) |
| `VoiceLanguageSuggestions.swift` | Language list and hints (`/onboarding/language-hints`) |
| `SystemAudioOutputVolume.swift` | Temporarily unmutes or raises system volume to speak a reply, then restores it |
| `CoreAnimationVoiceWaveform.swift` | Speaking waveform animation |

Key types: `RealtimeVoiceController` (conversation history, active text and voice turns, follow-up targets, document context), `RealtimeVoiceProvider` = `openAI`, `gemini`; `RealtimeVoiceTurnDetectionMode` = `manualPushToTalk`, `serverVoiceActivityDetection`; `RealtimeVoiceOption` {`id`, `displayName`, `subtitle`, `iconSystemName`, `iconColor`, `sampleSentence`, `previewResourceName`, `provider`}; `RealtimeVoiceCatalog`, `RealtimeSpeechSpeedCatalog`, `RealtimeToolDispatcher`, `RealtimeToolCall`, `RealtimeScopedResponseGate`, `RealtimeWalkthroughSync`, `RealtimeSessionPromptContext`, voice pickers (`VoiceOrbitPicker`, `VoiceWavePicker`, `VoiceDiscoveryMap`, `VoiceStepSliderPicker`, `VoiceChecklistPicker`), `MutedSpeaker*`.

### 8.7 `text-chat-widgets`: Typed chat and answer cards

| File | Purpose |
|---|---|
| `ClaudeAPI.swift` | Streaming client for the Worker `/v2/chat` (SSE). The upstream is Anthropic or OpenRouter, chosen server-side. Events include `content_block_start` / `delta`, `clicky_tool_start`, `clicky_widget`, `clicky_error`. Request keys: `user_prompt`, `base64_image_data`, `image_media_type`, `image_label`, `prompt_profile`, `response_model_selection`, `open_router_custom_model`, `open_router_verbosity`, `is_provider_fallback_retry` |
| `OpenAIAPI.swift` | Direct Chat Completions client (`max_completion_tokens`, images). INFERRED: legacy or dev path |
| `ResponseCardOverlay.swift` | Floating response card near the cursor with an image gallery strip |
| `ClickyGrowingTextView.swift` | Auto-growing text input |

Key types: `ClaudePromptProfile`, `ClaudeSSEFormat`, `ResponseCardViewModel`, `ResponseCardStatus`, `NotchHeyClickyComposer`, `NotchHeyClickyChatView`, `NotchHeyClickyChatFollowUpPills`, `NotchTextResponsePresentationPolicy`, `NotchClipboardImageAttachments`, `ClickyRequestCompression`.

### 8.8 `lookup-tools`: Server lookup tools and widgets

| File | Purpose |
|---|---|
| `PlaceSearchAPI.swift` | `place-search` / `place-photo` Worker tools. Result keys: `address`, `latitude`, `longitude`, `primary_type`, `user_rating_count`, `photo_names`, `website_url`, `phone_number`, `google_maps_url` |
| `PlaceWidget.swift`, `PlaceDetailOverlay.swift` | Map and place card UI; detail panel with photo carousel |
| `ImageSearchAPI.swift` | `image-search`. Result keys: `images`, `thumbnail_url`, `full_url`, `source_url`, `page_url` |
| `StockQuoteAPI.swift`, `StockWidget.swift` | `stock-quote`. Keys: `ticker`, `company_name`, `current_price`, `change_absolute`, `change_percent`, `day_high`, `day_low`, `previous_close`, `sparkline_closes`, `start_price` |

Other server tools seen as routes: `/web-search`, `/agent/realtime/spotify/search`, `/agent/realtime/google-calendar/events` (+`/create`), `/me/calendar/upcoming`.

### 8.9 `screen-drawing`: On-screen drawing

| File | Purpose |
|---|---|
| `ScreenDrawingCanvas.swift` | Host for a drawing program (JS) on a transparent overlay; stream state |
| `ScreenDrawingNativeEngine.swift` | Runs the brain-emitted drawing program in JavaScriptCore with `clicky-draw-*.js`. Callbacks: `onCaption`, `onButtonReady`, `onRenderOps`, `onSoundsScheduled`; schedules mark sounds |
| `ScreenDrawingNativePainter.swift` | Paints render ops (pen strokes, fills, text, images) natively |
| `ScreenDrawingTextShaper.swift` | Handwriting text shaping and layout (Patrick Hand / Barlow) |
| `ScreenDrawingClock.swift` | Frame clock with timing probes; `CANVAS_3D_*` debug env flags |
| `ScreenDrawingCSSColor.swift` | CSS named-colour table → RGBA |
| `ScreenDrawingPenCursor.swift`, `ScreenDrawingPenFollower.swift` | Pen cursor that follows strokes as they draw |
| `ScreenDrawingLiveCaption.swift`, `ScreenDrawingNativeCaption.swift` | Spoken-caption strip synced to narration |
| `ScreenDrawingActionButtons.swift` | Buttons the drawing can offer (for example "Run it now") |
| `ScreenDrawingPinnedCards.swift`, `ScreenDrawingCardDragHandles.swift` | Pin drawn cards to the screen; drag handles and window buttons |
| `ScreenDrawingPhotoLoader.swift` | Loads photos referenced by the drawing (`ScreenDrawingPublicImageFetch`) |
| `ScreenDrawingStaleWatch.swift` | Watches for window moves or app switches that make a drawing stale; refuses clicks while the screenshot UI is up |
| `ScreenDrawingSoundPlayer.swift` | Pen and paper sound beds and accents |
| `ScreenDrawing3DStage.swift`, `ScreenDrawing3DHandle.swift` | Metal stage for 3D objects in drawings; drag/rotate handle; shader warm-up |
| `ClickyThreeKernel.swift` | JSC host for the three.js slice that builds 3D geometry (`clickyThreeBuild`) |
| `DaVinci3DGeometry.swift`, `DaVinci3DRenderer.swift`, `DaVinci3DScene.swift`, `DaVinci3DStudioRenderer.swift` | Native 3D scene graph, ear-clipping and path flattening, Metal renderers |
| `ClickyCanvasScene.swift`, `ClickyCanvasRenderer.swift`, `ClickyCanvasBaker.swift`, `ClickyCanvasView.swift` | Generic animated vector canvas (nodes, pen masks, glyph ink, timing curves) with a Metal renderer and texture baking |
| `CompanionManager+Annotation.swift` | Starts and clears drawings and annotations from brain turns |

Key types: `ScreenDrawingProgram` {`code`, `modelIdentifier`, `firstTokenMilliseconds`, `totalMilliseconds`, `costUSD`}, `ScreenDrawingPreparedProgram`, `ScreenDrawingProgramMarkers`, `ScreenDrawingClient`, `ScreenDrawingStreamState`, `ScreenDrawingNativeMarkTiming`, `ScreenDrawingTargetSnapper`, `ScreenDrawingTurbulence`, `ScreenDrawingUnitBezier`, `ScreenDrawingDisplayChoice` (`display`, `undecided`), `ScreenDrawingNarrationOutcome`, `ScreenDrawingContinuationDecision`, `ScreenDrawingSuggestionCards`.

### 8.10 `drawings-library`: Saved drawings ("lessons")

| File | Purpose |
|---|---|
| `ClickyLesson.swift` | Lesson model and on-disk folder: `program.js`, `screen.jpg`, `poster.jpg`, `narration.caf`, `lesson.json`, `photos/` under a `Lessons` directory |
| `ClickyLessonRecorder.swift` | Captures a drawing plus narration as a lesson draft |
| `ClickyLessonPlayer.swift`, `ClickyLessonInlinePlayer.swift`, `ClickyLessonPlayerControls.swift` | Replay on a white board or inline; play, pause, scrub |
| `ClickyLessonPrinter.swift` | Renders a polaroid "print" with a Metal warp shader |
| `ClickyRecentDrawings.swift` | Session list of recent drawings; "save drawing" tool results |
| `ClickyDrawingVideoRecorder.swift` | Records a drawing playback with its soundtrack to a video in Downloads |
| `ClickyDrawingWindowViewer.swift` | Drawing viewer window (play full screen, download) |

### 8.11 `agent-runtime`: Background agents

| File | Purpose |
|---|---|
| `CodexAgentSession.swift` | Session facade over the agent runtime. Callbacks for progress, commentary, thinking, plan updates, file patches, tool steps, program batches, computer use, integrations, finish, fail and interrupt; MCP OAuth status; orphan subprocess sweep |
| `CodexProtocolClient.swift` | JSON-RPC (line-framed) client for `codex app-server`. Methods: `turn/start`, `turn/steer`, `turn/interrupt`, `thread/turns/list`; notifications `turn/started`, `turn/completed`, `turn/plan/updated`, `…/delta` |
| `CodexRuntimeBridge.swift` | Finds the runtime (bundled `CodexRuntime`, a local `codex` CLI, or node). Starts `app-server` with an isolated `CODEX_HOME`; stderr logging |
| `AgentHarnessRunnerRuntime.swift` (in `AgentHarness/`) | Alternative runtime. Spawns `Contents/Helpers/clicky-harness`, waits for a ready line, then speaks HTTP on `127.0.0.1` (`/prewarm`, `/steer`, `/cancel`, long-poll `&wait=20000`). Events: `AgentHarnessEvent` |
| `CompanionManager+CodexAgent.swift`, `CompanionManager+CodexAgentTurn.swift` | Launches agent turns (`/codex-thread-launch`, `/agent/session-token`, `/agent/turn-lease/`), presents progress, voice cues and final replies |
| `CompanionManager+AgentCommentaryStream.swift` | Relays agent commentary to the voice brain ("… is still working and last said …") |
| `ClickyAgentTurnCostLedger.swift` | Per-turn token and cost ledger; `/runtime/model-policy`; tracing headers `X-Clicky-Distinct-Id`, `-Session-Id`, `-Trace-Id`, `-Mode`, `-Agent-Thread-Id` |
| `ClickyLoopbackMCPServer.swift` | In-app MCP server on `127.0.0.1` (protocol `2025-03-26`; `initialize`, `tools/list`, `tools/call`) exposing app tools to agents; `/runtime/tool-policy` gating |
| `ClickyRoster.swift` | "Clickys": persistent named agents (`clicky.roster.v1`). Each has an `AGENTS.md` under `/agents/`, portrait, suggested asks, intro messages, archive state |
| `ClickyJobs.swift` | Jobs index and agent prompt context: waiting-on-user states, `job_id`, routine linkage |
| `ClickyJobUserSteps.swift` | "One step on your Mac" user steps with `done_when_url_contains` checks |
| `ClickyLearnedHowTos.swift` | Per-user learned how-tos carried to later jobs (`clicky.jobs.learnedHowTos.v1`) |
| `ClickyWorkFolderFiles.swift` | Job folder files: `WORK.md` runs log, `state.md`, `report.md`, `.clicky/owner`, `.clicky/previous-note.md` |
| `ClickyAppStore.swift` | Per-Clicky works store (`ClickyApps/works.json`); parses final reply sections (`DONE_TITLE`, `SUMMARY`, `ANSWER`, `ARTIFACTS`, `NEXT_ACTIONS`, `ROUTINE`, `COMPUTER_USE_REQUEST`, `LEARNED`) |
| `ClickyRestartInterruptions.swift` | Restores turns interrupted by a relaunch (`clicky.clickys.runningTurns.v1`) |
| `ClickyPlanMotion.swift` | Pending agent requests restored across launches (`clicky.agent.pendingRequests.v1`) plus plan-check animations |
| `CompanionManager+ClickyOrganizer.swift` | One-time `/clickys/organize-history`: files past agent threads into Clickys |
| `CompanionManager+EarlyStopRefund.swift` | `/refund-early-stop` when the user stops an agent early. Also folder-access recovery notices |
| `AgentPermissionsInspector.swift` | Probes Automation permission for apps agents may script |
| `CodexLaunchFlight.swift`, `CodexLaunchFlightLayerPlayer.swift` | Launch animation from the cursor to the edge deck |
| `CodexHomeSpaceCaches.swift` | Thread-history and turn-journal caches (`HomeSpaceCache/thread-history.json`, `turn-journal/`) |
| `ClickyAgentIconView.swift` | Topic-based agent icon selection (keyword → glyph) |

Key types:

- `AgentHarness` = `codex`, `pi`, `h1`; `AgentHarnessPlace` = `mac`, `cloud`; `AgentHarnessModel` = `standard`, `luna`, `haiku`
- `AgentHarnessEvent` = `turnStats`, `commentary`, `thinking`, `plan`, `toolStarted`, `toolFinished`, `webSearch`, `programBatch`, `answerDelta`, `finished`, `notePreview`, `noteSaved`, `connectedAppsUnreachable`
- `AgentHarnessTurn` {`harnessThreadID`, `appThreadID`, `isFirstTurn`, `text`, `imagePaths`, `workspace`, `model`, `context`, `leaseMetadata`, `turnID`}
- `AgentHarnessMCPServer` {`name`, `url`, `bearerToken`, `headers`, `sendsTurnIdentity`, `localCommand`}
- `CodexAgentTurnLease` {`leaseID`, `turnID`, `expiresAt`, `creditsUsed`, `includedCredits`, `costUSD`, `costLimitUSD`, `requiresExtraEffort`, `status`}
- `CodexTaskLifecycleState` = `queued`, `running`, `completed`, `failed`, `interrupted`
- `ClickyJob` {`id`, `title`, `prompt`, `threadID`, `folderPath`, `createdAt`, `finishedAt`, `outcome`, `summary`, `replyText`, `artifactEntries`, …, `runs`, `waitingStep`}; `ClickyJobKind` = `pdf`, `document`, `sheet`, `slides`, `image`, `video`, `page`, `code`, `message`, `research`
- `ClickyPendingAgentRequest` {`threadID`, `kind`, `requestText`, `leaseID`, `leaseTurnID`, `clickySlug`, `jobID`, `title`, `prompt`, `finalSummary`, `askedAt`}
- `ClickyDeveloperChatModel` = `gpt61Sol`, `gpt6Sol`, `gpt6Luna`, `luna`, `terra`, `sol`, `astra`; `ClickyDeveloperReasoningEffort` = `none` … `max`
- Also: `CodexHomeManager` (writes `CodexHome/config.toml`, syncs skills and model instructions), `CodexProcessManager`, `CodexRPCLineFramer`, `CodexThreadHistoryCache`, `CodexAgentTurnPromptBuilder`, `ClickyAgentCommentaryRelay`, `ClickyAgentStandingContextLedger`, `ClickyHarnessRecord`

### 8.12 `agent-output-ui`: Ink notes, edge deck and cards

| File | Purpose |
|---|---|
| `ClickyInkDocument.swift` | Parser for the agent-written `note.md` dialect: Markdown plus object blocks (receipt, sticky, chart, dashboard, tracker, schedule, letter, polaroid…) and inline tags (`{now}`, `{needs}`, `{done}`, `{pick}`…) |
| `ClickyInkObjects.swift`, `ClickyInkDashboardObjects.swift`, `ClickyInkInteractiveObjects.swift`, `ClickyInkFrontPageForm.swift` | Renderers for note objects: tables, charts, sparklines, streaks, tallies, checklists, quizzes, forms, front-page layouts |
| `ClickyInkText.swift`, `ClickyInkSketch.swift`, `ClickyInkEdgeNotes.swift` | Hand-lettered text, sketch primitives, edge-card note faces and paper colours |
| `ClickyInkLive.swift` | Live note while the agent writes; lints the note (title, pages ≤ 4, columns ≤ 4) and feeds problems back to the agent |
| `ClickyInkNotePages.swift`, `ClickyInkNoteStore.swift` | Paginated note store with versions |
| `ClickyInkActionsStore.swift` | User actions on notes (ticks, picks, criteria edits, letter re-tone) → `note-actions.json`; sends instructions back to the agent |
| `ClickyInkConnections.swift` | Inline `::ask[…]{say=…}` and `::link[…]{url=…}` affordances; connect-app objects; status-word mapping |
| `CompanionManager+InkConnect.swift` | Connect-an-app from inside a note; job search and report tools |
| `ClickyLiveNotes.swift`, `ClickyLiveSteps.swift` | Live step lines ("searched …", "used your Mac") with glyph icons; live-note feature flags |
| `ClickyEdgeDeck.swift`, `ClickyEdgeShelf.swift`, `ClickyEdgeStackInkCard.swift` | Right-edge shelf or deck of job windows (pins `clicky.clickyApps.pinnedSlugs.v1`), and the ink-card face |
| `ClickyArcCard.swift` | Top "arc" progress card for a running job (plan steps, stop button, answer input) |
| `ClickyResultCardFace.swift`, `ClickyCardParts.swift` | Finished-job result card face and status lines ("Needs you", "… is ready") |
| `ClickyStickyNotes.swift` | Sticky file cards; morning, afternoon or evening greeting summaries ("N jobs working") |
| `ClickyPaperGlyphs.swift`, `ClickyPaperPieces.swift` | Paper-style glyphs (SVG path strings) and pieces |
| `ClickyMorphingText.swift`, `ClickyTextMotionExamples.swift` | Text morph animation and its preview gallery |

Key types: `ClickyLiveNoteState` = `writing`, `needsYou`, `ready`, `done`; `ClickyInkNotePage` {`number`, `userMessage`, `isRoutineRun`}; `ClickyInkParser`, `ClickyInkPatchStream` (streamed note patches), `ClickyInkPen*` (pen animation scheduling), `ClickyEdgeShelfController`, `ClickyEdgeDeckLayout`, `ClickyTopArc*`.

### 8.13 `take-over-drive`: Computer use

| File | Purpose |
|---|---|
| `ClickyTakeOver.swift` | Consent flow and driver loop. The brain tools `offer_screen_takeover`, `start_screen_takeover` and `end_screen_takeover` require the user's yes; billing per drive (`drive_job_lease_id`); ends on `user_took_over`, `could_not_see`, `safety_check` or out of agent messages |
| `ClickyTakeOverOverlay.swift` | Overlay while driving (status, hints when the user moves the mouse) |
| `ClickyDriveNotchState.swift` | Notch state ("HeyClicky is driving", Esc stops) |
| `ClickyUserInputBlocker.swift` | Event tap that holds the user's input during a drive; AX menu-item presses |
| `ClickyBackgroundCursorControl.swift` | Private WindowServer property to set the cursor while in the background |
| `CompanionManager+ClickyAppDrives.swift` | Agent-requested drives ("I need a yes to use your Mac") |
| `CompanionManager+ComputerUseConsent.swift` | Consent bookkeeping for agent computer use |

Key types: `ClickyTakeOverController` (phase, consent card, step capture, user-move detection, drive billing and lease fields, action log), `ClickyAppDriver`, `ClickyDriveAX`, `ClickyScreenActuator`, `ClickyMacStepWaiters`, `CodexComputerUseActivity`.

### 8.14 `browser-bridge`: Chrome extension bridge

| File | Purpose |
|---|---|
| `ClickyBrowserBridge.swift` | Loopback server for the extension. Installs the NativeMessagingHosts `manifest.json` for Chrome, Edge, Brave, Arc, Vivaldi, Chromium (incl. Beta, Dev, Canary); profile discovery from `Local State`; per-turn grants; `browser_poll`/`browser_reply`; agent MCP server `clicky_browser` |
| `ClickyChromeSetupFlow.swift` | Guided extension install (Chrome Web Store), old-copy swap |

Also `ClickyChromeAutoInstall`, `ActiveBrowserSiteReader`, `HomeSpaceBrowserConnectionSettings.swift` (settings UI). Persisted: `BrowserBridge/connection.json` {`port`, `token`}; defaults `clicky.browserConnection.*.v1`.

### 8.15 `integrations-connectors`: Connected apps and custom MCP

| File | Purpose |
|---|---|
| `ClickyCustomConnectorOAuthClient.swift` | MCP OAuth: protected-resource metadata discovery, dynamic client registration, PKCE, localhost callback server, token refresh |
| `ClickyCustomConnectorCapabilityDeriver.swift` | Derives a capability summary (verbs such as find, create, update) from a connector's tool list |
| `HomeSpaceCustomConnectorsSettings.swift`, `HomeSpaceCustomConnectorDraftStore.swift` | Settings UI and draft persistence for custom connectors (transport, URL, token, OAuth client) |
| `HomeSpaceIntegrationConnectionFeedback.swift` | Connection progress and result feedback |
| `IntegrationSuggestionMonitor.swift` | Watches the frontmost app or site (AX title) and suggests connecting a matching integration, with rate limits (`clicky.integrationSuggestions.*`) |
| `IntegrationLogoArtwork.swift` | Logo mapping for apps and sites |

Key types: `AgentIntegration`, `AgentIntegrationAccount`, `AgentIntegrationToolkit`, `AgentIntegrationStatus`, `ComposioAgentMCPConfiguration`, `ComposioAgentSessionCache`, `ClickyCustomConnector`, `ClickyCustomConnectorSecretStore`, `ClickyCustomConnectorToolCatalog`, `SidecarLearningSuggestionCandidate`, `SpotifyVoiceTipLogoPair`. Routes: `/agent/integrations`, `/agent/integrations/<id>` (connect, disconnect), `/agent/composio/session`.

### 8.16 `skills-powerups`: Skills library

| File | Purpose |
|---|---|
| `ClickyPowerUp.swift` | Skill model and activation manager (`ClickyPowerUpManager`); writes active skills as agent skill files |
| `ClickySkillLibraryBackend.swift` | `/skills/library`, `/skills/create`, `/skills/creations`, `/skills/activations/sync`, share or unshare with team, publish or unpublish; cache `SkillLibraryCache.json` |
| `PowerUpSkillFileStore.swift` | Writes skill `.md` files (front-matter `name`, `description`) |
| `PowerUpPanelWindow.swift`, `PowerUpAvatarView.swift` | Library panel and author avatars |

Key types: `ClickyPowerUp` {`id`, `displayName`, `creator`, `authorSlug`, `blurb`, `routingDescription`, `tags`, `category`, …, `content`, `origin`, `fileURL`, usage counts}, `RemotePowerUpSkill`, `CreateSkillPanelViewModel`, `HermesSkill` {`id`, `displayName`, `subtitle`, `iconSystemName`, `iconColor`, `iconAssetName`, `bundledSkillIDs`}, `HermesSkillCatalog`.

### 8.17 `routines-proactive`: Routines, suggestions, morning brief, meetings

| File | Purpose |
|---|---|
| `CompanionManager+ClickyRoutines.swift` | Local routine scheduler: interval, daily or weekly slots, catch-up after wake or network return, keep-awake, retries |
| `CompanionManager+AgentCrons.swift` | Server crons (`/agent/cron/list`, `/agent/cron/<id>`, `run-now`); Obsidian vault picker |
| `CompanionManager+AgentNotifications.swift` | Polls `/agent/notifications`; mark read, read-all |
| `CompanionManager+Proactive.swift` | Proactive agent suggestion pipeline; approved-task queue; reads local `activity-timeline.sqlite` and `app-usage-timeline.sqlite` (INFERRED: from a sidecar app) |
| `ProactiveAgentsClient.swift` | `/proactive-agents` (+`/jobs/`, `/invitation-claim`, `/resolution`, `/suggestions/statuses`); cadence, morning headline, curated evidence |
| `GoodMorningBrief.swift` | Morning research job, then a drawn "good morning" on the first wake |
| `HomeSpaceRoutinesSettings.swift` | Routine management UI |
| `ClickySystemWindowPickerYield.swift` | Meeting-link detection (Meet, Zoom, Teams), upcoming calendar (`/me/calendar/upcoming`); also yields HeyClicky windows to the system window picker |

Key types: `ClickyRoutine` {`id`, `clickySlug`, `jobID`, `title`, `taskPrompt`, `intervalSeconds`, `createdAt`, `isPaused`, `nextRunAt`, `runCount`, `lastRun*`, `pendingRetryAt`, `consecutiveFailedRunCount`, `waitingForNetworkSince`, `scheduledMinuteOfDay`, `scheduledWeekday(s)`}, `ClickyRoutineRunTrigger`, `ClickyRoutineKeepAwake`, `ScheduledAgentCron*`, `ProactiveSuggestionCadence`, `ProactiveSuggestedAgentCard`, `QueuedProactiveTask`, `MorningSuggestionsInvitationPolicy`, `UpcomingCalendarEvent`, `AgentNotification`/`AgentNotificationSeverity`, `ClickyCallPresenceDetector`, `ClickyFocusModeDetector`.

### 8.18 `home-window`: Home space and HeyClicky window

| File | Purpose |
|---|---|
| `HeyClickyWindow.swift`, `HeyClickyWindowConversation.swift`, `HeyClickyWindowOpeningFlight.swift` | Main chat window (sidebar of conversations, composer, transcript, document column) and its opening animation |
| `HeyClickyConversationHistory.swift` | Local conversation store (`HeyClickyHistory/<user>.json`), synced with `/me/companion-history` (`before_id`, `has_more`) |
| `HeyClickyChatHandOffs.swift` | Records of replies delivered to other apps (`HeyClickyHistory/<user>-handoffs.json`) |
| `HomeSpaceViewModel.swift` | Home view model (suggestions, transcripts, previews) |
| `HomeSpaceSuggestionsPage.swift`, `HomeSpaceCardViews.swift`, `HomeSpaceArtifactCards.swift` | Suggestions and cards page |
| `HomeSpaceConversationTranscript.swift`, `HomeSpaceCoworkTranscript.swift` | Voice/text conversation transcript and agent "cowork" transcript (Markdown, tables, footers) |
| `HomeSpaceFocusPane.swift`, `HomeSpaceOutputPreviewColumn.swift` | Focus pane and artifact preview column |
| `HomeSpaceSettingsPage.swift`, `HomeSpaceSettingsContent.swift` | Settings: account, agents, cursor, developer, dictation, general, integrations, microphone, shortcuts, voice, routines, connectors |
| `HomeSpaceAmbientLayerViews.swift`, `HomeSpaceCloudFaceView.swift` | Ambient animation layers and cloud face |
| `ClickyUsageCardPopover.swift` | Usage popover from the notch |

Key types: `HomeSpacePage` = `suggestions`, `settings`; `HeyClickyConversationMessage` {`id`, `serverID`, `role`, `content`, `source`, `createdAt`, `attachmentPaths`, `bubbleSegments`, `replacedLocalID`, `sentToAgentName`, `sentToAgentTargetKey`}; `HeyClickyWindowModel`, `HeyClickyWindowController`, `HomeSpaceTheme`, `HomeSpaceLayoutMetrics`.

### 8.19 `file-previews`: Document viewers

| File | Purpose |
|---|---|
| `MarkdownViewerContentView.swift`, `MarkdownViewerTableView.swift` | Native Markdown renderer (selectable text, tables, copy blocks, animated images, file watcher) |
| `SpreadsheetXLSXReader.swift`, `SpreadsheetNumberFormat.swift` | XLSX reader (zip, shared strings, styles, themes) and number formats; CSV/TSV reader |
| `SpreadsheetGridLayout.swift`, `SpreadsheetGridRenderer.swift`, `SpreadsheetGridView.swift`, `SpreadsheetPreview.swift` | Frozen-pane grid view, formula bar, selection summary (Count, Average, Sum) |
| `DocumentAnimatedImageView.swift` | GIF and animated image view in documents |

Also `HomeSpacePDFPreview`, `HomeSpaceQuickLookPreview`, `HomeSpaceWebPageSnapshotter`, `HomeSpaceNativeDocumentViewCache`, `CappedDownload`.

### 8.20 `handoff`: Hand-off to another app

| File | Purpose |
|---|---|
| `HandoffManager.swift` | Attach to a target app (AX element and pid), queue region screenshots, deliver payloads |
| `HandoffRegionSelectOverlay.swift`, `HandoffRegionSelectDimLayers.swift` | Drag-to-select screen regions with dimming |
| `HandoffIndicatorWindow.swift` | Chip showing the attached app |
| `HandoffVoiceStopWindow.swift` | "Stop" pill while speaking a hand-off |
| `TextInjectionDelivery.swift` | Types or pastes text into the focused field (falls back to the clipboard without Accessibility) |

Key types: `HandoffDeliveryStrategy` = `pidTargetedPasteAndReturn`, `frontmostTypeTextAndReturn`; `HandoffDeliveryTarget` {`element`, `processIdentifier`, `targetAppDisplayName`, `targetAppBundleIdentifier`, `targetAttachmentPointInAppKitGlobalCoords`}; `HandoffPayload`, `HandoffPayloadImage`, `HandoffPostDragAction`.

### 8.21 `dictation`: System-wide dictation

| File | Purpose |
|---|---|
| `CompanionManager+Dictation.swift` | Dictation session lifecycle; salvages partial text to the clipboard on failure; 402 quota paywall |
| `DictationTranscriptionClient.swift` | Worker `/v2/dictation/transcribe` (batch) and `/v2/dictation/cleanup`. Header `X-Clicky-Dictation-Receipt`, bearer fallback; context keys `app_name`, `before_text`, `selected_text`, `after_text`, `single_line`, `site_host`, `known_terms` |
| `DictationGeminiTranscriber.swift` | Streaming dictation over Gemini Live (`/v2/dictation/gemini-token`) |
| `DictationFocusContext.swift` | Captures the AX focused element, value and selection (enables `AXManualAccessibility` for Electron and Chrome) |
| `DictationInsertion.swift` | Inserts text into the captured field; refuses if focus moved |
| `DictationCorrectionLearner.swift` | Learns corrections the user makes after insertion; seeds the vocabulary |
| `DictationAnnouncementWindow.swift` | "Introducing dictation" panel with language and shortcut setup |

Key types: `BuddyDictationManager`, `ClickyDictationController`, `DictationLanguageCatalog`, `DictationCustomVocabulary`, `DictationLearnedCorrection`, `DictationTranscriptArchive` (`DictationTranscripts/<yyyy-mm-dd>.jsonl`), `DictationStreamedTranscript`, `BuddyDictationStartSource` = `microphoneButton`, `keyboardShortcut`, `TextInsertionPrimitives`.

### 8.22 `pointing-annotation`: Cursor companion and guided walkthroughs

| File | Purpose |
|---|---|
| `OverlayWindow.swift` | Full-screen transparent overlay per display; companion cursor, bubbles ("this one!", "click this!") |
| `OverlayCursorStage.swift`, `OverlayCursorPerformanceController.swift`, `OverlayCursorSystemVisibilityMonitor.swift` | Cursor actor staging, spring flight paths, hide when the system cursor is hidden |
| `CompanionActorRenderer.swift` | Sprite actor state machine (point, travel, inspect, speak bubble, guide drag, tool states, return home, fade away) |
| `ScreenAnnotationManager.swift`, `AnnotationOverlay.swift` | Shape annotations (circle, line, highlight) and AX element harvesting with role labels |
| `ElementLocationDetector.swift` | Asks a model with Anthropic's `computer_20251124` tool (`anthropic-beta: computer-use-2025-11-24`) for the coordinate of a described element, then maps it into display-local AppKit coordinates |
| `ClickyPointerEvaluationDriver.swift`, `ClickyPointerEventSource.swift` | Per-frame "render server" loop driver and pointer event source for overlay animations |
| `CoreAnimationShimmerSweep.swift` | Shimmer animation |

Key types: `GuidedClickTarget`, `GuidedFollowUpRequestContext`, `GuidedWalkthroughLog`, `AnnotationShapeKind`, `AnnotationBeat`, `OverlayCursorColorChoice`, `CompanionActorState`, `CompanionActorChoreography`, `CursorMessageBubbleView`, `DetachedCursorClickPanel` ("click again to stop recording").

### 8.23 `screen-context`: Screen and document context

| File | Purpose |
|---|---|
| `ClickyWindowCapturePolicy.swift` | Excludes HeyClicky windows from captures unless "show in screen recordings" is on; attached-file-only turn note |
| `ClickySystemWindowPickerYield.swift` | (also §8.17) Steps transparent windows aside while the macOS window picker is up |

Key types (files not ID-tagged): `CompanionScreenCapture`, `CompanionScreenCaptureUtility`, `ScreenFrameLog`, `ActiveDocumentReader`, `ActiveDocumentContext`, `ActiveDocumentReference`, `ActiveBrowserSiteReader`, `ActiveWorkSurface`, `FrontmostApplicationResolver`, `ClickyUsersFrontApp`, `ClickyMissionControlMonitor`, `ClickyCaptureUIState`, `DocumentAccessNotice`, `ClickySystemEnvironment` (timezone, locale, OS version, device model).

### 8.24 `onboarding-permissions`: Onboarding, tutorial and permissions

| File | Purpose |
|---|---|
| `OnboardingIntroLayout.swift`, `IntroHatchFlightOverlay.swift` | Pre-sign-in intro steps (what it is, language, where you heard of us, skill selection) and the "hatch" flight |
| `OnboardingInterviewPage.swift`, `InterviewThoughtBubbles.swift` | Voice interview that founds the user's first Clickys |
| `OnboardingStarterPlanClient.swift`, `CompanionManager+OnboardingStarterPlan.swift` | `/onboarding/starter-plan` → suggested agents, first asks, routines, reveal lines |
| `OnboardingTutorialWindow.swift`, `OnboardingTutorialPerformanceViews.swift`, `CompanionManager+OnboardingTutorial.swift` | Step tutorial: `OnboardingTutorialStep` = `micCheck`, `speakerCheck`, `voiceHello`, `clickyInterview`, `drawDemo`, `drawToAsk`, `clickyDrive`, `textMode`, `emailDraft`, `dictation`, `finale` |
| `CompanionManager+DrawnOnboardingTour.swift` | Drawn tour with planned job cards |
| `CompanionManager+OnboardingDrive.swift` | Onboarding computer-use demo (GarageBand bass-line sample) |
| `CompanionManager+DiscoveryChannel.swift` | "Where did you hear about us" → `/me/discovery-channel` (`DiscoveryChannel` cases `instagramAd` … `other`) |
| `PermissionFlowCoordinator.swift`, `CompanionManager+PermissionFlow.swift` | Permission state machine, relaunch helper after a grant |
| `PermissionGuideAssistant.swift` | Coach that points at the right toggle in System Settings (drag source, strip view) |

Key types: `PermissionKind`, `PermissionSnapshot`, `PermissionDriver` (protocol), `PermissionFlowViewState`, `ScreenRecordingGuideProber`, `SystemSettingsWindowLocator`, `PreSignInIntroWindowManager`, `TutorialMicLevelMonitor`, `OnboardingTutorialPhase` = `running`, `inactive`, `invitePresented`.

### 8.25 `character-persona`: Characters and portraits

| File | Purpose |
|---|---|
| `ClickyCloudPortrait.swift`, `ClickyClassicCloudPortrait.swift`, `ClickyStorybookPortrait.swift` | Cloud-shaped character portraits with expressions (Curious, Listening, Sleepy …) |
| `ClickyInteractivePortrait.swift` | Interactive portrait (look-at pointer, blink, breathe, reactions) |
| `ClickyPortraitAppearance.swift` | Appearance model: character, colourway, hair, outfit, skin tone, framing, packs |
| `ClickyKiCrewHair.swift` | Hair and outfit catalogue for the portrait pack |

Key types: `ClickyPortrait*`, `AgentCloud*` (face moods and shapes), `CloudFaceExpression`, `ClickyAvatarImageStore`, `CatModeRuntimeFlag` (`ClickyCatModeEnabled`, red-cat sprite atlases).

### 8.26 `memory-profile`: Memory

No dedicated `#fileID`. Types: `UserMemoryProfileResponse`, `ClickyAgentStandingContextLedger`, `ClickyHelperFiles` (writes `Clicky/helper/about-the-user.md`, `note-guide.md`). Routes `/me/memory`, `/me/memory/save`. Learned how-tos are in §8.11.

### 8.27 `account-auth`: Sign-in and account

| File | Purpose |
|---|---|
| `SupabaseAuthManager.swift` | Google sign-in through Supabase (`/auth/start`, `/auth/v1/user`, refresh `/auth/v1/token?grant_type=refresh_token`). Keychain items `supabaseAccessToken`, `supabaseRefreshToken`; profile fields; refresh-error diagnostics |
| `AccountDeletionClient.swift`, `AccountDeletionPanel.swift` | `/me/account/delete` with reasons and a confirmation flow |

Key types: `ClickyKeychainStore`, `ClickySignInCallbackGuard`, `ClickyAuthRecovery`, `SupabaseRefreshErrorDiagnostic`, `LoopbackCallbackServer`.

### 8.28 `billing`: Plans, paywall and usage

| File | Purpose |
|---|---|
| `BillingClient.swift` | `/me/plan`, `/billing/checkout`, `/billing/portal`, discount codes; plan snapshot cache |
| `PaywallCardContent.swift` | Paywall card (Pro/Max, monthly or annual) |
| `AgentPaywallHUDWindow.swift` | Agent-surface paywall HUD |

Enums: `PaywallSurface` = `messages`, `agents`, `dictation`; `PaywallReason` = `quotaExceeded`, `paymentProblem`; `PaywallPlanKey` = `pro`, `max`; `BillingEnforcementMode` = `off`, `on`. Also `CodexExtraUsageApprovalMode`, `EarlyStopRefundResponseBody`, `PlanSnapshot`.

### 8.29 `referral`: Referral programme

| File | Purpose |
|---|---|
| `ReferralProgramModel.swift` | `/me/referral`, `/me/referral/claim`, `/me/referral/code`; balances in USD cents |
| `HomeSpaceReferralPage.swift` | Referral page, estimator, payout request by email |

### 8.30 `updates`

No dedicated file IDs. Types `SparkleUpdateDelegate`, `IdleUpdateInstallPolicy` / `Decision` / `WaitReason` (installs only when idle: no voice, agent or drawing activity), `ManualUpdateCheckState`, `AppUpdatedNotice`, `ClickyNotchUpdates`.

### 8.31 `telemetry-diagnostics`

| File | Purpose |
|---|---|
| `ClickyAITracing.swift` | PostHog LLM-analytics events (`$ai_generation`, `$ai_trace`, `$ai_span` with model, tokens, latency) |

Types: `ClickyAnalytics`, `ClickyErrorReporter` (Sentry plus `/report-error`), `ClickyDiagnosticsReport`, `ClickyDiagnosticsLogCapture`, `ClickyFeedbackEmail`, `FallbackLogLine`. Analytics event names are snake_case (for example `agent_started`, `chat_send`, `clicky_drive_action`).

### 8.32 `audio-feedback`

| File | Purpose |
|---|---|
| `ClickyChimeWarmer.swift` | Pre-warms an output engine and plays named UI chimes from the bundle |
| `SystemAudioOutputVolume.swift` | (also §8.6) Mute and volume restore |

### 8.33 `ui-kit`: Design system

| File | Purpose |
|---|---|
| `DesignSystem.swift` | `DS` tokens and button styles (primary, secondary, tertiary, outlined, destructive, icon, text) |
| `ClickySketchKit.swift` | Hand-drawn control kit (buttons, toggles, sliders, meters, cards) |
| `ClickyPaperGlyphs.swift`, `ClickyPaperPieces.swift` | (also §8.12) Paper kit |

Types: `ClickyGel*` (gel buttons, switches, sliders), `CoreAnimationOrbit*`, `CoreAnimationPingPong*`, `RenderServer*`, `Performance*` HUD content, `FlowLayout`, `NativeTooltipView`.

---

## 9. Windows and panels inventory (OBSERVED: NSPanel or NSWindow subclasses)

`NotchPanel`, `NotchKeyboardFocusReleasePanel`, `OverlayWindow` (overlay per display), `HeyClickyWindow` (main window), `ClickyEdgeShelfPanel`, `ClickyDrawingWindowPanel`, `PinnedCardsPanel`, `ScreenDrawingPinnedCardViewer.ViewerPanel`, `HandlePanel` (×2, card drag handles), `ButtonPanel`, `ScreenAnnotationPanel`, `ResponseCardPanel`, `PlaceDetailPanel`, `PowerUpPanel`, `PaywallInputPanel`, `AccountDeletionPanel`, `DictationAnnouncementPanel`, `HandoffIndicatorPanel`, `HandoffRegionSelectPanel`, `HandoffVoiceStopPanel`, `IntroHatchFlightPanel`, `PreSignInIntroPanel`, `OnboardingTutorialPanel`, `PermissionGuidePanel`, `DetachedCursorClickPanel`.

Rebuild implication: almost every surface is a non-activating `NSPanel` hosting SwiftUI (`NotchHostingView`, `Transparent*HostingView`, `FirstClickHostingView`), kept out of screen captures by policy.

---

## 10. Server surface seen in the client

Base: `WorkerBaseURL` = `https://api.heyclicky.com` unless noted. Routes are OBSERVED string literals. Purposes are INFERRED from neighbouring strings. Request and response bodies are UNKNOWN beyond the keys listed.

| Route | Area | Purpose | Model choice in request? |
|---|---|---|---|
| `/brain/turn` | voice-brain | One Brain turn (screenshot, transcript, tools) → speech lines, drawing program, tool calls | yes (`brain_model`, INFERRED) |
| `/brain/compact`, `/brain/prewarm`, `/brain/session-end` | voice-brain | Compaction, cache prewarm, session close | no |
| `/brain/ears/token`, `/brain/ears/transcribe` | stt-mic | Ephemeral Gemini STT token; batch fallback transcription | no |
| `/agent/realtime/session` | realtime-voice | Ephemeral OpenAI Realtime session (then `wss://api.openai.com/v1/realtime?model=`) | yes (realtime model and voice, INFERRED) |
| `/agent/realtime/turn`, `/agent/realtime/warmup`, `/agent/realtime/speak`, `/agent/realtime/voice-preview` | realtime-voice | Realtime turn helper, warm-up, server TTS line, preview clip | partly |
| `/agent/realtime/spotify/search`, `/agent/realtime/google-calendar/events`, `…/events/create` | lookup-tools | Tool back-ends | no |
| `/v2/chat` | text-chat | SSE chat (upstream Anthropic or OpenRouter) | yes (`response_model_selection`, `open_router_custom_model`) |
| `/v2/dictation/transcribe`, `/v2/dictation/cleanup`, `/v2/dictation/gemini-token` | dictation | Batch STT, LLM cleanup, streaming token | no (UNKNOWN) |
| `/agent/openai/v1` | agent-runtime | OpenAI-compatible proxy that Codex uses (`model_providers.clicky`) | yes (Codex `model`) |
| `/agent/session-token`, `/codex-thread-launch`, `/codex-thread-title`, `/agent/turn-lease/…`, `/agent/record-agent-launch`, `/agent-messages`, `/runtime/model-policy`, `/runtime/tool-policy`, `/refund-early-stop`, `/continue-after-computer-use-consent` | agent-runtime | Agent auth, launch, titling, metering leases, policy | `/codex-thread-launch` carries `developer_model_selection` |
| `/agent/composio/session`, `/agent/integrations[/…]` | integrations | Composio MCP session URL and toolkit connections | no |
| `/agent/cron/list`, `/agent/cron/…`, `/run-now` | routines | Server-side crons | no |
| `/agent/notifications`, `/agent/notifications/read-all` | routines | Agent notifications | no |
| `/proactive-agents` (+ `/jobs/`, `/invitation-claim`, `/resolution`, `/suggestions/statuses`) | routines | Proactive suggestions | no |
| `/clickys/organize-history` | agent-runtime | Organize past threads into Clickys | no |
| `/onboarding/starter-plan`, `/onboarding/language-hints` | onboarding | Starter agents and plan; language hints | no |
| `/skills/library`, `/skills/create`, `/skills/creations`, `/skills/activations/sync`, `/share-to-team`, `/unshare-from-team`, `/publish`, `/unpublish` | skills | Skill library | no |
| `/me/plan`, `/billing/checkout`, `/billing/portal` | billing | Plan and checkout | no |
| `/me/referral`, `/me/referral/claim`, `/me/referral/code` | referral | Referral | no |
| `/me/memory`, `/me/memory/save` | memory | Memory profile | no |
| `/me/companion-history` | home-window | Conversation sync | no |
| `/me/calendar/upcoming` | routines | Upcoming events | no |
| `/me/discovery-channel`, `/me/devices`, `/me/account/delete` | onboarding / account | Misc. | no |
| `/app-config` | app-shell | Remote config | no |
| `/report-error` | telemetry | Error report | no |
| `place-search`, `place-photo`, `image-search`, `stock-quote`, `/web-search` | lookup-tools | Lookup tools | no |
| Supabase `/auth/start`, `/auth/v1/user`, `/auth/v1/token?grant_type=refresh_token` | account | Auth | no |
| `wss://generativelanguage.googleapis.com/…BidiGenerateContentConstrained` | stt / voice | Gemini Live with ephemeral constrained token | model fixed client-side (`gemini-3.8-flash-lite-tts` for the mouth) |
| `https://api.anthropic.com/v1/messages` (Info.plist `AnthropicMessagesURL`) | pointing | Computer-use grounding call (`x-api-key`, `anthropic-version: 2023-06-01`) | yes (UNKNOWN which model) |

Common headers (OBSERVED): `Authorization: Bearer <supabase or agent session token>`, `X-Clicky-Distinct-Id`, `X-Clicky-Session-Id`, `X-Clicky-Trace-Id`, `X-Clicky-Mode`, `X-Clicky-Agent-Thread-Id`, `X-Clicky-Usage-Context`, `X-Clicky-Dictation-Receipt`, `x-clicky-accepts-gzip`, and `X-Clicky-App-Build` / `-App-Version` / `-Device` / `-OS-Version` / `-Platform` (in the Codex provider config).

---

## 11. Model slot map

| Area | Slot | Provider seen | Capabilities the OpenClicky slot needs |
|---|---|---|---|
| voice-brain | **brain** | Worker `/brain/turn`. Choices: GPT-6.1 Sol family (default Sol medium), Claude Haiku/Sonnet/Opus 5.5, DeepSeek V4.1 Flash | Image input (screenshots), streaming output, tool/function calling (sync and async), prompt caching, long context with compaction, low time-to-first-token, structured output of a JS drawing program plus speech lines |
| text-chat-widgets | **brain** | Worker `/v2/chat` → Anthropic or OpenRouter | Image input, SSE streaming, tool calls that become widgets |
| screen-drawing | **brain** (output of a brain turn) | same | Code generation into a constrained drawing DSL, timing-aware |
| pointing-annotation | **other:grounding** | Anthropic computer-use tool `computer_20251124` | Screenshot → pixel coordinate for a described element |
| realtime-voice | **voice** | OpenAI Realtime `gpt-realtime-2.1` / `-mini` (voices alloy … verse); Gemini `gemini-3.8-flash-lite-tts` (30 voices) | Streaming TTS with barge-in, voice id, speed control, optional server VAD, ephemeral client tokens |
| stt-mic | **stt** | Gemini Live (ears); server batch; Apple Speech fallback | Streaming partials, low latency on key release, language hints, fallback chain |
| dictation | **stt** + **other:text-cleanup** | `/v2/dictation/*` (Gemini streaming, LLM cleanup) | Streaming STT plus a fast LLM rewrite using field context and vocabulary |
| agent-runtime / routines | **agent** | Codex app-server with model `gpt-6-luna` (catalog includes `gpt-6-sol`, `gpt-6.1-sol`, `gpt-6-astra`, `gpt-5.6-*`) through `/agent/openai/v1`, or the `clicky-harness` (pi-coding-agent; models `standard` / `luna` / `haiku`) | Multi-step tool loop, shell and file edits, MCP clients, plan updates, image inputs, steering and interrupt mid-turn |
| take-over-drive | **brain** (+ **agent** computer use) | One Brain take-over tools | Screenshot-in-loop action planning with consent |
| routines-proactive, onboarding, organizer, titles, skill creation | **other:suggestions / onboarding-plan / titling / skill-authoring** | Server-side, prompts UNKNOWN | Plain LLM JSON generation |
| integrations | **other:tool-gateway** | Composio MCP | Hosted MCP tool gateway with OAuth accounts |

---

## 12. Local persistence map (OBSERVED in `~/Library/Application Support/Clicky`)

| Path | Owner area | Shape |
|---|---|---|
| `CodexHome/` (`config.toml`, `auth.json`, `installation_id`, `clicky-model-instructions.md`, `skills/`, `sqlite/`, `log/`, `task-assets/<uuid>/screen-N.jpg`, `.tmp/plugins`) | agent-runtime | Isolated `CODEX_HOME`. `config.toml` keys include `model`, `model_reasoning_effort`, `model_provider`, `approval_policy`, `sandbox_mode`, `model_catalog_json`, `model_providers.clicky.{base_url,env_key,wire_api,http_headers}`, `mcp_servers.clicky_browser.{url,bearer_token_env_var,…}`, `features.*`, `projects.<path>.trust_level` |
| `AgentHarness/h1-local/`, `AgentHarness/h1-mac/` (`harness-h1-mac-<uuid>`) | agent-runtime | Harness thread stores (`turns.json`, `events.jsonl`, per strings) |
| `projects/jobs/<slug>-<hash>/{output,tmp}`, `projects/jobs/WORK.md` | agent-runtime | Job working folders |
| `OneBrain/<userId>/<sessionUUID>.jsonl`, `OneBrain/<userId>/threads` | voice-brain | Brain session journal |
| `HeyClickyHistory/<userId>.json`, `<userId>-handoffs.json` | home-window, handoff | Conversation and hand-off history |
| `HomeSpaceCache/thread-history.json`, `turn-journal/<harness-thread>` | home-window | Agent thread caches |
| `DictationTranscripts/<yyyy-mm-dd>.jsonl` | dictation | Transcript archive |
| `BrowserBridge/connection.json` (`port`, `token`) | browser-bridge | Loopback credentials for the native host (values not read) |
| `SkillLibraryCache.json` | skills | Remote library cache |
| `helper/about-the-user.md` | memory-profile | User profile for agents |
| `VoicePreviews/`, `Lessons/` (per strings) | realtime-voice, drawings | Caches and saved lessons |

UserDefaults convention (OBSERVED): `clicky.<area>.<name>.v<N>`, for example `clicky.roster.v1`, `clicky.hotkeys.voiceHold.v1`, `clicky.jobs.learnedHowTos.v1`, `clicky.billing.lastKnownPlanSnapshot.v1.`, `clicky.notch.chatSize.v1`. Keychain item names: `supabaseAccessToken`, `supabaseRefreshToken`.

---

## 13. Rebuild plan (OpenClicky module layout)

Principles:

- Split the `CompanionManager` god object into feature services behind protocols.
- Make every model use go through a typed slot (`STTProvider`, `VoiceProvider`, `BrainProvider`, `AgentRuntime`) so providers can be swapped or self-hosted.
- Keep the JavaScript drawing engine as a separate, testable bundle.

| OpenClicky module (Swift package target unless noted) | Replaces HeyClicky areas | Key responsibilities |
|---|---|---|
| `OpenClickyApp` | app-shell | `@main`, `NSApplicationDelegate`, `LSUIElement` agent, launch at login, menu, dependency container, feature flags (local JSON in place of `/app-config`) |
| `OCCore` | app-shell, account | Settings store (`oc.<area>.<name>.vN`), Keychain wrapper, logging, file locations under `~/Library/Application Support/OpenClicky`, JSONL journal utility |
| `OCProviders` | all model slots | Protocols `STTProvider` (streaming sessions), `VoiceProvider` (streaming TTS with barge-in), `BrainProvider` (multimodal and tool calling, streaming), `GroundingProvider`, `AgentRuntime`; adapters for OpenAI Realtime, Gemini Live, Anthropic, OpenRouter and local models; ephemeral-token minting either local or through a user-run proxy |
| `OCPermissions` | onboarding-permissions | `PermissionKind` state machine (mic, accessibility, screen recording, SCK picker, automation, folders), System Settings deep links, guide overlay |
| `OCHotkeys` | hotkeys-input | CGEvent-tap monitors for hold and double-tap modifiers, Escape interrupt, recorder UI |
| `OCAudio` | stt-mic, realtime-voice, audio-feedback | Mic capture with device failover, resampling to PCM16 mono, duplex AEC engine, playback sink, chimes, temporary unmute |
| `OCScreenContext` | screen-context | ScreenCaptureKit capture with self-exclusion, AX focused element and document readers, browser site reader, call and focus detection |
| `OCBrain` | voice-brain, text-chat | Turn orchestrator (press → transcript → brain request → stream lines, drawing program, tools), tool registry, compaction, prewarm, timing metrics, stats HUD |
| `OCDrawing` (+ JS package `openclicky-draw`) | screen-drawing, drawings-library | JavaScriptCore host, native painter, text shaper, pen follower, captions, sound beds, Metal 3D stage, lesson save, replay and export |
| `OCOverlay` | pointing-annotation | Per-display transparent overlay, companion cursor actor, annotations, element grounding, guided walkthrough loop |
| `OCNotch` | notch-shell | Notch panel per screen, presenter state machine, tabs, transient surfaces |
| `OCHome` | home-window, file-previews | Main window, conversation store, settings pages, Markdown, XLSX and PDF previews |
| `OCAgents` | agent-runtime, routines | `AgentRuntime` protocol with adapters for Codex app-server (JSON-RPC over stdio) and a pi-style harness; isolated agent home; loopback MCP server for app tools; Clickys roster, jobs, work folders, pending requests, restart recovery; local scheduler for routines |
| `OCInk` | agent-output-ui | Note DSL parser, linter and renderer; edge deck and cards; note actions feedback to the agent |
| `OCTakeOver` | take-over-drive | Consent card, actuator (CGEvent/AX), user-input hold, safety stops |
| `OCBrowserBridge` (+ helper target `OpenClickyBrowserHost`, + Chrome extension) | browser-bridge | Native-messaging host manifest install, loopback relay with token, per-turn grants, MCP endpoint for agents |
| `OCIntegrations` | integrations-connectors | Custom MCP connectors with OAuth 2.1 (PKCE, DCR, protected-resource discovery), secret store; optional hosted-gateway adapter |
| `OCSkills` | skills-powerups | Local skill library (Markdown with front-matter), activation into the agent home |
| `OCDictation` | dictation | Focus-context capture, streaming STT, optional cleanup, insertion and clipboard fallback, correction learning, transcript archive |
| `OCHandoff` | handoff | Attach target, region capture, paste-and-Return delivery |
| `OCUIKit` | ui-kit, character-persona | Design tokens, paper and sketch components, portrait renderer |

Not rebuilt (out of scope): billing and paywall, referral, PostHog / Sentry telemetry (replace with local logs and opt-in crash reports), Supabase auth (replace with local or no account), Composio dependency (replace with direct MCP connectors).

---

## 14. Open items and cross-checks for other docs

- Which agent runtime is the 1.1.2 default? `CodexRuntime` is not shipped, while `clicky-harness` is. The `AgentHarness` enum includes `codex`, `pi` and `h1`, and the data dir shows only `h1-*`.
- The Deepgram STT and `/deepgram-token` from the task brief are not present in 1.1.2. The STT docs should describe Gemini ears and Apple fallback instead.
- `OpenAIAPI.swift` (direct Chat Completions) and `AnthropicMessagesURL`: production path or dev-only? Not decidable statically.
- `activity-timeline.sqlite` and `app-usage-timeline.sqlite` are referenced by proactive suggestions; their producer is UNKNOWN.

---

## Appendix A. Every top-level HeyClicky type, grouped by feature area

OBSERVED: names recovered from the arm64 slice `__swift5_types` reflection records (1,903 unique top-level names; nested types such as `CompanionManager.CompanionConversationTurn` are omitted here). Grouping is by name prefix and is INFERRED; a few types may sit in a neighbouring group.

### billing (34)

`AgentPaywallHUDManager`, `AgentPaywallHUDView`, `AgentPaywallHUDViewModel`, `BillingCheckoutLauncher`, `BillingClient`, `BillingClientError`, `BillingCursorLineUserInfoKey`, `BillingEnforcementMode`, `BillingPaywallDetector`, `BillingStateManager`, `CheckoutCompleteNotificationUserInfoKey`, `ClickyUsageCard`, `ClickyUsageCardPopover`, `ClickyUsageContext`, `ClickyUsageRingGlyph`, `CodexExtraUsageApprovalMode`, `DictationPaywallReachedError`, `EarlyStopRefundResponseBody`, `PaywallBillingInterval`, `PaywallCardChrome`, `PaywallCardContent`, `PaywallErrorUserInfoKey`, `PaywallInfoTipButton`, `PaywallInputPanel`, `PaywallNotificationUserInfoKey`, `PaywallPalette`, `PaywallPayload`, `PaywallPlanKey`, `PaywallPlanOption`, `PaywallReason`, `PaywallSurface`, `PlanBillingFingerprint`, `PlanSnapshot`, `ReferralPaywallDiscount`

### referral (34)

`ClickyNotchReferralButton`, `HomeSpaceReferralBalanceHelp`, `HomeSpaceReferralBalanceHelpAnchorKey`, `HomeSpaceReferralBalanceHelpOverlay`, `HomeSpaceReferralBalanceInfoIcon`, `HomeSpaceReferralEarningsEstimatorCard`, `HomeSpaceReferralEarningsOverview`, `HomeSpaceReferralFriendCodeSection`, `HomeSpaceReferralHeldCodeCard`, `HomeSpaceReferralInvitedFriendsList`, `HomeSpaceReferralLoadingSkeleton`, `HomeSpaceReferralMoneyBarChart`, `HomeSpaceReferralNegativeBalanceNote`, `HomeSpaceReferralPage`, `HomeSpaceReferralPalette`, `HomeSpaceReferralPayoutEmail`, `HomeSpaceReferralPayoutsAndTerms`, `HomeSpaceReferralTermsTiles`, `ReferralClaimResult`, `ReferralEarningsEstimate`, `ReferralEarningsEstimator`, `ReferralEarningsEstimatorInputs`, `ReferralEarningsMixEstimate`, `ReferralEarningsPlanMix`, `ReferralProgramFormatting`, `ReferralProgramInvitedFriend`, `ReferralProgramModel`, `ReferralProgramMonthlyEarnings`, `ReferralProgramReferredBy`, `ReferralProgramSnapshot`, `ReferralProgramStats`, `ReferralProgramTerms`, `ReferralUsernameChangeResult`, `ReferralUsernameRules`

### account-auth (16)

`AccountDeletionClient`, `AccountDeletionConfirmView`, `AccountDeletionErrorPresentation`, `AccountDeletionPanel`, `AccountDeletionPanelManager`, `AccountDeletionReasonChip`, `AccountDeletionReasonOption`, `AccountDeletionStep`, `ClickyAuthRecovery`, `ClickyClientIdentity`, `ClickyKeychainStore`, `ClickySessionRefreshUnavailableError`, `ClickySignInCallbackGuard`, `LoopbackCallbackServer`, `SupabaseAuthManager`, `SupabaseRefreshErrorDiagnostic`

### screen-drawing (126)

`CardHandleLayout`, `CardHandlePanel`, `CardHandleView`, `CardWindowButtonsView`, `ClickyBaselinePlaced`, `ClickyCanvasAnimatedValue`, `ClickyCanvasAnimation`, `ClickyCanvasBaker`, `ClickyCanvasContent`, `ClickyCanvasGlow`, `ClickyCanvasGlyphInk`, `ClickyCanvasInterpolation`, `ClickyCanvasNode`, `ClickyCanvasPenMask`, `ClickyCanvasPenStroke`, `ClickyCanvasPlane`, `ClickyCanvasRenderer`, `ClickyCanvasScene`, `ClickyCanvasShape`, `ClickyCanvasTimingCurve`, `ClickyCanvasView`, `ClickyDrawingLaptopScreen`, `ClickyDrawingSaveOffer`, `ClickyDrawingSaveOfferHostingView`, `ClickyDrawingSaveOfferView`, `ClickyDrawingSaver`, `ClickyDrawingSpokenCaption`, `ClickyDrawingVideoRecorder`, `ClickyDrawingWindowPanel`, `ClickyDrawingWindowView`, `ClickyDrawingWindowViewer`, `ClickyLesson`, `ClickyLessonDraft`, `ClickyLessonInlinePlayer`, `ClickyLessonNarrationFile`, `ClickyLessonPlaybackProgress`, `ClickyLessonPlayer`, `ClickyLessonPolaroidLayout`, `ClickyLessonPolaroidRenderer`, `ClickyLessonPrintJob`, `ClickyLessonPrinter`, `ClickyLessonRecorder`, `ClickyLessonStageNSView`, `ClickyLessonStageView`, `ClickyLessonStore`, `ClickyLessonWarp`, `ClickyRecentDrawings`, `ClickySVGPath`, `ClickyThreeKernel`, `DaVinci3DCatmullRomCurve`, `DaVinci3DDrawItem`, `DaVinci3DEarClipping`, `DaVinci3DGeometry`, `DaVinci3DLabelPlacement`, `DaVinci3DMaterial`, `DaVinci3DMath`, `DaVinci3DMesh`, `DaVinci3DNode`, `DaVinci3DPathFlattener`, `DaVinci3DRenderer`, `DaVinci3DScene`, `DaVinci3DStudioRenderer`, `DaVinci3DValue`, `DaVinci3DVertex`, `HandlePanel`, `HandleView`, `HomeSpaceDrawingRecordingLabel`, `HomeSpaceLessonBeatScrubber`, `HomeSpaceLessonTimeLabel`, `NotchHeyClickyChatDrawingRow`, `PinnedCardFlight`, `PinnedCardView`, `PinnedCardsPanel`, `PinnedCardsStackView`, `ScreenDrawing3DClick`, `ScreenDrawing3DHandle`, `ScreenDrawing3DRenderers`, `ScreenDrawing3DShaderWarmup`, `ScreenDrawing3DStage`, `ScreenDrawingActionButton`, `ScreenDrawingActionButtonPanel`, `ScreenDrawingActionButtonView`, `ScreenDrawingCSSColor`, `ScreenDrawingCanvas`, `ScreenDrawingCardDragHandles`, `ScreenDrawingClient`, `ScreenDrawingClientError`, `ScreenDrawingClock`, `ScreenDrawingContinuationDecision`, `ScreenDrawingDisplayChoice`, `ScreenDrawingDraggableCard`, `ScreenDrawingHandOff`, `ScreenDrawingLiveCaption`, `ScreenDrawingLiveDrawing`, `ScreenDrawingNarrationOutcome`, `ScreenDrawingNativeCaption`, `ScreenDrawingNativeEngine`, `ScreenDrawingNativeMarkTiming`, `ScreenDrawingNativePainter`, `ScreenDrawingNativePenStroke`, `ScreenDrawingNativeResources`, `ScreenDrawingPen`, `ScreenDrawingPenCursorController`, `ScreenDrawingPenFollower`, `ScreenDrawingPenHandoff`, `ScreenDrawingPenStroke`, `ScreenDrawingPhotoLoader`, `ScreenDrawingPinnedCardViewer`, `ScreenDrawingPinnedCards`, `ScreenDrawingPreferences`, `ScreenDrawingPreparedProgram`, `ScreenDrawingProgram`, `ScreenDrawingProgramMarkers`, `ScreenDrawingPublicImageFetch`, `ScreenDrawingSVGPath`, `ScreenDrawingSoundPlayer`, `ScreenDrawingStaleWatch`, `ScreenDrawingStreamState`, `ScreenDrawingSuggestionCards`, `ScreenDrawingTargetSnapper`, `ScreenDrawingTextShaper`, `ScreenDrawingTurbulence`, `ScreenDrawingUnitBezier`, `ScreenDrawingWindowChrome`, `SketchStrokeGenerator`, `StoredClickyLesson`

### pointing-annotation (100)

`AnnotationAccessibilityHarvester`, `AnnotationBeat`, `AnnotationShapeKind`, `AnnotationShapeOverlay`, `AnnotationShapeOverlayView`, `AnnotationVisual`, `BlueCursorStopIconView`, `BlueCursorView`, `ClickyPointerCursor`, `ClickyPointerEvaluationDriver`, `ClickyPointerEventSource`, `ClickyPointerOnHoverModifier`, `ClickyPointerSample`, `ClickyScreenRectAnchor`, `ClickyScreenRectAnchorView`, `CompanionActorAssetLoader`, `CompanionActorAtlas`, `CompanionActorChoreography`, `CompanionActorDirection`, `CompanionActorFrameClock`, `CompanionActorHostEvent`, `CompanionActorMotionMode`, `CompanionActorOverlayHostRole`, `CompanionActorOverlayRenderingPolicy`, `CompanionActorPackAssets`, `CompanionActorRenderMetrics`, `CompanionActorRenderer`, `CompanionActorState`, `CompanionActorStateDefinition`, `CompanionActorStateMapper`, `CompanionActorSurface`, `CompanionActorTokenSpeedMeter`, `CompanionActorWorkSpeed`, `CursorAdjacentPanelPlacement`, `CursorAdjacentPanelPlacements`, `CursorMessageBubbleSizePreferenceKey`, `CursorMessageBubbleView`, `CursorMessageBubbleWordRevealModifier`, `CursorMessageBubbleWordToken`, `CursorThinkingDotsLayers`, `CursorThinkingDotsView`, `CursorVideoPresentationKind`, `CursorVoicePieceLayerView`, `CursorVoicePieceMetrics`, `CursorWaveformBars`, `CursorWaveformBarsView`, `DetachedClickAgainToStopPill`, `DetachedCursorClickCatcherView`, `DetachedCursorClickPanel`, `ElementLocationDetector`, `GuidedClickTarget`, `GuidedFollowUpRequestContext`, `GuidedTargetPulseLayerView`, `GuidedTargetPulseLayers`, `GuidedWalkthroughLog`, `IBeamCursorNSView`, `IBeamCursorView`, `MascotSpeechBubbleShape`, `NavigationBubbleSizePreferenceKey`, `OverlayCursorColorChoice`, `OverlayCursorFlightTriangleView`, `OverlayCursorMoverMotion`, `OverlayCursorMoverView`, `OverlayCursorPassThroughView`, `OverlayCursorPerformanceController`, `OverlayCursorPerformanceStage`, `OverlayCursorPointingFlightPath`, `OverlayCursorSpring`, `OverlayCursorSpringState`, `OverlayCursorStageRole`, `OverlayCursorStageView`, `OverlayCursorSystemVisibilityMonitor`, `OverlayWindow`, `OverlayWindowManager`, `PerformanceCursorBodyPiecesStageContent`, `PerformanceCursorBubbleStageContent`, `PerformanceCursorFollowRuleInputs`, `PerformanceCursorNavigationStageContent`, `PerformanceCursorRules`, `PerformanceCursorStageGeometry`, `PerformanceCursorTriangleStageContent`, `PerformanceCursorViewState`, `PointerContainerView`, `PointerCursorNSView`, `PointerCursorView`, `RenderServerCursorThinkingDots`, `RenderServerCursorWaveform`, `RenderServerDetachedCursorFloat`, `RenderServerGuidedTargetPulse`, `RenderServerLoop`, `RenderServerLoopHostView`, `RenderServerMotionTrack`, `RenderServerNotchDwellRing`, `ScreenAnnotationCanvasView`, `ScreenAnnotationManager`, `ScreenAnnotationOverlay`, `ScreenAnnotationPanel`, `SystemCursorVisibilityProbe`, `ThinkingDotsGeometry`, `Triangle`

### take-over-drive (21)

`ClickyAppDriver`, `ClickyAppWindowLocator`, `ClickyBackgroundCursorControl`, `ClickyConsentReplyMarker`, `ClickyDriveAX`, `ClickyDriveConsentNotchSurface`, `ClickyDriveNotchLayout`, `ClickyDriveNotchState`, `ClickyDriveNotchSurface`, `ClickyDriveNudgeShake`, `ClickyMacStepWaiters`, `ClickyScreenActuator`, `ClickyTakeOverConsentCard`, `ClickyTakeOverConsentView`, `ClickyTakeOverController`, `ClickyTakeOverOverlay`, `ClickyUserInputBlocker`, `CodexComputerUseActivity`, `OnboardingClickyDriveStepContent`, `OnboardingDriveDemo`, `OnboardingDriveTarget`

### browser-bridge (10)

`ActiveBrowserSiteReader`, `ClickyBrowserBridge`, `ClickyBrowserNativeHostSetupError`, `ClickyChromeAutoInstall`, `ClickyChromeSetupFlow`, `ClickyDefaultBrowserIcon`, `HomeSpaceBrowserConnectionSettings`, `HomeSpaceBrowserIcon`, `HomeSpaceBrowserStatusBadge`, `HomeSpaceConnectChromeCard`

### integrations-connectors (77)

`ActiveIntegrationSuggestion`, `ActiveSidecarLearningSuggestion`, `AgentComposioMCPSessionResponse`, `AgentComposioMultiAccountToolkit`, `AgentIntegration`, `AgentIntegrationAccount`, `AgentIntegrationCategory`, `AgentIntegrationConnectResponse`, `AgentIntegrationConnectedToast`, `AgentIntegrationDisconnectResponse`, `AgentIntegrationListFilter`, `AgentIntegrationReturnDestination`, `AgentIntegrationSettingsConnection`, `AgentIntegrationStatus`, `AgentIntegrationStatusBadge`, `AgentIntegrationToolkit`, `AgentIntegrationsResponse`, `ClickyCustomConnector`, `ClickyCustomConnectorArgumentParser`, `ClickyCustomConnectorCapabilityDeriver`, `ClickyCustomConnectorCommandResolver`, `ClickyCustomConnectorOAuthClient`, `ClickyCustomConnectorOAuthClientCredentials`, `ClickyCustomConnectorOAuthDiscovery`, `ClickyCustomConnectorOAuthError`, `ClickyCustomConnectorOAuthTokens`, `ClickyCustomConnectorRuntimeRegistration`, `ClickyCustomConnectorSecretStore`, `ClickyCustomConnectorSecrets`, `ClickyCustomConnectorSignInState`, `ClickyCustomConnectorStore`, `ClickyCustomConnectorToolCatalog`, `ClickyCustomConnectorVerification`, `ComposioAgentMCPConfiguration`, `ComposioAgentMCPSessionFetchResult`, `ComposioAgentSessionCache`, `ComposioAgentSessionFetchPolicy`, `ComposioConnectedAppsUnreachableError`, `HomeSpaceCustomConnectorDraft`, `HomeSpaceCustomConnectorDraftStore`, `HomeSpaceCustomConnectorEditorCard`, `HomeSpaceCustomConnectorGlyph`, `HomeSpaceCustomConnectorListRow`, `HomeSpaceCustomConnectorRow`, `HomeSpaceCustomConnectorTextEditor`, `HomeSpaceCustomConnectorTextField`, `HomeSpaceCustomConnectorTransportOption`, `HomeSpaceIntegrationAccountPhoto`, `HomeSpaceIntegrationAccountRow`, `HomeSpaceIntegrationAccountsList`, `HomeSpaceIntegrationAddAccountRowButton`, `HomeSpaceIntegrationConnectionBadge`, `HomeSpaceIntegrationConnectionHighlight`, `HomeSpaceIntegrationListPresentation`, `HomeSpaceIntegrationRow`, `HomeSpaceIntegrationsLoadingShimmer`, `HomeSpaceIntegrationsSettingsContent`, `IntegrationLogoArtwork`, `IntegrationSuggestionActionButton`, `IntegrationSuggestionCandidate`, `IntegrationSuggestionDismissReason`, `IntegrationSuggestionLogoPair`, `IntegrationSuggestionMonitor`, `NotchConnectedToolLogo`, `NotchIntegrationConnectedSurface`, `NotchIntegrationSuggestionSurface`, `NotchSidecarLearningSuggestionSurface`, `NotchSpotifyVoiceTipSurface`, `RealtimeSessionCustomConnector`, `RealtimeSessionIntegrationAccounts`, `RemoteIntegrationLogoCacheEntry`, `RemoteIntegrationLogoLoader`, `RemoteIntegrationLogoView`, `SidecarLearningLogoPair`, `SidecarLearningSuggestionCandidate`, `SpotifyVoiceTipLogoPair`, `SuggestionAppBadge`

### skills-powerups (45)

`ClickyBundledCodexAssets`, `ClickyPowerUp`, `ClickyPowerUpManager`, `ClickySkillAuthor`, `ClickySkillLibraryBackend`, `ClickySkillLibraryBackendError`, `ClickySkillReviewStatus`, `ClickySkillStatusBadge`, `CreateSkillFieldChrome`, `CreateSkillPanelManager`, `CreateSkillPanelView`, `CreateSkillPanelViewModel`, `HatchPowerUpWiggleValues`, `HermesSkill`, `HermesSkillCatalog`, `HermesSkillCategory`, `LearningSkillCatalogEntry`, `NotchSkillPinnedSurface`, `PowerUpAvatarView`, `PowerUpCelebrationWiggleValues`, `PowerUpCreateSkillForm`, `PowerUpPanel`, `PowerUpPanelClickyGlyph`, `PowerUpPanelManager`, `PowerUpPanelView`, `PowerUpPanelViewModel`, `PowerUpSkillFileStore`, `RealtimeSessionActiveSkill`, `RemotePowerUpSkill`, `RemoteSkillAuthor`, `RemoteSkillCategory`, `RemoteSkillLibrary`, `RemoteSkillUsage`, `SkillCatalogRow`, `SkillCatalogRowButtonStyle`, `SkillCategoryStyle`, `SkillContentPreviewCache`, `SkillCreationElapsedLabel`, `SkillListShimmerRow`, `SkillSelectionWiggleValues`, `SkillStatusBadgeChip`, `SkillTagIconView`, `SkillTagStyle`, `SkillUserAvatarChrome`, `SkillUsersAvatarStackView`

### routines-proactive (71)

`AgentCronRunNowResponse`, `AgentNotification`, `AgentNotificationSeverity`, `AgentNotificationsResponse`, `ClickyCallPresenceDetector`, `ClickyCallPresenceReason`, `ClickyFocusModeDetector`, `ClickyFocusModeReason`, `ClickyInkRoutineControl`, `ClickyInkRoutineEditor`, `ClickyInkRoutineStatusLine`, `ClickyQuietContextReason`, `ClickyRoutine`, `ClickyRoutineFullWakeObserver`, `ClickyRoutineKeepAwake`, `ClickyRoutineNetworkObserver`, `ClickyRoutineResultsMirror`, `ClickyRoutineRunMarker`, `ClickyRoutineRunTrigger`, `ClickySuggestionApprovalMarker`, `ClickyUpcomingCalendarBackendClient`, `GoodMorningBrief`, `HomeSpaceRoutineSettingsRow`, `HomeSpaceRoutineVoiceHint`, `HomeSpaceRoutinesSettingsContent`, `HomeSpaceSuggestionActionTransition`, `HomeSpaceSuggestionAdjustmentControls`, `HomeSpaceSuggestionHeldCard`, `HomeSpaceSuggestionPaging`, `HomeSpaceSuggestionPortrait`, `HomeSpaceSuggestionPresenter`, `HomeSpaceSuggestionProposal`, `HomeSpaceSuggestionScrollGesture`, `HomeSpaceSuggestionSelection`, `HomeSpaceSuggestionSender`, `HomeSpaceSuggestionsPage`, `MeetingJoinButton`, `MorningClickyCharacter`, `MorningClickyConstellation`, `MorningClickyGreetingBeat`, `MorningFloatingClicky`, `MorningSuggestionsInvitationPolicy`, `MorningSuggestionsNarration`, `MorningSuggestionsNotice`, `NotchMeetingCountdownSurface`, `NotchMorningSuggestionsSurface`, `PersistedHomeSpaceSuggestedCard`, `ProactiveAgentCheckReason`, `ProactiveAgentJobStatus`, `ProactiveAgentSlotDayState`, `ProactiveAgentSuggestionHistory`, `ProactiveAgentSuggestionHistoryEntry`, `ProactiveAgentSuggestionResolution`, `ProactiveAgentsClient`, `ProactiveAgentsResponse`, `ProactiveSuggestedAgentCard`, `ProactiveSuggestedNewClicky`, `ProactiveSuggestedRoutine`, `ProactiveSuggestionAdjustmentQuestionBudget`, `ProactiveSuggestionApprovalResult`, `ProactiveSuggestionCadence`, `ProactiveSuggestionVoiceAction`, `ProactiveTaskQueueStatus`, `QueuedProactiveTask`, `ScheduledAgentCronDetail`, `ScheduledAgentCronDetailResponse`, `ScheduledAgentCronRun`, `ScheduledAgentCronSummary`, `ScheduledAgentCronsResponse`, `UpcomingCalendarEvent`, `UpcomingMeetingPrimaryActionKind`

### character-persona (62)

`AgentCloudEyePose`, `AgentCloudEyeShape`, `AgentCloudFaceMood`, `AgentCloudFaceTraits`, `AgentCloudShape`, `AgentCloudSilhouette`, `AgentCloudSleepZShape`, `CatModeRuntimeFlag`, `ClickyAgentHeldPropView`, `ClickyAgentProp`, `ClickyAgentPropArtView`, `ClickyAgentPropGesture`, `ClickyAgentPropHold`, `ClickyAvatarImageStore`, `ClickyAvatarImageView`, `ClickyBrandMark`, `ClickyBrandMarkLayerView`, `ClickyBrandMarkShape`, `ClickyBrandMarkView`, `ClickyCharacterLedgeHand`, `ClickyCharacterPortrait`, `ClickyClassicCloudPortrait`, `ClickyCloudArmCurve`, `ClickyCloudLedgeHandShape`, `ClickyCloudLimbLayer`, `ClickyCloudLimbsShape`, `ClickyCloudPortrait`, `ClickyComputerMark`, `ClickyIdentityIconShape`, `ClickyInteractivePortrait`, `ClickyKiCrewHair`, `ClickyPortraitAppearance`, `ClickyPortraitCharacter`, `ClickyPortraitColorway`, `ClickyPortraitExpression`, `ClickyPortraitFraming`, `ClickyPortraitHair`, `ClickyPortraitHairstyle`, `ClickyPortraitOutfit`, `ClickyPortraitPack`, `ClickyPortraitPackHair`, `ClickyPortraitPackOutfit`, `ClickyPortraitPresentation`, `ClickyPortraitReaction`, `ClickyPortraitReactionDelivery`, `ClickyPortraitRig`, `ClickyPortraitSkinTone`, `ClickyPropBoltShape`, `ClickyPropCartShape`, `ClickyPropChartArrowShape`, `ClickyPropChevronShape`, `ClickyPropOpenBookShape`, `ClickyPropPaperPlaneShape`, `ClickyPropSparkleShape`, `ClickyPropStarShape`, `ClickyPropTriangleShape`, `ClickySquareFace`, `ClickyStorybookPortrait`, `CloudFaceExpression`, `CloudFaceEyeAnimationOverride`, `HomeSpaceAccountAvatarDisc`, `HomeSpaceCloudFaceView`

### agent-runtime (155)

`AgentHUDGelIconButton`, `AgentHandoffBlock`, `AgentHarness`, `AgentHarnessError`, `AgentHarnessEvent`, `AgentHarnessLocalMCPCommand`, `AgentHarnessMCPServer`, `AgentHarnessModel`, `AgentHarnessPlace`, `AgentHarnessPreferences`, `AgentHarnessReadyLineReader`, `AgentHarnessRunnerProcess`, `AgentHarnessRunnerRuntime`, `AgentHarnessRuntime`, `AgentHarnessRuntimes`, `AgentHarnessTurn`, `AgentHarnessTurnContext`, `AgentLaunchTimingLog`, `AgentMessageLogRequestBody`, `AgentPermissionInspector`, `ClickyAgentBriefThreadMarker`, `ClickyAgentCommentaryRelay`, `ClickyAgentIconMemo`, `ClickyAgentIconView`, `ClickyAgentStandingContextLedger`, `ClickyAgentTurnCostFooter`, `ClickyAgentTurnCostLedger`, `ClickyAgentTurnUsageRecord`, `ClickyAppLiveStatus`, `ClickyAppStore`, `ClickyAppsPreferences`, `ClickyArtifactsTool`, `ClickyCodexAgentRuntimeConfig`, `ClickyDeveloperChatModel`, `ClickyDeveloperChatModelSelection`, `ClickyDeveloperModelAccess`, `ClickyDeveloperPreviewAccess`, `ClickyDeveloperReasoningEffort`, `ClickyFoundingMarker`, `ClickyHarnessRecord`, `ClickyHelperFiles`, `ClickyHomeInkNote`, `ClickyJob`, `ClickyJobBrief`, `ClickyJobCard`, `ClickyJobKind`, `ClickyJobMessageRoute`, `ClickyJobNames`, `ClickyJobRailPhase`, `ClickyJobStepWatcher`, `ClickyJobStore`, `ClickyJobUserStep`, `ClickyJobsPreferences`, `ClickyLearnedHowTo`, `ClickyLearnedHowTos`, `ClickyLocalRootToolExecutor`, `ClickyLoopbackHTTPServer`, `ClickyLoopbackMCPServer`, `ClickyMainArtifacts`, `ClickyOpenAIModelPricing`, `ClickyOrganizerClient`, `ClickyPendingAgentRequest`, `ClickyPendingAgentRequestStore`, `ClickyProgramBatch`, `ClickyProgramLogoRegistry`, `ClickyRestartInterruptions`, `ClickyRoster`, `ClickySpawnRepeatGuard`, `ClickyStarterAgentPins`, `ClickyStarterAgentWorkspace`, `ClickyTourJob`, `ClickyTourJobCardHost`, `ClickyTourJobCardLayout`, `ClickyTourJobCardView`, `ClickyTourJobCards`, `ClickyTourJobFirstClickHostingView`, `ClickyWorkEntry`, `ClickyWorkFolderFiles`, `ClickyWorkIndex`, `ClickyWorkPiece`, `ClickyWorkReplyParts`, `ClickyWorkShelf`, `CodexActiveTaskSnapshot`, `CodexAgentAttachmentSupport`, `CodexAgentCitationMarkers`, `CodexAgentFileDiffItem`, `CodexAgentFileDiffKind`, `CodexAgentFileSnapshot`, `CodexAgentFinishedCue`, `CodexAgentRoutineRequest`, `CodexAgentSession`, `CodexAgentTapback`, `CodexAgentTurnFeedbackPolicy`, `CodexAgentTurnLaunchRequest`, `CodexAgentTurnLease`, `CodexAgentTurnLeaseCompletionRequestBody`, `CodexAgentTurnLeaseContinueRequestBody`, `CodexAgentTurnLeaseRecorder`, `CodexAgentTurnLeaseRequestBody`, `CodexAgentTurnLeaseResponseBody`, `CodexAgentTurnPromptBuilder`, `CodexHomeManager`, `CodexHomeManagerError`, `CodexHomeSpaceCacheStorage`, `CodexIncomingMessage`, `CodexLaunchFlightLayerPlayer`, `CodexLaunchFlightManager`, `CodexLocalThreadTranscriptTurn`, `CodexLoopbackMCPEndpoint`, `CodexManagedRequirementsCompatibility`, `CodexProcessManager`, `CodexProcessManagerError`, `CodexProtocolClient`, `CodexProtocolError`, `CodexRPCLineFramer`, `CodexRPCLog`, `CodexRPCNotification`, `CodexRPCRequest`, `CodexResponseProjection`, `CodexRolloutConversation`, `CodexRunningTask`, `CodexStartupTimeoutError`, `CodexStatusViewModel`, `CodexStoredThreadPage`, `CodexTaskActivityItem`, `CodexTaskActivityType`, `CodexTaskAnalyticsSnapshot`, `CodexTaskLifecycleState`, `CodexTaskViewModel`, `CodexThreadDisplayPromptStore`, `CodexThreadHistoryCache`, `CodexThreadHistoryItem`, `CodexThreadHistoryStatus`, `CodexThreadLaunchLabels`, `CodexThreadLaunchRequestBody`, `CodexThreadLaunchResponseBody`, `CodexThreadLaunchSourceKind`, `CodexThreadTranscriptCache`, `CodexTurnCompletion`, `FloatingAgentChipPalette`, `HomeSpaceStarterAgent`, `HomeSpaceStarterCast`, `InflightToolCallBuffer`, `MultiAgentScrollingLabel`, `NotchAgentDisplayTitle`, `NotchAgentFaceBadge`, `NotchAgentIntegrationBadge`, `NotchAgentPeekFileIndex`, `NotchAgentPeekLayout`, `NotchAgentPeekWorkspaceFiles`, `NotchAgentStaticFaceBadge`, `NotchAgentSurface`, `NotchRunningTaskChangeObserver`, `RemoteAppProgram`, `RemoteCallerTeam`

### agent-output-ui (312)

`ClickyArcCard`, `ClickyArcCardContent`, `ClickyArcCardHost`, `ClickyArcCover`, `ClickyArcFileChip`, `ClickyArcFitSizes`, `ClickyArcGelTrack`, `ClickyArcPlan`, `ClickyArcPlanStepRow`, `ClickyArcProgressBar`, `ClickyArcStopButton`, `ClickyBreathingText`, `ClickyBreathingTextView`, `ClickyCardDots`, `ClickyCardFace`, `ClickyCardFooter`, `ClickyCardFooterRequest`, `ClickyCardFooterRequestRow`, `ClickyCardLatest`, `ClickyCardReadyOutput`, `ClickyCardSparkline`, `ClickyCardStatus`, `ClickyCardStyle`, `ClickyCardTheme`, `ClickyCardView`, `ClickyEdgeCardLayout`, `ClickyEdgeDeck`, `ClickyEdgeDeckCard`, `ClickyEdgeDeckFocus`, `ClickyEdgeDeckLayout`, `ClickyEdgeDeckMoreButton`, `ClickyEdgeDeckRemoval`, `ClickyEdgeDockRecency`, `ClickyEdgeDockedClickys`, `ClickyEdgePinTransitions`, `ClickyEdgeShelfActions`, `ClickyEdgeShelfController`, `ClickyEdgeShelfFramesKey`, `ClickyEdgeShelfGeometry`, `ClickyEdgeShelfHostingView`, `ClickyEdgeShelfLayout`, `ClickyEdgeShelfModel`, `ClickyEdgeShelfPanel`, `ClickyEdgeShelfPins`, `ClickyEdgeShelfRailEntry`, `ClickyEdgeShelfView`, `ClickyEdgeStackFitOrScroll`, `ClickyEdgeStackInkCard`, `ClickyEdgeStackInkFace`, `ClickyEdgeStackInkFooter`, `ClickyEdgeStackInkHeader`, `ClickyEdgeStackInkLead`, `ClickyEdgeStackInkLook`, `ClickyEdgeStackInkPaper`, `ClickyEdgeStackInkPresentation`, `ClickyEdgeStackInkPulledCard`, `ClickyEdgeStackInkReading`, `ClickyEdgeStackInkScreenPaper`, `ClickyEdgeStackInkTape`, `ClickyEdgeStackPulledInkHeightKey`, `ClickyFileCardRow`, `ClickyHandLineBreaker`, `ClickyHandParagraphCanvas`, `ClickyHandParagraphLayout`, `ClickyHandRing`, `ClickyHandText`, `ClickyHandTextMetrics`, `ClickyHomeRendering`, `ClickyHomeSpreadPaper`, `ClickyInkActedOn`, `ClickyInkActionFeedback`, `ClickyInkActions`, `ClickyInkActionsStore`, `ClickyInkActivity`, `ClickyInkAnswer`, `ClickyInkApprovedStamp`, `ClickyInkArrowStroke`, `ClickyInkAsks`, `ClickyInkAudioPlayer`, `ClickyInkBarcode`, `ClickyInkBlankLine`, `ClickyInkBottomClip`, `ClickyInkBox`, `ClickyInkBrief`, `ClickyInkCardSubject`, `ClickyInkChange`, `ClickyInkChart`, `ClickyInkClipping`, `ClickyInkClock`, `ClickyInkConnect`, `ClickyInkConnections`, `ClickyInkContentWidthKey`, `ClickyInkCountdown`, `ClickyInkCountdownReading`, `ClickyInkCriteria`, `ClickyInkCrossOut`, `ClickyInkDashboardBoard`, `ClickyInkDashboardFaceView`, `ClickyInkDashboardPalette`, `ClickyInkDashboardSplit`, `ClickyInkDashboardView`, `ClickyInkDates`, `ClickyInkDay`, `ClickyInkDayLabel`, `ClickyInkDeltaTag`, `ClickyInkDeskView`, `ClickyInkDocument`, `ClickyInkEdgeCardFooterHeightKey`, `ClickyInkEdgeCardLayout`, `ClickyInkEdgeCardSheetSizeKey`, `ClickyInkEditionView`, `ClickyInkEvent`, `ClickyInkEventDates`, `ClickyInkFaceView`, `ClickyInkFigures`, `ClickyInkFileCard`, `ClickyInkFilePicker`, `ClickyInkFlap`, `ClickyInkFollowOffsetKey`, `ClickyInkForm`, `ClickyInkFrontPageContent`, `ClickyInkFrontPagePlanner`, `ClickyInkFrontPageVariant`, `ClickyInkFrontPageView`, `ClickyInkGallery`, `ClickyInkGalleryTile`, `ClickyInkGroup`, `ClickyInkGroupView`, `ClickyInkGrow`, `ClickyInkHatch`, `ClickyInkHeightMorph`, `ClickyInkIcon`, `ClickyInkImages`, `ClickyInkInlineAnswerField`, `ClickyInkIsGlancePreviewKey`, `ClickyInkIsWindowPreviewKey`, `ClickyInkItemsList`, `ClickyInkLamp`, `ClickyInkLayout`, `ClickyInkLeader`, `ClickyInkLetter`, `ClickyInkLine`, `ClickyInkLinkAttribute`, `ClickyInkLinkRunKey`, `ClickyInkLint`, `ClickyInkList`, `ClickyInkLiveNote`, `ClickyInkLuggageTagShape`, `ClickyInkMadeLink`, `ClickyInkMadeLinkCard`, `ClickyInkMarginNote`, `ClickyInkMaskingTape`, `ClickyInkMatch`, `ClickyInkMiniTile`, `ClickyInkMotion`, `ClickyInkNoteAction`, `ClickyInkNoteActions`, `ClickyInkNotePage`, `ClickyInkNotePages`, `ClickyInkNoteStore`, `ClickyInkNoteTarget`, `ClickyInkNoteVersion`, `ClickyInkNumber`, `ClickyInkObjectKey`, `ClickyInkPageView`, `ClickyInkPagination`, `ClickyInkParser`, `ClickyInkPatchStream`, `ClickyInkPen`, `ClickyInkPenAnchor`, `ClickyInkPenAnchorKey`, `ClickyInkPenAttribute`, `ClickyInkPenClockKey`, `ClickyInkPenRenderer`, `ClickyInkPenSchedule`, `ClickyInkPenScope`, `ClickyInkPencilLayerView`, `ClickyInkPencilLayers`, `ClickyInkPhotos`, `ClickyInkPipeline`, `ClickyInkPipelineView`, `ClickyInkPlace`, `ClickyInkPlanOff`, `ClickyInkPolaroidPicture`, `ClickyInkProgress`, `ClickyInkProgressBar`, `ClickyInkProgressView`, `ClickyInkProse`, `ClickyInkQuestion`, `ClickyInkQuestionAnswers`, `ClickyInkQuiet`, `ClickyInkQuietReading`, `ClickyInkQuiz`, `ClickyInkReceipt`, `ClickyInkRestingPencil`, `ClickyInkReviewCompactLine`, `ClickyInkReviewList`, `ClickyInkReviewRules`, `ClickyInkRowMotion`, `ClickyInkRubberStamp`, `ClickyInkRuledBox`, `ClickyInkRuledLine`, `ClickyInkRunLine`, `ClickyInkRunStamp`, `ClickyInkRunStampMark`, `ClickyInkSentAction`, `ClickyInkSeries`, `ClickyInkSheetCamera`, `ClickyInkSheetLayout`, `ClickyInkSheetRowInfo`, `ClickyInkSheetRowKey`, `ClickyInkSheetRowKind`, `ClickyInkSheetRowView`, `ClickyInkSheetView`, `ClickyInkSketch`, `ClickyInkSketchBar`, `ClickyInkSketchModel`, `ClickyInkSketchPainter`, `ClickyInkSketchRandom`, `ClickyInkSources`, `ClickyInkSpark`, `ClickyInkSparkLine`, `ClickyInkSparkReading`, `ClickyInkSquiggle`, `ClickyInkStatusBoard`, `ClickyInkStatusState`, `ClickyInkStickies`, `ClickyInkStreak`, `ClickyInkStreakBoxes`, `ClickyInkStreakDay`, `ClickyInkStreakReading`, `ClickyInkStyle`, `ClickyInkSupportingFileRow`, `ClickyInkSupportingFiles`, `ClickyInkTable`, `ClickyInkTableLayout`, `ClickyInkTag`, `ClickyInkTally`, `ClickyInkTallyMarks`, `ClickyInkTallyReading`, `ClickyInkTick`, `ClickyInkTicket`, `ClickyInkTicketShape`, `ClickyInkTickingNumber`, `ClickyInkTile`, `ClickyInkTiles`, `ClickyInkTodo`, `ClickyInkTopOfNote`, `ClickyInkTornStrip`, `ClickyInkTornTape`, `ClickyInkWasValue`, `ClickyInkWindowShape`, `ClickyInkWords`, `ClickyInkWorkStep`, `ClickyInkYouSaidSlip`, `ClickyInkZigzagFoot`, `ClickyLiveLine`, `ClickyLiveLineGlyph`, `ClickyLiveLineIcon`, `ClickyLiveLineIconStack`, `ClickyLiveLineView`, `ClickyLiveNotePreferences`, `ClickyLiveNoteState`, `ClickyLiveNoteStore`, `ClickyLiveNoteWatching`, `ClickyLiveSteps`, `ClickyMorphingText`, `ClickyNoteChip`, `ClickyNoteFace`, `ClickyNotePaperColors`, `ClickyNoteShape`, `ClickyNoteView`, `ClickyNoteWindowTitleBarHeightKey`, `ClickyNotebookFlow`, `ClickyNotebookWritingPencil`, `ClickyPaperFileChip`, `ClickyPaperFileKind`, `ClickyPlanCascade`, `ClickyPlanCheck`, `ClickyPlanFoldIntoAnswer`, `ClickyPlanStrike`, `ClickyPlanTickBox`, `ClickyResultCardFace`, `ClickyResultChoiceButtonStyle`, `ClickyResultChoices`, `ClickyResultDraftSlip`, `ClickyResultFileChoice`, `ClickyResultFlow`, `ClickyResultList`, `ClickyResultNextStepButton`, `ClickyResultNumbers`, `ClickyResultReceipt`, `ClickyResultSticky`, `ClickyStickyFileCard`, `ClickyStickyFileCardSound`, `ClickyStickyFileCardStack`, `ClickyStickyHeaderState`, `ClickyStickyPreviewLayout`, `ClickyStickyScreenTitleBar`, `ClickyStickyStateCover`, `ClickyTextMorphIdentity`, `ClickyTextMorphView`, `ClickyTextMotionExamples`, `ClickyThingStatus`, `ClickyThingStockPicker`, `ClickyTopArcBackground`, `ClickyTopArcGreetingLayout`, `ClickyTopArcLayout`, `ClickyTopArcScreenMetrics`, `ClickyWritingCaret`, `StreamingMarkdownView`, `StreamingPulseIndicator`

### file-previews (84)

`BoundedReadResultBox`, `CappedDownload`, `DocumentAnimatedImagePreview`, `DocumentAnimatedImageView`, `HomeSpaceArtifactFileTypeStyle`, `HomeSpaceArtifactInventory`, `HomeSpaceArtifactPreviewContent`, `HomeSpaceArtifactThumbnailLoader`, `HomeSpaceLinkFavicon`, `HomeSpaceLinkPreviewPlate`, `HomeSpaceLinkedTextView`, `HomeSpaceMarkdownPreview`, `HomeSpaceNativeDocumentViewCache`, `HomeSpacePDFPreview`, `HomeSpacePreviewAsset`, `HomeSpacePreviewHeaderButton`, `HomeSpaceQuickLookPreview`, `HomeSpaceSpreadsheetPreview`, `HomeSpaceWebPageSnapshotter`, `MarkdownFileType`, `MarkdownViewerAnimatedImageAttachmentCell`, `MarkdownViewerBlock`, `MarkdownViewerContentView`, `MarkdownViewerCopyBlock`, `MarkdownViewerCopyBlockButton`, `MarkdownViewerDocumentModel`, `MarkdownViewerFileWatcher`, `MarkdownViewerInlineDocument`, `MarkdownViewerInlineRenderCache`, `MarkdownViewerInlineTextView`, `MarkdownViewerListItem`, `MarkdownViewerMetrics`, `MarkdownViewerPalette`, `MarkdownViewerParser`, `MarkdownViewerQuotePlateBlock`, `MarkdownViewerSelectableDocumentView`, `MarkdownViewerSelectableTextView`, `MarkdownViewerTableAttachmentCell`, `MarkdownViewerTableContent`, `MarkdownViewerTableOutlineView`, `MarkdownViewerTableScrollGesture`, `MarkdownViewerTableScrollView`, `MarkdownViewerTextRenderer`, `NotchDocumentAccessSurface`, `NotchDocumentViewer`, `NotchDocumentViewerHeaderRow`, `NotchDocumentViewerLayout`, `SpreadsheetBodyPaneView`, `SpreadsheetBorderEdge`, `SpreadsheetBottomBar`, `SpreadsheetCell`, `SpreadsheetCellAddress`, `SpreadsheetCellRange`, `SpreadsheetCellStyle`, `SpreadsheetChromePalette`, `SpreadsheetColor`, `SpreadsheetDelimitedTextReader`, `SpreadsheetFixedPaneView`, `SpreadsheetFormulaBar`, `SpreadsheetGridLayout`, `SpreadsheetGridPalette`, `SpreadsheetGridRenderer`, `SpreadsheetGridRepresentable`, `SpreadsheetGridView`, `SpreadsheetLinkButton`, `SpreadsheetMetrics`, `SpreadsheetNumberFormat`, `SpreadsheetPaneGeometry`, `SpreadsheetPaneView`, `SpreadsheetReadError`, `SpreadsheetSelection`, `SpreadsheetSelectionSummary`, `SpreadsheetSharedStringsParser`, `SpreadsheetSheet`, `SpreadsheetSheetParser`, `SpreadsheetSheetTab`, `SpreadsheetStylesReader`, `SpreadsheetTextAttributes`, `SpreadsheetThemeColors`, `SpreadsheetViewerState`, `SpreadsheetWorkbook`, `SpreadsheetXLSXReader`, `SpreadsheetXMLNode`, `SpreadsheetZipArchive`

### home-window (146)

`ClickyDockWindowContent`, `ClickyNotchHomeBody`, `ClickyTrafficCloseGlyph`, `ClickyTrafficFullScreenGlyph`, `ClickyTrafficMinimizeGlyph`, `ClickyWindowCapturePolicy`, `ClickyWindowFrame`, `ClickyWindowTitleBarBackground`, `ClickyWindowTrafficButton`, `HeyClickyChatHandOff`, `HeyClickyChatHandOffs`, `HeyClickyConversationHistory`, `HeyClickyConversationMessage`, `HeyClickyWindow`, `HeyClickyWindowAccountRow`, `HeyClickyWindowBackChip`, `HeyClickyWindowColumnHeader`, `HeyClickyWindowColumnResizeHandle`, `HeyClickyWindowComposer`, `HeyClickyWindowComposerBacking`, `HeyClickyWindowContent`, `HeyClickyWindowController`, `HeyClickyWindowConversation`, `HeyClickyWindowConversationLayout`, `HeyClickyWindowDocumentColumn`, `HeyClickyWindowDragArea`, `HeyClickyWindowDragView`, `HeyClickyWindowDropTargetOverlay`, `HeyClickyWindowEmptyConversation`, `HeyClickyWindowFollowsNewestWhileAtBottom`, `HeyClickyWindowHeaderButton`, `HeyClickyWindowLeadingFractionLayout`, `HeyClickyWindowMainThread`, `HeyClickyWindowModel`, `HeyClickyWindowOpeningFlight`, `HeyClickyWindowOpensReplyKey`, `HeyClickyWindowPendingSent`, `HeyClickyWindowRow`, `HeyClickyWindowRowView`, `HeyClickyWindowSettings`, `HeyClickyWindowSettingsHeader`, `HeyClickyWindowSidebar`, `HeyClickyWindowSidebarEntries`, `HeyClickyWindowSidebarName`, `HeyClickyWindowSidebarRow`, `HeyClickyWindowTrafficLights`, `HeyClickyWindowTranscript`, `HeyClickyWindowUsageRing`, `HomeSpaceAccountLabelBadge`, `HomeSpaceAccountLabelChip`, `HomeSpaceAccountSettingsContent`, `HomeSpaceAgentPermissionRow`, `HomeSpaceAgentsSettingsContent`, `HomeSpaceAmbientMotionFrozenKey`, `HomeSpaceClickOutsideDetector`, `HomeSpaceClickyOrdering`, `HomeSpaceConnectorEditorReveal`, `HomeSpaceConnectorEditorRevealLayout`, `HomeSpaceConversationTranscript`, `HomeSpaceCoreAnimationAmbientLifeKey`, `HomeSpaceCoworkFormatting`, `HomeSpaceCoworkLayout`, `HomeSpaceCoworkMarkdownBlock`, `HomeSpaceCoworkMarkdownCache`, `HomeSpaceCoworkPalette`, `HomeSpaceCoworkProseRunView`, `HomeSpaceCoworkStyledTextCache`, `HomeSpaceCoworkTableCell`, `HomeSpaceCoworkTableGrid`, `HomeSpaceCoworkTableLayoutMemo`, `HomeSpaceCoworkTableView`, `HomeSpaceCoworkTurnFooter`, `HomeSpaceCursorColorSwatch`, `HomeSpaceCursorSettingsContent`, `HomeSpaceDeveloperSettingsContent`, `HomeSpaceDictationSettingsContent`, `HomeSpaceDictionaryWordChip`, `HomeSpaceDisplayUserPromptMemo`, `HomeSpaceDocumentAssetCache`, `HomeSpaceDocumentLoadingView`, `HomeSpaceGeneralSettingsContent`, `HomeSpaceHoverPointerModifier`, `HomeSpaceLanguageCell`, `HomeSpaceLayerPhaseBarsView`, `HomeSpaceLayerPhaseDotsView`, `HomeSpaceLayerShimmerSweepView`, `HomeSpaceLayoutMetrics`, `HomeSpaceLoopingLayerHostView`, `HomeSpaceMagicalAppearModifier`, `HomeSpaceMessageBubble`, `HomeSpaceMessagesDateSeparator`, `HomeSpaceMessagesPalette`, `HomeSpaceMessagesStatusLabel`, `HomeSpaceMicrophoneDeviceRow`, `HomeSpaceMicrophoneLevelBars`, `HomeSpaceMicrophoneSettingsContent`, `HomeSpacePage`, `HomeSpacePointerCursor`, `HomeSpacePointerModifier`, `HomeSpaceProseRunTextView`, `HomeSpacePulsingDotView`, `HomeSpaceRailFooterPillMetrics`, `HomeSpaceReceivedIdentity`, `HomeSpaceReplyCalloutKind`, `HomeSpaceReplyCalloutView`, `HomeSpaceReplyChart`, `HomeSpaceReplyChartView`, `HomeSpaceReplyChecklistItem`, `HomeSpaceReplyChecklistView`, `HomeSpaceReplyChipFlow`, `HomeSpaceReplySource`, `HomeSpaceReplySourcesView`, `HomeSpaceScrollRowIntoViewAnchor`, `HomeSpaceScrollToBottomAffordanceModifier`, `HomeSpaceScrollToBottomButton`, `HomeSpaceSentBubbleBackground`, `HomeSpaceSettingsActionRow`, `HomeSpaceSettingsBrandLinkRow`, `HomeSpaceSettingsChip`, `HomeSpaceSettingsChipPicker`, `HomeSpaceSettingsGroup`, `HomeSpaceSettingsPage`, `HomeSpaceSettingsPalette`, `HomeSpaceSettingsPillButton`, `HomeSpaceSettingsRedirectNSView`, `HomeSpaceSettingsRedirectView`, `HomeSpaceSettingsRedirectWindowGrabber`, `HomeSpaceSettingsRow`, `HomeSpaceSettingsRowDivider`, `HomeSpaceSettingsScaffold`, `HomeSpaceSettingsSection`, `HomeSpaceSettingsSidebarRow`, `HomeSpaceSettingsToggleRow`, `HomeSpaceShortcutRecorderRow`, `HomeSpaceShortcutsSettingsContent`, `HomeSpaceSidebarUnreadDot`, `HomeSpaceStyledMessageTextCache`, `HomeSpaceSurfaceMetrics`, `HomeSpaceSurfaceMetricsEnvironmentKey`, `HomeSpaceTheme`, `HomeSpaceTypingDotsView`, `HomeSpaceTypingIndicatorBubble`, `HomeSpaceViewModel`, `HomeSpaceVoiceSettingsContent`, `HomeSpaceVoiceTile`, `WindowBackgroundDragLock`

### dictation (29)

`BuddyDictationDraftCallbacks`, `BuddyDictationManager`, `BuddyDictationPermissionProblem`, `BuddyDictationRecognitionErrorContext`, `BuddyDictationStartSource`, `ClickyDictationController`, `DictationAnnouncementLanguageSection`, `DictationAnnouncementManager`, `DictationAnnouncementPanel`, `DictationAnnouncementShortcutSection`, `DictationAnnouncementView`, `DictationClipboardNotice`, `DictationConfigRowLabel`, `DictationCorrectionLearner`, `DictationCustomVocabulary`, `DictationFocusContext`, `DictationGeminiTranscriber`, `DictationInsertion`, `DictationLanguage`, `DictationLanguageCatalog`, `DictationLearnedCorrection`, `DictationStreamedTranscript`, `DictationTranscriptArchive`, `DictationTranscriptionClient`, `DictationTranscriptionClientError`, `NotchDictationClipboardSurface`, `NotchDictionaryLearnedSurface`, `TextInjectionDelivery`, `TextInsertionPrimitives`

### stt-mic (33)

`AppleSpeechTranscriptionProvider`, `AppleSpeechTranscriptionProviderError`, `AppleSpeechTranscriptionSession`, `BuddyComposerVisualStyle`, `BuddyMicrophoneCaptureInput`, `BuddyNavigationMode`, `BuddyPushToTalkShortcut`, `BuddyStreamingTranscriptionSession`, `BuddyTranscriptionProvider`, `BuddyTranscriptionProviderFactory`, `CaptureSessionSafeTeardown`, `ClickyAudioBufferConversion`, `ClickyAudioLevelModel`, `ClickyAudioLog`, `ClickyAudioTopologyMonitor`, `ClickyAudioTopologySnapshot`, `ClickyCoreAudioAccess`, `ClickyFormatKeyedAudioConverter`, `ClickyMicrophoneDeviceOption`, `ClickyMicrophonePreferences`, `ClickyMicrophoneTestController`, `ClickyMicrophoneTestError`, `DuplexMicrophoneCaptureProcessor`, `InlineVoiceRecordingWaveformView`, `MicrophoneSelectionDefaultsObserver`, `MicrophoneTroubleNotice`, `NotchMicrophoneTroubleSurface`, `PCM16MonoResampler`, `RealtimeMicrophoneCapture`, `SampleBufferDelegateProxy`, `TutorialMicLevelLayerMeter`, `TutorialMicLevelMonitor`, `TutorialMicLevelOutputDelegate`

### voice-brain (26)

`ClickyAnswer`, `ClickyVoiceRoutingReport`, `ContinuationResumeOnceGate`, `EscapeInterruptDecisionBox`, `EscapeInterruptTapContext`, `EscapeInterruptTapThreadHandle`, `OneBrainClickyAnnouncement`, `OneBrainClient`, `OneBrainCompactionPolicy`, `OneBrainGeminiTranscriber`, `OneBrainJobIDs`, `OneBrainJobReports`, `OneBrainModelChoice`, `OneBrainPrewarmPolicy`, `OneBrainResumeOnce`, `OneBrainSayLines`, `OneBrainSpeechSocket`, `OneBrainSpeechTranscript`, `OneBrainStats`, `OneBrainStatsHUD`, `OneBrainStatsHUDView`, `OneBrainToolCallPolicy`, `OneBrainToolRunner`, `OneBrainTranscriptWaiter`, `OneBrainTurnTiming`, `OneBrainVoice`

### realtime-voice (65)

`ChimePlaybackEngine`, `ClickyChimeWarmer`, `ClickyVoiceCueKind`, `ClickyVoicePlateLabel`, `GeminiMouthProtocol`, `GeminiMouthTurnLedger`, `MutedSpeakerCountdownRing`, `MutedSpeakerCountdownRingObservingHover`, `MutedSpeakerRestoreSoundButton`, `MutedSpeakerVoiceReplyNotice`, `NotchMutedSpeakerVoiceReplySurface`, `RealtimeAudioPlaybackSink`, `RealtimeDuplexAudioEngine`, `RealtimeEphemeralSessionRequest`, `RealtimeExplicitAgentFollowUpTarget`, `RealtimeFollowUpRoute`, `RealtimeOutputEngineStarter`, `RealtimePlayer`, `RealtimeProviderAvailabilityDiagnosis`, `RealtimeProviderUnavailableReason`, `RealtimeScopedResponseGate`, `RealtimeSessionExplicitAgentFollowUpTarget`, `RealtimeSessionPromptContext`, `RealtimeSpeechSpeedCatalog`, `RealtimeSpeechSpeedOption`, `RealtimeToolCall`, `RealtimeToolDispatcher`, `RealtimeVoiceCatalog`, `RealtimeVoiceClient`, `RealtimeVoiceClientCallbacks`, `RealtimeVoiceClientConfig`, `RealtimeVoiceClientError`, `RealtimeVoiceController`, `RealtimeVoiceGender`, `RealtimeVoiceOption`, `RealtimeVoiceProvider`, `RealtimeVoiceTurnDetectionMode`, `RealtimeWalkthroughSync`, `SystemAudioOutputVolume`, `VoiceChecklistPicker`, `VoiceCompactCard`, `VoiceDiscoveryDot`, `VoiceDiscoveryDottedGrid`, `VoiceDiscoveryMagnetAnchor`, `VoiceDiscoveryMap`, `VoiceDiscoveryPicker`, `VoiceDiscoveryResolution`, `VoiceDiscoveryTraitLine`, `VoiceHoldShortcut`, `VoiceLanguage`, `VoiceLanguageCatalog`, `VoiceLanguageSuggestions`, `VoiceOptionMiniIcon`, `VoiceOrbitCenter`, `VoiceOrbitNode`, `VoiceOrbitPicker`, `VoicePickerVariantSelector`, `VoicePreviewStore`, `VoiceSnapPulseValues`, `VoiceStepSliderMarker`, `VoiceStepSliderPicker`, `VoiceWavePad`, `VoiceWavePicker`, `VoiceWavePreviewStage`, `VoiceWaveformBars`

### text-chat-widgets (98)

`ClaudeAPI`, `ClaudePromptProfile`, `ClaudeSSEFormat`, `ClickyGrowingTextView`, `ClickyImageLoader`, `ClickyPlacePhotoImage`, `ClickyPlacePhotoSource`, `ClickyRemoteImage`, `ClickyRequestCompression`, `ClickyTextInputAppearanceView`, `ImageSearchAPI`, `ImageSearchRequestBody`, `ImageSearchResponseBody`, `ImageSearchResult`, `InlinePlacePhotoStrip`, `MapMarkerGlyph`, `MapMarkerShape`, `NotchChatFullReplyCloseVia`, `NotchChatFullReplyOpenSource`, `NotchChatResizeEdges`, `NotchChatResizeGrip`, `NotchChatResizeGripView`, `NotchChatResizeGrips`, `NotchChatSizeStore`, `NotchClipboardImageAttachments`, `NotchHeyClickyActionCaption`, `NotchHeyClickyChatFollowUpPill`, `NotchHeyClickyChatFollowUpPills`, `NotchHeyClickyChatFullReply`, `NotchHeyClickyChatHandOffLayout`, `NotchHeyClickyChatHandOffRow`, `NotchHeyClickyChatLiveWorkCard`, `NotchHeyClickyChatPlanStepRow`, `NotchHeyClickyChatReplyBlock`, `NotchHeyClickyChatSitesReadChip`, `NotchHeyClickyChatStamp`, `NotchHeyClickyChatTapedChip`, `NotchHeyClickyChatTextRow`, `NotchHeyClickyChatView`, `NotchHeyClickyChatWorkingPencil`, `NotchHeyClickyComposer`, `NotchHeyClickyHostWindowReader`, `NotchHeyClickyKeepsBottomAnchoredOnSizeChanges`, `NotchHeyClickyMessageRow`, `NotchHeyClickyPagesInNearTop`, `NotchHeyClickyPeekHeaderRow`, `NotchHeyClickyPeekLayout`, `NotchHeyClickyPeekPlanPill`, `NotchHeyClickyPeekSurface`, `NotchHeyClickyPeekSwitcher`, `NotchHeyClickyPeekSwitcherButton`, `NotchHeyClickyReplyPreview`, `NotchHeyClickySentAttachments`, `NotchHeyClickyTopFade`, `NotchHeyClickyTracksDistanceFromBottom`, `NotchTextComposerContext`, `NotchTextInputCloseButton`, `NotchTextInputFocusBridge`, `NotchTextInputFocusProbeView`, `NotchTextInputIconButtonStyle`, `NotchTextInputSurface`, `NotchTextInputSurfaceWidthPreferenceKey`, `NotchTextResponseGalleryStrip`, `NotchTextResponsePresentationPolicy`, `NotchTextResponseSurface`, `NotchTutorialComposerCloseButton`, `OpenAIAPI`, `PlaceCardGlobalFrameKey`, `PlaceCardView`, `PlaceDetailOverlayManager`, `PlaceDetailPanel`, `PlaceDetailPhotoCarousel`, `PlaceDetailView`, `PlaceDetailViewModel`, `PlacePhotoRedirectPolicy`, `PlacePhotoRequestBody`, `PlaceSearchAPI`, `PlaceSearchRequestBody`, `PlaceSearchResponseBody`, `PlaceSearchResult`, `PlaceWidget`, `ResponseCardContentHeightKey`, `ResponseCardGalleryShimmerStrip`, `ResponseCardGalleryStrip`, `ResponseCardGalleryThumbnail`, `ResponseCardOverlayManager`, `ResponseCardPanel`, `ResponseCardStatus`, `ResponseCardView`, `ResponseCardViewModel`, `SinglePlaceWidget`, `StockQuoteAPI`, `StockQuoteRange`, `StockQuoteRequestBody`, `StockQuoteResult`, `StockWidget`, `TransparentPlaceDetailHostingView`, `TransparentResponseCardHostingView`

### handoff (29)

`ClickyHandoffChip`, `ClickyHandoffGlyph`, `ClickyHandoffGlyphView`, `HandoffCommentSource`, `HandoffDelivery`, `HandoffDeliveryError`, `HandoffDeliveryResult`, `HandoffDeliveryStrategy`, `HandoffDeliveryTarget`, `HandoffIndicatorChipView`, `HandoffIndicatorChipViewModel`, `HandoffIndicatorPanel`, `HandoffIndicatorWindowManager`, `HandoffManager`, `HandoffPayload`, `HandoffPayloadImage`, `HandoffPostDragAction`, `HandoffPostDragActionBarView`, `HandoffPostDragActionButton`, `HandoffPostDragActionButtonStyle`, `HandoffQueuedRegionScreenshot`, `HandoffRegionSelectCanvasView`, `HandoffRegionSelectDimLayers`, `HandoffRegionSelectOverlayManager`, `HandoffRegionSelectPanel`, `HandoffVoiceStopPanel`, `HandoffVoiceStopPillView`, `HandoffVoiceStopPillViewModel`, `HandoffVoiceStopWindowManager`

### screen-context (21)

`ActiveDocumentContext`, `ActiveDocumentReader`, `ActiveDocumentReference`, `ActiveWorkSurface`, `AppInfo`, `ClickyCaptureUIState`, `ClickyCaptureUIWindowDescription`, `ClickyInputProvenance`, `ClickyMissionControlMonitor`, `ClickyMissionControlState`, `ClickySystemEnvironment`, `ClickySystemWindowPickerMonitor`, `ClickySystemWindowPickerYield`, `ClickyUsersFrontApp`, `CompanionScreenCapture`, `CompanionScreenCaptureUtility`, `DocumentAccessNotice`, `FrontmostApplicationResolver`, `ScreenFrameLog`, `ScreenGeometryCandidate`, `SystemInfo`

### onboarding-permissions (103)

`ClickyDiscoveryChannelPreferences`, `ClickyIntroMark`, `ClosureBackedPermissionDriver`, `DiscoveryChannel`, `DiscoveryChannelChip`, `DiscoveryChannelIcon`, `DocumentImageAnimation`, `DrawnOnboardingFinalePrefetch`, `DrawnOnboardingNotchShowcase`, `DrawnOnboardingTour`, `InterviewBubblePagination`, `InterviewThoughtBubbles`, `IntroChipFlowLayout`, `IntroHatchFlightOverlay`, `IntroHatchFlightPanel`, `IntroHatchFlightView`, `IntroNotchHoverDemo`, `IntroPressFeedbackButtonStyle`, `IntroSkillPingDirection`, `IntroSkillPingSurface`, `IntroSkillPingWiggleValues`, `IntroTextChip`, `IntroVideoPlaybackAttempt`, `KeyCapChipRow`, `NotchOnboardingCardSurface`, `NotchTutorialInviteSurface`, `NotchUseCaseCarousel`, `NotchUseCaseCarouselRowWidthKey`, `NotchUseCaseMarqueeLayerView`, `NotchUseCaseMarqueeView`, `NotchUseCasePill`, `OnboardingChoiceCardLayout`, `OnboardingDemoClickyIdentity`, `OnboardingInterviewPage`, `OnboardingInterviewStage`, `OnboardingInterviewTranscriptLine`, `OnboardingIntroFlightAnchor`, `OnboardingIntroFlightAnchorReader`, `OnboardingIntroLayout`, `OnboardingIntroStageLayout`, `OnboardingNewAgentsUIDemo`, `OnboardingRevealLineBook`, `OnboardingStarterPlanClient`, `OnboardingStarterPlanResponse`, `OnboardingTutorialPanel`, `OnboardingTutorialPhase`, `OnboardingTutorialStep`, `OnboardingTutorialSystemVolume`, `OnboardingTutorialView`, `OnboardingTutorialWindowManager`, `OnboardingVideoDemoCue`, `OnboardingVideoPlayerView`, `PermissionCoachAnchorKind`, `PermissionCoachMotionStyle`, `PermissionCoachPresentationState`, `PermissionCopyProvider`, `PermissionDriver`, `PermissionFlowCoordinator`, `PermissionFlowEntryContext`, `PermissionFlowViewState`, `PermissionGuideAnchorResolver`, `PermissionGuideAssistant`, `PermissionGuideDragSourceOverlay`, `PermissionGuideDragSourceView`, `PermissionGuidePanel`, `PermissionGuideStripView`, `PermissionGuideStyle`, `PermissionGuideViewModel`, `PermissionKind`, `PermissionPanelCardState`, `PermissionPanelChipState`, `PermissionPanelViewState`, `PermissionRequestPresentationDestination`, `PermissionRequestTransition`, `PermissionSnapshot`, `PermissionStates`, `PermissionStatus`, `PermissionStepState`, `PreSignInIntroModalStep`, `PreSignInIntroModalView`, `PreSignInIntroPanel`, `PreSignInIntroPanelDelegate`, `PreSignInIntroSizeKey`, `PreSignInIntroVoicePickerShowcase`, `PreSignInIntroVoicePickerVariant`, `PreSignInIntroWindowManager`, `PremiumPermissionGuideAssistant`, `ScreenRecordingGuideBoundary`, `ScreenRecordingGuideBoundaryTracker`, `ScreenRecordingGuideGeometry`, `ScreenRecordingGuideProber`, `SettingsWindowCandidate`, `SettingsWindowSnapshot`, `ShakeKeyframeValues`, `SystemSettingsWindowLocator`, `TutorialInviteStartButton`, `TutorialKeyCap`, `TutorialLoopingVideoPlayerView`, `TutorialLoopingVideoView`, `TutorialModifierKeyState`, `TutorialSpeechBubbleShape`, `TutorialSpokenLineBubble`, `TutorialStaggeredReveal`

### hotkeys-input (11)

`ClickyHotkeyConfiguration`, `ClickyHotkeyModifier`, `ClickyHotkeyRecorder`, `ClickyModifierFlagsChangeMonitor`, `ClickyShortcutSlot`, `ClickyShortcutTriggerKind`, `GlobalPushToTalkShortcutMonitor`, `ModifierDoubleTapDetector`, `ModifierTapActivitySnapshot`, `RecordingStartSource`, `SingleUsePressLatch`

### notch-shell (63)

`ClickyNotchAppsPill`, `ClickyNotchAttachedShape`, `ClickyNotchTab`, `ClickyNotchTabs`, `ClickyNotchUpdate`, `ClickyNotchUpdateLayout`, `ClickyNotchUpdatePreview`, `ClickyNotchUpdateSurface`, `ClickyNotchUpdates`, `ClickyNotchUsagePill`, `NotchActivityIndicatorKind`, `NotchActivityIndicatorLayerView`, `NotchActivityIndicatorView`, `NotchActivityLabelMetrics`, `NotchActivityPhase`, `NotchActivitySurface`, `NotchAnimation`, `NotchAppUpdatedSurface`, `NotchAutoDismissClockButton`, `NotchChromePressButtonStyle`, `NotchCornerGlowAppearance`, `NotchCornerGlowEdges`, `NotchCornerGlowLayerView`, `NotchCornerGlowRenderServerView`, `NotchCornerGlowTiming`, `NotchCountdownRingLayerView`, `NotchCountdownRingView`, `NotchDwellRingLayerView`, `NotchDwellRingLayers`, `NotchExpandToWindowButton`, `NotchGelActionButtonBody`, `NotchGelActionButtonStyle`, `NotchHandoffSurface`, `NotchHostingView`, `NotchHoverGeometry`, `NotchHoverTickScheduler`, `NotchKeyboardFocusReleasePanel`, `NotchLibraryModeSwitch`, `NotchLiveEvent`, `NotchLiveEventCornerGlow`, `NotchMenuBarCoverageProbe`, `NotchPanel`, `NotchPanelContentView`, `NotchPanelViewState`, `NotchPillShape`, `NotchPreferencesKey`, `NotchPresentation`, `NotchPresenter`, `NotchRestingMarkSurface`, `NotchRootView`, `NotchScreenGeometry`, `NotchScreenInstance`, `NotchSettingsTab`, `NotchSignedOutPlaceholder`, `NotchSilhouetteBorderShape`, `NotchSilhouetteShape`, `NotchSystemOverlayCoordinator`, `NotchSystemOverlayInteraction`, `NotchSystemOverlayPolicy`, `NotchSystemOverlayWindow`, `NotchVisibleSurfaces`, `NotchVoicePill`, `NotchWindowManager`

### updates (8)

`AppUpdatedNotice`, `AppUpdatedPrimaryButton`, `IdleUpdateInstallConditions`, `IdleUpdateInstallDecision`, `IdleUpdateInstallPolicy`, `IdleUpdateInstallWaitReason`, `ManualUpdateCheckState`, `SparkleUpdateDelegate`

### telemetry-diagnostics (9)

`ClickyAITracing`, `ClickyAnalytics`, `ClickyBuildInfo`, `ClickyDiagnosticsDocument`, `ClickyDiagnosticsLogCapture`, `ClickyDiagnosticsReport`, `ClickyErrorReporter`, `ClickyFeedbackEmail`, `FallbackLogLine`

### memory-profile (1)

`UserMemoryProfileResponse`

### ui-kit (98)

`AVPlayerNSView`, `AnyCodable`, `ButtonPanel`, `ClickyAppIcon`, `ClickyCSSText`, `ClickyDataSource`, `ClickyExternalOpener`, `ClickyGelButton`, `ClickyGelButtonAppearance`, `ClickyGelButtonStyle`, `ClickyGelCheckmark`, `ClickyGelSelection`, `ClickyGelSlider`, `ClickyGelSurface`, `ClickyGelSwitch`, `ClickyGelSwitchStyle`, `ClickyLinkName`, `ClickyPanelBackground`, `ClickyPanelStylePreference`, `ClickyPaperBoardDots`, `ClickyPaperFonts`, `ClickyPaperGel`, `ClickyPaperGelButton`, `ClickyPaperGelPlate`, `ClickyPaperGlyph`, `ClickyPaperGlyphView`, `ClickyPaperGrain`, `ClickyPaperInk`, `ClickyPaperPressStyle`, `ClickyPaperProgressBar`, `ClickyPaperRandom`, `ClickyPaperStamp`, `ClickyPaperStatusTag`, `ClickyPaperSticker`, `ClickyPaperStickerKind`, `ClickyPaperStock`, `ClickyPaperStripes`, `ClickyPaperTextures`, `ClickySettingsHoverModifier`, `ClickySettingsHoverRole`, `ClickySketchBar`, `ClickySketchButton`, `ClickySketchButtonKind`, `ClickySketchCard`, `ClickySketchCardContentLayout`, `ClickySketchCardMetrics`, `ClickySketchCheck`, `ClickySketchIconTile`, `ClickySketchInk`, `ClickySketchLabel`, `ClickySketchLink`, `ClickySketchMeter`, `ClickySketchPath`, `ClickySketchPressStyle`, `ClickySketchRandom`, `ClickySketchRect`, `ClickySketchSegmented`, `ClickySketchShapeView`, `ClickySketchSlider`, `ClickySketchSwatch`, `ClickySketchTip`, `ClickySketchToggle`, `ClickySketchToggleRow`, `ClickySketchTone`, `ClickyVerifiedBadge`, `ClickyVisualEffectBackground`, `ClickyWobblyRect`, `CoreAnimationOrbitHostView`, `CoreAnimationOrbitLoop`, `CoreAnimationOrbitPath`, `CoreAnimationPingPongHostView`, `CoreAnimationPingPongLoop`, `CoreAnimationPingPongTrack`, `CoreAnimationShimmerSweep`, `CoreAnimationShimmerSweepView`, `CoreAnimationVoiceWaveform`, `CoreAnimationVoiceWaveformView`, `DS`, `DSDestructiveButtonStyle`, `DSIconButtonStyle`, `DSOutlinedButtonStyle`, `DSPrimaryButtonStyle`, `DSSecondaryButtonStyle`, `DSTertiaryButtonStyle`, `DSTextButtonStyle`, `FirstClickHostingView`, `FlexWrapHStackLayout`, `FlowLayout`, `NativeTooltipView`, `NonHitTestingVisualEffectView`, `PillPhaseBarsView`, `PillPhaseDotsView`, `ResourceBundleClass`, `Scheduler`, `ShimmerTile`, `SizePreferenceKey`, `SwiftUITimingCurve`, `UncheckedSendableBox`

### app-shell (16)

`AppBundleConfiguration`, `AppRemoteConfig`, `AppRemoteConfigLinks`, `AppRemoteConfigManager`, `AppRemoteConfigResponse`, `AppStateSection`, `ClickyAnnouncementPreferences`, `ClickyHelpMenuItems`, `ClickyInstallLocation`, `CompanionAppDelegate`, `CompanionManager`, `CompanionVoiceState`, `InstallLocationSection`, `RuntimeConfig`, `WindowPositionManager`, `leanring_buddyApp`

