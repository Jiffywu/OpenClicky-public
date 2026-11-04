import CoreFoundation
import Foundation

/// A range of text in UTF-16 code units, the unit Accessibility uses for text positions.
public struct UTF16Range: Codable, Sendable, Hashable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var end: Int { location + length }
}

/// A rectangle in global screen coordinates (top-left origin, as Accessibility reports it).
public struct FocusFrame: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// What kind of writing a field is for. Steers the cleanup style and, for terminals, how text is inserted.
public enum TextSurface: String, Codable, Sendable, CaseIterable {
    case general, chat, email, document, code, terminal, search
}

/// What dictation knows about the place the text will go, captured when the dictation key goes down.
/// The text around the caret is clipped to a window so it can be handed to the cleanup model.
public struct FocusContext: Codable, Sendable, Hashable {
    public var appName: String?
    public var bundleID: String?
    public var processID: Int32
    /// Host of the page, when the field is inside a browser.
    public var siteHost: String?
    public var role: String?
    public var subrole: String?
    public var frame: FocusFrame?
    /// Text before the caret (or before the selection), clipped to the context window.
    public var beforeText: String
    /// The selected text, which the dictated text will replace.
    public var selectedText: String
    /// Text after the caret (or after the selection), clipped to the context window.
    public var afterText: String
    /// The selection in the field's full value (UTF-16), when the field reports one.
    public var selection: UTF16Range?
    /// Length of the field's full value (UTF-16), when known.
    public var characterCount: Int?
    /// A password field. Dictation never types into one.
    public var isSecure: Bool
    /// The element accepts text (a text field, text area, combo box or an editable web element).
    public var isEditable: Bool
    /// Newlines would submit or be dropped (text fields, search fields, terminals).
    public var isSingleLine: Bool
    /// The field's value could be read, so the caret position and surrounding text are real.
    public var isValueReadable: Bool
    public var surface: TextSurface

    public init(appName: String? = nil, bundleID: String? = nil, processID: Int32 = 0, siteHost: String? = nil,
                role: String? = nil, subrole: String? = nil, frame: FocusFrame? = nil, beforeText: String = "",
                selectedText: String = "", afterText: String = "", selection: UTF16Range? = nil, characterCount: Int? = nil,
                isSecure: Bool = false, isEditable: Bool = true, isSingleLine: Bool = false, isValueReadable: Bool = false,
                surface: TextSurface = .general) {
        self.appName = appName
        self.bundleID = bundleID
        self.processID = processID
        self.siteHost = siteHost
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.beforeText = beforeText
        self.selectedText = selectedText
        self.afterText = afterText
        self.selection = selection
        self.characterCount = characterCount
        self.isSecure = isSecure
        self.isEditable = isEditable
        self.isSingleLine = isSingleLine
        self.isValueReadable = isValueReadable
        self.surface = surface
    }
}

/// An opaque handle on a UI element: an `AXUIElement` in the app, any object (a string works) in tests.
/// Two handles are equal when CoreFoundation says the underlying objects are equal.
public struct FocusElement: @unchecked Sendable, Equatable {
    public let raw: AnyObject

    public init(_ raw: AnyObject) { self.raw = raw }

    public static func == (lhs: FocusElement, rhs: FocusElement) -> Bool {
        CFEqual(lhs.raw as CFTypeRef, rhs.raw as CFTypeRef)
    }
}

/// A focus context together with the element it was read from, so insertion can write back to it.
public struct CapturedFocus: Sendable, Equatable {
    public var context: FocusContext
    public var element: FocusElement?

    public init(context: FocusContext, element: FocusElement? = nil) {
        self.context = context
        self.element = element
    }
}

public enum FocusReadError: Error, Sendable, Equatable, CustomStringConvertible {
    /// This process is not allowed to use Accessibility (System Settings → Privacy & Security → Accessibility).
    case notTrusted
    case noFocusedApplication
    /// The app is known (it is frontmost) but Accessibility gave no focused element in it yet.
    case noFocusedElement(appName: String?, processID: Int32? = nil)
    case accessibility(code: Int32)

    public var description: String {
        switch self {
        case .notTrusted: "Accessibility access is off for this process. Turn it on in System Settings → Privacy & Security → Accessibility."
        case .noFocusedApplication: "No application has keyboard focus."
        case .noFocusedElement(let app, _): "\(app ?? "The focused app") reports no focused element."
        case .accessibility(let code): "Accessibility error \(code)."
        }
    }
}

/// Reads the focused text field.
public protocol FocusReading: Sendable {
    func captureFocus() -> Result<CapturedFocus, FocusReadError>
}

/// Raw attribute values as read from Accessibility, before they are interpreted. Building the context from this
/// keeps the interpretation (field kind, caret window, secure detection) testable without a live AX tree.
public struct FocusSnapshot: Sendable {
    public var appName: String?
    public var bundleID: String?
    public var processID: Int32
    public var role: String?
    public var subrole: String?
    public var roleDescription: String?
    /// The full value, when it was read whole.
    public var value: String?
    /// For long values only a window around the selection is read: the text before and after it.
    public var windowBefore: String?
    public var windowAfter: String?
    public var selectedText: String?
    public var selection: UTF16Range?
    public var characterCount: Int?
    public var frame: FocusFrame?
    public var isValueSettable: Bool
    public var isSelectedTextSettable: Bool
    public var url: URL?

    public init(appName: String? = nil, bundleID: String? = nil, processID: Int32 = 0, role: String? = nil,
                subrole: String? = nil, roleDescription: String? = nil, value: String? = nil, windowBefore: String? = nil,
                windowAfter: String? = nil, selectedText: String? = nil, selection: UTF16Range? = nil,
                characterCount: Int? = nil, frame: FocusFrame? = nil, isValueSettable: Bool = false,
                isSelectedTextSettable: Bool = false, url: URL? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.processID = processID
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.value = value
        self.windowBefore = windowBefore
        self.windowAfter = windowAfter
        self.selectedText = selectedText
        self.selection = selection
        self.characterCount = characterCount
        self.frame = frame
        self.isValueSettable = isValueSettable
        self.isSelectedTextSettable = isSelectedTextSettable
        self.url = url
    }
}

/// How much text around the caret to keep.
public struct SurroundingTextWindow: Sendable, Hashable {
    public var before: Int
    public var after: Int

    public init(before: Int = 600, after: Int = 300) {
        self.before = before
        self.after = after
    }
}

extension FocusContext {
    static let singleLineRoles: Set<String> = ["AXTextField", "AXComboBox", "AXSearchField"]
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Interprets raw Accessibility values.
    public init(snapshot s: FocusSnapshot, window: SurroundingTextWindow = SurroundingTextWindow()) {
        let isSecure = s.subrole == "AXSecureTextField" || s.role == "AXSecureTextField"
            || (s.roleDescription?.localizedCaseInsensitiveContains("secure") ?? false)
        let siteHost = s.url?.host?.lowercased()
        let surface = AppTraits.surface(bundleID: s.bundleID, siteHost: siteHost, role: s.role, subrole: s.subrole)
        let roleIsText = s.role.map(Self.textRoles.contains) ?? false
        let isEditable = roleIsText || s.isValueSettable || s.isSelectedTextSettable
        // Terminals run what they get on Return, so newlines must never reach them.
        let isSingleLine = surface == .terminal || surface == .search
            || (s.role.map(Self.singleLineRoles.contains) ?? false) || s.subrole == "AXSearchField"

        var before = ""
        var selected = s.selectedText ?? ""
        var after = ""
        var readable = false
        if !isSecure {
            if let value = s.value {
                readable = true
                let units = Array(value.utf16)
                let selection = s.selection ?? UTF16Range(location: units.count, length: 0)
                let start = min(max(selection.location, 0), units.count)
                let end = min(max(selection.end, start), units.count)
                before = UTF16Text.slice(units, max(0, start - window.before), start)
                if selected.isEmpty { selected = UTF16Text.slice(units, start, end) }
                after = UTF16Text.slice(units, end, min(units.count, end + window.after))
            } else if s.windowBefore != nil || s.windowAfter != nil {
                readable = true
                before = UTF16Text.suffix(s.windowBefore ?? "", window.before)
                after = UTF16Text.prefix(s.windowAfter ?? "", window.after)
            }
        } else {
            selected = ""
        }

        self.init(appName: s.appName, bundleID: s.bundleID, processID: s.processID, siteHost: siteHost, role: s.role,
                  subrole: s.subrole, frame: s.frame, beforeText: before, selectedText: selected, afterText: after,
                  selection: isSecure ? nil : s.selection, characterCount: isSecure ? nil : (s.characterCount ?? s.value.map { $0.utf16.count }),
                  isSecure: isSecure, isEditable: isEditable, isSingleLine: isSingleLine,
                  isValueReadable: readable, surface: surface)
    }
}

/// Slicing by UTF-16 offsets without splitting a surrogate pair.
enum UTF16Text {
    static func slice(_ units: [UTF16.CodeUnit], _ from: Int, _ to: Int) -> String {
        var lower = min(max(from, 0), units.count)
        var upper = min(max(to, lower), units.count)
        if lower > 0, lower < units.count, UTF16.isTrailSurrogate(units[lower]) { lower += 1 }
        if upper > lower, upper < units.count, UTF16.isTrailSurrogate(units[upper]) { upper -= 1 }
        guard lower < upper else { return "" }
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }

    static func suffix(_ text: String, _ count: Int) -> String {
        let units = Array(text.utf16)
        return slice(units, units.count - count, units.count)
    }

    static func prefix(_ text: String, _ count: Int) -> String {
        slice(Array(text.utf16), 0, count)
    }
}
