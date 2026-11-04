# Turn contract (orchestrator ⇄ brain runtime)

This file fixes the interface between the turn orchestrator (talk keys, mic, listening, screen capture, voice,
drawing) and the brain runtime (prompt, conversation thread, tools, the brain-slot model). Change it only in its own PR.
The Swift types are in `Sources/OpenClickyKit/Brain/TurnContracts.swift`.

## Flow of one voice turn
1. Key down: the orchestrator stops any speech and drawing in progress (barge-in), starts the mic and the stt session,
   makes sure the voice session is warm, and calls `brain.prewarm()`.
2. Key up: it finishes the stt session and gets the transcript. If nothing was heard, it says so and stops.
3. It captures the screens (cursor display first) and the context, then builds a `TurnInput`.
4. It calls `brain.run(input)` and consumes `TurnEvent`s:
   - `programDelta` → `DrawingEngineHost` (append program text; see docs/drawing-contract.md).
   - `sayLine(index, text)` → the voice slot, one line at a time, in order. When a line actually starts or finishes
     playing, the orchestrator tells the drawing engine (`lineStarted` / `lineFinished`) so strokes stay in sync.
   - `status` → notch / cursor bubble.
   - `deferredAction` → held until the narration is done, then run; dropped if a new turn starts first.
   - `finished` / `failed` → end of turn; `failed.spoken` is said aloud.
5. Afterwards the orchestrator reports the narration outcome (completed, cut off by the user, screen changed…) with
   `brain.recordOutcome(...)`. It becomes an `[App]` note in the next turn.

## Brain runtime responsibilities
- Owns the conversation thread (persisted under `~/Library/Application Support/OpenClicky/Brain/`), screenshot pruning,
  compaction on the brain-fast slot, prompt-cache friendliness, and session end with memory notes.
- Assembles OpenClicky's own prompt: persona and behavior, the drawing language (`docs/dsl.md`, `docs/dsl-3d.md`), how to
  point, the tools, and the turn context.
- Streams the model through `LanguageModelClient`. It strips code fences, emits `programDelta`, and runs
  `SayLineExtractor` to emit `sayLine` as soon as each line is complete.
- Runs tools: reads go back to the model in another round (up to a round limit); actions report a status word; actions
  that must wait for narration become `deferredAction`. Results arrive in the order the calls started. A call cancelled by
  a newer turn gets a "cancelled" result, and a call that never ran gets a "never ran" result.
- Never blocks the first spoken line on tools that are not needed for it.
