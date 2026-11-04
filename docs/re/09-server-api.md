# 09 — HeyClicky server API surface and Codable shapes

Status: clean-room behavioural spec, reconstructed statically from HeyClicky 1.1.2 (build 69, git branch `changelog/v1.1.2`). No live traffic was captured and no HeyClicky server was contacted.

Scope: every network interaction the client makes. That covers the HeyClicky "Worker" at `https://api.heyclicky.com`, Supabase auth, the provider endpoints the client reaches directly with server-minted ephemeral credentials (OpenAI Realtime, Gemini Live), the agent runtimes' calls (Codex CLI, `clicky-harness`), and third-party SDK traffic (PostHog, Sentry, Sparkle). For each route the doc gives the method, path, auth, request and response key sets, streaming format, which call carries or decides a model choice, the OpenClicky typed slot that replaces it, and whether OpenClicky should replace, reimplement locally, or drop it.

Sibling docs go deeper on the client behaviour behind these calls: `02-voice-pipeline.md` (ears, one-brain turn, mouth), `06-agent-harness.md` (Codex/H1, leases, jobs), `07-browser-bridge.md`, `08-apps-memory-ui.md` (skills, memory, suggestions, billing UI). Where this doc and a sibling differ on a verb or path, this doc's evidence is function-level (see §0.2) and should win. The corrections are listed in §13.

---

## 0. Conventions and method

### 0.1 Evidence legend

- **OBSERVED [O]**: seen in an artifact. The path and identifier are cited.
- **INFERRED [I]**: my reasoning from observed facts.
- **UNKNOWN [U]**: the client can't answer it, for example server prompts, server-side routing, or exact upstream providers.

Artifact abbreviations:

- `BIN` = `Contents/MacOS/HeyClicky`, arm64 slice. Function anchors such as `fn@0x102db2d5c` are arm64 VM addresses of function starts (from `LC_FUNCTION_STARTS`).
- `HAR` = `Contents/Helpers/clicky-harness` (a Bun single-file executable). Its bundled JS is visible in `strings`.
- `PLIST` = `Contents/Info.plist`.
- `CAT` = `Contents/Resources/ClickyCodexModelCatalog.json`.
- `DATA` = `~/Library/Application Support/Clicky`.

### 0.2 How routes and shapes were recovered

1. **String dump.** `strings -n 6` of the arm64 slice (109k strings) gave route literals, header names, snake_case JSON keys and log lines.
2. **Function-level string xrefs [O].** A small scanner walked `__text` for `ADRP`+`ADD` pairs that resolve into `__cstring`. It also handled Swift large-literal addressing (string address minus 0x20) and linker tail-merged suffixes. It bucketed each reference by function start. This ties every route literal to the HTTP verb literal (`"POST"`, `"GET"`, `"PATCH"`, `"DELETE"`, `"HEAD"`), headers and JSON keys used in the same function or its async continuations. When a request-building function contains no verb literal, the verb is the `URLRequest` default, `GET` [I].
3. **Swift reflection metadata [O].** `__swift5_fieldmd` was parsed into type → field lists, including the cases of every `CodingKeys` enum. CodingKeys case names are Swift names. The wire names are their snake_case raw values: for almost every networked type, the snake form exists verbatim in `__cstring`. The exceptions are noted inline. For example, `AppRemoteConfig` is camelCase on the wire.
4. **The user's own data [O]** for file formats and live values: `DATA/CodexHome/config.toml`, `DATA/OneBrain/**`, `DATA/AgentHarness/h1-local/**`. No secret values were read into this doc. `auth.json` and `BrowserBridge/connection.json` were inspected for key names only.

Limitation: hand-built dictionaries that use very short keys sometimes leave no unique literal. Those keys are marked [I] or [U] and appear in the traffic checklist (§11).

---

## 1. Hosts and base URLs

| Host / URL | Configured by | Used for | Evidence |
|---|---|---|---|
| `https://api.heyclicky.com` | `PLIST WorkerBaseURL`, `PLIST CodexWorkerBaseURL` (both the same value) | Every HeyClicky product route (the "Worker") | [O] `PLIST`; log prefixes "Worker /agent/realtime/session…", "billed by the Worker" |
| `https://mrpvynsdsnimuisyhkow.supabase.co` | `PLIST SupabaseURL` + `SupabaseAnonKey` | GoTrue auth only: `/auth/v1/user`, `/auth/v1/token?grant_type=refresh_token` | [O] `fn@0x102e81c30`, `fn@0x102e8ba5c` |
| `wss://api.openai.com/v1/realtime?model=<m>` | hard-coded | Realtime speech session ("mouth" / full voice) with a Worker-minted ephemeral secret | [O] `fn@0x102db5cf8` `openWebSocketSession(ephemeralSessionToken:modelIdentifier:)` |
| `https://api.openai.com` (HEAD) | hard-coded | DNS/TLS pre-warm before opening the realtime socket | [O] `fn@0x102db24ec`, `fn@0x1022adb58` |
| `https://api.openai.com/v1/models` (GET) | hard-coded | Diagnoses region or network blocking when voice fails | [O] `fn@0x102d810dc` `RealtimeProviderAvailabilityDiagnosis` |
| `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained` | hard-coded | Gemini Live streaming STT (ears + dictation) using a Worker-minted ephemeral token | [O] `fn@0x1015f9280` (`OneBrainGeminiTranscriber.swift`) |
| `https://generativelanguage.googleapis.com` (HEAD) | hard-coded | Pre-warm for dictation | [O] `fn@0x102155160` |
| `https://api.anthropic.com/v1/messages` | `PLIST AnthropicMessagesURL` | `ElementLocationDetector`: direct Claude computer-use call (`x-api-key`, `anthropic-beta: computer-use-2025-11-24`, tool `computer_20251124`) | [O] `fn@0x102700444`. The key source is UNKNOWN. No key ships in the bundle, so the path is probably dormant or developer-only [I] |
| `https://api.openai.com/v1/chat/completions` | `PLIST OpenAIChatCompletionsURL` | `OpenAIAPI.swift`: direct chat-completions with images (`model`, `max_completion_tokens`, `messages`) | [O] `fn@0x1029f0004`. The class has an `apiKey` field. The caller is UNKNOWN, probably dormant [I] |
| `https://us.i.posthog.com` (also eu, `*-assets`) | `PLIST PostHogHost`/`PostHogAPIKey` | Product analytics, feature flags, surveys, error tracking, LLM-analytics `$ai_generation` events | [O] SDK strings `/batch`, `/flags`, `/config`, `/array/` |
| `*.ingest.us.sentry.io` | `PLIST SentryDSN` | Crash and error reports | [O] |
| `https://farzaa.github.io/clicky-releases/appcast.xml` | `PLIST SUFeedURL` | Sparkle updates, hourly (`SUScheduledCheckInterval` 3600), EdDSA-signed | [O] |
| `stream.mux.com/*.m3u8` | hard-coded | Hosted intro, onboarding and paywall videos | [O] |
| `icons.duckduckgo.com/ip3/<host>.ico` | hard-coded | Favicons | [O] `fn@0x102c890e0` |
| `https://team.heyclicky.com`, `heyclicky.com/changelog`, canny, reddit, WhatsApp, Chrome Web Store | hard-coded or `/app-config` | Links opened in the browser | [O] |
| `http://127.0.0.1:<port>` | runtime | Local only: harness runner, loopback MCP, browser bridge, custom-connector OAuth callback | [O]. Not server traffic; see §4.15 |

Notes:

- **Deepgram is absent [O].** A case-insensitive search for `deepgram`, `nova-3`, `/deepgram-token` and `/transcribe` finds nothing in `BIN`, `HAR` or `ClickyBrowserHost`. Those routes in the brief belong to an older build. In 1.1.2, streaming STT is Gemini Live, with Worker batch STT and Apple Speech as fallbacks.
- **No Supabase data API [O].** There are no `/rest/v1/`, `/rpc/`, `/storage/v1/` or `/functions/v1/` strings. Supabase is used only for identity (GoTrue). All product data goes through the Worker. Supabase tables or RPCs, if any exist behind the Worker, are UNKNOWN.
- **The Worker** is called exactly that throughout the logs ("Worker returned an unparseable URL", "billed by the Worker"). The name suggests a Cloudflare Worker [I]. The server's upstreams are UNKNOWN beyond these hints:
  - log strings name OpenRouter (`Worker /v2/chat upstream OpenRouter`), Anthropic (`Worker /chat upstream Anthropic`) and Brave (image search: "Brave returned N results");
  - `HAR` names Exa (web search mode `"exa"`);
  - `/agent/composio/*` implies Composio;
  - `place-photo`'s `photo_name` looks like a Google Places photo resource [I].

---

## 2. Authentication

### 2.1 Sign-in (Supabase GoTrue via the Worker) [O]

1. The app makes a random `state`, persists `PendingSignIn{state, startedAt}` (`clickyPendingGoogleSignIn.v1`), and opens `WorkerBaseURL + /auth/start?state=…` in the browser (`fn@0x102e74168`). The Worker drives Google OAuth through Supabase [I].
2. The browser returns to `clicky://auth-callback…` or `heyclicky://auth-callback…` (`PLIST CFBundleURLSchemes`; router `fn@0x10280555c`). The tokens arrive as `access_token` / `refresh_token` in the fragment or query (`#`, `?`, `&`, `=` parsing in `fn@0x102e76aac`, `fn@0x102e7fd4c`). Error parameters are `error`, `error_code` and `error_description`, with `access_denied` meaning the user cancelled ("Google sign-in was canceled…").
3. `ClickySignInCallbackGuard.Verdict` decides whether to accept the callback:
   - `accept`;
   - `acceptLocalDevelopment` (hosts `localhost`, `127.0.0.1`, `::1`, `*.localdev`);
   - `refuseNoSignInStarted`, `refuseSignInExpired`, `refuseMissingState`, `refuseStateMismatch`.

   Analytics reports the verdicts as `accepted`, `accepted_local_development`, `no_sign_in_started`, `sign_in_expired`, `missing_state` and `state_mismatch`.
4. The user id comes from the JWT `sub` claim. Then `GET {SupabaseURL}/auth/v1/user` with headers `apikey: <anon>` and `Authorization: Bearer <access>` returns `{id, email, user_metadata{full_name|name, avatar_url|picture}}`.
5. Keychain items: `supabaseAccessToken`, `supabaseRefreshToken`, `supabaseUserId`, `supabaseUserEmail`, `supabaseUserDisplayName`, `supabaseUserAvatarURL`, `supabaseSignupDate` (service `SupabaseAuth` / `com.humansongs.clicky`). There is migration telemetry (`keychain_token_migration`) and sign-out cleanup retries (`clickySignOutPendingKeychainCleanup`).

**Refresh.** `POST {SupabaseURL}/auth/v1/token?grant_type=refresh_token`, header `apikey`, body `{refresh_token}` → `{access_token, refresh_token, …}` (`fn@0x102e8ba5c`/`fn@0x102e8c6c8`).

- **Fatal errors** (sign the user out) are classified by substring: `invalid_grant`, "invalid refresh token", "refresh token not found", "revoked", "already used", "reuse detected", "session not found".
- **Transient errors** keep the cached session and retry later: "Auth recovery failed; keeping cached Supabase session…". There is an `accessTokenRefreshRetryCooldown`.
- A 200 response without `access_token` is its own error (`http_200_without_access_token`).

### 2.2 Worker bearer [O]

Nearly every Worker route sends `Authorization: Bearer <Supabase access JWT>`.

- The Worker verifies the JWT itself. The client mirrors its error strings: `invalid jwt`, `bad_jwt`, `unrecognized jwt kid`, `unable to parse or verify signature`, `authentication required`, `http 401`.
- On a 401, several callers force-refresh the Supabase token and retry once. Examples: "session mint rejected the bearer (401); retrying once with a force-refreshed Supabase token" and "Anthropic chat auth failed, retrying with refreshed Supabase token".
- Routes sent without the bearer [O: no `Authorization` literal in the builder]:
  - `/report-error`;
  - `stock-quote` (`StockQuoteAPI` has no auth-manager field);
  - `/billing/checkout` and `/billing/portal`. Their builders set only `Content-Type`; the bearer may be added by `BillingClient` elsewhere [I].

### 2.3 Agent session token [O]

`POST /agent/session-token`, body `{}`, Supabase bearer → `{token, expires_at, capabilities, developer_model_selection}` (`fn@0x102085e30`, parser `fn@0x1020866f4`).

- The token is a separate backend credential for agent runtimes:
  - Codex gets it as `OPENAI_API_KEY` (env) with `model_providers.clicky.base_url = https://api.heyclicky.com/agent/openai/v1`. `DATA/CodexHome/auth.json` holds only the keys `auth_mode` and `OPENAI_API_KEY`.
  - `clicky-harness` gets it as `worker.sessionToken`.
  - The Codex `composio` MCP server uses it via `bearer_token_env_var = "OPENAI_API_KEY"`.
- Also exported to agents: `CLICKY_WORKER_BASE_URL`, `GEMINI_API_KEY` (value source UNKNOWN; probably the same token for Worker-proxied image tools [I]) and `OBSIDIAN_VAULT_PATH`.
- Rotation: when the token rotates while tasks run, the app logs "rotated while N task(s) were in flight — keeping the stale subprocess alive". It restarts Codex at the next idle moment.
- `developer_model_selection` gates `ClickyDeveloperModelAccess{accountID, sessionToken, expiresAt, isAllowed}`. Only allowed accounts can choose the agent model (§5).

### 2.4 Ephemeral provider credentials minted by the Worker [O]

| Credential | Minted by | Used against |
|---|---|---|
| OpenAI Realtime client secret | `POST /agent/realtime/session` → `client_secret.value` (+ `session.model` / `model`) | `wss://api.openai.com/v1/realtime?model=<model>` with `Authorization: Bearer <secret>` |
| Gemini Live access token | `POST /brain/ears/token` or `POST /v2/dictation/gemini-token` → `{access_token, setup, receipt}` | Gemini `BidiGenerateContentConstrained` WebSocket (constrained = ephemeral-token endpoint). The `Token ` + `Authorization` literals sit next to `access_token` [O]; whether the token goes in the header or the `access_token` query parameter is UNKNOWN |
| Dictation receipt | `receipt` from the Gemini token mint | `X-Clicky-Dictation-Receipt` header on `/v2/dictation/cleanup` and `/v2/dictation/transcribe`. A 401 on a receipt-authed call retries with the bearer |

So voice audio never transits the Worker on the main paths. The Worker only mints the credential, and for OpenAI also fixes the session configuration (instructions, tools, voice) server-side [I: the client sends only turn detection and noise reduction in `session.update`, `fn@0x102dc09c4`].

---

## 3. Common conventions

### 3.1 Headers [O]

| Header | Value | Where |
|---|---|---|
| `Authorization` | `Bearer <Supabase JWT>`, or `Bearer <agent session token>` (agent runtimes), or `Bearer <ephemeral>` (OpenAI WS) | all |
| `Content-Type` | `application/json` | POST/PATCH bodies |
| `Content-Encoding: gzip` | only after the server opts in with response header `x-clicky-accepts-gzip: 1` | `/brain/*` (`fn@0x101524a48`, `fn@0x101857bb8`) and `HAR` model calls (gzip level 4, bodies ≥ 8 KiB) |
| `X-Clicky-Platform` (`macos`), `X-Clicky-Device`, `X-Clicky-App-Version`, `X-Clicky-App-Build`, `X-Clicky-OS-Version` | device identity | built in `fn@0x101cd1914`; written into Codex `http_headers` [O `DATA/CodexHome/config.toml`]; INFERRED to be attached to Worker calls generally |
| `X-Clicky-Usage-Context` | `companion` \| `agent_chat` \| `clicky_creation` \| `onboarding` (enum `ClickyUsageContext`) | `/brain/turn`, `/brain/ears/*`, `/chat-tool-call`, `/agent/realtime/turn`, `/agent/realtime/session`, `/codex-thread-launch`, `/agent/record-agent-launch`, `/skills/creations`, dictation |
| `X-Clicky-Distinct-Id`, `X-Clicky-Session-Id`, `X-Clicky-Trace-Id`, `X-Clicky-Mode` (`normal_companion` \| `agent_thread`), `X-Clicky-Agent-Thread-Id` | PostHog LLM-analytics correlation | `fn@0x101c14f4c`. The client also emits `$ai_generation` events with `$ai_trace_id` / `$ai_session_id` (`fn@0x101c15d3c`) |
| `X-Clicky-Dictation-Receipt` | receipt from the token mint | dictation |
| `apikey` | Supabase anon key | Supabase only |

**Device key.** It is derived from `IOPlatformUUID` with the prefix `heyclicky-device:`, giving 32 hex characters. The fallback is the UserDefaults key `clicky.device.fallbackKey.v1`. The hash function is UNKNOWN; an MD5-style or truncated SHA digest of the prefixed UUID is likely [I].

### 3.2 JSON conventions

- **Casing.** Wire keys are snake_case, as explicit `CodingKeys` raw values [O]. The exceptions:
  - `/app-config` uses camelCase (`appConfig`, `featureRequest`, `communityReddit`, `communityWhatsApp`, `changelog`);
  - `/runtime/model-policy` returns `codexAgentLane`, `model`, `reasoningEffort`;
  - `/runtime/tool-policy` returns `toolPolicy.enabledRootTools`;
  - Spotify search returns `albumUri` and `artistUri`;
  - realtime and chat-tool-call screenshots use `screenshotBase64`, `mimeType`, `screenshotWidthInPixels` and `screenshotHeightInPixels`;
  - higher-model responses use `annotationText`, `agentHandoff`, `clickyOffer`, `clipboardText` and `awaitsUserContinuation`.
- **Dates** are ISO-8601 strings (`created_at`, `expires_at`, `next_run_at`, …) [I from `String` field types].
- **Error envelope** is `{error, code?, message?}` [O keys]. Examples: `{"error":"not_signed_in"}`, `{"error":"upstream","status":N,"body":…}` and `{"error":"no_http_response"}`. The realtime tool forwarder synthesises these for the model (`fn@0x10238cea4`).

### 3.3 Status semantics [O]

| Status / code | Client behaviour |
|---|---|
| 401 | Refresh the Supabase token, retry once. Then "it seems like you got logged out…" |
| 402 / body with `paywall` | Paywall card from `PaywallPayload{reason: quota_exceeded\|payment_problem, surface: messages\|agents\|dictation, title, body, cta_label, price_display, current_usage, limit, reset_at, plans:[PaywallPlanOption{key: pro\|max, name, price_display, agents_cap, tagline, cta_label, recommended, yearly_price_display, yearly_billed_summary}], yearly_savings_label, default_interval: month\|year}` (`fn@0x102b50d34`) |
| 429 | "You're asking me a lot right now. Give me a minute, then try again." |
| `app_update_required`, `agent_turn_lease_required` | "Please update HeyClicky to keep using Agent Mode." |
| `agent_extra_effort_required` | Pause the agent and ask the user to approve extra usage |
| `clicky_openai_backend_key_invalid`, `clicky_upstream_auth_error` | "Agents stopped working. Contact HeyClicky support plz" |
| `screenshot_files_unavailable` (in `/brain/turn`) | Stop sending screenshots by reference for the rest of the session |
| `provider_region_unsupported` / `provider_blocked_by_network` with `provider_name`, `client_location_name` | Voice explains that the region or network blocks the provider (`RealtimeProviderUnavailableReason`) |

---

## 4. Route catalog

Column "Slot" uses OpenClicky's typed slots: `stt`, `voice`, `brain`, `agent`, `other:<name>`. Column "OC" gives OpenClicky's disposition:

- **REPLACE**: a user-provided provider fills the slot.
- **LOCAL**: reimplement as an on-device service.
- **DROP**: not needed.

All Worker paths are relative to `https://api.heyclicky.com`.

### 4.1 One-brain voice turn (the default hold-to-talk brain)

| Method | Path | Request | Response | Slot | OC |
|---|---|---|---|---|---|
| POST | `/brain/turn` | Gzip-able JSON (see below). Headers include `X-Clicky-Usage-Context` | **SSE** stream: `data: {json}` lines with a `type` | brain | REPLACE |
| POST | `/brain/prewarm` | `{session_id, user_layer, user_layer_signature, thread, canvas{w,h}, async_tools, brain_model, app_reads, figures_float, library_items, routines_tool, find_jobs_tool, saves_drawings, drive}` | ack [U] | brain (prompt-cache warm) | LOCAL (provider cache warm where supported) |
| POST | `/brain/compact` | `{thread, session_id, input_tokens}` | `{note_item, drop_leading_items, keep_from_index, keep_leading_items}` or `{tokens_until_fold}` or `{reason}`/`{error}` | brain (summariser) | LOCAL (compaction with the brain model) |
| POST | `/brain/session-end` | `{session_id, thread, screenshot_files}` | ack [U] | other:memory-writer | LOCAL (end-of-session memory note) |

Evidence: the route table is in `fn@0x101524b10`. The turn builder is `fn@0x101855ddc` (`turn_token`, `turn`, `input`, `text`) with gzip in `fn@0x101857bb8`. The body builder is `fn@0x10167cf44`. The SSE parser is `fn@0x101859dcc`. Compaction is `fn@0x10167871c`/`fn@0x1016789ec`; session end is `fn@0x10167a338`. Reply type: `OneBrainClient.Reply{code, computerCalls, spokenSentence, items, searchRecords, toolCalls, userLayer, modelIdentifier, firstTokenMilliseconds, totalMilliseconds, costUSD, usage, keepsReasoning, turnToken, userLayerSignature, guidedMaxRounds, screenshotFile}`.

**Request body** [O keys; nesting I]. The client holds the whole conversation and sends it every turn. The server is stateless per turn except for the files and tokens it hands back.

- `session_id`: a UUID per brain session.
- `thread`: an OpenAI **Responses-API item list**. Item types:
  - `message` with role `developer` / `user` / `assistant` and content parts `input_text`, `input_image`, `output_text`;
  - `reasoning` with `encrypted_content` and `summary`;
  - `function_call` (`call_id`, `name`, `arguments`) and `function_call_output` (`call_id`, `output`);
  - `computer_call_output`.

  Screenshots already uploaded are referenced as `{"type":"input_image","clicky_file":"file-…"}` instead of base64 [O `fn@0x10166549c`]. The persisted copy is `DATA/OneBrain/<uid>/threads/<session>.json` = `{session_id, last_turn_at, user_layer, user_layer_signature, user_layer_skills, thread[], drawing_code[], last_input_tokens, baseline_input_tokens, canvas[w,h], environment_sent}` [O].
- `turn{…}`: the current user turn (words, screenshot, front app, page context and so on; see `02-voice-pipeline.md` §5.4). `turn_token` echoes the previous round's token for tool-result rounds.
- Capability flags: `async_tools`, `app_reads`, `figures_float`, `library_items`, `routines_tool`, `find_jobs_tool`, `saves_drawings`, `drive`. They tell the server which tools the client can run [I].
- `brain_model`: **the client's model choice** (§5).
- `user_layer` + `user_layer_signature`: a server-built, server-signed per-user prompt layer. The client caches it and echoes it so the server can skip rebuilding it [I]. The `meta` event returns it.

**SSE events** (`type` field) [O]:

- `meta{model, user_layer, user_layer_signature, guided_max_rounds, drive_lease_id}`;
- `text{text}`: the drawing program streams as text, and `say("…")` lines are extracted;
- `status{kind}`;
- `items{items[]}`: Responses items to append to `thread`;
- `search_record`;
- `tool_call{call}` / `tool_calls{calls[]}`;
- `computer_calls{calls[]}`;
- `done{cost, keep_reasoning, turn_token, screenshot_file, message_recorded, message_refunded, drive_messages_refunded, usage…}`;
- `error{code, message}`.

The local log `DATA/OneBrain/<uid>/<session>.jsonl` records each round's usage as:

```
{turn_token, reported_model, input, cached, wrote, output, reasoning, last_input,
 cost, ttftMs, totalMs, fastServed, webSearches, keep_reasoning, screenshot_file,
 message_counted, message_recorded, turn_saved}
```

[O]. In the user's 32 rounds, `reported_model` was always `gpt-6.1-sol`.

- `turn_token` is an opaque server-signed compact token: base64url JSON payload plus signature. Its payload carries version, user, session, round and time fields [O shape; value not reproduced]. It lets the server tie tool-result rounds to one billed user message [I].
- `screenshot_file` ids look like OpenAI Files ids (`file-…`) [O]. So the server uploads the screenshot to its provider and hands back a reference [I].

### 4.2 Speech-to-text (ears and dictation)

| Method | Path | Request | Response | Slot | OC |
|---|---|---|---|---|---|
| POST | `/brain/ears/token` | `{language, keyterms[]}`; header `X-Clicky-Usage-Context` | `{access_token, setup, receipt}` | stt (credential mint) | REPLACE (stt provider's own auth) |
| POST | `/v2/dictation/gemini-token` | `{language, keyterms[]}` | `{access_token, setup, receipt}` | stt | REPLACE |
| WS | Gemini `BidiGenerateContentConstrained` | client: `setup` (the server-supplied blob) → `realtimeInput{audio{data(base64 PCM16), mimeType:"audio/pcm;rate=<hz>"}}`, `realtimeInput{activityStart}` / `{activityEnd}` (manual push-to-talk activity) | server: `setupComplete`, `serverContent{inputTranscription{text}}`, `interimInputTranscription`, `turnComplete`, `goAway` | stt | REPLACE |
| POST | `/brain/ears/transcribe` | `{audio_wav_base64, language}` | `{text}` | stt (batch fallback) | REPLACE |
| POST | `/v2/dictation/transcribe` | `{audio_wav_base64, audio_seconds, context, language, known_terms}` + `X-Clicky-Dictation-Receipt` | `{text}` | stt (batch) | REPLACE |
| POST | `/v2/dictation/cleanup` | `{transcript, audio_seconds, context{app_name, site_host, before_text, selected_text, after_text, single_line}, fast_cleanup, stt_ms, stt_provider, known_terms?}` + receipt header | `{text}` | other:text-cleanup LLM (small, fast, text-only) | REPLACE (brain slot in text-only mode, or a dedicated fast model) |

Evidence: the token request is `fn@0x101601540`/`fn@0x101602460` (`language`, `keyterms`). The mint response is `fn@0x101603374` (`access_token`, `setup`, `receipt`). Batch ears is `fn@0x101685b70`. The dictation client is `fn@0x1026ef6a0`–`fn@0x1026f6828`. The routes are in `fn@0x102148e88`–`fn@0x1021491d0`.

`OneBrainGeminiTranscriber{tokenProxyURL, languageCode, keyterms, readyGraceSeconds, finalTimeoutSeconds}` serves both features; only the token URL differs. Fallbacks:

- Gemini refuses for billing or quota reasons (`credit`, `billing`, `quota`, `exhausted`, `prepayment`, `payment`) → "using the fallback for 10 minutes" [O].
- Streaming fails → batch WAV upload.
- The legacy path uses Apple Speech (`AppleSpeechTranscriptionProvider`).

**Model choice:** none from the client. The Gemini model is fixed inside the server-minted `setup`/token [I].

### 4.3 Speech output ("mouth") and full-voice realtime

| Method | Path | Request | Response | Slot | OC |
|---|---|---|---|---|---|
| POST | `/agent/realtime/session` | `RealtimeEphemeralSessionRequest{voice, speed, prompt_context, client_capabilities}`; the builder also references `one_brain_mouth` (a purpose flag when the session only speaks the brain's lines [I]); header `X-Clicky-Usage-Context` | `{client_secret{value}, session{model}}`, with `model` possibly at top level [O keys `client_secret`, `value`, `session`, `model` in parser `fn@0x102db3948`] | voice (realtime) | REPLACE |
| WS | `wss://api.openai.com/v1/realtime?model=<from mint>` | client events: `session.update` (`type:"realtime"`, `audio.input.turn_detection{type:"server_vad", threshold, prefix_padding_ms, silence_duration_ms, create_response, interrupt_response}`, `noise_reduction{type: near_field\|far_field}`), `input_audio_buffer.append\|commit\|clear`, `conversation.item.create\|delete\|truncate{item_id, content_index, audio_end_ms}`, `response.create`, `response.cancel` | `session.created\|updated`, `input_audio_buffer.speech_started\|speech_stopped\|committed`, `response.created`, `response.output_audio.delta` / `response.audio.delta`, `response.output_audio_transcript.delta`, `response.output_text.delta`, `conversation.item.input_audio_transcription.delta\|completed`, `response.function_call_arguments.delta\|done`, `response.done` (usage: `input_token_details{cached_tokens, text_tokens, audio_tokens, image_tokens}`, `output_tokens`, `total_tokens`), `response.cancelled`, `error` | voice | REPLACE |
| POST | `/agent/realtime/speak` | One line per request: `{voice, text}`, or `{voice, update, instructions}` for a paraphrased status, plus `languages` (see `02` §7) | **Streamed** Gemini-Live-style messages: `serverContent` with audio, then `turnComplete`; or `{error, message}` (`fn@0x102de5c34`) | voice (TTS, model `gemini-3.8-flash-lite-tts`) | REPLACE |
| POST | `/agent/realtime/voice-preview` | `{voice, language}` | WAV bytes (`RIFF`), cached at `Clicky/VoicePreviews/<voice>.wav` | voice (TTS) | REPLACE (or bundle static previews) |
| HEAD | `/agent/realtime/warmup` | none | none | none | DROP (keep a generic pre-connect) |
| POST | `/agent/realtime/turn` | `{messages[{role, content}], prompt_profile, response_model_selection:"standard", count_usage, usage{model, purpose:"one_brain_mouth", provider:"gemini"\|…, transcription_usage}}` | [U] | other:usage-metering | DROP (log locally) |

Evidence: session `fn@0x102db2d5c`, socket `fn@0x102db5cf8`, `session.update` `fn@0x102dc09c4`, speak `fn@0x102dea4a0`, preview `fn@0x102eb466c`, warmup `fn@0x1022adb58` and `fn@0x102ddf6e8`, realtime turn `fn@0x1022d39c8` (bodies `fn@0x1022d1d50`, `fn@0x1022d2da8`).

**Prompt context keys** (`RealtimeSessionPromptContext`):

```
connected_integrations, needs_reconnect_integrations, explicit_agent_follow_up_target{codex_thread_id, title},
prior_message_count, time_zone, current_local_datetime, voice_gender,
active_skills[{display_name, one_liner, blurb, description, built_for}], dictation_hold_shortcut,
onboarding_tutorial, custom_connectors[{name, description}],
connected_integration_accounts[{integration, accounts[{connected_account_id, account_name, label}]}]
```

**Model choice:** the Worker decides the realtime model and returns it; the client only puts it into the socket URL (analytics key `realtime_model_from_mint`).

- Model ids in `BIN`: `gpt-realtime-2.1` (full voice) and `gpt-realtime-2.1-mini` (one-brain mouth context).
- Voice choice: the client sends `voice` and `speed`. OpenAI voices are `alloy, ash, ballad, cedar, coral, echo, marin, sage, shimmer, verse`. Gemini voices are 30 names, from `achernar` to `zubenelgenubi`, selected as `gemini:<Name>` (`RealtimeVoiceProvider` = `openAI|gemini`).
- If the Gemini mouth fails, "the next session speaks in the OpenAI voice" for 10 minutes [O].

**Pre-warm.** `HEAD https://api.openai.com` and `HEAD /agent/realtime/warmup` warm DNS and TLS. A session can be opened "ahead of the first press" [O].

### 4.4 Realtime tool backends (full-voice tool calls forwarded to the Worker)

The full-voice OpenAI model calls tools whose schemas are defined server-side in the minted session [I; schemas UNKNOWN]. The dispatcher table `fn@0x102251bd0` maps tool names to Worker paths. The generic forwarder `fn@0x10238c6d0` POSTs the tool's JSON arguments with the bearer and hands the raw JSON response (or a synthesized error) back to the model as the tool output.

| Tool | Method / path | Body | Response | Slot | OC |
|---|---|---|---|---|---|
| `send_to_higher_model` (and guided follow-ups, annotations, attachments) | POST `/chat-tool-call` | see below | see below | brain | REPLACE |
| `web_search` | POST `/web-search` | tool args (`query`, …) [I] | answer JSON [U] | other:web-search | REPLACE (search provider, or brain with hosted search) |
| `save_memory` | POST `/me/memory/save` | tool args [U] | `{status, …}` [U] | other:memory | LOCAL |
| `google_calendar_find_events` / `google_calendar_create_event` | POST `/agent/realtime/google-calendar/events`, `/agent/realtime/google-calendar/events/create` | tool args + `timeZone` | [U] | other:integrations | LOCAL (via MCP/Composio or EventKit) |
| `play_on_spotify` | POST `/agent/realtime/spotify/search` | `{query}` | `{track{uri, name, artists, albumUri, artistUri}}` or `{error, message}` (`fn@0x1023bde9c`) | other:music-search | LOCAL (Spotify Web API with the user's token, or an AppleScript search) |

Other tools in the same table run on the client: `insert_text`, `runtime_status`, `open_url`, `copy_to_clipboard`, `open_agent_dashboard`, `sessions_*`, `routines`, `clicky_memory`, `clicky_artifacts`, `save_drawing`, `open_artifact`, `reveal_artifact`, `skip_onboarding_interview`, `capture_screen`, `read_connected_apps`, `tutorial_draw_on_screen`, `find_jobs`. A tool-call cap per turn is enforced client-side ("tool_limit_reached").

**`POST /chat-tool-call`** ("higher model") [O `fn@0x1022e9858`, `fn@0x1022ed2e4`, `fn@0x10227a3f8`, `fn@0x10227b410`; parser `fn@0x10230c264`]:

- Request:

  ```
  query, currentUserText, currentMessageTimestamp, history[], guided_follow_up | guided_session,
  annotation_gesture, annotation_elements, active_skills,
  screenshots[{screenshotBase64, mimeType:"image/jpeg", screenshotWidthInPixels, screenshotHeightInPixels}],
  previous_screenshots[], userAttachedImages[], frontmost_app_bundle_id, frontmost_browser_host,
  environment, clipboard_copy, agent_handoff, clickys, connected_integrations, clicky_offers,
  recent_agent_suggestions, client_capabilities
  ```
- Response:

  ```
  text, annotationText, widgets[{kind: places|images|stock, payload}],
  agentHandoff{task, label, clicky_slug, new_clicky},
  walkthrough{…, awaitsUserContinuation}, point{x, y, element, screen},
  typing{text, x, y, screen}, clipboardText,
  clickyOffer{title, description, agent_prompt, spoken_line, suggestion_id}
  ```
- The client then returns a summary to the realtime model: `{status:"ok", answer, widgets_shown, visual_guidance_shown, visual_count, target_armed, cursor_animated, text_typed, copied_to_clipboard, delivery_refused, app_spoken_guidance, clicky_offer}`.
- **Model choice:** none sent; the server picks the "higher model". The log prints "higher-model route …" from the response [I].

### 4.5 Legacy streaming chat (text companion, onboarding demo)

| Method | Path | Request (`ClaudeProxyChatRequest`) | Response | Slot | OC |
|---|---|---|---|---|---|
| POST | `/chat` (`ClaudeSSEFormat.anthropic`) or `/v2/chat` (`openAICompatible`, upstream OpenRouter) | `{prompt_profile: voice_companion\|text_companion\|onboarding_demo\|onboarding_tutorial_draw, response_model_selection ("standard"), user_prompt, images[{base64_image_data, image_label, image_media_type: image/png\|image/jpeg}], open_router_custom_model?, open_router_verbosity?, is_provider_fallback_retry}` | **SSE**: Anthropic events (`message_start`, `content_block_start`, `content_block_delta`/`text_delta`, `server_tool_use`) or OpenAI-compatible deltas ending `[DONE]`, plus HeyClicky events `clicky_tool_start{tool_name}`, `clicky_widget{widget_kind: places\|images\|stock, payload}`, `clicky_error{message}` | brain | REPLACE |

Evidence: `fn@0x101bf107c`–`fn@0x101bf5de8`. The client also sends `HEAD /` to the base as a pre-connect (`fn@0x101bf2ebc`).

**Model choice:** `response_model_selection` and `open_router_custom_model` are the model selectors in this path.

### 4.6 Widget data services

| Method | Path | Request | Response | Slot | OC |
|---|---|---|---|---|---|
| POST | `image-search` (appended to the base) | `{query, limit, subject_photo, page_url}` | `{images[{thumbnail_url, full_url, source_url, title}]}` | other:image-search (upstream Brave [I]) | REPLACE (search API key) |
| POST | `place-search` | `{query, limit}` | `{places[{id, name, address, latitude, longitude, rating, user_rating_count, primary_type, photo_name, photo_names, website_url, phone_number, google_maps_url}]}` | other:places | REPLACE (Places API key or MapKit `MKLocalSearch`) |
| POST | `place-photo` | `{photo_name, max_height_px}` | image bytes [I] | other:places | REPLACE |
| POST | `stock-quote` (no bearer) | `{ticker, range}` | `{ticker, company_name, current_price, change_absolute, change_percent, day_high, day_low, previous_close, as_of, sparkline_closes[], start_price, range}` | other:market-data | REPLACE |
| GET [I] | `/favicon?host=<h>&sz=64` | query | image | none | LOCAL (DuckDuckGo icons or a page fetch) |

Evidence: `ImageSearchAPI` `fn@0x10274c63c`, `PlaceSearchAPI` `fn@0x102bb4da0`, `StockQuoteAPI` `fn@0x102e61e0c`, favicon `fn@0x101a62bb4` (the base for `/favicon` is INFERRED to be the Worker).

### 4.7 Background agent (Codex app-server and `clicky-harness` H1)

**Model transport** (called by the agent runtimes, not by Swift):

| Method | Path | Caller | Body | Slot | OC |
|---|---|---|---|---|---|
| POST | `/agent/openai/v1/responses` (streaming SSE) | Codex CLI (`wire_api = "responses"`), `HAR` H1 | OpenAI Responses request. `model` comes from `config.toml` (`gpt-6-luna`, effort `high`) or from the H1 mapping. `metadata` carries `clicky_agent_turn_lease_id`, `clicky_agent_turn_id`, `clicky_agent_thread_id`, `clicky_agent_task_id`, `clicky_harness:"h1"`, optional `clicky_effort_step_down:"1"`, `clicky_developer_model` / `clicky_developer_reasoning_effort` | agent | REPLACE |
| POST | `/agent/openai/v1/responses/compact` | `HAR` | `{model, input, tools?, prompt_cache_key?, reasoning?, metadata?}` | agent | REPLACE (or local summariser) |
| POST | `/agent/harness/model/anthropic/v1/messages` (SSE, `anthropic-version: 2023-06-01`) | `HAR` when the model is `claude-haiku-5-5` | Anthropic Messages | agent | REPLACE |
| GET / POST | `/agent/web-search` | `HAR` | GET probe → `{available:true}` selects mode `exa`, otherwise `hosted` (4 s timeout). POST `{query, count(1–10, default 8), freshness?}` (15 s timeout) | other:web-search | REPLACE |
| `*` | `/agent/harness/lab/h1/jobs…`, `/agent/harness/lab/h1/probe?url=` | `HAR` with `place:"cloud"` | Cloud job API (`06` §5.4). `cfg{model, effort:"medium", web, instructions, cacheKey, mcp, workspace, timezone, instance:"standard-2", limits{maxSteps:120, wallMs:1800000, bashTimeoutS:300}, env, tunnel, …}` [O `DATA/AgentHarness/h1-local/*/job.json`] | agent (cloud) | DROP (keep local runs only) |
| `*` | `{composio proxy_url}` and `{base}/mcp/<name>`, `{base}/mcp/device` | Codex / `HAR` MCP clients | MCP streamable HTTP, bearer = session token | other:integrations | LOCAL |

**App-side agent bookkeeping (Swift):**

| Method | Path | Request | Response | Slot | OC |
|---|---|---|---|---|---|
| POST | `/agent/session-token` | `{}` | `{token, expires_at, capabilities, developer_model_selection}` | none (auth) | DROP (use the user's key) |
| POST | `/codex-thread-launch` | `CodexThreadLaunchRequestBody{user_prompt, is_fresh_thread, launch_source}` | `{spoken_start_cue, text_start_cue, title}` | other:fast-labeler (server-side Haiku per logs "Haiku launch-labels") | REPLACE (small fast LLM, or brain) |
| POST | `/codex-thread-title` | `{user_prompt, names_in_use[]}` | `{title}` | other:fast-labeler | REPLACE |
| POST | `/agent/record-agent-launch` | `CodexAgentTurnLeaseRequestBody{supports_agent_turn_lease, thread_id, turn_id, task_id, is_follow_up, launch_source, idempotency_key, extra_usage_auto_approve}` [I pairing] | `CodexAgentTurnLeaseResponseBody{lease_id, turn_id, expires_at, credits_used, included_credits, cost_usd, cost_limit_usd, requires_extra_effort, status}` | other:metering | DROP |
| GET | `/agent/turn-lease/{id}/status` | none | lease (as above). Polled; `status` ∈ `completed\|failed\|interrupted\|…` | other:metering | DROP |
| POST | `/agent/turn-lease/{id}/continue` | `{extra_usage_approval: one_time\|as_many_as_needed}` | lease | other:metering | DROP |
| POST | `/agent/turn-lease/{id}/complete` | `{status, thread_id}` | ack | other:metering | DROP |
| POST | `/agent/turn-lease/{id}/refund-early-stop` | `{}` | `{refunded, reason}` | other:metering | DROP |
| POST | `/agent/turn-lease/{id}/continue-after-computer-use-consent` | `{}` | `{continued, reason}` (`no_computer_use_request` and others) | other:metering | DROP |
| POST | `/agent-messages` | `{thread_id, role, content, is_follow_up, is_demo, is_proactive, proactive_suggestion_id}` | ack | other:server-log | DROP |
| GET | `/me/memory` | none | `{markdown, has_profile}`, injected into agent briefs as a `<user_memory>` block and cached in UserDefaults `ClickyCachedUserMemoryMarkdown_<uid>` | other:memory | LOCAL |
| GET | `/runtime/model-policy` | none | `{codexAgentLane, model, reasoningEffort}`: the Worker's proxy lane for agent turns | agent (policy) | LOCAL (settings) |
| GET | `/runtime/tool-policy` | none | `{toolPolicy{enabledRootTools[]}}`: which root tools the loopback MCP exposes (`shell_exec`, `file_read`, `file_write`, …) | other:policy | LOCAL |

Evidence: `fn@0x102085e30`, `fn@0x102090cec`, `fn@0x10206b9a0`, `fn@0x1020e4dd0`, `fn@0x1020f0a1c`, `fn@0x1020f5808`, `fn@0x1020fb818`, `fn@0x102160adc`, `fn@0x1020f93e4`, `fn@0x10209495c`, `fn@0x1020dd45c`, `fn@0x101c0d394`/`fn@0x101c0e198`, `fn@0x101d570f8`/`fn@0x101d577a8`; `HAR` strings `H1_RESPONSES_URL`, `H1_ANTHROPIC_URL`, `H1_WEB_SEARCH_URL`.

### 4.8 Integrations (Composio)

| Method | Path | Request | Response (Codable) | OC |
|---|---|---|---|---|
| GET | `/agent/integrations?limit=1000` | none | `AgentIntegrationsResponse{composio_configured, integrations[AgentIntegration{id, display_name, description, use_cases, status, connected_count, total_count, toolkits[AgentIntegrationToolkit{slug, name, logo, status, is_connected, connected_account_id, auth_config_id, auth_config_is_composio_managed, categories[{slug,name}], tools_count, triggers_count}], accounts[AgentIntegrationAccount{connected_account_id, account_name, label, avatar_url?, account_name_kind, status, connected_at}]}], next_cursor}` | LOCAL |
| POST | `/agent/integrations/{id}/connect` | none / `{}` | `{redirect_url, connection_request_id, toolkit, integration_id}`. The app opens `redirect_url`; the browser returns to `heyclicky://integrations-auth-callback` | LOCAL |
| POST | `/agent/integrations/{id}/disconnect` | optional `{connected_account_id}` | `{ok, deleted_account_ids, integration_id, toolkits}` | LOCAL |
| POST | `/agent/integrations/{id}/accounts/{account}/label` | `{label}` | ack | LOCAL |
| POST | `/agent/composio/session` | none | `AgentComposioMCPSessionResponse{enabled, reason, proxy_url, expires_at, toolkits, multi_account_toolkits[{toolkit, accounts[{connected_account_id, account_name, label}]}]}`. `proxy_url` becomes `[mcp_servers.composio] url` in Codex `config.toml`. Retried with backoff ("fetch attempt N failed …; retrying in Xs") | LOCAL |

Evidence: `fn@0x101f9acc4`, `fn@0x101f9d510`, `fn@0x101fa0054`, `fn@0x101fa25fc`, `fn@0x101fa3e70`, `fn@0x101faae08`, `fn@0x101fac358`. Local-only integrations (Obsidian vault; custom MCP connectors with OAuth on a localhost `/callback`) never touch the Worker [O].

Slot: **other:integrations**. OpenClicky should host MCP connectors locally, optionally backed by a user-supplied Composio API key.

### 4.9 Remote Tasks (server crons) and agent notifications

| Method | Path | Response | OC |
|---|---|---|---|
| GET | `/agent/cron/list` | `{crons[ScheduledAgentCronSummary{id, name, description, schedule_kind, schedule_expr, timezone, enabled, last_run_at, last_run_status, next_run_at, runs_remaining, created_at}]}` | LOCAL |
| GET | `/agent/cron/{id}` | `{cron{id, name, description, schedule_kind, schedule_expr, timezone, source, source_lang, enabled, next_run_at, last_run_status}, runs[{id, cron_id, status, attempt, started_at, finished_at, duration_ms, result_summary, error, stdout_log, created_at}]}` | LOCAL |
| POST | `/agent/cron/{id}/run-now` | `{run_id}` | LOCAL |
| GET | `/agent/notifications?limit=20` | `{notifications[{id, source_type, source_id, run_id, title, summary, severity, read_at, created_at}]}` (polled) | LOCAL |
| POST | `/agent/notifications/{id}/read` | ack | LOCAL |
| POST | `/agent/notifications/read-all` | ack | LOCAL |

Evidence: `fn@0x101fb0430`, `fn@0x101fb28f8`, `fn@0x101fb14b4`, `fn@0x101fbbefc`, `fn@0x101fbd0f0`, `fn@0x101fbde6c`.

Remote Tasks are **server-executed scheduled scripts** (`source`, `source_lang`, `stdout_log`). "Remote Tasks are not enabled for this account" means the feature is gated per account. Codex edits them through a local stdio MCP named `clicky-crons` (`[mcp_servers.clicky-crons] command = …`), which calls cron APIs that are not visible in `BIN` [U: the create/update/delete routes live in that MCP]. HeyClicky's own routines (`ClickyRoutine`) are already local.

Slot: **other:scheduler**. OpenClicky should fold Remote Tasks into the local routine scheduler plus a local notification store.

### 4.10 Clickys, onboarding, suggestions

| Method | Path | Request | Response | Slot | OC |
|---|---|---|---|---|---|
| POST | `/clickys/organize-history` | `{threads[{thread_id, title, first_ask, last_reply, updated_at, turn_count}], existing_clickys[{slug, name, role, description}], found_from_thread}` | `{clickys[{existing_slug, name, role, description, notes, thread_ids}], leftover_thread_ids}` | brain (text) | REPLACE |
| POST | `/onboarding/starter-plan` | `{interview[{role, text}], connected_integrations, available_integrations, clickys, first_asks_for_clicky, interview_saved, jobs}` | `{clickys[{key, name, role, description, intro_messages, reveal_line, routine{title, task_prompt, interval_minutes}, first_asks}], suggested_agents[{title, description, agent_prompt, suggestion_id, clicky_slug, clicky_key, routine}], agent_familiarity, goal_line}` | brain (text) | REPLACE |
| GET | `/onboarding/language-hints?device_region=<CC>` [I query] | none | `{languages[]}`, normalised locally (`nb`→`no`, `fil`→`tl`, `iw`→`he`, `in`→`id`, `zh-Hans/Hant`) | none | LOCAL (static table) |
| POST | `/proactive-agents/jobs` | `{reports_suggestion_views, connected_integrations, clickys[{slug, name, role, description, routines[{title, every_minutes}], thread_ids}], check_reason, supports_morning_notch, recent_agent_suggestions[{title, description, status, hours_ago, deny_reason}], custom_connectors[{name, description}], local_day ("YYYY-MM-DD"), research_only, brief_style ("good_morning"), routines, jobs}` | job handle [I] | agent (research job) | REPLACE (run as a local agent job) |
| GET | `/proactive-agents/jobs/{id}` | none | `{job_id, status: queued\|running\|succeeded\|failed, suggested_agents[{title, description, agent_prompt, suggestion_id, clicky_slug, new_clicky{name, role, description}, routine{every_minutes, title}, integration}], error, break_until, curated_evidence, morning_headline, morning_headline_line}` | agent | REPLACE |
| POST | `/proactive-agents/invitation-claim` | [U] | `{granted}` | none | LOCAL |
| POST | `/proactive-agents/resolution` | `{suggestion_ids, status: approved\|denied\|expired\|replaced\|viewed\|presented, deny_reason}` | ack | none | LOCAL |
| POST | `/proactive-agents/suggestions/statuses` | `{suggestion_ids}` | `{statuses}` | none | LOCAL |
| POST | `/proactive-agents/<?>` | [U] path not recoverable (builder `fn@0x102d255c8` takes it from its caller) | [U] | n/a | n/a |

Evidence: `fn@0x102029b40`, `fn@0x1029001b4`/`fn@0x102901fa4`, `fn@0x102eaddd8`, `fn@0x102d21214`–`fn@0x102d2bfd0`.

### 4.11 Skills library ("power-ups")

| Method | Path | Request | Response | OC |
|---|---|---|---|---|
| GET | `/skills/library` | none | `LibraryResponse{skills[RemotePowerUpSkill{slug, display_name, author, author_slug, avatar_url, logo_url, blurb, description, tags, category, featured, verified, badges, one_liner, built_for, built_for_program, whats_inside, status, team_shared, is_mine, content, users_count, active_users_count, user_avatar_urls, created_at, creation_duration_ms}], authors[{slug, name, avatar_url, bio, verified}], categories[{id, name}] or [{name, symbol, color}], caller_team}`. Cached in `DATA/SkillLibraryCache.json` | LOCAL (bundled or local skills) |
| GET | `/programs` (prefix not observed) | none | `{programs[{slug, name, bundle_ids, host_suffixes, logo_url}]}` | LOCAL (static) |
| POST | `/skills/create` | `{display_name, one_liner, blurb, content, category, tags, logo_base64, logo_content_type}` | `{skill}` | LOCAL |
| POST | `/skills/creations` (+ `X-Clicky-Usage-Context`) | `{raw_text, display_name}` | `{slug}`; the client polls the library until creation finishes | agent → REPLACE (local agent job writes `SKILL.md`) |
| PATCH | `/skills/{slug}` | same fields as create | ack | LOCAL |
| DELETE | `/skills/{slug}` | none | ack | LOCAL |
| POST | `/skills/{slug}/publish`, `/unpublish`, `/share-to-team`, `/unshare-from-team` | none | ack | DROP |
| POST | `/skills/activations/sync` | `{active_slugs[]}` | `{usage[{slug, users_count, active_users_count, user_avatar_urls}]}` | DROP |

Evidence: `fn@0x101dbca64`, `fn@0x101dcf568`, `fn@0x101dc4c28`, `fn@0x101dc7170`, `fn@0x101dc8d0c`, `fn@0x101dcbae8`, `fn@0x101dcab1c`, `fn@0x101dce734`, `fn@0x101dcc9ac`, `fn@0x101dcd870`, `fn@0x101dd0320`.

### 4.12 Account, profile, history, config

| Method | Path | Request | Response | OC |
|---|---|---|---|---|
| GET | `/me/companion-history?limit=&before_id=` | query | `{messages[{id, role, content, source, created_at}], has_more}`. Cached at `DATA/HeyClickyHistory/<uid>.json` as `{messages, hasEarlierMessages}` | LOCAL |
| GET | `/me/calendar/upcoming` | none | `{connected, events[{id, title, starts_at, ends_at, is_all_day, meeting_url, location, html_link}]}` | LOCAL (EventKit or calendar MCP) |
| POST | `/me/devices` | `{capabilities[voice, dictation, screen_drawing, local_agents, notch], display_name, model ("hw.model")}` (+ device headers) | ack. The client caches `{fingerprint, registeredAt}` in `clicky.device.lastRegistration.v1` to avoid re-registering | DROP |
| POST | `/me/discovery-channel` | `{discovery_channel, discovery_channel_other}` | ack | DROP |
| POST | `/me/account/delete` | `{reason: found_something_better\|privacy_concerns\|too_expensive\|too_buggy\|not_useful\|…, + free text [I]}` | ack; then local wipe (Codex home purge, files to Trash, `tccutil reset`) | LOCAL (a "reset OpenClicky" action without a server) |
| GET | `/app-config` | none | `{appConfig{links{featureRequest, communityReddit, communityWhatsApp, changelog}}}` (camelCase; cached as `ClickyAppRemoteConfigV1`) | DROP |
| POST | `/report-error` (no bearer) | `{stage, error_kind, error_message, error_domain, error_code, user_facing_message, app_version, supabase_user_id, user_email}` | ack | DROP (local diagnostics file) |

Evidence: `fn@0x101136aa0`, `fn@0x101deaa84`, `fn@0x1021412cc`, `fn@0x10215b790`, `fn@0x101b13938`, `fn@0x101ba4554`, `fn@0x101d3c774`.

### 4.13 Billing and referrals (out of scope for OpenClicky)

| Method | Path | Request | Response |
|---|---|---|---|
| GET | `/me/plan` | none | `PlanSnapshot{plan: free\|unlimited, tier: free\|pro\|max, subscription{status, current_period_start, current_period_end, product_id, cancel_at_period_end, cancel_at, billing_interval}, usage{messages{used,cap}, agents{used,cap}, window_resets_at}, billing_enforcement: on\|off, unlimited_agents_cap, pro_agents_cap, max_agents_cap, pro_yearly_available, max_yearly_available, is_fail_open_fallback, tier_source, team_name}` |
| POST | `/billing/checkout` | `{plan, interval, checkout_ui:"web", discount_code?}` | `{url, discount_code_applied}`; the browser returns via `heyclicky://checkout-complete` |
| POST | `/billing/portal` | `{}` | `{url}` |
| GET | `/me/referral` | none | `ReferralProgramSnapshot{…}` (terms, stats, invited friends, monthly earnings, referred_by, `can_claim_friend_code`) |
| POST | `/me/referral/claim` | `{code, source, deep_link}` | `{outcome, message}` |
| POST | `/me/referral/code` | `{code}` | `{outcome, message}` |

Evidence: `fn@0x101bb3af8`, `fn@0x101baa31c`, `fn@0x101baba2c`, `fn@0x101bb6798`, `fn@0x101bb6df8`, `fn@0x101bb79d4`.

The plan can "fail open": when `/me/plan` fails, a local quota gate is suspended (`isLocalQuotaGateSuspendedAfterFailOpenRefresh`). **OC: DROP all of it.** Keep only a local usage and cost ledger (§7).

### 4.14 Third-party SDK traffic (not HeyClicky API)

- **PostHog** (`us.i.posthog.com`): `/batch` events, `/flags` feature flags, `/config` (`/array/<key>/config`) remote config, surveys and exception autocapture. Includes **LLM analytics** `$ai_generation` events: `$ai_model`, `$ai_input`, `$ai_output_choices`, `$ai_input_tokens`, `$ai_output_tokens`, `$ai_latency`, `$ai_trace_id`. **OC: DROP.** Any opt-in telemetry must not upload prompt content.
- **Sentry** envelope uploads; also a PLCrashReporter bundle. **OC: DROP or opt-in.**
- **Sparkle** appcast plus EdDSA-signed updates. **OC:** its own appcast.

### 4.15 Local endpoints (for completeness; not server)

- **Harness runner** on `127.0.0.1:<port>`, bearer `CLICKY_HARNESS_TOKEN`: `POST /turn`, `GET /events?job=&after=&wait=20000` (long poll), `POST /prewarm`, `/steer`, `/cancel`. The runner is `Contents/Helpers/clicky-harness`, running `agent-harness/runner.mjs`. See `06`.
- **H1 local job server** inside the harness: the same `/jobs/*` API as the cloud lab. A cloud job can reach the Mac through a `cloudflared` quick tunnel (`*.trycloudflare.com`, `/t/<key>`, `/health`, `/ready`) for the "device helper" MCP [O `HAR`].
- **Loopback MCP server** (`ClickyLoopbackMCPServer`, protocol `2025-03-26`) and browser-bridge MCP (`[mcp_servers.clicky_browser] url = http://127.0.0.1:<port>/mcp`). See `07`.
- **Custom-connector OAuth**: `http://localhost:<port>/callback`, with RFC 8414/9728 discovery (`oauth-authorization-server`, `oauth-protected-resource`, `registration_endpoint`). It talks to third-party MCP servers directly.

---

## 5. Model choice: which calls carry it and who decides

| Call | Field carrying the choice | Decided by | Observed values |
|---|---|---|---|
| `POST /brain/turn`, `/brain/prewarm` | `brain_model` (request); `meta.model` / `usage.reported_model` (response) | **Client** picks from `OneBrainModelChoice` (UserDefaults `ClickyOneBrainModelKey`, Developer settings); the server maps it to a provider | `gpt-6.1-sol`, `gpt-6.1-sol-medium`, `gpt-6.1-sol-fast`, `gpt-6.1-sol-ultrafast`, `gpt-6.1-sol-ultrafast-medium` (described in-app as "The default"), `gpt-6.1-sol-ultrafast-high`, `gpt-6.1-terra-fast-medium`, `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`, `deepseek-v4.1-flash-medium`, `deepseek-v4.1-flash-high` (OpenRouter) [O `fn@0x101a5a898`]. The user's log reports `gpt-6.1-sol` |
| `POST /agent/realtime/session` | response `session.model` / `model` | **Server** | `gpt-realtime-2.1`, `gpt-realtime-2.1-mini` |
| `POST /agent/realtime/speak` | none observed in the body | Server (the client labels it `gemini-3.8-flash-lite-tts`) | Gemini TTS |
| `POST /chat`, `/v2/chat` | `response_model_selection`, `open_router_custom_model`, `open_router_verbosity`, `prompt_profile`; also the route itself (Anthropic vs OpenRouter) | Client selector, server mapping | `standard` |
| `POST /agent/realtime/turn` | `response_model_selection:"standard"`; `usage.model` is a report, not a choice | Server | n/a |
| `POST /chat-tool-call` | none | Server | [U] |
| `/v2/dictation/cleanup` | `fast_cleanup` (speed tier) | Client flag, server model | [U] |
| Gemini token mints | none (inside `setup`) | Server | [U] |
| `POST /agent/session-token` | response `developer_model_selection` | Server grants permission to choose | bool [I] |
| `GET /runtime/model-policy` | response `codexAgentLane`, `model`, `reasoningEffort` | Server tells the client the agent lane | [U values] |
| Codex → `/agent/openai/v1/responses` | body `model`, `reasoning.effort`; `metadata.clicky_developer_model` / `_reasoning_effort` | Client (`config.toml` written by the app; developer override per turn) | `gpt-6-luna`, effort `high` [O `config.toml`; its `http_headers` say it was last written by 1.1.1 build 66, so 1.1.2 may write different values]; catalog `gpt-6-luna`, `gpt-6-sol`, `gpt-6.1-sol`, `gpt-6-astra`, `gpt-5.6-sol/terra/luna`, … [O `CAT`]; `ClickyDeveloperChatModel` = `gpt61Sol, gpt6Sol, gpt6Luna, luna, terra, sol, astra`; efforts `none…max` |
| `HAR` H1 jobs | `cfg.model` | Client mapping: Haiku stays Haiku; the Mac runs `gpt-6-luna`; the cloud runs `gpt-6-luna` or `gpt-6-sol` | `AgentHarnessModel` = `standard\|luna\|haiku` |
| `HAR` → `/agent/harness/model/anthropic/v1/messages` | body `model` | Client | `claude-haiku-5-5` |
| `/codex-thread-launch` | none | Server (Haiku per logs) | n/a |

---

## 6. Slot mapping summary (what OpenClicky must supply)

| OpenClicky slot | Replaces | Capabilities the slot needs |
|---|---|---|
| **stt** | `/brain/ears/token` + Gemini Live WS, `/brain/ears/transcribe`, `/v2/dictation/gemini-token`, `/v2/dictation/transcribe` | Streaming PCM16 input (16 kHz mono is typical); manual activity start/end for push-to-talk; interim plus final transcripts; keyterm or vocabulary biasing (`keyterms`, `known_terms`); language hint; batch WAV fallback; final text in about 300 ms after release |
| **voice** | `/agent/realtime/session` + OpenAI WS, `/agent/realtime/speak`, `/agent/realtime/voice-preview` | (a) **Line TTS**: stream audio per sentence, a selectable voice, a speed multiplier and a language, low first-audio latency, and cancel mid-line. (b) Optional **realtime speech-to-speech** session for "full voice" mode: server VAD, barge-in with truncate, function calling, and an ephemeral client credential if the provider needs one |
| **brain** | `/brain/turn` (+prewarm/compact), `/chat`, `/v2/chat`, `/chat-tool-call`, `/clickys/organize-history`, `/onboarding/starter-plan`, `/v2/dictation/cleanup` (text-only), `/codex-thread-launch`, `/codex-thread-title` | Multimodal (screenshot) input, streaming text output, tool or function calling (parallel and async), Responses-style item threads with reasoning carry-over (`encrypted_content`), prompt caching, a hosted or plug-in web-search tool, optionally computer use. A cheap "fast" variant for labels and cleanup |
| **agent** | Codex → `/agent/openai/v1/responses`(+`/compact`), `HAR` → `/agent/harness/model/anthropic/v1/messages`, `/proactive-agents/jobs`, `/skills/creations`, cloud H1 | A Responses-API- or Messages-compatible endpoint for Codex/H1 (custom `base_url` + key), long-running tool loops, MCP client, compaction |
| **other:web-search** | `/agent/web-search`, `/web-search` | `{query, count, freshness}` → results; Exa, Brave or similar with the user's key |
| **other:places / image-search / market-data** | `place-search`, `place-photo`, `image-search`, `stock-quote` | Plain JSON data APIs with user keys, or system frameworks (MapKit) |
| **other:integrations** | `/agent/integrations*`, `/agent/composio/session`, `/agent/realtime/google-calendar/*`, `/agent/realtime/spotify/search`, `/me/calendar/upcoming` | Local MCP host; optional Composio (user key); EventKit; Spotify app scripting |
| **other:memory** | `/me/memory`, `/me/memory/save`, `/brain/session-end` | Local Markdown profile and notes; a summariser that runs on the brain slot |
| **other:scheduler / notifications** | `/agent/cron/*`, `/agent/notifications*` | Local scheduler (launchd or in-app), local run log, local notification inbox |

---

## 7. Disposition summary

- **Replace with user-provided providers (typed slots):** brain, stt, voice and agent routes (§6).
- **Reimplement locally (product services):**
  - integrations hub (MCP host + OAuth);
  - Remote Tasks → local routines;
  - notifications inbox;
  - memory profile and save;
  - companion history;
  - calendar upcoming;
  - skills library (local folders + bundled `SKILL.md`);
  - Clicky organizer and starter plan (brain prompts);
  - proactive suggestions (local agent job);
  - app runtime policy (model and tool policy as settings);
  - account reset;
  - favicon fetch;
  - a **local usage ledger**: per-turn tokens and cost from provider responses, like `ClickyAgentTurnUsageRecord{task_id, thread_id, codex_turn_id, clicky_slug, finished_at, model, reasoning_effort, input_tokens, cached_input_tokens, output_tokens, lease_id, billed_cost_usd}`.
- **Drop:**
  - Supabase auth;
  - `/agent/session-token`;
  - leases, metering and refunds (`/agent/record-agent-launch`, `/agent/turn-lease/*`, `/agent/realtime/turn`);
  - `/agent-messages`;
  - billing, plans, referrals, paywall;
  - `/me/devices`, `/me/discovery-channel`, `/app-config`, `/report-error`;
  - skills publish, team sharing and activation sync;
  - cloud H1 lab;
  - PostHog and Sentry (or make them opt-in without content);
  - `/agent/realtime/warmup`.

---

## 8. Timing and latency behaviour tied to the server [O unless noted]

| Behaviour | Value or source |
|---|---|
| Gemini STT refused (billing/quota) | Use the fallback STT for **10 min** |
| Gemini mouth failed | Speak with the OpenAI voice for **10 min** |
| PTT release (full voice) | "scheduling **400ms** tail, then commit" |
| Harness event long-poll | `wait=20000` ms; runner start timeout 20 s |
| H1 job limits | `maxSteps 120`, `wallMs 1 800 000` (30 min), `bashTimeoutS 300` [O user `job.json`] |
| Agent web-search probe / query timeouts | 4 s / 15 s |
| Realtime mint 401 | 1 forced token refresh + retry |
| Dictation receipt 401 | Retry with the bearer |
| Composio session fetch | Retried with backoff; attempt count logged [U exact backoff] |
| Agent notifications poll | `limit=20` [U interval] |
| Lease status | Polled; "sustained: lease status unobserved for Ns" warning [U interval] |
| Brain round latency (user data) | Server `ttftMs` about 1.4–4.1 s (typically 2–2.5 s), `totalMs` 1.5–17 s, cache hit 85–97 %, about $0.06/round |
| Session pre-open | Mouth session opened "ahead of the first press"; brain prompt cache warmed at key-down when idle and large |
| Realtime idle teardown | Tear down after idle to release the mic, unless agents are busy or always-on is enabled [U seconds] |

---

## 9. Edge cases the client handles [O]

- **Superseded results.** A newer press cancels the in-flight `/brain/turn`. Late `/chat-tool-call` responses are discarded ("discarding superseded higher-model response"). Cancelled realtime tool calls get a synthetic "superseded" output.
- **Compaction race.** A compaction result that arrives after the thread moved on is not applied (`compactionGeneration`).
- **Screenshots by reference refused.** The client falls back to inline base64 for the rest of the session.
- **Account switch** mid-session: "another account signed in: starting clean" (new brain session).
- **Agent session token rotation** during running tasks: Codex restarts lazily.
- **Thread resume missing rollout:** start a fresh Codex thread ("thread_resume_missing_rollout").
- **Idempotency.** `idempotency_key` on lease creation, and refusal to spawn a repeat of work started moments earlier (`already_started`).
- **Offline routines:** "I couldn't reach HeyClicky's servers, so this run didn't start." The run retries; `waitingForNetworkSince` is tracked.
- **Paywall mid-task:** `requires_extra_effort` pauses the agent; the user approves `one_time` or `as_many_as_needed`; cancellation before Codex submit "won't count toward your quota"; early stop requests a refund.
- **Region or network blocks** for OpenAI voice are diagnosed with an unauthenticated `GET /v1/models` and explained to the user.
- **Fail-open billing** when `/me/plan` errors.
- **Sign-in callback hardening:** state match, expiry, local-dev hosts only.

---

## 10. Rebuild plan (OpenClicky modules)

Swift (app target):

1. `ProviderSlots/`: protocol per slot. Each has a registry, per-slot Keychain-stored credentials, and capability flags the UI can check.
   - `STTProvider`: `startStream(language:keyterms:) -> AsyncStream<TranscriptEvent>`, `activityStart()`, `activityEnd()`, `transcribe(wav:)`.
   - `VoiceProvider`: `speakLine(text:voice:speed:language:) -> AsyncThrowingStream<PCMChunk>`, `cancel()`, optional `RealtimeSession`.
   - `BrainProvider`: `streamTurn(thread:[ResponseItem], turn:, tools:, model:) -> AsyncThrowingStream<BrainEvent>`, `compact(thread:)`, `prewarm(thread:)`, plus a `fastText(prompt:)` variant.
   - `AgentProvider`: emits Codex `config.toml` `model_providers.<x>{base_url, env_key, wire_api}` or H1 `responsesURL` / `anthropicURL`.
2. `BrainEventStream`: keep the `/brain/turn` event vocabulary as OpenClicky's **internal** contract, so the drawing, mouth and tool runner code ports unchanged. Event types: `meta`, `text`, `status`, `items`, `search_record`, `tool_call(s)`, `computer_calls`, `done`, `error`. Adapters translate the OpenAI Responses SSE, Anthropic Messages SSE and OpenRouter/OpenAI-compatible SSE into it.
3. `BrainThreadStore`: the local Responses-item thread (same JSON file shape as §4.1) with screenshot pruning ("kept the newest N"), compaction (`note_item` + `keep_from_index`), and session-end memory write.
4. `GeminiLiveSTT`, `OpenAIRealtimeSTT`, `AppleSpeechSTT`: concrete `STTProvider`s. The Gemini adapter reuses the observed message vocabulary (`setup`, `realtimeInput`, `activityStart/End`, `serverContent.inputTranscription`) with the user's API key (or a self-minted ephemeral token).
5. `OpenAIRealtimeVoice`, `GeminiTTSVoice`, `SystemTTSVoice`: `VoiceProvider`s. The realtime adapter mints its own ephemeral `client_secrets` with the user's key, or connects directly, and sends `session.update` with instructions and tools locally (the server used to do this).
6. `ToolBackends/`: `WebSearch` (Exa/Brave/Tavily keys), `PlaceSearch` (MapKit by default), `ImageSearch`, `StockQuote`, `SpotifySearch`, `CalendarEvents` (EventKit). The same JSON shapes as §4.4/§4.6 keep the widget renderers unchanged.
7. `LocalServices/`:
   - `MemoryStore` (`/me/memory` markdown, `save_memory`);
   - `HistoryStore`;
   - `NotificationsStore`;
   - `RoutineScheduler` (absorbs Remote Tasks);
   - `IntegrationsHub` (MCP host; optional Composio with a user key; account labels);
   - `SkillsLibrary` (folders + index JSON shaped like `RemotePowerUpSkill`);
   - `SuggestionsEngine` (runs as an agent job);
   - `RuntimePolicy` (model and tool policy settings);
   - `UsageLedger` (§7).
8. `HTTPClient`: JSON snake_case coding, gzip request bodies above 8 KiB when a provider accepts them, SSE parser (`data:` lines, `[DONE]`), 401 refresh hook (for OAuth'd providers), per-call `X-OpenClicky-*` tracing kept **local only**.
9. `DeepLinkRouter`: `openclicky://` hosts `integrations-auth-callback`, `skill`, `settings`, with the same state/expiry guard pattern as `ClickySignInCallbackGuard`.

Agent runtime (TypeScript / Bun, mirrors `HAR`): point `H1_RESPONSES_URL`, `H1_ANTHROPIC_URL` and `H1_WEB_SEARCH_URL` at the user's providers or a local shim. Drop lease `metadata`. Keep `metadata` for local cost attribution only.

Dev tooling:

- `MockWorker` (a small local HTTP server, test-only) that speaks the §4 shapes, so the ported client code can be contract-tested before each adapter exists.
- JSON fixtures for every Codable in §4 (generated from this doc).

---

## 11. Traffic capture checklist

Capture the app through a TLS-intercepting proxy on a test account. WebSockets need a proxy that shows frames. Watch these requests and record the noted details. Never store tokens from the capture in the repo.

**Auth and identity**

1. Browser `GET https://api.heyclicky.com/auth/start?state=…`: the redirect chain (Supabase `/auth/v1/authorize?provider=google`?), and the exact callback URL format (fragment vs query; `expires_in`, `token_type` present?).
2. `GET {supabase}/auth/v1/user` and `POST {supabase}/auth/v1/token?grant_type=refresh_token`: refresh cadence (before expiry or on 401 only).
3. `POST /agent/session-token`: body `{}`; response `capabilities` value type; `developer_model_selection` type; `expires_at` lifetime; is the token a JWT?
4. Are the `X-Clicky-Platform/Device/App-Version/App-Build/OS-Version` headers on **every** Worker request, or only Codex's?

**Voice brain**

5. `POST /brain/turn`: full request JSON for (a) the first turn of a session, (b) a tool-result round, (c) a typed turn. Look for the exact `turn` sub-keys, `environment`, `max_rounds`, `turn_items`, and whether `input` is a Responses `input` array.
6. `/brain/turn` response: SSE framing (`event:` lines? keep-alives?); the exact `done` and `usage` keys; the `items` contents (does the server return `encrypted_content` reasoning?).
7. When does the server send `x-clicky-accepts-gzip: 1`, and on which response?
8. `POST /brain/prewarm`, `/brain/compact`, `/brain/session-end`: response bodies; compaction thresholds.

**STT**

9. `POST /brain/ears/token` and `/v2/dictation/gemini-token`: the `setup` object (Gemini model id, `inputAudioTranscription`, VAD config, language), token TTL, `receipt` format.
10. The Gemini WS URL query (`access_token=`?) and the first client frame (does the client send `setup` verbatim?). Audio sample rate in `mimeType`.
11. `POST /v2/dictation/cleanup`: full body and `context`, and whether `known_terms` is sent; response keys beyond `text`.
12. `POST /brain/ears/transcribe`, `/v2/dictation/transcribe`: when the fallback triggers; response keys.

**Mouth / realtime**

13. `POST /agent/realtime/session`: exact request (where `one_brain_mouth` lives, and the `client_capabilities` values); the full response (`client_secret.expires_at`? the full `session` object with instructions and tools?). This answers whether instructions and tools are minted server-side.
14. The first frames on `wss://api.openai.com/v1/realtime`: is `session.update` the only client config? Headers on the upgrade (`OpenAI-Beta`?).
15. `POST /agent/realtime/speak`: request body for a line and for an `update`; response content type and framing (NDJSON vs SSE vs raw PCM); audio sample rate.
16. `POST /agent/realtime/turn`: when it fires (every realtime turn? only the mouth?) and its response (remaining quota?).
17. `POST /agent/realtime/voice-preview`: response headers (WAV format).

**Realtime tools and higher model**

18. `POST /chat-tool-call`: one capture each for a plain question, a guided walkthrough, an annotation gesture, and attachments. Record the response `widgets` payloads and the `walkthrough` shape.
19. `POST /web-search`, `/me/memory/save`, `/agent/realtime/google-calendar/events[/create]`: the bodies the realtime model sends (these reveal the server-defined tool schemas).
20. `POST image-search`, `place-search`, `place-photo` (the response content type), `stock-quote` (confirm no auth), and `GET /favicon?host=…` (confirm the Worker host).
21. Is `/chat` vs `/v2/chat` ever hit in 1.1.2, and from which UI? What do `response_model_selection` values other than `standard` look like?

**Agent**

22. Codex → `POST /agent/openai/v1/responses`: headers (`X-Clicky-*`, `x-codex-turn-metadata`?), `metadata` keys, `prompt_cache_key`, `service_tier`; does Codex call `GET /agent/openai/v1/models`?
23. `HAR` → `POST /agent/openai/v1/responses/compact` and `/agent/harness/model/anthropic/v1/messages` (when Haiku is selected).
24. `GET`/`POST /agent/web-search`: response shape (`results[{title,url,snippet}]`?).
25. `POST /agent/record-agent-launch`: confirm it carries `CodexAgentTurnLeaseRequestBody` and returns the lease; then `GET /agent/turn-lease/{id}/status` cadence; and `POST …/complete`, `…/continue`, `…/refund-early-stop`.
26. `POST /codex-thread-launch` and `/codex-thread-title`: response timings (is the launch blocked on it? "awaiting Haiku gate").
27. `GET /runtime/model-policy` and `/runtime/tool-policy`: the host (Worker vs loopback), and the values of `codexAgentLane` and `enabledRootTools`.
28. `POST /agent/composio/session`: `proxy_url` host and path; MCP traffic to it (which tools are listed?).
29. Integration connect: `POST /agent/integrations/{id}/connect` → `redirect_url` host (Composio?) → `heyclicky://integrations-auth-callback` parameters.

**Product services**

30. `GET /agent/cron/list`, `/agent/cron/{id}`, and the `clicky-crons` MCP process's own HTTP calls (create, update and delete routes are missing from `BIN`).
31. `GET /agent/notifications?limit=20`: poll interval; `POST …/{id}/read`.
32. `POST /proactive-agents/jobs` → `GET …/jobs/{id}` polling interval; the unnamed POST (`fn@0x102d255c8`) path; `invitation-claim` request body.
33. `POST /clickys/organize-history`, `/onboarding/starter-plan`, `GET /onboarding/language-hints` (query parameter name), `/me/companion-history`, `/me/calendar/upcoming`, `/me/memory`.
34. `/skills/*`: confirm the `/programs` prefix and the `/skills/creations` polling cadence.
35. `/me/devices` response and when it is re-sent; `/app-config` cadence.

**Third party**

36. PostHog `/batch` payloads: confirm whether `$ai_generation` events include prompt or output text. This is a privacy note for the README comparison.

---

## 12. Open questions / UNKNOWN

- Server-side prompts, tool schemas, model routing tables and pricing logic behind every brain, realtime and agent route (not recoverable from the client).
- The exact `/brain/turn` `turn` and `environment` nesting, and the SSE framing details (§11 items 5–6).
- Whether OpenAI realtime instructions and tools are minted into the client secret's session (likely) or sent later.
- The `/agent/realtime/speak` response framing and audio format.
- The Gemini model id used for STT and the exact `setup` contents.
- Create, update and delete routes for Remote Tasks (inside the `clicky-crons` MCP).
- The path of the unnamed `ProactiveAgentsClient` POST.
- The real `/proactive-agents` job-create path (assumed `/proactive-agents/jobs`).
- The callers of the dormant direct clients `OpenAIAPI` (chat completions) and `ElementLocationDetector` (Anthropic computer use), and where their keys come from.
- The hash used for `X-Clicky-Device`.
- Whether `GEMINI_API_KEY` exported to agents equals the agent session token.
- Upstreams behind `image-search`, `place-*`, `stock-quote`, `/web-search` (Brave, Google Places and Exa are hinted, not proven).

## 13. Corrections to sibling docs (evidence in §4)

- `/agent/composio/session` is **POST**, not GET (`fn@0x101faae08`, `fn@0x101fac358` both reference `"POST"`).
- `/agent/session-token` is **POST** with body `{}` (`fn@0x102085e30`).
- Marking a notification read is `POST /agent/notifications/{id}/read` (literal `/read` in `fn@0x101fbd0f0`).
- Lease completion is observed: `POST /agent/turn-lease/{id}/complete {status, thread_id}`. Lease creation is most likely `POST /agent/record-agent-launch` (same file and function cluster as the lease Codables).
- The `ProactiveAgentsClient` request body is snake_case: `reports_suggestion_views, connected_integrations, clickys, check_reason, supports_morning_notch, recent_agent_suggestions, custom_connectors, local_day, research_only, brief_style, routines, jobs`.
- `/programs` is observed only as the literal `/programs`. Its `/skills` prefix is not proven.
