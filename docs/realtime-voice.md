# Always-on realtime voice

One realtime speech-to-speech session that listens with the provider's voice activity detection, answers aloud, looks at
the screen when asked and calls tools. HeyClicky calls this "full voice" (docs/re/02-voice-pipeline.md §1B, §6.2, §6.3,
§8, §9). The code is in `Sources/OpenClickyKit/RealtimeVoice/`.

## Pieces

| Type | Job |
|---|---|
| `RealtimeVoiceSession`, `RealtimeVoiceClient` | Provider-neutral session: PCM16 in and out, user and assistant transcripts, tool calls and results, screenshots, interrupt with truncation, discarding echo turns. |
| `OpenAIRealtimeVoiceClient` | OpenAI Realtime API (GA) over WebSocket: `session.update` with server VAD, `gpt-transcribe` input transcription, noise reduction, tools; `input_image` items (latest kept); `response.cancel` and `conversation.item.truncate` on barge-in. Checked only against fake sockets (no OpenAI key). |
| `GeminiLiveVoiceClient` | Gemini Live native audio (`gemini-3.8-live`): `setup` with voice, system instruction, function declarations (schema trimmed to Gemini's subset), automatic activity detection, input and output transcription and context compression; tool responses with `scheduling`; screenshots in the tool response's `parts`. Checked live. |
| `RealtimeToolDispatcher` | Runs tool calls: per-turn cap (`tool_limit_reached`), results after a newer user turn answered `superseded` without a reply, cancellable work stopped, `not_implemented` and `invalid_request`, a time limit, and actions held until the reply has been heard. |
| `RealtimeTools`, `RealtimeToolbox` | `capture_screen` (the pointer's screen), `send_to_higher_model` (one turn on any `BrainTurnRunning`, its say lines returned for the voice to narrate, its events forwarded so the app can play a drawing), memory, lookups, app tools, `skip_onboarding_interview`. |
| `RealtimeEchoGate` | On speakers, sends silence while the voice plays and for a short ring-out, opens on clear barge-in speech (with a short prefix of the real audio), and drops committed turns that had no real speech. With headphones it only does the last. |
| `RealtimeConversation` | The loop: mic → gate → session; session audio → `RealtimeAudioOutput`; tool calls → dispatcher; barge-in stops the voice and truncates the reply to what was heard; transcript in order. |
| `AlwaysOnVoiceController` | The `toggle()` / `start()` / `stop()` / `interrupt()` the app calls. Refuses to start without headphones unless allowed, ends if sound moves to the speakers, reopens a dropped session. `Environment.live(...)` wires the Mac's mic and voice on one voice-processing audio host. |
| `AlwaysOnVoiceLoop`, `AlwaysOnDisplay` | Always-on in the voice loop: `toggle()` for triple-tap Control, holding the orchestrator's turns while it runs, the talk keys and Escape interrupting its reply, typed questions into the conversation; the notch pill's text. |
| `SharedMicrophone` | One mic for the voice loop and always-on (`turns` and `alwaysOn` handles; a stale stop from one side can't close the other's). |
| `RealtimeBrainDrawing` | Shows what the brain draws for `send_to_higher_model` on the overlay, on the screenshot the call was about, at once. |
| `ModifierTapCounter` | Counts clean taps of one modifier (the voice loop's `TalkKeyGestureMachine` is what the app uses for the triple tap). |
| `VisionAnswerBrain` | A minimal `BrainTurnRunning` (one call on the brain slot with the screenshots) used by `occtl realtime --brain`; the app uses the brain runtime. |
| `SimulatedRealtimeVoiceClient`, `FakeRealtimeVoiceSession` | A no-network stand-in server and a scriptable session for tests and the simulator. |

`EngineFactory.realtimeVoice()` builds the client for the `realtime-voice` slot. The `gemini-live` dialect now serves
both the stt slot (transcription models) and the realtime-voice slot (native-audio models); the validator refuses it in
the line-reading `voice` slot, which has no Gemini Live adapter.

## In the app

Triple-tap Control (the text key's modifier, three clean taps) or the menu's Start / Stop Always-On Voice calls
`AlwaysOnVoiceLoop.toggle()`, which `VoiceLoopController` owns next to the turn orchestrator:

- **On.** A turn still running is stopped, the orchestrator holds its turns (`TurnOrchestrator.holdsTurns`), the
  walkthrough ends and the narrator lets go of the speech player (`LineNarrator.release()`). Then a fresh
  `AlwaysOnVoiceController` opens a session on the realtime-voice slot (`EngineFactory.realtimeVoice()`), with
  `RealtimeInstructions.alwaysOn` and these tools: `capture_screen` (the pointer's display, OpenClicky's own windows
  left out), `send_to_higher_model` on the voice loop's brain runtime (same thread; its drawing shows on the overlay
  through `RealtimeBrainDrawing`, and actions it held, such as opening a link, run once the realtime reply has been
  heard; the drawing is paced by the reply's playback, see docs/dsl.md "Who calls them"), memory, lookups, app tools,
  the background-job tools and `read_connected_apps`. Without working echo cancellation it refuses to start without
  headphones and stops if sound moves to the speakers (an `AudioDeviceWatcher` on the default output).
- **Same context as push-to-talk.**
  - `capture_screen` sends the voice model a smaller picture than the brain gets: re-encoded at a 768 px long edge
    with one display or 640 px with several, JPEG quality 0.6 (`RealtimeVoiceImages.voiceSized`,
    `CaptureSizing.voiceLongEdge`, `ImageCoding.voiceJPEGQuality`).
  - `send_to_higher_model` looks the way a push-to-talk turn does (`RealtimeBrainLooking`; the app's look goes
    through `ScreenLookService.lookForTurn()`): every display at the brain's size, the front app, window, element
    ids, selection and document text, plus an `[Always-on so far]` note with the run's recent exchanges. Its drawing
    lands on the pointer's screenshot (`RealtimeBrainDrawing.look`).
  - The instructions carry the stable memory block and the active skills (`alwaysOn(memory:skills:)`), read each
    time a session opens; switching a skill on or off sends a running session a `[Skill update]` note.
  - The background-job tools (`sessions_spawn`, `session_status`, `find_jobs`, `show_result` after the reply is
    heard, …) and `read_connected_apps` are offered as in push-to-talk.
- **History and memory.** `AlwaysOnRecorder` folds the conversation's updates into history turns (`AlwaysOnTurnLog`:
  one turn per exchange with the user's words or typed text, every line the voice said, tools, status words, how the
  reply ended, the realtime model and its token use) and appends them to the conversation the brain runtime holds,
  the one push-to-talk and Home's typed chat use. When a run ends, the run's conversation goes through the
  session-end memory writer (brain-fast), and the brain's next turn gets an `[Always-on]` note of what was said.
- **Mic and voice.** Both paths share one `SharedMicrophone` and the voice loop's `SpeechPlayer`
  (`SpeechPlayerRealtimeOutput`); the conversation's `RealtimeEchoGate` sits between them. On speakers,
  `Environment.prepareRoute` asks the `DuplexAudioRouter` first: when the voice-processing engine works on these devices
  (probed once, cached per input and output), the mic and a speech player move onto it, speakers are allowed and the gate
  uses `speakersEchoCancelled`; otherwise headphones stay required (docs/audio-robustness.md).
- **While on.** The notch pill shows always-on's state (listening with the mic level, hearing you, a tool's status,
  thinking, speaking) and the caption shows the end of the reply. Holding the talk keys interrupts the reply and any
  running tool (barge-in) and starts no turn: the user just keeps talking. While always-on only listens or hears the
  user, the press changes nothing (an interrupt would throw away what they are saying). Escape stops a reply or tool
  the same way and otherwise passes on. Typed questions (the text panel, drawn buttons) go into the conversation and
  are answered aloud; one typed while the session is still opening (or reopening after a drop) goes in once it is on.
  A walkthrough can't start a step, and job reports wait until always-on is off.
- **Off, refused or failed.** The session closes, the mic is let go, the orchestrator's turns come back (with any job
  report that waited), and the notch says why: "stopped" when it had been on (sound moved to the speakers, the session
  dropped for good), "didn't start" when it never got going (no headphones, no realtime-voice slot, no mic).

Dictation's chord still works while always-on runs, and the realtime model hears what is dictated.

### Swapping sessions, muted output and drawings (Wave 4)

- **goAway.** When the provider says it will close the session (Gemini Live's `goAway` with its time left),
  `AlwaysOnVoiceController` opens the replacement at once. Sessions ask Gemini for resumption handles
  (`RealtimeSessionConfiguration.resumable`, `sessionResumption` in the setup; the conversation keeps the latest
  `resumable(handle:)`), so the replacement resumes from the handle when there is one; without one its instructions
  carry the last dozen transcript lines (`carryOver`). The turn in progress finishes on the old session; the swap
  happens at the next pause, or 1.5 s before the deadline if the turn runs long. The mic moves to the new session
  without stopping, and the old session's end is not counted as a drop.
- **Voice changes.** Changing the voice or the realtime-voice slot calls `AlwaysOnVoiceLoop.voiceChanged()`: the
  session is marked stale (`isStale`) and replaced at the next pause with the new voice and the recent transcript. If
  the new session can't open, the old one keeps running and stays stale.
- **Muted output.** `AlwaysOnVoiceLoop.mutedGuard` (the app's `MutedOutputGuard`) checks the output when a reply starts
  to speak. Into a muted or zero-volume output, the finished reply is copied to the clipboard and `onUnheardReply`
  shows the same Unmute / Set volume notice push-to-talk uses. The volume is never changed without the button.
- **Drawings.** While a drawing plays (`AlwaysOnVoiceLoop.isDrawing`), `capture_screen` attaches no picture and tells
  the model in words to answer from what it already knows, the way HeyClicky skips it.
- **`send_to_higher_model` outcomes.** The result carries `cursor_animated`, `visual_guidance_shown`, `text_typed`,
  `copied_to_clipboard`, `routed_to_agent` and `delivery_refused` (`HigherModelOutcome.derive`, from the brain's drawing
  program, the actions it held and the tools it ran), and the message tells the voice not to repeat what is already on
  screen, typed or copied. The last `capture_screen` picture (`RealtimeCaptureMemory`) goes to the brain as an earlier
  look, never as the canvas it draws on. The brain can hold an `insert_text` action (`InsertTextTool`, through
  `TextInserter`) that types into the focused field once the reply has been heard; into a password field or under
  secure input it is dropped and reported as `delivery_refused`.

## The app's wiring without a person at the Mac

`occtl realtime --runtime` runs a round trip the way the app wires always-on: `send_to_higher_model` on the brain
runtime (`--state dir`, as `occtl brain ask`) with the context `--app`, `--window` and `--doc` give and the `--screen`
picture, memory and skills in the instructions, and the exchange recorded with `AlwaysOnRecorder` in the history's
current conversation (`OPENCLICKY_HISTORY_DIR`), followed by the memory writer. With `occtl history chat --runtime`
on the same `--state` and history, a typed question and the spoken exchange land in one conversation:

```sh
export OPENCLICKY_HISTORY_DIR=/tmp/oc-history
occtl history chat --runtime --state /tmp/oc-brain --config docs/examples/config-cheap.json "What's a good name for a sticky-note app?"
occtl realtime --runtime --state /tmp/oc-brain --config docs/examples/config-realtime-gemini.json \
    --in question-draw.wav --out reply.wav --screen shot.jpg --app Notes --window "Reminders"
occtl history show latest      # [typed] and [voice] turns in one conversation
```

## Running it without a person at the Mac

```sh
swift build --product occtl
# No network: a simulated server, a picture file for capture_screen.
.build/debug/occtl realtime --simulate --in question.wav --out reply.wav --screen shot.jpg
# The app's always-on loop on the simulator, through one edge case, with a PASS/FAIL list:
.build/debug/occtl realtime --simulate --scenario go-away|go-away-no-handle|voice-change|muted|drawing --in question.wav
# Live, Gemini Live native audio (keys reach the process as OPENCLICKY_KEY_<NAME>, see docs/testing.md):
.build/debug/occtl realtime --config docs/examples/config-realtime-gemini.json --in question.wav --out reply.wav \
    --transcript report.json [--screen shot.jpg] [--brain] [--lookups] [--note "[App] …"]
```

The input file is sent in real time (then silence, so activity detection ends the turn); the reply goes to a WAV with
its transcript, timeline and token use. `OPENCLICKY_REALTIME_TRACE=1` prints the shape of every socket message (no audio,
images, handles or keys).

## Live results (2026-10-31, MacBook Air M4, gemini-3.8-live, voice Kore)

Evidence: `docs/evidence/feat-realtime-voice/`. Questions were synthesized with the ElevenLabs voice slot.

| Check | Result |
|---|---|
| "What is the capital of France? Please answer in one short sentence." | Said "The capital of France is Paris." First reply audio 0.83 s after the question ended; session setup 0.45 s. |
| "Can you look at my screen and tell me when my appointment is?" with a sticky-note screenshot | Called `capture_screen`, then said "Your reminder says your dentist appointment is on Thursday at 4:15 PM." First reply audio 1.75 s after the question. Three runs, all correct once the picture rode in the tool response. |
| "Could you circle the reminder on my screen and walk me through what I need to bring?" with `--brain` | Called `send_to_higher_model`; Claude Haiku read the screenshot; Gemini narrated "the yellow note in the middle is your reminder … bring the blue folder." |
| Reply WAVs transcribed back with `gemini-3.5-transcribe-live` | Matched the transcripts above. |

Findings from the live runs:

- A screenshot sent as a `realtimeInput.video` frame, or as an `inlineData` part of a `clientContent` turn with
  `turnComplete: false`, was not in the prompt of the reply to a `capture_screen` call (no IMAGE tokens; the model made
  up a time). In the FunctionResponse's `parts` it was counted (60 IMAGE tokens) and read correctly.
- Gemini's input transcription left out the greeting "Hi there." at the start of one question.
- Gemini sends `voiceActivity` start and end messages, which drive the user-speaking state.

## Review (2026-10-31)

An independent review re-ran the build, the full test suite, the occtl commands and two live Gemini runs, and fixed:

- **Tools after "stop".** Gemini can't be told to drop a reply, so a tool call it made after the user pressed Escape or
  talked over it reached the dispatcher in the new turn and ran (a link could open after the user said stop). Such
  calls are now answered silently by the adapter and never reach the app. On OpenAI, calls from a reply the app
  cancelled (streamed late, or only listed in its `response.done`) are dropped, as are unfinished `function_call` items.
- **Time limits.** The dispatcher raced the tool against its deadline in a task group, which waits for every child, so a
  tool that ignores cancellation (a blocking AppleScript) held back its `timed_out` answer. The race no longer waits.
- **Stale screenshots (Gemini).** A screenshot taken for a call Gemini withdrew rode along with the next, unrelated
  tool response. It is now dropped.
- **Slot pickers.** With `gemini-live` serving realtime speech, `occtl models voice` and the Settings voice picker
  offered `gemini-3.8-live`, which the validator then refused. Pickers now follow `ProviderDialect.canFill`.
- **Route changes with speakers allowed.** `outputRouteChanged()` only acted when headphones were required; with
  speakers allowed, sound moving to the speakers left the echo gate off. It now switches the running gate.
- **Clean room.** The interview prompt, the tool-limit message and a few always-on lines shared several 4–5 word runs
  with HeyClicky's embedded prompt text. They are rewritten (`docs/evidence/feat-realtime-voice/review-clean-room-check.txt`).
- Four conversation tests read the update log before it caught up; they now wait.

Live (Gemini `gemini-3.8-live`, review build): the `capture_screen` question was answered "Your dentist appointment is
this Thursday at 4:15 PM." (first audio 1.80 s after the question). An `[App]` note sent with `--note` and no reply
(a `clientContent` turn with `turnComplete: false`, the path the interview's progress notes use) was in the context of
the next spoken turn: asked "What is my favorite color?", Gemini answered "Your favorite color is teal." Both reply WAVs
transcribe back to those words (`review-*` files in the evidence folder).

## After the voice-loop merge (2026-10-31)

With main (#39–#41) and the voice loop (#42) merged in and always-on wired into the app, a fresh question synthesized
with ElevenLabs, "Hey, can you look at my screen and tell me what I need to bring to my appointment?", went through
`occtl realtime --screen` on `gemini-3.8-live`: Gemini called `capture_screen` and said "It looks like you need to
bring the blue folder to your appointment." First reply audio 1.97 s after the question ended; session setup 0.46 s
(`docs/evidence/feat-realtime-voice/app-wiring/`).

## Not verified

- OpenAI Realtime against the real API (no OpenAI key): request and event shapes follow the GA reference pages listed
  in `OpenAIRealtimeVoiceWire.swift` and are covered by fake-socket tests.
- The microphone, the speakers, echo cancellation and barge-in with a real room: microphone permission can't be granted
  without a person at the Mac, and the Mac is muted. The gate's thresholds are untuned guesses.
- Always-on in the app with a real mic, headphones and a person talking: triple-tap Control, barge-in with the talk
  keys, the notch pill and caption over real apps, sound moving to the speakers. The wiring is checked headlessly by
  `AlwaysOnVoiceLoopTests` (real orchestrator, narrator, player, controller and conversation, fake session and mic).
- Session resumption after Gemini's `goAway` against the live service: the handle request and resume are covered by
  scripted-socket tests and `occtl realtime --simulate --scenario go-away`
  (`docs/evidence/feat-w4-voice/simulate-*.txt`); a real `goAway` only comes near the end of a long session.
- The muted-output notice's Unmute and Set volume buttons and the real clipboard in the app (the scenario uses a
  pretend output device and pasteboard).

## Onboarding interview (feat/w4-onboarding-previews)

The onboarding welcome chat runs on this slot: `OnboardingInterviewSession` opens an `AlwaysOnVoiceController` with
`RealtimeInstructions.interview` and only `skip_onboarding_interview`, with speakers allowed (stricter echo gate) and no
reconnects. The app sends the opener as a note that asks for a reply and `interviewProgress` as a note without one after
each answer; typed answers go in as messages. See [home.md](home.md#welcome-chat) for the step and its fallbacks.

- **Caption order.** On Gemini Live the user's final caption is settled at the end of the model's turn, so the reply to
  an answer finished before the answer was counted, and the first live run counted the wrap-up as a question. The
  session now holds a reply that finishes while the user's words are still open until the caption settles (2 s at
  most, then the partial words count), and a later, longer caption revises the answer instead of adding one.
- **Progress note wording.** In the first live run Gemini asked the AI-agents question one turn early; the note for two
  or more remaining replies now says to ask about something new and keep that question for last. The second run asked
  it last and closed in three sentences.
- `occtl realtime --interview [--simulate]` runs the step headlessly; the simulator now answers a message or note that
  asks for a reply and takes a list of scripted replies (`SimulatedRealtimeVoiceClient(replies:)`).

Evidence: `docs/evidence/feat-w4-onboarding-previews/interview-*.txt`.

