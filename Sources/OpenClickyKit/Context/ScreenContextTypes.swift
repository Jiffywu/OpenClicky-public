import CoreGraphics
import Foundation

/// The app the user is working in.
public struct FrontAppInfo: Sendable, Hashable {
    public var name: String?
    public var bundleIdentifier: String?
    public var processIdentifier: Int32

    public init(name: String?, bundleIdentifier: String?, processIdentifier: Int32) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["pid": .number(Double(processIdentifier))]
        if let name { object["name"] = .string(name) }
        if let bundleIdentifier { object["bundleID"] = .string(bundleIdentifier) }
        return .object(object)
    }
}

/// The front app's focused window.
public struct FocusedWindowInfo: Sendable, Hashable {
    public enum Source: String, Sendable { case accessibility, windowList }

    public var title: String?
    /// AppKit global points.
    public var frame: CGRect?
    /// `AXDocument`: the file the window shows, for document apps.
    public var documentURL: URL?
    public var source: Source

    public init(title: String?, frame: CGRect?, documentURL: URL? = nil, source: Source) {
        self.title = title
        self.frame = frame
        self.documentURL = documentURL
        self.source = source
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["source": .string(source.rawValue)]
        if let title { object["title"] = .string(title) }
        if let frame { object["frame"] = frame.jsonValue }
        if let documentURL { object["document"] = .string(documentURL.isFileURL ? documentURL.path : documentURL.absoluteString) }
        return .object(object)
    }
}

/// The control that has keyboard focus, and any text selected in it.
public struct FocusedElementInfo: Sendable, Hashable {
    public var role: String?
    public var subrole: String?
    public var roleDescription: String?
    /// Title, description or the label attached to the control.
    public var label: String?
    public var placeholder: String?
    /// AppKit global points.
    public var frame: CGRect?
    public var selectedText: String?
    /// The start of the control's text (editable fields), capped. Never read from secure fields.
    public var valuePreview: String?
    public var valueLength: Int?
    /// A password field: nothing of its contents is read.
    public var isSecure: Bool

    public init(role: String? = nil, subrole: String? = nil, roleDescription: String? = nil, label: String? = nil, placeholder: String? = nil,
                frame: CGRect? = nil, selectedText: String? = nil, valuePreview: String? = nil, valueLength: Int? = nil, isSecure: Bool = false) {
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.label = label
        self.placeholder = placeholder
        self.frame = frame
        self.selectedText = selectedText
        self.valuePreview = valuePreview
        self.valueLength = valueLength
        self.isSecure = isSecure
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["isSecure": .bool(isSecure)]
        if let role { object["role"] = .string(role) }
        if let subrole { object["subrole"] = .string(subrole) }
        if let roleDescription { object["roleDescription"] = .string(roleDescription) }
        if let label { object["label"] = .string(label) }
        if let placeholder { object["placeholder"] = .string(placeholder) }
        if let frame { object["frame"] = frame.jsonValue }
        if let selectedText { object["selectedText"] = .string(selectedText) }
        if let valuePreview { object["valuePreview"] = .string(valuePreview) }
        if let valueLength { object["valueLength"] = .number(Double(valueLength)) }
        return .object(object)
    }
}

/// The document the user is looking at: a web page or a file, with its text so the brain can answer about parts that
/// are scrolled out of view.
public struct ActiveDocument: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case webPage = "web_page"
        case pdf
        case textFile = "text_file"
        case richText = "rich_text"
        /// A file whose text OpenClicky can't extract (images, archives, app packages…).
        case file
    }

    public enum Source: String, Sendable, Hashable {
        /// The browser's scripting dictionary (Apple Events).
        case scripting
        /// The Accessibility tree (address bar, web area text).
        case accessibility
        /// Read from disk.
        case file
    }

    public var kind: Kind
    /// The page URL or the file path.
    public var reference: String
    public var title: String?
    public var text: String?
    public var isTruncated: Bool
    public var pageCount: Int?
    public var byteCount: Int?
    public var source: Source
    /// macOS refused the read (Files & Folders permission denied).
    public var accessDenied: Bool
    /// The file sits in a folder macOS guards with a one-time prompt, and this process hasn't read from it before, so
    /// its text was not read this time.
    public var awaitingFolderAccess: GuardedFolder?

    public init(kind: Kind, reference: String, title: String? = nil, text: String? = nil, isTruncated: Bool = false, pageCount: Int? = nil,
                byteCount: Int? = nil, source: Source, accessDenied: Bool = false, awaitingFolderAccess: GuardedFolder? = nil) {
        self.kind = kind
        self.reference = reference
        self.title = title
        self.text = text
        self.isTruncated = isTruncated
        self.pageCount = pageCount
        self.byteCount = byteCount
        self.source = source
        self.accessDenied = accessDenied
        self.awaitingFolderAccess = awaitingFolderAccess
    }

    /// The web page's host without "www.", for web pages.
    public var host: String? { kind == .webPage ? ReadableText.host(of: reference) : nil }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "reference": .string(reference),
            "truncated": .bool(isTruncated),
            "source": .string(source.rawValue),
            "accessDenied": .bool(accessDenied),
        ]
        if let title { object["title"] = .string(title) }
        if let host { object["host"] = .string(host) }
        if let text {
            object["text"] = .string(text)
            object["characters"] = .number(Double(text.count))
        }
        if let pageCount { object["pageCount"] = .number(Double(pageCount)) }
        if let byteCount { object["bytes"] = .number(Double(byteCount)) }
        if let awaitingFolderAccess { object["awaitingFolderAccess"] = .string(awaitingFolderAccess.rawValue) }
        return .object(object)
    }
}

/// Which permissions the context could use when it was gathered.
public struct ContextPermissions: Sendable, Hashable {
    public var accessibility: Bool
    public var screenRecording: Bool

    public init(accessibility: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    public static var current: ContextPermissions {
        ContextPermissions(accessibility: AccessibilityAccess.isTrusted, screenRecording: ScreenRecordingAccess.isGranted)
    }
}

/// Everything about what the user is doing that isn't pixels: front app, window, focus, document, displays, pointer.
public struct ScreenContext: Sendable, Hashable {
    public var gatheredAt: Date
    public var frontApp: FrontAppInfo?
    public var window: FocusedWindowInfo?
    public var focus: FocusedElementInfo?
    public var document: ActiveDocument?
    public var layout: DesktopLayout
    /// AppKit global points.
    public var cursor: CGPoint
    public var permissions: ContextPermissions
    /// What was skipped or failed, and why, in plain words.
    public var notes: [String]

    public init(gatheredAt: Date = Date(), frontApp: FrontAppInfo? = nil, window: FocusedWindowInfo? = nil, focus: FocusedElementInfo? = nil,
                document: ActiveDocument? = nil, layout: DesktopLayout, cursor: CGPoint, permissions: ContextPermissions, notes: [String] = []) {
        self.gatheredAt = gatheredAt
        self.frontApp = frontApp
        self.window = window
        self.focus = focus
        self.document = document
        self.layout = layout
        self.cursor = cursor
        self.permissions = permissions
        self.notes = notes
    }

    public var cursorDisplay: DisplayGeometry? { layout.display(nearest: cursor) }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "gatheredAt": .string(ISO8601DateFormatter().string(from: gatheredAt)),
            "cursor": cursor.jsonValue,
            "displays": .array(layout.displays.map(\.jsonValue)),
            "permissions": ["accessibility": .bool(permissions.accessibility), "screenRecording": .bool(permissions.screenRecording)],
            "notes": .array(notes.map(JSONValue.string)),
        ]
        if let id = cursorDisplay?.id { object["cursorDisplayID"] = .number(Double(id)) }
        if let frontApp { object["frontApp"] = frontApp.jsonValue }
        if let window { object["window"] = window.jsonValue }
        if let focus { object["focus"] = focus.jsonValue }
        if let document { object["document"] = document.jsonValue }
        return .object(object)
    }

    /// A few plain lines for the brain's turn message. Document text is included up to `documentCharacters`.
    public func promptText(documentCharacters: Int = 20_000) -> String {
        var lines: [String] = []
        if let app = frontApp {
            lines.append("Front app: \(app.name ?? "unknown")\(app.bundleIdentifier.map { " (\($0))" } ?? "")")
        }
        if let title = window?.title, !title.isEmpty { lines.append("Window: \(title)") }
        if let document {
            switch document.kind {
            case .webPage:
                lines.append("Page open: \(document.title.map { "\($0) — " } ?? "")\(document.reference)")
            default:
                lines.append("File open: \(document.reference)\(document.pageCount.map { " (\($0) pages)" } ?? "")")
            }
            if document.accessDenied { lines.append("(macOS denied reading this file; answer from what is visible.)") }
            if let folder = document.awaitingFolderAccess { lines.append("(The file's text was not read: \(folder.displayName) access hasn't been granted yet.)") }
        }
        if let focus, !focus.isSecure {
            let what = [focus.roleDescription ?? focus.role, focus.label.map { "\"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
            if !what.isEmpty { lines.append("Focused: \(what)") }
            if let selected = focus.selectedText, !selected.isEmpty { lines.append("Selected text: \(ReadableText.truncate(selected, maxCharacters: 2_000).text)") }
        }
        if let text = document?.text, !text.isEmpty, documentCharacters > 0 {
            let cut = ReadableText.truncate(text, maxCharacters: documentCharacters)
            let truncated = cut.truncated || document?.isTruncated == true
            lines.append("Document text\(truncated ? " (truncated)" : ""):\n\(cut.text)")
        }
        return lines.joined(separator: "\n")
    }
}
