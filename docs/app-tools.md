# Local app tools

The brain can call these tools on the user's Mac. The code is in `Sources/OpenClickyKit/AppTools/`, and
`AppToolbox.standard(.live())` builds the set. Parity rows: `apps-calendar` and `apps-spotify`. Reader notes:
[08 §3.6](re/08-apps-memory-ui.md#36-apps-exposed-to-the-voice-brain-and-realtime-voice) and
[02 §6.1–6.2](re/02-voice-pipeline.md#6-brain-tools).

`insert_text` is owned by the dictation part and is not in this toolbox.

| Tool | Runs | Model reads the result | Success status | Other statuses |
|---|---|---|---|---|
| `open_url` | after the narration | no | `opened` | `refused`, `invalid_request`, `failed` |
| `copy_to_clipboard` | now | no | `copied` | `invalid_request`, `failed` |
| `reveal_in_finder` | after the narration | no | `revealed` | `refused`, `not_found`, `invalid_request`, `failed` |
| `play_on_spotify` | after the narration | no | `completed` | `unconfirmed`, `not_found`, `unavailable`, `permission_denied`, `invalid_request`, `failed` |
| `calendar_find_events` | now | yes (read-only) | `ok` | `permission_denied`, `unavailable`, `invalid_request`, `failed` |
| `calendar_create_event` | now | yes | `needs_confirmation`, `created` | `not_found` (draft expired), `permission_denied`, `unavailable`, `invalid_request`, `failed` |

Every result is a flat JSON object: `{"status": <word>, "message": <optional sentence>, ...details}`. The words are
`AppToolStatus`. An unknown tool name gets `not_implemented`. A call whose task a newer turn has cancelled runs
nothing more and reports `cancelled`; `play_on_spotify` checks again before each step that would start music.

## How the brain runtime uses the toolbox

1. Send `toolbox.specs` in `ChatRequest.tools`.
2. For each `ToolCall`, call `toolbox.prepare(call)`. It never runs anything:
   - `.finished(result)`: unknown tool or bad arguments. Send `result.toolMessage(callID:)` back at once.
   - `.runNow(tool)`: run it with `await toolbox.run(call)`. If `tool.needsFollowUpRound` is true, the model reads
     the result in another round. Otherwise the status word alone is enough.
   - `.deferUntilNarrationEnds(action, queued)`: send `queued` to the model now. Its status word is the one the action
     reports when it works, with `"deferred": true`. Emit `TurnEvent.deferredAction(action)`. The orchestrator runs
     the action with `await toolbox.run(action)` once the narration has been spoken, and drops it if a new turn starts
     first.
3. When a deferred action fails, `result.appNote(toolName:)` gives the `[App]` note for the next turn.

`tool.statusLabel` is the short notch or cursor text shown while a tool runs. `tool.isReadOnly` lets policies tell
reads from actions.

Build the toolbox once per app session and keep it, because calendar drafts live inside it. The schemas leave
optional arguments out of `required`, so they are meant for non-strict function calling (`strictTools: false`, the
adapters' default).

## Calendar (EventKit)

- `EventKitCalendarStore` reads every account in the Mac's Calendar app, including iCloud, Google, Exchange and local
  calendars. HeyClicky reached only Google Calendar, through its server.
- **Find.** Use a named `range` (`today`, `rest_of_today`, `tomorrow`, `this_week`, `next_week`, `next_7_days`,
  `this_weekend`, `this_month`) or `start`/`end` dates. A plain end date includes that whole day. `query` matches the
  title, place, notes, attendees and calendar name. It ignores case and accents. When no event matches every word,
  it returns events that match any word, with `"match": "partial"`. Other filters are `calendar` (part of a calendar
  name), `include_all_day` and `limit`. With only a query, the next 30 days are searched. Times come back in the
  user's time zone with an offset and the weekday. Cancelled events are left out. Events the user declined are
  marked `declined`.
- **Create, with confirmation.** Without `confirmed`, the tool saves nothing. It returns `needs_confirmation` with a
  draft and a `draft_id`. Drafts last 30 minutes. The model reads the draft back to the user. If they agree, it calls
  again with `draft_id` and `confirmed: true`. The model sets `confirmed: true` on the first call only when the
  user's own words already asked for this exact event. A `draft_id` sent together with event details is saved only
  when the details match the draft (an echo of what was read back). Different details make a new draft, returned as
  `needs_confirmation` with `replaces_draft_id`, and the old draft is dropped. Partial details are turned away. Each
  draft is saved once: a repeated confirmation answers `created` with `"already_saved": true`, and one that arrives
  while another call is saving gets `invalid_request`. A draft whose save failed waits for another try. Events are timed, or all-day when `start` has no time; all-day
  `end` is the last day covered. Events are at most 14 days long and default to 60 minutes.
- **Time zone.** The default clock follows the Mac's time zone as it changes, so a toolbox kept for the whole app
  session still means the user's "today" after travel. Saved events get the zone in effect when the draft was made.
- **Permissions.** Tools never crash and never hang over calendar access. A state that was never decided triggers one
  request for full access, and only when the process declares `NSCalendarsFullAccessUsageDescription`. `occtl` and
  the test runner do not declare it, so they report `unavailable` and never prompt. Denied, restricted and write-only
  access return `permission_denied` with the System Settings link. Write-only access can still add events to the
  default calendar.
- **Meeting countdown.** `CalendarService.upcomingMeeting(withinMinutes:)` returns the next timed meeting within N
  minutes. It keeps a meeting that started less than 5 minutes ago, and skips all-day, cancelled and declined events.
  When two events start at the same time, the one with a call link wins. Its primary action is `join` (a Zoom, Meet,
  Teams, Webex or similar link found in the URL, location or notes), else `directions` (Apple Maps, for a physical
  place), else `open` (the event's own link). It runs on a timer, so it never asks for permission.

## Music

`play_on_spotify` takes `query`, `artist`, `kind` (`track`, `album`, `playlist`, `artist`), `uri` (a `spotify:` URI or
`open.spotify.com` link) and `app` (`spotify` or `apple_music`).

1. **Resolve.** It uses the given URI. Failing that, it asks the optional catalog search. `SpotifyWebAPICatalog` uses
   the user's own Spotify developer app with the client-credentials flow. Without a URI or a catalog match, it opens
   `spotify:search:<words>` and returns `unconfirmed`, because search results do not play by themselves.
2. **Play.** If Spotify is running, it sends the AppleScript `play track <uri> [in context <album>]`. If Spotify is
   closed, or AppleScript did not take, it opens the URI, which also launches Spotify.
3. **Verify.** It reads `player state` and `current track` after 0.4 s, or after 3 s on a cold start. Playback counts
   when the current track is the one asked for, or when the track changed or playback started. A Spotify that is open
   but idle gets one more play command. A result that cannot be confirmed is `unconfirmed`, never `completed`.
   Denied Automation also gives `unconfirmed`, with `"automation": "denied"` and the Settings link.
4. **Apple Music.** It is used when the user asks for it, or when Spotify is not installed. It searches the user's
   library with the Music app's `search … only names|albums|artists`, or matches user playlists by name. It plays
   the first match, preferring the named artist, then verifies the same way.

Every value placed in AppleScript goes through `AppleScriptText.literal`. That function escapes quotes and
backslashes and flattens line breaks, so an argument cannot end the string. Spotify URIs are checked against a strict
form before use. Scripts run through `/usr/bin/osascript`, with the source passed as one `-e` argument (no shell,
no stdin pipe), through the Kit's shared `AppleScriptRunning` seam. `CancellableOsascriptRunner` gives each script
15 seconds (`MusicPlayer.Timing.script`) and stops osascript as soon as the task is cancelled.

**Spotify Web API (optional, off by default).** Store your own app's credentials with
`occtl key set spotify-client-id` and `occtl key set spotify-client-secret`. Then pass
`SpotifyWebAPICatalog.fromCredentials(store)` as `spotifyCatalog` (or `occtl tools call --spotify-web-api …`).
The id, secret and token never appear in descriptions, mirrors or errors. The `market` sent with each search is the
Mac's region when it is a two-letter country code, and `US` otherwise (`Locale.region` can be an area such as `419`,
which Spotify rejects).

## Links, clipboard, Finder

- `open_url` opens only `http` and `https` links, in the default browser. It refuses other schemes (`javascript:`,
  `file:`, `data:`, `mailto:`, app schemes and others), links with embedded user names or passwords, and text with
  whitespace or control characters in it. A bare domain is opened over https, and a bare `localhost:port` over http.
- `copy_to_clipboard` copies the text exactly as given, up to 200,000 characters.
- `reveal_in_finder` shows only items inside the user's home folder. It resolves `~`, `..` and symbolic links first,
  so a link pointing out of the home folder is refused. A missing item gets `not_found` at once from `prepare`, so the
  model is never told `revealed` for something that is not there.

## occtl

```sh
occtl tools list [--json]                         # tools, flags, status labels
occtl tools call --dry-run play_on_spotify '{"query":"Kind of Blue","kind":"album","app":"apple_music"}'
occtl tools call open_url '{"url":"javascript:alert(1)"}'   # refused; nothing opens
occtl tools upcoming --dry-run 15                 # the countdown on sample events
occtl tools status                                # calendar permission, Spotify and Music on this Mac
```

`--dry-run` uses the in-memory fakes. Nothing opens, plays or is copied, and the calendar shows sample events. The
command prints, on stderr, the AppleScript and URLs a real call would use.

## Needs a person at the Mac

- Calendars permission, granted to the built app. The first `calendar_find_events` call shows the prompt.
- Automation permission for Spotify and Music. The first play shows the prompt, under the app's existing
  `NSAppleEventsUsageDescription`.
- A real Spotify check of playback on a cold start, on a warm start and with a context URI.
- A real Music check of library search for each kind.
