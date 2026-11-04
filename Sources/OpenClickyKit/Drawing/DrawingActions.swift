import AppKit
import Foundation

/// Carries out a drawing's actions (docs/dsl.md, "Actions"): `typeText`, `copyText`, `openPage`, `handOff` and `sfx`,
/// when their line is heard, and the open, copy and hand-off buttons and linked words when they are clicked.
///
/// Every side effect goes through a closure, so tests and `occtl` run it without touching the Mac. Typing never presses
/// Return (line breaks become spaces) and falls back to the clipboard when nothing could take the words; pages open
/// only over http or https, and a spoken answer opens at most one.
@MainActor
public final class DrawingActionPerformer {
    public struct Outcome: Sendable, Hashable {
        public var action: DrawingAction
        /// What happened, in a few words ("typed", "copied instead", "opened", "no agent to hand to", …).
        public var result: String
        public var succeeded: Bool
    }

    /// Writes text the user keeps on the clipboard.
    public var copy: (String) -> Bool
    public var open: (URL) -> Bool
    /// Types into the focused field; nil (or false back) copies the words instead.
    public var type: ((String) async -> Bool)?
    public var playSound: ((String) -> Void)?
    /// Starts a background agent on a task with an optional short title; returns false when there is none.
    public var handOff: ((String, String?) async -> Bool)?
    /// Every action and its outcome, newest last (the last 50).
    public private(set) var history: [Outcome] = []
    private var spokenOpens = 0
    /// The last action queued, so the next one waits for it (see `perform`).
    private var queue: Task<Outcome, Never>?

    public init(copy: @escaping (String) -> Bool = { SystemPasteboard().writeText($0) },
                open: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
                type: ((String) async -> Bool)? = nil, playSound: ((String) -> Void)? = nil,
                handOff: ((String, String?) async -> Bool)? = nil) {
        self.copy = copy
        self.open = open
        self.type = type
        self.playSound = playSound
        self.handOff = handOff
    }

    /// A new answer began: it may open a page again.
    public func newAnswer() { spokenOpens = 0 }

    /// Carries out `action` after every action handed in before it has finished. Typing and copying share the
    /// clipboard: typing writes the words there, pastes and puts the user's clipboard back a moment later, so two
    /// actions due together must not overlap. A sound plays at once; it touches neither the clipboard nor the caret.
    @discardableResult
    public func perform(_ action: DrawingAction) async -> Outcome {
        if action.role == .sfx { return await carryOut(action) }
        let previous = queue
        let task = Task { () -> Outcome in
            _ = await previous?.value
            return await self.carryOut(action)
        }
        queue = task
        return await task.value
    }

    private func carryOut(_ action: DrawingAction) async -> Outcome {
        let outcome: Outcome
        switch action.role {
        case .copy:
            let ok = copy(action.text ?? "")
            outcome = Outcome(action: action, result: ok ? "copied" : "the clipboard refused it", succeeded: ok)
        case .type:
            // Never Return: a line break would send a message or submit a form the user didn't mean to.
            let words = (action.text ?? "").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            if let type, await type(words) {
                outcome = Outcome(action: action, result: "typed", succeeded: true)
            } else {
                let ok = copy(words)
                outcome = Outcome(action: action, result: ok ? "copied instead" : "couldn't type or copy", succeeded: ok)
            }
        case .open:
            guard let url = action.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                outcome = Outcome(action: action, result: "not a web page", succeeded: false)
                break
            }
            if !action.fromClick {
                guard spokenOpens == 0 else {
                    outcome = Outcome(action: action, result: "one page per answer", succeeded: false)
                    break
                }
                spokenOpens += 1
            }
            let ok = open(url)
            outcome = Outcome(action: action, result: ok ? "opened" : "couldn't open", succeeded: ok)
        case .sfx:
            if let playSound, let name = action.text, DrawingSounds.accents.contains(name) {
                playSound(name)
                outcome = Outcome(action: action, result: "played", succeeded: true)
            } else {
                outcome = Outcome(action: action, result: "no sound", succeeded: false)
            }
        case .handoff:
            if let handOff, let task = action.text, await handOff(task, action.label) {
                outcome = Outcome(action: action, result: "handed off", succeeded: true)
            } else {
                outcome = Outcome(action: action, result: "no agent to hand to", succeeded: false)
            }
        }
        history.append(outcome)
        if history.count > 50 { history.removeFirst(history.count - 50) }
        return outcome
    }
}
