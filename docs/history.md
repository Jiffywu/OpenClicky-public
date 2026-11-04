# Conversation history

OpenClicky keeps every turn on the Mac so Home can show past conversations and recent drawings. There is no server
copy. The Swift types are in `Sources/OpenClickyKit/History/`.

## Who writes it

Whoever consumes the brain's `TurnEvent`s writes the turn:

```swift
var log = TurnLogBuilder(input: input, sessionID: sessionID)   // when the turn is handed to the brain
for try await event in brain.run(input) {
    log.apply(event)                                            // every event, as it arrives
    ...
}
try history.append(log.finish())                                // once, when the stream ends
// later, when the narration outcome is known (completed, cut off by the user…):
try history.recordNarration(note, forTurn: turn.id, in: sessionID)
```

- The turn orchestrator does this for voice turns. Home's chat does it through `TypedChatController`, and so does
  `occtl history chat`. Always-on voice does it through `AlwaysOnRecorder` (one turn per exchange, built from the
  realtime conversation's updates by `AlwaysOnTurnLog`; source `voice`, `text` for questions typed into it, `app`
  with trigger `always_on` when the voice spoke first; the realtime model and its token use).
- A turn that never sees `finished` or `failed` is stored as `cancelled`.
- `sessionID` is the brain runtime's session (`BrainSessionNaming`), for every surface: push-to-talk, Home's typed
  chat and always-on all record into the conversation the one brain holds. A session ends with
  `BrainTurnRunning.endSession()` (or after 30 idle minutes), and the next turn starts a new one. With a brain that
  doesn't name its session (the stand-in), `TypedChatController` reuses the newest session while it has been quiet
  for less than six hours.
- The brain runtime's own thread (the model-facing items, under `Application Support/OpenClicky/Brain/`) is separate.
  This history is the user-facing record. It reaches the model in one case only: when `TypedChatController` sends a
  question into a conversation the brain's thread doesn't hold (picked up after a relaunch or an occtl run, or chosen
  in Home), it first calls `endSession()` if the brain held another conversation, then hands brains that adopt
  `ConversationSeeding` that conversation's completed turns (words and spoken reply) as their thread. The brain
  runtime takes the picked conversation's id as its session id (`seedConversation(_:sessionID:)`), so the voice turns
  that follow are recorded there too; `startNewConversation(id:)` seeds an empty conversation under the new id. A
  brain that keeps its own thread per session can leave the protocol out and is only told to start fresh.

## Files

```
~/Library/Application Support/OpenClicky/History/
  index.json                       {"version":1,"sessions":[HistorySession…]}  (a cache)
  sessions/<session-id>.jsonl      one JSON object per line
  thumbnails/<hash>.png            drawing thumbnails (a cache)
  lessons/<turn-id>/               a saved drawing, with "Save drawings as lessons" (drawing.saves-lessons) on:
    lesson.json                    {version, turnID, sessionID, createdAt, question, program, canvas, lines:
                                   [{index, text, start, duration}], screen, screenshot, poster}; line times are
                                   seconds after the drawing began (absent for lines never spoken)
    screenshot.jpg                 the screenshot it was drawn on
    poster.png                     the finished drawing over that screenshot
```

`VoiceLoopController` writes the lesson folder when a turn that drew finishes (`TurnRecord.lesson`,
`DrawingLessonRecorder`). `HistoryStore.recentDrawings` fills `HistoryDrawing.lessonFolder` when one exists; the
thumbnail is then drawn over the stored screenshot, and Home's Drawings detail replays the lesson
(`DrawingLessonReplay`: the program through the engine and painter at its lines' recorded pace, the lines as
captions, no audio). Drawings without a lesson replay on a plain card at an average speaking rate.

Deleting a conversation (`HistoryStore.deleteSession`) also removes the lesson folders of its turns (and any whose
`lesson.json` names the session) and their screenshot thumbnails in `thumbnails/`. Lessons have no size cap; Clear
History removes them all.

Each session file starts with a header and is only ever appended to:

```jsonl
{"at":"2026-10-31T09:12:03.120Z","id":"4612C2F9-…","kind":"session","version":1}
{"kind":"turn","turn":{HistoryTurn}}
{"kind":"narration","note":"cut off by the user after line 2","turn":"<turn id>"}
{"kind":"handoff","handoff":{HistoryHandOff}}
```

- A crash can lose at most the line being written. A partial last line is skipped on read, and the next append starts
  on a fresh line.
- If a turn id appears twice, the later line wins.
- A `narration` line sets the `narration` field of the turn it names.
- `index.json` holds the session summaries the list shows. It is rebuilt from the session files whenever it is missing,
  unreadable, or doesn't list the same sessions as the folder.
- Session ids become file names after unsafe characters are replaced (`HistoryStore.safeName`).
- Dates are ISO 8601 strings with milliseconds. Numbers (epoch seconds) are also accepted on read.

### HistoryTurn

| key | type | meaning |
|---|---|---|
| `id` | string | turn id |
| `session` | string | session id |
| `at` | date | when the turn was handed to the brain |
| `source` | `voice` \| `text` \| `app` | spoken, typed, or started by OpenClicky (`trigger` says why) |
| `words` | string | what the user said or typed, trimmed; empty for app turns |
| `trigger` | string? | `job_report`, `tour`, `did_step`, … |
| `appNotes` | [string]? | the `[App] …` notes the brain saw before the words |
| `frontApp` | string? | front app when the user asked |
| `lines` | [string] | `say()` lines in order |
| `program` | string? | the whole drawing program (fences stripped); absent when nothing was drawn |
| `canvas` | `{width,height}`? | cursor screen size in points, for replaying the program |
| `statuses`, `tools`, `deferredActions` | [string]? | status words, tool names in start order, actions held for after the narration |
| `outcome` | `completed` \| `failed` \| `cancelled` | |
| `errorSpoken`, `errorDetail` | string? | for failed turns |
| `narration` | string? | what happened to the narration afterwards |
| `model`, `rounds`, `usage` `{input,cached,output}` | | from the brain's `TurnSummary` |
| `timings` | object | `firstEventMs`, `firstProgramMs`, `firstLineMs`, `modelFirstTokenMs`, `totalMs`, all counted from `at` |

Missing optional keys decode as empty, so older and newer files stay readable.

### HistoryHandOff

Work handed to a background job and the job coming back, in the conversation the brain held at the time
(`HistoryStore.append(_ handOff:)`, `handOffs(in:)`). The app writes them from the job manager's updates
(`HistoryHandOffTracker`: `started` once per run, `came_back` once per report). They don't count as turns; the
session's `updatedAt` moves to them.

| key | type | meaning |
|---|---|---|
| `id` | string | `<job>#<run>-started` or `<job>#<run>-back` |
| `session`, `at`, `job`, `run`, `title`, `agent` | | where and when, which job and run, its title and kept agent |
| `kind` | `started` \| `came_back` | |
| `task` | string? | for `started`: what was asked, shortened |
| `outcome`, `spoken`, `files`, `question` | | for `came_back`: `done`, `needs-you`, `failed` or `stopped`; the sentence to say; deliverables; what it asked |

### HistorySession (index.json)

`id`, `startedAt`, `updatedAt` (latest turn), `title` (first words, about 60 characters), `turnCount`, `preview`
(latest reply, about 120 characters) and `drawingCount`.

## Reading

`HistoryStore` covers what Home and occtl need:

- `sessions(limit:)`, `turns(in:)`, `recentTurns(limit:)`.
- `recentDrawings(limit:)`: turns with a program, newest first, with identical programs shown once.
- `search(_:)`: every word, ignoring case and accents.
- `changes()`: an `AsyncStream` that Home follows.
- `deleteSession`, `deleteAll`.

`DrawingThumbnailer` re-renders a drawing's program with the real drawing engine (`DrawingRehearsal`) at its recorded
canvas size, scales it down, and caches the PNG by a hash of the program, canvas, style and ink.

## occtl

```
occtl history list | show <id|latest> | drawings | search <words> | thumbnail <turn> <out.png>
occtl history replay <turn|lesson-folder> <out-dir> [--every s]   # replay frames, captions and timings, offscreen
occtl history chat [--config c.json] [--new] <question>     # a typed turn through the brain slot, recorded
```

`OPENCLICKY_HISTORY_DIR` points the commands at another folder.
