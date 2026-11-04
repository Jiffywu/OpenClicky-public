# Home, Settings, onboarding and skills

The windows beyond the overlay. The app code is in `Sources/OpenClicky/Home/` and `Sources/OpenClicky/Settings/`. The
logic is in OpenClickyKit (`History/`, `Skills/`, `Shell/`), so it runs in tests and `occtl` without a screen.

## Home window

Open it from the menu bar (**Open Home…**, ⇧⌘H) or from onboarding. `HomeServices` owns what it shows and is also in
the Settings window's environment.

- **Chat.** Conversations from the history (docs/history.md), newest first. The selected one shows each turn: the
  words with "Spoken in Numbers" or "Typed", the reply, an inline thumbnail when the reply drew something (a program
  that only speaks gets none), the tools or status words, and the model with its timings. Jobs that started or came
  back in that conversation (`HistoryHandOff`) appear between the turns.
  - Typing sends a turn through the voice loop's brain runtime: the app delegate makes one `BrainRelay`, passes it
    as `HomeServices(model:brain:)`, and the voice loop points it at the `BrainRuntime` it builds (and rebuilds when
    the slots or connected apps change). A typed question therefore gets everything a spoken one does except the
    screenshot: memory, lookups, app tools, connected apps and the Obsidian vault, background jobs, take-over, the
    active skills, the `[Your jobs]` note and drawings (shown as a thumbnail beside the reply). A question typed
    before the first press builds the engines first (`BrainRelay.setPrepare`).
  - `TypedChatController` records the turn in the history and tells the brain it was typed in Home
    (`TypedChatController.homeWindowNote`: no screenshot, lines shown as text). Actions the brain held until its
    answer was said (open a link, show a job's result) run once the answer is in.
  - One conversation: typed turns go into the brain runtime's own session (`BrainSessionNaming`), the same one
    push-to-talk turns and always-on exchanges are recorded in, so Home shows them together and follows the newest
    conversation as it grows. Picking an older conversation in the list (or New conversation) moves the brain there:
    it ends the session it held (its memory notes are written) and is seeded with that conversation's turns under the
    conversation's own id (`ConversationSeeding.seedConversation(_:sessionID:)`), so the next spoken question
    continues it too (see docs/history.md).
  - Session notes: Home typed chat now runs in the brain runtime's sessions, so a quiet conversation ends with a
    memory note like a spoken one.
  - `StandInTextBrain` (one text-only call on the brain slot, active skills and memory in its system prompt) is what
    `HomeServices` falls back to without a brain: the offscreen evidence renders and `occtl history chat` without
    `--runtime`.
- **Agents.** The agent HUD (`AgentHUDView`) over the live `AgentServices`. `HomeServices` creates the agent
  coordinator, starts it at launch and stops it on quit.
- **Drawings.** Replies that drew something, re-rendered from their saved programs by `DrawingThumbnailer` (over the
  stored screenshot when the drawing was saved as a lesson). Click one to see its spoken lines, copy the program, or
  press Replay: `LessonReplayModel` plays it again inline through `DrawingLessonReplay` at the pace its lines were
  heard, with the lines as captions (no sound). With "Save drawings as lessons" on (Settings → Developer), each
  drawing's screenshot, poster and `lesson.json` are kept (docs/history.md).
- **Skills.** The skills library (below).
- **Settings shortcuts.** Memory, Connected apps, Services, Voice, Talk keys and Models open the Settings window on that
  page (`HomeServices.openSettings(_:)`).

## Settings window

A sidebar of pages, chosen by `HomeServices.settingsPage`:

- **General.** Open Home, clear the conversation history, replay the welcome tour, a skills summary.
- **Models.** Every slot's provider and model (unchanged from before).
- **Voice.** The voice slot's voices:
  - the catalog's fixed list (OpenAI, Gemini), the macOS voices installed on this Mac, or the voices in the user's
    ElevenLabs account (`GET /v1/voices`);
  - **Preview** renders a sample line through the voice slot (`VoicePreviewRenderer`), caches it as a WAV in
    `Application Support/OpenClicky/VoicePreviews/` and plays it at the chosen speed;
  - speed is 0.5x to 1.5x, saved in `voice.json`. The app applies it through `SpeechPlayer.rate`, which keeps the pitch.
- **Talk keys.** Record a modifier chord for talking (hold), typing (double tap) and dictation (hold).
  - Recording uses a local key monitor, so it needs no permission while Settings is in front.
  - `TalkKeyRules` rejects single-key holds, multi-key double taps, keys already in use, and hold chords that contain
    one another (pressing the bigger one would start the smaller one first).
  - It warns about common macOS shortcuts: double-tap Fn (Dictation), double-tap Command (Siri), and ⌘⌥.
  - Keys are saved in `talk-keys.json`. The dictation chord is also written to `dictation.json`, which dictation reads.
    The voice chord is applied to the running push-to-talk monitor right away.
- **Providers & keys**, **Permissions.** Unchanged.
- **Memory**, **Connected apps**, **Services.** The existing views from the memory, integrations and lookups work, now
  reachable from Settings.
- **Skills.** The skills library.

## Onboarding

On first launch (no finished `onboarding.json`), the app opens the welcome window instead of Settings. If the user
closes it part-way, it resumes from the menu (**Finish Setting Up…**). Settings → General replays it.

`OnboardingMachine` (OpenClickyKit) holds the rules. The window feeds it events and performs the effects it returns:

1. **Welcome.** What OpenClicky is.
2. **Permissions.** Microphone, Screen Recording and Accessibility, with status polled every second (Speech
   Recognition is optional). The user can continue without them; Settings keeps asking.
3. **Models and keys.**
   - Pick a setup plan (`OnboardingSetupPlan`): Claude with macOS voices, Claude with ElevenLabs, or OpenAI like
     HeyClicky.
   - Paste the keys it names. They are saved to the Keychain through the app's credential store.
   - The config is re-validated on every change. Only problems with listening, the voice or the brain block; agent and
     optional-slot problems are warnings.
4. **Test the voice.** One line through the voice slot. The user can skip this.
5. **Talk keys.** The current keys. Holding the voice chord while the window is in front counts as practice.
6. **Welcome chat.** A short interview in the realtime voice (details below). It never blocks: Skip, Continue or the
   model's `skip_onboarding_interview` tool moves on and keeps the answers given so far.
7. **Skills.** "What should it be good at?" over OpenClicky's starter skills (details below).
8. **First question.** Suggestions or the user's own question, sent to Home's chat. The user can also finish without
   asking.

Saved progress never stores permission status, a test line in flight or an open chat session. Permissions are always
read live; a chat that was open when the window closed starts again when the step reopens. `onboarding.json` files
written before the welcome chat and skills steps existed still load (every key is optional), so a finished onboarding
is not shown again.

### Welcome chat

`OnboardingMachine` keeps the chat in `OnboardingInterviewState`; `OnboardingInterviewPerformer` (OpenClickyKit) runs
its effects for the window, `occtl realtime --interview` and the tests alike.

- **Session.** Opening the step opens an always-on session on the realtime-voice slot (`AlwaysOnVoiceController`, on
  speakers too with the stricter echo gate, no reconnects) with `RealtimeInstructions.interview(answers: 4, …)` and only
  the skip tool. When it is on, the app sends a note asking for OpenClicky's fixed two-part opener
  (`OnboardingInterviewScript.opener`), shown as the first bubble.
- **Counting.** Each final user caption (or typed answer) is one answer. The app sends
  `RealtimeInstructions.interviewProgress` as a note without a reply (typed answers then go in as a message that asks
  for one). After the fourth answer, the next finished reply is the wrap-up and the chat ends.
- **Caption order.** Gemini settles an answer's caption after the reply to it. `OnboardingInterviewSession` holds a
  reply that finishes while the user's words are still open until the caption settles (or 2 s pass, then the partial
  words count), and a later, longer transcript of the same answer revises it instead of counting again.
- **Retry and typed fallback.** If the session can't be prepared (no realtime slot, a connection error), the step tries
  once more. After the second failure, or if the session drops mid-chat, the chat carries on typed with OpenClicky's
  own questions (`OnboardingInterviewScript.typedQuestions`, the AI-agents one always last) and a fixed close.
  "Or type here" also lets the user type into a live chat.
- **Saved.** On the wrap-up or a skip with answers, the transcript goes to `onboarding-interview.json` beside
  `config.json`, and the answers go into the memory profile (`about-the-user.md`) under **From the welcome chat**, each
  with the question it answered, replacing an earlier chat's section. The memory prompt puts profile sections in every
  later brain and always-on turn, which stands in for HeyClicky's `[About the user]` note.

`occtl realtime --interview [--simulate] [--in answer.wav] [--typed text]… [--skip-after n] [--memory dir]` runs the
same step headlessly: a sound file stands in for each spoken answer, typed answers go first, the voice goes to a WAV,
and it prints the transcript, the memory section and the next turn's memory context.

### Skills picker

`SkillPicker` (OpenClickyKit) builds the step from the starter catalog (`Resources/skills/catalog`, OpenClicky's own
skills only), grouped by the catalog's categories. Hand-made entries can bundle several skills ("Meetings and
follow-ups" switches on Meeting notes and Writing coach); any catalog skill no entry covers gets an entry of its own.

- The picks and a `firstLaunchDefaultsApplied` flag are saved in `skill-picks.json` beside `config.json`. The first
  time the step opens it picks Research and Writing; after that an emptied selection stays empty.
- Leaving the step switches the picked skills on in the library (copying them from the catalog when needed), so
  Settings → Skills shows them and background agents get them through the library's install sync. Unpicking switches
  off only skills the picker turned on.

`occtl onboarding simulate` walks the same machine headlessly:

- permissions come from `--grant`;
- the test line goes to a WAV with `--speak`;
- the first question goes to the brain with `--send`;
- the welcome chat is skipped (run it with `occtl realtime --interview`) and the skill picks are printed, not switched
  on.

## Skills

A skill is a folder under `~/Library/Application Support/OpenClicky/Skills/<id>/` with a `SKILL.md`: YAML-style front
matter, then Markdown.

```markdown
---
name: Pitch decks
description: Shapes Keynote slides around one message per slide and a clear ask at the end.
built_for: Keynote        # optional: applies fully only when this app is involved
tags: [slides, writing]   # optional
---
One idea per slide…
```

- **Parsing** (`SkillFile`). Handles quoted values, `|` and `>` blocks, inline and dashed lists, a BOM and CRLF line
  endings.
  - Without front matter, the name comes from the first heading (or the folder name) and the description from the first
    paragraph, with a warning.
  - Empty, non-Markdown, unreadable and oversized (>256 KB) files are reported with the reason.
- **On and off.** The state is in `skills.json` beside `config.json`. A skill found on disk starts off.
- **Brain.** `SkillsLibrary.skillsPromptSection()` (`ActiveSkillsProviding`) returns an `<active_skills>` block of
  names, apps and descriptions, sorted so the prompt prefix stays stable, budgeted (about 700 tokens), and with the
  block's tags neutralized inside skill text. The voice loop's brain runtime reads it through
  `BrainContextSources.skills` (`BrainWiring.skills`): into the system prompt (`BrainPromptOptions.skills`, a
  `# Skills` section) when a session starts, and, when the active set changes mid-session, as a `[Skill update]` note
  with the new block at the next turn, so the cached prompt stays the same. Push-to-talk, Home's typed chat and
  `send_to_higher_model` all get them this way.
- **Always-on.** `RealtimeInstructions.alwaysOn(skills:)` carries the block when a session opens; switching a skill
  on or off in Home or Settings (`SkillsModel.onActiveSkillsChange`) sends a running session a `[Skill update]`
  note without asking for a reply (`AlwaysOnVoiceLoop.addNote`).
- **Agents.** Active skills are installed into the job's harness at launch with OpenClicky's own agent skills, and the
  instructions name them; `skillsAgentInstructions()` returns "" so nothing is appended twice. See
  [skills.md](skills.md).
- **The page.** My Skills and Catalog tabs, search, a category filter, the edit form, Remove, Deactivate All and
  Create from Notes. See [skills.md](skills.md).
- **occtl.** `occtl skills list | search | enable | disable | deactivate-all | show | edit | remove | add | new |
  categories | catalog | create | creations | agent | prompt`. `OPENCLICKY_SKILLS_DIR` points at another folder.

## Evidence renders

`OpenClicky --render-snapshots <folder> [--history <dir>]` renders every Home tab, every Settings page and every
onboarding step offscreen from fixtures in a temporary folder.

- It uses an in-memory credential store, fixed permission states and no network.
- `--history` copies in a real history folder, for example one that `occtl history chat` wrote, and adds
  `home-chat-live.png`.
- Toggle switches render in their inactive-window grey, because the offscreen window is never key.

`OpenClicky --render-onboarding-snapshots <folder>` renders the welcome chat (preparing, live, typed fallback,
finished), the skills picker, the last step and Settings → Skills after the picks were switched on, from the same
fixtures.
