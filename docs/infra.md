# Provider retries, failure explanations, usage, diagnostics and flags

The infrastructure every engine shares: what happens when a provider has a bad moment, how OpenClicky explains a
provider it can't reach, what each call costs, what goes into a bug report, and the switches that turn these on and
off. The code is in `Sources/OpenClickyKit/Infra/`.

## Where it hooks in

`ProviderResilience` holds the retry policies, the provider diagnostician and the usage recorder. The app installs
one at launch (`AppModel.init`) and so does `occtl` (`main.swift`):

```swift
ProviderResilience.install(.standard(client: "app"))
```

`EngineFactory` picks up the installed one (its `resilience` property) and wraps what it builds:

| Engine | Retries | Explanation when it can't open | Usage recorded |
|---|---|---|---|
| Brain, brain-fast, agent model | HTTP transport (`RetryingHTTPTransport`) | no (the brain already has spoken failures) | tokens per reply |
| Voice | HTTP transport, or the line again before any audio on a WebSocket voice | yes, before the narrator falls back | characters and seconds per line |
| Listening (stt) | HTTP transport, or the session open again on a WebSocket provider | yes, on open and on a socket refused before anything was heard | seconds of audio per session |
| Always-on (realtime voice) | the session open again | yes | tokens (text and audio) per reply |
| Lookups | none | no | one request per call |

A factory built without an installed `ProviderResilience` (tests, the snapshot renderer) builds the bare adapters
exactly as before. `EngineFactory.unwrapped(_:)` returns the adapter inside a metered language model, for code that
needs its concrete type (Anthropic's computer tool in take-over).

## Retries

`RetryPolicy` sets the attempts, the first wait (doubling after that), the longest single wait, the total wait and
jitter. The defaults per slot:

| Slot | Attempts | First wait | Longest wait | Total wait |
|---|---|---|---|---|
| brain | 3 | 0.6 s | 5 s | 8 s |
| voice, stt | 2 | 0.3 s | 1.5 s | 1.5 s |
| realtime-voice | 3 | 0.5 s | 3 s | 5 s |
| brain-fast, agent | 4 | 1 s | 20 s | 45 s |

What is retried: HTTP 408, 409, 425, 429, 500, 502, 503, 504, 520 to 524 and 529, and connections that drop or can't
connect before any answer. A 429 that says the account is out of quota or credit is not retried. Nothing is retried
once any part of an answer has been handed on, so a retry never repeats a spoken line or a tool call.

`Retry-After` is honoured in seconds or as an HTTP date, as is OpenAI's `retry-after-ms` and Gemini's `retryDelay` in
the error body. A provider that asks for a longer wait than the policy's longest wait makes the call fail at once, so a
turn never hangs; the brain then says it is getting too many requests. After the last attempt the adapter gets the
provider's own answer, so its error wording is unchanged.

Each retry is logged at notice level (`app.openclicky`, category `providers`), so it shows up in the diagnostics
bundle. `scripts/flaky-provider-proxy.py` answers the first requests with 529 and forwards the rest to a real
provider, for trying this end to end.

## Explaining a provider that can't be reached

When a listening, voice or always-on session can't open, `ProviderDiagnostician` asks the provider's models list on
its own host (a free GET, with the provider's usual auth header when a key is stored) and classifies the result:

| Verdict | From |
|---|---|
| `region-unsupported` | HTTP 451, or a body naming an unsupported country, region or location (OpenAI, Gemini and Deepgram wordings) |
| `network-blocked` | DNS, connect, TLS or certificate failures; a 403 HTML page (a firewall's); a proxy 407 or a redirect to a portal; or a reachable host whose streaming connection still failed |
| `offline` | no internet connection |
| `no-answer` | the probe timed out: a network that drops the traffic, or a slow provider |
| `key-rejected` | 401, or a 403 that names the key |
| `rate-limited`, `provider-down`, `forbidden` | 429, 5xx, other 403s |
| `reachable` | the provider answered: the problem is this model, voice or request |

Failures that already say what happened (offline, a turned-down key, a region refusal in the error itself) need no
probe. Results are kept for two minutes per provider. The session's error becomes a `ProviderUnavailableError` whose
text is the plain explanation, for example:

> OpenAI doesn't offer its service in your country or region, so always-on voice can't connect. Choose another
> provider for it in Settings → Models.

The notch shows it as the notice for listening (`TurnNotice.listeningFailed`) and for always-on voice; the voice
narrator logs it as the reason it fell back to the Mac's voice; the brain says it (`SpokenError`).

`occtl probe` checks each slot's provider from this Mac (`--no-key` probes the way HeyClicky does, without a key).
`occtl probe --simulate region|blocked|offline|key|down [--slot stt|voice|realtime-voice]` runs the whole failure path
offline with a scripted refusal and probe answer. Settings → Developer has a Check Providers button.

## Usage ledger

Each call becomes one JSON line in `~/Library/Application Support/OpenClicky/Usage/usage-YYYY-MM.jsonl`
(`OPENCLICKY_USAGE_DIR` overrides the folder): the slot, the surface, provider and model, tokens (cached and audio
tokens too), seconds of audio, characters, a cost in US dollars, whether the price was an estimate, the turn it belongs
to, and whether the app or occtl made it. Nothing leaves the Mac.

- **Surfaces.** The turn orchestrator gives each turn a `UsageContext` (a task-local), so the listening, brain rounds,
  spoken lines and lookups of one voice turn share a turn id and the surface `voice turn` (`typed turn`, `job report`,
  `walkthrough` for the other kinds). Records made outside a turn are named after their slot (`listening`,
  `voice lines`, `realtime`, `background text`, `lookups`); occtl's are `occtl`. Dictation cleanup replies (built by
  `AdapterModelClientFactory`) are metered like the other brain-fast calls, under `dictation`, and a stopping limit
  sends cleanup to the local tidy.
- **Background jobs.** Codex and Claude Code report tokens differently: Codex repeats the thread's running total after
  every model call (`thread/tokenUsage/updated`), Claude Code gives one total per run (`result`). `AgentManager` turns
  both into deltas (`AgentUsageMeter`; Codex's last total is kept on the job record as `usageCursor`, so a repeated or
  resumed total isn't counted twice, and a total that went backwards after a relaunch counts in full) and writes each
  delta under the `agent` slot and the `jobs` surface, with the turn `job:<id>#<run>`. A launch that starts a new
  conversation resets the cursor to zero; a Codex job saved before the cursor existed carries on from the running
  total it stored as its usage. A job on a keyed provider is priced from the catalog; a job on the harness's own
  sign-in (a ChatGPT or Claude subscription) is counted without a cost. Long-prompt tiers apply only to a delta known
  to be one model call (a Codex total's growth since the last report); Claude Code's per-run total and a first or
  restarted Codex total can add up several calls, so they are priced at the base rates. Settings → Usage and
  `occtl usage` have a "Background jobs" table per job.
- **Prices.** `model-catalog.json` gives prices per model (`price`: per million input, cached input, cache-write and
  output tokens, audio tokens, per minute of audio heard or spoken, per thousand characters, long-prompt tiers) and per
  lookup service
  (`servicePrices`). Each price names its source. A model declared in the config can carry its own `price`, as
  `docs/examples/config-cheap.json` does for its OpenRouter models. On-device models are free. A call without a known
  price keeps its tokens and shows `—`; totals that leave such calls out are marked `+`, estimates `≈`.
- **Every catalog model has a price or an explicit `priceUnknown` reason** (a test checks it). Published prices
  (checked 2026-11-03): OpenAI's realtime models by text and audio tokens, Gemini 3.8 Live by text and audio tokens,
  Deepgram Nova-3 per minute, Anthropic's models with their 5-minute cache-write rate. Estimates, marked `≈`:
  `gpt-4o-mini-transcribe` and `gpt-transcribe` (OpenAI's own per-minute estimates), `gemini-3.5-transcribe-live`
  (Google's blended per-minute estimate), the Gemini and OpenAI voices (priced in tokens; converted at about four
  characters a token and per minute of speech), and ElevenLabs, Brave and Exa (they bill in credits or plans). Gemini's
  TTS prices double from 2027-01-01; the catalog has the 2026 ones.
- **Cache writes.** Tokens written to a provider's prompt cache (Anthropic's `cache_creation_input_tokens`, Codex's
  `cacheWriteInputTokens`) are recorded as `cacheWriteTokens` and priced at `cacheWritePerMillion` when the model has
  one (plain input otherwise).
- **Limits.** `limits.json` beside the ledger holds an optional daily and monthly limit, the share at which to warn
  (80% by default), and whether to stop. Warnings show in the menu and on Settings → Usage, and crossing a level is said
  once per day or month (`UsageLimitAlerter`, fed from the ledger's record callback) as a macOS notification and a notch
  card with a Usage button. With stopping on, the
  brain, the voice and listening refuse new calls with `UsageLimitError` ("You've reached the spending limit you set
  for today…") until the limit is raised. Background jobs on a keyed provider don't launch at a stopping limit, and
  running ones are stopped at their next usage report once the limit stops calls; jobs on the harness's own sign-in
  aren't billed per token and keep going. Limits count calls from the app and occtl alike.

`occtl usage [--days n] [--json]` prints totals by day, slot, surface, provider and model, recent turns with their
cost, and the limits; `occtl usage limits --daily 2 --monthly 30 --stop` sets them; `occtl usage prices` lists what
each slot costs. Settings → Usage shows the same for today, 7 or 30 days and edits the limits.

Job usage is what the harnesses report: tokens a harness spends outside its reports (its own retries, a crash before
the report) are not seen.

## Diagnostics bundle and Report a Bug

`DiagnosticsBundle.write` makes `~/Library/Application Support/OpenClicky/Diagnostics/openclicky-diagnostics-<time>/`
and a zip of it (`/usr/bin/ditto`):

| File | Holds |
|---|---|
| `summary.txt` | version, macOS, hardware, install location (and App Translocation), displays, slots, missing keys, changed flags, usage, brain session, the user's note |
| `system.json` | the same in detail, with every display's size and refresh rate |
| `app-state.json` | turn phase, always-on, permission states, config problems, the last turn's timings (app) |
| `config.json` | the config with header values and URL credentials and queries replaced |
| `credentials.json` | which credentials are stored or missing, never their values |
| `flags.json` | every flag, its value, default and reader |
| `usage-7-days.json` | the ledger's last week and the limits |
| `brain.json` | the brain session's stats (app) |
| `unified-log.txt` | `/usr/bin/log show --last 30m` for OpenClicky's subsystem plus errors from its processes, stopped after 20 s |

Every file passes through `SecretScrubber`: bearer and key headers, provider key shapes (Anthropic, OpenAI, OpenRouter,
ElevenLabs, Google, GitHub, Slack, AWS), JWTs, OAuth and key parameters in URLs, key-like JSON fields, long hex runs,
every `OPENCLICKY_KEY_*` and `*_API_KEY` value in the environment, and the home folder's path (shown as `~`).

Settings → Developer and General have **Report a Bug…**: it writes the bundle, shows the zip in Finder and opens a new
GitHub issue with the summary filled in, for the user to attach the zip. **Save Diagnostics Only** skips the issue.
`occtl diagnostics [--out dir] [--no-log] [--log-minutes n] [--note text]` does the same from the command line.
Nothing is uploaded; there is no crash reporter.

## Feature flags

`FeatureFlag.all` is the one typed registry of boolean switches, each with a default, a group, a summary, what reads it
(`readBy`, nil when nothing does yet) and the HeyClicky defaults keys it stands in for. Values the user changed live in
`~/Library/Application Support/OpenClicky/flags.json`, shared by the app and occtl.

| Flag | Default | Read by |
|---|---|---|
| `providers.retries` | on | `ProviderResilience.standard` |
| `providers.diagnosis` | on | `ProviderResilience.standard` |
| `usage.ledger` | on | `ProviderResilience.standard` |
| `diagnostics.unified-log` | on | `DiagnosticsBundle` |
| `developer.brain-stats` | on | Settings → Developer |
| `developer.latency-hud` | off | `LatencyStatsPanel` (`VoiceLoopController.refreshLatencyHUD`): the floating latency stats panel, left out of OpenClicky's own screenshots; it now stands in for HeyClicky's `ClickyOneBrainStatsHUD` |
| `brain.reads-connected-apps` | on | `BrainWiring.tools` and always-on voice's tools: off leaves `read_connected_apps` (and the connected-app prompt lines) out |
| `brain.keeps-screens` | off | `BrainWiring.makeRuntime`: on keeps up to 24 screenshots in the thread instead of the newest 3 |
| `drawing.sounds` | on | `DrawingSoundPlayer`, together with Settings → Voice → Play drawing sounds |
| `drawing.saves-lessons` | off | `VoiceLoopController`: on, `DrawingLessonRecorder` keeps each drawing with its narration and screenshot under `<history>/lessons/<turn>/` |
| 5 more (drawings kept in chat, job labels in the activity strip, notch sounds, the pinned skill, the onboarding language step) | as HeyClicky | feature not built yet: kept so the choice survives until the feature lands |

Five former flags are regular settings instead, and `HeyClickyFlagKeys` points their HeyClicky keys there: captions
under drawings (Settings → Voice → Show the line being spoken as a caption), job voice and text announcements and job
suggestions (Settings → Agents, `agent-settings.json`), and the meeting countdown (the notch's settings,
`notch.json` `meetingCountdown`).

`HeyClickyFlagKeys.all` accounts for 59 `Clicky*` keys from HeyClicky 1.1.2's strings: 12 covered by a flag, 19 by a
regular setting (the brain and agent slots, Settings → Voice, Microphone, Agents, Connected apps, Talk keys, the notch),
28 dropped with the reason (hosted videos, server-gated developer access, the paywall, Library and Stream modes whose
purpose is unknown, live notes and other unbuilt surfaces).

Settings → Developer offers only flags something reads as switches (`FeatureFlag.developerSwitches`), grouped; flags
for unbuilt features are listed under **Not built yet** with a badge and no switch (`FeatureFlag.notBuilt`). The page
also has the key list, the brain session's stats with **Start a Fresh Session** (ends the thread and writes its memory
notes), Check Providers and Report a Bug. `occtl flags` (unbuilt ones marked "feature not built yet"),
`occtl flags set <id> on|off`, `occtl flags reset` and `occtl flags keys`.

## CI

`.github/workflows/ci.yml` builds, runs `swift test` and the extension's node tests on a GitHub-hosted macOS runner
(the newest Xcode on `macos-26` by default). The repository is private, so macOS minutes bill at ten times the Linux
rate (a clean run is roughly 100 to 200 included minutes). It never runs on push: start it from the Actions tab, or
add the `run-ci` label to a pull request (each push while the label is on runs it again).
