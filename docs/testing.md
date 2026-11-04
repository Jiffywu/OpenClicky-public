# Testing OpenClicky against real providers

Unit tests (`swift test`) never touch the network. To check providers end to end with your own keys, without writing
them anywhere:

```sh
source ~/.config/zsh/secrets.zsh      # or however your shell gets its API keys
source scripts/dev-keys.sh            # maps OPENAI_API_KEY, ANTHROPIC_API_KEY, … to OPENCLICKY_KEY_<NAME>; prints names only
swift build --product occtl
.build/debug/occtl validate docs/examples/config-cheap.json
.build/debug/occtl chat --config docs/examples/config-cheap.json "In one sentence: what is a gyroscope?"
.build/debug/occtl chat --config docs/examples/config-cheap.json --image shot.jpg --tool-test "Point at the Say hello button."
.build/debug/occtl say  --config docs/examples/config-cheap.json --out /tmp/hello.wav "Hi, I'm OpenClicky."
```

`OPENCLICKY_KEY_<NAME>` overrides the Keychain for that process only, which avoids Keychain prompts when rebuilt
development binaries change their code signature.

`docs/examples/config-cheap.json` uses cheap, fast models: Claude Haiku 5.5 as the brain, GPT-5 nano through OpenRouter as
brain-fast, ElevenLabs Flash v2.5 as the voice, Apple Speech for listening, and Claude Code on Haiku as the agent.

## Live results (2026-10-31, MacBook Air M4, home Wi-Fi)

| Check | Model / provider | Result |
|---|---|---|
| Text | claude-haiku-5-5 (Anthropic) | first text 0.66 s, total 1.00 s |
| Text | openai/gpt-5-nano (OpenRouter, chat) | first text 3.16 s (reasoning first) |
| Text | deepseek/deepseek-v4.1-flash (OpenRouter, chat) | first text 0.88 s |
| Text | deepseek-flash (DeepSeek direct, chat) | first text 2.10 s |
| Vision (screenshot JPEG) | claude-haiku-5-5 | read "Hello, Jeff! You picked Green." correctly; first text 0.58 s |
| Vision | deepseek-v4.1-flash, gpt-5-nano (OpenRouter) | both correct; 3.4 s / 3.9 s |
| Tool call (`point_at`) | claude-haiku-5-5 | `{"label":"Say hello","x":67,"y":228}` in 0.94 s |
| Tool call | deepseek-v4.1-flash / gpt-5-nano (OpenRouter) | correct calls in 0.83 s / 3.12 s |
| Voice | eleven_flash_v2_5 (ElevenLabs), voice Sarah | 4.2 s of 24 kHz PCM, first audio 1.38 s |
| Listening | gemini-3.5-transcribe-live (Gemini Live), the 4.2 s ElevenLabs clip | exact transcript; 7 interim updates; first words 0.96 s, final 0.56 s after the audio ended |
| Voice | gemini-3.8-flash-lite-tts (Gemini), voice Kore | 3.9 s of 24 kHz PCM, first audio 1.30 s |
| Always-on voice | gemini-3.8-live (Gemini Live native audio), voice Kore, `occtl realtime` | spoken question answered aloud correctly; first reply audio 0.83 s after the question ended |
| Always-on voice + `capture_screen` | gemini-3.8-live | read a test screenshot correctly (screenshot in the tool response); first reply audio 1.75 s |
| Always-on voice + `send_to_higher_model` | gemini-3.8-live → claude-haiku-5-5 | delegated a "circle the reminder" request; Haiku read the screenshot and Gemini narrated it |
| Brain first request, thinking summary streamed vs hidden | claude-haiku-5-5, `occtl latency brain` | first `say()` line median 2.74 s vs 1.57 s on the same request (4 runs each); thinking off 1.06 s |
| Voice turn with real listening | Apple Speech + Haiku + ElevenLabs, `occtl turn --in`, five questions | key up → first line heard median 2142 ms (1290 to 5030) |
| Ears in the voice loop | gemini-3.5-transcribe-live, warm socket | ready at key-down; key up → words 636 ms |
| Ears fallback | a refused Live model → gemini-3.5-transcribe (the press as WAV) | exact transcript 1058 ms after key up |

`docs/examples/config-realtime-gemini.json` adds the realtime-voice slot on Gemini Live (try
`occtl realtime --config docs/examples/config-realtime-gemini.json --in question.wav --out reply.wav`; see
docs/realtime-voice.md).

`docs/examples/config-cheap-gemini-ears.json` is the cheap config with Gemini Live listening. Try
`occtl turn --config docs/examples/config-cheap-gemini-ears.json --in question.wav --out-dir /tmp/turn` (the stt slot
hears a recording inside the voice loop) and `occtl latency brain --config docs/examples/config-cheap.json --sizes`
(where the brain's time goes; see docs/latency.md).

`docs/examples/config-gemini-voice.json` swaps listening to Gemini Live and the voice to Gemini TTS (try
`occtl transcribe --config docs/examples/config-gemini-voice.json clip.wav`).

Not yet checked live: OpenAI direct (Responses, Realtime voice and speech, TTS, transcription) and Deepgram, because no keys for them
were available.

## Private evidence and test fixtures

Keep generated screenshots, recordings, transcripts, diagnostic exports and run logs in ignored `docs/evidence/` or `.build/evidence/`. References to historical evidence paths in these docs describe local validation runs; those files are not part of a fresh clone. Review exports before sharing them and never force-add them to Git.

Tests use reviewed, non-private inputs under `Tests/Fixtures/`. Do not make a test depend on captured user data or a local evidence directory. The drawing fixture programs, blank canvas and bridge test-page image are retained there so the drawing tests still run without the private archive. `scripts/render-drawing-evidence.sh` reads those fixtures and writes local results under `.build/evidence/drawing/` by default.

Run `python3 scripts/check-publication-files.py` before committing. The existing CI workflow runs the same check when it is requested. It rejects tracked paths matched by `.gitignore`, including files added with `git add --force`.

This public repository starts with fresh history from the cleaned source snapshot. The older development history and its evidence remain in the private archive. Run `python3 scripts/check-stack-provenance.py` from a full public clone to verify the initial import. The check uses public Git objects only. Ignore rules cannot erase a future accidental disclosure from already-published history.
