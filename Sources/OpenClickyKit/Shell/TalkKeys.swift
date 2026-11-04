import Foundation

// Talk keys: the modifier-only shortcuts that start talking, typing and dictation. Kept free of AppKit so the rules
// (what a chord may be, which chords clash) are tested without a keyboard; the app maps `DictationModifier` sets to
// `NSEvent.ModifierFlags`.

/// What a talk key does.
public enum TalkKeyAction: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Hold to talk to OpenClicky.
    case voice
    /// Open the text box to type a question.
    case text
    /// Hold to dictate into the focused text field.
    case dictation
    /// Turn dictation on and off without holding anything (optional; off until the user records one).
    case handsFreeDictation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .voice: "Talk to OpenClicky"
        case .text: "Type a question"
        case .dictation: "Dictate into any text field"
        case .handsFreeDictation: "Hands-free dictation on and off"
        }
    }

    /// What the key is used for, in a sentence ("already used for dictation").
    public var purpose: String {
        switch self {
        case .voice: "talking to OpenClicky"
        case .text: "typing a question"
        case .dictation: "dictation"
        case .handsFreeDictation: "hands-free dictation"
        }
    }

    /// Whether the slot may be left empty (no key at all).
    public var isOptional: Bool { self == .handsFreeDictation }

    /// The kind of trigger the slot starts with (HeyClicky's defaults). Each slot may use either kind: a held chord
    /// or a double tap of one modifier (`TalkKeyGestureMachine` handles both for every slot).
    public var defaultTriggerKind: TalkKeyTrigger.Kind {
        switch self {
        case .voice, .dictation: .hold
        case .text, .handsFreeDictation: .doubleTap
        }
    }

    /// The default kind (kept for callers written before kinds were per slot).
    public var triggerKind: TalkKeyTrigger.Kind { defaultTriggerKind }

    /// What each kind does for this slot, for Settings.
    public func explain(_ kind: TalkKeyTrigger.Kind) -> String {
        switch (self, kind) {
        case (.voice, .hold): "Hold two or more modifier keys while you talk"
        case (.voice, .doubleTap): "Double-tap one modifier to start talking; tap it once more when you're done"
        case (.text, .hold): "Press two or more modifier keys together and let go"
        case (.text, .doubleTap): "Double-tap one modifier key (a triple tap toggles always-on voice)"
        case (.dictation, .hold): "Hold two or more modifier keys while you speak"
        case (.dictation, .doubleTap): "Double-tap one modifier to start dictating; double-tap again to finish"
        case (.handsFreeDictation, .hold): "Press two or more modifier keys together to start or finish"
        case (.handsFreeDictation, .doubleTap): "Double-tap one modifier key to start or finish"
        }
    }
}

/// A modifier-only shortcut: hold a chord, or double-tap one modifier.
public struct TalkKeyTrigger: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case hold, doubleTap

        /// Also reads HeyClicky's names for the two kinds (`holdCombo`, `doubleTapModifier`).
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "hold", "holdCombo": self = .hold
            case "doubleTap", "doubleTapModifier": self = .doubleTap
            default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown talk key kind \(raw)"))
            }
        }

        public var title: String {
            switch self {
            case .hold: "Hold keys"
            case .doubleTap: "Double-tap"
            }
        }
    }

    public var kind: Kind
    public var modifiers: Set<DictationModifier>

    public init(_ kind: Kind, _ modifiers: Set<DictationModifier>) {
        self.kind = kind
        self.modifiers = modifiers
    }

    public static func hold(_ modifiers: DictationModifier...) -> TalkKeyTrigger { TalkKeyTrigger(.hold, Set(modifiers)) }
    public static func doubleTap(_ modifier: DictationModifier) -> TalkKeyTrigger { TalkKeyTrigger(.doubleTap, [modifier]) }

    /// Modifiers in the order macOS menus show them.
    public static let displayOrder: [DictationModifier] = [.function, .control, .option, .shift, .command]

    public var orderedModifiers: [DictationModifier] { Self.displayOrder.filter(modifiers.contains) }

    /// "⌃⌥", "fn ⌃", "⌃ ⌃" (double tap).
    public var symbol: String {
        let set = modifiers
        var parts: [String] = []
        if set.contains(.function) { parts.append("fn") }
        var symbols = ""
        if set.contains(.control) { symbols += "⌃" }
        if set.contains(.option) { symbols += "⌥" }
        if set.contains(.shift) { symbols += "⇧" }
        if set.contains(.command) { symbols += "⌘" }
        if !symbols.isEmpty { parts.append(symbols) }
        let chord = parts.joined(separator: " ")
        return kind == .doubleTap ? "\(chord) \(chord)" : chord
    }

    /// "Hold Control and Option", "Double-tap Control".
    public var phrase: String {
        let names = orderedModifiers.map(Self.name)
        let list = names.count <= 1 ? names.joined()
            : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return kind == .doubleTap ? "Double-tap \(list)" : "Hold \(list)"
    }

    public static func name(_ modifier: DictationModifier) -> String {
        switch modifier {
        case .control: "Control"
        case .option: "Option"
        case .command: "Command"
        case .shift: "Shift"
        case .function: "Fn"
        }
    }

    // Stored as {"kind":"hold","modifiers":["control","option"]} with modifiers in display order.
    private enum CodingKeys: String, CodingKey { case kind, modifiers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        modifiers = Set(try c.decode([DictationModifier].self, forKey: .modifiers))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(orderedModifiers, forKey: .modifiers)
    }
}

/// Why a trigger can't be used, or what to watch out for.
public struct TalkKeyProblem: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable { case blocking, warning }
    public var severity: Severity
    public var message: String
    /// The other action involved, for clashes.
    public var other: TalkKeyAction?

    public init(_ severity: Severity, _ message: String, other: TalkKeyAction? = nil) {
        self.severity = severity
        self.message = message
        self.other = other
    }

    public var description: String { "\(severity.rawValue): \(message)" }
}

/// The four talk keys. Saved at `~/Library/Application Support/OpenClicky/talk-keys.json`; the dictation chord is
/// also written to dictation.json, which the dictation feature reads.
public struct TalkKeySettings: Codable, Sendable, Hashable {
    public var voice: TalkKeyTrigger
    public var text: TalkKeyTrigger
    public var dictation: TalkKeyTrigger
    /// A double tap of one modifier that turns dictation on and, tapped again, finishes it. Nil: no separate key
    /// (a double tap of the dictation chord still locks it on when that is allowed in dictation settings).
    public var handsFreeDictation: TalkKeyTrigger?

    /// HeyClicky's defaults: hold Control+Option to talk, double-tap Control to type, hold Control+Fn to dictate. The
    /// hands-free key starts empty: every single-modifier double tap is either taken (Control), used by macOS (Fn,
    /// Command) or easy to hit by accident, so the user picks one.
    public static let defaults = TalkKeySettings(voice: .hold(.control, .option), text: .doubleTap(.control),
                                                 dictation: .hold(.control, .function))

    public init(voice: TalkKeyTrigger, text: TalkKeyTrigger, dictation: TalkKeyTrigger, handsFreeDictation: TalkKeyTrigger? = nil) {
        self.voice = voice
        self.text = text
        self.dictation = dictation
        self.handsFreeDictation = handsFreeDictation
    }

    /// The key for an action; nil only for an optional slot left empty.
    public subscript(action: TalkKeyAction) -> TalkKeyTrigger? {
        get {
            switch action {
            case .voice: voice
            case .text: text
            case .dictation: dictation
            case .handsFreeDictation: handsFreeDictation
            }
        }
        set {
            switch action {
            case .voice: if let newValue { voice = newValue }
            case .text: if let newValue { text = newValue }
            case .dictation: if let newValue { dictation = newValue }
            case .handsFreeDictation: handsFreeDictation = newValue
            }
        }
    }

    public static var defaultURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("talk-keys.json")
    }

    /// The saved keys; defaults for anything missing or unreadable. A dictation chord saved in dictation.json wins
    /// over this file's while dictation is a held chord, since dictation reads that file.
    ///
    /// Migration: files written before kinds were per slot have a kind on every key already, and each slot then only
    /// accepted its default kind, so they load unchanged. A key saved without a kind takes the slot's default kind,
    /// and HeyClicky's kind names (`holdCombo`, `doubleTapModifier`) are read too.
    public static func load(from url: URL = defaultURL, dictationURL: URL? = DictationSettings.defaultURL) -> TalkKeySettings {
        var settings = defaults
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Partial.self, from: data) {
            for action in TalkKeyAction.allCases {
                guard let raw = saved[action] else { continue }
                let trigger = TalkKeyTrigger(raw.kind ?? action.defaultTriggerKind, Set(raw.modifiers))
                if TalkKeyRules.validShape(trigger, for: action) { settings[action] = trigger }
            }
        }
        if settings.dictation.kind == .hold, let dictationURL, FileManager.default.fileExists(atPath: dictationURL.path) {
            let chord = TalkKeyTrigger(.hold, Set(DictationSettings.load(from: dictationURL).holdChord))
            if TalkKeyRules.validShape(chord, for: .dictation) { settings.dictation = chord }
        }
        return settings
    }

    /// Saves the keys, and the dictation chord into dictation.json (keeping its other settings).
    public func save(to url: URL = defaultURL, dictationURL: URL? = DictationSettings.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        // dictation.json only knows a held chord; a double-tap dictation key leaves its chord as it was.
        if let dictationURL, dictation.kind == .hold {
            var dictationSettings = DictationSettings.load(from: dictationURL)
            dictationSettings.holdChord = dictation.orderedModifiers
            try dictationSettings.save(to: dictationURL)
        }
    }

    /// Every problem with the set as a whole.
    public var problems: [TalkKeyAction: [TalkKeyProblem]] {
        var result: [TalkKeyAction: [TalkKeyProblem]] = [:]
        for action in TalkKeyAction.allCases {
            guard let trigger = self[action] else { continue }
            let problems = TalkKeyRules.problems(trigger, for: action, in: self)
            if !problems.isEmpty { result[action] = problems }
        }
        return result
    }

    /// A saved key as written, with the kind optional (older or hand-written files).
    private struct RawTrigger: Decodable {
        var kind: TalkKeyTrigger.Kind?
        var modifiers: [DictationModifier]
    }

    private struct Partial: Decodable {
        var voice: RawTrigger?
        var text: RawTrigger?
        var dictation: RawTrigger?
        var handsFreeDictation: RawTrigger?

        subscript(action: TalkKeyAction) -> RawTrigger? {
            switch action {
            case .voice: voice
            case .text: text
            case .dictation: dictation
            case .handsFreeDictation: handsFreeDictation
            }
        }
    }
}

/// What a talk key may be, and which keys get in each other's way.
public enum TalkKeyRules {
    /// A sensible number of modifiers for the kind: hold chords need two or more (holding one modifier alone happens
    /// all the time while typing), double taps exactly one. Any slot may use either kind.
    public static func validShape(_ trigger: TalkKeyTrigger, for action: TalkKeyAction) -> Bool {
        shapeProblem(trigger, for: action) == nil
    }

    static func shapeProblem(_ trigger: TalkKeyTrigger, for action: TalkKeyAction) -> TalkKeyProblem? {
        switch trigger.kind {
        case .hold:
            if trigger.modifiers.count < 2 {
                return TalkKeyProblem(.blocking, "Hold at least two modifier keys together; one key alone is pressed all the time while typing.")
            }
            if trigger.modifiers.count > 4 {
                return TalkKeyProblem(.blocking, "That's too many keys to hold comfortably.")
            }
        case .doubleTap:
            if trigger.modifiers.count != 1 {
                return TalkKeyProblem(.blocking, "A double tap uses exactly one modifier key.")
            }
        }
        return nil
    }

    /// Problems with putting `trigger` on `action`, given the other keys in `settings`.
    public static func problems(_ trigger: TalkKeyTrigger, for action: TalkKeyAction, in settings: TalkKeySettings) -> [TalkKeyProblem] {
        if let shape = shapeProblem(trigger, for: action) { return [shape] }
        var problems: [TalkKeyProblem] = []
        for other in TalkKeyAction.allCases where other != action {
            guard let theirs = settings[other] else { continue }
            if theirs == trigger {
                problems.append(TalkKeyProblem(.blocking, "\(trigger.symbol) is already used for \(other.purpose).", other: other))
            } else if trigger.kind == .hold, theirs.kind == .hold,
                      trigger.modifiers.isSubset(of: theirs.modifiers) || theirs.modifiers.isSubset(of: trigger.modifiers) {
                // Pressing the bigger chord passes through the smaller one, which starts first.
                problems.append(TalkKeyProblem(.blocking,
                    "\(trigger.symbol) overlaps \(theirs.symbol), which is used for \(other.purpose): pressing one would start the other.",
                    other: other))
            }
        }
        problems += systemWarnings(trigger)
        return problems
    }

    /// Shortcuts macOS itself commonly uses.
    static func systemWarnings(_ trigger: TalkKeyTrigger) -> [TalkKeyProblem] {
        var warnings: [TalkKeyProblem] = []
        if trigger.kind == .doubleTap, trigger.modifiers == [.function] {
            warnings.append(TalkKeyProblem(.warning, "macOS Dictation often uses a double tap of Fn (Globe). Turn that off in System Settings → Keyboard, or pick another key."))
        }
        if trigger.kind == .doubleTap, trigger.modifiers == [.command] {
            warnings.append(TalkKeyProblem(.warning, "Siri can be set to a double tap of Command; check System Settings → Siri if both start."))
        }
        if trigger.kind == .hold, trigger.modifiers == [.command, .option] {
            warnings.append(TalkKeyProblem(.warning, "Command+Option is part of many app shortcuts; you may start talking by accident."))
        }
        return warnings
    }
}

/// Records a talk key from raw modifier changes, the way the Settings recorder and onboarding use it.
///
/// Feed it every modifier change while recording. For hold chords it remembers the largest set held together and
/// proposes it when all keys are released; for a double tap it proposes the single modifier that was pressed and
/// released. Any ordinary key cancels with an explanation; Escape cancels quietly. The result is then checked
/// against the other talk keys.
public struct TalkKeyRecorder: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case idle
        /// Waiting for keys; `held` is what is down right now, `peak` the most held together so far.
        case recording(held: Set<DictationModifier>, peak: Set<DictationModifier>)
        /// A usable key (warnings, if any, should be shown).
        case captured(TalkKeyTrigger, warnings: [TalkKeyProblem])
        /// The keys pressed can't be used; recording again is up to the user.
        case rejected(TalkKeyTrigger?, reason: String)
        case cancelled
    }

    public let action: TalkKeyAction
    /// What is being recorded: a held chord or the modifier to double-tap. Starts as the slot's current kind.
    public let kind: TalkKeyTrigger.Kind
    public private(set) var state: State = .idle
    public var settings: TalkKeySettings

    public init(action: TalkKeyAction, settings: TalkKeySettings, kind: TalkKeyTrigger.Kind? = nil) {
        self.action = action
        self.settings = settings
        self.kind = kind ?? settings[action]?.kind ?? action.defaultTriggerKind
    }

    public var isRecording: Bool { if case .recording = state { true } else { false } }

    /// What to show while recording.
    public var prompt: String {
        switch state {
        case .idle: return "Click Record, then press the keys."
        case .recording(let held, _):
            if held.isEmpty {
                return kind == .hold ? "Press and hold the modifier keys you want, then let go." : "Press the modifier key you want to double-tap."
            }
            return TalkKeyTrigger(.hold, held).symbol
        case .captured(let trigger, _): return trigger.phrase
        case .rejected(_, let reason): return reason
        case .cancelled: return "Recording cancelled."
        }
    }

    public mutating func start() { state = .recording(held: [], peak: []) }

    public mutating func cancel() { if isRecording { state = .cancelled } }

    /// The modifiers held now, after any change.
    public mutating func modifiersChanged(_ held: Set<DictationModifier>) {
        guard case .recording(_, var peak) = state else { return }
        if !held.isEmpty {
            // The most keys held at once; among equally big sets, the latest (the user changed their mind).
            if held.count >= peak.count { peak = held }
            state = .recording(held: held, peak: peak)
            return
        }
        guard !peak.isEmpty else {
            state = .recording(held: [], peak: [])
            return
        }
        conclude(with: TalkKeyTrigger(kind, peak))
    }

    /// A non-modifier key went down while recording.
    public mutating func keyPressed(isEscape: Bool) {
        guard isRecording else { return }
        state = isEscape ? .cancelled : .rejected(nil, reason: "Talk keys use only modifier keys: Control, Option, Shift, Command and Fn.")
    }

    private mutating func conclude(with trigger: TalkKeyTrigger) {
        let problems = TalkKeyRules.problems(trigger, for: action, in: settings)
        if let blocking = problems.first(where: { $0.severity == .blocking }) {
            state = .rejected(trigger, reason: blocking.message)
        } else {
            state = .captured(trigger, warnings: problems)
        }
    }

    /// Applies a captured key to the settings and returns them; nil unless a key was captured.
    public func applied() -> TalkKeySettings? {
        guard case .captured(let trigger, _) = state else { return nil }
        var updated = settings
        updated[action] = trigger
        return updated
    }
}
