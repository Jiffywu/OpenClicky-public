import Carbon.HIToolbox
import CoreGraphics
import Foundation

// The provider-neutral vocabulary of a take-over drive: what the model may ask the Mac to do, in the coordinates
// of the screenshot it was shown. Anthropic's computer tool, the generic function-calling schema and the occtl
// scripts all parse into `DriveAction` with `DriveActionParser`. See docs/takeover.md.

/// Where an action lands, as the model named it.
public enum DriveTarget: Sendable, Hashable {
    /// Pixels in the latest screenshot the model saw (origin top-left, y down).
    case pixel(x: Double, y: Double)
    /// An Accessibility element id from the observation's element list ("e12").
    case element(String)

    public var summary: String {
        switch self {
        case .pixel(let x, let y): "(\(Int(x.rounded())), \(Int(y.rounded())))"
        case .element(let id): id
        }
    }
}

public enum DriveMouseButton: String, Sendable, Hashable, Codable {
    case left, right, middle
}

public enum DriveScrollDirection: String, Sendable, Hashable, Codable, CaseIterable {
    case up, down, left, right
}

/// Modifier keys held during a click, scroll or key press.
public struct DriveModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = DriveModifiers(rawValue: 1 << 0)
    public static let control = DriveModifiers(rawValue: 1 << 1)
    public static let option = DriveModifiers(rawValue: 1 << 2)
    public static let command = DriveModifiers(rawValue: 1 << 3)
    public static let function = DriveModifiers(rawValue: 1 << 4)

    /// Accepts the names models use: xdotool style (`ctrl`, `alt`, `super`) and Mac style (`cmd`, `option`).
    public static func named(_ name: String) -> DriveModifiers? {
        switch name.lowercased() {
        case "shift": .shift
        case "ctrl", "control", "ctl": .control
        case "alt", "option", "opt": .option
        case "super", "cmd", "command", "meta", "win", "windows": .command
        case "fn", "function": .function
        default: nil
        }
    }

    /// Parses `"ctrl+shift"`; nil when any part is not a modifier. An empty string means none.
    public static func parse(_ text: String) -> DriveModifiers? {
        let parts = text.split(whereSeparator: { $0 == "+" || $0 == " " }).map(String.init)
        var result: DriveModifiers = []
        for part in parts {
            guard let modifier = named(part) else { return nil }
            result.insert(modifier)
        }
        return result
    }

    public var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// "cmd+shift", in a fixed order.
    public var summary: String {
        var names: [String] = []
        if contains(.control) { names.append("ctrl") }
        if contains(.option) { names.append("option") }
        if contains(.shift) { names.append("shift") }
        if contains(.command) { names.append("cmd") }
        if contains(.function) { names.append("fn") }
        return names.joined(separator: "+")
    }
}

/// One key on the keyboard, by its macOS virtual key code (ANSI positions).
public struct DriveKey: Sendable, Hashable {
    public var name: String
    public var keyCode: CGKeyCode

    public init(name: String, keyCode: CGKeyCode) {
        self.name = name
        self.keyCode = keyCode
    }

    /// Key names models use (xdotool keysyms such as `Return`, `Page_Down`, `BackSpace`), Mac names and single
    /// characters on the ANSI layout. Lookups are case-insensitive except for single characters, which are
    /// lowercased first.
    public static func named(_ raw: String) -> DriveKey? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if name.count == 1, let code = characterKeys[name.lowercased()] { return DriveKey(name: name.lowercased(), keyCode: code) }
        let lowered = name.lowercased().replacingOccurrences(of: "-", with: "_")
        if let code = namedKeys[lowered] { return DriveKey(name: name, keyCode: code) }
        if lowered.hasPrefix("f"), let number = Int(lowered.dropFirst()), (1...20).contains(number) {
            return DriveKey(name: "F\(number)", keyCode: functionKeys[number - 1])
        }
        return nil
    }

    /// For a modifier key pressed on its own, the flag it sets while down (macOS reports these as flagsChanged).
    public var modifierFlag: CGEventFlags? {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift: .maskShift
        case kVK_Control, kVK_RightControl: .maskControl
        case kVK_Option, kVK_RightOption: .maskAlternate
        case kVK_Command, kVK_RightCommand: .maskCommand
        case kVK_Function: .maskSecondaryFn
        default: nil
        }
    }

    static let namedKeys: [String: CGKeyCode] = [
        "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return), "kp_enter": CGKeyCode(kVK_ANSI_KeypadEnter),
        "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
        "backspace": CGKeyCode(kVK_Delete), "back_space": CGKeyCode(kVK_Delete),
        // xdotool's Delete is the forward delete key; the Mac's "delete" key is BackSpace.
        "delete": CGKeyCode(kVK_ForwardDelete), "forward_delete": CGKeyCode(kVK_ForwardDelete), "del": CGKeyCode(kVK_ForwardDelete),
        "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
        "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow), "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        "arrowup": CGKeyCode(kVK_UpArrow), "arrowdown": CGKeyCode(kVK_DownArrow), "arrowleft": CGKeyCode(kVK_LeftArrow),
        "arrowright": CGKeyCode(kVK_RightArrow),
        "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
        "page_up": CGKeyCode(kVK_PageUp), "pageup": CGKeyCode(kVK_PageUp), "prior": CGKeyCode(kVK_PageUp),
        "page_down": CGKeyCode(kVK_PageDown), "pagedown": CGKeyCode(kVK_PageDown), "next": CGKeyCode(kVK_PageDown),
        "minus": CGKeyCode(kVK_ANSI_Minus), "equal": CGKeyCode(kVK_ANSI_Equal), "plus": CGKeyCode(kVK_ANSI_Equal),
        "bracketleft": CGKeyCode(kVK_ANSI_LeftBracket), "bracketright": CGKeyCode(kVK_ANSI_RightBracket),
        "backslash": CGKeyCode(kVK_ANSI_Backslash), "semicolon": CGKeyCode(kVK_ANSI_Semicolon),
        "apostrophe": CGKeyCode(kVK_ANSI_Quote), "quote": CGKeyCode(kVK_ANSI_Quote), "grave": CGKeyCode(kVK_ANSI_Grave),
        "comma": CGKeyCode(kVK_ANSI_Comma), "period": CGKeyCode(kVK_ANSI_Period), "slash": CGKeyCode(kVK_ANSI_Slash),
        "capslock": CGKeyCode(kVK_CapsLock), "caps_lock": CGKeyCode(kVK_CapsLock),
        "volumeup": CGKeyCode(kVK_VolumeUp), "volumedown": CGKeyCode(kVK_VolumeDown), "mute": CGKeyCode(kVK_Mute),
        // Modifier keys pressed on their own (rare, but models do send "shift" or "super").
        "shift": CGKeyCode(kVK_Shift), "shift_l": CGKeyCode(kVK_Shift), "shift_r": CGKeyCode(kVK_RightShift),
        "ctrl": CGKeyCode(kVK_Control), "control": CGKeyCode(kVK_Control), "control_l": CGKeyCode(kVK_Control),
        "alt": CGKeyCode(kVK_Option), "option": CGKeyCode(kVK_Option), "alt_l": CGKeyCode(kVK_Option),
        "super": CGKeyCode(kVK_Command), "super_l": CGKeyCode(kVK_Command), "cmd": CGKeyCode(kVK_Command),
        "command": CGKeyCode(kVK_Command), "meta": CGKeyCode(kVK_Command),
        "fn": CGKeyCode(kVK_Function),
    ]

    static let characterKeys: [String: CGKeyCode] = [
        "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C), "d": CGKeyCode(kVK_ANSI_D),
        "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F), "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H),
        "i": CGKeyCode(kVK_ANSI_I), "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O), "p": CGKeyCode(kVK_ANSI_P),
        "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R), "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T),
        "u": CGKeyCode(kVK_ANSI_U), "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
        "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2), "3": CGKeyCode(kVK_ANSI_3),
        "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5), "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7),
        "8": CGKeyCode(kVK_ANSI_8), "9": CGKeyCode(kVK_ANSI_9),
        "-": CGKeyCode(kVK_ANSI_Minus), "=": CGKeyCode(kVK_ANSI_Equal), "[": CGKeyCode(kVK_ANSI_LeftBracket),
        "]": CGKeyCode(kVK_ANSI_RightBracket), "\\": CGKeyCode(kVK_ANSI_Backslash), ";": CGKeyCode(kVK_ANSI_Semicolon),
        "'": CGKeyCode(kVK_ANSI_Quote), "`": CGKeyCode(kVK_ANSI_Grave), ",": CGKeyCode(kVK_ANSI_Comma),
        ".": CGKeyCode(kVK_ANSI_Period), "/": CGKeyCode(kVK_ANSI_Slash), " ": CGKeyCode(kVK_Space),
    ]

    static let functionKeys: [CGKeyCode] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].map { CGKeyCode($0) }
}

/// A key with modifiers: `"cmd+shift+s"`, `"Return"`, `"ctrl+c"`.
public struct KeyCombo: Sendable, Hashable {
    public var modifiers: DriveModifiers
    public var key: DriveKey

    public init(modifiers: DriveModifiers = [], key: DriveKey) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Parses a `+`-joined combination. The last part is the key; every other part must be a modifier. A lone
    /// modifier ("shift") is a key press of that modifier. `"+"` and `"ctrl++"` name the plus key.
    public static func parse(_ raw: String) -> KeyCombo? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        // A trailing "+" key: "ctrl++" splits into ["ctrl", "", ""].
        if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" {
            parts.removeLast(2)
            parts.append("plus")
        }
        if parts == [""] || parts == ["", ""] { return KeyCombo(key: DriveKey(name: "plus", keyCode: CGKeyCode(kVK_ANSI_Equal))) }
        guard let keyName = parts.last, !keyName.isEmpty, let key = DriveKey.named(keyName) else { return nil }
        var modifiers: DriveModifiers = []
        for part in parts.dropLast() {
            guard let modifier = DriveModifiers.named(part) else { return nil }
            modifiers.insert(modifier)
        }
        return KeyCombo(modifiers: modifiers, key: key)
    }

    public var summary: String {
        let mods = modifiers.summary
        return mods.isEmpty ? key.name : "\(mods)+\(key.name)"
    }
}

/// One thing the model asked for, before it is checked, mapped and performed.
public enum DriveAction: Sendable, Hashable {
    /// A fresh screenshot (no input).
    case screenshot
    /// A closer look at a region of the latest screenshot, in its pixels (no input).
    case zoom(region: CGRect)
    /// Where the drive cursor is, in screenshot pixels (no input).
    case cursorPosition
    case moveMouse(to: DriveTarget)
    /// `count` 1, 2 or 3 for single, double and triple clicks. A nil target clicks where the cursor is.
    case click(at: DriveTarget?, button: DriveMouseButton, count: Int, modifiers: DriveModifiers)
    case mouseDown(at: DriveTarget?)
    case mouseUp(at: DriveTarget?)
    case drag(from: DriveTarget, to: DriveTarget, modifiers: DriveModifiers)
    /// `amount` is wheel clicks (lines).
    case scroll(at: DriveTarget?, direction: DriveScrollDirection, amount: Int, modifiers: DriveModifiers)
    case type(text: String)
    case key(KeyCombo, repeatCount: Int)
    case holdKey(KeyCombo, seconds: Double)
    case wait(seconds: Double)

    /// The action only looks or waits: nothing reaches the Mac's input.
    public var isObservation: Bool {
        switch self {
        case .screenshot, .zoom, .cursorPosition, .wait: true
        default: false
        }
    }

    /// The targets this action lands on, in order (a drag has two).
    public var targets: [DriveTarget] {
        switch self {
        case .moveMouse(let target): [target]
        case .click(let target, _, _, _), .mouseDown(let target), .mouseUp(let target), .scroll(let target, _, _, _):
            target.map { [$0] } ?? []
        case .drag(let from, let to, _): [from, to]
        default: []
        }
    }

    /// A short line for logs, the overlay and the report: "double click (412, 300) with cmd".
    public var summary: String {
        func with(_ modifiers: DriveModifiers) -> String { modifiers.isEmpty ? "" : " with \(modifiers.summary)" }
        switch self {
        case .screenshot: return "take a screenshot"
        case .zoom(let region):
            return "zoom into [\(Int(region.minX)), \(Int(region.minY)), \(Int(region.maxX)), \(Int(region.maxY))]"
        case .cursorPosition: return "read the cursor position"
        case .moveMouse(let target): return "move the pointer to \(target.summary)"
        case .click(let target, let button, let count, let modifiers):
            let kind = count == 3 ? "triple click" : count == 2 ? "double click" : button == .left ? "click" : "\(button.rawValue) click"
            return "\(kind) \(target?.summary ?? "where the pointer is")\(with(modifiers))"
        case .mouseDown(let target): return "press the mouse button at \(target?.summary ?? "the pointer")"
        case .mouseUp(let target): return "release the mouse button at \(target?.summary ?? "the pointer")"
        case .drag(let from, let to, let modifiers): return "drag from \(from.summary) to \(to.summary)\(with(modifiers))"
        case .scroll(let target, let direction, let amount, let modifiers):
            return "scroll \(direction.rawValue) \(amount) at \(target?.summary ?? "the pointer")\(with(modifiers))"
        case .type(let text):
            let shown = text.count > 60 ? String(text.prefix(57)) + "…" : text
            return "type \"\(shown.replacingOccurrences(of: "\n", with: "⏎"))\""
        case .key(let combo, let count): return "press \(combo.summary)\(count > 1 ? " ×\(count)" : "")"
        case .holdKey(let combo, let seconds): return "hold \(combo.summary) for \(Self.format(seconds)) s"
        case .wait(let seconds): return "wait \(Self.format(seconds)) s"
        }
    }

    static func format(_ seconds: Double) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }
}

/// Why a model's action could not be read.
public struct DriveActionParseError: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Reads an action from its name and JSON input. The names and fields are those of Anthropic's computer tool
/// members (`left_click` with `coordinate: [x, y]`, `key` with `text`, `scroll` with `scroll_direction` …), which
/// the generic function-calling schema and occtl scripts reuse; `element` / `start_element` may stand in for a
/// coordinate.
public enum DriveActionParser {
    /// Every action name the parser accepts.
    public static let actionNames = [
        "screenshot", "zoom", "cursor_position", "mouse_move", "left_click", "right_click", "middle_click", "double_click",
        "triple_click", "left_click_drag", "left_mouse_down", "left_mouse_up", "scroll", "type", "key", "hold_key", "wait",
    ]

    public static func parse(name: String, input: JSONValue) throws -> DriveAction {
        let fields = input.objectValue ?? [:]
        switch name {
        case "screenshot":
            return .screenshot
        case "cursor_position":
            return .cursorPosition
        case "zoom":
            guard let numbers = fields["region"]?.arrayValue?.compactMap(\.doubleValue), numbers.count == 4,
                  numbers.allSatisfy(\.isFinite) else { throw DriveActionParseError("zoom needs region [x0, y0, x1, y1].") }
            guard numbers[2] > numbers[0], numbers[3] > numbers[1] else {
                throw DriveActionParseError("zoom's region must have x1 > x0 and y1 > y0.")
            }
            return .zoom(region: CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1]))
        case "mouse_move":
            guard let target = try target(fields, coordinateKey: "coordinate", elementKey: "element") else {
                throw DriveActionParseError("mouse_move needs coordinate [x, y] or element.")
            }
            return .moveMouse(to: target)
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let button: DriveMouseButton = name == "right_click" ? .right : name == "middle_click" ? .middle : .left
            let count = name == "double_click" ? 2 : name == "triple_click" ? 3 : 1
            return .click(at: try target(fields, coordinateKey: "coordinate", elementKey: "element"), button: button, count: count,
                          modifiers: try modifiers(fields))
        case "left_mouse_down":
            return .mouseDown(at: try target(fields, coordinateKey: "coordinate", elementKey: "element"))
        case "left_mouse_up":
            return .mouseUp(at: try target(fields, coordinateKey: "coordinate", elementKey: "element"))
        case "left_click_drag":
            guard let from = try target(fields, coordinateKey: "start_coordinate", elementKey: "start_element") else {
                throw DriveActionParseError("left_click_drag needs start_coordinate [x, y] or start_element.")
            }
            guard let to = try target(fields, coordinateKey: "coordinate", elementKey: "element") else {
                throw DriveActionParseError("left_click_drag needs coordinate [x, y] or element for where to drop.")
            }
            return .drag(from: from, to: to, modifiers: try modifiers(fields))
        case "scroll":
            guard let raw = fields["scroll_direction"]?.stringValue, let direction = DriveScrollDirection(rawValue: raw.lowercased()) else {
                throw DriveActionParseError("scroll needs scroll_direction up, down, left or right.")
            }
            let amount = try integer(fields["scroll_amount"], name: "scroll_amount", default: 3, range: 1...50)
            return .scroll(at: try target(fields, coordinateKey: "coordinate", elementKey: "element"), direction: direction,
                           amount: amount, modifiers: try modifiers(fields))
        case "type":
            guard let text = fields["text"]?.stringValue, !text.isEmpty else { throw DriveActionParseError("type needs text.") }
            return .type(text: text)
        case "key":
            let combo = try combo(fields)
            let count = try integer(fields["repeat"], name: "repeat", default: 1, range: 1...100)
            return .key(combo, repeatCount: count)
        case "hold_key":
            let combo = try combo(fields)
            guard let seconds = fields["duration"]?.doubleValue, seconds.isFinite, seconds > 0 else {
                throw DriveActionParseError("hold_key needs duration in seconds.")
            }
            return .holdKey(combo, seconds: seconds)
        case "wait":
            let seconds = fields["duration"]?.doubleValue ?? 1
            guard seconds.isFinite, seconds >= 0 else { throw DriveActionParseError("wait's duration must be a number of seconds.") }
            return .wait(seconds: seconds)
        default:
            throw DriveActionParseError("Unknown action \(name).")
        }
    }

    private static func target(_ fields: [String: JSONValue], coordinateKey: String, elementKey: String) throws -> DriveTarget? {
        if let element = fields[elementKey]?.stringValue?.trimmingCharacters(in: .whitespaces), !element.isEmpty {
            return .element(element)
        }
        guard let raw = fields[coordinateKey], raw != .null else { return nil }
        guard let numbers = raw.arrayValue?.compactMap(\.doubleValue), numbers.count == 2, numbers.allSatisfy(\.isFinite) else {
            throw DriveActionParseError("\(coordinateKey) must be [x, y] in screenshot pixels.")
        }
        return .pixel(x: numbers[0], y: numbers[1])
    }

    private static func modifiers(_ fields: [String: JSONValue]) throws -> DriveModifiers {
        guard let text = fields["text"]?.stringValue, !text.isEmpty else { return [] }
        guard let modifiers = DriveModifiers.parse(text) else {
            throw DriveActionParseError("text on a click or scroll names modifier keys (shift, ctrl, alt, super); got \"\(text)\".")
        }
        return modifiers
    }

    private static func combo(_ fields: [String: JSONValue]) throws -> KeyCombo {
        guard let text = fields["text"]?.stringValue, !text.isEmpty else { throw DriveActionParseError("key needs text, e.g. \"Return\" or \"super+s\".") }
        guard let combo = KeyCombo.parse(text) else { throw DriveActionParseError("Unknown key or combination \"\(text)\".") }
        return combo
    }

    private static func integer(_ value: JSONValue?, name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value, value != .null else { return fallback }
        guard let number = value.doubleValue, number.isFinite, number.rounded() == number, let int = Int(exactly: number) else {
            throw DriveActionParseError("\(name) must be a whole number.")
        }
        guard range.contains(int) else { throw DriveActionParseError("\(name) must be between \(range.lowerBound) and \(range.upperBound).") }
        return int
    }
}
