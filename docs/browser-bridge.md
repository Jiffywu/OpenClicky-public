# Browser bridge

OpenClicky's agents act in websites the user is already signed into through a Chrome extension, a native-messaging
host and a loopback MCP server. Nothing here talks to the network beyond the user's own browser.

```
Chrome / Arc / Brave / Edge / Vivaldi / Chromium
  OpenClicky extension (Extension/chrome, MV3)
    chrome.runtime.connectNative("com.openclicky.browser")
        │ stdio: 4-byte little-endian length + UTF-8 JSON
  OpenClickyBrowserHost (OpenClicky.app/Contents/Helpers)
        │ Unix socket ~/Library/Application Support/OpenClicky/BrowserBridge/bridge.sock
        │ same framing; first message carries the per-install token
  OpenClicky app or `occtl browser mcp-serve`: BrowserBridgeService
    BrowserBridgeServer (socket) ── BrowserTool ── MCPHTTPServer http://127.0.0.1:<random>/mcp (Bearer token)
                                                        ▲
                                         agent harness (Codex CLI, Claude Code)
```

## Files (`~/Library/Application Support/OpenClicky/BrowserBridge/`, mode 0700)

| File | Written by | Contents |
|---|---|---|
| `token` (0600) | first bridge start | 64 hex characters, created once per install. The host presents it on the socket. |
| `bridge.sock` (0600) | bridge while running | Unix socket the host connects to. |
| `mcp.json` (0600) | bridge while running; removed on stop | How agents reach the MCP server (below). |
| `extra-extension-ids.txt` | the user, optional | More extension IDs (one per line) to accept, for a differently keyed development copy. |

`OPENCLICKY_BRIDGE_DIR` overrides the folder. Chrome passes its environment to the host, so a test browser launched
with the variable set talks to a test bridge (see `Extension/chrome/tests/e2e.sh`).

### `mcp.json`: the agent endpoint

Agent harnesses read this file (or call `BrowserMCPEndpoint.loadIfRunning()` in OpenClickyKit) when they start a job:

```json
{
  "pid" : 4242,
  "serverName" : "openclicky_browser",
  "startedAt" : "2026-10-31T04:30:22Z",
  "token" : "<64 hex characters>",
  "tokenEnvironmentVariable" : "OPENCLICKY_BROWSER_MCP_TOKEN",
  "transport" : "streamable-http",
  "url" : "http://127.0.0.1:59213/mcp"
}
```

- The port and token change every time the bridge starts. Re-read the file for every agent launch.
- A file whose `pid` is dead is stale (`BrowserMCPEndpoint.isProcessAlive`).
- Give the agent the token through the environment variable named in the file. Don't write it into config files.
- Codex: `endpoint.codexConfigTOML` produces the `[mcp_servers.openclicky_browser]` block (url,
  `bearer_token_env_var`, 20 s startup and 900 s tool timeouts).
- Claude Code: `endpoint.claudeMCPConfig` produces an `--mcp-config` document whose `Authorization` header reads
  `${OPENCLICKY_BROWSER_MCP_TOKEN}`.

## MCP server

Streamable HTTP, JSON-RPC 2.0, one JSON response per POST (no SSE stream, no sessions), bound to 127.0.0.1 only.

- `POST /mcp` with `Authorization: Bearer <token>` (constant-time compare). Missing or wrong token: 401. Other paths:
  404. `GET`: 405 (no server-initiated stream). `DELETE`: 200 (nothing to tear down). A browser `Origin` header that
  isn't a loopback origin: 403. An `MCP-Protocol-Version` header naming a revision the server doesn't speak: 400.
- Methods: `initialize` (echoes `2025-11-25`, `2025-06-18`, `2025-03-26` or `2024-11-05`, otherwise offers the newest,
  `2025-11-25`), `ping`, `tools/list`, `tools/call`. Notifications and client responses get 202. Batches (pre-2025-06-18
  clients) are answered as arrays. Errors use the standard codes: -32700 parse, -32600 invalid request, -32601 unknown
  method, -32602 unknown tool or bad params. `notifications/cancelled` is accepted but doesn't abort a call in flight.
- Any local process can open a connection before it shows a token, so request reading is bounded: each connection
  has its own thread (not a shared GCD worker), at most 256 are served at once (more get 503), the whole request must
  arrive within 15 s (else 408), headers are capped at 64 KB, bodies at 8 MB, and chunked bodies accept only plain hex
  chunk sizes on lines under 1 KB.
- `tools/call` results carry `content` (text, plus a JPEG `image` block for screenshots), `structuredContent` (the
  extension's JSON result) and `isError`. Browser failures are tool errors (`isError: true`), not protocol errors.
  `params._meta` reaches tool handlers. Request headers named `x-openclicky-*` (a job's identity, which harnesses send
  as a per-server header) are merged into it under their lowercase names; the same keys written into `_meta` by the
  caller are dropped, so a model can't claim another job's identity.
- `tools/list` asks a tool for its description each time (`MCPTool.describe`), so the `browser` description follows
  the bridge's state, and lists the tool's `_meta` (the browser tool's per-operation hints).

### The `browser` tool

One tool with an `operation` argument (19 operations):

| operation | arguments | what happens |
|---|---|---|
| `status` | none | Whether an extension is connected, and which browsers and profiles. Answered by the app. |
| `tabs` | none | Every non-private tab: id, title, URL, which one is focused, and which ones this job opened. |
| `open` | `url` | New background tab next to the focused one, put in the job's tab group (titled with an emoji and the job's title, e.g. "🛒 Weekly groceries"); waits for the load and answers with the page's elements. The job owns the tab. |
| `navigate` | `url`, `tabId?` | Loads the URL in the tab and waits. Notes when Chrome shows an error page. |
| `snapshot` | `tabId?`, `query?` | Visible interactive elements, each with a ref (`e1`, `e2`…). On-screen first; at most 250. `query` keeps elements whose name, value, link or role contains it. Becomes the baseline for change lists. |
| `read` | `tabId?`, `query?`, `maxChars?` | `snapshot` plus the readable text (main/article first, 6,000 characters by default). |
| `extract` | `tabId?`, `maxChars?` | Readable text and visible tables (caption and rows, at most 10 tables of 60 rows), no refs. |
| `click` | `ref` | Scrolls it into view, refuses if disabled, hidden or covered (names the cover), then sends pointer events and a click. Waits for any navigation, or for the DOM to stay quiet for 300 ms. |
| `fill` | `ref`, `text`, `submit?` | Text fields through the element's own value setter (so React-style pages notice), rich editors (insertText, then a synthetic paste, then plain text, checking the text landed), and native lists by option text. Refuses password, one-time-code and payment fields. |
| `type` | `ref`, `text`, `clear?` (true), `submit?` | The older text entry: inputs, text areas and contenteditable editors. Same refusals. |
| `select` | `ref`, `value` | Native `<select>`: matches option value, then visible text, then a partial match. |
| `scroll` | `ref` or `direction` (`up`, `down`, `top`, `bottom`) | Scrolls the element into view or moves the page (or its main scrolling box). |
| `press` | `key`, `ref?` | Enter, Tab, Escape, arrows, Page Up/Down, Home, End, Space, Backspace, Delete, plus the default action pages rely on (Enter submits a form, Tab moves focus). |
| `back` | `tabId?` | History back. Falls back to the page's own `history.back()` when Chrome's back skips an entry the agent's synthetic click created. |
| `wait_for` | `text?` or `url?`, `gone?`, `timeout?` (s, ≤120) | Waits for text in the page or a URL fragment to appear (or go away). With neither, waits for the load to finish. |
| `batch` | `tabId?`, `steps` (1–20) | Runs `open`, `navigate`, `click`, `fill`, `type`, `select`, `press`, `scroll`, `wait_for` and `back` steps in order in one tab (a leading `open` supplies the tab). Every step is validated first ("Step N: … Nothing ran."); it stops at the first failing step and answers with each step's note and one change list. Its time is the steps' times added up, capped at 130 s, and the extension stops between steps when that runs out. |
| `screenshot` | `tabId?`, `save?` | JPEG of the visible part of the tab (made active in its window first; quality drops until it fits). `save: true` also writes it to `<job folder>/output/<site>-<yyyy-MM-dd-HHmmss>.jpg` and returns the path as `saved`; outside a job it says it wasn't saved (or, under `occtl browser mcp-serve --save-dir DIR`, saves under `DIR/output/`). |
| `close` | `tabId` | Closes a tab this job opened. Any other tab (the user's, another job's) is refused before anything is sent. |
| `keep` | `tabId`, `why` (`result` or `waiting`) | Leaves a tab the job opened open past the end of this turn. Lasts one turn. |

`tabId` defaults to the focused tab. A ref belongs to the document it was read from; after the tab loads a new
document, using an old ref fails and says to snapshot again. Actions (`click`, `fill`, `type`, `select`, `scroll`,
`press`) answer with `changes`: elements added, removed and changed (same ref, different label, value or state)
since the agent's last full look, at most 30 each. After a navigation there is no change list.

**Classes and timeouts.** `status`, `tabs`, `read`, `snapshot`, `extract`, `wait_for`, `screenshot` and `keep` are
read-only, as is a `batch` of only `wait_for` steps: a timeout on one says nothing changed and one retry is safe.
`navigate`, `click`, `type`, `fill`, `select`, `press`, `back` and `batch` may change a site. The tool's
annotations describe the riskiest case (`destructiveHint: true`); its `_meta["openclicky/operations"]` gives
`readOnlyHint` and `destructiveHint` per operation.

**Description.** While a browser is connected, `tools/list` shows the full description. With none connected it adds
that the first call asks the user to connect Chrome, so the agent should do the rest first; with no Chromium browser
on the Mac it says the tool can't work and to use search, fetch or numbered steps.

### Jobs and turns

Every harness sends the job's id as the `X-OpenClicky-Job` header on the `openclicky_browser` server
(`AgentMCPServer.jobHeaderName`, shared with OpenClicky's job tools; `AgentManager` fills it in at each launch through `secretHeaders`, which Claude Code
reads from an aliased variable and Codex from `env_http_headers`). Codex's `_meta["x-codex-turn-metadata"]`
(`thread_id`, `turn_id`) also finds the job by its thread. `BrowserTurnRegistry` then ties the call to the job's
current turn. The app (`AgentServices`) tells it when each turn starts and ends, from `AgentManager`'s events.

- **Refusals.** A call after the job's turn ended: "The agent turn ended." A call after the browser reconnected
  since the turn's first call (each host connection gets a new generation number): "Browser connection changed.
  Start a new turn." After an acting call timed out, the rest of the turn is refused, because the outcome is
  unknown. None of these reach the browser. A turn's calls go to the connection its first call used, even when
  another browser connects later.
- **Arguments.** Only the schema's own arguments reach the extension (MCP doesn't enforce `additionalProperties`),
  so an agent can't add the tidy-up's `tabIds` to a `close`.
- **Unbound calls.** A call with no job identity (`occtl browser call`, tests), or from a job this process never
  heard of (one started by `occtl agent run` against the app's bridge), works as before and is never refused for
  turn reasons; such calls share one owner for `close`.
- **Tidy-up.** When a turn ends, the app sends `close {tabIds, tidy: true}` (with the job as the command's `task`)
  for the tabs the job opened that this turn didn't `keep`, to the browser profile each tab was opened in. The
  extension closes only tabs it has recorded for that job and skips the rest. The user's own tabs are never in the
  list. The turn ends in order with the job's events; only the closing runs in the background, so it never ends
  the next turn. When a browser (re)connects the app sends `sweep {running}` so the extension closes tabs left by
  jobs that are no longer running (kept ones become the user's).
- **Stop.** Stop in the extension, during a call or between calls, hands every tab a job opened in that browser to
  the user: the extension forgets their owners (so neither a tidy-up nor a later `sweep` closes them), the app stops
  counting them as the job's, and the turn counts as stopped by the user, so nothing is closed when it ends. A call
  refused while paused comes back as `stopped`, like one that was in flight.
- **Counters.** Each turn counts calls (per operation), batch steps, errors, timeouts, tabs opened, kept and closed,
  screenshots taken and saved, Stop and access ended by a timeout (`BrowserTurnUsage`). At the end they are kept on
  the job's run (`job.json` → `runs[].browser`) and logged as one line in the job's activity.
- **Chrome setup.** A job's call while no browser is connected raises a `chrome_setup` request on the job, once
  per job; the call's error tells the agent to finish the rest and end its turn. The voice brain answers it with
  `sessions_answer_request_request`: approve opens `openclicky://settings/browser` and returns the setup steps to explain,
  and the job is told to carry on when a browser connects (at once, if one already is); decline tells the job to
  finish without the browser. A harness approval raised meanwhile is shown first; `chrome_setup` faces the user
  again once nothing else waits. Stopping the job ends its wait for Chrome.

## Socket protocol (host ⇄ app)

Native-messaging framing in both directions. The host's first message is

```json
{"type":"auth","token":"…","protocol":1,"session":"<host uuid>","profileId":"<extension's profile uuid>",
 "origin":"chrome-extension://emfgfcpifjoglbdkhjnnmokbagmgmlem/","browser":"com.google.Chrome","extensionVersion":"0.1.0"}
```

The app answers `{"type":"welcome","peerId"}`, or `{"type":"denied","reason"}` and closes. It checks the token, the peer
uid (`getpeereid`), the protocol, the origin against its allow list and that `profileId` is a UUID. After that:

- app → extension: `{"type":"command","id","operation","args":{…},"task","groupTitle"?}` (under 1 MB, Chrome's
  limit; `task` is the calling job's id, "" for unbound calls) and
  `{"type":"ping"}` every 20 s. A connection silent for three intervals is dropped.
- extension → app: `{"type":"result","id","ok":true,"result":{…}}` or `{"ok":false,"error":"…"}`, `{"type":"pong"}`,
  `{"type":"stop"}` (the popup's Stop button: in-flight commands fail at once) and
  `{"type":"event","name":"problem","reason"}` (a setup problem the extension can't fix itself, such as an old copy
  missing the tab-groups permission). A result only completes a command that was sent to the same connection.
- A handshake the app turns away (unknown extension, other protocol, bad profile id) and a reported problem are kept
  as the bridge's `lastFailure` until a browser connects; Settings → Browser shows it as a "Setup failed" badge.
- A local status probe: `{"type":"status","token"}` answered with `{"type":"status","peers":[…],"failure"?}`
  (`occtl browser status`).

## Host (`OpenClickyBrowserHost`)

Chrome starts it with the caller origin as an argument. It:

1. Exits 1 unless the origin is OpenClicky's extension (or listed in `extra-extension-ids.txt`).
2. Requires `{"type":"hello","protocol":1,"profileId":<uuid>,"version"}` first; exits 1 on anything else, on a body over
   16 MiB, or on a message that isn't a JSON object. Exits 0 when Chrome closes stdin.
3. Finds which browser launched it by walking up to four parent processes to the first `.app` bundle.
4. Connects to the socket (re-reading the token each time), retrying every 2 s while the app isn't running, and tells
   the extension `{"type":"ready","app":true|false}` whenever that changes.
5. Relays `command` and `ping` to the extension, and `result`, `pong`, `stop` and `event` to the app.
   `{"type":"openApp"}` opens OpenClicky (`open -a <bundle>` or `open -b com.openclicky.app`).

## Extension

`Extension/chrome` (MV3, version 0.2.0). Permissions: `nativeMessaging`, `tabs`, `tabGroups`, `scripting`, `storage`,
`alarms`, host access to `<all_urls>` (needed for `captureVisibleTab` and for injecting the page agent). A copy loaded
before 0.2.0 lacks `tabGroups`: it still works without groups and reports the problem to the app. The fixed `key` in `manifest.json`
gives it the ID `emfgfcpifjoglbdkhjnnmokbagmgmlem` everywhere; only the public key is in the repository.

- `background.js`: the native port, reconnect with backoff (1 s doubling to 30 s) plus a 30-second alarm that restarts
  the loop if Chrome unloaded the worker, a persistent per-profile UUID, the command dispatcher and tab operations,
  and the toolbar badge (`stop` = paused by the user, `off` = no host, `…` = host but no app, blank = connected).
  It keeps which job owns which tab, and each job's tab group, in `chrome.storage.session` (lost when the browser
  quits); `close`, `keep` and `sweep` work from that, and acting on another job's tab is refused. An `open` whose
  page doesn't finish loading within 45 s still answers with its tab, so the job owns it.
- `page-agent.js`: injected into a tab's top frame on first use; keeps the ref registry (a `WeakMap` and `WeakRef`s,
  so refs are stable for the life of the document) and does reading and acting inside the page. It walks open
  shadow roots, and remembers what the agent last saw (ref → role, name, value) to answer actions with changes.
- `policy.js`: the URL rules (only `http(s)` pages are read or acted in; `open`/`navigate` take `http(s)` without
  credentials, or `about:blank`) and the paused message. Pure, so node tests it.
- `popup.html`: status, agent access, Stop / Resume, Open OpenClicky, Reconnect.

**Stop.** Pressing Stop pauses agent control of that browser profile until the user presses Resume. The extension
tells the app at once, so calls in flight fail (a running `wait_for` also ends), and it refuses every command while
paused with a message telling the agent not to retry. The pause is stored in `chrome.storage.local`, so it survives
the service worker being unloaded and the browser restarting; the toolbar badge reads `stop` meanwhile.

## Installing

```sh
swift build
.build/debug/occtl browser install-host     # writes com.openclicky.browser.json for each installed Chromium browser
# chrome://extensions → Developer mode → Load unpacked → Extension/chrome
.build/debug/occtl browser mcp-serve         # or run OpenClicky
.build/debug/occtl browser status
.build/debug/occtl browser call read         # the focused tab, through the MCP tool
```

`install-host` writes only `com.openclicky.browser.json` in `<browser support>/NativeMessagingHosts/` for Chrome,
Chromium, Brave, Edge, Arc, Vivaldi (and Chrome Beta, Dev, Canary and Chrome for Testing when present). Other apps'
manifests, HeyClicky's `com.heyclicky.browser.json` included, are never read or changed. `--all` also writes for
browsers that aren't installed; `--host` points at another host build; `uninstall-host` removes OpenClicky's files.

## Testing

- `swift test --filter Browser`: framing (including byte-by-byte delivery), the MCP server over real loopback HTTP
  (token, path, method, origin, chunked bodies, errors), the socket relay with a fake extension driving a real
  `NativeHostRelay` over pipes (reconnects, refusals, timeouts, Stop, disconnects), the installer, and the extension ID.
- `swift test --filter BrowserTurns` and `--filter BrowserOperations`: job identity from `_meta` and the job header,
  header forwarding, each refusal (turn ended, connection changed, access ended after an acting timeout), tidy-up
  closing only the turn's unkept tabs, keep lasting one turn, Stop leaving tabs alone, the counters, the `chrome_setup`
  ask, `sweep` on connect, the state-dependent description and per-operation hints, and validation and formatting of
  every new operation. `AgentChromeSetupTests` round-trips a `chrome_setup` request through the brain's tools.
- `swift test --filter BrowserHardening`: malformed chunk sizes and endless chunk lines get 400 (not a crash), idle
  connections don't stall requests, the connection cap and request deadline, the `MCP-Protocol-Version` check, a
  cancelled call never reaching the browser, results only from the browser a command went to, no handshakes after
  `stop()`, and a failed start leaving nothing running.
- `node --test Extension/chrome/tests/policy.test.mjs Extension/chrome/tests/background.test.mjs`: the extension's
  URL rules, and the service worker against a fake `chrome`: `close` only for the job's own tabs, the tidy-up
  skipping others, Stop handing tabs to the user (tidy-up and `sweep` leave them), and a slow `open`.
- `Extension/chrome/tests/e2e.sh [out-dir]`: Playwright's Chrome for Testing, headless, with the unpacked extension
  and a throwaway profile and bridge folder, driven through `occtl browser call`. It also presses the popup's Stop and
  Resume through the DevTools protocol (`tests/popup.mjs`) and checks that a call in flight ends and later calls are
  refused until Resume.
- `Extension/chrome/tests/mcp-sdk-check.mjs`: the official MCP TypeScript SDK client against `mcp-serve`.

## Browser change approvals

The app requires a separate user decision before every browser operation that changes page or browser state. This includes open, navigate, back, click, type, fill, select, press, scroll, close and batch. A batch is approved as one complete request before any step runs. Read operations do not need a change approval.

The job's user controls show the operation, target page and full arguments. Allow this action approves that request once; Don't allow refuses it. The model cannot approve its own browser request through `sessions_answer_request`, and Full access does not skip this check. Cancellation and an ended or replaced job turn prevent a waiting request from running. The target tab is fixed before approval, and a different URL expires it.

`occtl browser mcp-serve` refuses changes unless started with `--confirm-writes` in an interactive terminal. That mode prints each request and requires the unique `ALLOW` confirmation shown for it. The confirmation expires after two minutes. Without an app approval handler or that terminal mode, only reads are available. Never run a browser approval server for an untrusted client.
