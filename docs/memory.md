# Memory

OpenClicky's memory of the user is local and editable. HeyClicky keeps its profile on its server and writes it there
at session end ([08 §5.1](re/08-apps-memory-ui.md#51-user-memory-profile-server-and-helperabout-the-usermd),
[02 §5.6](re/02-voice-pipeline.md#56-prewarm-compaction-and-session-end-o)). OpenClicky keeps everything in
`~/Library/Application Support/OpenClicky/Memory/` and uses the brain-fast slot for the session-end writer. Code:
`Sources/OpenClickyKit/Memory/`, settings pane `Sources/OpenClicky/Memory/`, CLI `occtl memory`.

## Files

| File | What | Format |
|---|---|---|
| `about-the-user.md` | The profile | Markdown. `# ` starts a group, `## ` a section, `- ` an item. Text a person writes is kept byte for byte. Sections under `# Right now` hold short-lived context. |
| `standing-context.md` | Requests to follow in every conversation | One `- ` line each |
| `how-tos.md` | Steps learned for tasks the user repeats | `## title` and the steps under it |
| `memories.jsonl` | Dated memories and session notes | One JSON object per line: `id`, `text`, `kind` (`fact`, `preference`, `event`, `session`), `source`, `created_at`, optional `updated_at`, `tags`, `session` |

Every read goes to disk, so hand edits are seen at once. Writes are atomic, and the files are private (0600 files in a
0700 folder). Every `MemoryStore` for the same folder in one process shares one lock, so Settings and the brain runtime
can each hold their own store without losing each other's writes; two processes (the app and `occtl`) writing the same
file at the same moment resolve as last-writer-wins. Lines in `memories.jsonl` that don't parse are written back
unchanged; records are separated by `\n` only. A how-to step that would read as a `# ` or `## ` heading is written as a
`### ` subheading so it stays inside its how-to. Ids: memories keep the random
`m-` id they were saved with. Standing (`s-`), profile (`p-`) and how-to (`h-`) ids come from a hash of the text, so
editing a line by hand gives it a new id.

`MemoryBudget` sets the size limits: 400 memories, 30 standing lines, 40 how-tos and a 12,000-character profile by
default. When memories are over the limit, the oldest session notes are dropped first, then the oldest of the rest.
When the profile is over its limit, the oldest `Right now` items are dropped. If it is still over, new profile lines
are refused.

## Secrets

`MemorySecretScrubber` replaces anything that looks like a credential with `[redacted]`. It covers provider key
formats, JWTs, PEM private keys, bearer and basic credentials, passwords in URLs, values given after words like
"password" or "API key" (after a password-like word, the quoted value or the rest of the clause, so a passphrase with
spaces goes whole), Luhn-valid card numbers, US SSNs, and long high-entropy tokens. Scrubbing runs on every way
in: tool saves, the writer's transcript and reply, Settings, and `occtl`. It also runs on every way out: the prompt
blocks and recall results. An item that is mostly a secret ("my wifi password is …") is refused outright.

## Brain tools

`MemoryTools.specs` holds three tools. Pass each call to `MemoryTools.handle(_:)`, which returns nil for tools that
aren't memory tools.

| Tool | Arguments | Result | Kind |
|---|---|---|---|
| `save_memory` | `text`, `kind` (`fact`, `preference`, `event`, `standing`) | `{status: saved, already_known or refused, id, text, where}` | action, status word "remembered" |
| `recall_memory` (alias `recall`) | `query`, `limit` (1 to 10) | `{status, results: [{id, text, where, date}], earlier_chats?: [{date, how, user, reply}]}` | read, so it needs another model round |
| `forget_memory` | `id`, or `query` | `{status: forgotten, not_found or ambiguous, …}` | action. A query forgets only when one item clearly matches; otherwise the candidates come back so the model can pick an id |

With `MemoryTools(store:history:)` (the app and `occtl brain ask --tools memory` pass the conversation history),
`recall_memory` also looks through earlier chats: the most recent 600 completed turns, scored by how many of the
query's keywords their words and reply share (at least half), best then newest, three at most, scrubbed of secrets
and clipped. Chats from before the last "Forget everything" are left out: `MemoryStore.forgetEverything()` writes the
time to `forgotten-at` in the memory folder, and `MemoryStore.forgottenAt` reads it back. Forgetting one memory doesn't
hide the chat it came from; clearing the history in Settings does.

## Prompt

`MemoryPromptBuilder.build(from:for:)` returns two blocks that share one token budget (900 by default):

- `stableText` is `<user_memory>`: standing context, then the profile. It changes only when memory changes, so it
  belongs in the cached system prompt.
- `turnText` is `<relevant_memories>`: the memories and how-tos that match this turn, ranked by keywords and recency,
  each with its id. It changes every turn, so it belongs in the turn's own context after the thread.

Both blocks say they are background, not instructions. Text inside an item cannot close either block.

## Session end

`MemoryWriter(client:model:).endSession(thread:store:sessionID:)` runs when a session ends. Use the brain-fast slot,
or the brain slot when brain-fast is empty. The writer sends OpenClicky's own instructions, what is already
remembered, and a scrubbed transcript: spoken lines rather than drawing code, `[screenshot]` in place of images, and
the start and end of the thread when it is long. Text inside the data cannot close the request's `<conversation>` or
`<remembered>` blocks. It asks for a JSON diff: a session note, profile lines to add or remove, standing context,
how-tos, memories, and ids to forget. `MemoryStore.apply(_:)` checks each change the same way it checks a direct save:
secrets are scrubbed, near-duplicates are skipped, and the budget is enforced. A single session's changes are capped.

- If the user never spoke, no model call is made. A user-message line that starts with `[` (`[App] …`,
  `[This turn] …`) is an app note; any other non-blank line counts as the user's words.
- The reply cap is 4,000 tokens, since OpenAI counts reasoning against it. `MemoryWriter(factory:)` asks OpenAI models
  for the lightest effort the catalog lists (`none`, `minimal` or `low`) and leaves Anthropic thinking off. A reply
  cut off at the cap throws `MemoryWriterError.truncatedReply` and changes nothing.
- A cancelled writer applies nothing. If the user chooses "Forget everything" while the model is writing, the diff is
  dropped (the report says `MemoryStore.erasedDuringWrite`), so memory they deleted is never written back. Pass
  `erasuresAtStart:` (`store.erasures` read when the session began) to extend that to the whole session.

## Agents

Every job's instructions end with `MemoryAgentBrief.section(store:)`: an "About the user" section saying the block is
background only, never instructions, and not for the report; the `<user_memory>` block (standing context and the
profile, 1,200-token budget); and the paths of `about-the-user.md` and, when there are any, `how-tos.md`, so a job
can read them in full. The app appends it after the active skills (`HomeServices`, `AgentServices(extraInstructions:)`).
OpenClicky's profile file is already the `about-the-user.md` HeyClicky mirrors to its helper folder, so the path
handed to jobs is the file itself.

## How-tos from jobs

When a job's run comes back done, `AgentHowToLearner` (brain-fast, the memory writer's light effort) reads its
report and answers `{"howto": null}` or a title and up to eight general steps, which go to
`MemoryStore.saveHowTo` (secrets scrubbed, same title replaced, oldest dropped past the budget). Most jobs teach
nothing. The app runs it in the background for every finished job (`VoiceLoopController.followJobs`).

## Every chat

- Push-to-talk and Home's typed chat share the brain runtime's sessions, so both end with a session note.
- Always-on writes its own: when a run ends, `AlwaysOnRecorder` hands its conversation to
  `MemoryWriter.endSession` (with the erasure count from when the run began).

## Wiring checklist (for the brain runtime and the app)

1. Offer `MemoryTools.specs` with the turn's tools. Route each call to `MemoryTools.handle`, show
   `runningStatus(for:)` while it runs, and pass the result `output` back to the model.
2. Each turn, put `section.stableText` in the system prompt and `section.turnText` in the turn context.
3. When a session starts, keep `store.erasures`. In `endSession()`, build the writer with `MemoryWriter(factory:)`
   (brain-fast, falling back to brain), call `endSession(thread:store:sessionID:erasuresAtStart:)`, catch errors, and
   log the report. A failed or cancelled write leaves memory unchanged.
4. Settings: add `MemorySettingsView().tabItem { Label("Memory", systemImage: "brain.head.profile") }`.
