# Connected apps

OpenClicky reaches the user's apps without HeyClicky's server. Every app is an MCP server the user adds (a remote
URL or a command on this Mac), plus two built-ins: a local Obsidian vault and, optionally, Composio with the user's
own API key. The code is in `Sources/OpenClickyKit/Integrations/`; the settings view is in
`Sources/OpenClicky/Integrations/`; the CLI is `occtl apps`.

## Adding apps

Settings → Connected Apps, or:

```sh
occtl apps presets                       # official servers
occtl apps add notion                    # a preset (Notion and Linear: browser sign-in)
occtl apps signin notion
occtl apps add github                    # asks for a GitHub personal access token
occtl apps add Helpdesk https://helpdesk.example.com/mcp --bearer --label Support
occtl apps add-command Files npx -y @example/files-mcp
occtl apps env files FILES_TOKEN         # secret environment value for a local server (stdin)
occtl apps test helpdesk                 # connect, list tools, save a one-line capability
occtl apps tools helpdesk                # [read] / [write] per tool
occtl apps obsidian ~/Notes              # a vault folder
occtl apps composio me@example.com gmail googlecalendar   # after: occtl key set composio
```

The Settings forms take secret extra headers (`Header-Name: value`, remote servers) and secret environment variables
(`NAME=value`, commands) one per line, and a saved connector's row has Secret Headers… / Secret Variables… to add or
replace them and a × to forget one. They go through `ConnectorDraft` and `ConnectorSecretLines`, the same Keychain
names `occtl apps header` and `occtl apps env` use; a malformed line saves nothing, and `Authorization` belongs in the
token field.

`connectors.json` (next to `config.json`, or `$OPENCLICKY_CONNECTORS_FILE`) holds names, URLs, commands, auth kind,
account label and on/off. It never holds a secret: bearer tokens, OAuth tokens and client registrations, header
values and environment values live in the Keychain under `connector-<id>-…` names (so `OPENCLICKY_KEY_CONNECTOR_…`
environment overrides work for development, as with other credentials).

### Presets

Checked against each vendor's documentation on 2026-10-30:

| Preset | URL | Auth |
|---|---|---|
| GitHub | `https://api.githubcopilot.com/mcp/` | personal access token (GitHub's OAuth for this server needs a registered OAuth app) |
| Notion | `https://mcp.notion.com/mcp` | browser sign-in (OAuth) |
| Linear | `https://mcp.linear.app/mcp` | browser sign-in (OAuth with dynamic registration) or a Linear API key; `/mcp/readonly` exposes only reads |

Any other server is added by URL. If a server's sign-in has no dynamic client registration, register an OAuth app
with the vendor (redirect URI `http://127.0.0.1/callback`; OpenClicky listens on a free port each time, so the
vendor must accept any loopback port as RFC 8252 §7.3 asks) and pass `--client-id`, or use an API key instead.

## Protocol

`MCPClient` is dual-era, following the 2026-07-28 MCP specification and its backward-compatibility rules:

- It probes with `server/discover` and per-request `_meta`. A recognized modern error keeps it modern; anything else
  (a 4xx without a modern error body, another JSON-RPC error, or no answer on stdio) falls back to `initialize` with
  the newest initialize-based revision (2025-11-25, 2025-06-18, 2025-03-26).
- Streamable HTTP: one POST per message, JSON or SSE responses, `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` and
  `Mcp-Param-*` (from `x-mcp-header`) on modern requests; `Mcp-Session-Id` on legacy ones, re-initializing after a
  404, and a best-effort DELETE on close.
- stdio: newline-delimited JSON on the child's stdin and stdout, stderr kept for diagnostics, `notifications/cancelled`
  on cancel, close stdin then SIGTERM then SIGKILL. Writes to stdin are serialized, so concurrent requests never
  interleave. A server that exits stays down; the hub starts a fresh one on the next call. A local server inherits
  only HOME, USER, LOGNAME, SHELL, TERM, TMPDIR and the locale variables from OpenClicky, plus its own saved values
  (`occtl apps env`); API keys and tokens in OpenClicky's environment are not passed on. Its PATH also covers
  Homebrew, cargo, bun, volta, deno and `~/.local/bin`, so GUI-launched servers find their runtimes.
- Requests that arrive while the first handshake (or a re-initialize after a lost session) is running wait for it,
  so a server sees one `initialize`, not one per caller.
- OAuth 2.1 for remote servers: 401 challenge → protected-resource metadata → authorization-server metadata (with the
  issuer check) → pre-registered client id or dynamic registration as a native public client → PKCE S256 with
  `state` and `resource` → redirect to a one-shot listener on `127.0.0.1` → code exchange. The `iss` response
  parameter is checked (RFC 9207). Tokens refresh a minute before expiry, concurrent callers share one refresh, a
  401 triggers one refresh and retry, and `invalid_grant` clears the tokens so the app shows "Needs sign-in".

## The brain: `read_connected_apps`

`ReadConnectedApps.toolSpec(apps:)` is the tool definition; `ConnectedAppsPrompt.section(_:)` is the prompt text
listing the ready apps (and which need sign-in). The app's voice brain gets it through `ConnectedAppsWiring.make`
(`BrainWiring.connectedApps`): the tool is registered when an app is ready, the system prompt lists the ready apps with
their capability, and the chooser runs on brain-fast. Always-on voice is offered the same tool, and `occtl brain ask
--tools apps` (or `all`) does the same headlessly. The wiring underneath:

```swift
let hub = ConnectedAppsHub(registry: try ConnectorRegistry.load(), environment: ConnectorEnvironment(credentials: keychain))
let reader = ReadConnectedApps(hub: hub, chooser: ModelToolChooser(client: brainFastClient, model: brainFastModel))
// tools: [..., ReadConnectedApps.toolSpec(apps: await hub.summaries())]
// on a read_connected_apps call:
let outcome = await reader.run(arguments: call.arguments)
// status → outcome.status; tool result → outcome.text
// if outcome.didRead: speak only for the rest of this turn (no actions, no drawings that act)
```

That last rule is enforced, not only asked for: `BrainRuntime` remembers the turn that called `read_connected_apps`,
and `performDeferred` refuses that turn's deferred actions (open a link, an app or a page; only a job's result card
still shows) with `ConnectedAppsReadGuard.refusal`. The orchestrator says the refusal's line after the answer ("I only
looked things up in your apps that time, so I haven't opened anything…"), and the next turn hears an `[App]` note, so
asking again opens it. Always-on voice gets a connected-apps section in its instructions
(`RealtimeInstructions.connectedAppsSection`): each ready app by name and what it holds, the ones waiting on sign-in or a
key, and the same no-actions-after-a-read rule.

The chooser picks tools and arguments: the brain-fast model when configured (`ModelToolChooser`), otherwise word
matching (`KeywordToolChooser`). Whatever it picks, `ReadConnectedApps` runs only tools that `ToolSafety` classes as
reads. Server hints only add caution: a tool named like a write is a write even if it claims `readOnlyHint`, and a
name with no recognizable verb is a write. Composio's run-tools meta tool counts as a read only when every action it
lists reads; that argument check applies only to the built-in Composio app, so another server's tool with a similar
name is judged by its name alone. Users can allow writes per app ("Let the buddy change things"); background jobs can always write, and
are told to confirm before messaging people, posting, spending or deleting.

## Background agents

`ConnectedAppsAgentExporter(registry:environment:).export()` returns, right before a job launches:

- `codexConfigTOML()` / `codexConfigOverrides()`: `[mcp_servers.<id>]` with `url` + `bearer_token_env_var` +
  `env_http_headers`, or `command` + `args` + `env.PATH` + `env_vars`;
- `claudeCodeMCPConfig()`: `--mcp-config` JSON with `${VAR}` references;
- `jobEnvironment`: the secret values (`OPENCLICKY_APP_<ID>_TOKEN`, `OPENCLICKY_APP_<ID>_HEADER_<NAME>`, a local
  server's own variables, `OPENCLICKY_COMPOSIO_API_KEY`) and `OBSIDIAN_VAULT_PATH`;
- `instructions()`: the "Connected apps" and "Obsidian notes" sections for the job's instructions.

Jobs get the export at every launch (the app and `occtl agent run`, unless `--no-apps`): `AgentConnectedApps.extras()`
runs the exporter and `ConnectedAppsAgentExport.agentServers()` turns each server into an `AgentMCPServer` with its
bearer token, secret headers (`secretHeaders`) or a local server's variables (`forwardedVariables` + `environment`
PATH), so Codex gets `env_http_headers`/`env_vars` and Claude Code `${VAR}` headers and env entries. The Connected apps
and Obsidian sections go into the job's instructions and `OBSIDIAN_VAULT_PATH` into its environment (visible to its
commands; the secrets are not, under Codex).

OAuth apps go through `AgentConnectorRelay`, a loopback relay: the job is given
`http://127.0.0.1:<port>/apps/<id>/mcp` and a relay token, and the relay fetches a current access token from the
connector's `OAuthSession` for every request (refreshing shortly before expiry, and once more after a 401), so a job
that runs longer than the token lives keeps working. A relayed route keeps its address and token across launches. The
relay forwards POST and DELETE whole (an SSE reply is collected and returned in one response) and answers GET with
405, which MCP's Streamable HTTP transport defines as "no server stream". When the app needs signing in again, the
agent gets a JSON-RPC error saying so.

## Composio

With a Composio user id and the user's own API key saved (Settings → Connected Apps → Composio, or `occtl apps
composio`), the Composio section lists that user's connected accounts (`GET /connected_accounts`) with a Disconnect
button each (`DELETE /connected_accounts/{id}`). Connect… takes a toolkit slug (`gmail`, `slack`…): OpenClicky finds or
creates the project's Composio-managed auth config for it, asks for a Connect Link (`POST /connected_accounts/link`),
opens it in the browser, and polls the new account every two seconds for up to five minutes until it is `ACTIVE` (or
failed); then the list refreshes. The API shapes were checked against Composio's v3.1 reference on 2026-11-03
(`ComposioAccounts.swift`). `occtl apps composio-accounts [user-id] [--active]` asks the same question from the
command line (read-only) and prints the toolkits skills would follow.

Tool-router sessions are reused: `ComposioSessionCache` hands back the same session for the same user, toolkits and
key for 30 minutes, and after a failed create waits 5 s, then 10 s… up to 5 minutes before asking Composio again. The
app builds Settings' hub, the brain's hub and the job export with `ComposioSessionCache.shared`, so signing in,
connecting or disconnecting in Settings (the hub's reset) forgets the session everywhere. occtl is its own process
and never shares sessions with the app.

Integration skills for jobs follow what is really connected (`AgentSkillSources.connected`): only connectors whose
status is ready (a connector that needs sign-in, or is missing its token, a header or an environment value, gets no
skill), and the toolkits Composio reports with an active account (`ComposioToolkitDirectory`, cached for 5 minutes),
falling back to the toolkits typed in Settings when Composio can't be asked.

## Obsidian

Settings never scans folders on its own: listing iCloud Drive or `~/Documents` can raise a macOS privacy prompt, so
suggestions appear only after the user clicks Find Vaults. Choose Vault… uses the open panel, which needs no
permission. Reads and writes stay inside the vault (symlinks included) and out of hidden folders.

## Not covered yet

- Calendar and Spotify voice tools (`apps-calendar`, `apps-spotify`) and the dwell-based suggestion monitor.
  (Per-toolkit integration skills are installed for jobs while their app is connected; see [skills.md](skills.md).)
- Live sign-in against the real Notion, Linear and GitHub servers has not been run (no credentials in the build
  environment); the flow is tested against a fake authorization server on loopback.
- The Composio account list, Connect Link flow and disconnect are tested against a scripted Composio only; a live run
  with a real account (and a browser sign-in) is still to do. There is no browsable toolkit catalog: the user types the
  toolkit slug.
