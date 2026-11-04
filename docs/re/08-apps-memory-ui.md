# 08 — Connected apps, memory, skills, onboarding and app UI shell

Clean-room reverse-engineering notes for OpenClicky. Subject: HeyClicky 1.1.2 (build 69), bundle id `com.humansongs.clicky`.

This document covers the product surface around the voice/screen core: connected apps (Composio integrations, custom MCP connectors, local integrations), the skill library and skills picker, memory and on-disk history formats, onboarding (pre-sign-in intro, tutorial, interview, starter plan), the window/notch/Home/chat shell, settings and model pickers, sign-in, usage metering, analytics, crash reporting and auto-update. Referral payouts and billing checkout are described only enough to mark them **out of scope** for OpenClicky.

## Evidence conventions

- **OBSERVED**: seen directly in an artifact. The citation gives the path and the identifier or string.
  - `BIN` = `HeyClicky-1.1.2-b69.app/Contents/MacOS/HeyClicky` (arm64 slice). Strings came from `strings -n 6`. Swift type and field names came from the reflection field-descriptor metadata (`__swift5_fieldmd`).
  - `RES` = `Contents/Resources`.
  - `DATA` = `~/Library/Application Support/Clicky`.
  - `DEFAULTS` = `~/Library/Preferences/com.humansongs.clicky.plist`. Only key names and value types were read.
- **INFERRED**: my reasoning from the observed artifacts.
- **UNKNOWN**: the client can't show it, for example server prompts, server routing, or tool JSON schemas defined on the server.

Limitation: Swift stores string literals of 15 bytes or fewer inline in instructions, so they don't appear in a strings dump. Many short JSON keys, query parameter names and HTTP verbs are therefore not recoverable statically. They are marked UNKNOWN or INFERRED.

No personal content from the user's data directory is reproduced. Only key names, types, counts and enum values are given. Secrets (`CodexHome/auth.json`, `BrowserBridge/connection.json`, keychain items, and the API keys and DSNs in Info.plist) were not read or are omitted.

---

## 1. Component map

```
                ┌──────────────────────────── App shell ────────────────────────────┐
                │ AppDelegate / leanring_buddyApp (LSUIElement agent app, login item)│
                │  NotchWindowManager ─ NotchPresenter ─ NotchRootView (tabs)        │
                │  HomeSpace (Home: Clickys, suggestions, drawings, settings pages)  │
                │  HeyClickyWindow (standalone chat/agent window)                    │
                │  PreSignInIntroWindowManager / OnboardingTutorialWindowManager     │
                │  PowerUpPanel (skill library) / AgentPaywallHUD / AccountDeletion  │
                └────────────────────────────────────────────────────────────────────┘
   Identity & plan        Connected apps                 Skills                 Memory & history
   SupabaseAuthManager    CompanionManager+AgentInteg.   ClickyPowerUpManager   UserMemory (/me/memory)
   BillingStateManager    ComposioAgentSessionCache      ClickySkillLibraryBkd  ClickyHelperFiles (helper/)
   ReferralProgramModel   ClickyCustomConnector*         PowerUpSkillFileStore  OneBrain thread store
   AppRemoteConfigManager IntegrationSuggestionMonitor   HermesSkillCatalog     HeyClickyConversationHistory
   ClickyAnalytics(PostHog) ClickyUpcomingCalendarBackend                       HeyClickyChatHandOffs
   Sentry / PLCrashReporter Realtime tools (calendar, spotify)                  CodexHomeSpaceCacheStorage
   SparkleUpdateDelegate                                                         DictationTranscriptArchive
```

OBSERVED: Swift source files in BIN include `SupabaseAuthManager.swift`, `BillingClient.swift`, `ReferralProgramModel.swift`, `AppRemoteConfig.swift`, `ClickySkillLibraryBackend.swift`, `PowerUpSkillFileStore.swift`, `ClickyCustomConnectorOAuthClient.swift`, `ClickyCustomConnectorCapabilityDeriver.swift`, `HomeSpaceCustomConnectorsSettings.swift`, `IntegrationSuggestionMonitor.swift`, `HomeSpaceIntegrationConnectionFeedback.swift`, `HeyClickyConversationHistory.swift`, `HeyClickyChatHandOffs.swift`, `OnboardingInterviewPage.swift`, `OnboardingStarterPlanClient.swift`, `CompanionManager+OnboardingTutorial.swift`, `CompanionManager+DrawnOnboardingTour.swift`, `ProactiveAgentsClient.swift`, `NotchWindowManager.swift`, `NotchPresenter.swift`, `HomeSpaceSettingsPage.swift`, `HeyClickyWindow.swift`, `ClickyRecentDrawings.swift`, `ClickyDrawingWindowViewer.swift` and `PaywallCardContent.swift`.

All backend calls go to `WorkerBaseURL` = `https://api.heyclicky.com` (Info.plist key `WorkerBaseURL`; `CodexWorkerBaseURL` has the same value). They carry `Authorization: Bearer <Supabase access token>`. OBSERVED: the string `Bearer `, plus error strings such as "please sign in to use HeyClicky." and "invalid jwt" in `BillingClient.swift`'s string neighborhood.

Every request also carries device and trace headers. OBSERVED: `X-Clicky-Platform`, `X-Clicky-Device`, `X-Clicky-App-Version`, `X-Clicky-App-Build`, `X-Clicky-OS-Version`, `X-Clicky-Distinct-Id`, `X-Clicky-Session-Id`, `X-Clicky-Trace-Id`, `X-Clicky-Mode`, `X-Clicky-Agent-Thread-Id` and `X-Clicky-Usage-Context`.

---

## 2. Sign-in, account and URL schemes

### 2.1 Supabase auth (OBSERVED)

- Config keys in Info.plist: `SupabaseURL` = `https://mrpvynsdsnimuisyhkow.supabase.co` and `SupabaseAnonKey`. The anon key's value is present and omitted here.
- Flow:
  1. Sign-in starts at the Worker route `/auth/start`. OBSERVED string in the `SupabaseAuthManager.swift` block.
  2. The app opens it in the default browser. The only provider offered is Google: "Sign in with Google", `sign_in_with_google`, and the analytics events `google_sign_in` / `google_sign_up`.
  3. The browser returns to the app through a custom URL scheme (§2.3).
  4. The callback is validated by `ClickySignInCallbackGuard`:
     - `PendingSignIn {state: String, startedAt: Date}` is stored in memory and in defaults as `clickyPendingGoogleSignIn.v1`.
     - `Verdict` is one of `accept | acceptLocalDevelopment | refuseNoSignInStarted | refuseSignInExpired | refuseMissingState | refuseStateMismatch`.
     - Refusals are logged as `auth_callback_refused`.
     - Error query fields recognized: `error=`, `error_code=`, `error_description=`.
  5. Tokens: `/auth/v1/user` fetches the user (`user_metadata`, `full_name`). `/auth/v1/token?grant_type=refresh_token` refreshes. Both are Supabase GoTrue endpoints on `SupabaseURL` with the header `apikey`.
- Refresh failure classes are recognized by message text: `invalid_grant`, "refresh token not found / revoked / already used", "reuse detected", "session not found / expired", "user not found", `bad_jwt`. INFERRED: these force sign-out. Transport failures keep the session, and the app shows "couldn't reach the server to refresh your session…".
- Storage:
  - Tokens `supabaseAccessToken` and `supabaseRefreshToken` live in the Keychain (`ClickyKeychainStore`). There is a migration path from defaults: `keychain_token_migration`, `migrated_key_count`, `failed_key_count`. Sign-out cleanup is tracked with `clickySignOutPendingKeychainCleanup`.
  - Profile fields live in defaults: `supabaseUserId` (UUID string), `supabaseUserEmail`, `supabaseUserDisplayName`, `supabaseUserAvatarURL`, `supabaseSignupDate` (double).
  - The access token is never in defaults. OBSERVED: the key is absent from DEFAULTS.
- Account ID: the Supabase user UUID keys every per-account store. OBSERVED: `DATA/HeyClickyHistory/<uuid>.json`, `DATA/OneBrain/<uuid>/`, and the defaults key `ClickyCachedUserMemoryMarkdown_<uuid>` all use the same UUID as `supabaseUserId`. I checked this by equality without printing the values.
- Analytics identity: on sign-in, PostHog `identify` uses the user id and attaches the email and name. OBSERVED: " PostHog identify: ", plus redaction regexes for emails and long tokens (`[email]`, `[A-Za-z0-9/_+=.-]{24,}`).
- Account deletion: `POST /me/account/delete` (verb INFERRED), shown from `AccountDeletionPanel`. The panel copy says deletion wipes chats, agents and memory, and cancels the subscription. Failure copy covers "connection dropped before we could confirm".
- Sign-out: "Log Out" clears tokens and per-account in-memory stores. OBSERVED: `[one brain] another account signed in: starting clean`, and `IntegrationSuggestionDismissReason.signOut`.

### 2.2 Device registration and discovery channel (OBSERVED)

- `POST /me/devices` (`ClickyDeviceRegistration`). Keys seen: `fingerprint`, `registeredAt`, `capabilities`. The cache is the defaults key `clicky.device.lastRegistration.v1` (dict with 2 entries). The device key comes from `IOPlatformUUID` (`IOPlatformExpertDevice`), with `clicky.device.fallbackKey.v1` as a fallback. Other context keys sent: `timezone`, `locale`, `os_version`, `device_model`, `preferred_languages`.
- `POST /me/discovery-channel` saves the "Where'd you hear about us?" answer from onboarding. Defaults: `ClickyOnboardingDiscoveryChannel` and `ClickyOnboardingDiscoveryChannelSynced`.

### 2.3 URL schemes (OBSERVED)

Info.plist `CFBundleURLTypes`: name `com.humansongs.clicky.auth`, schemes `clicky` and `heyclicky`. The URL-event handler logs " HeyClicky: Received URL event: ". Recognized hosts and paths:

| URL | Purpose |
|---|---|
| `heyclicky://auth-callback…` | Supabase sign-in return (§2.1) |
| `heyclicky://integrations-auth-callback…` | Composio OAuth return after connecting an app (§3.1). Outcomes are `integration_callback` with `failure` or `cancelled`. |
| `heyclicky://checkout-complete…` | Stripe checkout or portal return. Keys `session_id`, `portal` and `canceled`. Out of scope. |
| `heyclicky://…/browser` | Chrome extension handshake. See the browser-bridge doc. |
| referral deep link | Defaults `clicky.referral.pendingDeepLinkCode.v1` and `…pendingDeepLinkOwner.v1`. Out of scope. |

`clicky://` is accepted as an alias. INFERRED: it is a legacy scheme. Some internal markdown links also use a `clicky:` prefix, for example `clicky:job-slot:` in `ClickyEdgeShelf.swift`.

Custom-connector OAuth does **not** use the URL scheme. It runs a loopback HTTP listener on `http://localhost:<port>/callback` (§3.5).

---

## 3. Connected apps

There are three families of "apps", and all of them surface in **Settings → Integrations**:

1. **Composio integrations.** These are server-brokered OAuth apps such as Gmail, Google Calendar, Notion, Linear and GitHub. The backend owns the Composio account. The client never sees Composio keys.
2. **Custom connectors.** These are any MCP server the user adds: a remote URL or a local stdio command. Secrets stay in the Keychain.
3. **Local integrations.** Obsidian (a vault folder) and the Chrome extension browser connection. The browser connection is covered in the browser-bridge doc.

### 3.1 Composio integrations: list, connect, disconnect

**Routes (OBSERVED path strings; verbs INFERRED):**

| Route | Verb | Purpose |
|---|---|---|
| `/agent/integrations` | GET | Catalog plus connection state. The response has `nextCursor`, so it is paged. `AgentIntegrationListFilter` is `all \| active`; the query parameter name is UNKNOWN. |
| `/agent/integrations/{id}/connect` | POST | Start OAuth. Returns a redirect URL. |
| `/agent/integrations/{id}/disconnect` | POST/DELETE | Remove all accounts for the integration. |
| `/agent/integrations/{id}/accounts/{connectedAccountId}/label` | PATCH/POST | Set an account label such as "Work". |
| `/agent/integrations/{id}/accounts/{connectedAccountId}/disconnect` | POST/DELETE | Remove one account. |

If Composio isn't configured server-side, the error copy "Composio is not configured on this HeyClicky backend yet." is shown. Not being signed in gives "Sign in to connect integrations."

**Data shapes.** OBSERVED type and field names. The JSON keys are snake_case, as the OBSERVED key strings show.

```
AgentIntegrationsResponse { composio_configured: Bool, integrations: [AgentIntegration], next_cursor?: String }

AgentIntegration {
  id: String                 // integration id, e.g. a provider grouping ("google" groups several toolkits — INFERRED)
  display_name: String
  description: String
  use_cases: [String]        // short phrases shown in the "connected" toast carousel
  status: AgentIntegrationStatus
  connected_count: Int
  total_count: Int
  toolkits: [AgentIntegrationToolkit]
  accounts: [AgentIntegrationAccount]
}

AgentIntegrationStatus = connected | partial | notConnected | needsReconnect | unavailable | error
   // wire values include "needs_reconnect" (OBSERVED string); others UNKNOWN casing

AgentIntegrationToolkit {
  slug: String               // Composio toolkit slug: gmail, googlecalendar, googledrive, googledocs, googlesheets, googlesuper, linkedin, notion, …
  name: String
  logo?: String (URL)
  status?: String
  is_connected: Bool
  connected_account_id?: String
  auth_config_id?: String
  auth_config_is_composio_managed?: Bool
  categories?: [ {slug, name} ]
  tools_count?: Int
  triggers_count?: Int
}

AgentIntegrationAccount {
  connected_account_id: String
  account_name?: String
  label?: String             // user label ("Work", "Personal")
  avatar_url?: String        // field avatarURLString
  account_name_kind?: String // e.g. "organization" vs personal (OBSERVED "organization" near these keys; INFERRED meaning)
  status: AgentIntegrationStatus
  connected_at?: String (ISO)
}

AgentIntegrationConnectResponse { redirect_url: String, connection_request_id?: String, toolkit: String, integration_id: String }
AgentIntegrationDisconnectResponse { ok: Bool, deleted_account_ids: [String], integration_id: String, toolkits: [String] }
```

**Connect state machine.** OBSERVED: `AgentIntegrationSettingsConnection {id, integration, phase, keepsListPosition}` with the phase enum `connecting | connected | syncing | failed`. Manager state fields: `pendingAgentIntegrationConnectionIDs`, `agentIntegrationAwaitingAuthCallbackIDs`, `pendingAgentIntegrationActiveAccountCountBaselines`, `pendingAgentIntegrationReconnectReplacedAccountIDs`, `agentIntegrationAuthRefreshTask`, `agentIntegrationRefreshGeneration` and `pendingAgentIntegrationReturnDestinations` (`AgentIntegrationReturnDestination.homeSpace(section: integration)`).

```
idle ──tap Connect / Reconnect / "Connect another account"──▶ connecting
  POST …/connect → redirect_url ; open in default browser ("Opening <App> sign-in in your browser")
  record baseline = number of active accounts for this integration
connecting ──heyclicky://integrations-auth-callback (success)──▶ syncing
  re-GET /agent/integrations (generation-guarded) until active account count > baseline
  ├─ new account appears ─▶ connected → show NotchIntegrationConnectedSurface toast
  │                           (AgentIntegrationConnectedToast{displayName, useCases, logoURL})
  ├─ count unchanged (multi-account add) ─▶ failed: "No new account showed up…" (paraphrase: pick the other account)
  └─ still pending after polling ─▶ "The connection is still syncing. Reopen Integrations to refresh its status."
connecting ──callback failure/cancelled──▶ failed ("Connection wasn't completed. Please try again.")
```

After any account change, the agent runtime is marked stale and rebuilt. OBSERVED: `isCodexRuntimeRestartPendingAfterIntegrationAccountChange`, `pendingSessionRebuildForIntegrationChange`, `rePrewarmAfterIntegrationChangeTask`, and "[Realtime] integration changed mid-turn … marking session stale; next PTT will rebuild". A live realtime voice session is torn down or restarted, because its prompt context lists the connected apps (§3.6).

Multi-account rules (OBSERVED UI copy):
- An app can hold a limited number of accounts. The copy is "… accounts is the most one app can have. Disconnect one to add another." The number is UNKNOWN.
- Accounts can be labeled ("Label your accounts so HeyClicky knows which one to use.").
- Expired accounts show "Sign-in expired", with "Remove this expired account" and "Sign in to this … account again".

Analytics: `integration_initiated`, `integration_connected`, `integration_disconnected`, `google_workspace_connect_clicked | _connected | _disconnected | _connect_failed | _connect_canceled`. Properties: `integration_name`, `toolkit_slug(s)`, `is_google_integration`, `is_local_integration`, `deleted_account_count`, `integration_status`, `custom_mcp`.

### 3.2 Composio MCP session for background agents

Background agents (the Codex CLI or the H1 harness; see the agent-harness doc) reach the user's apps through an MCP server proxied by the Worker.

- `GET/POST /agent/composio/session` (OBSERVED path; verb UNKNOWN) → `AgentComposioMCPSessionResponse`:
  ```
  { enabled: Bool, reason?: String, proxy_url?: String, expires_at?: Int (epoch s — INFERRED),
    toolkits?: [String], multi_account_toolkits?: [ {toolkit: String, accounts: [ {connected_account_id, account_name?, label?} ]} ] }
  ```
- The client folds the response into `ComposioAgentMCPSessionFetchResult`:
  - `.connected(ComposioAgentMCPConfiguration{url, toolkits, multiAccountToolkits, workerExpiresAt})`
  - `.unreachable(Error)`, which wraps `ComposioConnectedAppsUnreachableError{connectedAppNames, underlyingError}`
  - `.noConnectedApps`
- The result is cached per account until the Worker expiry (`ComposioAgentSessionCache`). The fetch is retried with backoff. OBSERVED logs: " Composio MCP session fetch attempt N failed (…); retrying in …" and "…failed after N attempt(s)". The counts and delays are UNKNOWN.
- The result is written into the agent's `CodexHome/config.toml`. OBSERVED template strings:
  ```toml
  [mcp_servers.composio]
  url = "<proxy_url>"
  bearer_token_env_var = "OPENAI_API_KEY"   # the same short-lived agent session token used for the model provider
  tool_timeout_sec = 120.0
  ```
  The user's current config has no `composio` section, which fits having no connected apps. OBSERVED: `config.toml` sections are `model_providers.clicky`, `projects."…/Clicky/projects"`, `features`, `tools.update_plan`, `mcp_servers.clicky_browser` and `skills.config`.
- Each agent launch gets a **"Connected apps"** section in its developer instructions. Paraphrase of the observed fragments:
  - When apps are connected, the section lists the connected toolkits and treats the `composio` tool list as authoritative and possibly changing, so the agent should search it before concluding that an app lacks a capability. Each Google product is its own toolkit (`gmail`, `googlesheets`, `googlecalendar`, `googledrive`, `googledocs`), and the agent should name the specific missing one.
  - When none are connected, the agent should use `composio` tools only if present, and otherwise tell the user to connect the app in Settings → Integrations.
  - When the session was unreachable, the agent should say the apps couldn't be reached right now and must not tell the user to reconnect.
  - The agent must never run OAuth or auth CLIs itself.
  - If Gmail can't send, the agent asks the user to reconnect Gmail with send permission.
  - Multi-account apps: every tool call names the `account`. Reads search every account unless one was named. Actions on existing items use the account that holds the item. For new items or sends, the agent picks the account the user specified, or else the one clearly implied by context, and asks a single short question if it is still ambiguous. Once learned, the account choice goes into the job's notes.
  - Custom connectors are listed as their own MCP servers, with a confirm-first rule for messaging other people or changing ad spend.
  - Obsidian is either "not set up" or "a local vault at <path> (also `$OBSIDIAN_VAULT_PATH`)".

### 3.3 Integration skills (RES/ClickyIntegrationSkills/*/SKILL.md)

These are bundled SKILL.md files (frontmatter `name` and `description`) that teach agents how to use specific Composio toolkits well. OBSERVED fields: `bundledIntegrationSkillContentsBySlug` and `availableIntegrationSkillSlugs`. INFERRED: when a toolkit with a bundled skill is connected, its SKILL.md is installed into the agent's skills list. The agent instructions tell the agent to read an app's SKILL.md before its first call to that app (RES/ClickyModelInstructions.md, paraphrased).

Every skill says its tools "run through the `composio` server". Each one ends with a "Check before you say done" section, which means re-reading the changed object to confirm the change. Capabilities, in my own words:

| Slug | What the skill enables / key guidance (paraphrased) |
|---|---|
| `gmail` | Search, read, count, draft and reply in Gmail. Drafts are the default for anything outgoing. Fetch headers first with small pages, then open single messages or threads. Handle "payload too large" by narrowing or paging. Has a section on writing in the user's own voice. Not for Calendar, Drive or Docs. |
| `outlook` | Outlook / Microsoft 365 mail and calendar. Use mailbox-wide search with paging, folder listing with OData filters, drafts by default, time-zone handling for calendar holds. Notes that Microsoft To Do isn't available. |
| `googledocs` | Read, create and edit Google Docs. Extract the doc id from the URL, search by title, insert text without disturbing existing content. Local .docx files go through the shell instead. |
| `googletasks` | Google Tasks to-dos: list, add, complete, reschedule, subtasks, move between lists. Dates are days, not times. Completed and hidden tasks need explicit flags. No assignees or notifications. |
| `clickup` | ClickUp tasks: resolve workspace, space, folder and list ids; statuses, priority and dates; write only what was asked (assignees get notified). |
| `jira` | Jira issues by JQL with paging and approximate counts; names → ids; transitions, comments, assignment. Notes that assignees and watchers get emailed. |
| `linear` | Linear issues, teams and projects. Prefer typed tools over raw GraphQL. Includes "what changed" queries. Write only when asked. |
| `hubspot` | HubSpot CRM search with explicit properties and full paging (counts and sums must not be taken from a single page; rows are written to `tmp/` and aggregated by a script). Labels are not ids. Log notes and calls, create tasks, move deal stages. |
| `salesforce` | SOQL reads with API names, `QUERY_MORE` paging, date and time-zone rules. Writes are limited to what was asked: stage moves, logged calls, tasks, notes, leads. |
| `dropbox` | Dropbox path rules (root is the empty string, reuse returned ids and paths), find, read, save, move, rename, sharing links (flagged as visible to others). |
| `microsoft_teams` | Teams (work or school accounts only): find teams, channels and chats by id, read messages and transcripts, post only after the user approves the exact message. |

Other bundled agent skills (RES/ClickyBundledSkills, copied into `DATA/CodexHome/skills/` and enabled through `[[skills.config]]`):
- `clicky-browser` (references: tabs, files, batching, confirmations, safety, troubleshooting). It covers working in the user's signed-in Chrome, and when to use the browser tool versus a connector.
- `vercel-deploy`, which includes `scripts/deploy.sh`.

### 3.4 Local integrations

- **Obsidian.** OBSERVED strings: "Select Obsidian Vault", "Choose the folder that contains your Obsidian markdown notes.", default search under `~/Library/Mobile Documents/iCloud~md~obsidian`, "No Composio account required.", and example use cases ("Search notes about this project", "Summarize today's notes", "Create a local Markdown brief", "Find backlinks for a topic"). When configured, the agent gets the `obsidian` skill (RES/obsidian.md) and the environment variable `$OBSIDIAN_VAULT_PATH`. Agents edit plain Markdown with the shell and must ask before deleting, bulk-moving or renaming notes, or touching `.obsidian`.
- **Chrome browser connection.** Settings rows "Chrome and HeyClicky drive" and the profile picker. See the browser-bridge doc.

### 3.5 Custom connectors (user-added MCP servers)

OBSERVED types: `ClickyCustomConnector`, `HomeSpaceCustomConnectorDraft`, `ClickyCustomConnectorSecrets`, `ClickyCustomConnectorStore`, `ClickyCustomConnectorSecretStore`, `ClickyCustomConnectorRuntimeRegistration`, `ClickyCustomConnectorOAuthClient`, `ClickyCustomConnectorOAuthDiscovery`, `ClickyCustomConnectorCapabilityDeriver` and `ClickyCustomConnectorVerification`.

**Draft (editor form).** Fields:
- `name`
- `transport`: remote URL or "Command on this Mac"
- `remoteURL`, `bearerToken`, `headerLines`
- `command`, `argumentLine`, `environmentLines` (one `KEY=value` per line, "Kept in your Keychain")
- `oauthClientID`
- `capabilityDescription`, `derivedCapabilityDescription`
- `authentication` = `browserSignIn | apiKey | noAuthentication`

Validation copy: "Enter the server's full URL, starting with https://." Environment variable names must be unique across connectors.

**Persistence.**
- Non-secret metadata is stored in defaults as `clicky.customConnectors.v1`. Fields seen: `transport`, `remoteURL`, `command`, `capabilityDescription`, `derivedCapabilityDescription`, `headerNames`, `environmentVariableNames`, `hasBearerToken`, `oauthClientID`, `browserSignInSupport` (`supported | unsupported`) and `signedInWithBrowser`.
- Secrets are stored in the Keychain under the service prefix `clicky.customConnector.secrets.<id>`, with `…secretsFallback.` as a fallback. `ClickyCustomConnectorSecrets` holds `bearerToken`, `headerValues{}`, `environmentValues{}`, `oauthRefreshToken`, `oauthTokenExpiresAt`, `oauthTokenEndpoint`, `oauthRegisteredClientID` and `oauthRegisteredClientSecret`.

**Verification.** HeyClicky acts as a minimal MCP client over Streamable HTTP:
1. It sends `initialize` with `protocolVersion` "2025-06-18" and `clientInfo {name: "HeyClicky"}`.
2. It sends `notifications/initialized`.
3. It calls `tools/list`, paging with `nextCursor`.

It sends the headers `Accept: application/json, text/event-stream`, `MCP-Protocol-Version`, and `Mcp-Session-Id` when one is given. The result is `ClickyCustomConnectorVerification = reachable(toolCount) | unauthorized(status) | serverError(status) | unreachable`.

**Capability deriver.** This builds a one-line description such as "find, create, and update …" from the tool names. It tokenizes the tool names against a verb lexicon. OBSERVED verbs include retrieve, describe, lookup, browse, create, activate, resolve, archive, assign, import, export, publish, invite, comment, approve, toggle and more. It can also reuse Codex's stored OAuth sign-in (`CodexStoredSignIn`).

**OAuth (browser sign-in).** This follows the MCP authorization spec:
1. Probe the server. A `401` with `WWW-Authenticate` carries `resource_metadata`.
2. Fetch `/.well-known/oauth-protected-resource` and read `authorization_servers`.
3. Fetch `/.well-known/oauth-authorization-server`, falling back to `openid-configuration`. Read `authorization_endpoint`, `token_endpoint`, `registration_endpoint` and `scopes_supported`.
4. Use dynamic client registration (`client_name`, `redirect_uris`, `grant_types`, `response_types`, `token_endpoint_auth_method`) unless the user supplied a client id.
5. Run the PKCE authorization code flow (`code_challenge`, `code_challenge_method`, `code_verifier`, `resource`).
6. The redirect goes to a **loopback listener** `http://localhost:<port>/callback`. OBSERVED dispatch queue: `com.humansongs.clicky.custom-connector-oauth-callback`. The listener serves a small dark HTML "you can close this" page and returns 404 for other paths.
7. Exchange the token (`grant_type=authorization_code`) and refresh it with `refresh_token`.

Errors: `discoveryFailed`, `clientRegistrationFailed`, `authorizationDenied`, `tokenExchangeFailed`, `serverDoesNotRequireOAuth`, `clientRegistrationUnavailable`, `callbackPortUnavailable`, `stateMismatch`, `timedOut`.

**Sign-in state shown in the row.** `signedIn | needsSignIn | awaitingBrowser | checking | notNeeded | tokenRejected(msg) | failed(msg) | signInUnavailable(msg) | unknown`.

**Runtime registration (agents).** `ClickyCustomConnectorRuntimeRegistration{serverKey, displayName, capabilityDescription, transport, environmentValues}`, where `transport` is one of:
- `remote(url, bearerTokenEnvironmentVariable?, headerEnvironmentVariables)`. Secrets are passed through env vars named `CLICKY_CONNECTOR_<KEY>_BEARER_TOKEN` and `CLICKY_CONNECTOR_<KEY>_HEADER_<NAME>`, and written to config as `bearer_token_env_var` / `env_http_headers`.
- `stdio(command, arguments, passthroughEnvironmentVariables, searchPath)`. The search path adds `~/.cargo/bin`, `~/.bun/bin`, `~/.volta/bin` and `/opt/homebrew/bin`.

The server key prefix is `custom-`. Connectors are also passed to realtime voice and proactive suggestions as `{name, description}` only.

### 3.6 Apps exposed to the voice brain and realtime voice

**Realtime prompt context.** Sent on `/agent/realtime/session` mint. OBSERVED `RealtimeSessionPromptContext` CodingKeys and wire keys:

```
prompt_context {
  connected_integrations: [String], needs_reconnect_integrations: [String],
  connected_integration_accounts?: [ {integration, accounts:[{connected_account_id, account_name?, label?}]} ],
  custom_connectors?: [ {name, description} ],
  active_skills: [ {display_name, one_liner, blurb, description, built_for?} ],   // §4.1
  explicit_agent_follow_up_target?: {codex_thread_id, title},
  prior_message_count: Int, time_zone: String, current_local_datetime: String,
  voice_gender: String, dictation_hold_shortcut?: String, onboarding_tutorial?: Bool
}
```

**`read_connected_apps` (brain tool).** OBSERVED developer toggle "One brain reads apps" (`one_brain_reads_apps`, defaults key `ClickyOneBrainReadsApps`). Its description, paraphrased: the voice brain may itself fetch a small item from a connected app (for example one message, calendar entry or document) and delegates larger lookups to a background job. Reads are read-only, and once one happens the brain only speaks for the remainder of that turn. GPT-6.1 Sol brain models only; experimental DeepSeek models are listed as having "No connected-app reads". It depends on a Worker-side MCP endpoint (the description mentions a local `npm run dev:mcp` tunnel for development).
- Client side: the brain turn request carries the flag `app_reads`. The status label is "Reading your apps" or "Read your apps" (tool-name keys `read_connected_apps`, `connected_apps`, `COMPOSIO`). State flags `isReadingConnectedApps` and `readConnectedAppsThisTurn` suppress further actions in that turn. OBSERVED: "not run: this turn read their connected apps", plus a user-facing line that begins "I didn't do that part, since I'd just read your apps" and invites the user to ask again.
- INFERRED: the read itself runs server-side. The Worker attaches a Composio-backed MCP tool to the model call, so the client only sees tool-call names (`tool_calls` in the OneBrain round log). Exact tool schema: UNKNOWN.
- Slot: **brain** (multimodal LLM with tool calling that can host remote MCP tools) plus an **other: connected-apps MCP proxy**.

**Google Calendar realtime tools.** OBSERVED tool names `google_calendar_find_events` and `google_calendar_create_event`. Routes: `/agent/realtime/google-calendar/events` (find) and `/agent/realtime/google-calendar/events/create` (create). The client adds `timeZone`. INFERRED: it otherwise forwards the model's tool arguments, and the Worker executes them against the user's Composio Google Calendar connection. Status labels: "Checked your calendar" and "Added it to your calendar" (icon `calendar.badge.plus`). Argument and response schema: UNKNOWN (server-defined tools).

**Upcoming meetings (notch countdown).** `GET /me/calendar/upcoming` → `{connected: Bool, events: [WireEvent{id, title, startsAt, endsAt?, isAllDay, meetingURL?, location?, htmlLink?}]}`. This drives `NotchMeetingCountdownSurface` with a primary action `join | open | directions`. Gated by the developer toggle "Upcoming meetings" (`upcoming_meetings`). Analytics: `meeting_countdown_presented`, `_action_clicked`, `_dismissed` and `meeting_list_item_clicked`.

**Spotify.** Realtime tool `play_on_spotify`. Client flow (OBSERVED log lines `[Realtime play_on_spotify] …`):
1. Arguments may carry a direct URI (`spotifyURI`/`spotifyUri`) or a query (`searchQuery`, optional `artist`). If both are missing, the result is `invalid_request` ("No song or artist to play…").
2. When there is no URI, it POSTs `/agent/realtime/spotify/search` and receives `{uri (spotify:track:…), name/trackName, artists, albumUri, artistUri}`, giving `ResolvedSpotifyTrack{uri, name?, artists?, contextURI?}` or `softFailure(status, summary)`. Not signed in returns `{"error":"not_signed_in"}`.
3. Playback: if Spotify is running, AppleScript `tell application "Spotify"` plays the track (optionally "in context"). It captures player state and track id and name before and after, with a 0.4 s delay. If AppleScript fails or Spotify isn't running, it opens the `spotify:` URL scheme (cold launch). A post-play check runs about 3 s later.
4. Result strings include "Started Spotify playback." and "Now playing … on Spotify."

Requires Automation permission for Spotify. INFERRED: the search is server-side because Spotify Web API credentials live on the Worker. A one-time `NotchSpotifyVoiceTipSurface` appears after dwelling in Spotify (`clicky.spotifyVoiceTip.acknowledged.v1`).

### 3.7 Integration suggestion monitor

OBSERVED `IntegrationSuggestionMonitor` state:
- Fields: `cumulativeDwellSecondsByToolkit`, `cumulativeLearningDwellSecondsBySkillID`, `cumulativeSpotifyVoiceTipDwellSeconds`, `availableComposioToolkitSlugs` and `currentSuppressionReason`.
- Callbacks: `onCandidateReady`, `onLearningCandidateReady`, `onSpotifyVoiceTipReady`, `isSuggestionSuppressed` and `hasAccessibilityPermission`.

How it works:
- It samples the frontmost app periodically. For browsers, it reads the window title and URL through Accessibility (`AXTitle`, `AXContents`).
- It matches against a built-in `RegistryEntry{toolkitSlug, displayName, hostSuffixes, titleNeedles, nativeBundleIdentifiers, pathPrefixes}` table of about 70 toolkits. Examples: notion (`notion.so`, `notion.site`), linear (`com.linearapp.linear`), github, googlecalendar, googledrive and googledocs (path `/document`), googlesheets (`/spreadsheets`), slack (`app.slack.com`, `com.tinyspeck.slackmacgap`), jira (`atlassian.net` + `/browse`, `/issues`, `/projects`), asana, trello, clickup, airtable, hubspot, salesforce, zendesk, dropbox, …, zoho_mail, spotify.
- When dwell time for a toolkit crosses a threshold (UNKNOWN), it creates a candidate `{toolkitSlug, displayName, useCases, logoURL, sourceApplicationName?, sourceHost?}`. The candidate is shown only if the toolkit is in the fetched Composio catalog. OBSERVED log: "Integration suggestion skipped because toolkit is not in the fetched Composio catalog".
- Throttling (defaults keys): `clicky.integrationSuggestions.snoozedUntilByToolkit.v1` (dict), `…neverAskToolkitSlugs.v1`, `…lastPromptAtByToolkit.v1`, `…lastGlobalPromptAt.v1`, `…recentPromptTimestamps.v1` (list).
- Dismiss reasons: `autoDismiss | close | accepted | snoozed | declined | compatibilityMode | signOut`. Analytics: `integration_suggestion_presented | _accepted | _snoozed | _declined`.
- Learning suggestions are a parallel path. `LearningRegistryEntry{skillID, displayName, bundleIdentifiers}` suggests a skill "built for" the app being used (`NotchSidecarLearningSuggestionSurface`, `clicky.sidecarLearningSuggestions.acknowledgedSkillIDs.v1`).

---

## 4. Skills

There are three skill systems: (a) the **Skills Library** ("power-ups"), a server-hosted catalog of persona and expertise skills the user activates; (b) the **Hermes skills picker** in pre-sign-in onboarding; (c) the bundled and integration **agent skills** described in §3.3.

### 4.1 Skills Library (power-ups)

**Routes (OBSERVED; verbs INFERRED):**

| Route | Purpose |
|---|---|
| `GET /skills/library` | Full catalog → `LibraryResponse{skills, authors?, categories?, caller_team?}` |
| `GET /skills/programs` (path `/programs`; prefix INFERRED) | App registry `ProgramsResponse{programs:[RemoteAppProgram{slug, name, bundle_ids, host_suffixes, logo_url?}]}`, used for `built_for` badges and logos (`ClickyProgramLogoRegistry`) |
| `POST /skills/create` | Create from a filled form → `CreateSkillResponse{skill}`. Fields include `logo_base64` and `logo_content_type`. |
| `POST /skills/creations` | Queue AI creation from a "brain dump" (`raw_text`) → `QueuedSkillCreationResponse{slug}`, then poll the library until the status leaves `creating` |
| `PATCH/DELETE /skills/{slug}` | Update or delete own skill |
| `POST /skills/{slug}/publish`, `/unpublish` | Submit for review / withdraw |
| `POST /skills/{slug}/share-to-team`, `/unshare-from-team` | Team sharing |
| `POST /skills/activations/sync` | Body `{active_slugs:[String]}` → `ActivationsSyncResponse{usage:[RemoteSkillUsage{slug, users_count, active_users_count, user_avatar_urls}]}` |

**Cache file `DATA/SkillLibraryCache.json`.** OBSERVED structure, about 2.1 MB:

```
{
  "skills":     [Skill]    // 200 entries in this snapshot
  "authors":    [Author]   // 118
  "categories": [Category] // 27 (8 carry symbol+color)
}
Skill {
  slug: str, visibility: str ("public" ×200), team_shared: bool, is_mine: bool,
  display_name: str, author: str, author_slug: str, avatar_url: str|null, logo_url: str,
  one_liner: str, built_for: str|null, built_for_program: str|null (75/200 set; e.g. capcut, shopify, claude-code, premiere-pro, final-cut-pro, davinci-resolve, linkedin, logic-pro, ableton-live),
  blurb: str, description: str, whats_inside: [str], tags: [str], category: str,
  featured: bool (5 true), verified: bool (1 true), status: str ("published" ×200),
  badges: [str] ("popular" 90, "trending" 4; enum also has "new"),
  content: str (full SKILL markdown, 3.6k–56k chars),
  users_count: int, active_users_count: int, user_avatar_urls: [str],
  created_at: str (ISO), updated_at: str (ISO)
}
Author   { slug, name, avatar_url|null, bio, verified: bool }
Category { name, symbol?: str (SF Symbol), color?: str (hex) }
```

The category names are Coding, Video, Productivity, Design, Marketing, AI, Startups, Career, Music, Writing, Education, 3D, Research, Learning, Travel, Shopping, Culture, Sports, Security, Food, Photography, Finance, Creative, Trading, Games, Ecommerce and Sales.

**Client model** `ClickyPowerUp` fields:
- `id`, `displayName`, `creator`, `authorSlug`, `blurb`, `routingDescription`, `tags`, `category`
- `isFeatured`, `isVerified`, `statusBadges[trending|popular|new]`, `oneLiner`
- `builtForAppName`, `builtForProgramSlug`
- `reviewStatus` (`creating | draft | inReview | published | failed`)
- `isMine`, `isTeamShared`, `avatarURL`, `logoURL`, `content`
- `origin` (`library | imported`). Users can import a local `.md` file; errors are `notMarkdown | unreadable | empty`.
- `fileURL`, usage counts, `whatsInside`, `createdAt`, `creationDurationMs`

`ClickyPowerUpManager` holds `_activePowerUpIDs`, `_recentlyUsedPowerUpIDs` and `latestUsageBySlug`, and fires `onActiveSetChangedForBackendSync` when the active set changes.

**Activation effects.**
1. **Realtime voice.** `prompt_context.active_skills` carries the descriptions only (`RealtimeSessionActiveSkill{displayName, oneLiner, blurb, description, builtFor?}`). Mid-session changes are pushed as a conversation item headed "[Skill update]". It either replaces the active set (wrapped in `<active_skills>`) or clears it. The model is told to color its tone lightly in the skill's domain, that full skill files ride along with `send_to_higher_model` and spawned agents, and not to announce the change (paraphrase). Skipped with no live session; the next mint carries it.
2. **Agents.** `PowerUpSkillFileStore` writes each active skill as a SKILL.md with `name:` and `description:` frontmatter under a `power-up-skills` directory. OBSERVED log: "[Skills] wrote N agent skill file(s) … under …". The agent prompt gets an `<active_skills …>` block listing each skill's description and a `file` attribute pointing at that SKILL.md. Paraphrased guidance: skills change how the agent works, never safety or approval rules. A skill with `built_for` applies fully only when the task involves that app. Don't announce loaded skills.
3. **Notch.** The developer toggle "Skills in notch" (`skills_in_notch`) pins active skill logos (`NotchSkillPinnedSurface`, live event `skillPinned(count)`).

**UI.** `PowerUpPanel` (NSPanel):
- Category filter, "my skills", "team skills", search, share-link copy, publish confirmation.
- `PowerUpCreateSkillForm` steps: `brainDump → confirm → creating → details`. Detail fields: name, one-liner, description, category, tags, content and logo.
- Copy (paraphrased): turning a skill on folds it into HeyClicky's behaviour, influencing both its own replies and the agents it launches.
- Actions: "Remove all", "Deactivate all attached skills".

### 4.2 Hermes skills picker (pre-sign-in onboarding)

OBSERVED in RES/ATTRIBUTION.md, paraphrased:
- The root-level `RES/*.md` skill files are vendored MIT skills from NousResearch/hermes-agent. `blender.md` comes from a separate marketplace plugin.
- They power the "What should HeyClicky be good at?" picker in pre-sign-in onboarding.
- Picked IDs are stored in defaults under `selectedHermesSkillIDs`. In DEFAULTS this is a list of 8 strings; `hermesSkillsFirstLaunchDefaultsApplied` is a bool.
- The attribution file says backend activation of these skills was not wired up yet.

Catalog model: `HermesSkillCategory{id, displayName, skills}` and `HermesSkill{id, displayName, subtitle?, iconSystemName, iconColor, iconAssetName?, bundledSkillIDs?}`. One picker entry can bundle several files; for example, the GitHub entry bundles the five `github-*` skills. Categories and entries in observed string order:
- **Productivity**: Apple Reminders, Apple Notes, iMessage, Google Workspace, PDFs/OCR, Generate Images, Obsidian vault, Find My, Maps.
- **Coding**: Claude Code, Codex, GitHub, Frontend design.
- **Office**: PowerPoint, Word docs.
- **Creative**: Excalidraw, Claude design, Blender, YouTube content, Spotify.
- **Research**: Polymarket.

Vendored skill files and what they enable, paraphrased from their descriptions:
- `apple-notes`: notes via the `memo` CLI.
- `apple-reminders`: reminders via `remindctl`.
- `imessage`: messages via the `imsg` CLI.
- `findmy`: devices and AirTags via the Find My app.
- `google-workspace`: Gmail, Calendar, Drive, Docs and Sheets via the `gws` CLI or Python; needs `google_token.json`.
- `ocr-and-documents`: PDF and scan text extraction.
- `maps`: geocoding, POIs and routes via OpenStreetMap/OSRM.
- `claude-code` and `codex`: delegate coding to those CLIs.
- `github-auth`, `-repo-management`, `-pr-workflow`, `-code-review`, `-issues`: work through `gh` or REST.
- `powerpoint`: .pptx files.
- `excalidraw`: diagram JSON.
- `claude-design`: one-off HTML artifacts.
- `blender` (blender-toolkit): WebSocket-controlled Blender, including Mixamo retargeting.
- `youtube-content`: transcripts → summaries.
- `spotify`: needs Spotify tool functions.
- `polymarket`: market data.
- `airtable`, `linear`, `notion`: REST/GraphQL with API keys in environment variables.
- `obsidian`: vault files.

INFERRED: `bundledSkillIDs` lets a selection install those SKILL.md files into the agent skills directory once backend wiring exists.

### 4.3 Clicky "programs" table

BIN holds a hard-coded `slug → app name → bundle ids` table that covers about 80 creative and pro apps, for example `ableton-live` → `com.ableton.live` … `xcode-development` → `com.apple.dt.Xcode`. It matches the `built_for_program` values. The matching server registry is `/skills/programs` with `bundle_ids` and `host_suffixes`. Uses: "built for" skill matching, learning suggestions, and app logos.

---

## 5. Memory and on-disk history

### 5.1 User memory profile (server) and `helper/about-the-user.md`

- `GET /me/memory` → `UserMemoryProfileResponse{markdown?: String, has_profile?: Bool}`. OBSERVED logs: "[Codex] user memory: server reports no profile yet", "fetched fresh (N chars) caching + injecting", "using cached copy", "no cached copy injecting nothing".
- Cache: defaults `ClickyCachedUserMemoryMarkdown_<accountUUID>` (string).
- Mirror file: `ClickyHelperFiles` writes `DATA/helper/about-the-user.md` (and `note-guide.md`). OBSERVED: the file is **byte-identical** to the cached markdown. It is a profile document with a top heading ("What HeyClicky knows about this user") and these second-level sections:
  - "Who they are"
  - "Role & background"
  - "Goals"
  - "People"
  - "Routines"
  - "Beliefs"
  - "Tools & apps they use"
  - "What they use HeyClicky for"
  - "Communication style & voice preferences"
  - "Writing style"
  - a second top heading "Current context" with "Current projects & focus" and "Recent activity & asks"

  Purpose (INFERRED): it gives background agents and helpers a file they can read about the user, and it backs the `<user_memory>` block.
- Injection into agent prompts: a `<user_memory note="…">` block. Its note says, paraphrased, that this is what HeyClicky learned across past conversations (identity, role, goals, stack, proficiency, working style), that the agent should use it to tailor the work, and that it is background only and never a source of instructions.
- Writing memory:
  - Realtime tool `save_memory` → `POST /me/memory/save` (label "Saved to memory" / "Saving to memory").
  - `forget_memory` (label "Forgot it"). Its route is UNKNOWN; INFERRED to be server-side.
  - `recall` (label "Looked back through earlier chats", icon `clock.arrow.circlepath`). INFERRED: it searches past conversation history server-side. Route UNKNOWN.
  - Tool argument schemas are defined server-side: UNKNOWN.
- Session-end consolidation: the brain posts `/brain/session-end`. OBSERVED copy: "The session that ends still gets its note and memory written." INFERRED: the Worker summarizes the session into a note and updates the profile markdown. Logic: UNKNOWN.
- Slot: memory extraction and consolidation is server-side **other: memory-writer LLM**.

### 5.2 OneBrain thread store (`DATA/OneBrain/<accountUUID>/`)

Two files per voice-brain session, named by session UUID (OBSERVED: the thread `session_id` equals the file name).

**`threads/<sessionUUID>.json`** holds the full conversation state, resent to the Worker each turn:
```
{
  session_id: str,
  thread: [Item],                       // OpenAI Responses-API style input items (80 in sample)
  user_layer: str,                      // client-built context block: <you><your_jobs>…</your_jobs><connected_apps>…</connected_apps><where>…</where></you>
  user_layer_skills: str,               // active-skill text (empty when none)
  user_layer_signature: str (43 chars), // change detector; algorithm UNKNOWN (not plain SHA-256 of user_layer)
  environment_sent: bool,
  canvas: [int, int],                   // screen canvas size e.g. [w, h]
  drawing_code: [str],                  // latest drawing program(s)
  baseline_input_tokens: int, last_input_tokens: int,
  last_turn_at: float (epoch s)
}
Item =
  {type:"message", role:"user"|"developer"|"assistant", content:[{type:"input_text"|"output_text", text}], phase?: "commentary"|"final_answer"}
| {type:"reasoning", id, summary:[…], encrypted_content}
| {type:"function_call", name, call_id, arguments}
| {type:"function_call_output", call_id, output}
```
Developer messages are app notes tagged with bracketed prefixes. Observed in this sample: `[This turn]` (time and context header) and `[App]` (events such as "user cut this answer off"). Other tags seen in BIN: `[Agent progress]`, `[About the user]`, `[Onboarding interview]`, `[Home tour]`, `[Chrome setup]`, `[Your jobs]`, `[Your routines]`, `[Your Clickys]`, `[Your plan]`, `[Skill update]`.

Compaction:
- When input tokens pass a threshold, the client asks the Worker to compact (`/brain/compact`, with `keep_from_index`, `keep_leading_items`, `drop_leading_items`, `note_item`, `tokens_until_fold`).
- A result that arrives after the thread moved on is discarded.
- Screenshots kept in the thread are capped ("more than N screenshots … kept the newest").
- A different account signing in starts clean.
- Picking up an existing session logs "picked up session … (N items, last turn M min ago)".

**`<sessionUUID>.jsonl`** is a per-round log. OBSERVED keys:
```
{ at: ISO8601, session: uuid, kind: "round"|"interrupted"|"tools", round: int,
  words: str (spoken text), code: str (drawing program, starts with step()/say()), fact: str (bracket-tagged app fact, e.g. "[App] …", "[Take-over] …", "[Chrome setup] …", "[Job ready] …"),
  tool_calls: [str], async_calls: [str], calls: [str], computer_actions: [...], asks_again: bool, ms_after_turn_start: int, error?: str,
  usage: { input, cached, wrote, output, reasoning, last_input: int, cost: float (USD), reported_model: str (e.g. "gpt-6.1-sol"),
           ttftMs, totalMs, fastServed, webSearches: int, keep_reasoning, message_counted, message_recorded, turn_saved: bool,
           turn_token: str, screenshot_file: str } }
```
`OneBrainStatsHUD` reads these figures. It is the developer toggle "Show one brain stats".

### 5.3 Conversation history (`DATA/HeyClickyHistory/`)

**`<accountUUID>.json`** is the local cache of the main HeyClicky chat, synced from the server:
```
{ messages: [Message], hasEarlierMessages: bool }
Message { id: str, serverID: int, role: "user"|"assistant", content: str, source: str ("voice"|"text"|… ),
          createdAt: float (epoch s), attachmentPaths?: [str], bubbleSegments?: [str],
          replacedLocalID?: str, sentToAgentName?: str, sentToAgentTargetKey?: str }
```
Server sync: `GET /me/companion-history` with `before_id` for older pages. The response carries `created_at` and `has_more`. Local ids are prefixed `local-` / `local-spoken-` until a server copy replaces them (`replacedLocalID`).

**`<accountUUID>-handoffs.json`** holds handoff rows interleaved in the chat (work sent to jobs, results that came back, drawings, text deliveries):
```
[ HandOff {
  id: str, kind: "started"|"cameBack"|"drawing"|"text", jobID?: str, clickySlug?: str, title: str, taskTitle?: str,
  createdAt: number (epoch ms in sample), isFollowUp: bool, outcome?: "finished"|"failed"|"stopped"|"needsYou",
  replyText?: str, fullReply?: str, threadID?: str, artifactEntries?: [str (file paths/URLs)], followUps?: [str],
  answer?: ClickyAnswer, card?: ClickyAnswer, lessonID?: str, deliveredText?: str, deliveredToApp?: str,
  wasCopied?: bool, isRoutineRun?: bool, sitesRead?: [str] } ]
ClickyAnswer { line: str, numbers?: [{value, label?, was?, of?, better?}], list?: [{text, detail?}], ranked?: bool,
               done?: [{did, what?, link?}], draft?: {text, to?}, ask?: [{answer?, detail?, file?}], note?: str,
               next?: {label, open}, quiet?: bool }
```

### 5.4 Agent thread cache (`DATA/HomeSpaceCache/`)

OBSERVED: `CodexHomeSpaceCacheStorage` with dispatch queue `com.humansongs.clicky.homespace-cache`.
- **`thread-history.json`**: `[ {threadID, threadName, createdAt (ISO), updatedAt (ISO), previewText, status} ]`. Status is one of `running | completed | failed | interrupted | idle`. In-memory only: `isLoaded`, `isPausedForExtraEffortApproval`.
- **`turn-journal/<threadID>/<turnUUID>.json`**: crash-safe "chat checkpoint" for a turn.
  ```
  { appSessionID: uuid, presentationID: uuid,
    turn: { clientTurnID, codexTurnID, startedAt, finishedAt (ISO), isCompleted, didFail, wasInterrupted,
            userMessages:[str], assistantMessages:[str], reasoningSteps:[str], suggestedNextActions:[str],
            userAttachmentPaths:[str], artifactEntries:[str], usedIntegrationProviderKeys:[str] } }
  ```
  Thread ids look like `harness-h1-mac-<uuid>`, the H1 harness on this Mac.
- `transcript-<thread>` cache files (`CodexThreadTranscriptCache`), loaded through `loadTurnsFromDisk(forThreadID:)`.

### 5.5 Dictation transcripts (`DATA/DictationTranscripts/YYYY-MM-DD.jsonl`)

`DictationTranscriptArchive` runs on queue `com.humansongs.clicky.dictation.transcript-archive` and writes one line per dictation: `{at: ISO8601, app: str (target app name), text: str}`. It is a local-only archive with daily files. Retention: UNKNOWN.

### 5.6 Per-Clicky and per-job memory (files)

- **Clickys** are persistent named agents. Each has a workspace folder whose `AGENTS.md` (path segment `/agents/`) acts as the agent's memory. INFERRED path: `DATA/projects/agents/<slug>/AGENTS.md`. Its template sections are an identity block (name, role, voice), "## Standing preferences" (durable one-line instructions) and "## Notes" (curated working memory with dated facts and pruning, never secrets). The file is read before every turn.
- Realtime tool `clicky_memory(clicky_slug)` returns `{is_archived, is_working_now, has_conversation, memory_markdown (or "(no memory file yet …)" / "(memory file truncated)"), recent_messages[] (role user|clicky|clicky_progress), latest_reply, current_progress}`.
- **Jobs**: `DATA/projects/jobs/<slug>-<10hex>/` contains `output/`, `tmp/`, `report.md`, `state.md` and `.clicky/owner` / `.clicky/previous-note.md`. The index `DATA/projects/jobs/WORK.md` has the heading "Work HeyClicky has done for the user" and a run list between `<!-- clicky:runs -->` markers.
- Roster: defaults `clicky.roster.v1` (encoded `StoredRoster{overridesBySlug, createdClickys:[{slug, name, roleText, oneLiner, baseHue, createdAt, introMessages, suggestedAsks, firstAsksGeneratedAfterCreation}], archivedSlugs, portraitAppearancesBySlug, userCustomizedPortraitSlugs}`). The defaults include the starter cast "Research Buddy" (`research-buddy`) and "Shippy" (`shippy`).
- History organizer: `POST /clickys/organize-history` with `{threads:[{threadID, title?, firstAsk?, lastReply?, updatedAt?, turnCount?}], existingClickys:[{slug,name,role,description}], foundFromThread?}` → `{clickys:[{existingSlug?, name, role, description, threadIDs, notes}], leftoverThreadIDs}`. This groups older one-off agent threads into Clickys. The completion flag is `clicky.clickyOrganizer.completedAt.v1`.

### 5.7 Saved drawings ("Drawings" in Home)

`ClickyLessonStore` keeps a `Lessons` directory. Each saved drawing is a folder with `lesson.json`, `program.js`, `screen.jpg`, `poster.jpg`, `narration.caf` and `photos/`:
```
lesson.json = { id: UUID, title, createdAt, question, model, canvasWidth: int, canvasHeight: int,
                displayWidth: double, displayHeight: double, lines: [{text, start: s, length?: s}], duration: s, hasNarration: bool }
```
`ClickyRecentDrawings` keeps in-session drafts `{handle, draft, finalFrame, displayFrame, saved?}` so "Save drawing" (realtime tool `save_drawing`) can persist them. Possible outcomes: `already_saved`, "Saved to the user's Drawings in Home", or failure because no recent drawing exists.

### 5.8 Relevant defaults keys (names and types only)

`clicky.jobs.v1` (data), `clicky.roster.v1` (data), `clicky.agentSpace.suggestedAgents.v1` (data), `clicky.codex.finalSummariesByThreadID.v1`, `clicky.codex.userFacingArtifactPathsByThreadID.v1`, `clicky.codexThreadDisplayPrompts.v1`, `generatedCodexThreadTitlesByThreadID` (dict), `clickyAgentThreadTraceIDsByThreadID` (dict), `clicky.billing.lastKnownPlanSnapshot.v1.<uuid>` (data), `ClickyAppRemoteConfigV1` (data), `ClickyDictationCustomWords` (string), `selectedRealtimeVoiceID` (string), `clicky.onboarding.completed.v2`, `clicky.onboarding.firstCompletedAt.v1`, `clicky.onboarding.tutorialCompletedAt.v1`, `clicky.preSignInIntro.dismissed.v2`, `clicky.permissionIntro.acknowledged.v2`, `persistedPermissionSnapshot.{accessibility,microphone,screenContent,screenRecording}.prod` (bools), and the Sparkle keys `SULastCheckTime` / `SUScheduledCheckInterval`.

---

## 6. Onboarding

### 6.1 Overall sequence (OBSERVED enums; order INFERRED)

```
first launch ─▶ PreSignInIntro panel (NSPanel, PreSignInIntroWindowManager)
   steps: whatIsClicky → whereClickyLives → clickyGetsLost → whereHeardAbout → pickLanguage
          → openClicky (pick a character/color: "Click one to bring me to life") → hatched (hatch animation, flight to notch)
          → skillSelection ("What should HeyClicky be good at?" Hermes picker) → readyToStart ("Start Clickying")
   voice picker variants: slider | map | orbit | checklist | wave
   "Next up, sign up to make sure we don't lose your setup." → Sign in with Google (§2.1)
─▶ Permission flow (PermissionFlowCoordinator): microphone, accessibility, screen recording, screen content
   PermissionStatus: notDetermined | prompting | waitingInSettings | waitingForPicker | restartRequired | granted | denied
   guide styles: dragToAllow | callout ; "Quit & Reopen HeyClicky" when restart required
─▶ Intro video (onboarding-intro-v2.mp4) ─▶ Onboarding tutorial (OnboardingTutorialWindow)
   OnboardingTutorialStep: micCheck → speakerCheck → voiceHello → clickyInterview → drawDemo → drawToAsk
                           → clickyDrive → textMode → emailDraft → dictation → finale
─▶ Starter plan (/onboarding/starter-plan) ─▶ Reveal (Home opens in notch, starter Clickys introduced) ─▶ Home tour
```
Analytics include `onboarding_started`, `onboarding_video_started|completed|escape_pressed`, `onboarding_tutorial_started|step_viewed|step_completed|resolved|music_toggled|resumed_from_notch|mic_device_switched|speaker_volume_fixed`, `onboarding_skipped_by_shake`, `onboarding_starter_plan_started|finished`, `onboarding_reveal_started|ended` and `onboarding_completed`. The tutorial can be resumed from the notch (`NotchTutorialInviteSurface` mode `invite | resume`). Settings has "Replay the welcome tour", which repeats the video, tour and interview and suggests three new jobs while keeping the existing ones.

Tutorial behaviors with timing or edge handling (OBSERVED UI copy, paraphrased):
- The mic check shows live bars and recommends built-in or wired mics over Bluetooth.
- The speaker check detects a muted Mac ("Your Mac is muted") and offers a one-click fix (`OnboardingTutorialSystemVolume`).
- The voice hello step teaches hold-to-talk. The default is hold control+option.
- Text mode is a double-tap of control. Dictation has a hold key and a hands-free toggle.
- Requests made during the tour are deferred. OBSERVED: "Nothing starts during the welcome tour's interview…", and `sessions_spawn` returns `not_during_the_tour`.

### 6.2 Onboarding interview

Surface: `OnboardingInterviewPage`. It shows a character stage (`OnboardingInterviewStage`) and `InterviewThoughtBubbles` with pagination (`InterviewBubblePagination{source, bubbles, bubbleStartOffsets, startsNextBubble}`). The user can answer by voice or switch to typing ("Or type here", `typedAnswerField`, `prefersVoiceAnswer`). The model runs in the realtime voice session with a large system note headed `[Onboarding interview]`. That prompt text is server-side or embedded and is paraphrased here.

Behavior contract (paraphrased):
1. **Fixed opener.** When the page opens, the app sends a note asking the model to say an exact two-part opener, shown as two bubbles. Part one is a short self-introduction (HeyClicky helps you make things, learn things, start a business). Part two says it has "four quick questions" and asks what the user is working on and what their story is. This is the only fixed line.
2. **Turn budget.** The model is told it gets exactly N turns (N is interpolated). After each answer, the app sends a per-answer note:
   - It lists the questions already asked and how many are left, not counting the fixed last one.
   - On the penultimate turn it says the next question is the fixed last one.
   - After the final answer it says to wrap up.
   - INFERRED: N = 4 answers in total, matching "four quick questions".
3. **Adaptive questions.** Every question after the opener grows from the user's last answer. Each question turn is a short reaction, one question, and two or three concrete ideas to talk about, about 35 words at most with no dashes. The model favors breadth over depth, with at most one follow-up per topic. It must surface one concrete goal and a picture of the person's day-to-day work. It never grills, diagnoses or quizzes about tools. It knows which apps HeyClicky can connect (sample list: Gmail, Google Calendar, Google Drive, Google Docs, Google Sheets, Notion, Linear, GitHub) but doesn't recite them.
4. **Fixed last question.** Asks about the user's prior experience with AI agents and which kind (for example a coding agent such as Claude Code or Codex, a computer-use agent, or only chat assistants such as ChatGPT). The answer becomes `agentFamiliarity` (§6.3).
5. **Skip handling.**
   - If the user asks to skip or stop in any words or language, the model gives one short friendly line with no question and calls the realtime tool **`skip_onboarding_interview`**.
   - The client answers `accepted`, or `not_in_interview` ("…nothing to skip") when the user isn't in the interview. The tour then advances automatically, and answers given before the skip are kept.
   - Logged as `onboarding_interview_skipped_by_voice` and "[tutorial] interview skipped by voice after N answers". Label "Skipping the interview" / "Skipped the interview".
   - Leaving a *new-Clicky* interview sends a `[New Clicky interview]` note telling the model the user has exited and that no Clicky should be created.
6. **Requests mid-interview.** The model doesn't act and makes no tool call. It says it will do the request after onboarding and returns to the question.
7. **Wrap.** Three short sentences: a reaction, thanks (using the first name if known), and a mention of the user's most-discussed topic framed as where to begin. No offers, plans or questions. The model never asks for a name or email.
8. **Afterwards.** The transcript is injected into later turns as an `[About the user]` note listing their answers in order. The model is told to let it color reactions without reciting it.

Data: `OnboardingInterviewTranscriptLine{role: user|assistant, text}`. Developer test fixture: `DrawnTourTestInterviews.json` → `RealInterviewFile{interviews:[{lines:[{role,text}]}]}`. Analytics: `clicky_interview_answer_submitted` (`answer_number`, `interview_id`), `has_interview`, `interview_answer_count`, `home_space_new_clicky_interview_started|ended`. The page entry retries if realtime preparation fails ("interview preparation unavailable; page entry will retry").

### 6.3 Starter plan

`POST /onboarding/starter-plan` (`OnboardingStarterPlanClient`). This call is skipped when the user isn't signed in, and retried ("[starter plan] attempt N").
```
Request  { interview: [ {role, text} ], connected_integrations: [str], available_integrations: [str],
           clickys?: [ {slug,name,role,description} ], first_asks_for_clicky?: str, interview_saved?: bool, jobs: bool }
Response { clickys: [StarterClicky], suggested_agents: [SuggestedAgent], agent_familiarity?: str ("new", …), goal_line?: str }
StarterClicky  { key, name, role, description, intro_messages?: [str], reveal_line?: str,
                 routine?: {title, task_prompt, interval_minutes?}, first_asks?: [str] }
SuggestedAgent { title, description, agent_prompt, suggestion_id?: int, clicky_slug?: str, clicky_key?: str,
                 routine?: {title, every_minutes} }
```
OBSERVED: a demo plan JSON embedded for the "new agents UI demo", with three Clickys and three suggested agents. The **reveal** (`OnboardingRevealLineBook`, `OnboardingRevealTurn{brief, lineKey, fallbackLine}`) opens Home in the notch. It introduces each new Clicky using `reveal_line`, explains that Clickys are AI agents with their own memory that work on the Mac, and can be aborted with a double Escape. The starter Clickys go into the roster, and `clicky.starterCast.unlockedByOnboarding.v1` is set. The starter plan's server prompt and logic: UNKNOWN. Slot: **other: plan generator LLM (server)**.

---

## 7. App UI shell

### 7.1 Process and windows

- `LSUIElement = true`: a menu-bar or agent app with no Dock icon by default. The setting "Show in Dock" (`show_in_dock`) switches the activation policy ("Turn off to keep HeyClicky notch only").
- The login item is registered on first launch only ("Registered as login item (first launch only)", `clicky.loginItem.registrationSettled.v1`).
- "Show in screen recordings" (`show_in_screen_recordings`) controls whether HeyClicky windows can be captured. INFERRED: `NSWindow.sharingType`. The app also excludes its own windows from its own screenshots.
- NSPanel subclasses (OBSERVED ObjC class names): `NotchPanel`, `NotchKeyboardFocusReleasePanel`, `OverlayWindow`, `HeyClickyWindow`, `ClickyEdgeShelfPanel`, `PowerUpPanel`, `ClickyDrawingWindowPanel`, `AccountDeletionPanel`, `PreSignInIntroPanel`, `OnboardingTutorialPanel`, `PermissionGuidePanel`, `PaywallInputPanel`, `IntroHatchFlightPanel`, `ResponseCardPanel`, `PinnedCardsPanel`, `ScreenAnnotationPanel`, `HandoffIndicatorPanel`, `HandoffVoiceStopPanel`, `HandoffRegionSelectPanel`, `DictationAnnouncementPanel`, `PlaceDetailPanel` and `DetachedCursorClickPanel`.
- The notch yields to system UI when the window picker or Mission Control is up (`ClickySystemWindowPickerYield.Reason windowPicker|missionControl`). It also avoids system processes such as Spotlight, Control Center and the screenshot UI (`NotchSystemOverlayCoordinator`).

### 7.2 Notch (primary surface)

`NotchWindowManager` keeps one `NotchScreenInstance` per display (`notchInstancesByDisplayIdentifier`). It handles hover dwell, outside-click monitoring, fullscreen-host probing, menu-bar coverage probing (the docked strip must not cover the front app's menus), screen and space changes, and Mission Control.

`NotchPresenter` owns the presentation state:
- **Tabs** (`ClickyNotchTab`): `home | chat | settings | document`. Notch chat state includes `composerDraftText`, `composerDraftAttachmentURLs`, `rememberedPlace` and `documentLeftOnClose`.
- **Chat session.** Opened via `doubleControl | composerClick | chatTab | fileDrag | fileDrop | send`. Closed by `escape | doubleControl | clickElsewhere | dragAbandoned | leftChatTab | notchFolded | drawingCaption | unspecified`. File drag onto the notch opens a composer with attachments.
- **Activity phases** (`NotchActivityPhase`): `listening | thinking | speaking | docked | dictation(label, isRecording) | agentMulti(count) | custom(label)`.
- **Live events** (`NotchLiveEvent`), which show as transient surfaces:
  - `activityListening/Thinking/Speaking`, `activityCustomStatus(label)`
  - `dictation(label,isRecording)`, `dictationCopiedToClipboard(title)`, `dictionaryWordLearned(word)`
  - `voiceReplyMutedCopiedToClipboard(title)`, `microphoneTrouble(title, subtitle, showsSettingsAction)`
  - `agentTask`, `agentMultiActivity(longestLabel,count)`, `agentPeek(listContentHeight)`
  - `handoffSent(target)`, `handoffQueued(count)`
  - `documentFolderAccessDenied`
  - `appUpdated(version)`
  - `meetingCountdown(title, startsAt, hasJoinAction)`
  - `clickyUpdate(railKey, kind: needsYou|failed|done)`
  - `clickyDriveConsent(id)`, `clickyDriving`
  - `onboardingTutorialInvite`, `onboardingTutorialResume(showsContinueButton)`
  - `integrationConnected(displayName,useCases,logoURL)`, `integrationSuggestion`, `sidecarLearningSuggestion`
  - `spotifyVoiceTip`, `skillPinned(count)`
  - `morningSuggestions`, `introHatchPeek`, `introSkillPing`
  - `restingMark(isCursorDocked)`, `dockedIdle`
- **Peek surface** (`NotchHeyClickyPeekSurface`): plan pill, "Connected apps / Connect apps", "Monthly usage" ring (agent and voice; "unlimited voice"), "Update app" and "Upgrade" buttons.

### 7.3 Home (HomeSpace)

The Home tab in the notch (`HomeSpaceViewModel.activePage: suggestions | settings`) shows:
- **Clickys** (roster cards with portrait packs and a character editor).
- **Jobs** working and finished, with artifact cards (`HomeSpaceArtifactCards`, thumbnails).
- **Drawings** (saved lessons with an inline player).
- **Suggestions page**: proactive agent ideas.

Suggestions flow (`ProactiveAgentsClient`; paths OBSERVED, composition INFERRED):
1. `POST /proactive-agents` sends `{connectedIntegrationNames, recentAgentSuggestions:[{title,description,status,hoursAgo,denyReason?}], checkReason, clickys:[{slug,name,role,description,routines:[{title,everyMinutes}],threadIDs}], customConnectors, researchOnlyForGoodMorning, readsForMorningPaper, existingRoutines}`.
2. It polls `…/jobs/{id}` → `{jobID, status: queued|running|succeeded|failed, suggestedAgents, error, breakUntil, curatedEvidence, morningHeadline, morningHeadlineLine}`.
3. Then it calls `…/invitation-claim`, `…/resolution` and `/suggestions/statuses`.
4. Suggestions resolve as `approved | denied | expired | replaced`. A denial can carry a reason ("Not now because…").
5. UI copy: "Looking for fresh ideas. This can take 5–10 minutes.", "Want me to do it?", "Adjust" (a voice adjustment turn), "No thanks."
6. The daily morning invitation (`MorningSuggestionsInvitationPolicy` with `dismissedDays`, `restingUntil`) is announced through the morning notch. It is gated by "Suggest agent tasks" (`suggest_agent_tasks`, "every 24 hours").

Slot: **other: suggestion generator (server LLM, reads connected apps)**.

### 7.4 Chat and agent windows

- **Notch chat** (`NotchHeyClickyChatView`) renders `HeyClickyConversationHistory` messages and `HeyClickyChatHandOffs` rows. Features: live work cards with plan steps, follow-up pills, a "sites read" chip, full-reply expansion, "Read aloud", and paging of earlier messages.
- **HeyClickyWindow** is a standalone resizable window (`HeyClickyWindowController`/`Model`). Its sidebar groups `working | recents | earlier` entries, one per Clicky or job. It has a conversation column (`HeyClickyWindowRow.Kind`: `dateSeparator | sent | sentFiles | reply | files(threadID) | footer(duration, finishedAt, copyText) | note | typing`), a composer with attachments and drag-drop, a document viewer and a settings host. It opens with a flight animation from the notch (`HeyClickyWindowOpeningFlight`).
- **Agent dashboard.** The realtime tool `open_agent_dashboard` (action `open`/`close`) opens or closes Home (label "Opened Home"). Background jobs appear as cards on a right-edge dock ("arc" deck, `ClickyEdgeShelf`/`ClickyEdgeDeck`). The Agent HUD offers "Follow up by voice".
- **Agent notifications.** `GET /agent/notifications?limit=20` → `{notifications:[{id, source_type, source_id?, run_id?, title, summary, severity: info|success|warning|error, read_at?, created_at}]}`. Also `POST /agent/notifications/{id}` (mark read; INFERRED) and `/agent/notifications/read-all`.

### 7.5 Recent drawings windows

`ClickyDrawingWindowViewer` presents a saved drawing in a `ClickyDrawingWindowPanel`. It replays `program.js` with narration and can record to video (`ClickyDrawingVideoRecorder`, `isRecording`). Pinned cards (`PinnedCardsPanel`) keep drawing cards at the screen edge. The `ClickyDrawingSaveOffer` hosting view offers "Save drawing" (bookmark icon) for recent drawings. Drawings can also be removed from the chat while staying in Drawings.

### 7.6 Settings and model pickers

`HomeSpaceSettingsSection`: `account | general | referral | voice | microphone | dictation | shortcuts | cursor | agents | routines | integrations | developer`. The sidebar has a "HEYCLICKY" group and an "INTERNAL" group; developer is internal (INFERRED to be gated by `ClickyDeveloperPreviewAccess`). Contents:

| Section | Contents (OBSERVED copy and keys) |
|---|---|
| Account | Plan card ("You're on the Free plan", Pro/Max, team), usage, Manage subscription / Fix payment / View your team, Sign in with Google, Log out, Delete account, Quit |
| General ("Behavior") | Show in Dock, Show in screen recordings, Updates (Check for updates, Install & Relaunch, What's new / changelog), Community (WhatsApp, Reddit), Support (Request a feature, Report a bug), Welcome tour replay |
| Voice | Voice list ("VOICES" / "MORE VOICES"): OpenAI realtime voices (alloy, ash, ballad, cedar, coral, echo, marin, sage, shimmer, verse), Gemini voices (achernar … zubenelgenubi), and persona previews (bright, bubbly, cheerful, expert, fun, gentle, hope, kid, lumen, original, polished, smooth, techy). Speech speed (`voice_speed`), "Speak to me in" languages (automatic or pinned), captions toggle (`screen_drawing_voice_captions`) |
| Microphone | Input device, "Test microphone" |
| Dictation | Language (`dictation_language`, `auto_detect_language`), Dictionary (up to 50 words, `dictation_dictionary`) |
| Shortcuts | `ClickyShortcutSlot`: `voiceHold`, `textTrigger`, `dictationHold`, `handsFreeDictation`. Trigger kinds `holdCombo` and `doubleTapModifier`. Modifiers control/option/command/shift/function. The recorder rejects combos that are already used. |
| Cursor | Cursor color (`cursor_color`, sets the accent color), "Hide floating cursor" (`dock_cursor`) |
| Agents | Agent folder (`agent_folder`, `uses_custom_folder`), Autonomy ("Auto-approve extra usage", `auto_approve_extra_usage`), Announcements (`agent_voice_announcements`, `agent_cursor_text_announcements`), "Suggest agent tasks", "What agents can reach" (`AgentPermissionsInspector`: Contacts, Calendar, Reminders, Photos, Files & Folders, and Automation targets Notes, Mail, Messages, Music, Safari, Chrome, Finder, System Events, Terminal, Keynote, Pages, Numbers, TextEdit, Preview) |
| Routines | List with Run now / Pause / Delete, last-run status, "Paused after N failed runs". Routines run only while the Mac is awake and HeyClicky is open. |
| Integrations | Search, connected rows with accounts and labels, "Available integrations", Custom connectors (add, edit, sign in, remove), Obsidian, Chrome connection |
| Invite & Earn | Referral page. **Out of scope.** |
| Developer | Previews and debug tools (§7.7) |

### 7.7 Developer section and model picker

- **One brain model** (`ClickyOneBrainModelKey`). The enum is `sol | solMedium | solFast | solUltrafast | solUltrafastMedium | solUltrafastHigh | terraFastMedium | haiku | sonnet | opus | deepSeekMedium | deepSeekHigh`. Option ids include `gpt-6.1-sol`, `gpt-6.1-sol-medium`, `gpt-6.1-sol-fast`, `gpt-6.1-sol-ultrafast`, `gpt-6.1-sol-ultrafast-medium`, `gpt-6.1-sol-ultrafast-high`, `gpt-6.1-terra-fast-medium`, `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`, `deepseek-v4.1-flash-medium` and `deepseek-v4.1-flash-high`. Each option has a one-line description with relative cost and speed. The default is "GPT-6.1 Sol at medium effort on Ultrafast". Claude and DeepSeek are marked experimental, "Not tuned for one brain", and DeepSeek has "No connected-app reads or drive".
- **Agent harness** (`ClickyAgentHarnessModel`): harness `h1` (default; the app's own runner or a lab Worker in the cloud) | `pi` (pi-coding-agent) | `codex` (bundled Codex app-server). Place: `mac | cloud` ("On this Mac" / "In the cloud"). Model: `standard` ("Default") | `luna` (`gpt-6-luna`) | `haiku` (`claude-haiku-5-5`). Further keys: `ClickyAgentHarnessDeviceHelperOff` and `ClickyAgentHarnessNoteToolsOff`.
- **Developer chat model** (`ClickyDeveloperChatModel`: `gpt61Sol | gpt6Sol | gpt6Luna | luna | terra | sol | astra`, plus effort). Access is gated by `ClickyDeveloperModelAccess{accountID, sessionToken, expiresAt, isAllowed}`.
- **Toggles:**
  - "Skills in notch"
  - "Upcoming meetings"
  - "Language step in onboarding" (`onboarding_language_step`)
  - "One brain reads apps"
  - "Keep screens in history" (`one_brain_keeps_screens`)
  - "Show one brain stats" (`one_brain_stats_hud`)
  - "Start a fresh session"
  - "Preview HeyClicky drive"
  - "Fetch suggestions now" / "Reset suggestions"
  - "Run welcome-website agent" / "Run SpaceX report agent"
  - Paywall and onboarding previews
- The agent model catalog file (`RES/ClickyCodexModelCatalog.json` → `{models:[{slug, display_name, default_reasoning_level, supported_reasoning_levels, context_window, …}]}`) is covered in the agent-harness doc.

---

## 8. Plans, usage metering (brief), billing and referrals (out of scope)

**Usage metering (keep a minimal version for OpenClicky).**
- `GET /me/plan` → `PlanSnapshot`:
  ```
  { plan: free|unlimited, tier?: free|pro|max, subscription?: {status, current_period_start?, current_period_end?, product_id?, cancel_at_period_end, cancel_at?, billing_interval?: month|year},
    usage: { messages: {used, cap}, agents: {used, cap}, window_resets_at? }, billing_enforcement: on|off,
    unlimited_agents_cap?, pro_agents_cap?, max_agents_cap?, pro_yearly_available?, max_yearly_available?,
    is_fail_open_fallback?, tier_source?, team_name? }
  ```
- Cached per account in `clicky.billing.lastKnownPlanSnapshot.v1.<uuid>`. `BillingStateManager` also tracks `locallyTrackedMessagesUsedThisWindow` and a fail-open mode (`isLocalQuotaGateSuspendedAfterFailOpenRefresh`).
- Two meters: voice/companion "messages" and "agent messages". The UI shows a usage ring and "resets …".
- Each agent turn takes a **turn lease**: `/agent/turn-lease/` with `/continue` and `/status`. The request is `{supports_agent_turn_lease, thread_id?, turn_id, task_id, is_follow_up, launch_source, idempotency_key, extra_usage_auto_approve}` and the response is `{lease_id, turn_id, expires_at?, credits_used, included_credits?, cost_usd?, cost_limit_usd?, requires_extra_effort?, status?}`. There is also `/agent/record-agent-launch`, and `/refund-early-stop` for agents stopped early ("Agent cancelled. This won't count toward your quota.").
- Usage purpose is tagged with `X-Clicky-Usage-Context` and keys `count_usage`, `transcription_usage` and `purpose`.
- The model sees a silent `[Your plan] … Agent messages this period: N used …` note.
- Quota errors arrive as HTTP **402** with a `PaywallPayload{reason: quotaExceeded|paymentProblem, surface: messages|agents|dictation, title, body, cta_label, price_display, current_usage, limit, reset_at?, plans?, yearly_savings_label?, default_interval?}`. The notification name is `com.humansongs.clicky.paywallDetected`.

**Out of scope for OpenClicky:**
- Stripe checkout and portal (`/billing/checkout`, `/billing/portal`, discount codes) and the `checkout-complete` deep link.
- Plan pricing copy (Pro $20/mo, Max $100/mo, yearly discounts).
- `AgentPaywallHUD`.
- The referral program (`/me/referral`, `/me/referral/claim`, `/me/referral/code`, earnings and payouts).

---

## 9. Analytics (PostHog)

- PostHog iOS/macOS SDK (`PostHog_PostHog.bundle`). Config keys: `PostHogAPIKey` (value omitted) and `PostHogHost` = `https://us.i.posthog.com`. The EU hosts appear only as SDK constants.
- Integrations enabled include app lifecycle, screen views and error-tracking autocapture (`PostHogErrorTrackingAutoCaptureIntegration`). It is backed by **PLCrashReporter** (`PLCrashReporter_CrashReporter.bundle`; "PLCrashReporter enabled successfully").
- `ClickyAnalytics` is the app-side event facade. Common properties: `app_version`, `app_build`, `is_debug_build`, `product_event_version`, `clicky_platform`, `clicky_device_key`, `interaction_context_version`, `input_method`, `input_surface`, `home_space_presentation`, `notch_was_expanded`.
- Representative events in this subsystem:
  - **App and notch:** `app_opened`, `notch_first_shown` (context `preSignInIntro|onboarding|postOnboarding`), `notch_expanded`/`collapsed` (trigger `hover|onboardingPin|introWelcomeAutoPin`), `notch_files_dropped`.
  - **Settings:** `setting_changed` (with `analyticsKey` from each toggle row).
  - **Messages and agents:** `user_message_sent` (source `voice|text|suggestedAction|retry`; route `assistant|codexAgent|handoff`), `agent_started` / `agent_finished` / `agent_followed_up` (source `voice|text|suggestedAction|proactiveSuggestion|retry|routine`; with `integrations_used` and `used_computer_use`).
  - **Integrations:** `integration_*`, `integration_suggestion_*`.
  - **Proactive:** `proactive_agent_recommended|approved|denied|unactioned|held`.
  - **Onboarding:** `onboarding_*`, `permission_*`.
  - **Billing:** `paywall_*`, `checkout_*`.
  - **Updates and bugs:** `update_found|install_clicked|install_completed`, `bug_report_submitted`.
  - **Routines and Clickys:** `clicky_routine_*`, `clicky_created|archived|restored|pin_changed`.
  - **Errors:** `app_error` (`RecentAppError{timestampISO8601, stage, kind, errorMessage, errorDomain?, errorCode, userFacingMessage}`).
- **LLM tracing** (`ClickyAITracing`): `$ai_generation`, `$ai_span` and `$ai_trace` events with `$ai_trace_id`, `$ai_session_id`, `$ai_span_name`, `$ai_provider`, `$ai_model`, `$ai_input`, `$ai_output_choices`, `$ai_input_tokens`, `$ai_output_tokens`, `$ai_latency`, `$ai_is_error`, `$ai_error`, plus `clicky_mode` (`normal_companion|agent_thread`) and `clicky_agent_thread_id`. The trace ids are mirrored into the `X-Clicky-Trace-Id` / `X-Clicky-Session-Id` / `X-Clicky-Distinct-Id` headers so server spans join up.
- PostHog feature flags and remote config come from the SDK. App-level link config is separate (§12).

## 10. Crash reporting and diagnostics

- **Sentry** `Sentry.framework` 8.58.1 with Info.plist `SentryDSN` (value omitted). It includes SentryCrash, ANR tracking, MetricKit and session-replay code paths from the SDK. Which options are enabled is UNKNOWN; they are set in code with short literals.
- **PostHog error tracking** also runs, with PLCrashReporter for symbolication (`PLCrashReporterSymbolicationStrategy`).
- **Bug report** ("Report a bug — Sends diagnostics along so we can actually fix it."):
  1. `ClickyDiagnosticsReport` gathers app state (`clicky_state`), display info, and recent unified logs. `ClickyDiagnosticsLogCapture` runs `/usr/bin/log` with a timeout.
  2. It POSTs `/report-error` with `user_email`, `supabase_user_id`, `error_code`, `error_message` and a `user-bug-report` kind.
  3. A Gmail compose link to the support address is the fallback.

## 11. Auto-update (Sparkle)

- `Sparkle.framework` 2.9.6. Info.plist: `SUFeedURL` = `https://farzaa.github.io/clicky-releases/appcast.xml`, `SUEnableAutomaticChecks` = true, `SUAutomaticallyUpdate` = true, `SUScheduledCheckInterval` = 3600 s, `SUPublicEDKey` (EdDSA signing key; value omitted).
- `SparkleUpdateDelegate` (an `SPUUpdaterDelegate`) feeds `ManualUpdateCheckState` (`idle | checking | upToDate | foundUpdate | failed`) into Settings. Settings shows "Check for updates", "Version X is available to download", "…is ready. Installing relaunches HeyClicky." and "Install & Relaunch".
- "Keep Sparkle update check timer alive" (INFERRED: a process-activity assertion so the hourly timer survives App Nap).
- After an update, the notch shows `appUpdated(version)` (`NotchAppUpdatedSurface`) and a changelog link.
- Analytics: `update_found` (`from_version`, `to_version`), `update_install_clicked`, `update_install_completed`, `check_for_updates_clicked`, `changelog_opened`.

## 12. Remote config

`GET /app-config` → `{appConfig: {links: {featureRequest, communityReddit, communityWhatsApp, changelog}}}`, cached in `ClickyAppRemoteConfigV1`. The built-in fallbacks are the Canny feature-requests URL, the Reddit and WhatsApp community URLs, and `https://heyclicky.com/changelog?p=mac`.

---

## 13. Server routes in this subsystem

| Route | Purpose | Carries model choice? |
|---|---|---|
| `/auth/start` (Worker) | Begin Google sign-in through Supabase | no |
| `{Supabase}/auth/v1/user`, `/auth/v1/token?grant_type=refresh_token` | User fetch / token refresh | no |
| `/me/devices` | Device registration | no |
| `/me/discovery-channel` | Save the onboarding "where'd you hear" answer | no |
| `/me/account/delete` | Delete account | no |
| `/app-config` | Remote links config | no |
| `/agent/integrations` (+ `/{id}/connect`, `/{id}/disconnect`, `/{id}/accounts/{acct}/label`, `/{id}/accounts/{acct}/disconnect`) | Composio catalog and connection management | no |
| `/agent/composio/session` | MCP proxy URL and toolkits for agents | no |
| `/agent/realtime/google-calendar/events`, `/events/create` | Voice calendar tools | no (INFERRED) |
| `/agent/realtime/spotify/search` | Resolve a track URI | no |
| `/me/calendar/upcoming` | Meeting countdown feed | no |
| `/me/memory` (GET), `/me/memory/save` | User memory profile read / save | no |
| `/me/companion-history` | Paged main-chat history | no |
| `/clickys/organize-history` | LLM grouping of old threads into Clickys | no (server LLM) |
| `/skills/library`, `/skills/programs`, `/skills/create`, `/skills/creations`, `/skills/{slug}` (+ `/publish`, `/unpublish`, `/share-to-team`, `/unshare-from-team`), `/skills/activations/sync` | Skill library | no |
| `/onboarding/starter-plan` | Interview → starter Clickys and suggested agents | no (server LLM) |
| `/onboarding/language-hints` | Language suggestions in onboarding (OBSERVED path only) | no |
| `/proactive-agents` (+ `/jobs/{id}`, `/invitation-claim`, `/resolution`), `/suggestions/statuses` | Proactive suggestions and the morning brief | no (server LLM) |
| `/agent/notifications?limit=20`, `/agent/notifications/{id}`, `/agent/notifications/read-all` | Agent notification feed | no |
| `/me/plan` | Plan and usage snapshot | no |
| `/agent/turn-lease/{id}/continue`, `/status`; `/agent/record-agent-launch`; `/refund-early-stop` | Agent usage metering | no |
| `/report-error` | Bug and error reports | no |
| `/billing/checkout`, `/billing/portal`, `/me/referral*` | **Out of scope** | no |

---

## 14. Model slots for this subsystem

| Feature | Slot | Required capabilities |
|---|---|---|
| Brain reads connected apps (`read_connected_apps`) | **brain** + **other: app-connector MCP** | Image input, tool calling, and remote MCP tools (or local MCP bridging), read-only enforcement per turn |
| Realtime voice tools `google_calendar_*`, `play_on_spotify`, `save_memory`, `recall`, `forget_memory`, `skip_onboarding_interview`, `open_agent_dashboard`, `save_drawing` | **voice** (realtime speech model with function calling) | Function calls with JSON arguments, mid-session context updates (skill updates, notes), interruption |
| Onboarding interview | **voice** | Long system instructions, per-turn developer notes, one tool (`skip_onboarding_interview`) |
| Starter plan, proactive suggestions, history organizer, skill creation from a brain dump | **other: server planning LLM** | Structured JSON output. Suggestions also need connected-app reads and web research. |
| Memory consolidation (session-end note, profile markdown) | **other: memory-writer LLM** | Summarization into a sectioned markdown profile |
| Agents using integrations and skills | **agent** | MCP client (remote HTTP + stdio), skills directory, per-account tool arguments |
| Spotify search, calendar find/create | none (plain API proxies) | n/a |

---

## 15. Permissions and entitlements relevant here

- Entitlements (OBSERVED, `codesign -d --entitlements`): app sandbox **off**, `cs.allow-jit`, `device.audio-input`, `device.camera`, `network.client`, plus a mach-lookup exception for `com.apple.screencapturekit.picker`.
- Usage descriptions: microphone, speech recognition, screen capture, and Desktop/Documents/Downloads folders.
- TCC at runtime:
  - Accessibility: needed for the integration suggestion monitor, notch focus and text insertion.
  - Screen Recording and screen content.
  - Automation (Apple Events), per target: Spotify for `play_on_spotify`; Notes, Mail, Messages and others for agents.
  - Contacts, Calendars, Reminders and Photos when agents ask for them.
- Network: localhost listeners for custom-connector OAuth callbacks and the harness runner (`127.0.0.1`).

## 16. Edge cases the client clearly handles

- Composio not configured on the backend, signed out, connected apps unreachable at agent start: the agent is told the apps *are* connected and must not ask for reconnects. A pending run may be retried "in a few minutes".
- An OAuth return that yields no new account, OAuth still syncing, expired accounts, the account cap reached, and per-account labels.
- Integration changes during a live voice session, during prewarm, or during always-on: the session is marked stale or restarted.
- A custom connector's keychain write fails ("Unlock your login keychain…"), the loopback port is busy, the OAuth state doesn't match, the user cancels, or sign-in times out. Servers that don't support dynamic client registration ask for a token or a client id instead.
- Spotify: no query and no URI, not signed in, search soft failure, Spotify not running (cold launch via URL), AppleScript failure (URL fallback), post-play verification.
- Interview: skip in any language, a skip request when not in the interview, task requests mid-interview, a page entry before realtime is ready (retry), a voice answer versus a typed answer.
- Memory: no server profile yet (inject nothing), fetch failure (fall back to cache), cache keyed per account.
- OneBrain thread: invalid JSON is not saved, a stale compaction result is dropped, a session changing mid-turn (sign-out or switched account) is not kept.
- Skills: an imported file that isn't markdown, is unreadable or is empty. A skill update with no live session is deferred to the next mint.
- Sparkle checks fail ("Couldn't check for updates just now").

---

## 17. Rebuild plan (OpenClicky modules)

Swift package targets. Names are suggestions; boundaries follow the observed responsibilities.

1. **`OCAuth`**
   - `AuthSession` (Keychain-backed tokens, refresh with failure classification, per-account id), `SignInCallbackGuard` (state plus expiry), `URLSchemeRouter` (`openclicky://auth-callback`, `integrations-auth-callback`, `browser`).
   - Provider-agnostic: Supabase or any OIDC.
2. **`OCBackendClient`**
   - Typed HTTP client with bearer auth and standard headers (platform, device, version, trace).
   - 402 → `PaywallPayload` detection. Kept even without billing, to surface quota errors.
3. **`OCIntegrations`**
   - `IntegrationCatalogService`: list, connect, disconnect, label, using the data models in §3.1 and the connection state machine with the active-account baseline.
   - `ConnectorProvider` protocol, so OpenClicky can plug in Composio, its own OAuth broker, or MCP-only connectors.
   - `AgentAppsSession`: fetches `{proxyURL, toolkits, multiAccountToolkits, expiresAt}`, caches until expiry, retries with backoff, and yields `.connected | .unreachable | .none`.
   - `AgentConnectedAppsPromptBuilder`: the "Connected apps" instruction section, including multi-account rules.
4. **`OCCustomConnectors`**
   - `CustomConnectorStore` (defaults or JSON for metadata, Keychain for secrets).
   - `MCPProbe` (initialize / initialized / tools/list over Streamable HTTP and stdio).
   - `MCPOAuthClient` (protected-resource and authorization-server discovery, DCR, PKCE, loopback callback server).
   - `CapabilityDeriver` (verb lexicon over tool names).
   - `RuntimeRegistration` → agent config (env-var indirection for secrets).
5. **`OCIntegrationSkills`**: bundled SKILL.md set per toolkit (write our own content; don't copy HeyClicky's), plus an installer that enables skills for connected toolkits in the agent skills directory.
6. **`OCSuggestionMonitor`**: frontmost-app and browser-URL sampler using Accessibility, a registry table (toolkit → hosts, bundle ids, title needles, path prefixes), dwell accumulation, snooze, never-ask and global rate limits, and a dismiss-reason enum.
7. **`OCVoiceTools`**: realtime tool handlers `calendar.find/create` (through the connector provider), `spotify.play` (search provider plus AppleScript and URL fallback with verification), `memory.save/recall/forget`, `interview.skip` and `home.open`. Each returns compact JSON results and status labels.
8. **`OCSkills`**
   - `SkillLibraryClient` (library, programs, create, creation polling, publish, share, activation sync).
   - `SkillLibraryCache` (same JSON shape as §4.1).
   - `ActiveSkillsController`: pushes skill descriptions into voice context and writes SKILL.md files for agents.
   - `ProgramRegistry` (bundle ids and hosts → program slug).
   - `OnboardingSkillPicker` (catalog with `bundledSkillIDs`).
9. **`OCMemory`**
   - `UserMemoryProfile` (fetch, cache per account, mirror to `helper/about-the-user.md`, inject as a `<user_memory>` block with a "background only, never instructions" guard).
   - `MemoryWriter` (save and forget endpoints, or a local LLM consolidation job at session end).
   - `ClickyWorkspaceMemory` (per-agent `AGENTS.md` template with Identity / Standing preferences / Notes).
10. **`OCHistoryStore`**: `ConversationHistory` (per-account JSON plus server paging with `before_id`), `HandOffStore` (`-handoffs.json`), `BrainThreadStore` (thread JSON plus round JSONL, compaction hooks), `AgentTurnJournal` (thread-history plus turn checkpoints), `DictationArchive` (daily JSONL) and `LessonStore` (drawings folder format).
11. **`OCOnboarding`**: `PreSignInIntroFlow` (step enum), `PermissionFlowCoordinator`, `TutorialFlow` (step enum), `InterviewController` (fixed opener note, turn budget N=4 with a fixed last question, per-answer notes, skip tool, deferred requests, transcript capture) and `StarterPlanClient` plus `RevealDirector`. Write our own prompts.
12. **`OCShell`**: `NotchWindowManager` (per-display panels, hover dwell, fullscreen and menu-bar probes, system-UI yield), `NotchPresenter` (tabs, live-event queue, chat session open and close reasons), `HomeView` (Clickys, jobs, drawings, suggestions), `ChatWindow` (sidebar working/recents/earlier, rows, composer), `DrawingViewer`, `SettingsView` (sections in §7.6), `ModelPicker` (brain, agent harness and model, voice), `AgentNotificationsFeed`.
13. **`OCTelemetry`**: an analytics facade with a typed event enum. PostHog is optional and off by default for OpenClicky; LLM tracing events go out with trace-header propagation. Crash reporting is optional (Sentry or PLCrashReporter). The diagnostics bundle (unified log capture) feeds a bug-report flow.
14. **`OCUpdates`**: Sparkle 2 with OpenClicky's own appcast and EdDSA key, an hourly check, a manual check state machine, and a post-update notch notice.
15. **`OCUsage`** (minimal): local counters for voice turns and agent turns, an optional server plan snapshot, and a turn-lease interface stub. Billing and referrals are excluded.

---

## 18. Open questions

- The exact JSON argument and response schemas of the realtime and brain tools (`save_memory`, `recall`, `forget_memory`, `google_calendar_*`, `play_on_spotify`, `read_connected_apps`). They are defined server-side.
- The HTTP verbs and query parameter names for the integration, skills and proactive routes, which are short inline literals.
- The interview turn count N. I inferred 4, but it is interpolated.
- Integration suggestion dwell thresholds and rate limits.
- The algorithm behind `user_layer_signature`.
- How the server builds the memory profile, and what `recall` searches.
