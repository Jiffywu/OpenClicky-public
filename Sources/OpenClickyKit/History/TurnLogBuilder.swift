import Foundation

/// Folds one turn's `TurnInput` and the `TurnEvent`s the brain streams back into a `HistoryTurn`.
///
/// Whoever consumes the brain's events (the turn orchestrator, the Home chat, `occtl history chat`) feeds each event
/// here as it arrives and appends `finish()` to the `HistoryStore`, so every surface writes the same record. Times
/// come from the clock passed in, so tests are exact.
public struct TurnLogBuilder: Sendable {
    public private(set) var turn: HistoryTurn
    private let start: Date
    private let clock: @Sendable () -> Date
    private var programText = ""
    private var lines: [Int: String] = [:]
    private var finished = false

    public init(input: TurnInput, sessionID: String, source: HistoryTurnSource? = nil, canvas: HistoryCanvas? = nil,
                id: String = UUID().uuidString, clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
        let now = clock()
        start = now
        let words = input.words.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSource = source ?? (input.isTyped ? .text : (words.isEmpty && input.context.trigger != nil ? .app : .voice))
        turn = HistoryTurn(id: id, sessionID: sessionID, startedAt: now, source: resolvedSource, words: words,
                           trigger: input.context.trigger, appNotes: input.appNotes, frontApp: input.context.frontApp,
                           canvas: canvas ?? Self.canvas(of: input))
    }

    /// The cursor screen's size in points, which is what drawing programs are laid out against.
    static func canvas(of input: TurnInput) -> HistoryCanvas? {
        guard let screen = input.screenshots.first(where: \.isCursorScreen) ?? input.screenshots.first else { return nil }
        return HistoryCanvas(width: screen.displayFrame.width, height: screen.displayFrame.height)
    }

    /// The drawing went on another screenshot than the one the record started with (`onScreen(n)`).
    public mutating func useCanvas(_ canvas: HistoryCanvas?) { turn.canvas = canvas }

    private var elapsedMs: Int { max(0, Int((clock().timeIntervalSince(start) * 1000).rounded())) }

    public mutating func apply(_ event: TurnEvent) {
        guard !finished else { return }
        let ms = elapsedMs
        switch event {
        case .status(let text):
            markFirstEvent(ms)
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, turn.statuses.last != text { turn.statuses.append(text) }
        case .programDelta(let text):
            markFirstEvent(ms)
            if turn.timings.firstProgramMs == nil, !text.isEmpty { turn.timings.firstProgramMs = ms }
            programText += text
        case .sayLine(let index, let text):
            markFirstEvent(ms)
            if turn.timings.firstLineMs == nil { turn.timings.firstLineMs = ms }
            lines[index] = text
        case .toolStarted(let name, _):
            turn.tools.append(name)
        case .toolFinished:
            break
        case .deferredAction(let action):
            turn.deferredActions.append(action.name)
        case .roundFinished(let round):
            turn.rounds = max(turn.rounds, round)
        case .finished(let summary):
            finished = true
            turn.outcome = .completed
            if !summary.program.isEmpty { programText = summary.program }
            if !summary.spokenLines.isEmpty {
                lines = Dictionary(uniqueKeysWithValues: summary.spokenLines.enumerated().map { ($0.offset, $0.element) })
            }
            turn.rounds = max(turn.rounds, summary.rounds)
            turn.usage = summary.usage.map(HistoryUsage.init)
            turn.model = summary.model.isEmpty ? nil : summary.model
            turn.timings.modelFirstTokenMs = summary.firstTokenSeconds.map { Int(($0 * 1000).rounded()) }
            turn.timings.totalMs = ms
        case .failed(let spoken, let detail):
            finished = true
            turn.outcome = .failed
            turn.errorSpoken = spoken
            turn.errorDetail = detail
            turn.timings.totalMs = ms
        }
    }

    private mutating func markFirstEvent(_ ms: Int) {
        if turn.timings.firstEventMs == nil { turn.timings.firstEventMs = ms }
    }

    /// The record to store. A turn that never saw `finished` or `failed` was cancelled.
    public func finish(narration: String? = nil) -> HistoryTurn {
        var result = turn
        if !finished {
            result.outcome = .cancelled
            result.timings.totalMs = elapsedMs
        }
        result.spokenLines = lines.keys.sorted().compactMap { lines[$0] }
        let program = programText.trimmingCharacters(in: .whitespacesAndNewlines)
        result.program = program.isEmpty ? nil : programText
        if let narration { result.narration = narration }
        return result
    }
}
