# OpenClicky parity inventory

This is the subsystem-by-subsystem inventory for the OpenClicky clean-room rebuild of HeyClicky. It turns the nine reverse-engineering reader docs in [`docs/re/`](re/) into one list of everything OpenClicky has to build, which model slot each part needs, what HeyClicky's server did that we must replace, and the order to build it in.

- **Evidence version.** HeyClicky 1.1.2, build 69, bundle id `com.humansongs.clicky`, git branch `changelog/v1.1.2`, commit `9bd03d487` (from `Contents/Resources/ClickyBuildInfo.plist`). Frozen snapshot: `~/Developer/openclicky-evidence/HeyClicky-1.1.2-b69.app`. Some user-data files (for example `CodexHome/config.toml`) were last written by 1.1.1 build 66; the reader docs say so where it matters.
- **Reader docs.** [01 type map](re/01-type-map.md), [02 voice pipeline](re/02-voice-pipeline.md), [03 screen and pointing](re/03-screen-pointing.md), [04 2D drawing](re/04-draw-2d.md), [05 3D figures](re/05-draw-3d.md), [06 agent harness](re/06-agent-harness.md), [07 browser bridge](re/07-browser-bridge.md), [08 apps, memory and UI](re/08-apps-memory-ui.md), [09 server API](re/09-server-api.md).
- **Clean-room rule.** OpenClicky rebuilds observed *behaviour, architecture, interfaces and data shapes*. It contains no HeyClicky code, prompts, JavaScript bodies, shader source, sounds, videos, voice previews, fonts from HeyClicky's bundle, art or icons. Identifiers (type, route, key and enum names) are quoted only as evidence. Prompts that HeyClicky keeps on its server are unknown and are written from scratch by OpenClicky. Third-party code HeyClicky vendors under open licences (three.js MIT, Barlow and Patrick Hand OFL) may be taken from upstream, never from HeyClicky's bundle.

**Evidence legend** (used by every reader doc):

| Label | Meaning |
|---|---|
| OBSERVED | Seen directly in an artifact (binary string or reflection metadata, bundled JS, Info.plist, the user's data dir). The reader doc cites path and identifier. |
| INFERRED | Reasoning from names, neighbouring strings or field layouts. |
| UNKNOWN | Not recoverable from the client: server prompts, model routing, pricing, values held in stripped Swift. |

**Corrections to the original task brief** (all OBSERVED in the readers):

- There is **no Deepgram** in build 69. Streaming STT is Gemini Live with a server-minted token, with a server batch fallback and Apple Speech as the legacy path ([02 correction](re/02-voice-pipeline.md#correction-to-the-brief), [09 §1](re/09-server-api.md#1-hosts-and-base-urls)).
- `Resources/CodexRuntime/` is **absent** from 1.1.2. Background jobs run on the bundled `Helpers/clicky-harness` (Bun 1.4.1, "H1", built on pi-coding-agent 0.87.1) with `gpt-6-luna` on the Mac ([06 §4](re/06-agent-harness.md#4-choosing-a-runtime)).
- The brain default shown in Developer settings is Sol at medium effort on the Ultrafast tier (`gpt-6.1-sol-ultrafast-medium`); the user's logs report the base model `gpt-6.1-sol` ([02 §1](re/02-voice-pipeline.md#1-architecture-overview)).
- `/agent/realtime/turn` reports usage; it does not carry drawing programs. Drawing programs stream back from `/brain/turn` ([09 §4.3](re/09-server-api.md#43-speech-output-mouth-and-full-voice-realtime)).

**Status values:** `working` means the row's main behavior has recorded end-to-end evidence; `partial` means code exists but behavior or validation is incomplete; `missing` means little or no implementation exists; `wont-build` records a scope exclusion. Statuses were reconciled with main at `f1dd898` on 2 November 2026 after #58 and match [parity-status.md](parity-status.md). That document records evidence, missing behavior and the [remaining-work queue](parity-status.md#next-wave). A source check or fixture test does not establish hardware or live-account behavior.

---

## 1. Parity table

Columns:

- **classification** describes HeyClicky: `built-in` (all client-side), `server-mediated` (core logic or model behind api.heyclicky.com), `mixed`, `out-of-scope` (commercial plumbing OpenClicky will not copy).
- **slot** is the OpenClicky typed model slot the subsystem uses (`stt`, `voice`, `brain`, `agent`, `other:<name>`, `none`). See [§2](#2-typed-model-slots).
- **evidence** links the reader doc section. Rows whose only evidence is the type map are marked **not yet investigated**: no reader covered them in depth, so they need an investigation pass before they are built.

| id | subsystem | classification | slot | status | evidence | unrecoverable parts |
|---|---|---|---|---|---|---|
| `shell-app` | App shell and process model: menu-bar/notch agent app (`LSUIElement`), launch at login, feature services in place of the `CompanionManager` god object (475 stored properties, 24 extension files), local config in place of `/app-config` | mixed | none | partial | [01 §1](re/01-type-map.md#1-bundle-anatomy); [01 §8.1](re/01-type-map.md#81-app-shell-app-shell-and-orchestration); [01 §13](re/01-type-map.md#13-rebuild-plan-openclicky-module-layout) | `/app-config` contents beyond the link keys |
| `shell-http` | Provider HTTP resilience replacing the original backend conventions: retries/backoff, Retry-After, provider error diagnosis and SSE parsing; Worker-specific device/trace headers, auth refresh and paywall envelopes are dropped | server-mediated | none | working | [09 §3](re/09-server-api.md#3-common-conventions) | Hash behind `X-Clicky-Device`; whether device headers ride on every call |
| `shell-permissions` | Permissions and coaching: mic, Accessibility, Screen Recording, ScreenCaptureKit picker, Automation probes, folder access, restart-required flow, a guide that points at the right System Settings toggle | built-in | none | partial | [01 §3](re/01-type-map.md#3-entitlements-and-runtime-permissions); [08 §6.1](re/08-apps-memory-ui.md#61-overall-sequence-observed-enums-order-inferred); [01 §8.24](re/01-type-map.md#824-onboarding-permissions-onboarding-tutorial-and-permissions) (guide overlay **not yet investigated**) | Coach overlay internals (`PermissionGuideAssistant`, `SystemSettingsWindowLocator`) |
| `shell-hotkeys` | Talk keys: four configurable slots (`voiceHold`, `textTrigger`, `dictationHold`, `handsFreeDictation`) as hold-combo or double-tap modifier, triple-tap for always-on, CGEvent taps, Escape interrupt on its own thread | built-in | none | partial | [02 §2](re/02-voice-pipeline.md#2-talk-keys-global-shortcuts) | Default `dictationHold` mask; double/triple-tap time windows |
| `shell-notch` | Notch panel per display, presenter state machine (`liveEvent`, `idle`, `onboardingPinned`, `textInput`, `textResponse`), tabs, activity pill, ~30 live-event kinds, hover-dwell expand, fullscreen and system-UI avoidance; floating chrome (drawing buttons, edge shelf, hand-off bar, stop pill) | built-in | none | partial | [03 §8](re/03-screen-pointing.md#8-notch-ui-and-floating-buttons); [08 §7.2](re/08-apps-memory-ui.md#72-notch-primary-surface) | `NotchPanel` window level; animation constants |
| `shell-home` | Home space and HeyClicky window: Clickys, jobs, drawings, suggestions, conversation sidebar (working, recents, earlier), transcripts, artifact previews, agent dashboard | mixed | none | partial | [08 §7.3](re/08-apps-memory-ui.md#73-home-homespace); [08 §7.4](re/08-apps-memory-ui.md#74-chat-and-agent-windows); [01 §8.18](re/01-type-map.md#818-home-window-home-space-and-heyclicky-window) | — |
| `shell-settings` | Settings sections and pickers: brain model, agent harness/place/model, voice, mic, shortcuts, cursor, dictation, integrations, developer toggles. In OpenClicky this is also where provider slots are configured | built-in | none (configures every slot) | partial | [08 §7.6](re/08-apps-memory-ui.md#76-settings-and-model-pickers); [08 §7.7](re/08-apps-memory-ui.md#77-developer-section-and-model-picker) | Server model policy (`/runtime/model-policy`) values |
| `shell-auth` | Sign-in and account: Google via Supabase, `clicky://` and `heyclicky://` callbacks with state and expiry guard, Keychain tokens, account deletion. OpenClicky has no account: per-slot credentials replace it | server-mediated | none | partial | [08 §2.1](re/08-apps-memory-ui.md#21-supabase-auth-observed); [09 §2](re/09-server-api.md#2-authentication) | Worker-side OAuth redirect chain |
| `shell-remote-config` | Remote link config, device registration, discovery-channel survey | server-mediated | none | wont-build | [08 §2.2](re/08-apps-memory-ui.md#22-device-registration-and-discovery-channel-observed); [08 §12](re/08-apps-memory-ui.md#12-remote-config) | — (dropped) |
| `shell-updates` | Auto-update: Sparkle 2 hourly checks, EdDSA, idle-time install that waits for voice, agent and drawing activity to stop, "app updated" notice | built-in | none | missing | [08 §11](re/08-apps-memory-ui.md#11-auto-update-sparkle); [01 §8.30](re/01-type-map.md#830-updates) | `IdleUpdateInstallPolicy` details (**not yet investigated**) |
| `shell-telemetry` | Local diagnostics bundle and Report a Bug, with secret scrubbing. Original hosted PostHog/Sentry/report-error services are dropped | out-of-scope | none | working | [08 §9](re/08-apps-memory-ui.md#9-analytics-posthog); [08 §10](re/08-apps-memory-ui.md#10-crash-reporting-and-diagnostics); [09 §4.14](re/09-server-api.md#414-third-party-sdk-traffic-not-heyclicky-api) | Whether `$ai_generation` events carry prompt text |
| `shell-billing` | Plans (Pro, Max), per-surface quotas, checkout and portal, paywall HUDs, extra-usage approval | out-of-scope | none | wont-build | [08 §8](re/08-apps-memory-ui.md#8-plans-usage-metering-brief-billing-and-referrals-out-of-scope); [01 §8.28](re/01-type-map.md#828-billing-plans-paywall-and-usage) | Pricing and quota rules |
| `shell-referral` | Referral codes, earnings estimator, payouts | out-of-scope | none | wont-build | [01 §8.29](re/01-type-map.md#829-referral-referral-programme); [09 §4.13](re/09-server-api.md#413-billing-and-referrals-out-of-scope-for-openclicky) | — |
| `shell-usage` | Usage metering: per-turn agent leases, launch records, early-stop refunds. OpenClicky replaces it with a local usage ledger (tokens and cost per turn from provider responses) | server-mediated | other:metering | working | [06 §11](re/06-agent-harness.md#11-usage-leases-paywall); [09 §7](re/09-server-api.md#7-disposition-summary) | Credit and pricing rules; exact lease-create route |
| `shell-audio-feedback` | UI chimes through a pre-warmed output engine (longer lead-in on Bluetooth, mic-start cue waits for the mic), drawing sound beds and accents, temporary unmute or volume raise when the Mac is muted | built-in | none | partial | [02 §12](re/02-voice-pipeline.md#12-sounds-at-each-stage-o); [04 §11.6](re/04-draw-2d.md#116-sound-recipes-soundof-the-player-is-another-subsystem); [01 §8.32](re/01-type-map.md#832-audio-feedback) | Which chime marks listen start; warm-up lead-in values. Sound files must be original |
| `shell-url-router` | URL-scheme router: one handler for `heyclicky://` and the legacy `clicky://` alias (sign-in return, connected-app OAuth return, checkout return, the browser host's "open browser settings" action, referral links), plus the in-app `clicky:` link scheme used in agent Markdown and cards (for example `clicky:job-slot:`). OpenClicky registers its own scheme and keeps only the connector-return, settings and in-app link routes | built-in | none | working | [08 §2.3](re/08-apps-memory-ui.md#23-url-schemes-observed); [01 §2.1](re/01-type-map.md#21-url-schemes); MAIN strings `Received URL event`, `integrations-auth-callback`, `checkout-complete`; `Helpers/ClickyBrowserHost` string `heyclicky://settings/browser`. Added by the completeness review (§6) | Full list of `clicky:` link verbs used inside notes and cards |
| `shell-announcements` | One-time feature-introduction panels: the dictation introduction panel for existing users (language and shortcut sections), seen and existing-user bookkeeping, and the post-update "app updated" notice | built-in | none | missing | [01 §8.21](re/01-type-map.md#821-dictation-system-wide-dictation) (`DictationAnnouncementWindow.swift`); [01 §8.30](re/01-type-map.md#830-updates) (`AppUpdatedNotice`); MAIN keys `clicky.dictationAnnouncement.{seen,existingUser,trackingInitialized}.v1`, type `ClickyAnnouncementPreferences` (**not yet investigated**; §6) | Which users count as "existing"; whether other announcements reuse the panel |
| `shell-feature-flags` | Local feature-flag and preference registry. About 40 `Clicky*` defaults keys have no reader coverage, among them `ClickyLibraryModeEnabled` (with `NotchLibraryModeSwitch`), `ClickyStreamMode` (`clickyNotchStreamModeChanged`), `ClickyMorningPaperEnabled`, `ClickyTransparentPanesEnabled`, `ClickyUseLegacyMenuBarPanel`, `ClickyJavaScriptJIT`, `ClickyLiveNotesEnabled`, `ClickyLiveNotesStreamPatches`, `ClickyScreenDrawing{Sounds,PenSounds,Subtitles,VoiceCaptions,SavesLessons,KeepsDrawingsInChat}`, `ClickyShowAgentLabelsInActivityStrip`, `ClickySkillPinnedNotchStateEnabled`, `ClickyUpcomingMeetingsEnabled`, `ClickyProactiveAgentSuggestionsEnabled`, `ClickyPreferHostedIntroVideos` and `ClickyForceHosted*Failure` debug toggles. OpenClicky keeps one typed registry with defaults, shows it in Developer settings and includes it in the diagnostics snapshot | built-in | none | working | MAIN strings dump (keys listed next to `HeyClicky/NotchPresenter.swift` and in the diagnostics settings block); [08 §7.7](re/08-apps-memory-ui.md#77-developer-section-and-model-picker) covers only the developer toggles it names (**not yet investigated**; §6) | What Library mode and Stream mode do; each flag's default |
| `ui-kit` | Design system: `DS` tokens and button styles, hand-drawn sketch kit, gel controls, paper glyphs, Core Animation loop hosts | built-in | none | missing | [01 §8.33](re/01-type-map.md#833-ui-kit-design-system) (**not yet investigated**) | Everything beyond type and file names |
| `ui-character` | Companion characters: cloud portraits with expressions, interactive portrait, portrait packs (hair, outfits, skin tones), sprite actor states, cat mode | built-in | none | missing | [01 §8.25](re/01-type-map.md#825-character-persona-characters-and-portraits) (**not yet investigated**) | Art assets (must be original) and animation details |
| `voice-mic` | Mic capture: AVCaptureSession path with silent-window rebuild, echo-cancelled duplex AVAudioEngine adopted by probe and verdict cache per device topology, Bluetooth capture held open after a press, failover to the built-in mic, dead-air counting, PCM16 conversion | built-in | none | partial | [02 §3](re/02-voice-pipeline.md#3-microphone-capture) | Bluetooth hold duration; rebuild ladder length; capture sample rates |
| `voice-ears` | Ears: push-to-talk streaming STT over Gemini Live with a server-minted token and server-supplied `setup`, manual `activityStart`/`activityEnd`, interim text into the notch, warm pre-connected socket, early-audio buffer, batch WAV fallback, 10-minute fallback after a billing refusal | server-mediated | stt | working | [02 §4](re/02-voice-pipeline.md#4-ears-streaming-speech-to-text); [09 §4.2](re/09-server-api.md#42-speech-to-text-ears-and-dictation) | Gemini model id and `setup` contents; sample rate; ready/final timeouts; warm-socket expiry; batch STT provider |
| `voice-apple-speech` | Apple Speech on-device transcription (older push-to-talk and composer-mic path) | built-in | stt | working | [02 §4.5](re/02-voice-pipeline.md#45-legacy-apple-speech-path-o) | Which 1.1.2 surfaces still route to it |
| `voice-orchestrator` | Turn state machine: idle → listening → transcribing → capturing → requesting (rounds) → speaking/drawing; key-down prewarm, mouth open and document read; barge-in, Escape, cut-off note, auto-advance after a user step; typed turns through the same brain | built-in | none | working | [02 §5.3](re/02-voice-pipeline.md#53-turn-state-machine-client-o-logs-i-structure); [02 §8](re/02-voice-pipeline.md#8-barge-in-interrupt-and-cut-off) | Exact rule for when hold-to-talk uses full voice instead of one brain |
| `voice-brain-turn` | One-brain turn: request builder (thread, turn context, screenshot, capability flags, `brain_model`), gzip, SSE parser (`meta`, `text`, `status`, `items`, `search_record`, `tool_call(s)`, `computer_calls`, `done`, `error`), incremental `say()` line extraction, tool-result rounds up to `max_rounds` | server-mediated | brain | working | [02 §5.4](re/02-voice-pipeline.md#54-post-brainturn-request-o-keys-from-xl-nesting-i); [02 §5.5](re/02-voice-pipeline.md#55-brainturn-response-sse-stream-o); [09 §4.1](re/09-server-api.md#41-one-brain-voice-turn-the-default-hold-to-talk-brain) | Server system prompt, tool schemas, `user_layer` and its signature, `turn_token` meaning, exact field nesting |
| `voice-brain-session` | Brain session lifecycle and thread store: prompt-cache prewarm at key-down, compaction into a sectioned note with keep/drop indices, session-end hand-off for notes and memory, per-account thread JSON plus a round JSONL log, screenshot pruning, fresh session on account switch | mixed | brain (+other:summarizer, other:memory-writer) | working | [02 §5.2](re/02-voice-pipeline.md#52-persistence-o-data); [02 §5.6](re/02-voice-pipeline.md#56-prewarm-compaction-and-session-end-o); [08 §5.2](re/08-apps-memory-ui.md#52-onebrain-thread-store-dataonebrainaccountuuid) | Compaction and prewarm thresholds; idle session-end timeout; summarizer and memory prompts |
| `voice-brain-tools` | Client-executed brain tools: concurrent calls with outputs in start order, sync reads that trigger another round, actions held until narration is spoken, synthetic outputs for calls that never ran | mixed | brain | working | [02 §6.1](re/02-voice-pipeline.md#61-one-brain-client-tool-runner-onebraintoolrunner-onebraintoolcallpolicy-o) | Server tool JSON schemas; full server-side tool list |
| `voice-mouth` | Mouth: each `say()` line spoken by a separate session (OpenAI realtime mini, out-of-band audio-only response, verbatim) or by Gemini TTS per line; health checks (silent first line, drop between lines), idle teardown, 10-minute fallback to the other provider, usage report | server-mediated | voice | partial | [02 §7](re/02-voice-pipeline.md#7-mouth-the-speaking-session); [09 §4.3](re/09-server-api.md#43-speech-output-mouth-and-full-voice-realtime) | Server-minted session config; `/agent/realtime/speak` framing and audio format; idle teardown seconds |
| `voice-full-realtime` | Full voice: realtime speech-to-speech for always-on (server VAD, headphones required, echo gates), the onboarding interview and follow-ups; screenshots as image items (latest kept); tool dispatcher with per-turn cap and superseded results; cancel, clear and truncate on interrupt | server-mediated | voice | partial | [02 §6.2](re/02-voice-pipeline.md#62-full-voice-tool-dispatcher-realtimetooldispatcher-o); [02 §9](re/02-voice-pipeline.md#9-full-voice-push-to-talk-flow-for-completeness-o) | Server instructions and tool definitions; VAD values actually used |
| `voice-higher-model` | Higher-model delegation from full voice (`send_to_higher_model`): screenshots, history and context in; text, widgets, pointing, typing, clipboard text and agent hand-off out | server-mediated | brain | partial | [02 §6.3](re/02-voice-pipeline.md#63-send_to_higher_model--post-chat-tool-call-full-voice-only-o); [09 §4.4](re/09-server-api.md#44-realtime-tool-backends-full-voice-tool-calls-forwarded-to-the-worker) | Prompt, model, widget payload shapes |
| `voice-playback` | Speech playback: player node with time-pitch speed, scheduled and played frame counts for truncation and captions, finish only after drain, engine restart on route change, muted or zero-volume output suppressed and copied to the clipboard with fix-it actions | built-in | none | working | [02 §8](re/02-voice-pipeline.md#8-barge-in-interrupt-and-cut-off) | — |
| `voice-captions-ui` | Live user transcript while keys are held, notch voice pill and cursor waveform from mic power, spoken-line captions synced to playback, walkthrough beats released by playback fraction | built-in | none | partial | [02 §13](re/02-voice-pipeline.md#13-live-captions-and-voice-ui-o) | Caption timing algorithm |
| `voice-picker` | Voice catalog (10 OpenAI voices, default `cedar`; 30 `gemini:` voices), speeds 0.5x to 1.5x, spoken languages with region hints, localized preview clips cached on disk, session marked stale on change | mixed | voice | partial | [02 §11](re/02-voice-pipeline.md#11-voice-picker-speed-languages-and-previews-o) | Some voice subtitles; purpose of the persona preview set. Preview audio must be generated by OpenClicky |
| `voice-latency` | Per-press ears timings, per-turn marks and timing event, optional stats HUD hidden from screenshots | built-in | none | partial | [02 §5.7](re/02-voice-pipeline.md#57-turn-latency-instrumentation-o) | — |
| `voice-job-reports` | Report turns: finished background jobs batched into a brain turn that shows result cards and speaks short lines; one retry | mixed | brain | working | [02 §14](re/02-voice-pipeline.md#14-report-turns-background-job-results-spoken-by-the-brain-o) | Server behaviour for report turns |
| `voice-provider-diagnosis` | When voice cannot open, probe the provider and explain region or network blocks | built-in | none | working | [02 §15](re/02-voice-pipeline.md#15-provider-availability-diagnosis-o) | — |
| `voice-dictation` | System-wide dictation: AX focus context capture (app, site, before/selected/after text, secure flag), streaming STT with batch fallback, LLM cleanup with field context and vocabulary, insertion by AX, paste, blind paste or clipboard, Secure Event Input refusal, correction learning, daily JSONL archive | mixed | stt (+other:text-cleanup) | partial | [02 §10](re/02-voice-pipeline.md#10-dictation-talk-to-type-o); [08 §5.5](re/08-apps-memory-ui.md#55-dictation-transcripts-datadictationtranscriptsyyyy-mm-ddjsonl); [01 §8.21](re/01-type-map.md#821-dictation-system-wide-dictation) | Cleanup model and prompt; meaning of `fast_cleanup`; per-app insertion strategy table |
| `voice-text-chat` | Typed chat: text trigger opens the notch composer; typed turns use the one brain and can answer as text; response cards near the cursor with an image strip | mixed | brain | partial | [02 §5.3](re/02-voice-pipeline.md#53-turn-state-machine-client-o-logs-i-structure); [01 §8.7](re/01-type-map.md#87-text-chat-widgets-typed-chat-and-answer-cards) (composer and cards **not yet investigated**) | Composer and response-card UI behaviour |
| `voice-legacy-chat` | Classic companion chat over `/chat` (Anthropic SSE) and `/v2/chat` (OpenRouter SSE) with prompt profiles and `clicky_widget`/`clicky_tool_start` events; still used for the onboarding draw demo | server-mediated | brain | partial | [09 §4.5](re/09-server-api.md#45-legacy-streaming-chat-text-companion-onboarding-demo); [03 §6.1](re/03-screen-pointing.md#61-tag-grammar-classic-v2chat-and-realtime-chat-tool-call-paths) | Which 1.1.2 UI still hits it; server prompt profiles |
| `screen-capture` | Multi-display screenshots with ScreenCaptureKit, own chrome excluded, long edge 1280 px, JPEG 0.8, labelled cursor screen vs secondary screens, pointer visible | built-in | none | partial | [03 §4.1](re/03-screen-pointing.md#41-full-desktop-capture-pipeline-observed-companionscreencaptureutility) | Display order the server expects for `screenN` |
| `screen-capture-variants` | Region capture (PNG), settle sampler (192 px thumbnails, under 0.5% change, 1.5 s cap, cursor hidden), realtime image adapter (768 or 640 px, JPEG 0.6, keep latest) | built-in | none | partial | [03 §4.4](re/03-screen-pointing.md#44-capture-variants) | — |
| `screen-capture-policy` | Window capture policy (three roles, sharing type from a "show in screen recordings" toggle, excluded window ids) and stepping aside for the window picker, Mission Control and the Screenshot UI with a hard timeout | built-in | none | partial | [03 §4.2](re/03-screen-pointing.md#42-keeping-heyclicky-out-of-the-picture); [03 §4.5](re/03-screen-pointing.md#45-system-ui-compatibility-edge-cases-handled) | Which role table is always capturable |
| `screen-context` | Front-app tracking, browser address-bar reading through AX, active document reader (AXDocument file via PDFKit or text, AXWebArea text with a 1.5 s deadline), folder-access notice | built-in | none | partial | [03 §5.1](re/03-screen-pointing.md#51-frontmost-app-and-browser); [03 §5.2](re/03-screen-pointing.md#52-active-document-desktop-documents-downloads-usage-strings) | Truncation length; full file-type list |
| `screen-focus-quiet` | Focus and selection context, call presence, Focus mode and quiet-context detection | built-in | none | partial | [03 §5.3](re/03-screen-pointing.md#53-focus-and-selection-context); [03 §5.5](re/03-screen-pointing.md#55-quiet-and-focus-context) | — |
| `screen-draw-to-ask` | Draw-to-ask: highlighter ink while the talk keys are held (60 Hz, dwell and fade constants), stroke-to-gesture description, AX text and controls harvested inside the region | built-in | none | working | [03 §5.4](re/03-screen-pointing.md#54-draw-to-ask-screen-annotation-as-context); OpenClicky: docs/guided.md (recorder, classifier, AX/OCR harvest, description, inked screenshot; `occtl highlight`) | — |
| `point-tags` | Inline pointing tag grammar (`POINT`, `HIGHLIGHT`, `TARGET`, `HOVER`, `SHAPE`, `TYPE`) in screenshot pixels, mapped to AppKit coordinates (clamp, scale, flip, offset) | server-mediated | brain | partial | [03 §6.1](re/03-screen-pointing.md#61-tag-grammar-classic-v2chat-and-realtime-chat-tool-call-paths); [03 §6.2](re/03-screen-pointing.md#62-coordinate-mapping-observed-math-0x10267ce98); OpenClicky: docs/guided.md (`PointingTagParser`) | Prompt that teaches the grammar; `HIGHLIGHT` number convention |
| `point-guided` | Guided click and hover walkthrough: arm a target ring (snapped to a real AX control when found), wait for click or rest, grace window, settle, re-capture, follow-up turn with goal and completed steps, quiet exit on off-target clicks | mixed | brain | working | [03 §6.4](re/03-screen-pointing.md#64-guided-walkthrough-state-machine-guidedclicktarget-and-companionmanagerannotation); [03 §6.5](re/03-screen-pointing.md#65-ax-snapping-of-targets); [03 §6.3](re/03-screen-pointing.md#63-beats-and-speech-sync-realtimewalkthroughsync); OpenClicky: docs/guided.md (`GuidedWalkthrough`, `GuidedTargetSnapper`; `occtl guided simulate`) | `guidedMaxRounds`; follow-up prompt; expiry and rest constants |
| `point-onebrain` | Drawing-program pointers and directives (`point`, `target`, `hover`, `task`, `waitForUser`, `onScreen`) read by the native host as guided targets | server-mediated | brain | partial | [03 §6.6](re/03-screen-pointing.md#66-onebrain-drawing-program-pointers); OpenClicky: docs/dsl-guided.md (`target`, `hover`, `task`, `waitForUser`; `onScreen` not yet) | How screenshots by reference are uploaded and addressed |
| `point-realtime-attach` | Realtime voice sees the screen: `capture_screen` and `send_to_higher_model` tools, image items, outcome flags so the voice does not repeat what is already shown | server-mediated | voice | partial | [03 §6.7](re/03-screen-pointing.md#67-outcome-reporting-to-the-voice-model); [03 §4.4](re/03-screen-pointing.md#44-capture-variants) | Realtime tool schemas |
| `point-grounding` | Computer-use element grounding: screenshot resized to a computer-use resolution, coordinate returned and mapped back. INFERRED dormant or fallback in 1.1.2 | server-mediated | other:grounding | missing | [03 §6.8](re/03-screen-pointing.md#68-elementlocationdetector-computer-use-grounding) | Caller, model and key source |
| `overlay-buddy` | Buddy cursor overlay: one click-through panel per screen, spring follow, Bezier flight capped at 1.4 s, label and phrase bubbles, thinking dots, mic waveform, colour presets, hide rules, shake to detach with click-to-talk, dock into the notch | built-in | none | partial | [03 §7.1](re/03-screen-pointing.md#71-window-inventory-observed-from-init-code-level-is-the-nswindowlevel-raw-value); [03 §7.2](re/03-screen-pointing.md#72-buddy-cursor-model); [03 §7.4](re/03-screen-pointing.md#74-detached-cursor-shake-and-click-to-talk) | Arc-height formula of the flight control point |
| `overlay-pen` | Pen cursor and follower for drawings (follows stroke arc length, flies between strokes, cross-screen hand-off) and the stale watch that clears drawings on window move, occlusion, scroll or app switch | built-in | none | partial | [03 §7.6](re/03-screen-pointing.md#76-pen-cursor-and-pen-follower-drawings) | — |
| `draw-runner` | Drawing program runner: statement-by-statement execution of streamed JS in a scoped API, parse-error-means-wait, top-level `const`/`let` rewrite, 2000-mark limit, seeded randomness, longest-runnable-prefix recovery | built-in | none | working | [04 §7](re/04-draw-2d.md#7-execution-model-and-sandboxing) | Any native wall-clock limit (none set in the bridge) |
| `draw-api` | Program API: primitives, math helpers, `step`/`say`/`seen`/`noted`, `graph` and `timeline` with anchors, edit calls; screen-marking pieces in the cursor ink, paper cards and photos, invisible action marks (type, copy, open, button, hand-off, sounds) | built-in | none | partial | [04 §4](re/04-draw-2d.md#4-program-api-reference) | The server-side drawing skill prompt |
| `draw-pacer` | Stream and pacer: each `say()` line owns the marks after it; strokes wait for the line start and spread over its duration within bounded pace factors; pause, resume, finish-now, drop on interrupt; causal layout check that nudges clashing labels | mixed | voice | partial | [04 §8](re/04-draw-2d.md#8-stream-layout-pacing-and-timing-eng-stream-layout-pacer) | Whether line duration comes from the server or a local estimate |
| `draw-svg-painter` | Reference SVG painter: layered output, tapered strokes revealed by masks, turbulence washes, text wrap and fit, label dodging, readable ink against the screenshot, windows that grow, tie snapping, a warnings report | built-in | none | working | [04 §9](re/04-draw-2d.md#9-the-svg-painter-eng-surfacefor) | — |
| `draw-editor` | Live editor: named parts and marks, a compact card-state text the brain reads on follow-ups (12 000 characters), edit ops with their own timings, undo, card drag/zoom/close | mixed | brain | working | [04 §10](re/04-draw-2d.md#10-live-editing-engine-16-editor) | How the prompt frames the state text and teaches edits |
| `draw-bridge` | JavaScriptCore bridge: minimal SVG DOM whose geometry questions are answered natively, host timers, `clickyCanvas` facade (`beginStream`, `feed`, `line`, `lineLength`, `finish`, `state`, `cards`, …), render ops drained after each call, button gating, sound recipes | built-in | none | partial | [04 §11](re/04-draw-2d.md#11-the-native-bridge-nat); [04 §12](re/04-draw-2d.md#12-render-record-format-__drainrender) | — |
| `draw-ca-painter` | Core Animation painter and helpers: masked stroke reveals, glows, multiply highlights, window chrome, photos, edit wrappers; Core Text shaper with bundled hand and sans fonts; SVG path geometry; CSS colours; unit Bezier; wash renderer; screen sampler for ink and busy-ness | built-in | none | working | [04 §13](re/04-draw-2d.md#13-swift-side) | Native animation keyframes; wash look; `busyFor`/`inkFor`/`lumFor` algorithms |
| `draw-metal-canvas` | Second, Metal-based canvas renderer with a settled-frame cache and reveal maps, consuming the same op vocabulary | built-in | none | missing | [04 §1](re/04-draw-2d.md#1-architecture-at-a-glance) | Which surfaces use it instead of Core Animation |
| `draw-captions` | Drawing captions: debug beat chips (waiting, drawing, done, late) and spoken-word captions, behind preferences | built-in | none | working | [04 §13.4](re/04-draw-2d.md#134-captions) | Word-timing source for live captions |
| `draw-generation` | The brain writes one streamed JS block of beats in screenshot pixel coordinates; the app feeds accumulated code to the engine and new `say()` lines to the voice | server-mediated | brain | working | [04 §3](re/04-draw-2d.md#3-the-program-the-model-writes); [04 §18](re/04-draw-2d.md#18-model-and-server-slot-mapping) | Drawing skill prompt and examples; how the server splits code from other output |
| `draw-photos` | Photos and favicons for `photo()`, image and source marks: query grammar (name, web, page preview, favicon, no-people), size-capped public-host downloads, people filter | server-mediated | other:image-search | working | [04 §13.9](re/04-draw-2d.md#139-photos-interface-only); [09 §4.6](re/09-server-api.md#46-widget-data-services); OpenClicky: docs/dsl-media.md (`photo`, `favicon`, `source`; live Brave renders) | Request schema and full path; search provider |
| `draw-lessons` | Saved drawings ("lessons"): folder with program, screenshot, poster, narration audio and `lesson.json`; inline and full-screen replay; polaroid print with a warp shader; video export to Downloads; recent drawings | built-in | none | partial | [08 §5.7](re/08-apps-memory-ui.md#57-saved-drawings-drawings-in-home); [01 §8.10](re/01-type-map.md#810-drawings-library-saved-drawings-lessons) (recorder, printer and video **not yet investigated**) | Lessons directory location; recorder, printer and video internals |
| `3d-figure-api` | `figure()` and legacy `scene3d()` authoring: plain-data marks (`stage3d`, `part3d`, `label3d`, `motion3d`, `camera3d`, `tick3d`), placement rules, canonical recipe JSON, materials, part handles and motions, labels, beat timings | built-in | none | partial | [05 §3](re/05-draw-3d.md#3-authoring-api-in-enginejs-observed-unless-noted) | The server prompt that teaches `figure()`; consumer of `readout()` values |
| `3d-kernel` | 3D geometry kernel: a separate JSContext running a three.js slice that builds recipes (box, cylinder, lathe, extrude, blob, gear, spring, …) into typed arrays plus framing samples, with a byte-budgeted cache and prewarm | built-in | none | working | [05 §4](re/05-draw-3d.md#4-the-3d-kernel) | Cache byte budget; idle-release interval |
| `3d-scene-model` | Native scene model: nodes with base, motion and tick pose layers, materials and presets, motions, orbit camera with auto-fit and refit throttles, labels beside silhouette rows | built-in | none | working | [05 §5](re/05-draw-3d.md#5-native-scene-model-observed-type-and-field-names-semantics-inferred) | Turntable speed and rest delay; drag sensitivity; grow easing |
| `3d-illustrated` | Illustrated look: two-tone toon shading with a physical fallback, part-id grids, full-screen ink outline and seams, picking from the id grid | built-in | none | working | [05 §7](re/05-draw-3d.md#7-illustrated-look-davinci3drenderer-davinci_) | Outline pen widths in pixels; pass ordering |
| `3d-studio` | Studio look: baked environment and irradiance cubes, cached shadow map, half-resolution SSAO, GGX key and rim, clearcoat, sheen, glass, hatched cuts, AgX or Neutral tone mapping, shadow-only ground | built-in | none | working | [05 §8](re/05-draw-3d.md#8-studio-look-davinci3dstudiorenderer-studio_) | Whether studio figures also get outlines; shadow and ground sizing |
| `3d-stage` | Stage host: CAMetalLayer in the drawing canvas, display-link frame pipeline, paper sheets, label words in the hand font, leaders and dots, runtime shader compile with warmup, GPU fallback and a "3D unavailable" flag fed to the brain | built-in | none | partial | [05 §6](re/05-draw-3d.md#6-the-stage-screendrawing3dstage-observed-fields); [05 §9](re/05-draw-3d.md#9-overlays-paper-and-words-screendrawing3dstageswift-shaders) | Frame-rate policy values |
| `3d-tick` | Live mechanism ticks: each frame the stage asks JS for poses (14 floats per posed part), slow or throwing ticks are stopped | built-in | none | working | [05 §3.10](re/05-draw-3d.md#310-live-run-tick-bridge-and-pose-packing) | — |
| `3d-picking` | Drag to orbit and click to ask: a non-activating handle panel; a click without travel picks a part and sends the brain a "what is this part" user turn | mixed | brain | working | [05 §3.13](re/05-draw-3d.md#313-click-to-ask); [05 §6.3](re/05-draw-3d.md#63-interaction-state-machine-inferred) | Click-turn wire format and tag; drag and click thresholds |
| `agent-runner` | Agent runner helper: spawned with a token and state dir, prints a ready line with its port (20 s timeout), bearer HTTP on 127.0.0.1 (`/turn`, `/steer`, `/cancel`, `/prewarm`, `/events` long-poll), driver registry keyed by runtime and place | built-in | none | partial | [06 §5.2](re/06-agent-harness.md#52-process-launch-and-the-runner-protocol); [06 §4](re/06-agent-harness.md#4-choosing-a-runtime) | Runner source; retry policy when the runner dies mid-turn |
| `agent-loop` | Durable agent loop: local job server with file-backed jobs, memoized workflow steps, model rounds through a Responses-style API, parallel tools, `ask_user` (30 min), steering notes, idempotent side effects, limits (120 steps, 30 min per turn, bash 300 s) | mixed | agent | partial | [06 §5.4](re/06-agent-harness.md#54-job-endpoint-api-h1-local-server-and-cloud-lab-worker-share-it); [06 §5.5](re/06-agent-harness.md#55-workflow-engine-the-h1-agent-loop); [06 §5.6](re/06-agent-harness.md#56-model-calls) | Server proxy behaviour (model aliasing, injected instructions, metering) |
| `agent-tools` | Agent tools: bash, read, write, edit, view image, ask user, progress or plan, notes, routines, fetch URL, web search, and a code-mode `exec` that calls MCP tools as functions | mixed | agent | partial | [06 §5.7](re/06-agent-harness.md#57-tools-exposed-to-the-h1-model) | — |
| `agent-compaction` | Agent context compaction at about 160k tokens or on context errors: remote compaction endpoint when available, otherwise a structured summary that keeps side effects, answers, deliverables and file lists | server-mediated | agent | partial | [06 §5.8](re/06-agent-harness.md#58-context-compaction) | Semantics of the server's remote compaction |
| `agent-anthropic` | Anthropic Messages adapter for agent turns (Responses-style input converted to Messages, thinking, prompt caching, server web search) | server-mediated | agent | working | [06 §5.6](re/06-agent-harness.md#56-model-calls) | — |
| `agent-cloud` | Cloud agent worker with workspace sync and a tunnel-exposed device helper (deny-listed paths). Code present but unreachable in 1.1.2 | mixed | other:cloud-agent-worker | missing | [06 §5.9](re/06-agent-harness.md#59-local-stdio-mcp-bridge-and-device-helper) | Lab worker implementation and sandbox image |
| `agent-codex` | Codex app-server runtime: isolated agent home, `config.toml` writer (provider, approval and sandbox modes, instructions, MCP servers, skills), model catalog, JSON-RPC over stdio. Runtime binary absent from 1.1.2 | mixed | agent | working | [06 §6](re/06-agent-harness.md#6-codex-app-server-path) | Bundled Codex CLI version; exact launch arguments |
| `agent-auth-policy` | Agent session token (bearer for runtimes) and server runtime policy (agent model lane and effort, enabled loopback root tools). OpenClicky replaces both with local settings | server-mediated | none | working | [09 §2.3](re/09-server-api.md#23-agent-session-token-o); [09 §4.7](re/09-server-api.md#47-background-agent-codex-app-server-and-clicky-harness-h1) | Token field name and TTL; policy values |
| `agent-jobs` | Jobs and work folders: per-job folder with `output/` and `tmp/`, managed run log, owner marker, previous note, `WORK.md` index, job model with rail phases, `WAIT_FOR` user steps watched through the browser URL | built-in | none | partial | [06 §7](re/06-agent-harness.md#7-jobs-one-off-background-work) | Format of per-job `state.md` |
| `agent-clickys` | Kept agents ("Clickys"): roster, per-agent workspace with an `AGENTS.md` memory (identity, standing preferences, notes), archive and restore, thread bindings | built-in | none | partial | [06 §8](re/06-agent-harness.md#8-clickys-kept-named-agents); [08 §5.6](re/08-apps-memory-ui.md#56-per-clicky-and-per-job-memory-files) | — |
| `agent-works-shelf` | Per-Clicky works shelf: a local index of what each Clicky has made (`ClickyApps/works.json`, location under Application Support INFERRED), filled from parsed final replies (title, summary, artifacts) with a main-artifact pick, plus docked and pinned Clickys at the screen edge and one-time migrations that turn older Clickys into jobs | built-in | none | missing | [01 §8.11](re/01-type-map.md#811-agent-runtime-background-agents) (`ClickyAppStore.swift`); types `ClickyWorkEntry`, `ClickyWorkIndex`, `ClickyWorkPiece`, `ClickyWorkShelf`, `ClickyMainArtifacts`, `ClickyAppLiveStatus`; keys `clicky.clickyApps.{pinnedSlugs,dockedUnpinnedSlugs,legacyClickysAsJobs,legacyClickysDocked,legacyClickyWorkBackfilled}.v1` (**not yet investigated**; §6) | `works.json` schema; how pieces are ranked |
| `agent-file-diffs` | Agent file-change tracking (developer preview): snapshot files an agent touches and keep per-thread diff items for a diff view, behind a developer toggle | built-in | none | partial | Types `CodexAgentFileDiffItem`, `CodexAgentFileDiffKind`, `CodexAgentFileSnapshot`; MAIN keys `clicky.codex.fileDiffsByThreadID.v1`, `agentDiffsDevelopmentPreviewEnabled`; fields `isFileDiffCollectionEnabled`, `shouldCollectFileDiffs` (**not yet investigated**; §6) | Diff kinds, snapshot size limits, where the diff renders |
| `agent-clicky-interview` | New-Clicky interview from Home: a short realtime voice interview, reusing the onboarding interview surface, that either founds a new Clicky (its first conversation already seeded with a hello and the task pitch) or routes the idea to an existing Clicky. Leaving midway tells the model not to found one | mixed | voice (+brain) | missing | [08 §6.2](re/08-apps-memory-ui.md#62-onboarding-interview) (leave note only); [06 §15](re/06-agent-harness.md#15-voice-brain-tools-that-control-agents) (`new_clicky` in `sessions_spawn`); MAIN analytics `home_space_new_clicky_interview_started` and `_ended` with `founded`, `routed_to_existing`, `answer_count`; `founded_new_clicky`; type `ClickyFoundingMarker` (**not yet investigated**; §6) | Interview instructions (server or embedded); how answers become `new_clicky {name, role, description}` |
| `agent-final-message` | Final-message contract: tag blocks for summary, done title, next actions, artifacts, structured answer card, learned how-tos, routine request, wait-for step and computer-use request; citation stripping | built-in | none | partial | [06 §9](re/06-agent-harness.md#9-final-message-contract-parsed-by-the-app) | — |
| `agent-brain-tools` | Voice-brain tools that control agents (`sessions_spawn`, `sessions_send`, `sessions_answer_request`, `sessions_interrupt`, `session_status`, `find_jobs`, `read_job`, `show_result`, `routines`, …) and the per-turn jobs, Clickys, routines and progress context notes | mixed | brain | partial | [06 §15](re/06-agent-harness.md#15-voice-brain-tools-that-control-agents) | Server-defined tool schemas and prompts |
| `agent-launch-labels` | Launch labels and titles: a fast model produces a title and spoken/text start cues before a job starts; thread-title backfill | server-mediated | brain | working | [06 §11](re/06-agent-harness.md#11-usage-leases-paywall); [09 §4.7](re/09-server-api.md#47-background-agent-codex-app-server-and-clicky-harness-h1) | Server model and prompt (INFERRED Haiku) |
| `agent-hud` | Agent HUD: notch agent surface, right-edge job rail, launch flight animation, activity labels, plan bars, progress lines fed to the voice brain, agent sounds | built-in | none | partial | [06 §13](re/06-agent-harness.md#13-hud-progress-lines-sounds) | — |
| `agent-task-assets` | Task assets: launch screenshots saved per task and attached; user files passed by path as inputs only | built-in | none | working | [06 §12](re/06-agent-harness.md#12-attachments-and-task-assets) | — |
| `agent-ink-notes` | Ink notes and agent output UI: agent-written `note.md` dialect (Markdown plus object blocks and inline tags), live lint fed back to the agent, user note actions, edge deck, arc progress card, result and sticky cards | built-in | none | missing | [01 §8.12](re/01-type-map.md#812-agent-output-ui-ink-notes-edge-deck-and-cards) (**not yet investigated**) | Full note DSL as taught to agents; renderer details |
| `agent-takeover` | Take-over drive: consent offer, actuator through CGEvent and AX, brain `computer_calls` with screenshot outputs, user-input blocker with Esc to stop, drive overlay and notch state, endings (finished, user took over, safety stop, could not see), agent `mac_step` consent | mixed | brain (+agent) | partial | [03 §7.7](re/03-screen-pointing.md#77-takeover-ill-drive-you-watch-overlay); [02 §5.5](re/02-voice-pipeline.md#55-brainturn-response-sse-stream-o); [06 §10](re/06-agent-harness.md#10-loopback-mcp-server-browser-and-mac_step); [01 §8.13](re/01-type-map.md#813-take-over-drive-computer-use) (actuator **not yet investigated**) | Server safety policy; actuator and step-capture internals |
| `agent-routines` | Local routines: interval, daily or weekday slots, pause, run counts, retries and failure streaks, wait for network, defer on dark wake, keep-awake assertion, run-number prefix on briefs | built-in | none | partial | [06 §14.1](re/06-agent-harness.md#141-local-routines-observed-clickyroutine) | — |
| `agent-remote-tasks` | Remote Tasks: server-run scheduled scripts edited through a local MCP helper; list, detail with runs, run-now. Absorbed into local routines in OpenClicky | server-mediated | other:scheduler | working | [06 §14.2](re/06-agent-harness.md#142-remote-tasks-server-cron--observed-types) | Create, update and delete routes; server executor |
| `agent-notifications` | Agent notifications inbox (in-app only, no macOS notifications), mark read, read all | server-mediated | other:notifications | missing | [06 §14.3](re/06-agent-harness.md#143-agent-notifications) | How notifications are generated; poll interval |
| `mcp-loopback` | Loopback HTTP and MCP server on 127.0.0.1 (bearer auth, `/mcp` only, one response per connection, `initialize`/`ping`/`tools/list`/`tools/call`), hosting the agent tools `browser` and `mac_step` with turn identity from `_meta` | built-in | none | partial | [07 §2.5](re/07-browser-bridge.md#25-loopback-http-and-mcp-server-generic); [06 §10](re/06-agent-harness.md#10-loopback-mcp-server-browser-and-mac_step) | JSON-RPC error codes; `serverInfo` version |
| `browser-host` | Native-messaging host: origin check against the extension id files, 4-byte length-prefixed JSON under 1 MiB, `hello` gate, long-poll relay to the app, `ready` heartbeats, open-app action, parent-browser detection | built-in | none | working | [07 §2.3](re/07-browser-bridge.md#23-clickybrowserhost-native-messaging-helper) | — |
| `browser-manifests` | Native host manifests written for Chrome, Edge, Brave, Arc, Vivaldi, Chrome Beta/Dev/Canary and Chromium where present; profile discovery from `Local State` | built-in | none | working | [07 §2.2](re/07-browser-bridge.md#22-native-messaging-host-manifests) | — |
| `browser-transport` | Host transport (`browser_poll`, `browser_reply`) and per-launch `connection.json` (port and token, private file modes) | built-in | none | working | [07 §2.4](re/07-browser-bridge.md#24-databrowserbridgeconnectionjson); [07 §2.6](re/07-browser-bridge.md#26-host-transport-mcp-server-clicky_browser_host) | Long-poll hold time; argument nesting inside commands |
| `browser-coordinator` | Bridge coordinator: status, profiles and selection, peer liveness (about 35 s), command queue with timeouts, generation counter, tidy at turn end, Stop, per-turn usage counters | built-in | none | partial | [07 §2.8](re/07-browser-bridge.md#28-clickybrowserbridge-app-side-coordinator) | Per-command timeouts; when the per-turn permission gate is active |
| `browser-tool` | Agent `browser` tool: one tool with an operation enum (status, tabs, open, snapshot, extract, batch, click, fill, …, javascript), state-dependent description, read-only class, upload path guard, screenshot saving, tab-group titles | mixed | agent | partial | [07 §2.7](re/07-browser-bridge.md#27-agent-mcp-endpoint-clicky_browser); [07 §2.9](re/07-browser-bridge.md#29-the-browser-tool-agent-facing) | Per-operation result payloads |
| `browser-extension` | Chrome extension (MV3): native port, per-profile id, accessibility-style snapshots with refs and diffs, actions, tab groups and ownership, cursor overlay, Stop, debugger-based pixel input, dialogs, uploads, screenshots, downloads | built-in | none | partial | [07 §2.1](re/07-browser-bridge.md#21-chrome-extension-not-bundled-in-112) | Extension source, manifest, permissions, snapshot and diff format (not on disk) |
| `browser-setup` | Setup and settings: manifests, store or fallback page, wait for first poll, old-copy migration; the voice brain asks before Chrome-dependent jobs and can drive or coach the install | mixed | brain | partial | [07 §2.13](re/07-browser-bridge.md#213-setup-connection-and-voice-brain-flows) | Server prompts behind the brain flows |
| `browser-skill` | Browser agent skill: surface choice, own tab group, batch-first workflow, proof screenshots, confirmations, upload and download rules, page content as data | built-in | agent | working | [07 §2.14](re/07-browser-bridge.md#214-clicky-browser-skill-described-not-copied) | — (OpenClicky writes its own text) |
| `apps-catalog` | Connected apps catalog: list with status, connect through a browser OAuth redirect and app callback, re-poll until a new account appears, disconnect per app or account, account labels; changes restart the agent runtime and mark voice stale | server-mediated | other:integrations | partial | [08 §3.1](re/08-apps-memory-ui.md#31-composio-integrations-list-connect-disconnect); [09 §4.8](re/09-server-api.md#48-integrations-composio) | HTTP verbs and list parameters; account cap; Composio project config |
| `apps-agent-mcp` | Connected-apps MCP session for agents (proxy URL, toolkits, multi-account toolkits, expiry, cached with backoff) and the "connected apps" instruction section | server-mediated | other:integrations | working | [08 §3.2](re/08-apps-memory-ui.md#32-composio-mcp-session-for-background-agents) | Retry counts; proxy tool catalog |
| `apps-integration-skills` | Per-toolkit integration skills (11 toolkits) installed for connected apps | built-in | agent | partial | [08 §3.3](re/08-apps-memory-ui.md#33-integration-skills-resclickyintegrationskillsskillmd) | — (OpenClicky writes its own) |
| `apps-custom-connectors` | User-added MCP connectors (remote URL or local command), auth by browser sign-in, API key or none, MCP probe, capability line from tool verbs, MCP OAuth (discovery, dynamic registration, PKCE, loopback callback), secrets via env vars | built-in | agent | partial | [08 §3.5](re/08-apps-memory-ui.md#35-custom-connectors-user-added-mcp-servers) | — |
| `apps-obsidian` | Obsidian vault integration: user-picked vault path given to agents with a skill | built-in | agent | partial | [08 §3.4](re/08-apps-memory-ui.md#34-local-integrations) | — |
| `apps-read-connected` | Voice brain reads connected apps during a turn (read-only quick look, then talk only; bigger digs become jobs) | server-mediated | brain (+other:integrations) | working | [08 §3.6](re/08-apps-memory-ui.md#36-apps-exposed-to-the-voice-brain-and-realtime-voice) | Tool schema; read-only enforcement on the server |
| `apps-calendar` | Calendar voice tools (find, create) and the upcoming-meeting notch countdown with join, open or directions | server-mediated | voice (+other:integrations) | partial | [08 §3.6](re/08-apps-memory-ui.md#36-apps-exposed-to-the-voice-brain-and-realtime-voice); [09 §4.4](re/09-server-api.md#44-realtime-tool-backends-full-voice-tool-calls-forwarded-to-the-worker) | Argument and response schemas; poll cadence |
| `apps-spotify` | `play_on_spotify`: resolve a query to a track, play through AppleScript, fall back to the URL scheme, verify playback | mixed | voice | partial | [08 §3.6](re/08-apps-memory-ui.md#36-apps-exposed-to-the-voice-brain-and-realtime-voice) | Search request body |
| `apps-suggestion-monitor` | Dwell-based suggestions: sample front app and browser URL, match a registry of about 70 toolkits, accumulate dwell, suggest connecting an app or skill, with snooze, never-ask and rate limits | built-in | none | missing | [08 §3.7](re/08-apps-memory-ui.md#37-integration-suggestion-monitor) | Dwell thresholds and rate limits |
| `lookup-web-search` | Web search for the full voice (`web_search` tool) and for agents (probe, then query with count and freshness; hosted search as fallback) | server-mediated | other:web-search | partial | [09 §4.4](re/09-server-api.md#44-realtime-tool-backends-full-voice-tool-calls-forwarded-to-the-worker); [06 §5.7](re/06-agent-harness.md#57-tools-exposed-to-the-h1-model) | Upstream provider (Exa hinted) |
| `lookup-widgets` | Widget data and renderers: places and place photos (map card), stock quote with sparkline, image gallery, favicons | server-mediated | other:places, other:market-data, other:image-search | partial | [09 §4.6](re/09-server-api.md#46-widget-data-services); [01 §8.8](re/01-type-map.md#88-lookup-tools-server-lookup-tools-and-widgets) (widget UI **not yet investigated**); OpenClicky: docs/dsl-media.md (place and stock cards in drawings; notch widgets not yet) | Upstream providers; widget layouts |
| `skills-library` | Skills library: catalog cache, create from a form or a brain dump (queued and polled), publish, team share, activation sync, program registry, local `.md` import | mixed | other:skill-authoring | working | [08 §4.1](re/08-apps-memory-ui.md#41-skills-library-power-ups); [09 §4.11](re/09-server-api.md#411-skills-library-power-ups) | Creation prompt; review pipeline |
| `skills-active` | Active skills applied to voice (session context, mid-session updates) and to agents (skill files plus an active-skills block); app-specific skills apply fully only in their app | built-in | agent (+voice) | working | [08 §4.1](re/08-apps-memory-ui.md#41-skills-library-power-ups) | — |
| `skills-onboarding-picker` | Onboarding "what should it be good at" picker over vendored open-licence skills | built-in | none | working | [08 §4.2](re/08-apps-memory-ui.md#42-hermes-skills-picker-pre-sign-in-onboarding) | — |
| `skills-bundled-agent` | Bundled agent skills copied into the agent home and enabled in its config: `clicky-browser` (behaviour in `browser-skill`) and `vercel-deploy` (preview-first deploys through the Vercel CLI, with a deploy script and an agent manifest). `vercel-deploy` is vendored under MIT from the public openai/skills repository at a pinned commit, so OpenClicky may take it from upstream, never from HeyClicky's bundle | built-in | agent | working | [08 §3.3](re/08-apps-memory-ui.md#33-integration-skills-resclickyintegrationskillsskillmd) (closing list); [06 §6](re/06-agent-harness.md#6-codex-app-server-path) (`CodexHome/skills/`); `Resources/ClickyBundledSkills/vercel-deploy/{SKILL.md,ATTRIBUTION.md,LICENSE.txt,agents/openai.yaml,scripts/deploy.sh}`. Added by §6 | Whether H1 jobs get the same skill set as Codex jobs |
| `mem-profile` | User memory: profile markdown per account mirrored to `helper/about-the-user.md`, injected into agent briefs as background-only, standing-context ledger, learned how-tos from jobs | mixed | other:memory | working | [08 §5.1](re/08-apps-memory-ui.md#51-user-memory-profile-server-and-helperabout-the-usermd); [06 §7](re/06-agent-harness.md#7-jobs-one-off-background-work) | Server memory extraction and consolidation |
| `mem-voice-tools` | Memory voice tools: save, recall earlier chats, forget | server-mediated | voice (+other:memory) | working | [08 §5.1](re/08-apps-memory-ui.md#51-user-memory-profile-server-and-helperabout-the-usermd) | Recall and forget routes; search semantics |
| `hist-conversation` | Conversation history per account (paged sync) and hand-off records | mixed | none | partial | [08 §5.3](re/08-apps-memory-ui.md#53-conversation-history-dataheyclickyhistory) | Page size; server retention |
| `hist-agent-cache` | Agent thread history and crash-safe turn journal checkpoints | built-in | none | partial | [08 §5.4](re/08-apps-memory-ui.md#54-agent-thread-cache-datahomespacecache) | — |
| `onb-intro` | Pre-sign-in intro steps, permission flow, intro video, 11-step tutorial (mic check to finale), requests deferred during the tour, replayable welcome tour | built-in | voice | partial | [08 §6.1](re/08-apps-memory-ui.md#61-overall-sequence-observed-enums-order-inferred) | — |
| `onb-demo-reel` | Intro-video demo reel: while the onboarding video plays, cues fire at fixed video times and act for real. They open a site in the default browser, launch canned demo agent jobs (fixed prompts, demo Clicky identities, a note telling the agent it is a demo) and open a mail compose window. Each cue fires once (fired times are remembered); replays skip the agent launches; signed-out users skip spawning. Hosted HLS video with a bundled-file fallback | mixed | agent | missing | [08 §6.1](re/08-apps-memory-ui.md#61-overall-sequence-observed-enums-order-inferred) (video only); MAIN strings next to `CompanionManager+OnboardingTutorial.swift`: `OnboardingVideoDemoCue`, `firedOnboardingVideoDemoCueTimes`, `onboarding_demo_triggered`, `OnboardingDemoClickyIdentity`, `IntroVideoPlaybackAttempt`, `ClickyHostedVideo`, log lines "firing cue @" and "skipping duplicate cue @" (**not yet investigated**; §6) | Cue timestamps (held in stripped Swift). OpenClicky needs its own video and demo script |
| `onb-drive-demo` | Scripted drive demos for the tutorial's `clickyDrive` step: deterministic Accessibility automation, not model-driven. Examples: trim a bundled sample clip to 5 s and export it at 720p in QuickTime Player; fix a flat photo with Adjust Color in Preview. Sample files are copied to user folders first; each step has a spoken caption and a failure line when an expected sheet or menu item does not appear; needs Accessibility | built-in | none | missing | [03 §9](re/03-screen-pointing.md#9-tours-and-walkthroughs) (`clickyDrive`); [01 §8.24](re/01-type-map.md#824-onboarding-permissions-onboarding-tutorial-and-permissions) (`CompanionManager+OnboardingDrive.swift`); types `OnboardingDriveDemo`, `OnboardingDriveTarget`, `OnboardingClickyDriveStepContent`; resources `clicky-drive-sample.mp4`, `clicky-preview-photo.jpg`; path strings `Movies/Clicky`, `Application Support/Clicky/Drive`. Added by §6 | Per-step timing; the full demo list (03 also mentions Logic-style examples). OpenClicky ships its own sample media |
| `onb-tour` | Drawn tour: draw demo, draw-to-ask practice, tour job cards, personal finale cards drawn from the interview | mixed | brain | missing | [03 §9](re/03-screen-pointing.md#9-tours-and-walkthroughs) | Tour prompts and card generation |
| `onb-interview` | Onboarding interview in the full voice: fixed opener, adaptive questions under a turn budget, fixed last question, skip tool, deferred task requests, transcript saved for later context | mixed | voice | working | [08 §6.2](re/08-apps-memory-ui.md#62-onboarding-interview) | Exact turn count (inferred 4); server additions to instructions |
| `onb-starter-plan` | Starter plan: interview and connections in, starter Clickys, first asks, routines and suggested agents out, then the reveal | server-mediated | brain | missing | [08 §6.3](re/08-apps-memory-ui.md#63-starter-plan) | Planning prompt and model |
| `pro-suggestions` | Proactive suggestions and the good-morning brief: an async research job returns suggested agents, a morning headline and curated evidence; resolutions and dismissal policy; drawn morning brief | server-mediated | agent | missing | [08 §7.3](re/08-apps-memory-ui.md#73-home-homespace); [01 §8.17](re/01-type-map.md#817-routines-proactive-routines-suggestions-morning-brief-meetings); [09 §4.10](re/09-server-api.md#410-clickys-onboarding-suggestions) | Research and selection logic; poll intervals; producer of `activity-timeline.sqlite` and `app-usage-timeline.sqlite` |
| `pro-organizer` | Clicky organizer: group old one-off agent threads into named Clickys | server-mediated | brain | missing | [08 §5.6](re/08-apps-memory-ui.md#56-per-clicky-and-per-job-memory-files); [09 §4.10](re/09-server-api.md#410-clickys-onboarding-suggestions) | Organizer prompt |
| `file-previews` | Document viewers: native Markdown, XLSX/CSV grid with frozen panes and selection summary, PDF, QuickLook, web snapshot, animated images | built-in | none | partial | [01 §8.19](re/01-type-map.md#819-file-previews-document-viewers) (**not yet investigated**) | Everything beyond file and type names |
| `handoff` | Hand-off to another app: attach to a target app's field, drag-select screen regions, speak, deliver text and images by pid-targeted paste plus Return or by typing; hand-off log | built-in | none | missing | [01 §8.20](re/01-type-map.md#820-handoff-hand-off-to-another-app); [03 §4.4](re/03-screen-pointing.md#44-capture-variants) (region capture only; rest **not yet investigated**) | Delivery strategy details; target attach rules |

**Row counts** (HeyClicky classification): 133 rows in total (124 from the reader pass, 9 added by the completeness review in [§6](#6-gaps-found-by-completeness-review)).

| classification | rows |
|---|---|
| built-in | 70 |
| server-mediated | 32 |
| mixed | 28 |
| out-of-scope | 3 |

By primary slot: 72 `none`, 21 `brain`, 14 `agent`, 11 `voice`, 3 `stt`, 12 `other:*`. Several rows also touch a secondary slot (shown in parentheses in the table).

Eleven reader-pass rows are **not yet investigated**, fully or in part. Fully: `ui-kit`, `ui-character`, `file-previews`, `handoff`, `agent-ink-notes`. In part: `agent-takeover` (actuator), `voice-text-chat` (composer and cards), `lookup-widgets` (widget UI), `draw-lessons` (recorder, printer, video), `shell-permissions` (guide overlay), `shell-updates` (idle-install policy). Six rows added in §6 are also **not yet investigated**: `onb-demo-reel`, `agent-clicky-interview`, `agent-works-shelf`, `agent-file-diffs`, `shell-feature-flags`, `shell-announcements`.

---

## 2. Typed model slots

OpenClicky routes every model use through a typed slot. A slot accepts only providers that declare the capabilities the slot needs; Settings refuses the rest instead of letting a wrong kind of model fail at run time. Each slot has a registry of adapters, per-slot credentials in the Keychain, and capability flags the UI can check. No slot ever points at api.heyclicky.com.

### 2.1 `stt`: streaming speech-to-text

| | |
|---|---|
| Used by | `voice-ears`, `voice-apple-speech`, `voice-dictation` |
| Capabilities required | Streaming PCM16 mono input (16 kHz is typical; HeyClicky's rate is UNKNOWN). Interim and final transcripts. Manual activity start and end for push-to-talk (no server VAD needed). Final text within about 300 ms of key release (02's target). Keyterm or vocabulary biasing (`keyterms`, `known_terms`). Language hint or auto-detect, multilingual. Cancel. Optional warm pre-connect with expiry. A batch WAV `transcribe` entry point for the fallback path. |
| HeyClicky default it replaces | Gemini Live over `BidiGenerateContentConstrained` with a token and `setup` minted by `/brain/ears/token` or `/v2/dictation/gemini-token` (model id inside `setup`, UNKNOWN); batch fallback `/brain/ears/transcribe` and `/v2/dictation/transcribe` (server STT UNKNOWN); Apple Speech on the legacy path. Not Deepgram nova-3 (absent from 1.1.2). |
| Allowed | Streaming ASR services with partial results (Gemini Live input transcription, OpenAI Realtime transcription sessions, Deepgram-style streaming sockets and similar), on-device streaming recognisers (Apple Speech, WhisperKit-class local models). Batch-only ASR is allowed **only** in the fallback sub-slot. |
| Rejected | Text LLMs, TTS models, speech-to-speech assistants used to answer rather than transcribe, and any recogniser without interim results or with finalisation slower than about 1 s as the primary path. |

### 2.2 `voice`: speech output, with an optional realtime sub-slot

| | |
|---|---|
| Used by | `voice-mouth`, `voice-picker`, `draw-pacer` (line timing), `onb-intro`; realtime sub-slot: `voice-full-realtime`, `point-realtime-attach`, `onb-interview`, `agent-clicky-interview`, `apps-calendar`, `apps-spotify`, `mem-voice-tools` |
| Capabilities required, `voice.line` (required) | Text in, streaming audio out (PCM16 or decodable). Verbatim reading of the given line, never paraphrased. Selectable voice id, speed 0.5x to 1.5x, language. Per-line start and finish events, and the line's audio duration as early as possible so the drawing pacer can fit strokes (`line(k)`, `lineLength(k, s)`). Optional transcript or word timing for captions. Cancel mid-line. First audio within about 500 ms. A short-clip mode for voice previews. |
| Capabilities required, `voice.realtime` (optional) | Bidirectional audio socket; server VAD with barge-in and truncate; input transcription; function calling with JSON arguments; image input items; mid-session instruction and context updates. Instructions and tools are sent by OpenClicky (HeyClicky's server injected them). |
| HeyClicky default it replaces | `voice.line`: `gpt-realtime-2.1-mini` in out-of-band audio-only mode through a session minted by `/agent/realtime/session` (default voice `cedar`), or `gemini-3.8-flash-lite-tts` per line through `/agent/realtime/speak`. `voice.realtime`: `gpt-realtime-2.1`. Previews: `/agent/realtime/voice-preview`. |
| Allowed | Streaming TTS APIs; realtime speech models driven in audio-only, out-of-band mode; on-device neural TTS; the system synthesizer as a last-resort fallback. For `voice.realtime`: speech-to-speech models with tool calling and VAD. |
| Rejected | Chat models that would rewrite the line; file-only TTS as the live path (fine for previews); STT models; any voice cloned from HeyClicky's bundled preview audio (clean-room). For `voice.realtime`: models without function calling or interruption support. |

### 2.3 `brain`: multimodal LLM with tool calling, plus a fast text variant

| | |
|---|---|
| Used by | `voice-brain-turn`, `voice-brain-tools`, `voice-higher-model`, `voice-text-chat`, `voice-legacy-chat`, `voice-job-reports`, `draw-generation`, `draw-editor`, `3d-picking`, `point-tags`, `point-guided`, `point-onebrain`, `agent-brain-tools`, `agent-takeover`, `browser-setup`, `apps-read-connected`, `onb-tour`, `onb-starter-plan`, `pro-organizer`; `brain.fast`: `agent-launch-labels`, `voice-dictation` cleanup, `voice-brain-session` compaction and memory notes |
| Capabilities required, `brain.main` | Image input (several labelled JPEG screenshots, long edge about 1280 px). Streaming text with low time to first token (HeyClicky's server TTFT was about 1.4 to 4.1 s). Function calling, parallel calls, async tools and a multi-round tool loop. Long, syntactically valid code output (the JS drawing program with early `say()` lines) that can be parsed while it streams. Long context (at least about 128k) with compaction. Prompt caching. Follows a long skill prompt (drawing DSL, `figure()`, pointing grammar) written by OpenClicky. Optional: opaque reasoning carry-over, hosted web search, computer-use actions for take-over. |
| Capabilities required, `brain.fast` | Text in and out, low latency and cost, JSON-mode output. Image input not required. |
| HeyClicky default it replaces | `/brain/turn` with `OneBrainModelChoice`; the in-app default reads as `gpt-6.1-sol-ultrafast-medium`, logs report `gpt-6.1-sol`; alternates `gpt-6.1-sol` variants, `gpt-6.1-terra-fast-medium`, `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`, `deepseek-v4.1-flash-medium/high`. Also `/chat-tool-call` (server-chosen), `/chat` and `/v2/chat` (Anthropic and OpenRouter). `brain.fast` replaces `/v2/dictation/cleanup`, `/codex-thread-launch` and `/codex-thread-title` (Haiku per logs), `/brain/compact`, `/brain/session-end`, `/clickys/organize-history`. |
| Allowed | Multimodal frontier models over the OpenAI Responses API, Anthropic Messages, Gemini, or an OpenAI-compatible endpoint (OpenRouter or local) whose model declares image input, tools and streaming. Text-only models are allowed in `brain.fast` only. |
| Rejected | Text-only models in `brain.main`; models without tool calling or without streaming; short-context models that cannot hold the skill prompt plus thread; image-generation, embedding and realtime speech models. |

### 2.4 `agent`: agent harness plus LLM

| | |
|---|---|
| Used by | `agent-loop`, `agent-tools`, `agent-compaction`, `agent-anthropic`, `agent-codex`, `browser-tool`, `browser-skill`, `apps-integration-skills`, `apps-custom-connectors`, `apps-obsidian`, `skills-active`, `skills-bundled-agent`, `pro-suggestions` (research job), `onb-demo-reel` (canned demo jobs), `agent-takeover` (`mac_step`) |
| Capabilities required | **LLM:** Responses-style or Messages-style streaming; function tools with parallel calls; reasoning-effort control; image input (screenshots, `view_image`); large output budget; long context (about 200k or more) or compaction; prompt cache key; request metadata. **Harness:** multi-step loop with shell and file tools; MCP client over Streamable HTTP and stdio with a bearer from an environment variable, `_meta` pass-through and 900 s tool timeouts; skills directory; `ask_user`; steer and interrupt mid-turn; durable steps and per-job folders. |
| HeyClicky default it replaces | `Helpers/clicky-harness` (H1, `h1-mac` driver) with `gpt-6-luna` through `/agent/openai/v1/responses` (and `/responses/compact`); Claude Haiku 5.5 through `/agent/harness/model/anthropic/v1/messages` when chosen; Codex app-server with model provider `clicky`, `gpt-6-luna`, effort high (runtime missing from 1.1.2). |
| Allowed | OpenClicky's own harness (`openclicky-harness`, an H1-style runtime) pointed at any Responses- or Messages-compatible endpoint the user configures; a user-installed Codex CLI app-server with a user model provider; other harnesses that implement OpenClicky's `AgentRuntime` runner protocol. |
| Rejected | Plain chat models with no tool calling; harnesses without MCP, interrupt or steering; models with small context and no compaction path. |

### 2.5 Other slots

| slot | capabilities | HeyClicky default it replaces | allowed | rejected |
|---|---|---|---|---|
| `other:grounding` (optional) | Screenshot plus element description in, screen coordinate out; fixed working resolutions | Anthropic computer-use tool `computer_20251124` via `AnthropicMessagesURL` (INFERRED dormant) | Vision models with a computer-use or pointing tool; local UI-grounding models; an AX search fallback | Text-only models |
| `other:web-search` | Query, count and freshness in; results with title, URL, highlights and age out | Exa-like `/agent/web-search` for agents; `/web-search` for full voice; hosted `web_search` fallback | Search APIs with the user's key; provider-hosted search tools | Scraping search-engine HTML |
| `other:image-search` | Name, web or page-preview query; public photos with source URL; people filter | `image-search` (Brave hinted by logs) | Image search APIs, Wikimedia Commons | Image-generation models (drawings must show real, sourced photos) |
| `other:places` | Place search with coordinates, rating, hours links; optional photos | `place-search`, `place-photo` (Google Places INFERRED) | MapKit local search (default, no key); a places API with the user's key | — |
| `other:market-data` | Quote, day range, previous close, sparkline closes | `stock-quote` | Market data APIs with the user's key | — |
| `other:integrations` | Remote MCP tool gateway with per-user OAuth accounts and labels | Composio through `/agent/integrations*` and `/agent/composio/session` | Direct remote MCP servers with OAuth 2.1, local stdio MCP, an optional Composio adapter with the user's own key | Storing third-party passwords; any shared HeyClicky gateway |

**Derived slots** (no separate provider; they reuse a typed slot with OpenClicky-authored prompts):

| derived use | runs on | replaces |
|---|---|---|
| `other:text-cleanup` (dictation) | `brain.fast` | `/v2/dictation/cleanup` |
| `other:summarizer` (thread compaction) | `brain.fast` | `/brain/compact` |
| `other:memory-writer` (session note, profile) | `brain.fast` | `/brain/session-end`, `/me/memory/save` |
| launch labels and titles | `brain.fast` | `/codex-thread-launch`, `/codex-thread-title` |
| planner and organizer | `brain.main` (JSON output) | `/onboarding/starter-plan`, `/clickys/organize-history` |
| `other:skill-authoring` | `agent` job that writes a `SKILL.md` | `/skills/creations` |
| proactive suggestions research | `agent` job | `/proactive-agents/*` |
| `other:metering`, `other:scheduler`, `other:notifications` | local services, no model | leases, `/agent/cron/*`, `/agent/notifications*` |
| `other:cloud-agent-worker` | deferred; no slot in v1 | `/agent/harness/lab/h1/*` |

---

## 3. Server routes

Every HeyClicky server route seen in 1.1.2, merged from all readers, with OpenClicky's replacement. Base is `https://api.heyclicky.com` (the "Worker") unless a host is given. "Model choice" says whether the request carries a model selection. Corrections from [09 §13](re/09-server-api.md#13-corrections-to-sibling-docs-evidence-in-4) are applied (for example `/agent/composio/session` and `/agent/session-token` are POST).

| route | rows | purpose | model choice | OpenClicky replacement |
|---|---|---|---|---|
| `POST /brain/turn` (SSE, gzip when large) | `voice-brain-turn`, `draw-generation`, `point-onebrain`, `agent-takeover` | One-brain turn: thread plus turn context and screenshot in; program text with `say()` lines, tool calls, computer calls, items and usage out | yes (`brain_model`) | `brain.main` adapters emitting OpenClicky's internal BrainEvent stream (same event vocabulary); local prompt assembler; no signed user layer |
| `POST /brain/prewarm` | `voice-brain-session` | Warm the provider prompt cache at key-down | yes | Provider prompt caching (cache keys or cache-control) or a no-op |
| `POST /brain/compact` | `voice-brain-session` | Fold old thread items into a note | no | Local compaction on `brain.fast` |
| `POST /brain/session-end` | `voice-brain-session`, `mem-profile` | Hand a finished session over for note and memory | no | Local memory-writer job on `brain.fast` |
| `POST /brain/ears/token` | `voice-ears` | Mint a Gemini Live token, `setup` and receipt | no | `stt` adapter with the user's key (or a locally minted ephemeral token) |
| `POST /brain/ears/transcribe` | `voice-ears` | Batch fallback for a whole press (WAV) | no | `stt` batch sub-slot |
| `POST /v2/dictation/gemini-token` | `voice-dictation` | Gemini token for dictation | no | `stt` adapter |
| `POST /v2/dictation/transcribe` | `voice-dictation` | Batch dictation STT with field context and terms | no | `stt` batch sub-slot |
| `POST /v2/dictation/cleanup` | `voice-dictation` | LLM cleanup with field context (`fast_cleanup` tier flag) | tier flag only | `brain.fast` with an OpenClicky prompt |
| `WSS generativelanguage.googleapis.com/…BidiGenerateContentConstrained` | `voice-ears`, `voice-dictation` | Direct streaming STT with the minted token | no | Kept as a `GeminiLiveSTT` adapter on the user's key |
| `POST /agent/realtime/session` | `voice-mouth`, `voice-full-realtime`, `point-realtime-attach` | Mint an OpenAI Realtime ephemeral secret; server picks the model | server decides | `voice` adapter mints its own client secret with the user's key or connects directly; sends instructions and tools itself |
| `WSS api.openai.com/v1/realtime?model=…` | `voice-mouth`, `voice-full-realtime` | Direct realtime socket | yes (query) | Kept as an `OpenAIRealtimeVoice` adapter |
| `POST /agent/realtime/speak` (streamed) | `voice-mouth` | Gemini TTS of one line or a paraphrased update | no | `voice.line` HTTP-streaming TTS adapter |
| `POST /agent/realtime/voice-preview` | `voice-picker` | Localized preview clip (WAV) | no | `voice.line` short-clip synthesis, cached locally |
| `POST /agent/realtime/turn` | `voice-mouth`, `shell-usage` | Usage report for realtime turns | report only | Drop; local usage ledger |
| `HEAD /agent/realtime/warmup` | `voice-full-realtime` | TLS warm-up | no | Drop (optionally pre-warm the provider host) |
| `GET https://api.openai.com/v1/models` (no auth) | `voice-provider-diagnosis` | Diagnose region or network blocks | no | Kept, generalised per adapter |
| `POST /chat-tool-call` | `voice-higher-model`, `point-guided` | Higher-model answer with widgets, visuals, typing, hand-off | no (server) | `brain.main` HigherModelDelegate returning the same response shape |
| `POST /web-search` | `lookup-web-search` | Full-voice web search | no | `other:web-search` |
| `POST /me/memory/save` | `mem-voice-tools` | `save_memory` backend | no | Local MemoryStore |
| `POST /agent/realtime/google-calendar/events`, `…/events/create` | `apps-calendar` | Calendar find and create | no | EventKit, or a calendar MCP connector |
| `POST /agent/realtime/spotify/search` | `apps-spotify` | Resolve a query to a track URI | no | Spotify Web API with the user's app credentials, else the search URL scheme |
| `POST /chat`, `POST /v2/chat` (SSE) | `voice-legacy-chat`, `onb-tour` | Classic chat via Anthropic or OpenRouter with prompt profiles | yes (`response_model_selection`, `open_router_custom_model`) | Covered by `brain.main` adapters; no separate route |
| `POST image-search` | `draw-photos`, `lookup-widgets` | Image search for drawings and galleries | no | `other:image-search` |
| `POST place-search`, `POST place-photo` | `lookup-widgets` | Places and photos | no | `other:places` (MapKit default) |
| `POST stock-quote` (no bearer) | `lookup-widgets` | Stock widget data | no | `other:market-data` |
| `GET /favicon?host=…&sz=64` | `draw-photos` | Favicons | no | Direct public favicon service (HeyClicky also uses one directly) |
| `POST /agent/session-token` | `agent-auth-policy` | Short-lived agent bearer | grants dev model choice | Drop; agent slot credentials |
| `POST /agent/openai/v1/responses` (+ `/compact`) | `agent-loop`, `agent-compaction`, `agent-codex`, `browser-tool` | Responses proxy for H1 and Codex; lease ids in metadata | yes (`model`, `reasoning.effort`) | `agent` adapter to the user's Responses-compatible base URL; compaction via remote endpoint if offered, else local summary; metadata for local cost attribution only |
| `POST /agent/harness/model/anthropic/v1/messages` | `agent-anthropic` | Messages proxy for Haiku agent runs | yes | `agent` Anthropic adapter on the user's key |
| `GET/POST /agent/web-search` | `lookup-web-search` | Agent search probe and query | no | `other:web-search` |
| `/agent/harness/lab/h1/jobs…`, `/probe` | `agent-cloud` | Cloud H1 job API | yes (`cfg.model`) | Deferred |
| `GET /runtime/model-policy` | `agent-auth-policy` | Agent lane, model and effort | yes (server) | Local settings |
| `GET /runtime/tool-policy` | `agent-auth-policy`, `mcp-loopback` | Enabled loopback root tools | no | Local settings |
| `POST /codex-thread-launch` | `agent-launch-labels` | Title, start cues, paywall gate | no (server) | `brain.fast` task labeler, no gate |
| `POST /codex-thread-title` | `agent-launch-labels` | Thread name backfill | no | `brain.fast` |
| `POST /agent/record-agent-launch` | `shell-usage` | Usage record, likely lease creation | no | Drop; local usage ledger |
| `GET /agent/turn-lease/{id}/status`; `POST …/continue`, `…/complete`, `/refund-early-stop`, `/continue-after-computer-use-consent` | `shell-usage`, `agent-takeover` | Lease lifecycle, extra-usage approval, refunds | no | Drop; computer-use consent stays local |
| `POST /agent-messages` | `shell-home` | Server log of agent messages | no | Drop (local history only) |
| `GET /me/memory` | `mem-profile` | Memory profile markdown | no | Local MemoryStore |
| `GET /agent/integrations?limit=1000`; `POST …/{id}/connect`, `…/{id}/disconnect`, `…/{id}/accounts/{acct}/label`, `…/{id}/accounts/{acct}/disconnect` | `apps-catalog` | Integration catalog and connections | no | IntegrationsHub with a `ConnectorProvider` protocol (MCP OAuth; optional Composio adapter) |
| `POST /agent/composio/session` | `apps-agent-mcp` | MCP proxy session for agents | no | Local MCP host config; optional Composio adapter |
| `GET /agent/cron/list`, `GET /agent/cron/{id}`, `POST /agent/cron/{id}/run-now` | `agent-remote-tasks` | Server-run scheduled tasks | no | Local RoutineScheduler |
| `GET /agent/notifications?limit=20`, `POST …/{id}/read`, `POST …/read-all` | `agent-notifications` | Notification inbox | no | Local NotificationsStore |
| `POST /clickys/organize-history` | `pro-organizer` | Group threads into Clickys | no (server) | `brain.main` organizer prompt |
| `POST /onboarding/starter-plan` | `onb-starter-plan` | Interview to starter plan | no (server) | `brain.main` planner prompt |
| `GET /onboarding/language-hints` | `voice-picker` | Region to language hints | no | Static table |
| `POST /proactive-agents/jobs`, `GET …/jobs/{id}`, `POST …/invitation-claim`, `…/resolution`, `/suggestions/statuses` | `pro-suggestions` | Suggestions and morning brief | no (server) | Local SuggestionsEngine as an `agent` job; statuses stored locally |
| `GET /skills/library`, `GET /programs`, `POST /skills/create`, `POST /skills/creations`, `PATCH/DELETE /skills/{slug}`, `POST /skills/{slug}/publish`, `…/unpublish`, `…/share-to-team`, `…/unshare-from-team`, `POST /skills/activations/sync` | `skills-library` | Skills marketplace | no | Local SkillsLibrary folders and index; creation as an `agent` job; drop publish, team share and sync |
| `GET /me/companion-history` | `hist-conversation` | Paged chat history | no | Local HistoryStore (no sync) |
| `GET /me/calendar/upcoming` | `apps-calendar` | Upcoming events for the countdown | no | EventKit |
| `POST /me/devices`, `POST /me/discovery-channel`, `GET /app-config` | `shell-remote-config` | Device registration, survey, remote links | no | Drop |
| `POST /me/account/delete` | `shell-auth` | Account deletion | no | "Reset local data" action |
| `POST /report-error` (no bearer) | `shell-telemetry` | Client error reports | no | Local diagnostics bundle the user can share |
| `GET /me/plan`, `POST /billing/checkout`, `POST /billing/portal` | `shell-billing` | Plans and checkout | no | Drop |
| `GET /me/referral`, `POST /me/referral/claim`, `POST /me/referral/code` | `shell-referral` | Referral programme | no | Drop |
| `GET /auth/start` (browser); Supabase `GET /auth/v1/user`, `POST /auth/v1/token?grant_type=refresh_token` | `shell-auth` | Sign-in and refresh | no | Drop (no account) |
| `POST https://api.anthropic.com/v1/messages` (`AnthropicMessagesURL`) | `point-grounding` | Computer-use grounding | yes | Optional `other:grounding` adapter |
| `POST https://api.openai.com/v1/chat/completions` (`OpenAIChatCompletionsURL`) | `voice-legacy-chat` | Dormant direct chat client | yes | Covered by `brain.main` adapters |
| PostHog (`/batch`, `/flags`, `/config`), Sentry ingest | `shell-telemetry` | Analytics, LLM traces, crashes | no | Drop, or opt-in content-free reporting |
| Sparkle appcast (GitHub Pages), `stream.mux.com` videos | `shell-updates`, `onb-intro` | Updates, hosted videos | no | OpenClicky's own appcast and EdDSA key; own or no videos |
| `http://127.0.0.1:<port>` (runner, loopback MCP, browser host transport, connector OAuth callback) | `agent-runner`, `mcp-loopback`, `browser-transport`, `apps-custom-connectors` | Local only, not server traffic | no | Kept (rebuilt) |

---

## 4. Traffic capture checklist

Readers worked only from static artifacts and the user's local data. They made **no** network calls to HeyClicky. The items below would settle what static analysis could not. If they are ever captured, rules apply:

- Only the account owner does it, on a test account, through a TLS-intercepting proxy that shows WebSocket frames.
- Tokens, cookies and keys from a capture never enter the repo.
- Server-injected prompts or tool descriptions seen in a capture are HeyClicky's IP: record their *shape* (field names, sizes, which turn they ride on), never their wording.
- Items marked **local** need no HeyClicky traffic (loopback, process listing, or the user's own log files).

Priority: **P1** blocks an OpenClicky internal contract or slot design; **P2** sets a tuning constant or behaviour detail; **P3** concerns routes OpenClicky drops.

**Brain turn**

1. P1 `/brain/turn` request for (a) the first turn of a session, (b) a tool-result round, (c) a typed turn: which keys sit in `turn` vs top level, `environment`, `turn_items`, `max_rounds`, whether `input` is a Responses input array. (`voice-brain-turn`)
2. P1 `/brain/turn` SSE framing (`event:` lines, keep-alives), the full event and `status` kind set, `items` contents (encrypted reasoning?), the `done`/`usage` keys, and whether program text arrives as fine deltas or whole lines. (`voice-brain-turn`, `draw-generation`)
3. P1 How screenshots "by reference" (`screenshot_files`, `clicky_file`) are uploaded and addressed after the first turn. (`point-onebrain`)
4. P1 Whether the drawing and `figure()` references ride on every turn or stay server-side; whether follow-ups carry the canvas card-state text, in which field; whether 3D availability is flagged in the request. (`draw-generation`, `draw-editor`, `3d-figure-api`)
5. P2 `turn_token` meaning across tool rounds and how rounds avoid double billing. (`voice-brain-turn`)
6. P2 `/brain/prewarm`, `/brain/compact`, `/brain/session-end` response bodies; compaction thresholds and `tokens_until_fold` values; prewarm idle threshold; when session-end fires and whether it updates `/me/memory`. (`voice-brain-session`, `mem-profile`)
7. P2 Wire format and tag of the 3D click-to-ask turn (`drawing_3d_part` or `figure_part`). (`3d-picking`)
8. P2 Function-call argument shapes for brain tools (`sessions_spawn`, `sessions_send`, `sessions_answer_request`, `routines`, `find_jobs`, `show_result`, `read_connected_apps`). **Local** first: the user's saved thread JSON already holds past `function_call` arguments. (`voice-brain-tools`, `agent-brain-tools`)
9. P2 When `x-clicky-accepts-gzip: 1` is sent and whether every brain turn is gzipped; `X-Clicky-Usage-Context` values per surface. (`shell-http`)
10. P2 End-to-end latency per press: key-down to token and ready, finish to final, release to first spoken line. **Local**: from the app's own timing logs. (`voice-latency`)

**Speech to text**

11. P1 The `setup` object from `/brain/ears/token` and `/v2/dictation/gemini-token`: Gemini model id, input transcription config, whether automatic activity detection is off, language handling; token TTL; receipt format. (`voice-ears`, `voice-dictation`)
12. P1 Gemini socket auth placement (query parameter or `Authorization: Token`), the first client frame, and the audio rate in `audio/pcm;rate=N`. (`voice-ears`)
13. P2 `/v2/dictation/cleanup` full body, the meaning of `fast_cleanup`, whether `known_terms` is sent, and response keys beyond `text`. (`voice-dictation`)
14. P2 When the batch fallbacks trigger and what they return. (`voice-ears`, `voice-dictation`)

**Speech output and full voice**

15. P1 `/agent/realtime/session` request (placement of the `one_brain_mouth` marker, `client_capabilities` values) and full response (`client_secret` expiry; does `session` include instructions, tools and turn detection?). (`voice-mouth`, `voice-full-realtime`)
16. P1 First frames on the OpenAI realtime socket and upgrade headers: is `session.update` the only client configuration? (`voice-mouth`)
17. P1 `/agent/realtime/speak` framing (NDJSON, SSE or raw PCM), audio format and rate, request body for a line vs an update. (`voice-mouth`)
18. P2 Which hold-to-talk situations route to full voice instead of one brain. (`voice-orchestrator`)
19. P2 Realtime tool definitions (`capture_screen`, `send_to_higher_model`, `tutorial_draw_on_screen`, `read_connected_apps`, calendar, Spotify, memory) and any server-side image detail limits. (`voice-full-realtime`, `point-realtime-attach`)
20. P2 VAD values actually used in always-on mode. (`voice-full-realtime`)
21. P3 When `/agent/realtime/turn` fires and what it returns; voice-preview response headers. (`shell-usage`, `voice-picker`)

**Higher model, pointing and tools**

22. P1 `/chat-tool-call` captures for a plain question, a guided walkthrough, an annotation gesture and attachments: `widgets` payloads, `walkthrough` shape, whether visuals arrive as tag lines or structured fields, and whether `guidedMaxRounds` is always present. (`voice-higher-model`, `point-guided`)
23. P2 The `HIGHLIGHT` four-number convention and whether `screenN` is 1-based in label order; the guided follow-up body (goal, prior instruction, target label, completed steps). (`point-tags`, `point-guided`)
24. P2 Bodies the realtime model sends to `/web-search`, `/me/memory/save` and the calendar routes; the recall and forget routes. (`lookup-web-search`, `mem-voice-tools`, `apps-calendar`)
25. P2 `image-search` full path and body (query field, people filter, count, page-URL mode); `place-photo` content type; whether `stock-quote` is unauthenticated; host of `/favicon`. (`draw-photos`, `lookup-widgets`)
26. P2 Size limit on `active_document` extracted text. (`screen-context`)
27. P3 Whether `/chat` or `/v2/chat` is still hit in 1.1.2 and from which UI; `clicky_widget` payloads; other `response_model_selection` values. (`voice-legacy-chat`)
28. P3 Whether `ElementLocationDetector` or the direct chat-completions client is ever called, with which model and key. (`point-grounding`)

**Agents**

29. P1 Which runtime actually runs jobs in 1.1.2 (H1 vs Codex) and what endpoints and model ids `clicky-harness` calls. **Local**: process listing and the harness's own job files. (`agent-loop`)
30. P1 Agent calls to `/agent/openai/v1/responses`: headers, `metadata` keys, `prompt_cache_key`; whether the proxy rewrites model ids, injects instructions, or downsizes tool results such as browser screenshots; whether Codex calls `/models`. (`agent-loop`, `browser-tool`)
31. P2 `/responses/compact` and the Anthropic Messages calls when Haiku is chosen. (`agent-compaction`, `agent-anthropic`)
32. P2 `/agent/web-search` response shape, freshness values, and how Exa vs hosted search is chosen. (`lookup-web-search`)
33. P2 `/runtime/model-policy` and `/runtime/tool-policy`: host, values, and whether the model policy overrides `config.toml`. (`agent-auth-policy`)
34. P2 `/agent/composio/session`: `proxy_url` form, headers, expiry units; MCP tools it lists; multi-account signalling; connect redirect host and the `integrations-auth-callback` query parameters. (`apps-agent-mcp`, `apps-catalog`)
35. P3 Lease lifecycle: `/agent/record-agent-launch` body and response, status poll cadence, `complete`/`continue`/refund bodies, when `requires_extra_effort` fires, how drive leases tie in. (`shell-usage`)
36. P3 `/codex-thread-launch` and `/codex-thread-title` timing (is launch blocked on them?) and the paywall response. (`agent-launch-labels`)
37. P3 `/agent/session-token` response: token field, TTL, JWT or opaque, `capabilities` type; whether `GEMINI_API_KEY` exported to agents equals it. (`agent-auth-policy`)
38. P3 Whether the server ever selects the cloud place or the `pi` harness; the exact Codex app-server command line and environment used by 1.1.1 (**local** process capture). (`agent-cloud`, `agent-codex`)

**Browser bridge** (all **local** loopback)

39. P1 Command and result JSON on the host transport for each operation (tabs, open, snapshot, extract, batch, download, keep, end, sweep), including `closed` and `downloads`. (`browser-transport`, `browser-tool`)
40. P2 How long `browser_poll` is held and how fast commands are delivered; per-command timeouts before "didn't answer in time". (`browser-transport`, `browser-coordinator`)
41. P3 Whether the host and agent endpoints share one listener and token; JSON-RPC error codes and `serverInfo` on each. (`mcp-loopback`)
42. P3 Browser analytics event names and whether any server route is touched when a browser turn ends, times out or is stopped. (`browser-coordinator`)

**Product services**

43. P2 `/proactive-agents` job-create path, polling interval, `curated_evidence` and morning headline shapes, the unnamed POST path, the invitation-claim body. (`pro-suggestions`)
44. P2 `/clickys/organize-history` and `/onboarding/starter-plan` request and response, including the interview line format and latency; the `/onboarding/language-hints` query parameter. (`pro-organizer`, `onb-starter-plan`, `voice-picker`)
45. P3 HTTP calls made by the `clicky-crons` MCP helper (create, update, delete routes). (`agent-remote-tasks`)
46. P3 Notification and plan poll intervals; integration and skills route verbs and query parameters; `/programs` prefix; skill-creation polling. (`agent-notifications`, `apps-catalog`, `skills-library`)
47. P3 `/me/companion-history` page size and message wire format; `/me/calendar/upcoming` cadence; `/me/devices` resend rule; full `/app-config` contents (feature flags, kill switches). (`hist-conversation`, `apps-calendar`, `shell-remote-config`)
48. P3 `/auth/start` parameters, redirect chain and callback format (fragment vs query); Supabase refresh cadence. (`shell-auth`)
49. P3 Whether device headers ride on every Worker request and how `X-Clicky-Device` is hashed. (`shell-http`)
50. P3 Whether PostHog `$ai_generation` events include prompt or output text (privacy note for the README comparison). (`shell-telemetry`)

**Local runtime observation** (no traffic; values held in stripped Swift)

51. P2 Duration constants: mouth and realtime idle teardown, ears ready grace and final timeout, warm-socket expiry, Bluetooth mic hold, response watchdog. (`voice-mouth`, `voice-ears`, `voice-mic`)
52. P2 Double- and triple-tap windows and the default dictation-hold mask; which chime marks listen start; chime warm-up lead-ins. (`shell-hotkeys`, `shell-audio-feedback`)
53. P2 Turntable speed, rest delay, drag sensitivity, click threshold, outline widths, kernel cache budget. (`3d-scene-model`, `3d-illustrated`, `3d-kernel`)
54. P2 Guided target expiry, rest duration and grace window; cursor flight arc height; `NotchPanel` window level. (`point-guided`, `overlay-buddy`, `shell-notch`)
55. P3 Integration suggestion dwell thresholds and rate limits; interview turn count. (`apps-suggestion-monitor`, `onb-interview`)

---

## 5. Build order

This is the original dependency-ordered milestone plan, retained for scope and row mapping. It is not the current remaining-work queue; use [parity-status.md](parity-status.md#next-wave) for that. Each milestone was intended as one PR or a short stack. "Rows" lists the parity rows the milestone brings to `working`; a row listed in two milestones is finished by the later one. Milestones marked **investigate first** need a reader pass on the type-map-only areas before code.

**Foundation and the voice loop**

1. **M01 App scaffold.** SwiftPM workspace, `OpenClickyApp` (`LSUIElement`, launch at login), `OCCore` (settings store, file locations under `~/Library/Application Support/OpenClicky`, logging, JSONL journal), typed feature-flag registry, URL-scheme handler, CI with unit tests. Rows: `shell-app`, `shell-feature-flags`, `shell-url-router`.
2. **M02 HTTP and streaming client.** JSON coding, SSE parser, optional gzip, retry and 401 hooks, a test-only mock server speaking the shapes in [09 §4](re/09-server-api.md#4-route-catalog), fixtures. Rows: `shell-http`.
3. **M03 Provider slot registry.** `STTProvider`, `VoiceProvider`, `BrainProvider`, `AgentRuntime` and `other:*` protocols; capability declarations and validation that rejects wrong kinds; Keychain credentials; a minimal Settings providers page. No account system. Rows: `shell-auth` (replacement), `shell-settings` (providers part).
4. **M04 Permissions.** Coordinator for mic, Accessibility, Screen Recording, the ScreenCaptureKit picker and folders; deep links; relaunch helper; basic coaching. Rows: `shell-permissions`.
5. **M05 Talk keys.** CGEvent-tap monitor, shortcut specs per slot, double and triple tap, Escape tap, recorder. Rows: `shell-hotkeys`.
6. **M06 Audio I/O basics.** Capture-session mic, PCM16 converter, WAV encoder, speech player with frame tracking and drain events, output-silence detector, chime player. Rows: `voice-playback`, `voice-mic` (basic), `shell-audio-feedback` (chimes).
7. **M07 STT slot v1.** Streaming transcriber protocol, one cloud streaming adapter, Apple Speech adapter, batch fallback, warm sockets, press timings. Rows: `voice-ears`, `voice-apple-speech`.
8. **M08 Screen capture.** Multi-display capture, window capture policy with self-exclusion, front-app tracker. Rows: `screen-capture`, `screen-capture-policy` (exclusion part).
9. **M09 Notch v0 and design tokens.** Notch panel per display, presenter states, activity pill, live transcript, minimal design tokens. Rows: `shell-notch`, `voice-captions-ui` (pill and transcript), `ui-kit` (tokens).
10. **M10 Brain slot v1.** BrainEvent vocabulary with Responses, Messages and OpenAI-compatible adapters; thread store v0; OpenClicky prompt assembler; incremental `say()` extractor. Rows: `voice-brain-turn`.
11. **M11 Voice slot v1.** Line speaker protocol, one streaming TTS adapter, system TTS fallback, health checks and provider fallback. Rows: `voice-mouth`.
12. **M12 Voice loop end to end.** Turn orchestrator (press → transcript → screenshot → brain → spoken lines), barge-in, Escape, cut-off notes, muted-output fallback, typed turns from the text trigger, timing marks and stats HUD. Rows: `voice-orchestrator`, `voice-latency`, `voice-text-chat` (typed turns).
13. **M13 Brain tools.** Tool runner (sync and async, ordered outputs, deferred actions, synthetic outputs), registry, first local tools, web-search slot. Rows: `voice-brain-tools`, `lookup-web-search`.
14. **M14 Brain session lifecycle.** Compaction and memory notes on `brain.fast`, provider prompt caching, session end, screenshot pruning, per-account persistence. Rows: `voice-brain-session`.

**Drawing on screen**

15. **M15 Drawing engine core (JS).** Runner, primitives, geometry, layout check, timing table, SVG painter; golden and determinism tests in Node. Rows: `draw-runner`, `draw-svg-painter`, `draw-api` (engine primitives).
16. **M16 Native drawing host.** JavaScriptCore host with a wall-clock watchdog, bridge and DOM shim, render ops, Core Animation painter, Core Text shaper, transparent canvas window per display. Rows: `draw-bridge`, `draw-ca-painter`.
17. **M17 Speech-paced drawing.** Pacer and stream, voice line start and duration events, drawing coordinator fed by the brain stream, OpenClicky's own drawing-skill prompt. Rows: `draw-pacer`, `draw-generation`.
18. **M18 Pieces and pointers.** Screen-marking pieces, paper cards, action marks, `point`/`target`/`hover`/`onScreen` markers, coordinate mapper. Rows: `draw-api` (pieces), `point-onebrain`.
19. **M19 Buddy cursor and pen.** Overlay per screen, buddy actor, flights and bubbles, detach and dock, pen cursor and follower, stale watch. Rows: `overlay-buddy`, `overlay-pen`.
20. **M20 Editor, cards and captions.** Live editor and card-state text, card handles, buttons gated on beats, captions, drawing sound beds. Rows: `draw-editor`, `draw-captions`, `shell-audio-feedback` (sound beds).
21. **M21 Context readers.** Browser URL, active document, focus and selection, call and quiet detection, region capture, settle sampler, system-UI yield. Rows: `screen-context`, `screen-focus-quiet`, `screen-capture-variants`, `screen-capture-policy`.
22. **M22 Draw-to-ask and guided walkthroughs.** Highlighter and gesture description, AX region harvest, guided target loop with AX snapping and follow-up turns, tag parser for the classic grammar. Rows: `screen-draw-to-ask`, `point-guided`, `point-tags`.
23. **M23 Photos and widgets** (investigate widget UI first). Image-search slot and photo loader with public-host and people guards, favicons, places (MapKit), stock data, widget renderers, response cards. Rows: `draw-photos`, `lookup-widgets`, `voice-text-chat` (cards).

**Voice completeness**

24. **M24 Mic hardening.** Duplex echo-cancelled engine with probe and verdict cache, Bluetooth hold, health monitor and failover, trouble notice. Rows: `voice-mic`.
25. **M25 Dictation.** Focus context, hold and hands-free controller, streaming STT, cleanup on `brain.fast`, inserter chain with secure-input refusal, correction learner, daily archive. Rows: `voice-dictation`.
26. **M26 Voice settings.** Voice catalog, speed, languages and region hints, preview generation and cache, provider diagnosis. Rows: `voice-picker`, `voice-provider-diagnosis`.

**3D figures**

27. **M27 3D kernel.** Own three.js slice, part builders, typed-array packing, framing samples, Swift kernel host with cache; golden recipe tests. Rows: `3d-kernel`.
28. **M28 Figure authoring.** `figure()` and `scene3d()` on the 2D mark sink, mark schemas, tick bridge with pose packing. Rows: `3d-figure-api`, `3d-tick`.
29. **M29 Stage and illustrated look.** Scene model, stage (Metal layer, frame pipeline, paper, labels, leaders), illustrated renderer, id-grid picking readback, GPU fallback and capability line. Rows: `3d-scene-model`, `3d-stage`, `3d-illustrated`.
30. **M30 Studio look.** Environment bakes, shadows, SSAO, PBR, tone mapping. Rows: `3d-studio`.
31. **M31 Figure interaction.** Handle panel, drag to orbit, click to ask turn. Rows: `3d-picking`.
32. **M32 Lessons** (investigate recorder, printer and video first). Save, replay, print, video export, recent drawings. Rows: `draw-lessons`.

**Background agents**

33. **M33 Agent runner.** TypeScript runner (token HTTP, event ring, long-poll, driver registry) plus Swift process, client and event projector. Rows: `agent-runner`.
34. **M34 Agent loop and tools.** Local job server and durable workflow engine, Responses and Messages adapters, compaction, tool set including code-mode exec, local runtime policy settings. Rows: `agent-loop`, `agent-tools`, `agent-compaction`, `agent-anthropic`, `agent-auth-policy`.
35. **M35 Jobs and results.** Job folders and index, final-message parser, result cards, HUD and rail, task assets. Rows: `agent-jobs`, `agent-final-message`, `agent-hud`, `agent-task-assets`.
36. **M36 Brain and agents together.** Agent-control brain tools and context notes, job report turns, launch labels, Clickys roster and workspace memory, organizer. Rows: `agent-brain-tools`, `voice-job-reports`, `agent-launch-labels`, `agent-clickys`, `agent-works-shelf` (investigate first), `pro-organizer`.
37. **M37 Loopback MCP.** Loopback HTTP and MCP server, agent MCP endpoint config and token injection. Rows: `mcp-loopback`.
38. **M38 Browser bridge (app side).** Native host helper, manifests, transport and credentials, coordinator, `browser` tool, browser skill. Rows: `browser-host`, `browser-manifests`, `browser-transport`, `browser-coordinator`, `browser-tool`, `browser-skill`.
39. **M39 Chrome extension and setup.** MV3 extension (snapshot, actions, debugger input, tab groups, cursor, Stop), setup flow and settings, brain-driven setup help. Rows: `browser-extension`, `browser-setup`.
40. **M40 Take-over drive** (investigate actuator first). Consent card, actuator, `computer_calls` with screenshot outputs, input blocker, drive overlay, `mac_step` consent; optional grounding adapter. Rows: `agent-takeover`, `point-grounding`.
41. **M41 Routines and bookkeeping.** Local routine scheduler (absorbing Remote Tasks), notifications inbox, local usage ledger. Rows: `agent-routines`, `agent-remote-tasks`, `agent-notifications`, `shell-usage`.

**Apps, memory, full voice and product surfaces**

42. **M42 Integrations hub.** Custom MCP connectors with OAuth, Obsidian, connector provider protocol with an optional Composio adapter, agent connected-apps session and prompt section, integration skills, brain read-only app reads. Rows: `apps-custom-connectors`, `apps-obsidian`, `apps-catalog`, `apps-agent-mcp`, `apps-integration-skills`, `apps-read-connected`.
43. **M43 Memory.** Local profile and `about-the-user.md` mirror, standing context, learned how-tos, save/recall/forget. Rows: `mem-profile`, `mem-voice-tools`.
44. **M44 Full voice.** Realtime sub-slot session (always-on with VAD and echo gates), tool dispatcher, higher-model delegate on `brain.main`, realtime image adapter; legacy prompt profiles folded into brain adapters. Rows: `voice-full-realtime`, `voice-higher-model`, `point-realtime-attach`, `voice-legacy-chat`.
45. **M45 Voice app tools.** Calendar via EventKit and the meeting countdown, Spotify play with fallbacks and verification. Rows: `apps-calendar`, `apps-spotify`.
46. **M46 Skills.** Local skills library and index, creation as an agent job, active skills for voice and agents, onboarding skill picker. Rows: `skills-library`, `skills-active`, `skills-onboarding-picker`, `skills-bundled-agent`.
47. **M47 Home and history.** Home space, chat window, all settings pages and model pickers, conversation and hand-off history, agent thread cache and turn journal. Rows: `shell-home`, `shell-settings`, `hist-conversation`, `hist-agent-cache`.
48. **M48 File previews** (investigate first). Markdown, XLSX/CSV grid, PDF, QuickLook, web snapshot, animated images. Rows: `file-previews`.
49. **M49 Ink notes and agent output UI** (investigate first). Note dialect parser, linter and renderer, note actions back to the agent, edge deck, arc card, result and sticky cards. Rows: `agent-ink-notes`.
50. **M50 Onboarding.** Intro flow, tutorial, interview on the realtime sub-slot, starter plan on `brain.main`, drawn tour and finale. Rows: `onb-intro`, `onb-tour`, `onb-interview`, `onb-starter-plan`, `onb-drive-demo`, `onb-demo-reel` (investigate first), `agent-clicky-interview` (investigate first).
51. **M51 Proactive.** Suggestions engine as a local agent job, morning invitation and drawn brief, dwell-based suggestion monitor. Rows: `pro-suggestions`, `apps-suggestion-monitor`.
52. **M52 Hand-off** (investigate first). Attach target, region select, paste-and-Return and typing delivery, hand-off log. Rows: `handoff`.
53. **M53 Characters and full UI kit** (investigate first; original art). Portraits, actor states, sketch and gel kits. Rows: `ui-character`, `ui-kit`.
54. **M54 Updates and diagnostics.** Sparkle with OpenClicky's appcast and idle-install policy, local diagnostics bundle, optional opt-in crash reporting. Rows: `shell-updates`, `shell-telemetry` (replacement), `shell-announcements` (investigate first).
55. **M55 Optional runtimes and renderers.** Codex app-server as a second `AgentRuntime` adapter (can move earlier, after M35, if wanted), Metal canvas renderer, cloud agent worker. Rows: `agent-codex`, `draw-metal-canvas`, `agent-cloud`, `agent-file-diffs` (investigate first).

**Scope exclusions:** `shell-billing`, `shell-referral`, `shell-remote-config`. Their user-visible effects are covered by the local usage ledger (`shell-usage`) and local settings.

---

## 6. Gaps found by completeness review

A completeness pass on 2026-10-30 checked this inventory and the nine reader docs against the 1.1.2 (build 69) snapshot. It was read-only, with no network calls; scratch dumps sit outside the repo. The sweep compared every artifact class below with the docs, then mapped each source file to a parity row. Nine rows were added (§6.2). Each added row initially had `not started` status and cites its evidence. Its current status is in §1 and parity-status.md. Anything that static analysis cannot settle is listed in §6.5.

### 6.1 What was swept

| artifact | count | result |
|---|---|---|
| `HeyClicky/*.swift` `#file` strings in `Contents/MacOS/HeyClicky` (`strings -n 6 -a`, both slices) | 268 unique files | All 268 map to a row (§6.4). 265 map to reader-pass rows. Three needed new rows: `ClickyAppStore.swift` (`agent-works-shelf`), `CompanionManager+OnboardingDrive.swift` (`onb-drive-demo`) and `DictationAnnouncementWindow.swift` (`shell-announcements`). 116 files are named only in [01](re/01-type-map.md) and appear in no deep reader. They sit under the not-yet-investigated rows or under broad rows such as `shell-notch` and `shell-home`. |
| Top-level Swift types (01's reflection list) | 1,897 names | Every name appears in at least one doc, mostly in 01 Appendix A. The names are all covered, but behaviour is not (see the not-yet-investigated rows). |
| `Contents/Resources` files | 219 (including the PostHog and PLCrashReporter bundle files) | All are listed in [01 §5](re/01-type-map.md#5-resources-inventory-observed-contentsresources). Each runtime resource maps to a row. Sounds go to `shell-audio-feedback` and voice previews to `voice-picker`. Fonts go to `draw-ca-painter`. The draw and three.js scripts go to `draw-*` and `3d-*`. `ClickyIntegrationSkills/` goes to `apps-integration-skills` and the Hermes `*.md` files to `skills-onboarding-picker`. `ClickyBundledSkills/` goes to `browser-skill` and to the new `skills-bundled-agent`. `ClickyModelInstructions.md` and `ClickyCodexModelCatalog.json` go to `agent-codex`. The browser extension id, setup page and host version file go to `browser-setup` and `browser-host`. The intro video and tutorial music go to `onb-intro` and `onb-demo-reel`. `clicky-spatial-demo.mp4` goes to `onb-intro` (draw-to-ask step). `clicky-drive-sample.mp4` and `clicky-preview-photo.jpg` go to `onb-drive-demo`, `paywall-intro-v2.mp4` to `shell-billing`, and `Assets.car` to `ui-character`, `apps-catalog` and `onb-intro`. `AGENTS.md`, `LICENSE` and `ATTRIBUTION.md` are not used at runtime. No literal reference was found for `eshop.mp3` or `codex-add-project.png` (§6.5). |
| Route and URL strings in MAIN | 82 path or URL matches | Every server route is already in [§3](#3-server-routes). The non-route matches break down as follows. `/agents/` is the per-Clicky workspace folder. `%@/api/%@/` and `localhost:8969/stream` belong to the Sentry SDK. `mcp.facebook.com/ads` is placeholder text in the custom-connector form. `127.0.0.1:4173` appears inside a demo-reel agent brief. The WhatsApp, Canny, changelog, Reddit and team-site links belong to `shell-remote-config` and `shell-settings`. `icons.duckduckgo.com/ip3/` serves favicons (`draw-photos`). `google.com/maps/search/` gives meeting directions (`apps-calendar`). `mail.google.com/mail/` is the bug-report compose fallback (`shell-telemetry`) and one demo-reel cue. |
| Routes in `Helpers/clicky-harness` | 6 Worker paths, 12 local paths | The Worker paths are `/agent/openai/v1/responses`, `/v1/responses/compact`, `/agent/harness/model/anthropic/v1/messages`, `/agent/web-search` and `/agent/harness/lab/h1[/probe]`. The local paths are `/jobs/{id}/{start,turn,steer,interrupt,cancel,answer,files,events,blob}`, `workspace.tgz`, `/health`, `/turn`, `/steer`, `/cancel`, `/prewarm` and `/events`. All are covered by §3 and [06 §5](re/06-agent-harness.md#52-process-launch-and-the-runner-protocol). `/api/hello` and `/api/users/:id` are Bun documentation samples. |
| Strings in `Helpers/ClickyBrowserHost` | — | Its only app link, `heyclicky://settings/browser`, is now covered by the new `shell-url-router` row. |
| `clicky.*` UserDefaults keys | 105, of which 53 appear in no doc | All map to existing rows, except the keys behind the new rows. `integrationSuggestions.*` goes to `apps-suggestion-monitor`. `morningGreeting.*`, `morningSuggestions.*`, `proactiveAgents.*`, `approvedTaskQueue`, `agentSpace.suggestionJob` go to `pro-suggestions`. `starterAgents.*` goes to `onb-starter-plan` and `agent-clickys`. `codex.{completionTimestamps,hiddenThreadIDs,userInputFilePaths}ByThreadID` go to `hist-agent-cache` and `agent-task-assets`. `codexAgent.*` goes to `agent-loop`, `heyClickyWindow.*` and `homeSpace.*` to `shell-home`, `ink.sheet*` and `notePaperColors` to `agent-ink-notes`, `jobNames.*` to `agent-jobs` and `portrait.*` to `ui-character`. `documentAccess.noticeSuppressed` goes to `screen-context`, `firstVoiceTurnCompleted`, `tutorial.micCheck` and `upgrade.skipOnboardingVideo` to `onb-intro`, `customConnector.secretsFallback` to `apps-custom-connectors`, `cursor.docked.forceUndockMigration` to `overlay-buddy` and `debug.agentTurnCosts` to `shell-usage`. The checkout and referral keys go to the out-of-scope rows. The new rows take `codex.fileDiffsByThreadID` (`agent-file-diffs`), `clickyApps.*` (`agent-works-shelf`) and `dictationAnnouncement.*` (`shell-announcements`). |
| `Clicky*` preference and flag keys | 67, of which 41 appear in no doc | Collected under the new `shell-feature-flags` row. |
| Bracketed log tags | 127, of which 31 appear in no doc | All belong to existing rows, for example `[starter-agent]`, `[clicky-organizer]`, `[lease/poll]`, `[Home tour beat]`, `[tour-visibility]`, `[agent-launch-timing]`. The onboarding cue log lines led to `onb-demo-reel`. |
| Voice-brain and realtime tool names (the tool-name lists in MAIN) | — | All are named in 02, 06 or 08. `exec_command` appears only as a Codex activity label. |
| Entitlements (MAIN, harness, host) | — | They match 01 §3.1. |
| User data dir `~/Library/Application Support/Clicky` | 11 top-level entries | All are in 01 §12. Paths seen only as strings are missing from that map: `ClickyApps/works.json`, `Drive/`, `~/Movies/Clicky`, `CodexHome/sessions`, `Lessons/`. None of them exist on this Mac. |

### 6.2 Rows added

| id | why the reader pass missed it | joins |
|---|---|---|
| `onb-demo-reel` | 08 §6.1 treats the intro video as playback only. The strings next to `CompanionManager+OnboardingTutorial.swift` show cues timed to the video that open sites and launch canned demo agent jobs. | M50 (investigate first) |
| `onb-drive-demo` | 03 §9 names the `clickyDrive` step, but no row owned the scripted QuickTime and Preview automations or their bundled sample media. | M50 |
| `agent-clicky-interview` | 08 §6.2 mentions only the leave note. Analytics and prompt-context strings show a Home flow that interviews the user and then founds or routes a Clicky. | M50 (investigate first) |
| `agent-works-shelf` | `ClickyAppStore.swift` and the `ClickyWork*` types were only listed in 01. The works index and the edge-dock pin keys had no row. | M36 (investigate first) |
| `agent-file-diffs` | It is a developer-preview path that appears only as type names and defaults keys. | M55 (investigate first) |
| `skills-bundled-agent` | The `vercel-deploy` bundled skill was named in 08 §3.3 and 06 but owned by no row. `browser-skill` covers only `clicky-browser`. | M46 |
| `shell-url-router` | The URL handling was split between `shell-auth`, `apps-catalog` and `browser-setup`. The `clicky:` in-app link scheme and the browser host's settings link had no owner. | M01 |
| `shell-announcements` | `DictationAnnouncementWindow.swift` and `ClickyAnnouncementPreferences` were only in 01. | M54 (investigate first) |
| `shell-feature-flags` | About 40 `Clicky*` flag keys appear in no reader doc, and some of them (Library mode, Stream mode) gate user-visible behaviour of unknown purpose. | M01 (investigate first) |

The new rows also appear in the §2 "Used by" lists (`agent-clicky-interview` under `voice.realtime`; `skills-bundled-agent` and `onb-demo-reel` under `agent`) and in the §5 milestone row lists.

### 6.3 Scope notes for existing rows (no new row needed)

- `onb-starter-plan`: during the reveal, the voice narrates one "Home tour beat" per Clicky. Before narrating, it checks that the notch panel is actually visible, using its occlusion state and covered fraction. OBSERVED log tags: `[reveal]`, `[Home tour beat]`, `[tour-visibility]`. 08 §6.3 describes the reveal but not the visibility check.
- `pro-suggestions`: a suggestion card can be adjusted before approval by holding the talk key and speaking the change (`[Adjusting this suggestion]`). An approved repeating suggestion runs at once as run 1 of a routine. The morning brief has a "morning paper" variant (`ClickyMorningPaperEnabled`, `readsForMorningPaper`) rendered as an ink front page (`ClickyInkFrontPage*`).
- `shell-telemetry`: before export, the diagnostics snapshot scrubs token-like text: OAuth token parameters, JWT-shaped strings, bearer headers and provider-key prefixes. It also records install location and App Translocation. OpenClicky's local diagnostics bundle should do the same.
- `shell-app`: login-item registration happens only on first launch.
- `agent-loop`: steering acknowledgements play a tapback chime (`steerTapback`). 02 lists the sound mapping.

### 6.4 Source file to row map

Each of the 268 `HeyClicky/*.swift` files maps to exactly one primary row (`.swift` omitted). The table lists only rows that own at least one file. Many server-mediated rows share files with others, for example `OneBrainVoice` and `RealtimeVoiceClient`.

| row | count | source files |
|---|---|---|
| `3d-illustrated` | 1 | `DaVinci3DRenderer` |
| `3d-picking` | 1 | `ScreenDrawing3DHandle` |
| `3d-scene-model` | 2 | `DaVinci3DGeometry`, `DaVinci3DScene` |
| `3d-stage` | 1 | `ScreenDrawing3DStage` |
| `3d-studio` | 1 | `DaVinci3DStudioRenderer` |
| `agent-clickys` | 2 | `ClickyAgentIconView`, `ClickyRoster` |
| `agent-codex` | 3 | `CodexAgentSession`, `CodexProtocolClient`, `CodexRuntimeBridge` |
| `agent-hud` | 5 | `CodexLaunchFlight`, `CodexLaunchFlightLayerPlayer`, `CompanionManager+AgentCommentaryStream`, `NotchAgentFileIndex`, `NotchAgentSurface` |
| `agent-ink-notes` | 23 | `ClickyArcCard`, `ClickyCardParts`, `ClickyEdgeDeck`, `ClickyEdgeShelf`, `ClickyEdgeStackInkCard`, `ClickyInkActionsStore`, `ClickyInkConnections`, `ClickyInkDashboardObjects`, `ClickyInkDocument`, `ClickyInkEdgeNotes`, `ClickyInkFrontPageForm`, `ClickyInkInteractiveObjects`, `ClickyInkLive`, `ClickyInkNotePages`, `ClickyInkNoteStore`, `ClickyInkObjects`, `ClickyInkSketch`, `ClickyInkText`, `ClickyLiveNotes`, `ClickyLiveSteps`, `ClickyResultCardFace`, `ClickyStickyNotes`, `CompanionManager+InkConnect` |
| `agent-jobs` | 3 | `ClickyJobUserSteps`, `ClickyJobs`, `ClickyWorkFolderFiles` |
| `agent-launch-labels` | 1 | `CompanionManager+CodexAgent` |
| `agent-notifications` | 1 | `CompanionManager+AgentNotifications` |
| `agent-remote-tasks` | 1 | `CompanionManager+AgentCrons` |
| `agent-routines` | 2 | `CompanionManager+ClickyRoutines`, `HomeSpaceRoutinesSettings` |
| `agent-runner` | 2 | `AgentHarnessRunnerRuntime`, `CompanionManager+CodexAgentTurn` |
| `agent-takeover` | 7 | `ClickyBackgroundCursorControl`, `ClickyDriveNotchState`, `ClickyTakeOver`, `ClickyTakeOverOverlay`, `ClickyUserInputBlocker`, `CompanionManager+ClickyAppDrives`, `CompanionManager+ComputerUseConsent` |
| `agent-works-shelf` | 1 | `ClickyAppStore` |
| `apps-catalog` | 2 | `HomeSpaceIntegrationConnectionFeedback`, `IntegrationLogoArtwork` |
| `apps-custom-connectors` | 4 | `ClickyCustomConnectorCapabilityDeriver`, `ClickyCustomConnectorOAuthClient`, `HomeSpaceCustomConnectorDraftStore`, `HomeSpaceCustomConnectorsSettings` |
| `apps-suggestion-monitor` | 1 | `IntegrationSuggestionMonitor` |
| `browser-coordinator` | 1 | `ClickyBrowserBridge` |
| `browser-setup` | 2 | `ClickyChromeSetupFlow`, `HomeSpaceBrowserConnectionSettings` |
| `draw-api` | 1 | `ScreenDrawingActionButtons` |
| `draw-bridge` | 2 | `ScreenDrawingCanvas`, `ScreenDrawingNativeEngine` |
| `draw-ca-painter` | 4 | `ScreenDrawingCSSColor`, `ScreenDrawingClock`, `ScreenDrawingNativePainter`, `ScreenDrawingTextShaper` |
| `draw-captions` | 2 | `ScreenDrawingLiveCaption`, `ScreenDrawingNativeCaption` |
| `draw-editor` | 2 | `ScreenDrawingCardDragHandles`, `ScreenDrawingPinnedCards` |
| `draw-generation` | 1 | `CompanionManager+Annotation` |
| `draw-lessons` | 9 | `ClickyDrawingVideoRecorder`, `ClickyDrawingWindowViewer`, `ClickyLesson`, `ClickyLessonInlinePlayer`, `ClickyLessonPlayer`, `ClickyLessonPlayerControls`, `ClickyLessonPrinter`, `ClickyLessonRecorder`, `ClickyRecentDrawings` |
| `draw-metal-canvas` | 4 | `ClickyCanvasBaker`, `ClickyCanvasRenderer`, `ClickyCanvasScene`, `ClickyCanvasView` |
| `draw-photos` | 2 | `ImageSearchAPI`, `ScreenDrawingPhotoLoader` |
| `file-previews` | 10 | `DocumentAnimatedImageView`, `MarkdownViewerContentView`, `MarkdownViewerTableView`, `NotchDocumentViewer`, `SpreadsheetGridLayout`, `SpreadsheetGridRenderer`, `SpreadsheetGridView`, `SpreadsheetNumberFormat`, `SpreadsheetPreview`, `SpreadsheetXLSXReader` |
| `handoff` | 8 | `HandoffIndicatorWindow`, `HandoffManager`, `HandoffRegionSelectDimLayers`, `HandoffRegionSelectOverlay`, `HandoffVoiceStopWindow`, `NotchHandoffSurface`, `NotchHeyClickyChatHandOffRow`, `TextInjectionDelivery` |
| `hist-agent-cache` | 2 | `ClickyPlanMotion`, `ClickyRestartInterruptions` |
| `hist-conversation` | 2 | `HeyClickyChatHandOffs`, `HeyClickyConversationHistory` |
| `lookup-widgets` | 5 | `PlaceDetailOverlay`, `PlaceSearchAPI`, `PlaceWidget`, `StockQuoteAPI`, `StockWidget` |
| `mcp-loopback` | 1 | `ClickyLoopbackMCPServer` |
| `mem-profile` | 1 | `ClickyLearnedHowTos` |
| `onb-drive-demo` | 1 | `CompanionManager+OnboardingDrive` |
| `onb-interview` | 2 | `InterviewThoughtBubbles`, `OnboardingInterviewPage` |
| `onb-intro` | 5 | `CompanionManager+OnboardingTutorial`, `IntroHatchFlightOverlay`, `OnboardingIntroLayout`, `OnboardingTutorialPerformanceViews`, `OnboardingTutorialWindow` |
| `onb-starter-plan` | 2 | `CompanionManager+OnboardingStarterPlan`, `OnboardingStarterPlanClient` |
| `onb-tour` | 2 | `ClickyTourJobCards`, `CompanionManager+DrawnOnboardingTour` |
| `overlay-buddy` | 6 | `ClickyPointerEvaluationDriver`, `ClickyPointerEventSource`, `OverlayCursorPerformanceController`, `OverlayCursorStage`, `OverlayCursorSystemVisibilityMonitor`, `OverlayWindow` |
| `overlay-pen` | 3 | `ScreenDrawingPenCursor`, `ScreenDrawingPenFollower`, `ScreenDrawingStaleWatch` |
| `point-grounding` | 1 | `ElementLocationDetector` |
| `point-tags` | 2 | `AnnotationOverlay`, `ScreenAnnotationManager` |
| `pro-organizer` | 1 | `CompanionManager+ClickyOrganizer` |
| `pro-suggestions` | 4 | `CompanionManager+Proactive`, `GoodMorningBrief`, `NotchMorningSuggestionsSurface`, `ProactiveAgentsClient` |
| `screen-capture-policy` | 3 | `ClickySystemWindowPickerYield`, `ClickyWindowCapturePolicy`, `NotchSystemOverlayCoordinator` |
| `shell-announcements` | 1 | `DictationAnnouncementWindow` |
| `shell-app` | 5 | `AppBundleConfiguration`, `CompanionManager`, `GeneratedAssetSymbols`, `WindowPositionManager`, `leanring_buddyApp` |
| `shell-audio-feedback` | 2 | `ClickyChimeWarmer`, `SystemAudioOutputVolume` |
| `shell-auth` | 3 | `AccountDeletionClient`, `AccountDeletionPanel`, `SupabaseAuthManager` |
| `shell-billing` | 4 | `AgentPaywallHUDWindow`, `BillingClient`, `ClickyUsageCardPopover`, `PaywallCardContent` |
| `shell-home` | 12 | `HeyClickyWindow`, `HeyClickyWindowConversation`, `HeyClickyWindowOpeningFlight`, `HomeSpaceAmbientLayerViews`, `HomeSpaceArtifactCards`, `HomeSpaceCardViews`, `HomeSpaceConversationTranscript`, `HomeSpaceCoworkTranscript`, `HomeSpaceFocusPane`, `HomeSpaceOutputPreviewColumn`, `HomeSpaceSuggestionsPage`, `HomeSpaceViewModel` |
| `shell-hotkeys` | 3 | `ClickyHotkeyConfiguration`, `ClickyHotkeyRecorder`, `CompanionManager+EscapeInterrupt` |
| `shell-notch` | 14 | `ClickyNotchTabs`, `ClickyNotchUpdateSurface`, `CompanionManager+NotchSurfaces`, `NotchActivitySurface`, `NotchCornerGlowRenderServer`, `NotchGelActionButtonStyle`, `NotchHeyClickyChatDrawingRow`, `NotchHeyClickyPeekSurface`, `NotchHoverTickScheduler`, `NotchLoopLayers`, `NotchPresenter`, `NotchRootView`, `NotchStripPerformanceSupport`, `NotchWindowManager` |
| `shell-permissions` | 4 | `AgentPermissionsInspector`, `CompanionManager+PermissionFlow`, `PermissionFlowCoordinator`, `PermissionGuideAssistant` |
| `shell-referral` | 2 | `HomeSpaceReferralPage`, `ReferralProgramModel` |
| `shell-remote-config` | 2 | `AppRemoteConfig`, `CompanionManager+DiscoveryChannel` |
| `shell-settings` | 3 | `HomeSpaceSettingsContent`, `HomeSpaceSettingsPage`, `NotchSettingsTab` |
| `shell-telemetry` | 1 | `ClickyAITracing` |
| `shell-usage` | 2 | `ClickyAgentTurnCostLedger`, `CompanionManager+EarlyStopRefund` |
| `skills-active` | 2 | `ClickyPowerUp`, `PowerUpSkillFileStore` |
| `skills-library` | 3 | `ClickySkillLibraryBackend`, `PowerUpAvatarView`, `PowerUpPanelWindow` |
| `ui-character` | 8 | `ClickyClassicCloudPortrait`, `ClickyCloudPortrait`, `ClickyInteractivePortrait`, `ClickyKiCrewHair`, `ClickyPortraitAppearance`, `ClickyStorybookPortrait`, `CompanionActorRenderer`, `HomeSpaceCloudFaceView` |
| `ui-kit` | 7 | `ClickyMorphingText`, `ClickyPaperGlyphs`, `ClickyPaperPieces`, `ClickySketchKit`, `ClickyTextMotionExamples`, `CoreAnimationShimmerSweep`, `DesignSystem` |
| `voice-apple-speech` | 1 | `AppleSpeechTranscriptionProvider` |
| `voice-brain-session` | 1 | `OneBrainVoice` |
| `voice-brain-tools` | 1 | `OneBrainToolCalls` |
| `voice-captions-ui` | 1 | `CoreAnimationVoiceWaveform` |
| `voice-dictation` | 8 | `CompanionManager+Dictation`, `DictationCorrectionLearner`, `DictationFocusContext`, `DictationGeminiTranscriber`, `DictationInsertion`, `DictationTranscriptionClient`, `NotchDictationClipboardSurface`, `NotchDictionaryLearnedSurface` |
| `voice-ears` | 1 | `OneBrainGeminiTranscriber` |
| `voice-job-reports` | 1 | `OneBrainJobReports` |
| `voice-latency` | 1 | `OneBrainStatsHUD` |
| `voice-legacy-chat` | 2 | `ClaudeAPI`, `OpenAIAPI` |
| `voice-mic` | 4 | `ClickyAudioBufferConversion`, `NotchMicrophoneTroubleSurface`, `RealtimeDuplexAudioEngine`, `RealtimeMicrophoneCapture` |
| `voice-mouth` | 2 | `GeminiMouthProtocol`, `RealtimeVoiceClient` |
| `voice-orchestrator` | 2 | `CompanionManager+RealtimeVoice`, `CompanionManager+ResponsePipeline` |
| `voice-picker` | 2 | `VoiceLanguageSuggestions`, `VoicePreviewStore` |
| `voice-playback` | 1 | `RealtimePlayer` |
| `voice-provider-diagnosis` | 1 | `RealtimeProviderAvailabilityDiagnosis` |
| `voice-text-chat` | 6 | `ClickyGrowingTextView`, `NotchChatResize`, `NotchHeyClickyChatTextRow`, `NotchTextInputSurface`, `NotchTextResponseSurface`, `ResponseCardOverlay` |

### 6.5 Still unanswerable from the client

These need runtime observation, traffic capture (under the [§4](#4-traffic-capture-checklist) rules) or a fresh investigation pass. Static strings cannot settle them.

- Demo-reel cue timestamps, and whether cues are also authored server-side (`onb-demo-reel`). They are held in stripped Swift.
- The new-Clicky interview's instructions and the step that turns answers into `new_clicky` fields (`agent-clicky-interview`). The text may come from the server.
- The behaviour of `ClickyLibraryModeEnabled` / `NotchLibraryModeSwitch`, `ClickyStreamMode`, `ClickyUseLegacyMenuBarPanel`, `ClickyTransparentPanesEnabled` and the diagnostics field `screenShareDemoModeEnabled` (`shell-feature-flags`).
- The `works.json` schema and ranking (`agent-works-shelf`), and the file-diff kinds and limits (`agent-file-diffs`).
- `eshop.mp3` and `codex-add-project.png` have no literal reference in MAIN. Swift stores strings of 15 bytes or fewer inline in code, so this does not prove they are unused. `steve.jpg` is referenced by name, but its use is unknown.
- `activity-timeline.sqlite` and `app-usage-timeline.sqlite`, read by `pro-suggestions`: their producer is still unknown (01 §14).
- Everything in §4, and the eleven reader-pass rows marked not yet investigated in §1.
