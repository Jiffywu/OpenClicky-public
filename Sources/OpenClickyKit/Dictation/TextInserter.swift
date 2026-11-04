import Foundation

/// One way of getting text into the focused field.
public enum InsertionStrategy: String, Codable, Sendable, CaseIterable {
    /// Replace the selection through Accessibility (`AXSelectedText`). Keeps undo and rich text in native apps.
    case accessibilitySelectedText = "ax-selected-text"
    /// Rewrite the whole value through Accessibility (`AXValue`) and move the caret. Plain single-line fields only.
    case accessibilityValue = "ax-value"
    /// Put the text on the clipboard, press Command-V in the target app, then put the old clipboard back.
    case paste
    /// Synthesize the characters as key events.
    case typing
}

/// Which strategies to try, in order, for a field. Built-in rules plus per-app overrides from settings.
public struct InsertionStrategyTable: Sendable, Equatable {
    /// Bundle identifier → strategies to try, in order. Wins over the built-in rules.
    public var overrides: [String: [InsertionStrategy]]

    public init(overrides: [String: [InsertionStrategy]] = [:]) { self.overrides = overrides }

    public static let standard = InsertionStrategyTable()

    public func strategies(for context: FocusContext, isElectron: Bool = false) -> [InsertionStrategy] {
        if let bundleID = context.bundleID, let custom = overrides[bundleID], !custom.isEmpty { return custom }
        // Terminals, browsers, Electron and apps with custom text views: Accessibility writes either fail or
        // change what is drawn without telling the app, so paste first.
        if context.surface == .terminal || AppTraits.prefersPaste(bundleID: context.bundleID, isElectron: isElectron) {
            return [.paste, .typing]
        }
        guard context.isEditable else { return [.paste, .typing] }
        var order: [InsertionStrategy] = [.accessibilitySelectedText]
        // Rewriting the whole value drops formatting and undo, so it is only a fallback for plain one-line fields.
        if context.isSingleLine && context.isValueReadable { order.append(.accessibilityValue) }
        order += [.paste, .typing]
        return order
    }
}

/// What happened to a dictation's text.
public enum InsertionOutcome: Sendable, Equatable {
    case inserted(InsertionStrategy)
    /// Nothing could type into the field, so the text was left on the clipboard for the user to paste.
    case copiedToClipboard(InsertionFailure)
    case refused(InsertionRefusal)
    case nothingToInsert
}

public enum InsertionFailure: String, Sendable, Equatable {
    /// Another app took focus between key-down and insertion.
    case focusLost
    /// No focused field was found at all.
    case noTarget
    /// Every strategy was tried and none worked.
    case strategiesFailed
    case pasteboardWriteFailed
}

public enum InsertionRefusal: String, Sendable, Equatable {
    /// The field is a password field.
    case secureField
    /// Some app has Secure Event Input on (a password prompt, a terminal's secure keyboard entry).
    case secureEventInput
    /// This process may not use Accessibility, so it cannot read focus or send keys.
    case accessibilityPermission
}

public struct InsertionReport: Sendable, Equatable {
    public struct Attempt: Sendable, Equatable {
        public var strategy: InsertionStrategy
        public var succeeded: Bool
        public var note: String?

        public init(strategy: InsertionStrategy, succeeded: Bool, note: String? = nil) {
            self.strategy = strategy
            self.succeeded = succeeded
            self.note = note
        }
    }

    public var outcome: InsertionOutcome
    public var attempts: [Attempt]
    /// The exact text that was typed (after spacing and line-break adjustments).
    public var insertedText: String
    /// The text was left on the clipboard (the fallback, or salvage after a refusal).
    public var copiedToClipboard: Bool
    /// The field the text went into, re-read at insertion time.
    public var target: CapturedFocus?

    public var appName: String? { target?.context.appName }
}

/// The operating-system side of insertion. `SystemTextInsertion` is the real one; tests script a fake.
public protocol TextInsertionSystem: Sendable {
    var pasteboard: any PasteboardAccess { get }
    func isAccessibilityTrusted() -> Bool
    func isSecureEventInputEnabled() -> Bool
    /// Re-reads the focused field now.
    func currentFocus() -> CapturedFocus?
    func frontmostProcessID() -> Int32?
    func isElectron(processID: Int32) -> Bool
    func value(of element: FocusElement) -> String?
    func setSelectedText(_ text: String, on element: FocusElement) -> Bool
    /// Sets the whole value, then puts the caret at `caret` (UTF-16 offset).
    func setValue(_ value: String, caret: Int, on element: FocusElement) -> Bool
    /// Presses Command-V for the given process.
    func postPaste(to processID: Int32) async -> Bool
    /// Types text as key events for the given process. Line breaks are Return, or Shift-Return when asked.
    func type(_ text: String, to processID: Int32, shiftNewlines: Bool) -> Bool
    func pause(seconds: Double) async
}

extension TextInsertionSystem {
    public func isElectron(processID: Int32) -> Bool { false }
    public func pause(seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
}

/// Puts dictated text into the field the user was in, trying strategies in order and falling back to the clipboard.
public struct TextInserter: Sendable {
    public var system: any TextInsertionSystem
    public var table: InsertionStrategyTable
    /// How long a target app gets to read the clipboard after Command-V before the old contents go back.
    public var pasteRestoreDelay: Double

    public init(system: any TextInsertionSystem, table: InsertionStrategyTable = .standard, pasteRestoreDelay: Double = 0.45) {
        self.system = system
        self.table = table
        self.pasteRestoreDelay = pasteRestoreDelay
    }

    public func insert(_ text: String, into captured: CapturedFocus?) async -> InsertionReport {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return InsertionReport(outcome: .nothingToInsert, attempts: [], insertedText: "", copiedToClipboard: false, target: captured)
        }
        if captured?.context.isSecure == true { return refuse(.secureField, captured) }
        if system.isSecureEventInputEnabled() { return refuse(.secureEventInput, captured) }
        guard system.isAccessibilityTrusted() else {
            let copied = system.pasteboard.writeText(trimmed)
            return InsertionReport(outcome: .refused(.accessibilityPermission), attempts: [], insertedText: trimmed,
                                   copiedToClipboard: copied, target: captured)
        }

        let current = system.currentFocus()
        let target: CapturedFocus
        var sameElement = false
        switch (captured, current) {
        case (nil, nil):
            return copyFallback(trimmed, .noTarget, attempts: [], target: nil)
        case (let captured?, nil):
            // Focus can't be re-read (some apps answer slowly). Trust the captured field if its app is still in front.
            guard system.frontmostProcessID() == captured.context.processID else {
                return copyFallback(trimmed, .focusLost, attempts: [], target: captured)
            }
            target = captured
            sameElement = captured.element != nil
        case (nil, let current?):
            target = current
            sameElement = true
        case (let captured?, let current?):
            guard current.context.processID == captured.context.processID else {
                return copyFallback(trimmed, .focusLost, attempts: [], target: current)
            }
            target = current
            // No element was known at key-down (only the app): the field focused now in that app is the target.
            sameElement = current.element != nil && (captured.element == nil || current.element == captured.element)
        }
        if target.context.isSecure { return refuse(.secureField, target) }

        let context = target.context
        let prepared = InsertionText.prepare(trimmed, before: context.beforeText, after: context.afterText,
                                             singleLine: context.isSingleLine)
        let order = table.strategies(for: context, isElectron: system.isElectron(processID: context.processID))
        var attempts: [InsertionReport.Attempt] = []
        for strategy in order {
            let (ok, note) = await attempt(strategy, text: prepared, target: target, elementStillFocused: sameElement)
            attempts.append(.init(strategy: strategy, succeeded: ok, note: note))
            if ok {
                return InsertionReport(outcome: .inserted(strategy), attempts: attempts, insertedText: prepared,
                                       copiedToClipboard: false, target: target)
            }
        }
        return copyFallback(trimmed, .strategiesFailed, attempts: attempts, target: target)
    }

    private func attempt(_ strategy: InsertionStrategy, text: String, target: CapturedFocus,
                         elementStillFocused: Bool) async -> (Bool, String?) {
        let context = target.context
        switch strategy {
        case .accessibilitySelectedText:
            guard elementStillFocused, let element = target.element else { return (false, "no element") }
            let before = system.value(of: element)
            guard system.setSelectedText(text, on: element) else { return (false, "AX write refused") }
            // Some apps accept the write and ignore it. When the value is readable, make sure it changed; give apps
            // that update a moment later one more look before falling through (falling through types it again).
            guard let before else { return (true, "unverified") }
            let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for attempt in 0..<2 {
                if attempt > 0 { await system.pause(seconds: 0.06) }
                if let after = system.value(of: element), after != before, after.contains(core) { return (true, nil) }
            }
            return (false, "AX write had no effect")
        case .accessibilityValue:
            guard elementStillFocused, let element = target.element, context.isValueReadable,
                  let value = system.value(of: element) else { return (false, "value unreadable") }
            let units = Array(value.utf16)
            let selection = context.selection ?? UTF16Range(location: units.count, length: 0)
            let start = min(max(selection.location, 0), units.count)
            let end = min(max(selection.end, start), units.count)
            let composed = UTF16Text.slice(units, 0, start) + text + UTF16Text.slice(units, end, units.count)
            let caret = start + text.utf16.count
            guard system.setValue(composed, caret: caret, on: element) else { return (false, "AX write refused") }
            for attempt in 0..<2 {
                if attempt > 0 { await system.pause(seconds: 0.06) }
                if system.value(of: element) == composed { return (true, nil) }
            }
            return (false, "AX write had no effect")
        case .paste:
            guard system.frontmostProcessID() == context.processID else { return (false, "target not frontmost") }
            let pasteboard = system.pasteboard
            let saved = pasteboard.snapshot()
            guard let written = pasteboard.writeTransientText(text) else { return (false, "clipboard write failed") }
            let posted = await system.postPaste(to: context.processID)
            await system.pause(seconds: pasteRestoreDelay)
            // Put the user's clipboard back unless someone copied something new in the meantime.
            if pasteboard.changeCount == written { pasteboard.restore(saved) }
            return posted ? (true, nil) : (false, "could not post Command-V")
        case .typing:
            guard system.frontmostProcessID() == context.processID else { return (false, "target not frontmost") }
            // In chat apps Return sends the message, so typed line breaks use Shift-Return.
            let shiftNewlines = context.surface == .chat
            return system.type(text, to: context.processID, shiftNewlines: shiftNewlines) ? (true, nil) : (false, "could not post key events")
        }
    }

    private func refuse(_ refusal: InsertionRefusal, _ target: CapturedFocus?) -> InsertionReport {
        // Text meant for a password prompt is never left on the clipboard.
        InsertionReport(outcome: .refused(refusal), attempts: [], insertedText: "", copiedToClipboard: false, target: target)
    }

    private func copyFallback(_ text: String, _ reason: InsertionFailure, attempts: [InsertionReport.Attempt],
                              target: CapturedFocus?) -> InsertionReport {
        let copied = system.pasteboard.writeText(text)
        return InsertionReport(outcome: .copiedToClipboard(copied ? reason : .pasteboardWriteFailed), attempts: attempts,
                               insertedText: text, copiedToClipboard: copied, target: target)
    }
}

/// Fits dictated text to the caret: no line breaks in one-line fields, and a space where words would run together.
public enum InsertionText {
    public static func prepare(_ text: String, before: String, after: String, singleLine: Bool) -> String {
        var result = text
        if singleLine {
            result = result.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        guard let first = result.first, let last = result.last else { return result }
        if let previous = before.last, !previous.isWhitespace, !opensGroup(previous), needsSpaceBefore(first),
           !isSpaceless(previous), !isSpaceless(first) {
            result = " " + result
        }
        if let next = after.first, isWordCharacter(next), !last.isWhitespace, !isSpaceless(next), !isSpaceless(last) {
            result += " "
        }
        return result
    }

    /// Scripts written without spaces between words (Chinese, Japanese, Thai) and full-width punctuation.
    static func isSpaceless(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(scalar) || (0xF900...0xFAFF).contains(scalar)
            || (0xFF00...0xFFEF).contains(scalar) || (0x0E00...0x0E7F).contains(scalar)
            || (0x20000...0x2FA1F).contains(scalar)
    }

    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    static func opensGroup(_ c: Character) -> Bool { "([{<\"'“‘/@#$`\u{2014}-".contains(c) }

    static func needsSpaceBefore(_ c: Character) -> Bool {
        isWordCharacter(c) || "\"“‘([{&$@#".contains(c)
    }
}
