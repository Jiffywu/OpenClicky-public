# Latency of a voice turn

What happens between letting go of the talk keys and hearing the first spoken line, where the time goes, and what
OpenClicky does about it. Measured on a MacBook Air M4 over home Wi-Fi on 31 October 2026 with
`docs/examples/config-cheap.json` (brain Claude Haiku 5.5, voice ElevenLabs Flash v2.5, stt Apple Speech). The raw runs
are kept locally under `docs/evidence/feat-latency/` and are not distributed with the repository. See the
[fixture and evidence policy](testing.md#private-evidence-and-test-fixtures).

## The steps

```
key down ── mic + stt open (warm socket), context prefetch, brain prewarm, voice connection warm-up
key up ──┬─ the last words settle (ears: streamed final, or a fallback)     ~0.1 s Apple Speech, ~0.6 s Gemini Live
         └─ screenshots and context (started at key-up, in parallel)
request ── response head (network, queue, prefill of the uncached turn)    ~0.5 s
           thinking (adaptive, effort low)                                 0 to 4.5 s, by question
           first program text → first complete say() line                 ~0.1 s
first line → first audio (ElevenLabs Flash)                                ~0.16 s
```

`TurnTimings` records each step for every turn (`occtl turn` writes `timing.txt` and `timing.json`; the app logs it).
Since this change it also carries the brain's token use (cache hit or miss, tokens read and written) and the ears'
press report (warm or not, outcome, key down → ready → first text, key up → words).

## Where the time went

`occtl latency brain` sends the brain's real first request (the system prompt and tools, 13.3k tokens, and a turn
message with a screenshot, 1.2k) and times each step from the raw stream. Each variant first sends one request that
warms the prompt cache, then the timed ones (`evidence/feat-latency/probe/*.txt`):

| Question | Thinking | Response head | First say() line, median (range) |
|---|---|---|---|
| "what does the say hello button do" (bridge page, 4 runs) | adaptive, summary streamed (the old default) | 0.54 s | 2.74 s (2.22 to 3.45) |
| same | adaptive, nothing streamed (`hidden`, the new default) | 0.61 s | 1.57 s (1.30 to 1.76) |
| same | off | 0.79 s | 1.06 s (0.95 to 1.12) |
| "how do I change my favorite color here" (4 runs) | summary streamed | 0.55 to 11.7 s (provider queueing) | 2.70 s in the one clean run that thought |
| same | `hidden` | 0.58 s | 1.42 s (1.32 to 1.51) |
| "draw me how a refrigerator keeps food cold" (blank canvas, 3 runs) | summary streamed | 0.55 s | 3.95 s (3.48 to 5.20) |
| same | `hidden` | 0.55 s | 4.24 s (1.74 to 5.11) |
| same | off | 0.62 s | 0.79 s (0.75 to 0.90) |

What this shows:

- **The thinking summary held the answer back.** With `display: "summarized"` Anthropic streams a readable summary
  of the thinking, the thinking block took about 1.2 s longer to close, and the answer text only started after it (on
  short answers the whole program then arrived in one burst). With `display: "omitted"` the same thinking happens (it
  is billed the same) and the answer streams as soon as it ends. Nothing in the voice loop reads the summary, so voice
  turns now use `ThinkingMode.hidden`.
- **Thinking length is the rest of the variance.** Haiku decides per question: a simple pointing answer thinks for
  0 to 0.8 s, a diagram or a 3D figure for 2 to 4.5 s. Turning thinking off answers everything in about a second, but
  the drawings lose their planning (below), so it is not the default.
- **The prompt's size barely matters once it is cached.** The prompt is 14.5k tokens (`--sizes`): the 3D section
  5,466, the 2D language 2,217, the six tool definitions 1,991, media 903, guided steps 719, the rest under 600 each,
  and this turn's notes and screenshot 1,164. With the cache warm, the response head stayed at about 0.5 s with the
  3D section removed (9.1k tokens) and with the tools removed as well (7.0k); the first line moved from 1.42 to
  1.31 s, inside the run-to-run spread (`probe/bridge-page-first-pass.json`, `probe/no-figures-*.json`). Cutting the
  3D section would cost every 3D answer an extra round to fetch it, so the prompt was kept whole. Writing the whole
  prompt to the cache (the warm-up rows) gave response heads of 0.61 to 0.87 s, against 0.5 to 0.8 s when cached.
- **The prewarm works.** At key-down `BrainRuntime.prewarm()` sends the system prompt, tools and thread with one
  output token and the same effort and thinking as the turn (thinking settings are part of the cached prefix on
  Haiku 5.5: switching them rewrote all 14.5k tokens). In the first live turn below it wrote 13,279 tokens in 0.9 s
  while the question was spoken, and the turn read those 13,279 from the cache (`after/q1/brain-log.jsonl`).

## What changed

- **Thinking without the summary** (`ChatRequest.thinking`, `ThinkingMode.summarized | hidden | off`; Anthropic maps
  them to adaptive thinking with `display` `summarized` or `omitted`, or `{type: "disabled"}`).
  `BrainRuntime.defaultThinking` picks `hidden` for Anthropic brains; the prewarm sends the same value.
- **Screenshots at key-up.** The orchestrator starts the capture as the keys come up, alongside the final transcript,
  instead of after it (context prefetch already starts at key-down). Screen capture can't start earlier without
  showing the brain a screen from before the user finished.
- **The voice's connection at key-down.** `ElevenLabsSpeechClient.warmUp()` opens the HTTPS connection with a keyless
  `HEAD` while the user talks (at most once per 30 s), so the first line skips the TCP and TLS handshakes: first line
  → first audio went from 223 to 287 ms (median 233) to 151 to 180 ms (median 164).
- **Warm ears.** The stt slot's Gemini Live socket is opened ahead of key-down (see [voice-loop.md](voice-loop.md#the-ears)):
  a warm press was ready at once; a cold one took 0.42 s to be ready (`ears/gemini-warm`, `ears/gemini-cold`).

## Five turns, before and after

`run-turns.sh` speaks five questions (three on the bridge test page, two on a blank canvas) through `occtl turn` with
the cheap config. "Before" is `origin/main`'s `occtl` (thinking summary streamed, the transcript given as text, so no
real speech recognition). "After" is this branch with `--in qN.wav`: Apple Speech really hears each recording inside
the voice loop, which adds 80 to 180 ms that "before" doesn't pay.

| Question | Before: key up → first line heard | After | Thinking off (not the default) |
|---|---|---|---|
| q1 what does the say hello button do | 2142 ms | 2141 ms | 1176 ms |
| q2 where do I type my password | 1385 ms | 1290 ms | 1608 ms |
| q3 draw me how a refrigerator keeps food cold | 6623 ms | 5030 ms | 1226 ms |
| q4 show me how a gear train changes speed | 5095 ms | 5026 ms | 1880 ms |
| q5 how do I change my favorite color here | 1128 ms | 2142 ms | 1264 ms |
| **median** | **2142 ms** | **2142 ms** | **1264 ms** |

The after median meets the 2.5 s target with real speech recognition in the loop; it ties the before median because
one before run (q5) didn't think at all and one after run (q5) thought for 1.2 s. The controlled comparison is the
probe above. Diagrams and figures still take about 5 s to the first line, all of it thinking.

**Drawing quality.** `compare-q1-q3.png` and `compare-q4-q5.png` put the final frames side by side. With hidden
thinking the drawings are the same kind as before (the thinking is unchanged; differences are run-to-run). With
thinking off, the refrigerator loop came out cramped, with labels over arrows and boxes, so `off` stays an option
(`occtl turn --thinking off`, `BrainRuntimeConfiguration.thinking`) rather than the default.

## Next steps

- Diagrams and figures: a first line before the thinking (thinking off with a short planning comment after the first
  `say()`, or a filler line from brain-fast while the brain thinks) could bring them near 1.5 s; both need a broader
  drawing comparison first.
- ~~The stats HUD~~: done, see below.

## Floating latency stats

Settings → Developer → Floating latency stats (`developer.latency-hud`) shows a small click-through panel in the
top-right corner with the last turn's marks (release → transcript, capture, request, first token, first line, first
audio, heard), the cache hit, the request body size (`TurnTimings.requestBodyBytes`, the encoded request the brain
sent), and the brain thread's items, screenshots, turns and compactions (`LatencyHUDContent`). The panel has no title
bar and ignores the mouse, so `WindowCaptureRegistrar` gives it the `hiddenFromOwnCaptures` role and OpenClicky's own
screenshots leave it out. Offscreen render: `OpenClicky --render-latency-hud <folder>`
(`docs/evidence/feat-w4-voice/latency-hud.png`).

## Measuring

```sh
zsh -c 'source ~/.config/zsh/secrets.zsh >/dev/null 2>&1; source scripts/dev-keys.sh >/dev/null;
  .build/debug/occtl latency brain --config docs/examples/config-cheap.json --image shot.jpg --sizes \
    --variant adaptive-summarized --variant adaptive-omitted --variant off --runs 3'
zsh -c 'source ~/.config/zsh/secrets.zsh >/dev/null 2>&1; source scripts/dev-keys.sh >/dev/null;
  .build/debug/occtl turn --config docs/examples/config-cheap.json --image shot.jpg --in question.wav --out-dir /tmp/turn'
```
