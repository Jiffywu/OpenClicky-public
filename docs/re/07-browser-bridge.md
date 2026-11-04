# 07: Browser bridge (Chrome extension, native-messaging host, loopback MCP)

Subsystem: how HeyClicky 1.1.2 (build 69, `com.humansongs.clicky`) lets its background agent act inside the user's signed-in Chromium browser.

Evidence legend:
- **OBSERVED**: seen in an artifact. The path and identifier are cited.
- **INFERRED**: my reasoning from observed facts.
- **UNKNOWN**: not recoverable from the client.

Abbreviations:
- `APP` = `~/Developer/openclicky-evidence/HeyClicky-1.1.2-b69.app`
- `DATA` = `~/Library/Application Support/Clicky`
- `HOST` = `APP/Contents/Helpers/ClickyBrowserHost`
- `MAIN` = `APP/Contents/MacOS/HeyClicky`

Method: static only. `HOST` was decompiled with REA/Ghidra (bound only for this task and closed afterwards) and disassembled with `otool`. `MAIN` was string-dumped. The x86_64 slice of `MAIN` was disassembled with `llvm-objdump`. That slice appears to be built without optimisation, so string literals load in source order, which let me recover per-function literal sequences (scratch dir `/tmp/openclicky-re/browser-bridge/`). Nothing was launched. No network calls were made. No secrets were read beyond key names and lengths.

---

## 1. One-paragraph summary

The browser bridge has no model of its own and makes no HeyClicky server calls. It is a local transport plus a tool:

1. A Chrome Web Store extension (`bphdnlcghkpiaoiplkhfofpfboddahce`) talks to a tiny native-messaging host, `ClickyBrowserHost`, over Chrome's stdio framing.
2. The host relays to the main app over **HTTP on 127.0.0.1**, using **MCP JSON-RPC `tools/call`**. It long-polls a private tool, `browser_poll`, and posts replies with `browser_reply`. The port and bearer token come from `DATA/BrowserBridge/connection.json`.
3. The main app runs a second loopback MCP server for the agent. It is registered in Codex's `config.toml` as `mcp_servers.clicky_browser` and protected by the env var `CLICKY_BROWSER_MCP_TOKEN`. It exposes a single, many-operation tool, `browser`, plus `mac_step`.
4. When the agent calls `browser`, the app turns the call into a `command` envelope. It queues the command for the extension of the selected Chrome profile, waits for the matching `result`, and returns it to the agent as MCP content (text plus an optional JPEG image).
5. A bundled skill, `clicky-browser`, teaches the agent how to use the tool.
6. A setup flow installs native-host manifests into every Chromium browser's support folder and sends the user to the Web Store. The voice brain can walk the user through that install.

```
 ┌──────────── Chrome (user profile) ────────────┐
 │  HeyClicky extension (MV3, Web Store)         │
 │   connectNative("com.heyclicky.browser")      │
 └──────────────┬────────────────────────────────┘
                │ stdio, 4-byte length + UTF-8 JSON
 ┌──────────────▼────────────────────────────────┐
 │ ClickyBrowserHost (Contents/Helpers)          │  spawned by Chrome, argv[1] = caller origin
 │  hello → poll thread (browser_poll loop)      │
 │  result/stop → browser_reply; openApp → open  │
 └──────────────┬────────────────────────────────┘
                │ HTTP POST http://127.0.0.1:<port>/mcp
                │ Authorization: Bearer <token>   (from BrowserBridge/connection.json)
 ┌──────────────▼──────────────────────── HeyClicky.app ──────────────────────────┐
 │ ClickyLoopbackMCPServer "clicky_browser_host"  tools: browser_poll, browser_reply│
 │                     │                                                           │
 │            ClickyBrowserBridge (profiles, pending polls, commands, turns, tidy)│
 │                     │                                                           │
 │ ClickyLoopbackMCPServer (agent endpoint)  tools: browser, mac_step (+jobs)      │
 └──────────────▲──────────────────────────────────────────────────────────────────┘
                │ HTTP POST http://127.0.0.1:<port2>/mcp, Bearer $CLICKY_BROWSER_MCP_TOKEN
                │ params._meta["x-codex-turn-metadata"] = {thread_id, turn_id}
 ┌──────────────┴────────────────────────────────┐
 │ Codex CLI (model gpt-6-luna via api.heyclicky │   or clicky-harness (same MCP endpoint)
 │ .com/agent/openai/v1) + skill clicky-browser  │
 └───────────────────────────────────────────────┘
```

---

## 2. Components

### 2.1 Chrome extension (not bundled in 1.1.2)

- OBSERVED: `APP/Contents/Resources/ClickyBrowserExtensionID.txt` contains one line, `bphdnlcghkpiaoiplkhfofpfboddahce`.
- OBSERVED: `MAIN` contains the store URL `https://chromewebstore.google.com/detail/heyclicky/bphdnlcghkpiaoiplkhfofpfboddahce`.
- OBSERVED: `MAIN` and `HOST` also look for `ClickyBrowserExtensionDevelopmentID.txt`, a second allowed ID for dev builds. It is absent from this bundle.
- OBSERVED: there is no extension code in the bundle. `MAIN` still references a resource name, `ClickyBrowserExtension`, and an older copy location, `~/Library/Application Support/Clicky/HeyClicky Chrome Extension`. It also references marker names `.heyclicky-contents` and `.heyclicky-extension-` (next to `manifest.json`). These belong to the earlier "preview copy" (unpacked extension) flow.
- OBSERVED: prompt strings call the old unpacked extension the "old preview copy" and say its ID starts with `pijeb`. That matches the old ID `pijeboofamochnneahbbehanombcfkkl`.
- Disk search (read-only):
  - No directory named `bphdnlcghkpiaoiplkhfofpfboddahce` or `pijeboofamochnneahbbehanombcfkkl` was found under `~/Library/Application Support` (depth 6).
  - Direct probes covered Chrome, Brave, Edge, Arc, Vivaldi and Chromium, each with profiles Default, Profile 1–10 and Guest Profile, under `Extensions`, `Local Extension Settings` and `Sync Extension Settings`.
  - The only hit was `~/Library/Application Support/Google/Chrome/Default/Local Extension Settings/pijeboofamochnneahbbehanombcfkkl`. That is the old preview copy's `chrome.storage.local` LevelDB. It is TCC-protected ("Operation not permitted") and was not read.
  - The old copy folder `DATA/HeyClicky Chrome Extension` does not exist. Spotlight finds no `ClickyBrowserExtension` or `.heyclicky-contents`.
  - Conclusion: **no copy of the extension's code, manifest or background logic exists on this Mac**, so its manifest and permissions are UNKNOWN.
- What the extension must do, INFERRED from the host protocol, the tool schema and the skill:
  - Runs as an MV3 service worker.
  - Calls `chrome.runtime.connectNative("com.heyclicky.browser")`. It sends `hello` first, keeps the port open, and reacts to `ready` and `command` messages.
  - Generates a per-profile UUID `profileId` and persists it. The lowercase UUID stored in the app's defaults, and the surviving `Local Extension Settings` folder, are consistent with `crypto.randomUUID()` plus `chrome.storage.local`.
  - Needs approximately these permissions: `nativeMessaging`, `tabs`, `tabGroups`, `scripting`, `storage`, `downloads`, `debugger`, and host access to all http(s) URLs.
    - `debugger` is likely needed for pixel input, keyboard input, page dialogs, file inputs without a picker, and screenshots of background tabs.
    - File upload depends on "Allow access to file URLs" being enabled for the extension. Troubleshooting text says Chrome refuses the file otherwise.
  - Owns everything page-level:
    - accessibility-style snapshots with `[ref]` handles, and diffs since the last look
    - `extract`, actions, `wait_for`, tab group management and the blue cursor overlay
    - the toolbar Stop button
    - its own error strings, listed in §2.9.4. These strings are absent from `MAIN`, which shows they come from the extension.

### 2.2 Native-messaging host manifests

- OBSERVED: `~/Library/Application Support/<browser dir>/NativeMessagingHosts/com.heyclicky.browser.json` exists for Google/Chrome, Chromium, BraveSoftware/Brave-Browser, Microsoft Edge, Arc/User Data and Vivaldi. All six are byte-identical, 303 bytes, written at app launch (22:20). None exist for Opera, Chrome Beta, Chrome Dev or Chrome Canary; the latter three browsers' folders do not exist on this Mac.
- Content (OBSERVED, non-secret). The manifest is Foundation `JSONSerialization` output: pretty-printed, with escaped slashes:
  - `name`: `com.heyclicky.browser`
  - `description`: `HeyClicky browser connection`
  - `type`: `stdio`
  - `path`: absolute path to `<installed app>/Contents/Helpers/ClickyBrowserHost`
  - `allowed_origins`: `["chrome-extension://bphdnlcghkpiaoiplkhfofpfboddahce/"]`
- Browser table (OBSERVED in `MAIN`, as an ordered literal triple per browser: display name, bundle ID, Application Support subpath):

| Display | Bundle ID | Support dir under `~/Library/Application Support/` |
|---|---|---|
| Chrome | com.google.Chrome | Google/Chrome |
| Edge | com.microsoft.edgemac | Microsoft Edge |
| Brave | com.brave.Browser | BraveSoftware/Brave-Browser |
| Arc | company.thebrowser.Browser | Arc/User Data |
| Vivaldi | com.vivaldi.Vivaldi | Vivaldi |
| Chrome Beta | com.google.Chrome.beta | Google/Chrome Beta |
| Chrome Dev | com.google.Chrome.dev | Google/Chrome Dev |
| Chrome Canary | com.google.Chrome.canary | Google/Chrome Canary |
| Chromium | org.chromium.Chromium | Chromium |

- INFERRED rule: at launch, and whenever setup runs, write or refresh the manifest for each browser whose support folder exists. Create `NativeMessagingHosts/` when missing. `allowed_origins` comes from the ID files.
- The installer refuses when the app isn't running from a real `.app` bundle. OBSERVED: an `app` extension check and the analytics key `has_bundled_helper`.
- Write failures surface as "HeyClicky couldn't set up the browser connection: …" or "Setup failed: …", plus a folder-ownership hint ("HeyClicky couldn't write to …'s folder. Check that you own it…").
- `MAIN` also reads each browser's `Local State` JSON at `profile.info_cache.*.active_time`. INFERRED: this counts profiles and picks the most recently active profile, for the setup UI and the analytics key `installed_chromium_browser_count`.
- `MAIN` contains the literals `a` and `p` next to the ID-file code, and links CryptoKit. INFERRED: it can derive a Chrome extension ID with Chrome's SHA-256-to-`a..p` mapping, probably for the dev/unpacked copy. Unverified; my test hashes of plausible unpacked paths did not reproduce `pijeb…`, so the old copy likely used a manifest `key`.
- OBSERVED: `APP/Contents/Resources/.clicky-browser-host-version` is a 64-hex stamp. It does not equal the SHA-256 of `HOST`, and `MAIN` does not reference it. INFERRED: a build-cache stamp. It can be ignored.

### 2.3 ClickyBrowserHost (native-messaging helper)

OBSERVED in `HOST`:
- 225 KB universal Mach-O (arm64 and x86_64).
- Hardened runtime, team `2UDAY4J48G`, no entitlements.
- Links only Foundation, CFNetwork and the Swift runtime.
- Single-file Swift program. The module name equals the arch name: symbols are `x86_64.request`, `arm64.ResponseBox`.

Globals:
- `base`: `~/Library/Application Support/Clicky/BrowserBridge`
- `input`: stdin handle
- `outputLock`: NSLock
- `session`: a fresh UUID string per host process
- `profile`: `String?`
- `origin`: argv[1], which Chrome passes as the caller origin
- `resources`: argv[0] minus two path components, plus `Resources`
- `configuredIDs`
- `browserBundleID`
- `started`: Bool

Functions:
- `readExactly(Int) -> Data?`
- `request(String, [String: Any]) -> [String: Any]?`
- `writeMessage([String: Any])`
- `openHeyClicky()`
- closure #2 (read ID file lines)
- closure #4 (find the browser's bundle ID)
- closure #6 (poll loop)

#### 2.3.1 Startup and origin check

1. Read `Resources/ClickyBrowserExtensionID.txt` and `Resources/ClickyBrowserExtensionDevelopmentID.txt`. A missing file contributes nothing. Split lines, trim whitespace and drop empties to get `configuredIDs`.
2. If `origin != "chrome-extension://" + id + "/"` for every configured ID, `exit(1)`. Only HeyClicky's own extension IDs can drive the host.
3. Compute `browserBundleID` by walking up to 4 ancestor processes, starting at `getppid()`:
   - Take each process's `proc_pidpath`.
   - Find the first path component ending in `.app` and read `NSBundle(path:).bundleIdentifier`.
   - If that fails, get the next parent PID with `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)`.
   - The default is the empty string.
   - INFERRED: this tells the app which browser (Chrome, Arc, Brave…) the extension runs in.

#### 2.3.2 Wire framing, extension to host (stdin)

- Each message is a 4-byte length (native byte order, little-endian on both archs) followed by UTF-8 JSON. This is the standard Chrome native-messaging framing.
- `exit(0)` on EOF or a short read of the length. Chrome closed the port.
- `exit(1)` on any of these:
  - length is not below 0x100000 (1 MiB)
  - the body read fails
  - the body isn't a JSON object
  - `type` is missing or not a string
- Responses go to stdout with the same framing. Writes are serialised by `outputLock` because the poll thread and the main thread both write.

#### 2.3.3 Message types the host accepts (extension to host)

| `type` | When | Host action |
|---|---|---|
| `hello` | Must be the first message | Requires `protocol == 1` (Int) and `profileId` (String that parses as a UUID); otherwise `exit(1)`. Stores `profile = profileId`, sets `started = true`, and starts the poll loop on a global queue. |
| `result` | After hello | `request("browser_reply", message)`. The whole message becomes the tool arguments. |
| `stop` | After hello | Same as `result`: forwarded through `browser_reply`. |
| `openApp` | After hello | `openHeyClicky()`. If the bundle path ends in `.app`, runs `/usr/bin/open -a <HeyClicky.app> heyclicky://settings/browser`; otherwise `/usr/bin/open heyclicky://settings/browser`. stdout and stderr go to `/dev/null`. |
| any other | After hello | Ignored. |
| anything other than `hello` | Before hello | `exit(1)`. |

#### 2.3.4 Message types the host emits (host to extension)

- `{"type":"ready","selected":<Bool>,"app":<Bool>}` after **every** poll attempt.
  - `app:false` means HeyClicky wasn't reachable: no `connection.json`, a bad port, a non-200 status or a timeout. In that case `selected` is false and the host sleeps 2.0 s before retrying.
  - `app:true` means HeyClicky answered. `selected` echoes the poll result.
  - INFERRED: this doubles as a heartbeat so the extension can show "HeyClicky not running" or "this profile isn't the selected one" UI.
- The `command` object from the poll result, written verbatim when present. Shape in §2.6.

#### 2.3.5 HTTP relay (`request`)

- Re-reads `base/connection.json` on **every** call, so it picks up a new port or token after the app restarts. Keys: `port` (Int, must be 1–65535) and `token` (String). Any failure makes `request` return nil.
- `POST http://127.0.0.1:<port>/mcp` with:
  - `timeoutInterval` 30 s
  - `Authorization: Bearer <token>`
  - `Content-Type: application/json`
  - an ephemeral `URLSession` with an empty `connectionProxyDictionary`, so system proxies are bypassed
- Body: `{"jsonrpc":"2.0","id":<new UUID string>,"method":"tools/call","params":{"name":<tool>,"arguments":<args>}}`.
- `args` always gains four keys:
  - `session`: this host process's UUID
  - `profile`: the hello `profileId`
  - `extension`: argv[1] origin
  - `browser`: the ancestor bundle ID
- Response: only HTTP 200 is accepted. The host parses JSON and returns `result.structuredContent` as a dictionary, or nil.
- The call is synchronous: a semaphore waits for the data task.

#### 2.3.6 Poll loop (closure #6)

```
loop forever:
  r = request("browser_poll", {})
  if r == nil:   write {type:ready, selected:false, app:false}; sleep 2 s; continue
  write {type:ready, selected: r.selected as? Bool ?? false, app:true}
  if let cmd = r.command as? [String:Any]: write cmd
  (immediately poll again; the server is expected to hold the request open)
```

### 2.4 `DATA/BrowserBridge/connection.json`

- OBSERVED: the folder is mode 0700 and the file mode 0600. The file is rewritten at app launch.
- Keys:
  - `port`: integer, the ephemeral loopback port of the host-transport MCP server
  - `token`: string, 64 characters. INFERRED: 32 random bytes in hex; `MAIN` has a `%02x` formatter next to the loopback server code.
- The value was not printed.
- The port differed from the agent endpoint port in `CodexHome/config.toml`, which was written by an earlier 1.1.1 launch. INFERRED: ports are ephemeral per launch, and the host and agent servers are separate listeners (see §2.8, fields `server` and `agentServer`).

### 2.5 Loopback HTTP and MCP server (generic)

OBSERVED type names in `MAIN`:
- `ClickyLoopbackHTTPServer`, with nested `Request`, `Response`, `ServerError`, `OnceFlag`
- `ClickyLoopbackMCPServer`, with nested `ToolDefinition`; source file `HeyClicky/ClickyLoopbackMCPServer.swift`
- `CodexLoopbackMCPEndpoint`

Imports `Network.NWListener` and `NWConnection`.

HTTP behaviour (OBSERVED literals, in order):
- Listens on `127.0.0.1` (log line "… up on 127.0.0.1:"). The port is ephemeral.
- Hand-rolled HTTP/1.1 parser: request line, headers matched lowercase (`content-length`, `authorization`), then the body.
- Exactly one response per connection. Headers: `Content-Type: application/json`, `Content-Length`, `Cache-Control: no-store`, `Connection: close`.
- Status reasons: `OK`, `Accepted`, `Bad Request`, `Unauthorized`, `Not Found`, `Method Not Allowed`.
- Only path `/mcp`. Any other path returns 404 `{"error":"not_found"}`.
- A missing or wrong `Authorization: Bearer <token>` returns 401 `{"error":"unauthorized"}`.
- Methods: `POST` carries JSON-RPC. `DELETE` is accepted (INFERRED: MCP session teardown). Anything else returns 405 `{"error":"method_not_allowed"}`.
- An `Mcp-Session-Id` header is handled.
- A queue label pattern `com.humansongs.clicky.<name>-mcp` exists (INFERRED).

JSON-RPC (MCP Streamable HTTP, JSON responses only, no SSE, OBSERVED):

| method | response |
|---|---|
| `initialize` | `result: {protocolVersion:"2025-03-26", capabilities:{tools:{}}, serverInfo:{name, version}}` |
| `ping` | `result: {}` |
| `tools/list` | `result: {tools:[{name, description, inputSchema}]}` |
| `tools/call` | Reads `params.name`, `params.arguments`, `params._meta`. Returns `result: {content:[{type:"text",text}…], structuredContent?, isError}`. |
| notifications (no `id`) | 202 Accepted (INFERRED from the `Accepted` status literal) |
| unknown method | `error: {code, message:"Method not found"}` |
| unknown tool | `error: {code, message:"Unknown tool"}` |
| bad JSON | `error: {code, message:"Parse error"}` |

- Numeric error codes are UNKNOWN. JSON-RPC standard codes (-32601, -32602, -32700) are the safe choice.
- Handlers return an internal dictionary with `is_error`, mapped to `isError`.
- Separately, the same HTTP server code serves a `GET /runtime/tool-policy` endpoint with Bearer auth for the harness's root tools (`shell_exec`, `file_read`, …). That is out of scope here.

### 2.6 Host-transport MCP server `clicky_browser_host`

- OBSERVED: the literal `clicky_browser_host` is loaded right before tool names `browser_poll` and `browser_reply`. INFERRED: it is this server's `serverInfo.name`.
- Both tools have the description "Private native host transport" and the input schema `{type:"object"}`.
- The port and token are published to `connection.json`.

`browser_poll` (OBSERVED keys `profile`, `session`, `extension`, `selected`, `command`, `browser`):
- Validates that `extension` is an allowed origin (`chrome-extension://<id>/`). It registers or refreshes the peer `(profile, session, browser)` in the fields `peerBrowsers` and `peerExtensions` and in the profile list.
- INFERRED: the call parks in `Pending {profile, session, continuation}` until a command for that profile is queued or a hold timeout passes. The hold must be under 30 s because the host gives up at 30 s.
- Returns `structuredContent: {selected: Bool, command?: {…}}`. `selected` is true when this profile is the one HeyClicky works in. Commands go only to the selected profile.
- The first status change sets "Chrome connected" and fires `extension_connected`.

`browser_reply` (OBSERVED keys `type`, `stop`, `extension`, `ok`, `id`, `result`, `closed`, `error`, "Browser command failed."):
- `type == "result"`: finds the in-flight command by `id`. On `ok:true` it resolves with `result`. Otherwise it fails with `error`, or with "Browser command failed." when `error` is missing. `closed` appears in replies to tidy or `end` commands. INFERRED: the count or list of tabs closed, which feeds `tabs_closed` and `tabs_closed_known`.
- `type == "stop"`: the user pressed Stop in the extension toolbar. The active turn's browser access ends. In-flight calls fail with "Browser access stopped. An in-flight action may already have completed; inspect before retrying." and analytics record `was_stopped_by_user`. Per the skill, tabs then become the user's and are not auto-closed.
- Returns a small `structuredContent`, probably `{ok:true}`. The host ignores it.

Command envelope sent through `browser_poll.command` (OBSERVED key sequences; exact nesting INFERRED):

| purpose | keys |
|---|---|
| tool operation | `type:"command"`, `id` (UUID), `operation`, `task` (job or thread key), `owner` (which Clicky owns the work; the extension refuses tabs owned by another), `groupTitle` (emoji + title), `say` (progress line), `cursorColor` (hex, from the Clicky's `overlayCursorColorHex`, default `#3380FF`), plus the tool arguments (`tabId`, `url`, `ref`, `text`, `steps`, …) |
| end of turn or abort | `type:"command"`, `id`, `operation:"end"`, `task`, `owner`, `tidy` (Bool) |
| orphan cleanup | `type:"command"`, `id`, `operation:"sweep"`, `running` (list of task keys still alive) |

INFERRED: `sweep` goes out when a profile (re)connects, so the extension can fold or close groups left by jobs that no longer exist.

### 2.7 Agent MCP endpoint `clicky_browser`

OBSERVED in `DATA/CodexHome/config.toml` (non-secret lines):
```
[mcp_servers.clicky_browser]
url = "http://127.0.0.1:<ephemeral>/mcp"
bearer_token_env_var = "CLICKY_BROWSER_MCP_TOKEN"
startup_timeout_sec = 20.0
tool_timeout_sec = 900.0
[[skills.config]]
path = ".../CodexHome/skills/clicky-browser"
enabled = true
```
- The config template literals are in `MAIN`.
- INFERRED: the config is rewritten for each Codex launch (the port changes). The token is injected only through the Codex process environment, never into the TOML.
- OBSERVED in `DATA/AgentHarness/h1-local/*/steps.jsonl` (clicky-harness job config): `cfg.mcp[] = {name:"clicky_browser", url, token, meta:{"x-codex-turn-metadata":{thread_id, turn_id}}, optional:true}`. Its `tools/list` returned two tools on that server: `browser` and `mac_step`.
- `MAIN` also defines `find_jobs` and `read_job` (read-only job search) in the same tool-definition block. INFERRED: they are conditionally listed on the same endpoint. They belong to another doc.
- Turn binding (OBSERVED keys `x-codex-turn-metadata`, `thread_id`, `threadId`, `turn_id`): `tools/call` carries `params._meta["x-codex-turn-metadata"]`. The bridge maps that to the active HeyClicky job turn (`agentTurnLookup`). With no active turn it returns "Browser tool is unavailable outside its active agent turn." An unknown tool returns "Unknown tool.".
- Result formats (OBSERVED):
  - MCP: `content` is `[{type:"text", text}]`, plus `{type:"image", data:<base64>, mimeType:"image/jpeg"}` for screenshots. Also `isError`.
  - A second encoder emits `{contentItems:[{type:"inputText", text}, {type:"inputImage", imageUrl:"data:image/jpeg;base64,…"}], success}`. INFERRED: the same `perform` path also serves Codex app-server "dynamic tool" calls.
- Main entry point (OBSERVED symbol string): `perform(arguments:thread:turn:title:groupTitle:progressLine:isActive:)`.

### 2.8 ClickyBrowserBridge (app-side coordinator)

OBSERVED: class `ClickyBrowserBridge` in `HeyClicky/ClickyBrowserBridge.swift`.

Reflected fields:
- state: `_status`, `_profiles`, `_selectedProfile`, `_activeCount`, `_isEnabled`, `_isConnected`, `_isAwaitingExtension`, `_setupFailureMessage`, `_hasEverConnected`, `_setupBrowserName`, `_hasOldCopyToRemove`
- callbacks: `onExtensionConnected`, `onConnectionChanged`, `onSetupFailed`
- servers and tasks: `server`, `startTask`, `monitorTask`
- peers and commands: `peerBrowsers`, `peerExtensions`, `commands`
- permission state: `grants`, `denied`, `prompting`
- `generation`, `pending`
- per-turn usage and tidying: `turnBrowserUsage`, `turnUsageAwaitingTidy`, `tidyCommandTurns`, `tidyRepliesAwaited`, `turnsReportedChromeUnavailable`
- connection timing: `connectedAt`, `lastDisconnectWasExtensionGoingQuiet`, `setupStartedAt`
- dependencies and hooks: `directory`, `preferences`, `customApprove`, `macStepHandler`, `workHandler`, `onAgentNeedsChromeConnection`, `agentServer`, `agentTurnLookup`

Nested types:
- `Pending {profile, session, continuation}`
- `TurnBrowserUsage {thread, firstCallAt, operationCount, operationCounts, batchStepCount, commandsSentToBrowser, errorCount, timeoutCount, tabsKept, screenshotsSaved, wasStoppedByUser, accessEndedByTimeout, endedAt}`
- `ClickyBrowserNativeHostSetupError`

UserDefaults (OBSERVED keys; values seen on this Mac):
- `clicky.browserConnection.enabled.v1`: Bool, 1
- `clicky.browserConnection.hasConnected.v1`: Bool, 1
- `clicky.browserConnection.lastBrowser.v1`: String; absent here
- `clicky.browserConnection.oldCopyToRemove.v1`: Bool, 0
- `clicky.browserConnection.profile.v1`: String, a lowercase UUID. This is the selected `profileId`.

Status strings (OBSERVED): `Not set up`, `Not connected`, `Waiting for Chrome`, `Chrome connected`. The Settings badge shows `Off`, `Waiting`, `Setup failed` or `Connected`.

Turn-scoped behaviour (OBSERVED strings and analytics; ordering INFERRED):
- A turn's first call records `firstCallAt`. Each call increments `operationCount` and `operationCounts[op]`.
- When the turn ends, the bridge sends `end` with `tidy:true`. The extension closes every tab the agent opened that wasn't `keep`-ed, returns the user's own tabs to their place, and folds the group. Analytics: `tabs_closed`, `tabs_closed_known`.
- A tool call that arrives after the turn ended fails with "The agent turn ended.".
- A connection generation change mid-turn fails with "Browser connection changed. Start a new turn.". Per the skill text, this happens when Chrome reconnects.
- Per-turn permission plumbing exists: `grants`, `denied`, `prompting`, `customApprove`. Errors: "Another browser permission request is open. Wait for it to finish." and "Browser permission was declined or the turn ended.". The 1.1.2 tool description and skill say connecting the extension is the permission. INFERRED: the gate is an injectable hook that defaults to allow and is reserved for non-interactive or other contexts. There is also "Browser access is unavailable for this turn.".

### 2.9 The `browser` tool (agent-facing)

#### 2.9.1 Input schema

Exact JSON Schema, OBSERVED from the `tools/list` result recorded by clicky-harness and matching `MAIN` literals:

- top level: `type: object`, `additionalProperties: false`, `required: ["operation"]`
- `operation`, enum (23 values): `status`, `tabs`, `open`, `snapshot`, `extract`, `batch`, `click`, `fill`, `press`, `scroll`, `wait_for`, `back`, `upload`, `download`, `close`, `keep`, `dialog`, `screenshot`, `click_at`, `hover_at`, `drag_at`, `type`, `javascript`
- `tabId`: integer
- `url`, `ref`, `text`, `query`, `code`: string
- `key`, enum: `Enter`, `Tab`, `Escape`, `ArrowDown`, `ArrowUp`, `ArrowLeft`, `ArrowRight`, `Backspace`, `Delete`, `PageDown`, `PageUp`, `Home`, `End`
- `direction`, enum: `up`, `down`
- `dismiss`, `gone`, `accept`, `save`: boolean
- `timeout`, `x`, `y`, `toX`, `toY`: number
- `paths`: array of string
- `why`, enum: `result`, `waiting`
- `steps`: array of objects with `additionalProperties:false` and `required:["operation"]`
  - step `operation` enum: `open`, `click`, `fill`, `press`, `scroll`, `wait_for`, `back`, `upload`
  - step fields: `text`, `ref`, `url`, `direction`, `gone`, `timeout`, `x`, `y`, `toX`, `toY`, `paths`, `key`, `dismiss`, `code`

#### 2.9.2 Operation semantics

Paraphrased from the tool description in `MAIN` and the skill:

| op | args | behaviour |
|---|---|---|
| `status` | none | Returns `{enabled, connected, chromium_browsers, setup}`. `setup` is a guidance line. It is never required before other calls. |
| `tabs` | none | Lists the user's tabs (id, title, URL). `current:true` marks the focused one. |
| `open` | `url` [, `tabId`] | Without `tabId`: creates a background tab next to the user's tab, inside this task's tab group. Uses a separate unfocused window if the front window can't hold groups. With `tabId`: navigates that tab. Returns the tab ID and a full snapshot. |
| `snapshot` | `tabId` [, `query`] | One element per line, formatted `role: name [ref]`. On-screen elements come first when the page is large. `query` filters by name. |
| `extract` | `tabId` | Page text and tables only, with no refs. Cheaper than a snapshot. |
| `click` / `fill` / `press` / `scroll` / `back` | `tabId` + `ref` / `ref,text` / `key` / `direction` / none | Once the page goes quiet, returns a diff of elements added and removed. Refs remain usable until the tab navigates. `fill` handles text fields, rich editors and `<select>` (by visible option text). `dismiss:true` retries a blocked click after closing the blocking layer (Escape, then a close or decline button). |
| `wait_for` | `text` or `url` [, `gone`, `timeout` s] | Waits for text or a URL to appear, or disappear with `gone`. |
| `batch` | `tabId`?, `steps` (≤20) | Runs the steps in order and stops at the first failure. Returns one diff at the end. It may start with `open` when there is no `tabId`. |
| `upload` | `tabId, ref, paths` | 1–10 absolute paths, ≤100 MB each. Validated by the app (§2.10). Works as a batch step. |
| `download` | `url` or `tabId+ref` | Saves http(s) files to `~/Downloads/HeyClicky/<task>/`. Returns `path`, `bytes`, `mime`, or `state:"in_progress"`. Click-triggered downloads come back as `downloads` in later results. |
| `dialog` | `accept` [, `text`] | Answers an alert, confirm or prompt. |
| `close` | `tabId` | Only tabs this Clicky opened. |
| `keep` | `tabId, why` | Keeps a tab past the end of the turn. `why` is `result` or `waiting`. Lasts one turn. |
| `screenshot` | `tabId` [, `save`] | JPEG. `save:true` writes it to the job's `output/` folder (§2.11). |
| `click_at` / `hover_at` / `drag_at` / `type` | pixel coordinates from the last screenshot; `toX,toY`; `text` | Fallback for canvas or custom controls. `type` types into the focused element. |
| `javascript` | `tabId, code` | Runs `code` as the body of an async function and returns a JSON value of at most 20,000 characters. Counts as acting on the page. |

Read-only and stall-safe class (OBSERVED literal list in `MAIN`): `status`, `tabs`, `snapshot`, `extract`, `screenshot`, `wait_for`, `keep`, a `batch` made only of `wait_for` steps, and `download`. INFERRED purpose:
- A timeout on a read-only op returns "The page didn't answer in time. Nothing was changed…" (retryable).
- A timeout on an acting op returns "Browser action timed out. Its outcome is unknown. Do not repeat it…" and access for that turn ends (`access_ended_by_timeout`).
- Both timeout paths send an `end` command (`id`, `operation:"end"`, `task`, `owner`) to the extension.
- Acting on the user's own tab pulls it into the task group. Reads do not.

#### 2.9.3 Dynamic tool description variants

OBSERVED: the description text changes with state:
- (a) connected: the normal description
- (b) Chrome not connected, but some Chromium browser exists on the Mac: site work is deferred; the agent finishes whatever else it can and closes its turn with a brief note that the remaining steps need Chrome
- (c) the user chose to continue without Chrome: use `mac_step` for signed-in sites
- (d) no Chromium browser on this Mac: use web search, and either `mac_step` or numbered manual steps, depending on whether `mac_step` is available

`onAgentNeedsChromeConnection` and analytics `agent_found_chrome_unavailable` (reasons `no_chromium_browser`, `user_chose_without_chrome`, `not_connected`; flag `via_status`) record these cases.

#### 2.9.4 Error catalogue

Errors from the app, all OBSERVED in `MAIN`:
- "Unsupported browser operation."
- "Chrome isn't connected. " followed by guidance
- "Browser access is unavailable for this turn."
- "Browser connection changed. Start a new turn."
- "Browser tool is unavailable outside its active agent turn."
- "Another browser permission request is open. Wait for it to finish."
- "Browser permission was declined or the turn ended."
- "Browser action timed out…"
- "The page didn't answer in time…"
- "Browser access stopped. An in-flight action may already have completed…"
- "The agent turn ended."
- upload-path errors (§2.10)
- "Not saved: only a job's screenshots are kept in its folder."
- batch "Step N … Nothing ran."

Errors from the extension (absent from `MAIN`; listed in the skill's troubleshooting reference):
- stale or unknown refs, and the page changed
- element obscured, off-screen, not visible or not clickable
- password, verification-code and payment fields are refused
- fill limit of 20,000 characters
- no matching option
- file chooser errors
- only http(s) pages without URL credentials
- private browsing unsupported
- screenshot exceeds the transport limit
- `wait_for` timeouts
- tab owned by another Clicky
- batch ran out of time

INFERRED: the screenshot limit exists because the host `exit(1)`s on messages of 1 MiB or more and Chrome caps host-bound messages. A rebuild must keep extension-to-host messages under 1 MiB.

### 2.10 Upload path guard

OBSERVED in `MAIN`; enforced by the app before forwarding:
- 1–10 paths. Each must be absolute (`~/` is expanded), exist, be a regular file and be ≤100 MB.
- Refused locations:
  - home-relative: `.ssh`, `.gnupg`, `.aws`, `.azure`, `.kube`, `.docker`, `.config/gcloud`, `.config/gh`, `.codex`, `Library/Keychains`, `Library/Cookies`, `Library/Safari`
  - `Library/Application Support/{Google, Chromium, BraveSoftware, Microsoft Edge, Arc, Vivaldi, Firefox, Clicky, HeyClicky}`, except `…/Clicky/projects` and `…/HeyClicky/projects`, which are allowed
  - `/Library/Keychains/`
  - extensions `.env`, `.pem`, `.key`
  - file names `.netrc`, `.git-credentials`, `.npmrc`, `.pypirc`, `.pgpass`
- Error texts: "upload needs paths: 1 to N absolute file paths.", "No file at …", "… is not a regular file; upload takes files.", "HeyClicky can't read …", "… is larger than 100 MB.", and a refusal for files under a protected location (credential stores, keychains, browser profiles, app settings).
- The same validation runs for `upload` steps inside `batch`. A failure there returns "Step N: … Nothing ran.".

### 2.11 Screenshot persistence

- OBSERVED literals `url`, `page`, `www.`, `.`, `-`, `yyyy-MM-dd-HHmmss`, `output`, `.jpg`, `saved`, `note`.
- With `save:true` the app writes `<job folder>/output/<host-slug>-<yyyy-MM-dd-HHmmss>.jpg`. The slug is the page host with a leading `www.` dropped and dots replaced by `-`. The file path comes back as `saved`.
- If the turn has no job folder, the result carries `note`: "Not saved: only a job's screenshots are kept in its folder.".
- The image itself is returned inline as image content (§2.7).

### 2.12 Tab-group title heuristics

OBSERVED: a keyword-to-emoji table in `MAIN`.
- `🔎` is the default.
- 🛒 shopping, cart, orders, amazon, grocery
- ✈️ flights, trips, hotels, airbnb
- 🎟️ tickets, concerts, shows
- 📧 email, inbox, gmail
- 📅 calendar, meetings, events
- 💰 prices, bills, invoices, refund
- 💬 discord, slack, messages, posts, social sites
- 🎵 music, spotify
- 🎬 video, youtube, tiktok
- 💻 code, github, deploy, website
- 📰 news, articles, blog
- 📄 docs, forms, sheets, reports, applications
- 🍽️ restaurants, recipes, reservations
- 🏠 apartments, rent, listings

The group title is `<emoji> <task title>`, for example "🛒 Weekly groceries", and is sent as `groupTitle`.

### 2.13 Setup, connection and voice-brain flows

Settings UI (OBSERVED: `HomeSpaceBrowserConnectionSettings`, `HomeSpaceBrowserStatusBadge`, `HomeSpaceBrowserIcon`, source `HeyClicky/HomeSpaceBrowserConnectionSettings.swift`):
- Lives under Settings → Integrations → Chrome. The setup page names this path.
- Header line: works with Chrome, Edge, Brave, Arc and other Chromium browsers.
- Status badge.
- Profile picker when several profiles are connected ("The profile HeyClicky works in."). Analytics: `profile_count`, `profile_index`, `settings_profile_changed`.
- Disconnect, with a confirmation. Analytics: `settings_disconnect_asked`, `settings_disconnect_cancelled`.
- A live line while a job uses the browser.
- A "new version" banner when the old preview copy must be swapped.
- The setup button offers `do_it_for_me` or `show_me_how`. Analytics: `settings_setup_pressed`, `settings_setup_stopped`.

Setup action (OBSERVED analytics `setup_started` with `opened_page` = `store_listing` | `setup_guide` | `none`, plus `preferred_browser`, `installed_chromium_browser_count`, `was_connected_before`, `reconnected_without_steps`, `has_old_copy_to_remove`, `left_to_drive`):
1. Install or refresh the native-host manifests (§2.2).
2. If no Chromium browser is installed, open `Resources/ClickyBrowserSetup.html` as a `file://` page. That is a static dark page titled "HeyClicky works in Chrome" with browser chips and a "Get Chrome" link to google.com/chrome.
3. Otherwise open the Web Store listing in the preferred browser and set `_isAwaitingExtension` ("Waiting for Chrome").
4. The first `hello` followed by a `browser_poll` from an allowed origin sets "Chrome connected" and fires `extension_connected` (`is_first_connection_ever`, `was_awaiting_setup`, `connected_profile_count`, `seconds_since_setup_started`).
5. A disconnect is detected when the extension stops polling (`stopped_answering`, `extension_disconnected` with `seconds_connected`).

Old-copy migration (OBSERVED): `preview_copy_folder_removed` and `preview_copy_folder_remove_failed`, `old_copy_pretended`, the `oldCopyToRemove` default, and `chrome://extensions/`, `brave://extensions/`, `edge://extensions/`. HeyClicky deletes its old unpacked folder. It then either drives, or coaches the user through, removing the old `pijeb…` card and adding the Web Store extension.

Voice-brain integration (OBSERVED keys; the prompts are long and are only paraphrased here):
- The brain's context gets a `Browser: …` line. Variants: connected, not connected (with the extension available in the Web Store), needs swapping, or no Chromium browser.
- When a job would have to operate inside the user's signed-in account on a website that none of their connected apps handles, the brain asks for permission a single time before launching it. It then calls `sessions_spawn` with `chrome: "ask"`; the job waits for the choice and starts itself once Chrome connects. With `chrome: "without"`, the job does website steps through `mac_step`.
- The user's answer goes through `sessions_answer_request` with request `chrome_setup`:
  - `approve`: HeyClicky drives the install on screen
  - `show_how`: coach mode with click targets
  - `decline`
- Card choices: Connect Chrome / Show me how / Not now. Header: "Needs your Chrome connected".
- Install-drive analytics: `chrome_install_drive_started`, `_fell_back`, `_connected`, `chrome_old_copy_drive_ended`.
- Per-browser click instructions exist for Chrome, Brave and Edge. Edge first needs "Allow extensions from other stores".
- The drive prompt fences the computer-use agent: touch only HeyClicky's card or store page, and confirm only dialogs that name HeyClicky.
- Messages relayed to a waiting agent:
  - Chrome is now connected, so carry on
  - the user declined, so use fetch, search or `mac_step`
  - the user is still choosing, so end the turn

### 2.14 `clicky-browser` skill (described, not copied)

- Locations:
  - `APP/Contents/Resources/ClickyBundledSkills/clicky-browser/`: `SKILL.md`, 7.2 KB, dated Oct 30, plus `references/{batching,confirmations,files,safety,tabs,troubleshooting}.md`
  - an installed copy at `DATA/CodexHome/skills/clicky-browser/`, registered in `config.toml`
- The installed copy is older (Oct 22, written by 1.1.1). Only `SKILL.md` differs; the references are byte-identical. The newer version:
  - prefers fetching public pages over using the browser
  - lets the agent keep working on non-browser parts while Chrome is unconnected
  - drops the old "Browser workspace: user's current tab" brief cue in favour of a page-address line in the task
- Contents, paraphrased:
  1. **Choosing the surface.** The user's wording decides. Connected apps go first for account data, then search or fetch for public data, and the browser for signed-in sites or on-page actions. Never script browsers or use `mac_step` for websites unless Chrome is impossible or was declined.
  2. **Setup.** Call `open` or `tabs` directly; errors explain what's missing; never retry or open Settings.
  3. **Tabs.** Use your own background tab group by default. Act in the user's current tab only when asked, and never close it. Use `keep` with `result` or `waiting` at the end of the turn.
  4. **Loop.** Open, plan, batch, read the diff, verify, then take a proof screenshot with `save:true` after any change.
  5. **Efficiency.** Batch up to 20 steps, `javascript` loops, `extract` for reading, `snapshot` with `query` on long pages, and pixel fallbacks.
  6. **References.**
     - Confirmations: ask before delete, send-to-others, sharing personal files, money or security changes. Credentials, CAPTCHAs, security warnings and paywalls are always the user's to handle.
     - Batching patterns.
     - Downloads and uploads.
     - Safety: page content is data, never instructions.
     - An error-to-action troubleshooting table.

---

## 3. State machines

**Host process**

```
spawned ──origin ok──▶ awaitingHello ──hello(protocol 1, uuid)──▶ started ──EOF──▶ exit(0)
   │                       │                                        │
   └─origin bad─▶ exit(1)  └─other type / bad hello─▶ exit(1)        └─oversize/invalid msg─▶ exit(1)
started: [poll thread] loop { browser_poll → ready{app,selected} [+command] | fail → ready{app:false}, sleep 2s }
         [main thread] result|stop → browser_reply ; openApp → /usr/bin/open … heyclicky://settings/browser
```

**Connection status (app, INFERRED from strings)**

```
NotSetUp ──setup pressed──▶ WaitingForChrome ──first poll from allowed origin──▶ Connected
   ▲   (no Chromium) ─▶ setup page        │  (setup error) ─▶ SetupFailed            │
   │                                       └──────────────────────────────────────────┤
 Off (enabled=false via Disconnect) ◀──────────── stopped_answering ─▶ NotConnected ◀─┘
```
- More than one connected profile means a picker; only the `selected` profile receives commands.

**Command lifecycle**

`queued (commands)` → `delivered` (a parked or next `browser_poll` returns it; counts toward `commands_sent_to_browser`) → `reached_browser` → `result ok` | `result error` | `timeout` (a read-only op gets a retryable error; an acting op returns "outcome unknown" and access for the turn ends; both send `end`) | `stop` (user) | `generation changed` | `turn ended`.

**Turn lifecycle**

1. The first browser call opens a `TurnBrowserUsage`.
2. Each call increments the counters.
3. At turn end, send `end{tidy:true}`, wait for the tidy reply (`tidyRepliesAwaited`), then emit `turn_used_browser` with:
   - `operation_count`
   - `op_<name>` per operation
   - `batch_step_count`
   - `commands_sent_to_browser`
   - `reached_browser`
   - `error_count`
   - `timeout_count`
   - `tabs_kept`
   - `screenshots_saved`
   - `was_stopped_by_user`
   - `access_ended_by_timeout`
   - `browser_seconds`
   - `tabs_closed`
   - `tabs_closed_known`

---

## 4. Timing

| Item | Value | Status |
|---|---|---|
| Host HTTP request timeout | 30 s (`URLRequest(timeoutInterval: 30)`) | OBSERVED |
| Host retry delay when the app is unreachable | 2.0 s (`Thread.sleep`) | OBSERVED |
| Host poll cadence | immediately after each response; long-poll | OBSERVED / INFERRED |
| Server poll hold | under 30 s, likely about 20–25 s | INFERRED / UNKNOWN |
| Liveness window | constant 35.0 compared with elapsed seconds near connection-status code | INFERRED: the extension counts as gone when it hasn't polled for 35 s |
| Codex MCP startup / tool timeout | 20 s / 900 s | OBSERVED (`config.toml`) |
| Batch length | 20 steps | OBSERVED (description) |
| `javascript` return / `fill` text | 20,000 characters each | OBSERVED (description / skill) |
| Native message cap (extension to host) | under 1 MiB, or the host exits | OBSERVED |
| Upload | ≤10 files, ≤100 MB each | OBSERVED |
| Per-command action timeout | UNKNOWN | — |

---

## 5. Security model (what to preserve)

- **Host gate.** Chrome's `allowed_origins`, plus the host's own argv[1] check against the bundled ID list.
- **Loopback auth.**
  - 127.0.0.1 only.
  - A random 32-byte hex bearer per launch, stored in a 0600 file inside a 0700 folder for the host, and passed by environment variable to Codex.
  - Proxies are disabled in the host.
  - `Cache-Control: no-store` and one request per connection.
- **Origin re-check.** The `extension` argument is re-checked by the app, so a local process holding the token still needs a valid origin string. That is weak. INFERRED: the bearer is the real gate.
- **Turn binding.** Agent calls only work inside an active, known Codex thread or turn (`x-codex-turn-metadata`). Commands carry `task` and `owner`, and the extension enforces tab ownership across concurrent Clickys.
- **Sensitive input refusal.** Done in the extension: passwords, OTP and payment fields. The app guards uploads against private paths.
- **Stop.** Any Stop press ends access for the turn.

---

## 6. Permissions and entitlements

- **`MAIN`.**
  - OBSERVED: `com.apple.security.app-sandbox = false`, `network.client`, `audio-input`, `camera`, `allow-jit`, and a mach-lookup exception for `com.apple.screencapturekit.picker`.
  - It needs no sandbox to write `~/Library/Application Support/<browser>/NativeMessagingHosts/` and to bind NWListener on loopback.
  - URL schemes: `clicky` and `heyclicky`, used by the host's `heyclicky://settings/browser`.
  - The app is `LSUIElement`.
- **`HOST`.** No entitlements and hardened runtime. It must stay inside the signed app bundle, because the manifest `path` points there. The manifest needs refreshing if the app moves (INFERRED).
- **TCC.** None for the bridge itself. Browser profile folders are TCC-protected, which is why the app reads only `Local State` and never extension storage.
- **Extension.** See §2.1. The user must enable "Allow access to file URLs" for uploads.

---

## 7. Edge cases the code clearly handles

- The app is not running: the host reports `app:false` and the extension can send `openApp`.
- The app restarted with a new port or token: the host re-reads `connection.json` on every request.
- Several Chromium browsers or profiles: there are per-profile peers, a selected profile, `selected:false` for the rest, and a profile picker.
- No Chromium browser at all: the setup HTML page is shown, the tool description changes, and the agent falls back to `mac_step` or manual instructions.
- The app was moved or translocated: the manifest path is derived from the bundle, and setup can fail with `has_bundled_helper`.
- An old unpacked preview copy is present: the folder is removed, a swap UI and swap drive follow, and the `oldCopyToRemove` default is set.
- The user's tab: reads don't move it; acting moves it into the group; it is never closed and returns to its place at the end.
- The front window can't host a tab group: a separate unfocused window is used.
- A sleeping background tab stalls a read: the retryable error suggests opening the same URL in the agent's own tab.
- A timeout on a mutating action: "outcome unknown", no automatic retry, and access ends.
- Concurrent Clickys: `owner` is sent per command; foreign tabs are refused; concurrent permission prompts are refused.
- The turn ended or the connection generation changed: in-flight calls fail with explicit messages.
- Oversized messages: the host exits on 1 MiB or more, and the extension downgrades screenshots ("Use snapshot").

---

## 8. Slot mapping

- The bridge itself uses **no model**. It is purely local and needs no HeyClicky server route.
- Its caller is the **agent** slot: Codex CLI with `gpt-6-luna` via `api.heyclicky.com/agent/openai/v1`, or clicky-harness. The agent needs:
  - MCP client support for Streamable HTTP with a bearer from an env var
  - the ability to pass `_meta` turn metadata
  - image (JPEG) tool-result support
  - long tool timeouts (900 s)
  - skill loading
- The **brain** slot (the realtime voice brain) decides when to ask about Chrome and calls `sessions_spawn` / `sessions_answer_request`. It also runs the "do it for me" screen drive that installs the extension, which needs computer-use tools, image input and tool calling.
- Analytics go to PostHog (other: analytics).

---

## 9. Rebuild plan (OpenClicky)

Swift, in the app:
1. `LoopbackHTTPServer`
   - NWListener on 127.0.0.1, port 0
   - minimal HTTP/1.1 parsing with Content-Length and one response per connection
   - 401, 404 and 405 JSON errors
   - constant-time bearer comparison
2. `LoopbackMCPServer` (on top of 1)
   - JSON-RPC methods: `initialize` (protocol `2025-03-26`, or negotiate), `ping`, `tools/list`, `tools/call`
   - 202 for notifications
   - `ToolDefinition { name, description, inputSchema, handler(arguments, meta) async -> ToolResult }`
   - `ToolResult` encodes as MCP `content` + `structuredContent` + `isError`
3. `BrowserBridgeCredentials`
   - generates a 32-byte hex token per launch
   - writes `~/Library/Application Support/OpenClicky/BrowserBridge/connection.json` (`{port, token}`) atomically with 0600 permissions in a 0700 folder
4. `NativeHostInstaller`
   - the browser table in §2.2, with our own host name (for example `com.openclicky.browser`)
   - writes manifests for each existing browser support folder at launch and on setup
   - `allowed_origins` comes from `ExtensionID.txt` (+ `ExtensionDevelopmentID.txt`)
   - reports per-browser failures
5. `BrowserHostTransport` (MCP server `…_browser_host`): tools `browser_poll` (long-poll with a continuation and an approximately 20 s hold) and `browser_reply`; validates origin and profile UUID.
6. `BrowserBridge` (coordinator, `@MainActor` / actor)
   - status enum, profiles and selection, peer liveness (35 s window)
   - command queue with UUID IDs and per-command continuations and timeouts
   - generation counter
   - `sweep` on connect, `end{tidy}` at turn end
   - Stop handling and per-turn usage counters
   - persists `enabled`, `hasConnected` and `selectedProfile` in UserDefaults
7. `AgentBrowserTool`
   - the `browser` tool schema in §2.9.1
   - state-dependent descriptions (§2.9.3)
   - read-only classification and timeout policy
   - group-title emoji heuristic (§2.12)
   - screenshot saving (§2.11)
   - `UploadPathGuard` (§2.10)
   - turn binding via `_meta["x-codex-turn-metadata"]`
8. `AgentMCPEndpoint`
   - writes `[mcp_servers.<name>]` (url, `bearer_token_env_var`, timeouts) into the agent's config
   - injects the token env var when spawning the agent
   - installs the `browser` skill (our own text) into the agent's skills folder
9. `BrowserConnectionSettingsView`: status badge, profile picker, disconnect, setup buttons, and a no-Chromium fallback page.
10. Brain hooks: a `Browser:` context line, `chrome: ask | without` on job spawn, `chrome_setup` answer routing, and events back to waiting jobs.

Native host (separate Swift CLI target, embedded in `Contents/Helpers/`):
- Behaves exactly as §2.3:
  - origin check
  - `hello` gate
  - 1 MiB cap
  - poll thread with `ready` heartbeats
  - result/stop relay
  - `openApp` through `/usr/bin/open -a <app> <scheme>://settings/browser`
  - parent-browser bundle-ID detection
  - re-reading `connection.json` on every request
  - proxies disabled
- Keep it Foundation-only and small, so a review stays easy.

Chrome extension (new, MV3, our own code):
- `background.js`
  - native port management with reconnect/backoff
  - a `profileId` in `chrome.storage.local`
  - the `ready` and `command` dispatcher
  - tab-group manager (title, colour, collapse, unfocused-window fallback)
  - tab ownership per `task` and `owner`
  - `end`/tidy and `sweep`
  - toolbar Stop that sends `{type:"stop"}`
  - an "Open OpenClicky" action that sends `{type:"openApp"}`
- `snapshot.js` (content script)
  - accessibility-style tree serialisation as `role: name [ref]`
  - viewport-first ordering and `query` filter
  - ref registry invalidated on navigation
  - diffs since the last look
  - `extract` for text and tables
- `actions.js`: click/fill/press/scroll/back/wait_for, obscurer detection with `dismiss`, select-by-text, rich-editor fill verification, and refusal of sensitive fields.
- `cdp.js` (`chrome.debugger`): pixel click, hover and drag, `type`, dialogs, `DOM.setFileInputFiles`, background-tab screenshots (JPEG, quality reduced until the message is under 1 MiB), downloads tracking.
- `cursor.js`: overlay cursor in `cursorColor`.
- The manifest has an explicit `key` for a stable ID during development, and the ID goes into `ExtensionDevelopmentID.txt`.

Tests:
- Host framing and gate unit tests (fixtures for hello, oversize and bad origin).
- MCP conformance against Codex's client (initialize, tools/list, tools/call with `_meta`).
- An end-to-end test with a stub extension driving `browser_poll` and `browser_reply`.
- Upload-guard table tests.

---

## 10. Unknowns and open questions

- The real extension's code, `manifest.json`, permissions, snapshot format, diff algorithm and per-operation timeouts are UNKNOWN. It is not on disk, and its Chrome storage is TCC-protected.
- The exact JSON shapes inside `result` for each operation are UNKNOWN: tab IDs, snapshot text, `downloads`, `closed`.
- The server-side long-poll hold time and the per-command timeout are UNKNOWN.
- Whether the host and agent endpoints share one listener is unresolved. Evidence points to two (`server` versus `agentServer`).
- Numeric JSON-RPC error codes and the `serverInfo.version` value are UNKNOWN.
- When `find_jobs` and `read_job` are listed on the `clicky_browser` endpoint is UNKNOWN; this harness run showed only `browser` and `mac_step`.
- When the per-turn permission gate (`customApprove`, `grants`, `denied`) is active is UNKNOWN.
- The meaning of the `.clicky-browser-host-version` stamp is UNKNOWN.

## Appendix: evidence index

- `HOST`
  - decompiled `entry`, `request`, `writeMessage`, `readExactly`, `openHeyClicky`, closures #2, #4 and #6, and the completion closure
  - x86_64 disassembly 0x1000013e0–0x100002130 for the dispatch on `type`
  - strings: `browser_poll`, `structuredContent`, `heyclicky://settings/browser`, `http://127.0.0.1:`, `ClickyBrowserExtension(Development)ID.txt`
- `MAIN` strings and ordered literals (x86_64 0x101e70000–0x101ed0000 and 0x101f8a000–0x101fa4000):
  - type names: `ClickyBrowserBridge`, `ClickyLoopbackMCPServer`, `ClickyLoopbackHTTPServer`, `CodexLoopbackMCPEndpoint`
  - tool and schema literals; analytics keys
  - `perform(arguments:thread:turn:title:groupTitle:progressLine:isActive:)`
- `APP/Contents/Resources`: `ClickyBrowserExtensionID.txt`, `ClickyBrowserSetup.html`, `.clicky-browser-host-version`, `ClickyBundledSkills/clicky-browser/**`
- `DATA`
  - `BrowserBridge/connection.json` (keys `port`, `token` only)
  - `CodexHome/config.toml` (`mcp_servers.clicky_browser`, `skills.config`)
  - `CodexHome/skills/clicky-browser/**`
  - `AgentHarness/h1-local/*/steps.jsonl` (tool schema; `meta` keys)
- `~/Library/Application Support/{Google/Chrome, Chromium, BraveSoftware/Brave-Browser, Microsoft Edge, Arc/User Data, Vivaldi}/NativeMessagingHosts/com.heyclicky.browser.json`
- `defaults read com.humansongs.clicky clicky.browserConnection.*` (types and booleans; the UUID was not printed)
