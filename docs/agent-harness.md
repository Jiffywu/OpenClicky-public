# Agent harness

Background jobs run in the harness the `agent` slot names: Codex CLI or Claude Code. Code: `Sources/OpenClickyKit/Agent/`
(HUD and notifications: `Sources/OpenClicky/Agents/`).

## Files

Under `~/Library/Application Support/OpenClicky/` (`OPENCLICKY_SUPPORT_DIR` relocates it):

| Path | What |
|---|---|
| `projects/WORK.md` | Index of every job, newest first. Agents read it to find earlier work. |
| `projects/jobs/<slug>-<10 hex>/` | One-off job. |
| `projects/agents/<slug>/` | Kept agent: the same folder for every task it gets. |
| `…/AGENTS.md` | Job notes, or the kept agent's persona, standing preferences and notes. Both harnesses read it. |
| `…/output/`, `…/tmp/` | Deliverables; scratch. |
| `…/job.json` | `AgentJobRecord`: status, runs, harness thread id, latest report, pending request, usage, the list flags (`isSeen`, `isDismissed`, `archivedAt`), a waiting user step and proposed routines. |
| `…/events.jsonl` | Normalized events, one per line, plus a `run` marker (`id` = run number, `text` = the ask) when each run starts. |
| `…/report.md` | Latest report and the list of runs. |
| `…/diffs/run-<n>/<i>-<file>.diff` | Developer preview: unified diffs of the files that run changed (see File diffs). |
| `agents/<slug>/jobs/<job-id>` | A relative link to a one-off job the organizer filed under this kept agent. The job folder stays in `jobs/`. |
| `organizer.json` | The organizer's run-once flag (`completedAt`) and what it last did. |
| `routines.json` | Routines. |
| `harness/codex-home/` | OpenClicky's own `CODEX_HOME` (generated `config.toml`). |
| `harness/claude-config/` | `CLAUDE_CONFIG_DIR` for bring-your-own-key Claude Code runs. |

No file holds a key or token. Keys reach a harness only as environment variables, and the harness is told not to hand
them on to the commands the agent runs (see below).

## Harnesses

**Codex** (`codex app-server`, JSON-RPC 2.0 over stdio, checked against codex-cli 0.165.0's generated schema):
`initialize` → `initialized` → `thread/start` (`cwd`, `developerInstructions`, `approvalPolicy`, `sandbox`, `model`) or
`thread/resume` → `turn/start`. Follow-ups use `turn/steer` mid-turn, otherwise a new turn. `turn/interrupt` stops a turn.
Approval requests (`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
`item/permissions/requestApproval`, `item/tool/requestUserInput`) wait for the user.

- Bring your own key (`openai-responses` provider): `CODEX_HOME=harness/codex-home` with a generated `config.toml`:
  `model`, `model_provider = "openclicky"` and `[model_providers.openclicky]` (`base_url`, `wire_api = "responses"`,
  `env_key = "OPENCLICKY_AGENT_API_KEY"`, `http_headers`), approval policy and sandbox, `[features]` off for plugins,
  connectors, memories, hooks and screen control, `notify = []`, `[mcp_servers.*]` with `bearer_token_env_var`, and
  `[shell_environment_policy.filters]` excluding exactly the variables OpenClicky adds (the key, MCP tokens). Codex
  hands KEY/TOKEN variables to every command the agent runs by default (`ignore_default_excludes` is true), where a
  prompt-injected command could read them.
- `harness-login`: Codex's ChatGPT sign-in. If OpenClicky's home has one (`occtl agent login codex`), that home is used.
  Otherwise the user's own Codex home is used with the same settings as `-c` overrides, plus every MCP server the
  user configured switched off (`codex mcp list --json`, names only, run off Swift's cooperative threads) and their
  `notify` program off. All MCP settings go in one inline `-c mcp_servers={ "name" = { enabled = false }, … }`: Codex's
  `-c` parser splits keys at every dot, so `mcp_servers."my.server".enabled` would make it refuse to load its config. Nothing is written there. No environment filters there: a `filters` override switches off a
  user's own legacy `exclude` list for the run, and these runs carry no OpenClicky key (the browser MCP token, if
  the bridge runs, stays visible to the agent's commands; it only reaches the loopback bridge).

**Claude Code** (`claude -p --input-format stream-json --output-format stream-json --verbose --permission-prompt-tool
stdio --setting-sources project,local --strict-mcp-config --mcp-config <json> --append-system-prompt <instructions>`,
checked against 2.1.314): user messages go in as stream-json lines, each turn ends with a `result` line, permission
prompts arrive as `control_request`/`can_use_tool` and are answered with `control_response`; interrupt is a
`control_request` (SIGINT after 10 s). `--resume <session>` continues a conversation. A user message written while a
turn runs gets its own turn and `result` (checked on 2.1.314), which is how queued follow-ups are counted.

- Bring your own key (`anthropic-messages` provider): `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`,
  `ANTHROPIC_CUSTOM_HEADERS`, a separate `CLAUDE_CONFIG_DIR`, and `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, without which
  Claude Code passes the key (and any MCP token) to the agent's Bash commands, hooks and stdio MCP servers.
- `harness-login`: no key in the environment, so Claude Code uses its subscription sign-in.
- MCP bearer tokens are `${VAR}` references in `--mcp-config`.

Both: model keys exported by the user's shell and nested-agent markers (`CLAUDECODE`, `CODEX_THREAD_ID`, …) are
dropped from the child environment; loopback is added to `NO_PROXY`. Approval mode `ask` (default) is Codex
`on-request` + `workspace-write` (network on) or Claude Code `acceptEdits`; `full-access` is no sandbox, no prompts.
An unanswered request is declined after 30 minutes.

The browser bridge's MCP server is offered when its `mcp.json` (`BrowserBridgePaths.standard`, moved only by
`OPENCLICKY_BRIDGE_DIR`) exists and its process is alive.

## Events and reports

Each harness's stream becomes `AgentEvent`s: `progress` lines, `thinking` headings, `commentary`, `plan`,
`fileChanged`, `approvalRequested`/`approvalResolved`, `usage`, `error`, `turnFinished(outcome, finalText)`.

The job instructions (`AgentInstructions`) ask the agent to end with:

```
<report>
say: One or two sentences to say aloud.
title: Two to five words
files:
- output/main-file.ext
next:
- A follow-up the user could ask for
question: Only when blocked on the user.
</report>
```

`AgentFinalReport.parse` reads it (or falls back to the first sentence). Before that, `AgentFinalBlocks.extract` takes out
the optional blocks the instructions also teach (tags in any case, spaces allowed, a missing closing tag runs to the
next block or `<report>`; each block is checked on its own, and a malformed one is dropped with a note in
`AgentFinalReport.blockProblems`):

| Block | Content | What OpenClicky does |
|---|---|---|
| `<answer>` | one JSON object (`AgentAnswer`): `outcome` (≤90 chars) plus `numbers` (≤3 `{value≤9, label, was?, of?, better?}`), `list` (≤4 `{text≤40, detail≤20}`, `ranked`), `done` (≤3 `{did, what, link?}`), `draft` (`{text, to?}`), `ask` (≤3 `{answer≤28, detail?}` or `{file}`), `note` (≤70), `next` (`{label, open}`), `quiet` | the result card lays out at most two blocks (`AgentAnswer.blocks`); numbers look like one hero figure, tiles, before/after changes or progress toward a total; a choice sends its answer to the job; a draft has Copy. Without a `say:` line the outcome is spoken. |
| `<routine>` | `{action: create\|update\|pause\|resume\|delete, title, task?, every_minutes? \| at "HH:MM" + days?, new_title?}` (`AgentRoutineRequest`) | the job goes to needs-you with a confirmation (`pendingRoutines`, request id `openclicky-routine-…`); yes applies it through `AgentCoordinator.apply` (created routines run in that job's folder, or its kept agent); no drops it |
| `<wait_for>` | `{step, page?, done_when_url_contains?}` or a plain sentence (`AgentUserStep`) | the job waits in needs-you (`waitingStep`); "I'm done" on the card, the HUD, Home → Agents, or `sessions_answer_request` approve sends a follow-up run that checks the step and carries on; decline ends the wait |
| `<learned>` | up to three `Topic: what worked` lines (`AgentLearnedHowTo`) | saved as how-tos (`AgentHowToLearner.saveLearned`) instead of the brain-fast learning pass |

A waiting user step and proposed routines survive a relaunch (`recoverInterruptedJobs` keeps them in needs-you). The
browser-URL watcher for `done_when_url_contains` isn't built: the user says when they are done. `COMPUTER_USE_REQUEST`
isn't parsed (it belongs with `mac_step`). Citation leftovers from the agent's web
searches (`[label](turn0search3)`, `cite turn0search3`, `【4:0†source】`, spans in U+E200–U+E201) are removed first
(`AgentText.stripCitations`). Each finished run becomes an `AgentJobReport` (with the run's deliverable `kind`: pdf,
document, sheet, slides, image, video, page, code, message or research); `AgentReportBatcher` groups those that finish
close together and `AgentReportTurn.note(for:)` is the note that starts the brain's report turn.

### Report turns, result cards and sounds

- A report turn that fails, or ends without a spoken line or a `show_result`, is run once more with an `[App]` note
  saying the first try didn't reach the user (`TurnOrchestrator.reportRetries`). It never says "something went wrong,
  ask again": the user didn't ask. If the retry doesn't land either, the notch shows the jobs' own `say` lines
  (`AgentReportTurn.fallbackText`) and `onReportUndelivered` opens the jobs panel.
- `show_result` (held until the narration ends) opens the result card (`AgentResultCard` in the kit,
  `AgentResultCardView`/`AgentResultCardPanel` in the app): summary, report, files and links, up to three next-step
  chips, and a reply box when the job asked something. A chip sends its text to the same job (`AgentManager.send`).
- Sounds (`UICue`): `agentLaunch` when work starts (`AgentManagerUpdate.launched`, and a chip or reply sent from the
  card), `agentNeedsYou` when a running job stops for a yes or a report comes back with a question, `agentDone`
  otherwise.
- Launch labels: `ModelAgentLaunchLabeler` on the brain-fast slot names a new job ("Denver Flight Options") and writes
  its start line ("I will search for nonstop SFO to Denver flights."). It runs beside the launch, never before it: the
  job starts under its first-words title, and the title (unless the brain named the job) and the start line are filled
  in when the labels arrive (gpt-5-nano: 2.5–3.7 s). Reasoning models that list no efforts are asked for `low`.

### File previews

The result card renders the report's Markdown natively (`MarkdownBlockParser` in the kit, `MarkdownDocumentView` in the
app): headings, nested and task lists, code, tables, quotes and images. Each file has a preview button (the eye), and
the expand button opens the whole report; both open the preview pane (`FilePreviewPane` in a normal window), with the
job's report and files in a sidebar, and Open in the default app and Show in Finder above each one.

| Kind (`FilePreviewKind`) | Files | Viewer |
|---|---|---|
| `markdown` | `.md`, `.markdown` | Native blocks; relative images resolve beside the file |
| `spreadsheet` | `.csv`, `.tsv` | `DelimitedText` (RFC 4180, delimiter guessed), grid with frozen column letters and header row, row numbers; click, shift-click or a column letter selects, and the bar shows Count, Sum and Average (`GridSelectionSummary`) |
| `pdf` | `.pdf` | PDFKit `PDFView`, continuous and fit to width |
| `animatedImage` | GIF, APNG (`acTL` before `IDAT`) | Frames and per-frame delays from ImageIO, looped |
| `quickLook` | everything else, XLSX included | `QLPreviewView` |
| `link` | `http(s)` | Opens in the browser |

`OpenClicky --render-preview-snapshots <folder>` renders each kind in light and dark from fixture files. PDFView draws
its pages in tiles that never reach an offscreen capture, so the renders draw the same document's pages with PDFKit
(`PDFPageStackView`); the app uses the interactive PDFView.

### Job list state and transcripts

`AgentTranscript.build(record:entries:)` folds `job.json` and `events.jsonl` into one turn per run: the ask, what the
agent said (`commentary`), reasoning headings, tool steps, files touched, the latest plan, the parsed report with its
next steps, and the error. Events go to the run whose marker came last; a finished turn moves on to the next run, so
logs from before the markers split the same way, and a harness restarted after a crash writes its run's marker again.
A run whose log was cleaned up keeps its ask and spoken result. `read_job` (detail `conversation`) gives the brain the
same turns (`brainLines`), and Home → Agents shows them (`AgentJobsBrowserView`: the list with preview text, an unseen
dot and count, run counts, Archive / Mark as seen in the context menu and an Archived view; the selected job's
transcript per run, its next-step chips, "I'm done" and a follow-up field).

Flags in `job.json`: `isSeen` (false when a run finishes; opening the job marks it seen; nil on older records counts
as seen), `isDismissed` (closed in the jobs panel; a new result clears it), `archivedAt` (`isArchived`: out of the default list and
the panel; a new run clears it, except a kept agent's own routine runs). `AgentJobStore.listed()` leaves archived jobs out. `occtl agent show <job> --transcript` prints the same
turns from the files (what a relaunched app reads).

### Task assets

The voice loop's screen (`AgentContextScreen`) records every turn's screenshots in `AgentTurnAssetsBox`.
`sessions_spawn` hands them to the new job (unless `include_screen` is false), plus any `attachments` (absolute paths,
as inputs only). They are saved as `harness/task-assets/<job>/run-<n>/screen-<i>.jpg` (outside the job folder, so
they never look like deliverables) and attached as images; the brief says what they are and that a file or page the
user had open is better read directly. A routine run is told no screenshot is attached.

### Silent context

`AgentContextScreen` also appends `AgentBrainContext.note` (`[Your jobs]`) to every voice turn's notes: what is running
with its latest progress line and what the agent last said, what waits on the user (with request ids), and what came
back recently. The brain is told not to read it out.

## Brain tools

`AgentTools.specs` (JSON schema) and `AgentTools.call(_:)`: `sessions_spawn`, `sessions_send`, `sessions_interrupt`,
`session_status`, `sessions_answer_request`, `find_jobs`, `read_job` (the job's `report.md`, files and next steps, or
its recent conversation), `show_result`, `routines`, and the kept-agent tools below. Results are JSON objects with a
`status`. `AgentBrainContext.note` is the `[Your jobs]` context for each brain turn.

A job can also wait on a `chrome_setup` request (`AgentApprovalRequest.Kind.chromeSetup`): OpenClicky raises it when
the job calls the browser and none is connected (`AgentManager.requestChromeSetup`, once per job; it survives the end of
the job's turn). `sessions_answer_request` answers it without the harness: approve runs `AgentTools.openBrowserSetup`
(the app opens Settings → Browser) and returns `steps` for the brain to explain, and the job gets a follow-up once a
browser connects (`AgentManager.browserConnected`), or at once when one already is (`setBrowserConnectedCheck`);
decline sends the job a follow-up to finish without the browser. A harness approval that arrives meanwhile is shown
first, and an answer with no `request_id` goes to whichever request is shown. Stopping the job (or a turn that ends
stopped or failed) drops the request and the wait for Chrome.
What each turn did in the browser (`BrowserTurnUsage`) is kept on its run as `runs[].browser` in `job.json`.

## OpenClicky's tools for jobs (loopback MCP)

The app serves three tools next to the browser tool on the bridge's loopback MCP server (`AgentJobMCPTools`, passed as
`BrowserBridgeService.start(extraTools:)` by `AgentServices`):

| Tool | What it does |
|---|---|
| `openclicky_web_search` | `query`, `count`, `freshness`: the search service set in Settings → Services (`LookupServices.make`, metered like the brain's searches). For harnesses without a search of their own. |
| `openclicky_progress` | `line` and/or `plan` steps (`pending`, `in_progress`, `completed`): published as the job's plan and a commentary line, so the HUD and `[Your jobs]` follow them. Not counted as steps. |
| `openclicky_routines` | `list` (all, marked `this_job`), `add` (asks the user through the job's needs-you flow and waits up to the approval timeout; yes creates it in this job's folder), `pause` / `resume` (this job's routines by title). |

The calling job is the `X-OpenClicky-Job` header: every launch fills it in for servers with `jobHeaderName` (the
browser server from `mcp.json`) as a secret header, so it travels like the bearer token (Codex `env_http_headers`,
Claude Code `${OPENCLICKY_MCPVAR_n}`). Without it, a thread id in the call's `_meta` (Codex's turn metadata) is matched
to the job's harness thread. `occtl agent run --job-tools` serves the same tools on its own loopback server
(`AgentJobToolServer`, `openclicky_tools`) for that run. `occtl browser mcp-serve` serves only the browser tool.

The three tools are `trustedTools` on that server: Claude Code gets them as `--allowedTools
mcp__<server>__<tool>` in ask mode, so a progress line or a search never stops the job for a yes (adding a routine
still asks, through the job's own needs-you flow). Codex doesn't ask before MCP tool calls.

## Kept agents ("Clickys")

A kept agent is a job record of kind `kept` in `agents/<slug>/`, made by `sessions_spawn` with `keep` (or by the
organizer). The brain sees them in a second note, `AgentBrainContext.clickysNote` (`[Your Clickys]`): name and slug,
role, `WORKING NOW` / `WAITING ON THE USER` / idle, and the last thing it said (its latest message while it works, else
its last report); archived ones are listed by name on one line. `AgentCoordinator.brainNotes()` returns both notes and
`BrainWiring.jobNotes` hands them to the runtime with `[Your routines]` (`routinesContext()`); the runtime sends each
again only when its text changes. The app's voice loop reads them through `AgentServices.brainNotes()` instead
(`[Your jobs]` with the agent settings line, `[Your routines]`, then `[Your Clickys]` from the coordinator;
`AgentServicesNotesTests`).

| Tool | Kind | What |
|---|---|---|
| `clicky_memory {agent}` | read | `memory_markdown` (its `AGENTS.md`, cut at 8,000 characters with "(memory file truncated)"), `state_markdown` (`state.md`), the six latest runs (asked, outcome, said), `latest_reply`, `current_progress` while it works, `is_archived`, `is_working_now`, and the jobs the organizer filed under it. Also works on a one-off job. |
| `clicky_artifacts {agent, file?}` | read | Files in its folder, newest first (`output/` and top-level files; never `tmp/`, `diffs/`, `job.json`, `events.jsonl`, `AGENTS.md`, `state.md` or linked job folders). With `file` (a relative path or a bare name) it reads one in full, text only, up to 20,000 characters. Anything resolving outside the folder, or into `diffs/`, is `not_found`. |
| `clicky_archive {agent, action}` | action | `archive` or `unarchive`. Archiving needs a kept agent that isn't working; it sets `archivedAt` in `job.json`, so it survives a relaunch. The jobs list's Archive button (`AgentManager.setArchived`) sets the same `archivedAt` on any job. |
| `open_artifact {agent, file?}` | deferred | Opens a file from its folder in its usual app (default: its newest output). Offered only when the app supplies `AgentTools.openFile`. |
| `open_agent_dashboard {action?, job_id?}` | deferred | Opens `openclicky://home/agents` (or `openclicky://job/<id>`) through the app's URL router; `close` hides the jobs panel and Home when it shows Agents. Offered only when the app supplies `AgentTools.openLink`. |

Revive on route: `sessions_spawn` naming an archived kept agent unarchives it first and its result carries
`revived: true` with a message telling the brain to mention it; `sessions_send` does the same. A kept agent's own
scheduled routine runs on it while it stays archived (archiving keeps its routines). `clicky_memory`
is no longer an alias of the user's `recall_memory`. `sessions_yield` is not built: the reverse-engineering notes don't
say what it does.

### Organizer

`AgentOrganizer` groups finished one-off jobs (not filed yet, not routine runs, newest 60) under kept agents. One
brain-fast call (the launch labeler's model and effort, 60 s deadline) gets each job's id, title, first ask, last reply,
date and run count, plus the existing kept agents, and answers JSON: groups with `existing_slug?`, `name`, `role`,
`description`, `job_ids`, `notes`, and `leftover_job_ids`. `AgentOrganizer.parse` keeps only known job ids, each in one
group, groups of two or more (one is enough to join an existing kept agent), names up to 40 characters, at most eight
groups. `apply` first sets aside jobs already filed (another run may have filed them meanwhile) and skips a group
left with no job to file (fewer than two for a new kept agent), so no empty kept agent is made. A new name joins the
kept agent of the same name; otherwise it gets its own folder: names with no Latin letters are transliterated for the
slug (`旅行プランナー` → `lu-xing-puranna`), and a slug another agent already uses gets `-2`, `-3`. It creates the kept
agents (harness, model and provider from the group's first job), writes the group's
notes and a dated list of the filed jobs into its `AGENTS.md`, sets `filedUnder` in each job's record and links
`agents/<slug>/jobs/<job-id>` → `../../../jobs/<job-id>`. Applying again changes nothing (filed jobs are skipped, links
aren't made twice). `organizer.json` holds the run-once flag: the app runs it by itself once, after start, when at
least six finished one-off jobs are waiting; Settings → Agents ("Group Old Jobs Now") and `occtl agent organize
--force` run it again; `--dry-run` only prints the proposal.

## File diffs (developer preview)

Off by default; Settings → Agents → Developer preview turns on `developerFileDiffs` in `agent-settings.json`, which
`AgentManager.setFileDiffs` reads at every file event. Harnesses emit `AgentEvent.fileWillChange(path:)` before an edit:
Codex on `item/started` for a `fileChange` item (before the patch is approved or applied), Claude Code on a `Write`,
`Edit`, `MultiEdit` or `NotebookEdit` tool use. The first time a run sees a path, `AgentFileDiffRecorder` keeps its
content (text up to 256 KB, measured on a link's target, and only regular files; `AgentFileSnapshot` reads anything
with a NUL byte or not UTF-8 as binary). A `fileChanged … created` with no earlier event means the file didn't exist. When the turn ends every touched file is read
again: unchanged files are dropped, the rest become `AgentFileDiffItem`s (`created`, `changed`, `deleted`, with line
counts and sizes) in the record's `fileDiffs` (newest 400 kept; a trimmed item's diff file is deleted with it), with a
unified diff (`AgentUnifiedDiff`, three lines of context) in `diffs/run-<n>/`. Lines shared at the start and end are
matched directly; when more than 2,000 changed lines remain (a file rewritten throughout), they are shown as one removed
and one added block instead of going through Myers, whose memory grows with the square of the edit distance. Binaries and files over the cap are listed with `skipped: binary` or `too_large` and no
text; a change that arrived before any "about to change" event is `before_missed`. Neither harness waits for
OpenClicky before editing (Claude Code in acceptEdits mode, Codex auto-applying a patch), so the edit can land before
the snapshot. The recorder can't prevent that, only notice it: a file already modified since the run started when its
"before" is read is listed as `before_missed` (or `created`, if the harness then reports it as new) rather than
compared with itself and dropped. A file the run touched earlier by a shell command shows the same way. Paths are
compared by the real path of the nearest folder that exists (`AgentFileDiffs.canonical`), because Claude Code has named
one file `/private/tmp/…` before an edit and `/tmp/…` after it, including in folders the edit creates. Files a job changes with shell commands aren't reported by either harness and get no
diff. `occtl agent run --diffs` (or `developerFileDiffs` in the sandbox's `agent-settings.json`) keeps them from occtl. "Show File Changes…" in Settings
→ Agents opens the viewer (`AgentFileDiffsView`): jobs and their files on the left, the coloured diff on the right.

## Limits, compaction and cleanup

`AgentLimits` (config `agentLimits`, every field optional):

| field | default | enforced by |
|---|---|---|
| `maxStepsPerRun` | 120 | the manager counts tool starts and interrupts the run past the cap |
| `maxRunSeconds` | 1800 | the manager interrupts a run still going after it |
| `commandTimeoutSeconds` | 300 | Claude Code (`BASH_DEFAULT_TIMEOUT_MS`, `BASH_MAX_TIMEOUT_MS`); Codex is told in its instructions |
| `assumeAfterSeconds` | 1800 | a report question nobody answers: the job is told to carry on with its best assumption (nothing it can't undo) and say what it assumed; once per question |
| `idleEndSeconds` | 21600 | a job still waiting on the user after 6 hours is ended (no longer "waiting") |
| `cleanupAfterDays` | 30 | `tmp/` contents, `events.jsonl` and task screenshots of one-off jobs idle that long (only in folders whose `.openclicky/owner` marker names the job); kept agents lose only old task screenshots |
| `compactionTokens` | 160000 | Codex `model_auto_compact_token_limit`; Claude Code `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (at least 100k) |

**A harness that dies mid-turn.** When the process exits during a turn ("Codex stopped (exit N)", "Claude Code stopped
(exit N)", recognized by `AgentHarnessExit`), the manager restarts the harness once in the same run, resuming its
conversation (Codex thread, Claude Code `--resume`) with a short note: it was interrupted, read `state.md`, don't repeat
outside actions, carry on (`AgentInstructions.resumeAfterCrash`; the original ask when there was no thread to resume).
Each exit is kept in the run's `harnessExits`; a second exit in the same run fails it with both. A turn the model
failed, a stop OpenClicky asked for, or a quit is not retried.

A run stopped at a limit is reported as stopped with the reason ("…stopped early: It reached the limit of 120 steps
for one task…"). Unanswered approval requests keep the 30-minute decline (a question gets "assume and say so").
`AgentCoordinator` runs `AgentManager.maintain(limits:)` at start and hourly (assume for questions left while the app
was closed, the idle end, the cleanup); sweeps don't reorder the job list.

**The job ledger.** The manager keeps what a harness's own compaction can lose in `AgentJobRecord.ledger` and writes it
to `state.md` in the job folder: actions that changed something outside the folder (approved writes and sending
commands, app tools whose names write: "Called gmail: send_email"), what the user said (approvals, answers,
follow-ups), and the files touched. The instructions tell the agent to read `state.md` after a compaction or when it
picks the job up later. Both harnesses report compaction (`AgentEvent.compacted`: Codex `thread/compacted` or a
`contextCompaction` item, counted once; Claude Code `compact_boundary`); a Codex turn is then steered with the ledger.
Claude Code would only read a message after the turn, so it relies on `state.md`.

**Ownership and kind.** New job and kept-agent folders get `.openclicky/owner` (`openclicky-job-owner:<id>:<created>`);
finished runs get a deliverable kind (`AgentJobRecord.deliverableKind`, in the report JSON as `kind`).

## Routines

`RoutineScheduler` runs routines while the app is open: `every_minutes`, `at` HH:MM with optional weekdays, or a
five-field cron string. A routine whose time passed while the app was closed runs once on launch. Interval routines
keep their phase. Failed runs retry after 10, 20 … 60 minutes, but never after the next scheduled run. Later runs go
to the same job folder and are asked to report only what changed.

Before a due run starts, the scheduler checks `RoutineRunConditions` (`SystemRoutineConditions` in the app):

- **Dark wake.** A run that comes due while the Mac is in a dark wake (it went to sleep and the full-wake notification
  hasn't come: Power Nap, maintenance) waits for a full wake. Checked again every 15 s.
- **Network.** With no usable path (`NWPathMonitor`), the run waits, rechecked every 15 s, for up to 15 minutes
  (`networkWaitCap`), then starts anyway. `waitingForNetworkSince` and a `deferral` line ("waiting for the network
  since 08:00", "ran 3 minutes late, once the network was back", "ran without a network after waiting 15 minutes")
  are saved in `routines.json` and shown to the brain.
- **Keep awake.** Each run holds an IOKit `PreventUserIdleSystemSleep` assertion ("OpenClicky is running the routine
  …") from its start until its outcome is recorded (or the scheduler stops).

`RoutineNotes.brainNote` is the `[Your routines]` note: every routine with its schedule, next run, run count, failures
and deferral. The brain runtime sends it with `[Your jobs]` and again only when it changes (`AgentServices.brainNotes`,
`BrainWiring.jobNotes`). Every job launch gets `RoutineNotes.jobNote` in its instructions (the current list, marking the
routines that run in its folder).

## Wiring into the app

`AgentServices` (app target) owns `AgentCoordinator.live(...)`, the HUD panel and notifications:

```swift
// Called (off the main actor) at each launch, so settings changes apply to the next job. Give it a thread-safe copy
// of the config the app holds, e.g. a lock-protected box the settings window updates on save. Avoid
// `(try? OpenClickyConfig.load()) ?? .heyClickyLike`: a config that fails to read would run jobs on defaults.
let agents = AgentServices(config: { configSnapshot.value }, credentials: model.credentials)
agents.onReportTurn = { note, reports in /* start a brain report turn with `note` */ }
agents.start()          // after launch
await agents.stop()     // on quit
agents.panel.toggle()   // menu item / shortcut
```

The brain runtime adds `agents.tools.specs` to its tools, sends matching calls to `agents.tools.call(_:)`, and puts
`await agents.brainContext()` in its per-turn context (the voice loop does both: `ToolRegistry.agentTools` and
`AgentContextScreen`).

At every launch `AgentCoordinator.live` adds what `AgentConnectedApps.extras()` exports (connected-app MCP servers,
the Connected apps and Obsidian sections, `OBSIDIAN_VAULT_PATH`; see connected-apps.md) and the browser bridge's MCP
server when it runs. The app starts the bridge itself (`AppBrowserBridge`: the native-host socket and the loopback MCP
server, unless another process such as `occtl browser mcp-serve` already serves it), so app-launched jobs get
`openclicky_browser`. A server with a `jobHeaderName` (the browser's) gets the job's id in that header at each launch
(`AgentMCPServer.identifyingJob`), so the bridge can tie each call to the job's turn (browser-bridge.md, "Jobs and
turns") and the job tools on the same server know who is calling.

`AgentMCPServer` carries secret headers (`secretHeaders`, header → variable), stdio variables
(`forwardedVariables`) and plain stdio `environment`; secret values ride in `secretValues` and reach the harness only
through its environment. Codex hides them from the agent's commands (`shell_environment_policy` filters). Claude Code
gets them under plain aliases (`OPENCLICKY_MCPVAR_<n>`): with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` on (every
bring-your-own-key run) Claude Code 2.1.314 withholds TOKEN-, KEY- and AUTH-like names from `${VAR}` expansion in its
MCP config, which sent the browser server a bare `Bearer` header (checked against a local server). Because the
aliases don't look like credentials, the agent's own shell commands can read them under Claude Code, as they always
could in harness-login runs.

## Config

`harness-login` is a provider dialect for the agent slot only. It serves no model kind (no OpenClicky client talks to
it), so nothing that wants a language model, such as the brain slots or dictation cleanup, accepts it; the validator
allows it in the agent slot with a harness set, with the model `default`, empty, or any name the harness takes. The
settings window lists providers by the kinds they serve, so it doesn't offer `harness-login` yet: set it in
`config.json` or add an agent-slot case there.

## occtl

```sh
occtl agent run "<task>" [--harness codex|claude-code] [--login] [--model M] [--keep NAME] [--yes] [--full-access]
                         [--image FILE] [--attach FILE] [--label] [--no-apps] [--no-browser] [--job-tools]
occtl agent send <job-id|agent> "<message>"
occtl agent list
occtl agent show <job-id|agent>          # also the ledger (state.md) and the deliverable kind
occtl agent maintain [--dry-run]         # the sweep: idle end and 30-day cleanup
occtl agent label "<task>"               # what the brain-fast labeler names a task
occtl agent login codex
occtl agent organize [--dry-run] [--force]   # group finished one-off jobs into kept agents (brain-fast)
occtl agent clickys                      # the [Your Clickys] note
occtl agent archive|unarchive <agent>
occtl agent diffs <job-id|agent> [N]     # the job's file diffs, or diff N in full
occtl agent-report <job-id> --out-dir d [--config c.json]   # the job's report turn: voice to d/voice.wav, card printed
```

`OPENCLICKY_CONFIG` names a config file for `occtl agent`; `OPENCLICKY_CONNECTORS_FILE` a connector registry.

occtl reads `config.json` from the support folder; with no file it uses the built-in defaults, and a file it can't
read stops it with the error. It has no daemon: `occtl agent send` to a job another occtl process is still running
starts a second harness on the same conversation.
