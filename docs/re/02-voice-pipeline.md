# 02 — Voice pipeline: talk keys, mic, ears, one-brain turn, mouth

Subsystem reverse-engineered from HeyClicky 1.1.2 (build 69), bundle `com.humansongs.clicky`, for a clean-room rebuild in OpenClicky. This document covers behavior, architecture, interfaces and data shapes. It contains no HeyClicky prompt text, JavaScript bodies or shader code.

## 0. Conventions and evidence sources

Each claim carries one of these tags:

- **[O] OBSERVED** means the claim was seen directly in an artifact.
- **[I] INFERRED** means it is reasoned from observed artifacts.
- **[U] UNKNOWN** means it cannot be recovered from the client, usually because it is server-side.

Short names for the evidence sources:

| Tag | Source |
|---|---|
| `BIN` | `HeyClicky-1.1.2-b69.app/Contents/MacOS/HeyClicky`, string dump (`strings -n 6`, arm64 slice) |
| `XL` | Code-ordered literal listing of the x86_64 slice. It resolves RIP-relative `lea` references into `__cstring`, so it shows which literals one function uses, in order. The JSON keys in this doc come from these clusters. |
| `FMD` | Swift reflection metadata (`__TEXT,__swift5_fieldmd`) of `BIN`, parsed to recover type names, stored-property names and enum cases. Types and fields below come from here. |
| `PLIST` | `Contents/Info.plist` and `codesign -d --entitlements -` |
| `RES` | `Contents/Resources/*` (sounds, voice previews) |
| `DATA` | `~/Library/Application Support/Clicky/...` (the user's own HeyClicky data; only shapes, key names and aggregate numbers were read) |
| `PREFS` | `~/Library/Preferences/com.humansongs.clicky.plist` (key names only; values only for non-secret voice settings) |

Swift source files that belong to this subsystem, as named in `BIN` [O]:

- `OneBrainVoice.swift`
- `OneBrainGeminiTranscriber.swift`
- `OneBrainToolCalls.swift`
- `OneBrainJobReports.swift`
- `OneBrainStatsHUD.swift`
- `RealtimeVoiceClient.swift`
- `RealtimeMicrophoneCapture.swift`
- `RealtimeDuplexAudioEngine.swift`
- `RealtimePlayer.swift`
- `RealtimeProviderAvailabilityDiagnosis.swift`
- `GeminiMouthProtocol.swift`
- `CompanionManager+RealtimeVoice.swift`
- `CompanionManager+Dictation.swift`
- `CompanionManager+EscapeInterrupt.swift`
- `DictationGeminiTranscriber.swift`
- `DictationTranscriptionClient.swift`
- `DictationFocusContext.swift`
- `DictationInsertion.swift`
- `DictationCorrectionLearner.swift`
- `AppleSpeechTranscriptionProvider.swift`
- `ClickyHotkeyConfiguration.swift`
- `ClickyHotkeyRecorder.swift`
- `ClickyChimeWarmer.swift`
- `ClickyAudioBufferConversion.swift`
- `CoreAnimationVoiceWaveform.swift`
- `ScreenDrawingLiveCaption.swift`
- `VoicePreviewStore.swift`
- `VoiceLanguageSuggestions.swift`
- `SystemAudioOutputVolume.swift`

### Correction to the brief

Build 69 contains no Deepgram code. [O] A case-insensitive search for `deepgram`, `nova-3`, `linear16`, `smart_format`, `/deepgram-token` and `/transcribe` finds nothing in `BIN` or the other bundle binaries. The only Deepgram hits are in third-party skill markdown under `DATA/CodexHome/.tmp/plugins`.

Build 69 uses this speech-to-text stack instead:

- **Primary:** Gemini Live streaming over `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained`, authenticated with a short-lived token from the Worker.
- **Fallback:** batch transcription by the Worker (`/brain/ears/transcribe`, `/v2/dictation/transcribe`).
- **Legacy:** the push-to-talk path (`BuddyDictationManager`) uses Apple's on-device Speech recognizer through `AppleSpeechTranscriptionProvider`.

The Deepgram routes in the brief probably come from an earlier version. [I]

---

## 1. Architecture overview

Build 69 has two voice architectures. Both share the mic, the audio player and the talk keys.

### A. "One brain" (default for hold-to-talk) [O]/[I]

The pipeline has three parts:

- **Ears:** streaming speech-to-text.
- **Brain:** one multimodal LLM turn on the Worker.
- **Mouth:** a separate realtime text-to-speech session that only reads lines aloud.

Logs are prefixed `🧠 [one brain]`, `[one brain ears]` and `[speech]`.

```
 talk keys down ──► mic capture ──► Ears (Gemini Live, warm socket) ──► interim text (notch live transcript)
      │                 │                                               │
      │                 └─► pressAudio buffer (for batch fallback)       │
      ├─► prompt-cache prewarm  POST /brain/prewarm (if idle & big)       │
      ├─► open/keep Mouth session  POST /agent/realtime/session          │
      └─► active document read (page/file) started at key-down            │
 talk keys up ──► finish ears (activityEnd) ──► final transcript ─────────┘
      │
      ▼
 screenshot(s) + [This turn] context + local thread ──► POST /brain/turn  (SSE stream)
      │                                                        │
      │  text deltas (a ```js drawing program with say("…") calls) ──► say-line extractor ──► Mouth (line by line)
      │  tool_calls / computer_calls ──► OneBrainToolRunner ──► function_call_output ──► next round /brain/turn
      │  items/meta/done ──► local thread + usage + turn_token
      ▼
 drawing engine runs the program (separate subsystem) while Mouth speaks each line, captions follow audio
```

The brain answers with a program, not prose. [O] Each assistant item in the saved thread is a fenced program (```` ```js ````) whose `say("…")` calls are the spoken lines (`DATA/OneBrain/<account>/threads/<session>.json`, regex `say\(\s*("(?:[^"\\]|\\.)*")` in `BIN`). The client pulls `say` strings out of the stream as they arrive, so the mouth can start speaking before the whole program has arrived. The timing metric `first_token_to_first_line_ms` measures this.

### B. "Full voice" (OpenAI Realtime speech-to-speech with tools) [O]

`RealtimeVoiceController` and `RealtimeVoiceClient` run a single `gpt-realtime-2.1` session. In that session:

- mic audio streams over the socket;
- OpenAI's server transcribes the user;
- the realtime model answers aloud and calls tools such as `send_to_higher_model`, `capture_screen`, `tutorial_draw_on_screen` and `read_connected_apps`.

Logs are prefixed `🎙️ [Realtime]`.

These surfaces still use full voice [I, from log/prompt clusters in `CompanionManager+RealtimeVoice.swift`]:

- always-on mode (triple-tap Control);
- the onboarding interview;
- the agent HUD's "Follow up → Voice";
- adjusting a suggestion;
- spoken announcements (`announceAgentEvent`);
- guided-annotation speech;
- page-driven turns.

The same `RealtimeVoiceClient` class also implements the one-brain mouth, selected by `RealtimeVoiceClientConfig.isOneBrainMouth`. The controller can retire a session of the wrong kind; the log reads "retiring a mouth/full voice session: this moment needs the other kind".

### Model and voice identifiers [O]

| Part | Identifier(s) |
|---|---|
| Brain model choices | `OneBrainModelChoice` enum (see the table after this one) |
| Mouth (OpenAI) | `gpt-realtime-2.1-mini`, which sits next to the one-brain code in `XL` |
| Full voice (OpenAI) | `gpt-realtime-2.1` |
| Mouth (Gemini voice) | `gemini-3.8-flash-lite-tts`, reached through Worker `/agent/realtime/speak` |
| Ears | Gemini Live `BidiGenerateContentConstrained`; the model id is inside the Worker-supplied `setup` [U] |

`OneBrainModelChoice` cases and their ids:

| Case | Model id |
|---|---|
| `sol` | `gpt-6.1-sol` |
| `solMedium` | `gpt-6.1-sol-medium` |
| `solFast` | `gpt-6.1-sol-fast` |
| `solUltrafast` | `gpt-6.1-sol-ultrafast` |
| `solUltrafastMedium` | `gpt-6.1-sol-ultrafast-medium` |
| `solUltrafastHigh` | `gpt-6.1-sol-ultrafast-high` |
| `terraFastMedium` | `gpt-6.1-terra-fast-medium` |
| `haiku` | `claude-haiku-5-5` |
| `sonnet` | `claude-sonnet-5-5` |
| `opus` | `claude-opus-5-5` |
| `deepSeekMedium` | `deepseek-v4.1-flash-medium` |
| `deepSeekHigh` | `deepseek-v4.1-flash-high` |

Notes on the brain model:

- The Developer settings describe "Sol at medium effort on Ultrafast" as the default. Plain `gpt-6.1-sol` is described as the default only until an October date. So in this build the default appears to be `solUltrafastMedium`. [O]
- The model choice lives in UserDefaults key `ClickyOneBrainModelKey` and is sent as `brain_model`.
- The server reports the base model in `usage.reported_model`. In the user's log every round reports `gpt-6.1-sol`. [O, DATA]

---

## 2. Talk keys (global shortcuts)

### Types [O, FMD]

- `ClickyShortcutSlot` has four slots: `voiceHold`, `textTrigger`, `dictationHold`, `handsFreeDictation`.
- `VoiceHoldShortcut` is Codable with keys `modifierMaskRawValue` (UInt, `NSEvent.ModifierFlags` raw), `keyCode` (optional) and `triggerKind`.
- `ClickyShortcutTriggerKind` is either `holdCombo` or `doubleTapModifier`.
- `ClickyHotkeyModifier` covers `control`, `option`, `command`, `shift` and `function`.

### Persistence [O]

Shortcuts are stored as JSON in UserDefaults under:

- `clicky.hotkeys.voiceHold.v1`
- `clicky.hotkeys.textTrigger.v1`
- `clicky.hotkeys.dictationHold.v1`
- `clicky.hotkeys.handsFreeDictation.v1`

Example of the stored shape on this machine (`PREFS`): `{"triggerKind":"doubleTapModifier","modifierMaskRawValue":8650752}`. The mask is Control plus Fn.

### Defaults [O from UI and onboarding strings, mask values I]

| Action | Default trigger |
|---|---|
| Voice (hold to talk) | Hold Control+Option. Onboarding and the model's own first reply tell the user to hold Control and Option. |
| Text input | Double-tap Control (log "Double-tap of control → opening text input") |
| Always-on voice | Triple-tap Control (user messages say "triple-tap control") |
| Dictation hold / hands-free dictation | Configurable. The default dictation-hold mask was not recovered [U]. |

Other notes:

- Legacy option enum `BuddyPushToTalkShortcut.ShortcutOption` has `shiftFunction`, `controlOption`, `shiftControl`, `controlOptionSpace` and `shiftControlSpace`. Its labels read "shift + fn", "ctrl + option", and so on.
- The recorder only accepts modifiers (Control, Option, Command, Shift, fn), never letters. It rejects combinations that clash with another HeyClicky shortcut ("That matches one of your HeyClicky shortcuts…").

### `GlobalPushToTalkShortcutMonitor` [O, FMD]

- It installs a `CGEventTap` (`globalEventTap` plus a run-loop source) for `flagsChanged`, `keyDown`, `keyUp` and mouse events. It adds a local `NSEvent` monitor (`keyEventLocalMonitor`) for when HeyClicky itself has focus.
- It publishes Combine streams:
  - `shortcutTransitionPublisher` (voice hold `pressed`/`released`)
  - `dictationShortcutTransitionPublisher`
  - `handsFreeDictationTogglePublisher`
  - `textTriggerPressedPublisher`
  - `alwaysOnVoiceModeTogglePublisher`
  - `shiftOptionTapPublisher`
  - `optionClickPublisher`
  - `mouseDownPublisher` and `leftMouseDownPublisher`
- Double and triple taps are detected by `ModifierDoubleTapDetector` (`pendingPressStartTime`, `pendingPressReachedFullSet`, `firstCompletedTapReleaseTime`). A `ModifierTapActivitySnapshot` holds `keyDownCount` and `scrollWheelCount`. A modifier tap that happened while the user was typing or scrolling is therefore not counted as a tap. [I]
- The mouse publishers during a hold drive "circle anything and ask". The user can draw a highlight while holding the keys, which becomes `OneBrainVoice.Highlight{gesture, textUnder}`. Onboarding copy says to hold the keys, circle something with the cursor, and ask. [O]
- Failure logs: "Global push-to-talk: couldn't create modifier/mouse event tap". The tap needs the Accessibility / Input Monitoring permission.

### Escape interrupt (`CompanionManager+EscapeInterrupt.swift`) [O]

- A second `CGEventTap` runs on its own thread (`com.humansongs.clicky.escape-interrupt-tap`, `EscapeInterruptTapThreadHandle`).
- On Escape it logs "Interrupting active HeyClicky work — stopping speech and cancelling tasks" and emits analytics `escape_interrupt`.
- `EscapeInterruptDecisionBox.shouldConsume` decides whether the key is swallowed. It is only swallowed when there is something to interrupt. [I]
- `suppressPushToTalkReleaseAfterEscape` stops a key-up that follows an Escape from sending a turn.

---

## 3. Microphone capture

There are two capture paths, plus Bluetooth handling and failover.

### 3.1 Legacy capture: `RealtimeMicrophoneCapture` [O]

- Built on `AVCaptureSession` with `AVCaptureAudioDataOutput`. Delegate queues are `com.humansongs.clicky.RealtimeMicrophoneCapture.{configuration,sampleBufferDelivery}`.
- Output is PCM16 mono chunks through `pcmChunkHandler`. Format conversion goes through `ClickyFormatKeyedAudioConverter`, which caches an `AVAudioConverter` per source-format key. Log on failure: "mic PCM16 converter init failed".
- Device selection:
  - UserDefaults key `selectedMicrophoneCaptureDeviceID` and notification `clickyMicrophoneSelectionDidChange`.
  - Options are modelled as `ClickyMicrophoneDeviceOption{id, displayName, subtitle, isSystemDefault, isAvailable}`.
  - Settings has a level-meter test (`ClickyMicrophoneTestController`).
- Liveness watchdog:
  - If no audible chunk arrives for **2.5 s**, the `AVCaptureSession` is rebuilt (log "legacy capture delivered no audible chunks for 2.5s … rebuilding AVCaptureSession").
  - After repeated silent windows the failure is surfaced: `legacy_capture_dead`, "microphone capture produced no audio".
  - Stall and all-zero detection: `capture_stalled`, `capture_went_all_zeros`.
  - `mic_capture_rebuild*` events and `onRebuildLadderExhausted` mark the end of the rebuild ladder.
- Teardown uses `CaptureSessionSafeTeardown.deferredRelease`, which releases the session on a deferred queue to avoid AVFoundation deadlocks. [I]

### 3.2 Echo-cancelled duplex: `RealtimeDuplexAudioEngine` [O]

- Built on `AVAudioEngine` with voice processing (AEC) enabled on the input node and an `AVAudioPlayerNode` for playback. Capture and playback share one engine so echo cancellation can see the reference signal.
- It is an upgrade over the legacy path, found by probing:
  1. The probe is scheduled with a trigger, limited per session (`duplexUpgradeAttemptsThisSession`, "duplex upgrade budget exhausted").
  2. Legacy capture pauses ("pausing legacy capture for sequential AEC bring-up") and the voice-processing engine starts.
  3. The probe fails if the engine is deaf: `deaf_at_start_no_chunks` or `deaf_at_start_all_zeros`.
  4. If the probe is proven but a session is busy, promotion waits for the next idle moment.
  5. On promotion the log reads "duplex AEC engine PROMOTED — echo-cancelled capture+playback active". If the promoted engine dies, it is demoted to legacy and re-probed in a lull.
- Verdicts are cached per audio-topology fingerprint (input + output devices). The cache lives in UserDefaults dict `RealtimeDuplexAECTopologyVerdicts`, with `TopologyAECVerdict` `promoted` or `zombie`. A "zombie" topology skips probing next time (`cached_zombie_topology`).
- Input pin policy `InputDevicePinPolicy` is `configuredSelection` or `systemDefaultOnly`. The engine pins the AUHAL input element to the chosen device UID, falling back to the default input.
- Errors (`DuplexEngineError`): `voiceProcessingEnableFailed`, `inputFormatInvalid(sampleRate, channelCount)`, `engineStartFailed`, `bringUpAbandoned`.
- Route changes produce `RouteChangeContext{reason, droppedBufferCount, previousOutputTransport, previousOutputDeviceName}` with reasons such as `default_device_changed`, `engine_configuration_change` and `engine_stopped_before_playback`.

### 3.3 Bluetooth handling [O]

- Starting capture on a Bluetooth headset forces it into the low-quality call profile. To avoid repeated profile flips, after a press the app keeps the Bluetooth capture session open with deliveries muted:
  - log: "mic deliveries muted — holding Bluetooth capture session open …", which explains that the headset should stay in its current audio profile;
  - fields `lingeringBluetoothMicrophone` and `lingeringBluetoothMicrophoneTask`.
- It closes the held session later, logging "closing the held Bluetooth mic (reason)". The lingering duration is not known [U].
- The chime player delays the "mic started" cue until the mic is actually running (`PendingMicrophoneStartCue`, logs "mic not running yet" and "mic running"). That way the cue is not lost in the route switch.
- It warms the output device with a longer lead-in on Bluetooth (`bluetoothAudioOutputWarmupLeadInTimeSeconds` versus `audioOutputWarmupLeadInTimeSeconds`).

### 3.4 Mic failover and dead air [O]

- **Failover.** When the selected device "proved dead" (stalled or all zeros), the client pins the built-in mic. Analytics `mic_capture_failover_to_built_in{from, to}`; field `microphoneFailover{deviceID, replacedSelection}`. A user change of selection in Settings drops the pin ("mic selection changed in Settings — dropping built-in failover pin").
- **No failover left.** The event is `mic_capture_irrecoverable`. The notch shows `MicrophoneTroubleNotice{title, subtitle, showsMicrophoneSettingsAction}` via `NotchMicrophoneTroubleSurface`.
- **Dead-air presses.** A hold produces either no audio ("N s hold, no audio from the mic") or only silence ("the mic delivered only silence"). The client counts these (`consecutiveDeadAirPressCount`) and escalates to the trouble notice. [I] Full voice logs `mic_capture_dead_air_turn`.
- **Overflow.** The send buffer has a soft cap (`pendingAudioAppendChunkSoftCap`); overflow logs "mic buffer overflow — dropping chunks past N".

### 3.5 Audio formats

- Mic chunks are PCM16 mono. [O]
- The Gemini ears declare `audio/pcm;rate=<N>`. [O] N is probably 16000 (Gemini Live's input rate), produced by `PCM16MonoResampler`. [I]
- OpenAI Realtime uses PCM16; 24 kHz is the platform default [I].
- Playback for both providers is PCM16 into `AVAudioPlayerNode` [O]. The output rate is not observed directly [U].

---

## 4. Ears: streaming speech-to-text

### 4.1 `OneBrainGeminiTranscriber` (shared by one-brain ears and dictation) [O, FMD + XL]

**Configuration fields:**

- `tokenProxyURL`, `languageCode`, `keyterms: [String]`
- `readyGraceSeconds`, `finalTimeoutSeconds` (values unknown [U])
- `makeSocket` (an injectable `OneBrainSpeechSocket` for tests)

**State fields:**

- `warming`, `ready`, `activityStarted`, `finishRequested`, `finishSent`, `ended`
- `pendingAudio`, `capturedBytes`, `bufferedAudioBytes`, `sentBytes`
- `finalSegments`, `interim`, `loudestLevel`, `mintedReceipt`
- timing points: `pressStartedAt`, `tokenReadyAt`, `readyAt`, `firstTextAt`, `finishCalledAt`, `finalReceivedAt`

**Protocol sequence** (key order from `XL`):

1. **Mint.** `POST <tokenProxyURL>` with `Authorization: Bearer <Supabase access token>`, `Content-Type: application/json` and `X-Clicky-Usage-Context`.
   - Body: `{language, keyterms}`.
   - Response keys: `access_token`, `setup` (an opaque Gemini Live setup message chosen by the server), `receipt`.
   - Token URLs: `/brain/ears/token` for the brain and `/v2/dictation/gemini-token` for dictation.
2. **Connect.** WebSocket to the Constrained `BidiGenerateContent` endpoint with header `Authorization: Token <access_token>`. Send `{setup: …}` exactly as received and wait for `setupComplete`.
3. **Stream.** Send `{realtimeInput:{activityStart:{}}}`, then `{realtimeInput:{audio:{data:<b64 PCM16>, mimeType:"audio/pcm;rate=N"}}}` chunks.
   - Audio captured before the socket is ready is buffered (`pendingAudio`) and flushed afterwards, so the first words are not clipped. [I]
   - The setup evidently turns off automatic voice-activity detection and uses manual activity markers. [I] (`activityStart`/`activityEnd` are observed [O].)
4. **Receive.** `serverContent.interimInputTranscription.text` gives interim text, shown live. `serverContent.inputTranscription.text` gives final segments. `goAway` and closes are handled. Speaker tags matching `</?speaker[^>]*>` are stripped.
5. **Finish.** On key-up send `{realtimeInput:{activityEnd:{}}}` and wait up to `finalTimeoutSeconds` for the final segments. The result is `OneBrainSpeechTranscript{transcript, audioSeconds, receipt?}`.

**Errors (user-safe strings in `BIN`):**

- "Speech final transcript timed out."
- "Speech audio upload stalled." (from `uploadWatchdog`)
- "Speech session was not ready."
- "Speech audio exceeded the supported format or duration."
- "Speech audio could not be resampled."
- "Gemini refused the speech session: …"

If the refusal text mentions `credit`, `billing`, `quota`, `exhausted`, `prepayment` or `payment`, the client logs "[speech] Gemini refused for its account; using the fallback for 10 minutes" and uses batch transcription for 10 minutes.

**Close log fields:** `purpose=` (`ears` or `dictation`), `phase=` (`connecting`, `warm_connecting`, `warm_idle`, `press_connecting`, `press`, `finishing`), `close=`, `reason=`, `open_for_s=`.

### 4.2 Warm sockets [O]

- One brain keeps a pre-connected ears socket, `OneBrainVoice.WarmEars{transcriber, languageCode, keyterms, usageContext, expiry}`. It wakes with the system (`warmEarsWakeObserver`). Keeping it warm is tied to recent use (`clicky.oneBrain.lastEarsUsedAt.v1`). [I]
- A press that lands on a warm socket logs "ears: on the warm socket"; otherwise the phase is `press_connecting`.
- Dictation has its own warm socket (`ClickyDictationController.WarmStreamingConnection{transcriber, languageCode, customWords, usageContext, expiryWorkItem}`). It also sends a periodic `HEAD https://generativelanguage.googleapis.com` network warm-up (`networkWarmupTimer`) and records `clicky.dictation.lastCompletedAt.v1`.

### 4.3 Batch fallback [O]

- One brain: `POST /brain/ears/transcribe` with body `{audio_wav_base64, language}` and header `X-Clicky-Usage-Context`. The client builds a RIFF/WAVE file from the whole press's audio (`pressAudio`). Response: `{text}`.
- Used when Gemini fails during a press ("Gemini failed; the press was heard by the fallback"), when the final transcript times out, or during the 10-minute refusal window.
- Outcome tags: `fallback`, `failed`, `silent`.

### 4.4 Ears timing (one log line per press) [O]

`⏱ [one brain ears] warm= outcome= held_ms= keydown_to_token_ms= keydown_to_ready_ms= keydown_to_first_text_ms= finish_to_final_ms= release_to_words_ms=`

The struct is `OneBrainGeminiTranscriber.PressTimings`.

### 4.5 Legacy Apple Speech path [O]

- `BuddyDictationManager` drives an `AppleSpeechTranscriptionProvider` (display name "Apple Speech"). It uses `SFSpeechAudioBufferRecognitionRequest` and handles `onTranscriptUpdate`, `onFinalTranscriptReady` and `finalTranscriptFallbackDelaySeconds`.
- It needs Speech Recognition permission ("speech recognition permission is required for push to talk.").
- Start sources: `microphoneButton` or `keyboardShortcut`. `contextualKeyterms` are passed in as hints.
- It is the older composer and push-to-talk path. A quick tap with no recognized text suppresses the error UI.
- In 1.1.2 the ears do not fall back to Apple Speech; they fall back to the Worker. [I]

---

## 5. The one-brain turn

### 5.1 Session state (`OneBrainVoice`, FMD) [O]

| Field | Meaning |
|---|---|
| `sessionID`, `sessionStartedAt` | Session id is a UUID |
| `thread: [[String: Any]]` | Local Responses-API item list sent with every turn |
| `userLayer`, `userLayerSignature`, `userLayerSkillsFingerprint` | Server-built "user layer" (persona, memory, skills) plus a signature. Sent back on later turns. Probably signed so the client cannot change it. [I] |
| `environmentSentForSessionID` | The `environment` object is sent once per session |
| `codeOfDrawingOnScreen` | Program of the drawing currently on screen, sent as `drawing_code` |
| `lastCanvasSize (width, height)` | Canvas in points, e.g. `[1280, 832]` [DATA] |
| `lastTurnInputTokens`, `sessionBaselineInputTokens`, `compactionNextCheckInputTokens`, `isCompacting`, `compactionGeneration` | Compaction bookkeeping |
| `sessionScreenshotFiles`, `screenshotFilesOffForSession` | Screenshot-by-reference ids, and a flag to send full images instead |
| `pendingAppNotes [(key,text)]` | `[App]` notes queued for the next turn |
| `pendingHighlight` | The user's drawn highlight plus the text under it |
| `pageReference` (`ActiveDocumentReference.webPage(fullAddress)` or `.file(fileURL)`), `pageReadTask` | Active document read started at key-down |
| `actionsWaitingForTheDrawing (sessionID, [ToolCall])` | Side-effect tools held until narration has been spoken |
| `advanceArmedUntil`, `advanceTask`, `automaticRestartsInARow` | Auto-advance for walkthroughs |
| `microphone`, `earsPressID`, `pressAudio`, `transcriber`, `transcriptWaiter`, `warmEars`, `heardAudioSecondsForNextTurn`, `pressWasRefused`, `lastPressEarsFailed`, `lastPressHeldSeconds` | Per-press state |
| `idleSessionEndTask` | Calls `/brain/session-end` after a period of inactivity [I: the duration is unknown] |

### 5.2 Persistence [O, DATA]

**Thread file:** `Clicky/OneBrain/<supabaseUserID>/threads/<SESSION-UUID>.json`

```json
{ "session_id": "<uuid>", "last_turn_at": <unix float>, "thread": [<items>],
  "user_layer": "<text>", "user_layer_signature": "<b64url>", "user_layer_skills": "<text>",
  "drawing_code": ["<program>"], "last_input_tokens": 88668, "baseline_input_tokens": 40166,
  "canvas": [1280, 832], "environment_sent": true }
```

**Thread items** use the OpenAI Responses-API shapes [O]:

- `{"type":"message","role":"developer","content":[{"type":"input_text","text":"[This turn] <HH:mm, weekday date>.\nFront app: <app>.\nPage open: <host>"}]}`. The per-turn note uses format `HH:mm, EEEE MMM d, yyyy`.
- `{"type":"message","role":"developer",…"[App] …"}`. These are app notes, for example "[App] The user cut this answer off here."
- `{"type":"message","role":"user","content":[{"type":"input_text","text":"<transcript>"}]}`. Images are added as `{"type":"input_image","image_url":"data:image/jpeg;base64,…"}` or as `{"type":"input_image","clicky_file":"<server file id>"}`.
- `{"type":"message","role":"assistant","phase":"commentary"|"final_answer","content":[{"type":"output_text","text":"```js\n…say(\"…\")…\n```"}]}`
- `{"type":"reasoning","id":…,"summary":[],"encrypted_content":…}`. Encrypted reasoning is carried between turns when the server returns `keep_reasoning`.
- `{"type":"function_call","call_id","name","arguments"}` and `{"type":"function_call_output","call_id","output"}`
- `{"type":"computer_call_output","call_id","output":{"type":"computer_screenshot","image_url":"data:image/jpeg;base64,…","detail":"original"}}`. Used when the brain drives the Mac (take-over).

**Saved threads omit screenshots** ("picked up N items, no screenshots"). The exception is developer toggle "Keep screens in history" (`ClickyOneBrainKeepsScreensInHistory`); even then only the newest N are kept ("more than N screenshots in the thread: kept the newest N"). A compaction note is a developer message with sections `GOALS:`, `OPEN TASKS:`, `DECISIONS AND CORRECTIONS:`, `FACTS:`, `NOTED:`, `SCREEN ACTIVITY:`, `DRAWN:`, `SCREENS:` [O, DATA].

**Turn log:** `Clicky/OneBrain/<user>/<SESSION-UUID>.jsonl`, one JSON object per line [O]:

- `{"kind":"round","at","session","round":0,"words","fact","code","tool_calls":[],"async_calls":[],"computer_actions":[],"usage":{…}}`
- `{"kind":"interrupted","at","session","words","fact","code","error"}`. For example, a cancelled `/brain/turn` (`NSURLErrorCancelled`) when the user pressed again.
- `{"kind":"tools","at","session","round","calls":[names],"asks_again":bool,"ms_after_turn_start"}`
- Other kinds in `XL`: `paywall` and `dropped_before_use` (with `error`).
- `usage` keys returned by the server: `input`, `cached`, `wrote`, `output`, `reasoning`, `cost`, `ttftMs`, `totalMs`, `webSearches`, `fastServed`, `reported_model`, `keep_reasoning`, `turn_token`, `screenshot_file`, `last_input`, `message_counted`, `message_recorded`, `turn_saved`.

**Session pickup:** at launch the newest saved session for the signed-in account is reloaded ("picked up session X again (N items, last turn M min ago)"). Otherwise a new session starts. Signing in as a different account starts clean ("another account signed in: starting clean"). Turns whose account changed mid-flight are discarded. A thread that cannot be encoded is not saved ("thread not saved: it isn't valid JSON").

### 5.3 Turn state machine (client) [O logs, I structure]

```
            ┌─────────────── Esc / new press / dismiss ───────────────┐
            ▼                                                         │
IDLE ──keydown──► LISTENING ──keyup──► TRANSCRIBING ──final──► CAPTURING ──► REQUESTING(round r)
  ▲                 │  ears interim → notch                 │ (screenshot +     │  SSE: meta,text,items,
  │                 │  prewarm cache, open mouth,           │  context)         │  status, tool_calls,
  │                 │  read active document                 │                   │  computer_calls, done
  │                 └─ press cancelled / nothing heard ──► IDLE (+message)      ▼
  │                                                                  SPEAKING/DRAWING
  │   ◄── narration done ── (deferred action tools run) ◄────────── say-lines → mouth; program → drawing
  │                                                                   │ sync tool results needed?
  │                                                                   └──yes──► REQUESTING(r+1, function_call_output) ≤ max_rounds
  └── auto-advance: user clicked/scrolled after a step ──► CAPTURING (trigger did_step)
```

`CompanionVoiceState` drives the UI: `idle`, `listening`, `processing`, `responding` [O, FMD].

**Key-down** [O/I]:

- Stop any current speech and drawing narration (barge-in, §8).
- Start the mic and attach the ears (warm socket or new connection).
- Start the live transcript task. Interim words fill `CompanionManager._livePushToTalkTranscript` in the notch.
- Ensure a healthy mouth session (`oneBrainMouthSessionOpeningCount` deduplicates concurrent opens).
- Run the prompt-cache prewarm if the session has been idle a while and the conversation is large: "cache warming at key-down (~Nk, idle M min)" → `POST /brain/prewarm` (§5.6).
- Start reading the active document (browser page address or open file). Reading files under `/Documents/`, `/Downloads/`, `/Desktop/`, iCloud `Mobile Documents` and `/Volumes/` is tracked in `clicky.oneBrain.guardedFoldersReadBefore.v1`, because the first read triggers a macOS privacy prompt. [I]

**Key-up:**

- Finish the ears and wait for the transcript (`OneBrainTranscriptWaiter`).
- If nothing was heard, the notch says "I didn't catch that. Hold the keys while you talk, then let go."
- If the speech connection dropped, it says the connection dropped and suggests trying again or typing (string begins "I couldn't hear that, my speech connection dropped.").
- If the user pressed again before the transcript arrived, the log reads "the user moved on before the transcript finished; this press's turn is dropped".

**Capture:** screenshot of the display under the cursor. Other displays go in `other_screens`. Capture uses ScreenCaptureKit (`CompanionScreenCaptureUtility.SettleSampler` with `SCContentFilter` and `SCStreamConfiguration`). Each capture is a `CompanionScreenCapture{imageData(JPEG), label, isCursorScreen, displayWidthInPoints, displayHeightInPoints, displayFrame, screenshotWidthInPixels, screenshotHeightInPixels}`. With no screenshot or no sign-in, the turn is dropped with "I couldn't see your screen just now…".

**Request:** §5.4. **Stream handling:** §5.5. **Tools:** §6. **Speaking:** §7.

**Typed turns** use the same brain (`OneBrainTurnTiming.Marks.isTyped`, `latestTurnWasTyped`). Typed answers can be shown as text (`latestTurnAnswersInText`) unless "Read answers aloud" is on.

### 5.4 `POST /brain/turn`: request [O keys from XL; nesting I]

Headers:

- `Authorization: Bearer <Supabase JWT>`
- `Content-Type: application/json`
- `X-Clicky-Usage-Context: companion | agent_chat | clicky_creation | onboarding` (`ClickyUsageContext`)
- When large, the body is gzipped with `Content-Encoding: gzip` (log "turn body gzip X KB → Y KB"). `x-clicky-accepts-gzip` is the opt-in signal.
- Tracing headers: `X-Clicky-Trace-Id`, `X-Clicky-Session-Id`, `X-Clicky-Distinct-Id`, `X-Clicky-Mode`, plus device headers `X-Clicky-Platform`, `X-Clicky-Device`, `X-Clicky-App-Version`, `X-Clicky-App-Build`, `X-Clicky-OS-Version`.

Body, top level:

```
session_id, thread[...], turn{...}, turn_items, max_rounds, turn_token?, screenless?,
brain_model, async_tools, app_reads, figures_float, library_items, routines_tool,
find_jobs_tool, saves_drawings, takeover?, user_layer?, user_layer_signature?,
environment{ roster_note, connected_apps, time_zone, user_context, drive }   (once per session)
```

`turn` (the current user turn):

```
words            transcript (or typed text)
fact             app-supplied fact for app-initiated turns            [I]
time_label       "HH:mm, EEEE MMM d, yyyy"
front_app, front_app_bundle_id
drawing_on_screen, drawing_code
highlight{gesture, text}                   user's circled region + text under it
page{web_page | file …, access_denied?}    active document context
input{text…}, voice (bool: spoken vs typed), audio_seconds, stt_provider:"gemini"
live_state, stable_note, flow_brief, walkthrough_step, trigger, flow   (tour/walkthrough context)
screenshot{base64, mimeType:"image/jpeg", widthInPixels, heightInPixels}  or by reference
other_screens[...], attached_images[...]
```

- `trigger` values include `did_step` and `clicked_target` (auto-advance) and `tour_finale`.
- Attachments add an instruction note: images are attached for viewing; files need a job.

Feature flags tell the server what the client supports [I]:

| Flag | Meaning |
|---|---|
| `async_tools` | Runs tools without blocking the turn |
| `app_reads` | Brain reads connected apps itself (Developer toggle `ClickyOneBrainReadsApps`) |
| `figures_float` | Figures render as floating cards |
| `library_items`, `routines_tool`, `find_jobs_tool` | The matching tools exist |
| `saves_drawings` | Drawings can be saved |
| `takeover` | Computer-use is allowed |
| `screenless` | No screenshot this turn |

When 3D is unavailable, a note forbids `figure()`/`scene3d()` (key `no_3d`).

**Screenshots by reference** [O]:

- After a turn, the server returns `screenshot_file` (an id such as `file-…`). The client keeps these ids (`sessionScreenshotFiles`) and later turns refer to the image as `{"type":"input_image","clicky_file":id}` instead of re-uploading it.
- If the server answers `screenshot_files_unavailable`, the client logs "screenshots by reference refused: sending them in full for the rest of this session" and sets `screenshotFilesOffForSession`.

### 5.5 `/brain/turn` response: SSE stream [O]

Each event is a `data:` line holding JSON with a `type`:

| `type` | Payload keys | Client action |
|---|---|---|
| `meta` | `model`, `user_layer`, `user_layer_signature`, `guided_max_rounds`, `drive_lease_id` | Store the model, the signed user layer and the round cap |
| `text` | `text` | Program text delta. Append it, strip the ```` ``` ```` fences, extract `say("…")` lines as they complete, and send each to the mouth |
| `status` | `kind` (e.g. `searching`, `reading_apps`) | Notch or cursor status ("Searching the web…") |
| `items` | `items[]` | Responses items (reasoning, assistant message, function_call, server-side web_search call and output) to append to `thread` |
| `search_record` | `text` | Record of a server-side web search |
| `tool_call` / `tool_calls` | `call` / `calls[]` (`ToolCall{callID, name, arguments, isAsync}`) | Run client tools (§6) |
| `computer_calls` | `calls[]` (`ComputerCall{callID, actions[], pendingSafetyChecks[]}`) | Take-over actions on the Mac (separate subsystem) |
| `done` | `cost`, `keep_reasoning`, `turn_token`, `screenshot_file`, `message_recorded`, `message_refunded`, `drive_messages_refunded`, usage | End of round |
| `error` | `code`, `message` | Error (e.g. `screenshot_files_unavailable`) |

- Decoded result: `OneBrainClient.Reply{code, computerCalls, spokenSentence?, items, searchRecords, toolCalls, userLayer, modelIdentifier, firstTokenMilliseconds, totalMilliseconds, costUSD, usage, keepsReasoning, turnToken, userLayerSignature, guidedMaxRounds, screenshotFile}`.
- `turn_token` is echoed on the next request. It probably ties tool-result rounds to the same billed user message. [I]
- A stream that ends early produces "the connection ended before the answer was complete".
- HTTP 429 → "You're asking me a lot right now. Give me a minute, then try again."
- HTTP 402 → `PaywallReachedError`, paywall card.
- Spoken lines have markdown links and bare URLs removed (three regexes in `BIN`).
- Observed latency from the user's log (32 rounds, `DATA`):
  - server `ttftMs` ranges 1379–4140 ms, typically about 2.0–2.5 s;
  - `totalMs` ranges 1.5–17 s;
  - prompt-cache hit rates of about 85–97 % (`cached`/`input`);
  - cost of about $0.06 per round.

### 5.6 Prewarm, compaction and session end [O]

**`POST /brain/prewarm`**

- Body: `{session_id, user_layer, user_layer_signature, thread, canvas, async_tools, brain_model, app_reads, figures_float, library_items, routines_tool, find_jobs_tool, saves_drawings, drive}`.
- Sent at key-down by `OneBrainPrewarmPolicy`, so the provider's prompt cache is warm by key-up. Log: "prompt cache warming (~N, conversation ~M tokens, idle X min)".

**`POST /brain/compact`**

- Body: `{thread, session_id, input_tokens}`.
- Triggered when `last_input` reaches the next check threshold ("input reached N tokens … asking the Worker to compact the thread"; HUD "Compacts at N").
- Response is one of:
  - **Compacted:** `{note_item, drop_leading_items, keep_from_index, keep_leading_items}`. The client replaces the dropped leading items with the developer `note_item`. Log: "thread compacted: A → B items". The next turn rewrites the cache.
  - **Not yet:** `{tokens_until_fold}`. Log: "too little to fold yet; asking again at N input tokens".
  - **No compaction:** `{reason}` or `{error}`.
- A compaction that comes back after the thread has changed is discarded (`compactionGeneration`).
- Thresholds are set by `OneBrainCompactionPolicy` and the server [U].

**`POST /brain/session-end`**

- Body: `{session_id, thread, screenshot_files}`.
- Hands the session to the Worker so it can write the session note and memory ("session N handed to the Worker").
- Also used by "Start a fresh session" in Developer settings, by account switch, and by idle timeout [I].

### 5.7 Turn latency instrumentation [O]

**`OneBrainTurnTiming.Marks`:** `releasedAt`, `transcriptAt`, `requestStartedAt`, `headersAt`, `firstTokenAt`, `requestBodyBytes`, `requestBodyWasGzip`, `isTyped`.

**Analytics event `one_brain_turn_timing`:**

- durations: `release_to_transcript_ms`, `transcript_to_request_ms`, `request_to_headers_ms`, `headers_to_first_token_ms`, `first_token_to_first_line_ms`, `request_to_first_line_ms`, `release_to_first_line_ms`
- other fields: `body_kb`, `body_gzip`, `model`, `typed`, `sample_rate`

**Stats HUD** (`OneBrainStatsHUD`, Developer toggle "Show one brain stats", excluded from screenshots):

- session tokens, the next compaction point, screenshots kept in the thread;
- the last turn's cache "HIT/MISS", read/written/fresh token counts, reasoning, output, rounds;
- step timings "release→sent", "1st token", "heard", "TOTAL", and the time since the previous turn.
- Model types: `OneBrainStats.Session{id, startedAt, lastTurnAt, threadItems, screenshotsInThread, lastInputTokens, baselineInputTokens, nextCompactionCheckInputTokens, isCompacting, turnCount}`, `OneBrainStats.Turn{kind, model, keyUpAt, sentAt, firstTokenMilliseconds, firstHeardAt, rounds, input, cached, wrote, output, reasoning, cost, idleMinutesBefore}`, `OneBrainStats.Event{id, at, text}`.

---

## 6. Brain tools

### 6.1 One-brain client tool runner (`OneBrainToolRunner`, `OneBrainToolCallPolicy`) [O]

- Tool calls arrive with `isAsync`. Async calls run without holding the turn; synchronous reads need another brain round with their outputs.
- Tasks run concurrently, keyed by call id, but outputs are returned in start order (`startOrder`, `lastOrderedTask`).
- A call that never ran returns `{"status":"error","message":"the call never ran"}`.
- A call cancelled by a newer turn returns `{"status":"cancelled","message":…}`.
- Status-label marks `tool:` and `tool_done:` appear in the drawing stream.

Tool names and how the client resolves them (status words from `XL`):

| Group | Tools | Result |
|---|---|---|
| Reads (another round needed) | `file_read`, `file_list`, `clicky_memory`, `session_status`, `clicky_artifacts`, `google_calendar_find_events`, `find_jobs` (arg `limit`/`query`) | JSON output becomes a `function_call_output`, followed by round r+1 |
| Actions (status words) | `open_url`→`opened`, `play_on_spotify`→`completed`, `copy_to_clipboard`, `insert_text`→`inserted`, `open_agent_dashboard`, `open_artifact`→`completed`, `reveal_artifact`→`completed`, `sessions_spawn`→`dispatched`, `sessions_send`→`sent`, `show_result`→`shown`, `routines`→`created`/`updated`/`paused`/`resumed`/`deleted`/`started` | Status output |
| Deferred until narration has been spoken | `open_url`, `open_artifact`, `reveal_artifact`, `open_agent_dashboard`, `play_on_spotify`, `show_result` | Held in `actionsWaitingForTheDrawing` |
| Server-side (Worker runs them) | `web_search` (seen as `function_call` in `DATA` thread), connected-app reads when `app_reads` | Arrive as `items` or `search_record` |
| Take-over | `computer_calls`, `offer_screen_takeover`, `start_screen_takeover`, `end_screen_takeover` | Separate subsystem (ClickyTakeOver) |

Notes on deferred and blocked tools:

- Deferred tools log a line ("N action(s) wait until the drawing is told …") noting that the screen is left untouched until narration ends. If a new turn starts first, they are dropped.
- If a deferred action fails after narration, the next turn gets an `[App]` note saying it didn't work.
- `sessions_spawn` during the welcome tour returns `not_during_the_tour` with a note to carry on.
- `show_result` needs the job's `codexThreadId` and an outcome line.

### 6.2 Full-voice tool dispatcher (`RealtimeToolDispatcher`) [O]

Tool names with the status label the notch shows while each runs:

| Tool | Label | Backend |
|---|---|---|
| `send_to_higher_model` | "Thinking deeper…" | `POST /chat-tool-call` (§6.3) |
| `tutorial_draw_on_screen` | "Drawing on your screen…" | Drawing lane. Result `{status:"answer", app_spoken_guidance, visual_guidance_shown, message}` tells the realtime model to stay quiet while HeyClicky narrates |
| `capture_screen` | "Looking at your screen…" | Local screenshot attached as `input_image` |
| `read_connected_apps` | "Reading your apps…" | Worker (Composio) [I] |
| `web_search` | "Searching the web…" | `POST /web-search` |
| `save_memory` | "Saving to memory…" | `POST /me/memory/save` |
| `insert_text` | "Typing it in…" | Local AX insertion (refuses secure fields and address bars) |
| `play_on_spotify` | "Playing on Spotify…" | `POST /agent/realtime/spotify/search`, then AppleScript with a URL-scheme fallback |
| `open_url`, `copy_to_clipboard`, `open_agent_dashboard`, `open_artifact`, `reveal_artifact` | "Opening link…", and similar | Local |
| `google_calendar_find_events`, `google_calendar_create_event` | none | `/agent/realtime/google-calendar/events[/create]` (arg `timeZone`) |
| `sessions_spawn`, `sessions_send`, `sessions_interrupt`, `sessions_yield`, `session_status`, `sessions_answer_request` | "Starting agent…", etc. | Agent subsystem. `sessions_answer_request` takes `request` (`extra_usage` / `computer_use` / `chrome_setup`) and `decision` (`approve` / `show_how` / `decline`) |
| `routines`, `clicky_memory`, `clicky_artifacts`, `find_jobs`, `save_drawing`, `runtime_status`, `skip_onboarding_interview` | Various | Local and agent |
| `shell_exec`, `file_read`, `file_write`, `file_list` | "Running command…", and similar | Local |

Rules:

- There is a per-turn tool-call cap. When hit, the client returns `tool_limit_reached` and tells the model to answer with what it has.
- A tool result that arrives after a newer user turn is discarded, or replaced with a synthetic `superseded` output.
- Unknown tools return `not_implemented`.

`client_capabilities` sent at session mint [O]: `spotify_search`, `clipboard_copy`, `realtime_model_from_mint`, `save_memory`, `insert_text`, `capture_screen`, `agent_dashboard`, `clicky_memory`, `clicky_artifacts`, `agent_routines`, `agent_requests`, `onboarding_interview_skip`.

### 6.3 `send_to_higher_model` → `POST /chat-tool-call` (full voice only) [O]

Request keys:

- `query`, `currentUserText`, `currentMessageTimestamp`, `history`
- `screenshots[{screenshotBase64, mimeType:"image/jpeg", screenshotWidthInPixels, screenshotHeightInPixels, …}]`, `previous_screenshots`
- `active_skills`, `annotation_gesture`, `annotation_elements`, `guided_session`, `clickys`
- `connected_integrations`, `clicky_offers`, `recent_agent_suggestions`, `client_capabilities`
- `frontmost_app_bundle_id`, `frontmost_browser_host`, `environment`
- `active_document` (full text of the open file or page, with `truncated` and `access_prompt_suppressed`)
- `userAttachedImages`

Response keys: `text`, `annotationText`, `clipboardText`, `widgets`, `agentHandoff{task, label, clicky_slug | new_clicky}`, `clickyOffer`, `places`, `awaitsUserContinuation`. Inline `[POINT:…]` and `[TYPE:x,y:…]<<<…>>>` markers make the client point the cursor or type text.

---

## 7. Mouth: the speaking session

### 7.1 Opening a session: `POST /agent/realtime/session` [O]

- Request body (`RealtimeEphemeralSessionRequest`): `{voice, speed, prompt_context, client_capabilities}`.
- The mouth variant sends the marker `one_brain_mouth`. Its exact placement is unknown [U]: the literal sits next to the session-mint code.
- `prompt_context` (`RealtimeSessionPromptContext`, snake_case CodingKeys):
  - `connected_integrations`, `needs_reconnect_integrations`
  - `explicit_agent_follow_up_target{codex_thread_id, title}`
  - `prior_message_count`, `time_zone`, `current_local_datetime`, `voice_gender`
  - `active_skills[{display_name, one_liner, blurb, description, built_for}]`
  - `dictation_hold_shortcut`, `onboarding_tutorial`
  - `custom_connectors[{name, description}]`
  - `connected_integration_accounts[{integration, accounts[{connected_account_id, account_name, label}]}]`
- Response: `client_secret.value` (or `value`) is an ephemeral OpenAI key; `session.model` (or `model`) is the model. The server picks the model (`realtime_model_from_mint`). Instructions and tools are configured on the server [U].
- A 401 triggers one retry with a force-refreshed Supabase token.
- Errors (`RealtimeVoiceClientError`): `workerEphemeralSessionFailed(status, body)`, `webSocketOpenFailed`, `sessionConfigurationRejected`, `ephemeralTokenMalformed`, `notRunning`.
- Socket: `wss://api.openai.com/v1/realtime?model=<model>` with `Authorization: Bearer <ephemeral>`.
- Pre-warming:
  - `HEAD https://api.openai.com` and `HEAD /agent/realtime/warmup` warm DNS and TLS.
  - The mouth is opened at launch ("launch prewarm"), for the tutorial ("tutorial prewarm") and at key-down.
  - The last open time is recorded in `clicky.realtime.lastSessionOpenedAt.v1`.

### 7.2 Speaking one line (OpenAI mouth) [O]

Each `say` line is sent as an out-of-band `response.create`:

```json
{"type":"response.create","response":{
  "conversation":"none", "output_modalities":["audio"],
  "instructions":"<fixed verbatim-reader instructions>",
  "input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"<JSON {response_text: line}>"}]}],
  "metadata":{"response_text":"<line>","require_repeat_verbatim":"…"}}}
```

- The input-message JSON wrapper is [I], built from an observed instruction to output exactly `response_text`. The fixed instructions tell the model to read the line exactly as written, in the line's own language, with no additions. They are server-independent text in `BIN`; this doc paraphrases them.
- If a response is already in flight, the line is queued ("verbatim narration line: response in flight, queuing").
- Events consumed:
  - `response.created`
  - `response.output_audio.delta` (or legacy `response.audio.delta`)
  - `response.output_audio_transcript.delta`
  - `response.output_text.delta`
  - `response.done` (usage tokens `input_tokens`, `output_tokens`, `total_tokens`, `input_token_details{text_tokens, audio_tokens, image_tokens, cached_tokens}`)
  - `response.cancelled`
  - `session.created` and `session.updated`
  - `error`
- `responseDidFinish` fires only after the player has drained its scheduled buffers ("deferring responseDidFinish until player drains").
- Health checks:
  - "the mouth never answered line 1 …": the connection looks open but is dead (`mouth_silent_socket`). The mouth is reopened and the line resent.
  - "the mouth's connection dropped between lines … opening a new one quietly" (`mouth_dropped_between_lines`).
- Idle teardown: the mouth closes after `oneBrainMouthIdleTeardownSeconds` (value unknown [U]). Full voice uses `idleTeardownSeconds`. Teardown is skipped while an agent is busy or always-on is active.
- Narration log: "line 1 handed to the voice N ms after the tool call", "narrated N line(s) in X ms".
- Usage reporting: `POST /agent/realtime/turn` with `{count_usage, messages, usage, model, purpose:"one_brain_mouth", provider:"gemini"|…, transcription_usage}`.

### 7.3 Gemini voices (`GeminiMouthProtocol`) [O]

- Selecting a `gemini:<Name>` voice makes `RealtimeVoiceClient` a "Gemini mouth session" (`isGeminiMouthSession`, `geminiMouthModelIdentifier` = `gemini-3.8-flash-lite-tts`). Each line is one HTTP request: `POST /agent/realtime/speak` with `{voice, text}` for a line, or `{voice, update, instructions}` for a paraphrased status update, plus `{languages}`.
- The streamed response holds Gemini Live messages: `setupComplete`, `serverContent.modelTurn.parts[].inlineData.data` (audio), `outputTranscription.text`, `generationComplete`, `turnComplete`, `interrupted`, `usageMetadata`, `goAway`. The client translates them into OpenAI-shaped events (`GeminiMouthProtocol.Event.realtimeEvent`) so the rest of the pipeline is provider-neutral.
- `GeminiMouthTurnLedger.Turn{verbatimLine, discarded, generationComplete, sawAudio, transcript}` tracks lines.
- Failure handling: "Gemini line failed … the next session speaks in the OpenAI voice" (`gemini_mouth_line_failed`) and `gemini_mouth_line_cut_off`. After failure the client uses the OpenAI voice for 10 minutes ("Gemini voice unavailable lately").
- Gemini voice speed is applied in the client (`RealtimePlayer.speedNode: AVAudioUnitTimePitch`, `playbackRate`). [I]

### 7.4 Filler and recovery lines [O]

- Fillers when a web search runs before line 1: "Sure, one sec.", "Mm, let me see.", "Almost there.", "Let me look that up.", "Let me check online.", "Let me search for that." In full voice the realtime model is told its preamble budget (none, or "One sec."/"Mm-hm."/"Okay.").
- Failures heard by the user: "Sorry, I couldn't get an answer just now. Try asking me again.", "Sorry, my drawing didn't come through…", "The screen changed before I could draw that…".

### 7.5 Narration outcome and screen-change handling [O]

- `ScreenDrawingNarrationOutcome` has `droppedBeforeFirstLine(reason)`, `stoppedMidway(reason)`, `completed`, `targetArmed`, `failed` and `superseded`.
- Reasons include: the answer ended; the target window closed, moved or was covered by another window; the screen content changed; the user changed Space or app; the user scrolled or clicked.
- The outcome becomes an `[App]`/`[clicky drawing]` note in the next turn: what was said, where it stopped, and what was still to come.
- If the screen changed before a step showed, the client looks again once ("looking again"). A second change makes it stay quiet.

---

## 8. Barge-in, interrupt and cut-off

### One brain [O]

- A new key-down while speaking or drawing cancels the in-flight `/brain/turn` (logged as `interrupted`, `NSURLErrorCancelled`) and stops the mouth (`response.cancel`).
- It adds the developer note "[App] The user cut this answer off here." and records the narration outcome `stoppedMidway`.
- The new press supersedes the old one ("replaced by a newer press").
- Escape does the same without starting a new turn.

### Full voice [O]

- `interruptCurrentResponse`: send `response.cancel` if a response is in flight, plus `input_audio_buffer.clear` ("manual interrupt").
- Then truncate the assistant item to what was actually heard: `conversation.item.truncate{item_id, content_index, audio_end_ms}`, computed from played frames (`playedFrameCountBaselineForCurrentResponse`). The client skips truncation if the playback backend changed mid-response.

### Always-on (server VAD) [O]

- `session.update` sets `turn_detection{type:"server_vad", threshold, prefix_padding_ms, silence_duration_ms, create_response, interrupt_response}` and `noise_reduction{type:"near_field"|"far_field"}`. Literal values `0.5` and `0.72` sit nearby [I: likely thresholds with and without echo cancellation].
- Gating:
  - Speech-start events pass a barge-in gate and an interrupt gate based on speech-like audio durations (`speechLikeAudioDurationThisTurn`, `alwaysOnBargeInSpeechLikeAudioDurationThisTurn`, `peakAudioPowerThisTurn`).
  - A post-response settle window suppresses echo.
  - Commits without real speech are discarded with `conversation.item.delete`; log labels: `silent always-on commit`, `always-on output echo commit`, `always-on self/post-response audio`.
  - Unexpected auto responses are cancelled.
- Always-on needs headphones. It refuses to start on speakers and ends if audio switches to speakers.

### Muted output [O]

- `SystemAudioOutputVolume.OutputSilenceKind` is `muted` or `zeroVolume`. When the reply can't be heard, audio is suppressed and the answer is copied to the clipboard.
- The notch shows "Your Mac is muted" / "Your volume is at zero" / "That reply wasn't heard" with actions "Unmute" or "Set volume to 50%".

---

## 9. Full-voice push-to-talk flow (for completeness) [O]

1. **PTT begin.** Reuse a healthy session or open a fresh one (`ptt_open_session`). The session is rebuilt when:
   - it is unhealthy;
   - the integration list changed (needs fresh prompt context);
   - the selected voice changed;
   - it is the wrong kind (mouth vs full voice).
   A stale tail-commit task from the previous turn is cancelled.
2. **Mic.** Audio streams as `input_audio_buffer.append{audio}`. Chunks buffered before the socket opened are drained.
3. **PTT end.**
   - Schedule a **400 ms tail** so trailing words aren't cut.
   - Poll session health (gives up after N ticks).
   - Capture screen(s) and summarize the annotation gesture and the Accessibility context.
   - Send screen context as `conversation.item.create` user message with `input_image` (item ids prefixed `clkyimg`). Only the latest screenshot is kept; older ones are deleted with `conversation.item.delete`.
   - Send a time note ("[Current time] …").
   - Then `input_audio_buffer.commit` and `response.create`.
4. **Early release.** A short tap cancels startup ("short-tap PTT cancel"); a silent release before the session is healthy cancels too.
5. **Watchdog.** If no `response.done` arrives within the watchdog window, the unhealthy session is torn down (`silent_session_death`, "no server message for Ns after commit").
6. **Mid-session updates** via `session.update`: speech speed (`audio.output.speed`), reasoning effort (`reasoning.effort`) and skill changes (a context note).

---

## 10. Dictation (talk-to-type) [O]

Owner is `ClickyDictationController`. It shares the ears transcriber (`DictationGeminiTranscriber` wraps `OneBrainGeminiTranscriber`).

### Engagement states

`ShortcutEngagement` has three states: `idle`, `holding`, `handsFreeLocked`.

- **Hold:** dictates until release.
- **Hands-free:** a separate double-tap shortcut, or a quick-tap lock (`pendingQuickTapFinishWorkItem`, `shouldIgnoreNextReleaseAfterLockStop`). The quick-tap lock is [I]. Notch label "Dictating (hands-free)".
- **Key bounce:** ignored ("key bounce ignored; still holding").

### Flow

1. **Key-down: capture the focus context** (`DictationFocusContext`): `element` (AXUIElement), `processIdentifier`, `appName`, `siteHost` (browsers), `role`, `elementFrame`, `beforeText`, `selectedText`, `afterText`, `isSecure`.
   - Reads `AXFocusedUIElement`, `AXValue`, `AXSelectedText` and `AXSelectedTextRange`.
   - Sets `AXEnhancedUserInterface` / `AXManualAccessibility` so Chromium and Electron apps expose their text.
   - A field that was missed at key-down is re-captured late if it is in the same app.
2. **Stream** through a warm or new Gemini socket (`/v2/dictation/gemini-token`). The minted `receipt` is kept. If streaming fails, it falls back to batch: "streaming failed, batch fallback".
3. **Batch:** `POST /v2/dictation/transcribe` with `{audio_wav_base64, audio_seconds, context, language, known_terms}` → `{text}`.
4. **Cleanup:** `POST /v2/dictation/cleanup` with `{transcript, audio_seconds, context{app_name, site_host, before_text, selected_text, after_text, single_line}, fast_cleanup, stt_ms, stt_provider}`.
   - Header `X-Clicky-Dictation-Receipt: <receipt>`. On 401 it retries with the Bearer token.
   - Response `{text}`. If cleanup fails, the raw streamed transcript is inserted.
   - HTTP 402 means the dictation word quota was reached (paywall).
5. **Insert** (`DictationInsertion`):
   - Outcomes: `inserted(targetAppName)`, `failed(emptyTranscript | focusLost | eventSourceUnavailable | pasteboardWriteFailed)`, `refusedAccessibilityPermission`, `refusedUnsafeTarget`.
   - Text is never inserted into secure fields, and never while Secure Event Input is on. The Secure Event Input check uses `IsSecureEventInputEnabled` via HIToolbox `dlsym`.
   - A special bundle list includes terminals (Terminal, iTerm2, Warp, Ghostty, kitty, Alacritty, WezTerm), WeChat/WeCom, Doubao, Teams, ChatGPT, Codex and Sublime Text. These probably get paste instead of AX value-setting. [I]
   - Fallbacks: "blind paste" (pasteboard + synthetic Command-V into the target app), otherwise the clipboard plus a notch notice ("Copied to your clipboard", "Press ⌘V to paste").
   - Analytics `DictationOutcome`: `inserted`, `pastedBlind`, `clipboard`.
   - On failure, any partial transcript is salvaged to the clipboard.
6. **Learn:** `DictationCorrectionLearner` watches the field after insertion. A user correction yields `DictationLearnedCorrection{original, corrected}`, which updates the custom vocabulary (`ClickyDictationCustomWords`, newline-separated) and shows a "learned word" notch. Vocabulary is seeded with the product name and the account display name (`clicky.dictation.claudeSeeded.v1`, `clicky.dictation.accountNameSeeded.v1`).
7. **Archive:** `Clicky/DictationTranscripts/YYYY-MM-DD.jsonl`, one `{at, app, text}` object per line [O, DATA].

### Settings

`ClickyDictationLanguage`, `ClickyDictationAutoDetect`, and `ClickyDictationCustomWords`. A language catalog of about 100 languages (`DictationLanguage{code, displayName, nativeName}`) includes "Auto-detect" and "Multilingual".

---

## 11. Voice picker, speed, languages and previews [O]

### `RealtimeVoiceOption`

Fields: `id`, `displayName`, `subtitle`, `iconSystemName`, `iconColor`, `sampleSentence`, `previewResourceName`, `provider` (`openAI` | `gemini`). Gender is `RealtimeVoiceGender` (`female`, `male`, `neutral`) and is sent as `voice_gender`.

**OpenAI voices.** Default is `cedar` (`selectedRealtimeVoiceID`; PREFS value `cedar`). Subtitles shown:

| Voice id | Subtitle |
|---|---|
| `cedar` | Warm default |
| `marin` | Bright & natural |
| `alloy` | Balanced |
| `ash` | Calm & even |
| `ballad` | Expressive |
| `coral` | Friendly |
| `echo` | (not recovered) |
| `sage` | Measured |
| `shimmer` | Light & airy |
| `verse` | Lively |

Previews are `realtime-voice-preview-<id>.mp3` in `RES`.

**Gemini voices.** Ids are `gemini:<Name>`; previews are `gemini-voice-preview-<name>.mp3` in `RES`. The 30 names:

- Puck, Zephyr, Aoede, Fenrir, Leda, Sulafat
- Achird, Sadachbia, Kore, Charon, Orus, Callirrhoe
- Autonoe, Enceladus, Iapetus, Umbriel, Algieba, Despina
- Erinome, Algenib, Rasalgethi, Laomedeia, Achernar, Alnilam
- Schedar, Gacrux, Pulcherrima, Zubenelgenubi, Vindemiatrix, Sadaltager

**Other preview files.** `RES` also contains `voice-preview-{bright,bubbly,cheerful,expert,fun,gentle,hope,kid,lumen,original,polished,smooth,techy}.mp3`. No literal in `BIN` references them, so they are probably leftovers from an earlier voice set. [I]

### Speed, languages and localized previews

- **Speed:** `RealtimeSpeechSpeedOption{multiplier, label}` with labels `0.5x`, `0.75x`, (1x), `1.25x`, `1.5x`. Stored in `selectedRealtimeSpeechSpeed`.
- **Languages:** `selectedVoiceLanguageCodes`, sent to the mouth as `spokenLanguageCodes`/`languages` and to the ears as `language`. Region suggestions come from `POST /onboarding/language-hints {device_region}` → `{languages}`.
- **Localized previews:** `POST /agent/realtime/voice-preview {voice, language}` → WAV, cached under `Clicky/VoicePreviews/<sanitized>.wav`. They are prefetched ("[Voice preview] prefetching N preview(s) in <lang>").
- **Live voice change:** changing the voice mid-session marks the session stale. An idle session closes; always-on restarts.

---

## 12. Sounds at each stage [O]

`ClickyChimeWarmer.Chime` → `RES` file:

| Chime | File |
|---|---|
| `textOpen` | `clicky-text-open` |
| `textSend` | `clicky-text-send` |
| `textReceive` | `clicky-text-receive` |
| `textClose` | `clicky-text-close` |
| `agentDone` | `agent-done` |
| `agentClose` | `agent-close` |
| `agentLaunch` | `agent-launch` |
| `hatching` | `hatching` |
| `clickyQuestion` | `clicky-question` |
| `agentNeedsYou` | `agent-needs-you` |
| `clickySurprised` | `clicky-surprised` |
| `connectionQuestion` | `connection-question` |
| `skillUp` / `skillDown` | `skill-up` / `skill-down` |
| `steerTapback` | `tapback-thumbs-up` |
| `homeReveal` | `home-reveal` |
| `clickyReveal` | `clicky-reveal` (missing in bundle) |
| `integrationPop` | `integration-pop` (missing in bundle) |
| `revealBoot` | `reveal-boot` |

All are `.wav` (RIFF parsed in memory).

`ChimePlaybackEngine` behavior:

- Preloads audio data, prepares one `AVAudioPlayer` per chime and tracks play generations.
- Warms the output device with a lead-in before playing, with a freshness window and a longer lead-in on Bluetooth.
- Re-warms after system wake.
- The mic-start cue (`PendingMicrophoneStartCue{chime, volume, identifier, requestedAt}`) waits until the mic is running.
- `hasPlayedVoiceRecordingStartChimeForCurrentSession` and `hasPlayedTextReceiveChimeForCurrentResponse` prevent duplicate cues.
- Which chime marks voice start was not recovered [U].
- Job reports can play the agent-done chime (`OneBrainJobReports.Report.playsChime`).
- Drawing sounds (pen, paper and so on) belong to the drawing subsystem (`ScreenDrawingSoundPlayer`).

---

## 13. Live captions and voice UI [O]

- **Live transcript (user):** interim ears text appears in the notch while holding (`_livePushToTalkTranscript`).
- **Voice pill and waveform:**
  - `NotchVoicePill` (placement `notch` or `arc`).
  - `CoreAnimationVoiceWaveform` and the cursor waveform (`cursorWaveform.levelEase`) are driven by `ClickyAudioLevelModel.currentAudioPowerLevel`, which comes from the mic RMS reported by `inputAudioPowerDidChange`.
  - Cursor and companion animation states include `notchListen`, `notchSpeak`, `detachedListening` and `speakBubble`.
- **Spoken-line captions:**
  - `ScreenDrawingLiveCaption` (a `CALayer` plate with a `currentWords` layer, auto-hide) and `ScreenDrawingNativeCaption` (JSON-driven) show the line being spoken.
  - Sync uses the callbacks `assistantTranscriptDelta`, `assistantTranscriptPlaybackProgress(charIndex)` and `tracksAssistantTranscriptPlayback`. The client aligns transcript characters to played audio frames (`transcriptAwaitingFirstAudio`, `responseTranscriptCharacterCount`). [I for the exact alignment]
  - Settings keys: `ClickyScreenDrawingVoiceCaptions`, `ClickyScreenDrawingSubtitles`.
- **Walkthrough sync (full voice drawing):** `RealtimeWalkthroughSync{beatFractions, drawLeadFraction, playbackFraction}`. Drawing beats are released when audio playback reaches each beat's fraction ("release threshold … at playbackFraction").

---

## 14. Report turns (background job results spoken by the brain) [O]

- `OneBrainJobReports` batches finished Codex jobs (`waiting`, `inFlight`, `flushTask`). It then runs a brain turn whose app note says the jobs came back, asking for `show_result` cards and one short `say()` per job.
- `Report{turnIdentifier, taskIdentifier, threadID, name, speaksAloud, raisesHeadsUp, playsChime}`.
- A failed report turn is retried once.
- Analytics fields: `job_count`, `waited_seconds`, `attempts`, `has_card`, `cards_shown`, `jobs_without_card`, `block_count`, `card_errors`, `line_count`, `raised_heads_up`, `played_chime`, `duration_ms`, `spoken_after_presented` / `spoken_on_request`.
- If the report turn says nothing, only the job status shows ("report turn said nothing for N job(s)").

---

## 15. Provider availability diagnosis [O]

When a session can't open, `RealtimeProviderAvailabilityDiagnosis` probes the provider directly (`https://api.openai.com/v1/models`, outcome `answered(statusCode, bodyText)` or `failed(urlErrorCode)`). It classifies the failure as:

- `regionUnsupported(providerName, location)` (detects `unsupported_country_region_territory`);
- `networkBlocksProvider(providerName)`.

It then shows a plain explanation that a firewall or region blocks the voice provider. Open-failure kinds: `workerCouldNotReachProvider`, `appCouldNotReachProvider`.

---

## 16. Permissions and entitlements [O PLIST]

- Not sandboxed (`com.apple.security.app-sandbox=false`).
- Entitlements: `device.audio-input`, `device.camera`, `network.client`, `cs.allow-jit`, mach-lookup `com.apple.screencapturekit.picker`.
- Usage strings: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` (Apple Speech path), `NSScreenCaptureUsageDescription`, `NSDesktop/Documents/DownloadsFolderUsageDescription` (reading the active document).
- `LSUIElement=true` (menu-bar / notch app).
- At runtime it also needs:
  - **Accessibility:** CGEventTaps for talk keys and Escape; AX focus, insertion and correction learning.
  - **Input Monitoring:** likely for listen-only key taps on recent macOS [I].
  - **Screen Recording:** screenshots.
- Permission deep links: `x-apple.systempreferences:com.apple.preference.security?Privacy_{Microphone,SpeechRecognition,Accessibility,ScreenCapture,FilesAndFolders}`.

---

## 17. Edge cases the code clearly handles [O]

- The key is released before the mic or session starts, so startup is cancelled: "start cancelled (shortcut released …)" and "silent PTT release".
- Repeated presses supersede older ones. Older transcripts and turns are dropped and tool results marked superseded.
- Sign-out or account switch mid-turn means the turn is discarded and the session restarted.
- Paywall or message cap blocks a press (`lastPushToTalkPressWasBlockedByMessageCap`, `pressWasRefused`). HTTP 402 → paywall; 429 → slow-down line.
- Screen Recording is missing: the realtime tool tells the model to answer without the screen; the brain turn is dropped with a user message.
- A document folder's access was denied: the turn notes it and the notch offers "Allow access to this file's folder". Document extraction waits a bounded time at key-down.
- Integrations or skills change mid-session: the session is marked stale and rebuilt on the next press. Always-on restarts.
- Output route change: the player engine restarts with retries (`engineRestartRetryTask`, `consecutiveColdStartFailureCount`, `onOutputEngineIrrecoverable`).
- Bluetooth profile flips are reduced by holding the capture session. A dead mic is replaced by the built-in mic.
- Gemini region or billing refusal → 10-minute fallback; Gemini voice failure → OpenAI voice for 10 minutes.
- Screenshot references refused → full images for the rest of the session.
- Compaction result arriving after the thread changed is ignored.

---

## 18. Model slot mapping (OpenClicky typed slots)

| HeyClicky part | Server route(s) | Slot | Capabilities required |
|---|---|---|---|
| Ears (hold-to-talk STT) | `/brain/ears/token` + Gemini Live WS; `/brain/ears/transcribe` fallback | **stt** | Streaming PCM16 input; interim and final transcripts; manual activity start/end (push-to-talk, no VAD); keyterm/vocabulary biasing; language hint or auto-detect; target: final result under about 300 ms after release; batch WAV fallback |
| Dictation STT | `/v2/dictation/gemini-token`, `/v2/dictation/transcribe` | **stt** | Same as ears, plus `known_terms` |
| Dictation cleanup | `/v2/dictation/cleanup` | **other: text-cleanup LLM** (a text-only brain slot also works) | Fast small text LLM; inputs: transcript plus surrounding field text, app or site, single-line flag; output: cleaned text |
| One brain | `/brain/turn`, `/brain/prewarm` | **brain** | Multimodal (JPEG screenshots, file references); streamed output; function and tool calling (sync and async); multi-round tool loop; server-side web search; optional computer-use actions; encrypted or opaque reasoning carry-over; prompt caching; outputs a drawing program with `say()` lines |
| Thread compaction | `/brain/compact` | **other: summarizer** (text LLM) | Fold old Responses items into a structured note (GOALS, OPEN TASKS, …) |
| Session-end memory | `/brain/session-end` | **other: memory writer** | Summarize a session into note and memory |
| Mouth | `/agent/realtime/session` (+ OpenAI WS, `gpt-realtime-2.1-mini`); `/agent/realtime/speak` (Gemini TTS) | **voice** | Low-latency streaming TTS of a given line, verbatim; voice id; speed; multilingual; streamed PCM16 with transcript deltas for captions; cancel or truncate; target: under about 500 ms to first audio |
| Full voice | `/agent/realtime/session` (`gpt-realtime-2.1`) | **voice** (realtime speech-to-speech) that also does light **brain** work | Bidirectional audio WS; server VAD option; input transcription; tool calling; image input items; truncate and cancel |
| Higher model | `/chat-tool-call` | **brain** | Multimodal answer with structured extras (widgets, handoff, pointing and typing markers) |
| Voice previews | `/agent/realtime/voice-preview` | **voice** | Short TTS sample in a given language |
| Jobs started by tools | `sessions_spawn` → agent subsystem | **agent** | Covered in the agent doc |

The model choice is carried by the client only on `/brain/turn` and `/brain/prewarm` (`brain_model`). The mouth and full-voice session sends a voice id, and the server chooses the model.

---

## 19. Rebuild plan (OpenClicky)

Swift modules (macOS 15+, SwiftPM targets):

1. **`TalkKeys`**
   - `ShortcutSpec{modifierMask, keyCode?, trigger: .hold | .doubleTap | .tripleTap}`, persisted as JSON per slot (`voiceHold`, `textTrigger`, `dictationHold`, `handsFreeDictation`, `alwaysOn`).
   - `GlobalKeyMonitor`: CGEventTap on a dedicated thread for flags, keys and mouse, plus a local NSEvent monitor. Tap detection discounts taps that overlap typing or scrolling. Exposes `AsyncStream<KeyEvent>` (`.voicePressed`, `.voiceReleased`, `.textTrigger`, `.alwaysOnToggle`, `.dictation(...)`, `.mouseDown(point)` while held).
   - `EscapeInterruptTap`: consumes Escape only when work is active.
   - `ShortcutRecorder`: modifier-only recording with conflict detection.
2. **`AudioIO`**
   - `MicCapture` protocol with two implementations: `CaptureSessionMic` (AVCaptureSession, legacy, robust) and `VoiceProcessingDuplex` (AVAudioEngine with `setVoiceProcessingEnabled(true)`, shared with playback).
   - `DuplexUpgrader`: probe, deaf-check, promote or demote. Verdict cache keyed by input+output topology fingerprint.
   - `MicHealthMonitor`: 2.5 s silent-window rebuild, all-zero detection, failover to built-in, irrecoverable notice.
   - `BluetoothMicHold`: keeps the capture session open, muted, for a grace period after a press.
   - `PCMConverter` (format-keyed AVAudioConverter, PCM16 mono at the target rate) and `WAVEncoder`.
   - `SpeechPlayer`: AVAudioEngine + AVAudioPlayerNode + AVAudioUnitTimePitch. Tracks scheduled and played frames for truncation, captions and drain notifications. Restarts the engine on route change.
   - `OutputSilenceDetector` (CoreAudio mute and volume) and `ChimePlayer` (preloaded, output warm-up, wait for mic before the start cue).
3. **`STT`** (slot **stt**)
   - `StreamingTranscriber` protocol: `start(language, keyterms)`, `append(pcm)`, `finish() async -> Transcript`, `interim: AsyncStream<String>`.
   - Providers: a Gemini-Live-compatible one (ephemeral token, manual activity markers) and a pluggable alternative such as Deepgram-style WS.
   - `WarmSocketPool` (pre-connect with expiry; refresh after wake).
   - `BatchTranscriber` fallback (WAV upload).
   - `AppleSpeechTranscriber` as an offline last resort.
   - `PressTimings` metrics.
4. **`Brain`** (slot **brain**)
   - `BrainSession` actor: session id, Responses-style `thread` items, user layer plus signature, canvas, environment-sent flag, screenshot file refs, compaction state. Persisted to `OneBrain/<account>/threads/<id>.json` with a `<id>.jsonl` turn log.
   - `BrainTurnRequest` builder (fields as in §5.4) with gzip; `BrainStreamParser` for SSE events `meta`, `text`, `status`, `items`, `search_record`, `tool_call(s)`, `computer_calls`, `done`, `error`.
   - `SayLineExtractor`: incremental parser over streamed program text. Emits each complete `say("…")` string immediately, with links and URLs stripped.
   - `ToolRunner`: sync vs async tools, ordered outputs, cancelled and never-ran results, actions deferred until narration has been spoken, round loop up to `max_rounds`.
   - `CompactionPolicy`, `PrewarmPolicy`, `SessionEnd`; screenshot-by-reference with full-image fallback.
   - `TurnTiming`: marks and an analytics event; optional stats HUD excluded from capture.
5. **`Mouth`** (slot **voice**)
   - `LineSpeaker` protocol: `speak(line) async`, `speakUpdate(text, instructions)`, `cancel()`, plus events `audio(pcm)`, `transcriptDelta`, `done`.
   - Implementations: an OpenAI-Realtime-compatible WS (out-of-band `response.create`, `conversation: none`, audio-only) and an HTTP-streaming TTS.
   - `MouthHealth`: line-1 silence detection, then reopen and resend; reconnect between lines; idle teardown; fallback to a second provider for 10 minutes.
6. **`RealtimeVoice`** (optional, slot **voice**): full-duplex session for always-on and interview modes.
   - Server-VAD config, barge-in and echo gates, `truncate` on interrupt, screenshot items with keep-latest-1, tool dispatcher with per-turn cap and superseded results.
7. **`VoiceOrchestrator`** (the turn state machine in §5.3)
   - Coordinates key events, mic, STT, screen capture, document read, highlight gesture, brain turn, mouth and drawing.
   - Handles barge-in, Escape, auto-advance after a user action, `[App]` notes, narration outcomes, muted-output clipboard fallback and job report turns.
8. **`Dictation`**
   - `FocusContextReader` (AX, including Chromium/Electron enablement, secure-field detection).
   - `DictationController` (hold, hands-free, bounce).
   - `CleanupClient` (slot **other: text-cleanup**).
   - `TextInserter` (AX set, then paste, then blind paste, then clipboard; Secure Event Input check; app-specific strategy table).
   - `CorrectionLearner`, `CustomVocabulary`, `TranscriptArchive` (daily JSONL).
9. **`VoiceSettings` + UI**
   - Voice catalog (provider, gender, preview), speed options, language codes, localized preview cache, mic picker and level test.
   - SwiftUI or CALayer notch pill, waveform bound to mic power, live user transcript, spoken-line caption layer.

JS side: none for voice. The program that `say()` lines come from runs in the drawing engine (see the drawing doc). OpenClicky's engine must expose a hook such as `onSay(lineIndex, text)` and an `await lineSpoken(i)` barrier, so speech and drawing steps stay in sync.
