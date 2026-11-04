# Sound trouble and quiet times

How the voice loop copes when sound goes wrong: a microphone that stops working, a Mac that is muted, OpenClicky's own
voice leaking into the microphone, and moments when it should keep quiet (a call, a Focus). Behaviour is described from
docs/re/02-voice-pipeline.md §3.2-3.4, §8 ("Muted output"), §12, and docs/re/03-screen-pointing.md §5.5; the code is new.

| Piece | Where | Job |
|---|---|---|
| `MicPressSummary`, `MicPressMeter` | `Audio/MicTrouble.swift` | One press's chunks: how long it was held, how many chunks came, how many were above digital silence. |
| `MicTroubleTracker` | `Audio/MicTrouble.swift` | Counts dead-air presses (2 in a row by default) and turns `MicrophoneCapture` events into notices: rebuilding (info), failed over to the built-in mic, irrecoverable, overflow (once per press past 25 dropped chunks), a failed engine, and denied permission. |
| `MicTroubleMonitor` | `Audio/MicTrouble.swift` | The app's wiring of the tracker to `SharedMicrophone` (`onStreamEnded`, `onCaptureEvent`), main-actor ordered. |
| `MicInputPin` | `Audio/MicTrouble.swift` | The chosen input plus a failover pin to the built-in mic. A user choice drops the pin. `MicrophoneCapture` uses it, `CaptureMicrophoneDevice` carries it across rebuilt captures. |
| `SharedMicrophone` additions | `Audio/SharedMicrophone.swift` | Per-stream summaries, capture events, `selectDevice(uid:)`, `failoverPin`, and the turn handle's `waitUntilLive` (`TurnMicrophoneReadiness`). `CaptureMicrophoneDevice(host:)` captures on its own engine or on a shared voice-processing one. |
| `OutputVolumeState`, `CoreAudioOutputVolume`, `FakeOutputVolume` | `Audio/OutputVolume.swift` | The default output's mute switch and volume (virtual main volume, else channel volumes). Reading needs no permission. Setting happens only from the notice's buttons. |
| `MutedOutputGuard` | `Audio/OutputVolume.swift` | `TurnOutputChecking` for the orchestrator; copies an unheard reply to the clipboard and builds the notice; performs Unmute and Set volume to 50%. |
| `TurnOrchestrator` changes | `Orchestrator/` | The start cue waits for the mic to be live (`Settings.startCueTimeout`, 1.5 s; no cue if it never goes live). With `Services.output` reporting silence, the turn isn't spoken: captions and drawing at once, and `TurnRecord.unheardReply` carries the lines. |
| `CuePlayer.preload()` | `Audio/UICues.swift` | Synthesizes every cue at launch; the app also wakes the cue output at key-down. |
| `AudioTopology`, `EchoVerdictCache` | `Audio/EchoCancellation.swift` | Input and output device UIDs as the cache key; verdicts (`promoted` or `zombie`) saved in `echo-cancellation.json`; a zombie is probed again after 7 days. |
| `EchoCancellationPlanner`, `EchoProbeResult` | `Audio/EchoCancellation.swift` | Not needed on headphones, off by setting, a cached verdict, or a probe (3 per run at most). The deaf check: no chunks, or only digital zeros, in the probe window (0.8 s). |
| `VoiceProcessingProbe` | `Audio/EchoCancellation.swift` | The real probe: a `MicrophoneCapture` on the shared voice-processing host for 0.8 s. Needs microphone permission; without it the probe reports `unavailable` and nothing is cached. |
| `DuplexAudioRouter` | `Audio/EchoCancellation.swift` | Owns the shared voice-processing `AudioEngineHost` and a speech player on it. `prepare(route:setting:)` decides and switches; `captureEvent` demotes a promoted engine that rebuilds within 4 s (deaf at start) or dies; `release()` goes back to plain. |
| `RealtimeEchoGate.Settings.speakersEchoCancelled`, `.speakersRaw`, `.tuned(for:echoCancelled:)` | `Audio/EchoCancellation.swift` | Gate presets from the offline tuning below. |
| `EchoGateTuner` | `RealtimeVoice/EchoGateTuner.swift` | Offline tuning: recorded replies into modelled rooms (coupling, reflections, canceller residual, noise), a recorded user talking over them, false barge-ins and barge-in delay per candidate. |
| `AlwaysOnVoiceController` changes | `RealtimeVoice/AlwaysOnVoice.swift` | `Environment.prepareRoute` (set up echo cancellation before a session on speakers; `.echoCancelled` allows speakers even when headphones are required) and `echoSettings`; `releaseRoute` when always-on is turned off while echo cancellation is being set up; `echoCancellationLost(_:)`; moving to speakers mid-session reopens on the cancelled engine. |
| `FocusDatabaseReader`, `ControlCenterFocusIndicator`, `SystemFocusStatus` | `Context/QuietContext.swift` | Focus: an active assertion from `~/Library/DoNotDisturb/DB`, readable only with Full Disk Access. Menu-bar visibility and configured schedules do not establish active Focus. Without a readable assertion, Focus state is unknown and does not hold output. |
| `CoreAudioInputUsage`, `CallPresenceDetector` | `Context/QuietContext.swift` | Calls: which processes record from the mic (CoreAudio's process list, macOS 14.2+; older systems only know "the input is running"). A call app or a browser recording is a call; another regular app recording makes the mic busy. OpenClicky and the system's listening helpers don't count. |
| `QuietContextMonitor`, `QuietGate`, `QuietHold` | `Context/QuietContext.swift` | Readings every 5 s; the gate holds job reports, routine notices and the onboarding prompt during calls and Focus, drops meeting countdowns during calls and holds them (until they expire) during Focus, and releases what waited, in order, when it's over (items older than 4 h are dropped). |

## In the app

`VoiceLoopController` owns an `AudioRobustness` (`Sources/OpenClicky/Voice/AudioRobustness.swift`):

- The shared mic is a `CaptureMicrophoneDevice` on the user's chosen input (Settings > Voice > Microphone) whose engine
  comes from the duplex router. `MicTroubleMonitor` shows each notice in a small clickable card under the notch
  (`AudioNoticePanel`, non-activating, never key). Microphone Settings opens Settings on the Voice page; picking a mic
  there drops the failover pin. A press that couldn't open the mic because access is off shows the privacy notice.
- Every turn's orchestrator gets `MutedOutputGuard` as its output check. A reply that went unheard is copied to the
  clipboard and the card offers Unmute or Set volume to 50% (when the Mac is muted *and* at zero, only the latter).
  Settings > Voice can turn this off.
- The start cue plays once the mic delivers audio. Cues are synthesized at launch and the cue output is woken at
  key-down.
- Always-on: before a session on speakers, `prepareAlwaysOn` asks the router. With a working verdict the mic and a
  second speech player move onto one voice-processing engine and the gate uses `speakersEchoCancelled`; otherwise
  always-on still asks for headphones. A demotion during the session (`MicTroubleMonitor.onCaptureEvent` →
  `router.captureEvent`) stops always-on on speakers with a notice. When always-on ends, the router goes back to plain.
  Settings > Voice has Automatic / Off and "Test echo cancellation again".
- Quiet: job and routine report turns go through `QuietHold`; held ones come back as one report turn when the quiet
  ends. Job notifications during quiet are silent and passive. Onboarding at launch waits for the quiet to end. Push
  to talk, typed questions and always-on are never held.

## Running it without a person at the Mac

```sh
swift build --product occtl
.build/debug/occtl soundcheck output            # reads this Mac's output mute and volume; changes nothing
.build/debug/occtl soundcheck mic               # dead-air presses and capture events through SharedMicrophone
.build/debug/occtl soundcheck muted-turn --config docs/examples/config-cheap.json --silence live "What is the capital of France?"
.build/debug/occtl soundcheck echo --probe working --sessions 2
.build/debug/occtl soundcheck echo --probe zeros
.build/debug/occtl soundcheck topology
.build/debug/occtl soundcheck gate-tune --reply a.wav,b.wav --user q.wav --out table.txt
.build/debug/occtl quiet status                 # Focus and call detection on this Mac, read-only
.build/debug/occtl quiet simulate               # a call and a Focus over a scripted timeline, through QuietHold
OpenClicky --render-audio-notices <folder>      # every notice card and the Settings sections, offscreen
```

## Echo-gate tuning

`occtl soundcheck gate-tune` with three recorded Gemini replies and two recorded questions (16 kHz, 40 ms frames) over
modelled rooms. With the voice-processing canceller (22-28 dB of cancellation, laptop speakers at normal and loud
volume) the old defaults (-32 dBFS for 0.35 s) never opened falsely but missed users at -34 dBFS talking over a reply;
the shipped `speakersEchoCancelled` (-36 dBFS for 0.20 s in a 0.6 s window, 0.3 s ring-out) had no false barge-ins and no
misses. Without echo cancellation no setting is safe at loud volume (the voice reaches the mic about as loud as the
user), which is why always-on still asks for headphones there; `speakersRaw` is the least bad at normal volume and is
only used when speakers are allowed without echo cancellation. Full tables:
`docs/evidence/feat-audio-robustness/echo-gate-tuning.txt`. The room is a model: a person has to confirm the values.

## What a person at the Mac has to check

The Mac stayed muted and no microphone, Focus or call permission could be granted while this was built, so these are
unverified:

1. **Mic trouble.** With a USB or Bluetooth mic chosen in Settings > Voice, unplug it mid-press (or mute it with its
   hardware switch): the card says "Reconnecting the microphone…", then "Switched to MacBook … Microphone" with
   Microphone Settings. Pick the USB mic again: the next press uses it (Console, subsystem `app.openclicky`, category
   `audio`: "failover pin dropped"). Hold the keys twice in a row with a muted mic: the dead-air card appears.
2. **Muted output.** Mute the Mac and ask something: no voice, captions only, the reply on the clipboard, the card
   with Unmute. Press Unmute: the Mac unmutes. Set the volume to zero and repeat: Set volume to 50% sets 50%.
3. **Start cue.** With speakers unmuted, the start cue plays only once the mic is live (on AirPods, after the profile
   switch, not swallowed by it). The first cue after launch plays promptly.
4. **Echo cancellation.** On the MacBook's speakers, turn on always-on: the first time it probes (under a second), then
   runs. Let it talk and talk over it at a normal voice: it stops and listens. Let it finish a long answer without
   talking: it never answers itself. Try a USB mic plus speakers and an external display's speakers, and check
   Settings shows the verdict for each.
5. **Quiet contexts.** Join a FaceTime or Zoom call (or a Meet call in Chrome), start a background job, and let it
   finish during the call: no spoken report and a silent notification; hang up: the report is spoken within a few
   seconds. Pin the Focus menu-bar item while Focus is off and verify that output is not held. With Full Disk Access for OpenClicky, turn on Do Not Disturb and repeat. Call detection remains available without Full Disk Access.
