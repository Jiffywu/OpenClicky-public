# 06 — Background agent harness (H1 / clicky-harness, Codex app-server, jobs, Clickies, routines)

Status: clean-room behavioral reconstruction of HeyClicky 1.1.2 (build 69, git `changelog/v1.1.2` @ `9bd03d487`).
Scope: everything that runs "background work" for the user — the agent runtimes, how the app launches and
talks to them, the on-disk job/agent layout, the final-message contract the app parses, routines and server
"Remote Tasks", notifications, usage/lease accounting, and the voice-brain tools that steer agents.

Evidence legend used throughout:

- **OBSERVED** — seen in an artifact. Paths are abbreviated:
  - `APP` = `openclicky-evidence/HeyClicky-1.1.2-b69.app/Contents`
  - `MAIN` = `APP/MacOS/HeyClicky` strings / Swift field metadata (arm64 slice)
  - `H1JS` = the JavaScript bundle embedded in `APP/Helpers/clicky-harness` (`__BUN,__bun` section)
  - `DATA` = `~/Library/Application Support/Clicky`
- **INFERRED** — my reasoning from observed facts.
- **UNKNOWN** — not recoverable from the client (server logic, server prompts, exact server schemas).

Nothing in this document is copied prompt text; prompt content is paraphrased. No secrets were read into this
doc (auth.json, BrowserBridge/connection.json, MCP tokens, and the session token were not printed).

---

## 1. One-paragraph summary

HeyClicky hands "real work" (research, files, app actions) to a background agent that runs in a per-job folder
under `DATA/projects/jobs/<slug>-<10hex>/` (one-off jobs) or a per-agent folder for kept agents ("Clickys").
In 1.1.2 the **default runtime is "H1"**, HeyClicky's own agent loop, shipped as `Helpers/clicky-harness`
(a Bun 1.4.1 single-file executable containing an `agent-harness` JS project built on
`@earendil-works/pi-coding-agent`). The Swift app spawns it once, talks to it over a token-protected
localhost HTTP API (`/turn`, `/events` long-poll, `/steer`, `/cancel`, `/prewarm`), and translates its events
into the same internal notification vocabulary the app uses for the older **Codex app-server** runtime
(JSON-RPC over stdio, `CODEX_HOME=DATA/CodexHome`, custom `model_provider = "clicky"` pointing at
`https://api.heyclicky.com/agent/openai/v1`). All model traffic is proxied through HeyClicky's server using a
short-lived backend session token as the bearer. The agent ends every turn with a report plus machine-readable
tag blocks (`<SUMMARY>`, `<ANSWER>{json}`, `<ARTIFACTS>`, `<NEXT_ACTIONS>`, `<ROUTINE>{json}`, `<WAIT_FOR>{json}`,
`<COMPUTER_USE_REQUEST>`, `<LEARNED>`, `<DONE_TITLE>`) that the app parses into result cards, follow-up chips,
schedules and consent requests. A voice "brain" controls agents with tools such as `sessions_spawn`,
`sessions_send`, `sessions_answer_request`, `session_status`, `clicky_memory`, `find_jobs`, `read_job` and a
`routines` tool. Usage is metered per turn by a server "turn lease".

---

## 2. Architecture

```
            ┌──────────────────────── HeyClicky.app (Swift, not sandboxed) ─────────────────────────┐
 voice/text │ OneBrain (server brain) ──tool calls──► CompanionManager+CodexAgent / +CodexAgentTurn │
  "brain"   │   sessions_spawn / sessions_send / sessions_answer_request / session_status / ...      │
            │                                       │                                                │
            │        ┌──────────── AgentHarnessRuntime (protocol) ─────────────┐                     │
            │        │                                                          │                     │
            │  AgentHarnessRunnerRuntime (harness=h1, place=mac)     CodexAgentSession (harness=codex)│
            │        │  HTTP 127.0.0.1:<port>, Bearer CLICKY_HARNESS_TOKEN       │ JSON-RPC lines/stdio │
            │        ▼                                                          ▼                     │
            │  Helpers/clicky-harness (Bun)                         CodexRuntime/.../codex app-server │
            │    runner ─► driver "h1-mac" ─► h1-local job server ─► H1 workflow (agent loop)         │
            │        │                        (127.0.0.1:<port2>, random token)                       │
            │        └── local-mcp bridge (stdio MCP → HTTP) ; device helper (cloudflared, cloud only)│
            │                                                                                         │
            │  ClickyLoopbackMCPServer  http://127.0.0.1:<port>/mcp  tools: browser, mac_step         │
            │  ClickyJobs / ClickyRoster / ClickyWorkFolderFiles / ClickyRoutines / AgentCrons / ...  │
            └─────────────────────────────────────────────────────────────────────────────────────────┘
                     │ Bearer <agent session token>
                     ▼
     api.heyclicky.com:  /agent/openai/v1/responses(+/compact)   /agent/harness/model/anthropic/v1/messages
                          /agent/web-search  /agent/composio/session (Composio MCP)  /agent/session-token
                          /agent/turn-lease/*  /agent/record-agent-launch  /agent-messages  /codex-thread-launch
                          /agent/cron/*  /agent/notifications*  /agent/integrations*  /me/memory
```

---

## 3. Components and responsibilities

Swift source files are OBSERVED as `HeyClicky/<file>.swift` strings in MAIN; type/field names come from the
`__swift5_fieldmd` metadata of MAIN.

| Component (OpenClicky name suggestion) | HeyClicky evidence | Responsibility |
|---|---|---|
| Harness selection | `AgentHarness` {codex, pi, h1}; `AgentHarnessPlace` {mac, cloud}; `AgentHarnessModel` {standard, luna, haiku}; `AgentHarnessPreferences`; defaults keys `ClickyAgentHarnessModel`, `ClickyAgentHarnessDeviceHelperOff`, `ClickyAgentHarnessNoteToolsOff` | Picks which runtime runs a job. Default: h1 on mac (UI text "The default: H1 on this Mac"). |
| Runner process | `AgentHarnessRunnerProcess` (process, stdinPipe, endpoint{port, token}, starting), `AgentHarnessReadyLineReader`, `AgentHarnessRunnerRuntime.swift` | Spawns `Helpers/clicky-harness`, reads its ready line, owns its lifetime. |
| Runner runtime | `AgentHarnessRunnerRuntime` (harness, place), `AgentHarnessTurn`, `AgentHarnessTurnContext`, `AgentHarnessMCPServer`, `AgentHarnessLocalMCPCommand`, `AgentHarnessEvent`, `AgentHarnessError` {notAvailable, failed} | Sends turns, long-polls events, maps events to the app's Codex-style notifications. |
| Codex process | `CodexProcessManager`, `CodexLaunchConfiguration` (executableURL, arguments, pathPrefixes), `CodexProcessManagerError` {bundledCodexRuntimeMissing, codexExecutableNotFound}, `CodexRuntimeBridge.swift` | Launches `codex app-server` with isolated `CODEX_HOME`, sweeps orphans. |
| Codex home | `CodexHomeManager` (clickyDirectoryName, codexHomeDirectoryName, codexSkillsDirectoryName, managedModelInstructionsFileName, agentProjectsDirectoryName, ...), `ClickyBundledCodexAssets` | Creates `DATA/CodexHome`, writes `config.toml`, syncs skills, instructions file. |
| Codex protocol | `CodexProtocolClient`, `CodexRPCLineFramer`, `CodexRPCRequest`, `CodexRPCNotification`, `CodexIncomingMessage`, `CodexRPCLog`, `CodexStartupTimeoutError` | Newline-delimited JSON-RPC 2.0 over the child's stdin/stdout. |
| Codex session | `CodexAgentSession` (callbacks onTurnCompleted, onTaskProgress, onAgentCommentary, onTaskPlanUpdated, onTaskFinished/Failed/Interrupted, onMCPServerStartupStatusUpdated, ...) | Thread/turn management, streaming, steering, interrupts. |
| Task model | `CodexRunningTask`, `CodexTaskViewModel`, `CodexTaskLifecycleState` {queued, running, completed, failed, interrupted}, `CodexTaskActivityItem`/`Type` {commentary, thinking, toolCall, shellOutput, fileChange, error} | UI state for one running agent turn. |
| Turn launch | `CompanionManager+CodexAgentTurn.swift`, `CodexAgentTurnLaunchRequest`, `CodexAgentTurnPromptBuilder`, `AgentLaunchTimingLog` | Builds the brief, gets labels, leases, starts/steers turns. |
| Lease / usage | `CodexAgentTurnLease`, `CodexAgentTurnLeaseRequestBody/ResponseBody/CompletionRequestBody/ContinueRequestBody`, `CodexExtraUsageApprovalMode` {oneTime, asManyAsNeeded}, `ClickyAgentTurnCostLedger`, `ClickyAgentTurnUsageRecord`, `AgentPaywallHUDWindow.swift`, `PlanSnapshot` | Metering, extra-usage approval, paywall. |
| Jobs | `ClickyJobs.swift`, `ClickyJob`, `ClickyJobStore`, `ClickyJobRailPhase`, `ClickyJobKind`, `ClickyJobMessageRoute`, `ClickyJobUserSteps.swift` (`ClickyJobUserStep`, `ClickyJobStepWatcher`) | One-off background jobs and their folders. |
| Work folder files | `ClickyWorkFolderFiles.swift` | Writes `WORK.md` index, per-job `report.md`, `.clicky/owner`, `.clicky/previous-note.md`. |
| Kept agents | `ClickyRoster.swift` (`StoredRoster.CreatedClicky`), `ClickyRestartInterruptions.swift` | Persistent named agents with AGENTS.md persona. |
| Routines (local) | `CompanionManager+ClickyRoutines.swift`, `ClickyRoutine`, `ClickyRoutineRunMarker`, `ClickyRoutineNetworkObserver`, `ClickyRoutineFullWakeObserver`, `ClickyRoutineKeepAwake`, `CodexAgentRoutineRequest` | On-device scheduler that re-runs a job's task. |
| Remote Tasks (server cron) | `CompanionManager+AgentCrons.swift`, `ScheduledAgentCron*`, `AgentCronRunNowResponse` | Lists/inspects/runs server-side scheduled tasks. |
| Notifications | `CompanionManager+AgentNotifications.swift`, `AgentNotification`, `AgentNotificationSeverity` | In-app agent notifications from the server. |
| Progress stream | `CompanionManager+AgentCommentaryStream.swift` | Feeds agents' progress lines to the voice brain as silent context. |
| Loopback MCP | `ClickyLoopbackMCPServer.swift`, `CodexLoopbackMCPEndpoint` (url, bearerTokenEnvironmentVariable) | Localhost MCP server exposing `browser` and `mac_step` to agents. |
| Surfaces | `NotchAgentSurface`, `ClickyEdgeShelf/Deck/StackInk*`, `CodexLaunchFlight*`, `HeyClickyChatHandOffs`, `ClickyResultCardFace`, `ClickyUsageCardPopover` | HUD, right-edge job rail, launch animation, result cards. |

---

## 4. Choosing a runtime

OBSERVED (MAIN strings + enum cases):

- `AgentHarness` cases: `codex`, `pi`, `h1`. Settings descriptions (paraphrased):
  - **h1** — the default. Runs locally in HeyClicky's in-house runner, or remotely on a cloud worker (`lab Worker`) that is paired with a device helper on the Mac.
  - **pi** — `pi-coding-agent 0.87.1`. Runs locally with access to the job's skills and connected apps, or remotely in a cloud sandbox.
  - **codex** — the Codex app-server shipped inside the app, run locally, or Codex hosted in a cloud sandbox.
- `AgentHarnessPlace`: `mac` ("On this Mac"), `cloud` ("In the cloud").
- `AgentHarnessModel`: `standard` ("Default"), `luna` ("GPT-6 Luna", id `gpt-6-luna`), `haiku` ("Claude Haiku 5.5", id `claude-haiku-5-5`).
- In this build the runner registers only one driver: `"h1-mac"` (last line of H1JS). A turn whose
  `${harness}-${place}` key is anything else fails with "No <key> harness in this runner." The app also has the
  string "The agent harness isn't set up in this build." and "<x> isn't available in this build."
- Model mapping inside the driver (H1JS `m_`): haiku → `claude-haiku-5-5`; place≠cloud → `gpt-6-luna`
  (always, regardless of the "standard" choice); cloud → `gpt-6-luna` if asked, else `gpt-6-sol`.

INFERRED: in 1.1.2 every job effectively runs as H1 on the Mac with `gpt-6-luna` (or Haiku if a developer
toggles it). Codex remains as a legacy/alternate path; cloud and pi paths are scaffolding.

Thread identity: app thread ids for harness jobs look like `harness-h1-mac-<UUID>` (OBSERVED dir names in
`DATA/AgentHarness/*`). The app keeps a map app-thread → harness-thread in UserDefaults under the prefix
`ClickyAgentHarnessThreadMap.` (OBSERVED key prefix). The app's history code knows "A harness conversation has
no Codex history" and rebuilds transcripts for harness jobs from `h1-local/<job>/turns.json` and
`events.jsonl` (OBSERVED strings `turns.json`, `events.jsonl`, `"kind":"tool_call"`, `"kind":"message"`,
`"kind":"turn_end"`, `finalText`).

---

## 5. `Helpers/clicky-harness` (H1)

### 5.1 What the binary is (OBSERVED)

- Universal Mach-O (arm64 + x86_64), ~136 MB, links only libicucore, libresolv, libc++, libSystem.
- Has a `__BUN,__bun` section (2.38 MB) and `__TEXT,__bun_builtins` → **Bun single-file executable**.
  Embedded runtime string `Bun v1.4.1`.
- Bun virtual FS entries: `/$bunfs/root/clicky-harness-arm64` (the JS entry, ~500 KB minified, header
  `// @bun`) and `/$bunfs/root/photon_rs_bg-bq08arze.wasm` (Rust `photon-rs` image library, wasm-bindgen,
  used for image resizing/JPEG re-encode).
- Build-path strings show the source project is a folder named `agent-harness` whose dependency is
  `@earendil-works/pi-coding-agent` (a fork/rename of the "pi" coding agent; its `piConfig`/`*_CODING_AGENT_DIR`
  plumbing and tool set `read, bash, edit, write, grep, find, ls` are present).
- Entitlements: `com.apple.security.cs.allow-jit`, `com.apple.security.cs.allow-unsigned-executable-memory`
  (needed by JavaScriptCore JIT in Bun).
- Dev override (MAIN): UserDefaults `ClickyAgentHarnessRunnerPath` (expects `agent-harness/runner.mjs`) and
  `ClickyAgentHarnessNodePath` (searches `~/.local/share/mise/installs/node/*/bin/node`, `/opt/homebrew/bin/node`,
  `/usr/local/bin/node`, `~/.nvm/versions/node`). The `Launch` enum has cases `bundled(URL)` and
  `node(node:script:)`. If neither exists: "This build has no agent harness runner".

### 5.2 Process launch and the runner protocol

Launch (OBSERVED MAIN + H1JS):

- Executable: `Contents/Helpers/clicky-harness` (no args).
- Environment: `CLICKY_HARNESS_TOKEN` = random secret per launch; `CLICKY_HARNESS_STATE` =
  `DATA/AgentHarness`; `PATH` prefixed with `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/share/mise/shims`,
  `/usr/bin`, `/usr/sbin`. A list of Xcode/Metal debug env-var prefixes (`__XPC_DYLD_`, `GPUTOOLS_`,
  `MTLCAPTURE_`, `MTL_DEBUG_LAYER`, …) sits next to the runner strings (OBSERVED); INFERRED: they are removed from
  the inherited environment before spawning.
- stdin is a pipe kept open by the app. The runner exits when stdin reaches EOF (parent died) and on
  SIGTERM/SIGINT/SIGHUP.
- On start the runner listens on `127.0.0.1:0` and prints exactly one line to stdout:
  `{"ready":true,"port":<n>}`. The app waits up to **20 s** ("didn't start within 20 s"). stderr lines are logged
  as `[harness runner] ...`. Unhandled promise rejections are logged and swallowed (runner keeps running).

Runner HTTP API (all requests need `Authorization: Bearer <CLICKY_HARNESS_TOKEN>`, else 401; JSON in/out):

| Method + path | Request | Response | Notes |
|---|---|---|---|
| `POST /turn` | Turn object (below) | `{ok:true, after:<seq>, turnRef:"t<n>"}` | If the job is mid-turn, waits up to 25 s for it to finish, else error "still working on its current turn". If a cancel arrived during that wait, immediately emits `turn_end{status:"interrupted"}`. |
| `POST /prewarm` | arbitrary | `{ok, started}` | Hook to warm a job; in the h1-mac build it is a no-op returning false (OBSERVED `vf=()=>!1`). |
| `POST /steer` | `{job, text, info?}` | `{ok:true}` or `{ok:false, reason:"not running"\|"cannot steer"}` | App shows "This agent can't take a message right now..." on not-running. |
| `POST /cancel` | `{job, place?}` | `{ok:true}` | Increments the job's cancel counter; driver interrupts (local) or cancels (cloud). |
| `GET /events?job=<id>&after=<seq>&wait=<ms>` | – | `{events:[...≤400], latest:<seq>}` | Long-poll; wait capped at 25 000 ms. App uses `after=0&wait=0` to resync, then `wait=20000`. |

Turn object sent by the app (OBSERVED key names from MAIN strings and the H1JS consumer; Swift
`AgentHarnessTurn` + `AgentHarnessTurnContext`):

```jsonc
{
  "job": "harness-h1-mac-<uuid>",      // harnessThreadID
  "harness": "h1", "place": "mac",
  "text": "<brief or follow-up text>",
  "images": ["/abs/path/screen-1.jpg"],  // imagePaths (png => image/png else image/jpeg)
  "workspace": "/…/projects/jobs/<slug>-<hex>",
  "model": "standard|luna|haiku",        // AgentHarnessModel (mapped by m_)
  "mcp": [ { "name","url","token?","headers?","meta?" } | { "name","command","args","env" } ],
  "skills": ["/abs/skill/dir", ...],     // each must contain SKILL.md
  "leaseMetadata": { "clicky_agent_turn_lease_id": "...", "clicky_agent_turn_id": "...", "clicky_agent_task_id": "..." },
  "worker": { "base": "https://api.heyclicky.com", "sessionToken": "<agent session token>" },
  "deviceHelper": true,                  // cloud only
  "note": { "tools": true, "path": "<workspace>/note.md", "kept": false },
  "planTool": true,
  "instructions": "<developer instructions text>" // AgentHarnessTurnContext.instructions
}
```

Runner job bookkeeping: per job id it keeps `{events[], seq, waiters[], running, cancels, turns}`; only the
newest 2 000 events are retained; every event gets `{seq, t:<ms epoch>, turnRef}`. Non-log events are echoed to
stderr as `[harness <job>] <kind>`.

### 5.3 Driver `h1-mac` (OBSERVED H1JS `gf`, `I_`, `k_`)

State file: `CLICKY_HARNESS_STATE/h1-mac/<job>/h1.json` =
`{jobId, turn, lastSeq, pendingAsk, helperBase, noteTools, dead, started, restarts?}`; plus an append-only
`h1-rounds.jsonl` of per-model-round and per-tool timing records:

- round: `{kind:"round", t, ms, firstOutputMs, model, effort, input, cached, output, reasoning, calls:[tool names], requestBytes, error}`
- tool: `{kind:"tool", t, ms, name, server, ok, resultChars, error, slugs?}` (slugs for Composio multi-execute)

Turn algorithm:

1. Normalize MCP list: stdio servers (`command` present) are wrapped by the **local-mcp bridge** (5.9) and
   replaced with `{name, url:"http://127.0.0.1:<p>/mcp/<id>", token, optional:true}`.
2. Resolve the job endpoint: local → start (once) the in-process **h1-local job server** (5.4) and point model
   URLs at the HeyClicky worker base; cloud → `${worker.base}/agent/harness/lab/h1` with the session token.
3. If no job yet (or the previous one is `dead`), create it: `POST /jobs {job:<id>[-r<restarts>], cfg}`.
   `cfg` (OBSERVED in `DATA/AgentHarness/h1-local/*/job.json`):
   `model, effort:"medium", web:"exa"|"hosted"|"brave", instructions, cacheKey (job id ≤64), mcp[], workspace,
   timezone (IANA), instance:"standard-2", limits{maxSteps:120, wallMs:1800000, bashTimeoutS:300}, env{},
   tunnel|null, stripOlderUserImages:false, prewarm:true, earlyStart:false, reasoningSummary:true,
   asyncTools (true for gpt-6*), scriptMode:"only" (local), noRoutinesTool:true (local), noteTools{path,async}?,
   noProgressTool?, planTool?`. Web provider: local probes `GET /agent/web-search` once per base (4 s timeout);
   `{available:true}` → `"exa"`, else `"hosted"` (OpenAI hosted `web_search` tool). Cloud uses `"brave"`.
   Cloud also uploads the workspace and skill folders as base64 file batches (`POST /jobs/<id>/files`,
   ≤4 MB per batch, files ≤2 MB, ≤30 MB total, skipping `.git node_modules tmp .venv __pycache__ .DS_Store`).
4. If `pendingAsk` is set, this turn's text is the user's answer: `POST /jobs/<id>/answer {ask, text, metadata}`.
   Otherwise increment `turn`, upload each image as a blob (`PUT /jobs/<id>/blob/turn<N>-img<i>` raw bytes),
   `POST /jobs/<id>/start` once, then `POST /jobs/<id>/turn {n, turn:{text, images:[{blob,mime}], clock:"turn"}, mcp, instructions, metadata}`
   where metadata = leaseMetadata + `clicky_harness:"h1"`. When the job has note tools, a note-writing guide is
   appended to the text; if note tools are off but a note is expected, a one-line hint to write `note.md` with
   file tools is appended instead.
5. If the endpoint answers 404/410 ("job is gone"), mark dead, start a new job once, and retry.
6. Long-poll `GET /jobs/<id>/events?after=<lastSeq>&wait=20000` and translate (table 5.10) until a terminal
   event. `question` events end the runner turn as "completed" with the question text (plus "Options: a · b")
   as the answer and store `pendingAsk` — the user's next message becomes the answer.
7. Cloud only: after the turn, download `GET /jobs/<id>/workspace.tgz` and copy the job folder back (local returns
   409 `notStarted` because H1 on the Mac works in the folder itself).
8. Emit `answer{text}` (citation markers stripped), `stats{...}`, `turn_end{status, error?}`.

Steer: `POST /jobs/<id>/steer {text, turn, info?}`. Cancel: local → `/interrupt`; cloud/lab → `/cancel`.
A timed-out turn reports (paraphrased) that it hit the 30-minute per-turn maximum and that a retry resumes where
it stopped.

### 5.4 Job endpoint API (h1-local server and cloud "lab" worker share it)

The local job server listens on `127.0.0.1:0` with its own random bearer token (48 hex chars). Paths match
`^/jobs(/<id>(/<verb>(/<arg>)?)?)?$`; job ids must match `[A-Za-z0-9_-]{1,100}`.

| Route | Body | Result |
|---|---|---|
| `POST /jobs` | `{job, cfg}` | `{job, ok:true}` or `{job, exists:true}` |
| `POST /jobs/:id/files` | `{files:[{path,b64,mtimeMs}]}` | `{ok, n}` (local ignores) |
| `PUT /jobs/:id/blob/:key` | raw bytes | `{ok, blob}` |
| `POST /jobs/:id/start` | `{}` | `{ok}` (starts the workflow run) |
| `POST /jobs/:id/turn` | `{n, turn, mcp?, instructions?, metadata?}` | `{ok}`; 410 if job ended. Changing the MCP list or instructions triggers an MCP re-list. |
| `POST /jobs/:id/answer` | `{ask, text(≤4000), metadata?}` | `{ok}`; delivers workflow event `answer-<ask>` |
| `POST /jobs/:id/steer` | `{text(≤60000), turn, metadata?, info?}` | `{ok, sequence}` or `{ok:false, reason}` |
| `POST /jobs/:id/interrupt` | – | `{ok}` |
| `POST /jobs/:id/cancel` | – | `{ok}`; emits `cancelled`, marks done |
| `GET /jobs/:id/events?after&wait` | – | `{events, latest, done?}` |
| `GET /jobs/:id/workspace.tgz` | – | tarball (cloud) / 409 (local) |
| `GET /agent/harness/lab/h1/probe?url=` | – | cloud tunnel reachability check |

Jobs are restored from disk on demand after a runner restart ("H1 job <id> restored from disk (N turns)"); an
interrupted cut-off turn is re-interrupted on restore. Job dirs older than **30 days** are deleted at startup.

### 5.5 Workflow engine (the H1 agent loop)

OBSERVED: the loop is written as a durable workflow class (`class … extends <WorkflowEntrypoint-like>` with
`run(event, step)`, `step.do(name, retryConfig, fn)`, `step.waitForEvent(name, {type, timeout})`,
`NonRetryableError`, an `env.JOBS` object-store binding). INFERRED: it is designed to run unchanged on
Cloudflare Workflows + Durable Objects in the cloud, and locally via a file-backed emulation (`h1-local`).

Local persistence (`DATA/AgentHarness/h1-local/<job>/`, OBSERVED):

| File | Content |
|---|---|
| `job.json` | `{cfg, done, started, ...}` (cfg as in 5.3; MCP entries include bearer tokens — treat as secret) |
| `turns.json` | `{"<n>": {text, images:[{blob,mime}], clock:"turn"}}` |
| `steps.jsonl` | memoized step results `{key, value:{v, t0, t1}}` or `{key, error, nonRetryable}`; keys like `do:setup`, `wait:turn 1`, `do:model 3`, `do:tools 3`, `do:write 3 <call_id>`, `compact 1`; duplicates get `#n` suffixes |
| `events.jsonl` | every emitted event (see 5.10) with `key, seq, t` |
| `blobs/` | URL-encoded keys: `turn1-img0`, `img:<call_id>:<i>`, `mout:<n>` (large model outputs), `compacted:<n>` |

Step retry policies (OBSERVED constants):

| Step type | Retries | Delay | Timeout |
|---|---|---|---|
| default (`setup`, bookkeeping) | 4 | 1 s exponential | 3 min |
| model call | 3 | 4 s exponential | 15 min |
| compaction | 2 | 3 s exponential | 10 min |
| long tool step | 2 | 2 s exponential | 45 min |

Turn loop (per user turn):

1. `setup` (first time): read cfg, list MCP tools for every server (retry 6×, optional servers 2×, backoff
   1 s·i), read turn 1. Emits `mcp_tools{servers:[{server,ok,tools,error}]}`.
2. Repeat model rounds until the model returns a message with no function calls, `maxSteps` (120) is hit, or the
   wall clock (30 min) runs out:
   - Build input: developer message (`instructions`) + history + queued steering notes. Images referenced as
     `h1blob:<key>` are inlined as data URLs after resizing.
   - Call the model (5.6). Stream `reasoning` summaries, `commentary` (assistant text that accompanies tool
     calls), `plan` updates, and `model_request` accounting events.
   - Execute tool calls (in parallel where allowed). Write-like tools record a **side effect** with an
     idempotency key and receipt so a crash/retry never repeats them; these are preserved through compaction.
   - `ask_user` emits `question{ask, text, choices≤6}` and waits for `answer-<ask>` up to **30 min**
     (3 attempts); with no answer the tool returns a fixed "user did not answer; assume and say so" instruction.
   - When the turn would end, an optional "closing check" (note tools) asks the model to fix the note first.
3. Emit `message{phase:"final", text, turn}`, `steps{turn, timeline, rounds}`,
   `turn_end{turn, status, reason, finalText, modelSteps, workflowSteps, routineBlocks, searches, lateMessages}`.
4. Wait for `turn-<n+1>` up to **6 hours**; if none arrives the workflow ends with `job_end`.

Steering: notes added via `/steer` are queued and injected before the next model round of the same turn
(`takeNotes`); a note arriving as the turn completes is turned into a continuation round
(`finishOrTakeNotes`). Steers for a finished/interrupted turn are rejected "not running".

### 5.6 Model calls

Responses API (OpenAI-compatible), OBSERVED H1JS:

- URL: `${worker}/agent/openai/v1/responses` (local) — default constant is `https://api.openai.com/v1/responses`
  overridden by `globalThis.H1_RESPONSES_URL`. Headers: `Authorization: Bearer <session token>`,
  `Accept: text/event-stream`, `Content-Type: application/json`, optional `Content-Encoding: gzip`.
- Body: `{model, tools, tool_choice:"auto", parallel_tool_calls:true, store:false, max_output_tokens:128000,
  reasoning:{effort, summary:"auto"}, include:["reasoning.encrypted_content"(, "web_search_call.action.sources")],
  prompt_cache_key:<cacheKey≤64>, input:[...], metadata:{...lease/turn metadata, clicky_effort_step_down?}, stream:true}`.
- SSE handling: tracks `response.output_item.added` (web_search_call), `response.output_item.done`,
  `response.completed`/`response.incomplete` (final), `response.failed`/`error` (throw). Records marks
  `t_send, t_first_byte, t_first_reasoning, t_first_output, t_end`.
- Timeouts: 25 s to first byte, 90 s idle between chunks, and a per-call wall cap of 10 min
  (`H1_MODEL_CALL_MAX_MS`, default 600 000). If a call "ran past N minutes", the retry of that same step lowers
  reasoning effort one notch (max→xhigh→high→medium→low; low/minimal/none unchanged) and adds metadata
  `clicky_effort_step_down:"1"`.
- Errors: 429/408/409/5xx and messages matching rate_limit/overloaded/timeout/connection are retryable; other
  4xx are `NonRetryableError`.
- Gzip negotiation: once any response carries `x-clicky-accepts-gzip: 1`, request bodies ≥ 8 KB are gzip
  (level 4) if smaller. Lone UTF-16 surrogate escapes are replaced before sending.
- Usage normalization: `{input, cached, cache_write, output, reasoning}` from `usage.*_tokens(_details)`.

Anthropic adapter (for `claude-haiku-5-5`): `${worker}/agent/harness/model/anthropic/v1/messages`,
`anthropic-version: 2023-06-01`. Converts the Responses-style input to Messages: first developer/system
message → `system` (ephemeral cache control), function calls/outputs → `tool_use`/`tool_result`, images →
base64 image blocks, last block gets ephemeral cache control, `web_search` → server tool
`web_search_20250305` (max_uses 8), `thinking:{type:"adaptive"}`, `output_config:{effort}`, `max_tokens =
min(max_output_tokens or 32000, 64000 for haiku)`. "prompt is too long" maps to a non-retryable context error.

Images: decoded with photon (wasm); if the image exceeds a budget of 16 000 tiles of 32×32 px or 8 MB it is
downscaled (triangle filter) and a note tells the model the scale factor for coordinates; PNG > 4 MB is
re-encoded as JPEG q85. Total inline image bytes per request are capped at 16 MB; older images are replaced by a
placeholder text asking the model to re-view if needed. Results are cached (24 entries) by SHA-256.

### 5.7 Tools exposed to the H1 model

Direct tools (H1JS `li` + `Yf`): `bash`, `read`, `write`, `edit`, `view_image`, `fetch_url`, `ask_user`
(with optional `choices`), `progress`, `update_plan` (if `planTool`), `routines` (unless `noRoutinesTool`),
`web_search` (if web is `exa`/`brave`), note tools (if `noteTools`), plus MCP tools.

In local mode `scriptMode:"only"` the `web_search`/`fetch_url` functions and all MCP tools are **not** direct
tools; they are callable only from inside an `exec` program (`update_plan`, when enabled, is both a direct tool
and listed inside `exec`). If the web provider is `"hosted"`, OpenAI's hosted `{type:"web_search"}` tool is added
directly instead. Model-visible set locally ≈ bash, read, write, edit, view_image, ask_user, progress or
update_plan, note tools, `exec` (+ hosted web_search).

| Tool | Parameters (paraphrased) | Behavior / limits |
|---|---|---|
| `bash` | command, timeout | runs in the job folder; 300 s limit (`bashTimeoutS`); PowerShell variant on Windows builds |
| `read` | path, offset, limit | 2 000 lines / 50 KB truncation with continuation hints |
| `write`, `edit` | path, content / exact replacements | pi-coding-agent semantics |
| `view_image` | path | png/jpg/gif/webp → image input |
| `fetch_url` | url, offset, max_chars (default 20 000, max 60 000) | 25 s timeout, ≤6 MB body, HTML → readable text; binary types refused (use curl) ; UA ends `ClickyBench/1.0` |
| `web_search` | query, count (1–10, default 8), freshness? | `POST /agent/web-search {query,count,freshness}` → `{results:[{title,url,highlights[],age}], text?}`; budget 10 per turn, ≤3 per step, 2 reserved |
| `ask_user` | question, choices? (2–4) | see 5.5; ends the runner turn with a question |
| `progress` | note | one short milestone line for the user |
| `update_plan` | plan:[{step, status: pending\|in_progress\|completed}], explanation? | 3–5 steps; drives the job's progress bar |
| `routines` | action create\|update\|pause\|resume\|list, title, task, every_minutes (2–43200), time_of_day "HH:MM", timezone, new_title | validates and emits a `routine` event carrying a `<ROUTINE>` block (cloud only; local passes `noRoutinesTool`) |
| `exec` (local) / `run_script` | code = body of an async JS function | calls `await tools.NAME(args)`; `text()` prints; `store/load` keep ≤100 KB across the job; `progress()`; 180 s budget excluding time waiting on `mac_step`; output > 40 000 chars spills to a file. Runs in-process as an `AsyncFunction` with `process/require/Bun/globalThis` shadowed (soft sandbox, not a security boundary). |
| note tools | `note`, `note_add(after, md)`, `note_replace(find, md)`, `note_remove(find, why)`, `note_tick(item, next)`, `note_answer(line, big, aside)` | edit `<workspace>/note.md` in place, streaming previews (`note` events); validator limits a note to 4 pages, ≤4 table columns, short paragraphs; cross-ref doc on Ink notes |
| MCP tools | per server | names from `tools/list`; `COMPOSIO_*` tools; `browser`, `mac_step` (from `clicky_browser`); custom connectors |
| `device_*` (cloud) | list_folder / find_files / read_file / save_file / open | via device helper; refuses `~/.ssh`, `~/.gnupg`, `Library/Keychains`, `~/.aws`, `~/.config/gh`, `Clicky/CodexHome`, `.env*` |

Tool-call accounting events: `tool_call{id, name, server, args, t_end, ok, error, result_chars, early?}`;
`program_step{program, phase, name, what, ok}` for calls made inside `exec`.

### 5.8 Context compaction

- Threshold `compactAt` = 160 000 estimated tokens (same number as Codex's `model_auto_compact_token_limit`).
  Context-length errors also trigger it.
- For `gpt-*` models it first tries **remote compaction**: `POST <responses URL>/compact` with the same model,
  input, tools and cache key; success requires a `compaction` item in the output.
- Fallback: local summarization with `gpt-6-luna` (effort low, `store:false`) producing a structured checkpoint
  (goal, constraints, done/in-progress/blocked, decisions, next steps, critical context, deliverables, side effects
  done with idempotency keys, user answers/approvals). Incremental updates merge into the previous summary. When the
  cut falls inside a turn, a second "turn prefix" summary is made. Read/modified file lists and recorded side
  effects/answers are appended as tagged sections. The new history = summary user-message + pinned turn message +
  the recent tail (~20 000 tokens kept).
- Emits `compaction{n, reason, remote, tokensBefore, ms, usage, keptItems}`.

### 5.9 Local stdio-MCP bridge and device helper

- **local-mcp bridge** (local): for MCP servers given as `{command, args, env}` the harness spawns the process,
  speaks MCP over stdio, and exposes it as Streamable-HTTP-ish JSON-RPC at
  `http://127.0.0.1:<p>/mcp/<24-hex id>` behind a constant-time-compared bearer token. One JSON-RPC message per
  POST; notifications return 202. Processes are reused while their (command,args,env) fingerprint is unchanged.
- **device helper** (cloud only, `deviceHelper:true`): starts `cloudflared` (from `CLICKY_CLOUDFLARED`,
  `/opt/homebrew/bin/cloudflared` or `/usr/local/bin/cloudflared`; error asks to `brew install cloudflared`) to
  expose a local proxy. Routes `/t/<key>/mcp/<server>` (forwards to the Mac's MCP servers or the built-in
  `device` server), `PUT /t/<key>/ws` (push a workspace tarball; rejects paths outside the workspace), `/health`.
  Idempotency via `x-h1-idempotency-key` (deduped responses flagged `x-h1-deduped: 1`); `x-h1-ws` returns
  changed-file lists. The cloud worker retries tunnel calls on 502–530 (530 up to 8×). `mac_step` gets a 15 min
  timeout, other tools 3 min. If the tunnel base changes, the driver starts a new cloud job.
- localhost URLs in fetched text are rewritten to `<tunnel>/port/<n>` when a tunnel exposes those ports.

### 5.10 Event vocabulary

Workflow → driver (from `events.jsonl`, OBSERVED kinds): `mcp_tools`, `plan`, `model_request`, `tool_call`,
`reasoning`, `commentary`, `program_step`, `note`, `question`, `routine`, `compaction`, `message`, `steps`,
`turn_end`, `job_end`, `cancelled`, `error{where, message}`, `log{text}`.

`model_request` record (OBSERVED): `{purpose:"agent"|"compaction", provider:"openai", path:"/v1/responses",
model, effort, t_send, t_first_byte, t_first_reasoning, t_first_output, t_end, status, stream, usage{input,
cached, cache_write, output, reasoning}, hosted_tools{web_search}, web_search_actions{search, open_page,
find_in_page, other}, request_bytes, response_status, incomplete_reason, function_calls[]}`.

Driver → runner → app (runner events and Swift enum cases OBSERVED; the right-hand column is INFERRED from the
OBSERVED Swift strings `harness-turn-`, `harness-answer-`, `harness-thinking-`, `harness-commentary-`,
`turn/started`, `item/completed`, `agentMessage`, `final_answer`, `item/agentMessage/delta`, `turn/plan/updated`,
`mcpToolCall`, `commandExecution`, `webSearch`, `openPage`, `turn/completed`, `turn_failed` that sit in the
runner-runtime string cluster):

| Runner event | Fields | Swift `AgentHarnessEvent` | Codex-style notification the app synthesizes |
|---|---|---|---|
| `commentary` | text | `.commentary` | item `harness-commentary-*` (phase commentary) |
| `thinking` | text (bold heading of a reasoning summary only) | `.thinking` | `item/agentMessage/thinking/delta`-like, id `harness-thinking-*` |
| `tool` | phase start/end, id, name, server?, command?, query?, url? | `.toolStarted` / `.toolFinished` / `.webSearch` | `item/started` / `item/completed` (`commandExecution`, `mcpToolCall`, `webSearch`, `openPage`) |
| `batch` | id, searches{count,done,query}, sites[{host,done}]≤24, siteCount, sitesDone, apps[{toolkit,kind,count,done,slug}], latest | `.programBatch(ClickyProgramBatch)` | grouped activity row ("searches", "sites", app logos) |
| `plan` | plan[{step,status}] | `.plan` | `turn/plan/updated` |
| `note` | phase preview\|saved, path, text? | `.notePreview` / `.noteSaved` | live note page |
| `apps_unreachable` | – | `.connectedAppsUnreachable` | warning |
| `tools_listed` | servers[{server,ok,tools,error?}] | (logged) | "Connecting your apps" |
| `answer` | text | `.answerDelta` | `item/agentMessage/delta` + `item/completed agentMessage final_answer` (`harness-answer-*`) |
| `stats` | rounds, modelMs, inputTokens, cachedTokens, outputTokens, reasoningTokens, toolCalls, toolErrors, earlyStarts, compactions | `.turnStats` | cost ledger |
| `turn_end` | status completed\|failed\|interrupted, error | `.finished` | `turn/completed` (or `turn_failed`, `out_of_budget`, `agent_extra_effort_required`) |
| `log` | text | – | console |

Composio app action kinds for `batch.apps[].kind` are derived from the tool slug words:
send/reply/forward/post → `send`; delete/remove/trash/archive → `delete`; create/add/insert/new/draft/upload →
`create`; update/edit/patch/replace/modify/move/label/append → `update`; else `read`.

### 5.11 Instruction assembly for H1

The harness concatenates (H1JS `x_`), in order:

1. `instructions` from the app (the same developer text the Codex path writes into `developer_instructions`,
   plus per-turn app context; see 6.3 for its themes).
2. An `<environment>` block: local → the job folder path, "edit files with your edit/write tools", and, when the
   plan/note tools are on, that the plan/note is the progress channel and a tool-less message ends the turn;
   cloud → a Linux copy of the folder synced back after each turn, no Spotlight, Mac reachable only via
   `device_*` (or not at all).
3. A `<working_fast>` block: batching guidance (parallel independent reads via `exec` + `Promise.allSettled`,
   Composio multi-execute/search usage, read-light-first, stop when answerable, short network timeouts, never
   search the whole disk).
4. `<workspace_instructions path=".../AGENTS.md">` with the job folder's `AGENTS.md`, if any.
5. Skill catalog: `<connected_app_skills>` (skills whose SKILL.md mentions the `composio` server) and
   `<skills>` (others), each line `- name: description (read <path> ...)`. Name/description come from the
   SKILL.md front-matter (`name:` / `description:` lines).

Observed top-level tags in a real `job.json` instructions string: `package`, `environment`, `working_fast`,
`browser_skill`, `skills`.

---

## 6. Codex app-server path

### 6.1 Runtime location (OBSERVED)

- Snapshot 1.1.2 has **no** `Resources/CodexRuntime`. MAIN still references it (`CodexRuntime`,
  "HeyClicky's bundled Codex runtime is missing from this build.", "could not find the `codex` CLI executable").
- The user's `DATA/CodexHome/tmp/arg0/codex-arg0*/` contains symlinks `apply_patch`, `applypatch`,
  `codex-execve-wrapper` → `~/Applications/HeyClicky.app/Contents/Resources/CodexRuntime/bin/../vendor/aarch64-apple-darwin/bin/codex`.
  So the previously installed build (1.1.1/66, per the `X-Clicky-App-Version`/`Build` headers still in
  `config.toml`) bundled an npm-style Codex layout: `CodexRuntime/bin/<launcher>` + `vendor/<target-triple>/bin/codex`.
- The launcher may be run via `/usr/bin/env node` (OBSERVED string) — INFERRED: `bin/codex.js` from the
  `@openai/codex` npm package. PATH prefixes include `~/.local/bin` and `~/.nvm/versions/node`.
- Codex CLI version: **UNKNOWN** (runtime absent; logs carry no version). Codex's sqlite migrations present:
  `state_5`, `logs_2`, `goals_1`, `memories_1`, `queue_1`; log targets include `codex_app_server`,
  `codex_app_server_transport::…::remote_control::websocket`, `codex_login::auth::manager`,
  `codex_core_plugins`, `codex_skills_extension` — a 2026-era app-server.
- No Codex threads exist in `state_5.sqlite` (0 rows): every job on this Mac ran through H1.

Launch: `codex app-server` with env `CODEX_HOME=DATA/CodexHome`, `OPENAI_API_KEY=<agent session token>`,
`CLICKY_WORKER_BASE_URL`, `CLICKY_BROWSER_MCP_TOKEN`, optionally `OBSIDIAN_VAULT_PATH`, `GEMINI_API_KEY`
(OBSERVED env names; values UNKNOWN/secret). Logged as "Started app-server with isolated CODEX_HOME at …".
An orphan sweep runs `/bin/ps -o pid=,ppid=,comm=` and kills agent subprocesses that outlived their turn.
When the session token rotates while tasks are running, the old app-server is kept alive and restarted at the
next idle moment (OBSERVED log text). After integration-account changes a restart is flagged
(`isCodexRuntimeRestartPendingAfterIntegrationAccountChange`).

### 6.2 `CODEX_HOME` layout (OBSERVED `DATA/CodexHome`)

```
CodexHome/
  auth.json                      (secret — key names only; API-key style login)
  config.toml                    (written by HeyClicky each launch)
  clicky-model-instructions.md   (copy of Resources/ClickyModelInstructions.md, 3 989 bytes)
  installation_id
  log/  sqlite/  tmp/arg0/  .tmp/plugins/ (Codex's own plugin sync)
  skills/clicky-browser/  skills/vercel-deploy/  skills/.system/
  task-assets/<TASK-UUID>/screen-1.jpg   (screenshots captured at launch; see §12)
  sessions/**.jsonl              (Codex rollouts; read back by CodexRolloutConversation)
```

### 6.3 `config.toml` (OBSERVED file + writer strings)

Always written:

```toml
model = "gpt-6-luna"                    # lane model (see §11); observed
model_reasoning_effort = "high"         # observed
model_provider = "clicky"
preferred_auth_method = "apikey"
approval_policy = "never"
sandbox_mode = "danger-full-access"
personality = "friendly"
cli_auth_credentials_store = "file"
mcp_oauth_credentials_store = "file"
log_dir = "<CODEX_HOME>/log"
sqlite_home = "<CODEX_HOME>/sqlite"
history.persistence = "save-all"
developer_instructions = "<contents of clicky-model-instructions.md + connected-apps section>"
model_catalog_json = "<app>/Contents/Resources/ClickyCodexModelCatalog.json"
include_collaboration_mode_instructions = false
model_auto_compact_token_limit = 160000

[model_providers.clicky]
name = "Clicky"
base_url = "https://api.heyclicky.com/agent/openai/v1"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
http_headers = { "X-Clicky-App-Build" = "<build>", "X-Clicky-App-Version" = "<ver>",
                 "X-Clicky-Device" = "<device id>", "X-Clicky-OS-Version" = "<os>", "X-Clicky-Platform" = "macos" }

[projects."<DATA>/projects"]
trust_level = "trusted"

[notice]
hide_full_access_warning = true

[features]
apps = true
fast_mode = false
goals = false
multi_agent = true

[tools.update_plan]
enabled = true

[mcp_servers.clicky_browser]             # ClickyLoopbackMCPServer
url = "http://127.0.0.1:<port>/mcp"
bearer_token_env_var = "CLICKY_BROWSER_MCP_TOKEN"
startup_timeout_sec = 20.0
tool_timeout_sec = 900.0

[[skills.config]]                        # one per synced skill dir
path = "<CODEX_HOME>/skills/<name>"
enabled = true
```

Conditionally written (OBSERVED writer fragments, not present in this user's file):

- `[mcp_servers.composio]` with `url = <Composio proxy URL from /agent/composio/session>`,
  `bearer_token_env_var = "OPENAI_API_KEY"` (the session token doubles as the proxy credential),
  `tool_timeout_sec = 120.0`.
- `[mcp_servers.clicky-crons]` with `command = <path to a clicky-crons-mcp helper>`, `startup_timeout_sec = 10.0`
  (only when Remote Tasks are enabled for the account).
- Custom connectors (Settings → Integrations → Custom connectors): stdio (`command`, `args`, `env`,
  `env_vars`) or HTTP (`url`, `bearer_token_env_var` / `env_http_headers`), `startup_timeout_sec = 60.0`.
- `apply_patch_streaming_events = true` and a patched catalog `clicky-model-catalog-streaming-patches.json`
  (INFERRED: enables streaming file-patch events for the "Editing files" HUD).
- If the Mac has a managed Codex `requirements` file restricting `approval_policy`/`sandbox_mode`, the app logs
  the allowed set and retries with an allowed value (`CodexManagedRequirementsCompatibility`).

`developer_instructions` themes (paraphrased from `ClickyModelInstructions.md`; do not reuse verbatim):
you are a background helper started by HeyClicky from a spoken request; the final message is shown and its
first sentence may be spoken; the working folder is the work's home and may hold an `AGENTS.md` identity +
dated Notes (no secrets); infer intent, do the parts not blocked on user-only facts then ask one bundled set of
questions; never invent facts; prefer connected apps, web, shell, and the `browser` tool for signed-in sites;
use `mdfind`/`rg` rather than walking Desktop/Documents/Downloads; the request is the approval for writes, but
confirm before deleting, overwriting unasked, sending to others or spending; never script clicks/keystrokes
(app scripting dictionaries are fine) and hand window-only steps back to HeyClicky; deliverables in `output/`,
scratch in `tmp/` (install Python libs into `tmp/pylib` with `uv pip install --target`); verify outputs; send
short progress lines at milestones; final message leads with the result, plain and warm; a "Connected apps"
section varies with Composio state (none / unreachable / list of toolkits, multi-account rules, Obsidian vault).

### 6.4 JSON-RPC protocol (OBSERVED method names; parameter details INFERRED from the public Codex app-server protocol)

Transport: one JSON object per line on stdin/stdout (`CodexRPCLineFramer`). stderr is logged
(`[Codex Process stderr]`). EOF = disconnected.

Handshake:
1. `initialize` `{clientInfo:{name:"ClickyApp", version}, capabilities:{experimentalApi:true}}`
2. notification `initialized`
3. `account/login/start` `{type:"apiKey", apiKey:<session token>}`

Client → server requests used: `thread/start`, `thread/resume`, `thread/read` (`includeTurns`),
`thread/list` (`cursor`, `sortKey`, …; `next_cursor`), `thread/turns/list` (`itemsView`, `sortDirection`,
`historyMode: paginated`), `thread/archive`, `thread/unsubscribe`, `turn/start`, `turn/steer`
(`expectedTurnId`), `turn/interrupt`, `config/mcpServer/reload`, `mcpServerStatus/list`,
`mcpServer/oauth/login` (→ `authorizationUrl`).

Server → client notifications handled: `thread/started`, `thread/status/changed`, `thread/closed`,
`thread/compacted`, `thread/tokenUsage/updated`, `turn/started`, `turn/completed`, `turn/plan/updated`,
`item/started`, `item/completed`, `item/agentMessage/delta`, `item/agentMessage/thinking/delta`,
`item/reasoning/summaryTextDelta`, `item/commandExecution/outputDelta`, `item/fileChange/outputDelta`,
`item/fileChange/patchUpdated`, `account/rateLimits/updated` (`usedPercent`), `mcpServer/startupStatus/updated`,
`mcpServer/oauthLogin/completed`, `error` (with `willRetry`).

Server → client requests: `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
`item/permissions/requestApproval` — always answered `accept` (approval policy is `never` anyway).

Turn input: `{type:"text", text}` plus screenshots as `{type:"localImage", path}`; per-turn
`responsesapiClientMetadata` carrying the lease ids (`clicky_agent_turn_lease_id`, `clicky_agent_turn_id`,
`clicky_agent_task_id`) so the proxy can meter Responses calls (INFERRED; Codex forwards it as request metadata /
`x-codex-turn-metadata`).

Item types mapped to HUD rows: `agentMessage` (phase commentary vs final_answer), `reasoning`,
`commandExecution` (`aggregatedOutput`, `exit_code`, `commandActions`), `fileChange` (patch text; `*** Add File:`,
`*** Update File:`, `*** Delete File:`, `*** Move to:` parsed into created/changed/deleted diffs), `mcpToolCall`,
`dynamicToolCall`, `webSearch` (`openPage`, `findInPage`), `contextCompaction`.

Retry/"Reconnecting" parsing: regexes for "reconnecting … n/m", "attempt n of m", "(n/m)"; maxRetries fields.
Fatal: `clicky_openai_backend_key_invalid` / `clicky_upstream_auth_error` → "Agents stopped working. Contact
HeyClicky support plz". Timeouts: "Codex request timed out", startup RPC timeouts ("The agent took too long to
connect"), MCP startup wait before a turn ("waited Ns for MCP startup").

Thread history: `CodexThreadHistoryCache` writes `HomeSpaceCache/thread-history.json` and per-thread
`transcript-*` checkpoints (`com.humansongs.clicky.homespace-cache`). `CodexRolloutConversation` reads rollouts
from `CodexHome/sessions/*.jsonl` (`"type":"response_item"`, `"type":"message"`, skipping injected
`# AGENTS.md instructions`, `<environment_context>`, `<user_instructions>` items). When a conversation moves
between runtimes, the new runtime gets the old transcript wrapped in `<earlier_conversation>`.

### 6.5 `ClickyCodexModelCatalog.json`

Codex model-catalog format `{models:[…]}`, 14 entries: `gpt-6-luna`, `gpt-6-sol`, `gpt-6.1-sol`,
`gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-daybreak-blue-latest`,
`gpt-daybreak-red-latest`, `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.2`, `codex-auto-review`. Entry keys
(OBSERVED): `slug, display_name, description, default_reasoning_level, supported_reasoning_levels, shell_type
("unified_exec"), visibility, supported_in_api, priority, base_instructions (~18 KB), model_messages,
include_*_usage_instructions, default_reasoning_summary, web_search_tool_type, truncation_policy,
context_window (272000 for luna), max_context_window, effective_context_window_percent, input_modalities,
supports_search_tool, multi_agent_version, apply_patch_tool_type, …`. Developer-only model picker
(`ClickyDeveloperChatModel` {gpt61Sol, gpt6Sol, gpt6Luna, luna, terra, sol, astra}, efforts none…max) is gated by
`ClickyDeveloperModelAccess` and persisted per account under `clicky.developerChat.model.v1.<id>` /
`clicky.developerChat.effort.v1.<id>`.

---

## 7. Jobs (one-off background work)

### 7.1 Folder layout (OBSERVED `DATA/projects/jobs/` + MAIN strings)

```
projects/
  jobs/
    WORK.md                                 # index, newest first
    <title-slug>-<10 hex>/                   # one folder per job (e.g. "research-buddy-76123b191e")
      output/                               # deliverables only
      tmp/                                  # scratch, downloads, tmp/pylib for Python deps
      report.md                             # per-run record (managed block between markers)
      state.md                              # (name observed; content UNKNOWN)
      note.md                               # live "note" page when note tools are on
      AGENTS.md                             # only when a kept Clicky owns it / persona
      .clicky/owner                         # "clicky-work-owner:<stamp>" ownership marker
      .clicky/previous-note.md              # note left by the previous run of a routine
  agents/<clicky-slug>/                      # kept Clicky workspaces (INFERRED from "/agents/" + AGENTS.md template)
```

`WORK.md` format (OBSERVED, text masked): heading `# Work HeyClicky has done for the user`, one explanatory
line, then bullets `- yyyy-MM-dd HH:mm · <title> · <folder>/ · <status or result line>`. Status words include
"working now", "stopped by the user", "done earlier".

`report.md` (OBSERVED markers): a block between `<!-- clicky:runs -->` and `<!-- /clicky:runs -->` under
`## Runs (HeyClicky keeps this list, newest last)`, entries headed `## yyyy-MM-dd HH:mm …` with "asked:"
text, result, and files; older runs are elided ("N older run(s) left out"). A one-time backfill
(`clicky.work.reportsBackfilled.v2.<account>`) creates reports for old folders.

### 7.2 `ClickyJob` model (OBSERVED fields)

`id, title, prompt, threadID?, folderPath, createdAt, finishedAt?, outcome (working|done|failed|stopped), summary?,
replyText?, artifactEntries[], latestReplyArtifactEntries?, isSeen, isDismissed, followedUpOnLaterDay?, isArchived?,
cloudColorName?, suggestionCardID?, nickname?, waitsForChrome?, skipsChrome?, runs:[{threadID?, startedAt, ask,
finishedAt?, outcome, summary?}], waitingStep: ClickyJobUserStep?` — persisted under UserDefaults `clicky.jobs.v1`
(`ClickyJobStore`, plus `jobIDsWithRoutines`).

Other enums: `ClickyJobRailPhase` {queued, working, needsYou, done, failed, stopped} (right-edge rail);
`ClickyJobKind` {pdf, document, sheet, slides, image, video, page, code, message, research} (card icon);
`ClickyJobMessageRoute` {targetThreadID?, newRunFollowsThreadID?, resumesFinishedRun} (where a follow-up goes).

### 7.3 Lifecycle

1. Brain calls `sessions_spawn` (or user taps a suggestion/tour card). The app creates the job folder and
   `ClickyJob`, plays `agent-launch.wav`, animates `CodexLaunchFlight` from cursor to the edge rail.
2. Pre-launch: label/paywall gate (`/codex-thread-launch`, §11), lease, screenshot capture into
   `CodexHome/task-assets/<TASK-UUID>/screen-N.jpg`.
3. Brief assembly (`CodexAgentTurnPromptBuilder`): job preamble (folder rules, `find_jobs`/`read_job`,
   `../WORK.md`), language rule, attachments list, user memory pointer (`Clicky/helper/about-the-user.md`),
   standing context (`ClickyAgentStandingContextLedger` sections userMemory, agentInstructions, activeSkills,
   learnedHowTos), browser/Chrome state lines, current routines list, final-message contract (§9), lease metadata
   wrapper `<clicky_agent_turn_lease_metadata>`, hand-off wrappers `<AGENT_HANDOFF>` /
   `<REALTIME_AGENT_HANDOFF>` and `<RECENT_COMPANION_CONTEXT>`. For app-generated briefs (suggestion, routine,
   retry) the agent is told the brief may rest on facts HeyClicky never had and that "Open input" lines need
   the user.
4. Running: HUD/rail show plan, activity, commentary; the brain receives progress as silent context.
5. Completion: parse final blocks (§9) → result card (`ClickyResultCardFace`), chat hand-off entry
   (`HeyClickyChatHandOff` kinds started/cameBack/drawing/text, outcomes finished/failed/stopped/needsYou),
   `agent-done.wav` or `agent-needs-you.wav`, first artifact opened in the viewer, `WORK.md`/`report.md` updated,
   learned how-tos stored (`ClickyLearnedHowTos`).
6. Follow-up: `sessions_send` → same thread (steer if running, else new turn); if the thread's rollout is missing
   a fresh thread is started with `<earlier_conversation>`.
7. Restart safety: `clicky.clickys.runningTurns.v1` (`ClickyRestartInterruptions`) records running turns; after a
   crash/quit the job shows "Stopped before I finished" and the brief for the retry says the last run was
   interrupted and must not repeat external actions that already succeeded.

### 7.4 User steps (`WAIT_FOR`)

When the agent ends with `<WAIT_FOR>{"step","page","done_when_url_contains"}</WAIT_FOR>`, the job stores a
`ClickyJobUserStep {step, page?, doneWhenURLContains?, askedAt}`. `ClickyJobStepWatcher` polls the browser
(via the Chrome bridge) and, when the URL contains the marker, continues the job automatically ("HeyClicky saw
the user's browser reach …"); the user can also tap "I'm done" which continues with a note to verify.

---

## 8. Clickys (kept, named agents)

- Roster stored in UserDefaults `clicky.roster.v1` (`StoredRoster`: createdClickys, overridesBySlug,
  archivedSlugs, portraitAppearancesBySlug, userCustomizedPortraitSlugs). `CreatedClicky {slug, name, roleText,
  oneLiner, baseHue, createdAt?, introMessages?, suggestedAsks?, firstAsksGeneratedAfterCreation?}`.
- Thread bindings: `clicky.starterAgents.threadBindings.v1`, `…filedThreadOwners.v1`, `…lastSeenAt.v1`,
  `…manuallyMarkedUnread.v1`, routines `clicky.starterAgents.routines.v1`.
- Each Clicky has a workspace folder with an `AGENTS.md` generated from a template (OBSERVED section headings):
  a one-line identity ("You are <name>, the user's persistent <role> agent in HeyClicky"), what it does, a note
  that the folder is its own workspace and it remembers, `## Identity` (`- Name:`, `- Role:`, speaking voice),
  `## Standing preferences` (one line each), `## Notes` (dated, curated working memory, pruned; never secrets).
  The agent is told AGENTS.md was preloaded and to keep Notes current.
- Routing rules given to the brain (paraphrased): all background work belongs either to a Clicky or to a standalone job;
  Clickys are referenced by `clicky_slug` only, because thread ids are not stable; new work that matches an existing Clicky
  goes to `sessions_spawn` with that slug, and follow-ups go to `sessions_send` with the slug; a new Clicky is created
  (`new_clicky {name, role, description}`) only on explicit request or for long-lived recurring work; questions about a
  Clicky's results are answered from `clicky_memory` rather than invented.
- Archive/unarchive is supported; a task routed to an archived Clicky revives it and the brain is told to mention
  that. A Clicky founded during onboarding starts idle ("start_idle") and waits for its first message.

---

## 9. Final-message contract (parsed by the app)

Parser (OBSERVED regex): tags matched case-insensitively with optional whitespace,
`<\s*(/?)\s*(SUMMARY|NEXT_ACTIONS|DONE_TITLE|ARTIFACTS|ROUTINE|COMPUTER_USE_REQUEST|WAIT_FOR|LEARNED|ANSWER)\s*>`.
Everything outside the blocks is the report (markdown). Citation artifacts are stripped before display:
`[text](turnNsearchM)`-style links → text, `cite turn…` markers, and private-use characters U+E200–U+E2FF.

Two prompt variants exist (OBSERVED): one where the final message is shown to the user directly (old "agent mode"
with SUMMARY / NEXT_ACTIONS / DONE_TITLE / ARTIFACTS) and one where the final message is a **report to HeyClicky**
that the voice brain retells and turns into a card (adds ANSWER and LEARNED).

| Block | Content | App use |
|---|---|---|
| `SUMMARY` | one plain sentence < 200 chars, result first | spoken when the user isn't looking; card subtitle |
| `DONE_TITLE` | 2–5 words, Title Case, names the outcome | card / rail title |
| `NEXT_ACTIONS` | 2–3 `- ` lines, concrete next steps | tappable follow-up chips (sent verbatim) |
| `ARTIFACTS` | `- ` absolute paths or http(s) URLs, ≤8, most important first; never tmp/ or scripts | artifact cards; first auto-opens in the viewer |
| `ANSWER` | one line of JSON (`ClickyAnswer`) | result card |
| `LEARNED` | ≤3 lines `Topic: what worked` about the user's own setup | `ClickyLearnedHowTos`, fed to later jobs |
| `ROUTINE` | JSON `{action:create\|update\|pause\|resume\|delete, title, task, every_minutes, new_title?}` (`CodexAgentRoutineRequest`) | creates/changes a local routine |
| `WAIT_FOR` | JSON `{step, page, done_when_url_contains?}` | user-step watcher (§7.4) |
| `COMPUTER_USE_REQUEST` | the one Mac step to perform | consent card; see §10 |

`ClickyAnswer` JSON (OBSERVED fields): `outcome` (≤90 chars; "line" in Swift), `numbers[≤3] {value≤9 chars,
label, was?, of?, better: "higher"|"lower"}`, `list[2–4] {text≤40, detail≤20}` + `ranked?`, `done[1–3] {did, what,
link}` (receipts confirmed by a tool result), `draft {text, to}`, `ask[2–3] {answer≤28, detail} | {file}`, `note`
(≤70), `next {label, open}`, `quiet: true` (nothing new). Display looks: `NumbersLook` {hero, tiles, changes,
progress}; at most two blocks are shown (`Block` {numbers, list, done, draft, ask}).

Report style guidance given to the agent (paraphrased): lead with the answer in 1–2 sentences with a little bold;
2–5 short `##` sections; small tables (≤4 columns, ≤8 rows, best row marked); short lists/checklists; ≤2 callouts
`> [!TIP]`/`> [!WARNING]`/`> [!NOTE]`; copyable text as a quote block; at most one fenced `chart` block
(`title:`, `caption:`, `type: line`, `Label: value` lines); `## Sources` last with 2–6 real links; < 300 words
unless a document was requested. The app's markdown viewer renders these (cross-ref result-card/viewer docs).

---

## 10. Loopback MCP server, `browser` and `mac_step`

- `ClickyLoopbackMCPServer` (OBSERVED): HTTP on `127.0.0.1:<random>`; path `/mcp`; requires
  `Authorization: Bearer $CLICKY_BROWSER_MCP_TOKEN`; JSON-RPC methods `initialize` (answers
  `protocolVersion "2025-03-26"`, `serverInfo`), `tools/list`, `tools/call` (`structuredContent`, `isError`);
  errors "Parse error", "Method not found", "Unknown tool"; responses `Cache-Control: no-store`,
  `Connection: close`; 405 for wrong methods. Codex/H1 see it as server `clicky_browser` with 2 tools.
- `browser` — drives the user's signed-in Chrome via the HeyClicky browser extension (operations include `extract`,
  `download`, `dialog`, `click_at`, `hover_at`, `drag_at`, `javascript`, `upload`, `wait_for`, key presses). Cross-ref
  the Browser Bridge doc. When Chrome is not connected the job may wait for the user's choice
  (`sessions_answer_request` request `chrome_setup`).
- `mac_step` — the agent asks HeyClicky to perform ONE step in a native app window or system dialog. HeyClicky
  shows a consent card ("I need a yes to use your Mac"), and on yes drives the screen via its computer-use
  subsystem (`ClickyTakeOver`), then returns what happened (finished / lost connection / couldn't see the screen /
  safety check / user took over / ended without acting). The tool call blocks up to 15 min (tool timeout 900 s). If
  the user does not answer in time, the agent is told to end its turn with a `<COMPUTER_USE_REQUEST>` block; the
  request stays on the card and a later yes resumes the job with a synthetic message. Only one pending Mac step
  per job. Turn identity reaches the server via MCP `_meta["x-codex-turn-metadata"]` (OBSERVED key in H1 cfg)
  so the app knows which job/lease asked.
- The loopback server also exposes root file tools gated by a runtime policy (`/runtime/tool-policy`,
  `enabledRootTools`, "Root file access is disabled in this build's runtime policy") — INFERRED dev-only.

---

## 11. Usage, leases, paywall

Per agent turn (OBSERVED types + strings; route suffixes partly INFERRED):

1. **Launch labels / gate**: `POST …/codex-thread-launch` body `{user_prompt, is_fresh_thread, launch_source
   (voice|text)}` → `{spoken_start_cue?, text_start_cue?, title?}` (`CodexThreadLaunchLabels`). Logged as the
   "Haiku gate" (INFERRED: server runs a small Claude Haiku model). A paywall response shows the agent paywall HUD
   ("Oops, you're out of tokens! …").
2. **Lease**: request `{supports_agent_turn_lease, thread_id, turn_id, task_id, is_follow_up, launch_source,
   idempotency_key, extra_usage_auto_approve}` → `{lease_id, turn_id, expires_at, credits_used, included_credits,
   cost_usd, cost_limit_usd, requires_extra_effort, status}`. Create route: UNKNOWN (only prefix
   `/agent/turn-lease/` observed). During the turn the app polls `GET /agent/turn-lease/<id>/status`
   (`lease_status_poll`). If `requires_extra_effort`, the task pauses ("Needs more agent messages to keep
   going"); approval → `POST /agent/turn-lease/<id>/continue {extra_usage_approval: "one_time"|"as_many_as_needed"}`.
   Completion body `{status, thread_id}` (route UNKNOWN). Errors: `app_update_required`,
   `agent_turn_lease_required` ("Please update HeyClicky to keep using Agent Mode"), `agent_turn_limit_exceeded`,
   `out_of_budget`, `agent_extra_effort_required`. Cancelling before debit shows "Agent cancelled. This won't count
   toward your quota."
3. **Lease metadata on model calls**: `clicky_agent_turn_lease_id`, `clicky_agent_turn_id`, `clicky_agent_task_id`
   (+ `clicky_harness:"h1"`, `clicky_effort_step_down`) travel as Responses `metadata` (H1) or client metadata
   (Codex) — the proxy meters against the lease.
4. **Launch record**: `POST /agent/record-agent-launch` ("record agent usage").
5. **Message log**: `POST …/agent-messages {thread_id, role, content, is_follow_up, is_demo, is_proactive?,
   proactive_suggestion_id?}`.
6. **Local cost ledger**: `ClickyAgentTurnCostLedger` keeps `ClickyAgentTurnUsageRecord {taskID, threadID?,
   codexTurnID?, clickySlug?, finishedAt, model, reasoningEffort, inputTokens, cachedInputTokens, outputTokens,
   leaseID?, billedCostUsd?}` and computes cost with a built-in `ClickyOpenAIModelPricing` table; tracks the current
   "lane" model/effort (refreshed from the server). Plan usage (`PlanSnapshot.usage.agents/messages {used, cap},
   windowResetsAt`) is shown in `ClickyUsageCardPopover` and as a "[Your plan]" silent line to the brain.
7. **Analytics**: `codex_agent_turn` with `clicky_turn_status`, `clicky_screenshot_count`,
   `clicky_used_computer_use`, `clicky_computer_use_tool_names/count`, `clicky_integrations_used(_count)`.

Session token: `GET/POST /agent/session-token` → token + `expires_at` (+ optional `developer_model_selection`);
used as `OPENAI_API_KEY` for Codex and `worker.sessionToken` for H1; rotation handled as in §6.1.

---

## 12. Attachments and task assets

- Screenshots captured at launch go to `CodexHome/task-assets/<TASK-UUID>/screen-<n>.jpg` (OBSERVED, 3 tasks) and
  are passed as `localImage` (Codex) or uploaded as `turn<N>-img<i>` blobs (H1). Whether to capture is decided
  per launch (`shouldCaptureLiveScreenshotWhenNoImagesAttached`; logged `[token-audit] screenshot decision`).
  Background-launched work states that no desktop screenshot is attached.
- User-attached files are listed by absolute path with instructions to read them with file tools; they are
  inputs, never save destinations (`CodexAgentAttachmentSupport.Routing {fileCount, totalBytes, allImages}`).
- Active-document context: if the user had a file or browser page open, the brief tells the agent to read the file
  / fetch the page rather than trusting the screenshot.

---

## 13. HUD, progress lines, sounds

- Activity labels (OBSERVED): "Launching Agent Mode...", "Opening conversation and tools", "Connecting your apps",
  "Sending your message", "Waiting for the agent's response", "Working on it", "Reasoning...", "Running command:",
  "Searching web", "Editing files", "Composing reply", "Sharing an update", "Reconnecting...", "This task requires
  extra effort", "Needs a yes", "Finalizing". Tool rows prefix "Search:", "Reading:", "Editing:", "Finding:",
  "Using:".
- `CodexTaskViewModel` holds `_progressSummary`, `_queuedBadgeText`, `_activityItems`, `_streamingCommentary`,
  `_latestThinkingHeading` (bold heading of reasoning summary), `_finalResponseMarkdown`, `finalAnswer`
  (`ClickyAnswer`), `_pendingComputerUseRequest`, `_pendingUserStep`, `_needsChromeConnection`, `learnedHowTos`.
- Progress → voice: `CompanionManager+AgentCommentaryStream` injects "[Agent progress]" silent context listing what
  each running agent last said; `session_status` returns `current_progress` and `clicky_progress` messages.
- Surfaces: notch agent surface (`NotchAgentSurface`, face badge), right-edge job rail/deck (`ClickyEdgeShelf*`,
  phases queued/working/needsYou/done/failed/stopped), result cards, chat hand-off rows, live note "ink" cards
  (states writing/needsYou/ready/done/watching/paused).
- Sounds (OBSERVED resources): `agent-launch.wav`, `agent-done.wav`, `agent-needs-you.wav`, `agent-close.wav`.

---

## 14. Routines (local) and Remote Tasks (server)

### 14.1 Local routines (OBSERVED `ClickyRoutine`)

`{id, clickySlug, jobID?, title, taskPrompt, intervalSeconds, createdAt, isPaused, nextRunAt, runCount,
lastRunStartedAt?, lastRunFinishedAt?, lastRunSummary?, lastRunFailed, pendingRetryAt?, lastRunTaskIdentifier?,
consecutiveFailedRunCount?, waitingForNetworkSince?, scheduledMinuteOfDay?, scheduledWeekday?, scheduledWeekdays?}`.

- Created from a `<ROUTINE>` block, from the brain's `routines` tool (actions create/update/pause/resume/delete/
  list/run-now; `every_minutes` or `days` + `at` "HH:MM"; validation errors observed: weekday names, time format,
  "create needs task and every_minutes (or days)"), from approved proactive suggestions (`ProactiveSuggestedRoutine
  {everyMinutes, title}`), or Settings → Routines ("Routines run on this Mac while it's awake and HeyClicky is
  open").
- Scheduler: runs only while the app is open; waits for network (`NWPathMonitor`, queue
  `com.heyclicky.routine-network`), defers on dark wake until screens wake (`ClickyRoutineFullWakeObserver`),
  holds an IOKit `PreventUserIdleSystemSleep` assertion "HeyClicky is running a routine on a schedule" during a
  run, retries failed runs later, tracks consecutive failures, finishes quietly in Do Not Disturb. Triggers:
  `scheduled` or `manual` (`routine_run_now`).
- Run brief: prefixed with a marker `[Routine "<title>" run #<n>, <cadence>]` (parsed back by
  `ClickyRoutineRunMarker`). Run 1 does the full task; later runs report only what is new (one line if nothing
  changed); a retry after failure must not repeat external actions; notes are reset per run (`note.md` cleared,
  previous saved to `.clicky/previous-note.md`) for "kept" dashboard notes. The current routine list is injected
  each turn as authoritative ("CURRENT routines").
- Analytics events: `clicky_routine_created/updated/deleted/pause_changed/run_requested/run_dispatched/run_ended`.

### 14.2 Remote Tasks (server cron) — OBSERVED types

- `GET /agent/cron/list` → `{crons:[{id, name, description?, schedule_kind, schedule_expr, timezone, enabled,
  last_run_at?, last_run_status?, next_run_at?, runs_remaining?, created_at?}]}`.
- `GET /agent/cron/<id>` → `{cron:{id, name, description?, schedule_kind, schedule_expr, timezone, source,
  source_lang, enabled, next_run_at?, last_run_status?}, runs:[{id, cron_id, status, attempt, started_at?,
  finished_at?, duration_ms?, result_summary?, error?, stdout_log?, created_at?}]}`.
- `POST /agent/cron/<id>/run-now` → `{run_id}`.
- Disabled accounts get "Remote Tasks are not enabled for this account."
- Agents manage them through a `clicky-crons` MCP server (stdio command; name `clicky-scheduled-crons`).
  INFERRED: Remote Tasks are server-executed scripts (`source`, `source_lang`, `stdout_log`) on a cron/interval
  schedule; their runtime is UNKNOWN.

### 14.3 Agent notifications

- `GET /agent/notifications?limit=20` → `{notifications:[{id, source_type, source_id?, run_id?, title, summary,
  severity: info|success|warning|error, read_at?, created_at}]}`; per-item route under
  `/agent/notifications/<id>…` (mark read, INFERRED) and `POST /agent/notifications/read-all`.
- In-app only (the binary does not link UserNotifications).
- "Modify the task with Agent" on a Remote Task notification launches an agent whose brief contains the
  notification, the cron's fields, recent runs, the (truncated) current source and the user's requested change,
  and tells it to use the clicky-crons tools.

---

## 15. Voice-brain tools that control agents

The brain (server-side; see brain doc) calls client-executed tools. Names OBSERVED; full JSON schemas are
server-defined (UNKNOWN); arguments listed are those visible in client strings/handlers.

| Tool | Arguments seen | Client behavior / result |
|---|---|---|
| `sessions_spawn` | `task`, `label`, `clicky_slug?`, `new_clicky {name, role, description}?`, `chrome: "ask"\|"without"?`, approved-suggestion reference | Starts a job (or a Clicky's turn); dedupes a repeat within a short window (`{"status":"already_started"}`); result text tells the brain which Clicky took it / was founded / was unarchived; failures say nothing was started. During the onboarding interview nothing starts. |
| `sessions_send` | `clicky_slug` or `codexThreadId`, `message` | Follow-up or steer; returns `sent_as` (the user's own words unchanged vs rewritten). |
| `sessions_answer_request` | `request: extra_usage\|computer_use\|chrome_setup`, `decision: approve\|decline\|show_how`, `clicky_slug`/`job_id`, `always?` | Answers a pending card. |
| `sessions_interrupt`, `sessions_yield` | target | stop / yield (details UNKNOWN). |
| `session_status` | – | `{activeCount, previousCount, activeAgents[], previousAgents[]}` with `codexThreadId`, `latest_reply`, `recent_messages` (roles user / clicky / clicky_progress), `current_progress`. |
| `clicky_memory` | `clicky_slug` or job thread | `memory_markdown` (AGENTS.md), recent messages, is_working_now, is_archived. |
| `clicky_artifacts` | slug or thread, `file?` | files newest first; reads one in full. |
| `open_artifact` | `codexThreadId` or `uri`/`path` | opens in the HeyClicky viewer. |
| `show_result` | `codexThreadId` | shows the job's result card. |
| `find_jobs` | query | searches earlier jobs (titles/topics). |
| `read_job` | `job_id`, `detail: report\|conversation` | returns `report.md` runs or the whole conversation. |
| `routines` | action, `routine_id`, title, task, every_minutes, days, at, codexThreadId | manages local routines (§14.1). |
| `open_agent_dashboard` | action open\|close | toggles the agent dashboard. |

Context notes injected into the brain each turn (OBSERVED headers): `[Your jobs]` (jobs needing attention + six
most recent, with `job_id`, states WORKING NOW / WAITING ON THE USER / OFFERED, NOT STARTED / repeats
routine_id), `[Your Clickys]` (slugs, PENDING REQUEST, MOST RECENT REPORT), `[Your routines]`, `[Your plan]`,
`[Agent progress]`, `[clicky update]` (paused-for-extra-usage heads-up), `[Job result]` (when the user presses
"Show me").

---

## 16. Permissions and entitlements

- Main app (OBSERVED): `app-sandbox = false` (required: spawns helpers, writes arbitrary job folders, runs agents
  with full shell access), `cs.allow-jit`, `device.audio-input`, `device.camera`, `network.client`, mach-lookup
  exception `com.apple.screencapturekit.picker`. Info.plist usage strings for Desktop/Documents/Downloads,
  microphone, screen capture, speech recognition. `LSUIElement = true`.
- Helper `clicky-harness`: `cs.allow-jit`, `cs.allow-unsigned-executable-memory`.
- TCC effects of agents (agents run as children of the app, so prompts are attributed to HeyClicky):
  Files & Folders (Desktop/Documents/Downloads — agents are told to avoid walking them and use `mdfind`),
  Automation/Apple Events for app scripting (Notes, Mail, Messages, Music…), Contacts, Calendars, Reminders,
  Photos. `AgentPermissionsInspector` probes and shows these (OBSERVED rows).
- Screen Recording is needed for launch screenshots and `mac_step`; a failure tells the brain to retry with the
  same `clicky_slug` after the user fixes the permission.
- Codex runs with `sandbox_mode = danger-full-access`, `approval_policy = never`; H1 has no sandbox at all
  (bash runs as the user). The only guard rails are prompt rules, the device-path deny list (cloud helper), and
  confirmation-before-send rules.

---

## 17. Timing and limits (OBSERVED unless noted)

| Item | Value |
|---|---|
| Runner ready timeout | 20 s |
| Runner `/turn` wait for previous turn | 25 s |
| Event long-poll | app→runner 20 s (cap 25 s); driver→job 20 s; ≤400 events/response; 2 000 retained |
| Model first byte / idle / per-call cap | 25 s / 90 s / 10 min (then effort step-down) |
| Job limits | 120 model steps, 30 min wall per turn, bash 300 s |
| `ask_user` wait | 30 min (×3), then default assumption |
| Idle job keeps waiting for next turn | 6 h, then `job_end` |
| h1-local GC | 30 days |
| Compaction threshold | 160 000 tokens; keep ≈20 000 tail; summary cap ≈13 107 tokens |
| `exec` program | 180 s (excl. `mac_step` waits); 40 000 chars output; store ≤100 000 chars |
| Web search | 10/turn, ≤3/step; 15 s timeout (exa), count ≤10 |
| fetch_url | 20 000 chars default (max 60 000), 25 s, ≤6 MB |
| Images | ≤16 000 32-px tiles, ≤8 MB each, ≤16 MB per request |
| MCP | clicky_browser startup 20 s / tool 900 s; composio tool 120 s; crons startup 10 s; custom startup 60 s |
| `mac_step` via tunnel | 15 min; other tunnel tools 3 min |
| Codex auto-compact | 160 000 tokens; luna context window 272 000 |

---

## 18. Edge cases the code clearly handles

- Job endpoint says the job is gone (404/410) → new job, retried once; restarts suffix `-r<n>`.
- Cancel arriving while a `/turn` is waiting → immediate interrupted `turn_end`.
- Steer when nothing runs → `{ok:false, reason:"not running"}` → app asks the user to resend later.
- Stale turn events (`turn_end`/`message` from an older turn number) are ignored.
- Composio unreachable → job continues without apps; brain/agent told apps are connected but unreachable (not to
  reconnect).
- MCP list or instructions changed between turns → re-list tools; failed optional servers retried.
- Model call over time → effort step-down; context overflow → compaction; incomplete summary → error.
- Writes with idempotency keys + recorded side effects survive crashes and compaction (no double sends).
- Images too large → downscaled with coordinate scale note; too many → older replaced with placeholder.
- Session token rotation mid-task → keep old process until idle.
- Codex rollout missing on resume → fresh thread seeded with `<earlier_conversation>`; steer with no active turn →
  start a turn instead.
- Managed Codex requirements restricting policies → retry with an allowed value.
- App restart mid-turn → "Stopped before I finished" + retry brief.
- Account switch → caches are per account (user memory `ClickyCachedUserMemoryMarkdown_<id>`, hand-offs).
- Suggestion approved twice / expired → "already handled or expired", nothing started.
- Device helper path deny-list; tarball push rejects `..`/outside-workspace paths.
- Windows build of the harness exists in code (PowerShell bash tool, `%LOCALAPPDATA%/HeyClicky/AgentHarness`).

---

## 19. Model slots (what OpenClicky must supply)

| Use | HeyClicky source | Slot | Capabilities needed |
|---|---|---|---|
| H1 agent loop | `/agent/openai/v1/responses` with `gpt-6-luna` (local default), `gpt-6-sol` (cloud) | **agent** | Responses-style streaming, function tools with parallel calls, reasoning effort + summaries + encrypted reasoning carry-over, image input, prompt cache key, request metadata, ≥128k output budget, ~272k context |
| H1 with Haiku | `/agent/harness/model/anthropic/v1/messages`, `claude-haiku-5-5` | **agent** (alt provider) | Anthropic Messages streaming, tool use, adaptive thinking, prompt caching, server web search tool |
| Context compaction | `/agent/openai/v1/responses/compact` or summarization with `gpt-6-luna` | **agent** (same LLM) / other:compaction | remote compaction endpoint optional; otherwise any LLM with ~13k-token output |
| Codex app-server | provider `clicky` → `/agent/openai/v1` (`wire_api = responses`) | **agent** | Codex-compatible Responses provider; catalog models |
| Web search | `/agent/web-search` (Exa-like) or hosted `web_search` | other:web-search | query → results with highlights/age |
| Launch labels / paywall gate | `/codex-thread-launch` (INFERRED Haiku) | other:launch-labels | small fast LLM for title + start cues |
| Connected apps | Composio MCP via `/agent/composio/session` | other:integrations-mcp | remote MCP with per-user OAuth accounts |
| Proactive suggestions, cron execution, notifications | server | other:server-jobs | UNKNOWN server logic |

---

## 20. Server routes used by this subsystem

| Route | Purpose | Carries model choice |
|---|---|---|
| `POST /agent/openai/v1/responses` | All H1 (and Codex) agent model calls | yes (`model`, `reasoning.effort`) |
| `POST /agent/openai/v1/responses/compact` | Remote context compaction | yes |
| `POST /agent/harness/model/anthropic/v1/messages` | Haiku agent calls | yes |
| `GET /agent/web-search` (probe) / `POST /agent/web-search` | Web search availability / queries | no |
| `GET\|POST /agent/session-token` | Backend agent session token (bearer for everything above) | maybe (`developer_model_selection`) |
| `POST …/codex-thread-launch` | Title + start cues; paywall gate | no (server picks) |
| `/agent/turn-lease/…` (`/<id>/status`, `/<id>/continue`, create/complete UNKNOWN) | Per-turn metering lease | no |
| `POST /agent/record-agent-launch` | Usage record | no |
| `POST …/agent-messages` | Conversation log | no |
| `GET /agent/composio/session` | Composio MCP proxy URL/session | no |
| `GET /agent/integrations`, `/agent/integrations/<id>/connect\|disconnect`, `/accounts/<id>/label` | Integration management | no |
| `GET /agent/cron/list`, `GET /agent/cron/<id>`, `POST /agent/cron/<id>/run-now` | Remote Tasks | no |
| `GET /agent/notifications?limit=20`, `/agent/notifications/<id>…`, `POST /agent/notifications/read-all` | Agent notifications | no |
| `GET /me/memory` | User memory markdown for briefs | no |
| `/agent/harness/lab/h1/*`, `/agent/harness/lab/h1/probe` | Cloud H1 lab worker (unused by the h1-mac-only runner) | yes (cfg.model) |

---

## 21. Rebuild plan (OpenClicky)

Goal: same behavior with OpenClicky-owned code and pluggable model slots. Recommended split: a Swift host and a
TypeScript agent runtime (Bun-compiled helper), keeping the runner HTTP protocol so either side can be swapped.

### 21.1 Swift (app target)

1. `AgentRuntimeKind` / `AgentPlace` / `AgentModelChoice` enums + `AgentRuntimePreferences` (UserDefaults keys,
   dev overrides for runner/node paths).
2. `AgentRunnerProcess` — spawn helper, env (`OPENCLICKY_RUNNER_TOKEN`, `OPENCLICKY_RUNNER_STATE`, PATH prefixes),
   ready-line reader with 20 s timeout, stdin keep-alive, restart on exit, stderr logging.
3. `AgentRunnerClient` — `/turn`, `/steer`, `/cancel`, `/prewarm`, `/events` long-poll loop with resync; typed
   `AgentRunnerEvent` decoding (table 5.10).
4. `AgentEventProjector` — maps runner events (and Codex notifications) into one `AgentTaskViewModel` stream:
   lifecycle, activity items, plan, commentary, thinking heading, program batches, answer, stats.
5. `CodexAppServerRuntime` (optional legacy path) — `CodexProcessManager`, `CodexHomeWriter` (config.toml per
   §6.3 with OpenClicky provider), `JSONRPCLineClient`, `CodexSession` (handshake, thread/turn/steer/interrupt,
   auto-accept approvals, MCP startup wait, rollout reader).
6. `AgentSessionTokenProvider` — obtains/rotates the bearer for the agent slot; restart policy on rotation.
7. `JobStore` + `JobFolderManager` — `projects/jobs/<slug>-<hex>/{output,tmp}`, `WORK.md` index, `report.md`
   managed block, `.clicky/owner`-equivalent, `previous-note.md`, restart-interruption ledger.
8. `ClickyRoster` (kept agents) — roster persistence, workspace + AGENTS.md template generator (write our own text),
   archive/unarchive, thread bindings.
9. `AgentBriefBuilder` — assembles instructions (own wording) + per-turn context: folder rules, attachments,
   screenshot policy, user-memory pointer, standing context ledger, routines list, browser state, final-message
   contract, lease metadata.
10. `FinalMessageParser` — tag regex, `ClickyAnswer`-equivalent Codable, routine/wait-for JSON, artifacts list,
    citation stripping; unit-tested against fixtures.
11. `ResultCardPresenter`, `JobRail` (edge shelf), `AgentHUD`, `LaunchFlightAnimator`, sound cues.
12. `LoopbackMCPServer` — localhost MCP (protocol 2025-03-26/2025-06-18), bearer token, tools `browser` (bridge
    to the Chrome extension doc) and `mac_step` (bridge to computer-use with consent card, 15 min timeout).
13. `MacStepConsentCoordinator` + `UserStepWatcher` (WAIT_FOR URL watcher).
14. `RoutineScheduler` — local routines (interval / daily / weekday times), NWPathMonitor wait, wake observer,
    IOKit sleep assertion, retry/backoff, run markers, DND quiet mode.
15. `RemoteTasksClient` + `AgentNotificationsClient` (only if OpenClicky gets a server; otherwise omit).
16. `UsageLedger` — per-turn token/cost records; optional lease client if a metering server exists.
17. `BrainAgentTools` — client handlers for `sessions_spawn`, `sessions_send`, `sessions_answer_request`,
    `session_status`, `clicky_memory`, `clicky_artifacts`, `open_artifact`, `show_result`, `find_jobs`,
    `read_job`, `routines`; plus the `[Your jobs]`/`[Your Clickys]`/`[Your routines]` context-note builders.
18. `AgentCommentaryStream` — rate-limited progress digest fed to the voice brain.

### 21.2 TypeScript runtime (`openclicky-harness`, Bun single-file build)

1. `runner/server.ts` — token-auth HTTP API, per-job event ring buffer (2 000), long-poll waiters, driver registry
   keyed `<runtime>-<place>`.
2. `driver/local.ts` — h1-mac equivalent: per-job state file, job create/turn/answer/steer/interrupt, event
   translation, stats accumulation, rounds log.
3. `jobs/localJobServer.ts` + `jobs/diskStore.ts` — job endpoint API (§5.4) with file-backed persistence
   (`job.json`, `turns.json`, `steps.jsonl`, `events.jsonl`, `blobs/`), restore on demand, 30-day GC.
4. `workflow/engine.ts` — durable `step.do` memoization with retry policies, `waitForEvent` with timeouts
   (portable to Cloudflare Workflows later).
5. `agent/loop.ts` — rounds, parallel tool execution, ask/answer, steering notes, side-effect ledger with
   idempotency keys, closing checks, limits.
6. `models/responses.ts` (SSE client, timeouts, retry classes, effort step-down, gzip negotiation) and
   `models/anthropic.ts` (Responses→Messages adapter). Both read base URL + bearer from the **agent slot** config.
7. `context/compaction.ts` — remote compact if supported, else structured-summary compaction (own prompt text).
8. `tools/` — `bash`, `read`, `write`, `edit`, `view_image` (can reuse an OSS coding-agent toolkit), `fetch_url`
   (HTML→text), `web_search` (pluggable provider), `ask_user`, `progress`, `update_plan`, `routines`, note tools,
   `exec` code-mode with `tools.*`, `store/load`, time budget.
9. `mcp/client.ts` (Streamable HTTP + SSE response parsing, retries, optional servers) and `mcp/stdioBridge.ts`.
10. `media/images.ts` — tile-budget downscale, JPEG fallback, per-request image budget (photon-wasm or sharp).
11. `instructions/assemble.ts` — environment block, batching guidance, workspace AGENTS.md, skill catalog from
    SKILL.md front-matter.
12. (Later) `cloud/deviceHelper.ts` — tunnel-based device tools with path deny-list, idempotency, workspace sync.

### 21.3 Fixtures/tests to write first

- Runner protocol contract tests (ready line, 401, `/turn` busy wait, `/events` long-poll ordering).
- Event projection snapshot tests from recorded `events.jsonl` shapes (synthetic, not the user's data).
- Final-message parser tests for every block, malformed JSON, missing closing tags, citation markers.
- Routine scheduler tests (interval, daily HH:MM + timezone, weekdays, sleep/wake, offline).

---

## 22. Open questions and unknowns

- Server prompts and logic for the brain tools, `/codex-thread-launch`, proactive suggestions, cron execution,
  notification generation: UNKNOWN (server-side).
- Exact lease create/complete routes and the session-token response field name for the token: UNKNOWN.
- Codex CLI version formerly bundled in `CodexRuntime`, and the exact launcher arguments beyond `app-server`:
  UNKNOWN.
- Contents/format of `state.md` in job folders and the `clicky-crons-mcp` helper: UNKNOWN (not present on disk).
- Whether the brain ever selects `place = cloud` or `pi` in production: INFERRED no (driver not registered).
