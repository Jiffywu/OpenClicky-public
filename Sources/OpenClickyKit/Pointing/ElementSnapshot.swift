import CoreGraphics
import Foundation

/// One on-screen control or piece of text from the front window's Accessibility tree.
public struct ElementSnapshot: Sendable, Hashable {
    /// Short handle, unique within its snapshot ("e12"), that the brain can name instead of coordinates.
    public var id: String
    public var role: String
    public var subrole: String?
    public var roleDescription: String?
    public var title: String?
    public var detail: String?
    public var value: String?
    public var help: String?
    public var identifier: String?
    public var placeholder: String?
    /// AppKit global points.
    public var frame: CGRect
    public var isEnabled: Bool
    public var isFocused: Bool
    public var depth: Int

    public init(id: String, role: String, subrole: String? = nil, roleDescription: String? = nil, title: String? = nil, detail: String? = nil,
                value: String? = nil, help: String? = nil, identifier: String? = nil, placeholder: String? = nil, frame: CGRect,
                isEnabled: Bool = true, isFocused: Bool = false, depth: Int = 0) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.title = title
        self.detail = detail
        self.value = value
        self.help = help
        self.identifier = identifier
        self.placeholder = placeholder
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.depth = depth
    }

    /// The words a person would use for it: its title, else its description, else its text (for text roles),
    /// placeholder or help tag.
    public var label: String? {
        let textRoles: Set<String> = ["AXStaticText", "AXHeading", "AXLink", "AXCell", "AXMenuItem", "AXMenuBarItem"]
        let candidates: [String?] = [title, detail, textRoles.contains(role) ? value : nil, placeholder, help]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    /// Something the user can click, toggle, type into or open.
    public var isActionable: Bool { ElementRoles.actionable.contains(role) }

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// The friendly kind name ("button", "link", "text field").
    public var kindName: String { ElementRoles.friendlyName(role: role, subrole: subrole) }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "role": .string(role),
            "frame": frame.jsonValue,
            "enabled": .bool(isEnabled),
            "actionable": .bool(isActionable),
        ]
        if let label { object["label"] = .string(label) }
        if let subrole { object["subrole"] = .string(subrole) }
        if let identifier { object["identifier"] = .string(identifier) }
        if let value, label != value { object["value"] = .string(String(value.prefix(200))) }
        if isFocused { object["focused"] = .bool(true) }
        return .object(object)
    }
}

/// Role groups used for pointing.
public enum ElementRoles {
    /// Controls a pointer can usefully land on.
    public static let actionable: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle", "AXDisclosureTriangle",
        "AXLink", "AXMenuItem", "AXMenuBarItem", "AXTab", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSlider",
        "AXIncrementor", "AXStepper", "AXColorWell", "AXDockItem", "AXCell", "AXRow", "AXSegmentedControl", "AXDateField",
    ]

    /// Big structural containers: never a pointing target in themselves.
    public static let containers: Set<String> = [
        "AXApplication", "AXWindow", "AXWebArea", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXList", "AXTable", "AXOutline",
        "AXBrowser", "AXGroup", "AXToolbar", "AXTabGroup", "AXSplitter", "AXScrollBar", "AXUnknown",
    ]

    static func friendlyName(role: String, subrole: String?) -> String {
        if subrole == "AXSecureTextField" { return "password field" }
        if subrole == "AXSearchField" { return "search field" }
        switch role {
        case "AXButton", "AXMenuButton": return "button"
        case "AXPopUpButton": return "pop-up menu"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio button"
        case "AXSwitch", "AXToggle": return "switch"
        case "AXLink": return "link"
        case "AXMenuItem": return "menu item"
        case "AXMenuBarItem": return "menu"
        case "AXTab": return "tab"
        case "AXTextField", "AXComboBox", "AXDateField": return "text field"
        case "AXTextArea": return "text area"
        case "AXSearchField": return "search field"
        case "AXSlider": return "slider"
        case "AXStaticText": return "text"
        case "AXHeading": return "heading"
        case "AXImage": return "image"
        case "AXCell": return "cell"
        case "AXRow": return "row"
        case "AXDisclosureTriangle": return "disclosure triangle"
        default:
            var name = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            name = name.reduce(into: "") { result, character in
                if character.isUppercase, !result.isEmpty { result.append(" ") }
                result.append(contentsOf: character.lowercased())
            }
            return name
        }
    }

    /// Words people put next to a label that name the kind of control ("the Save button").
    static let kindWords: [String: Set<String>] = [
        "button": ["AXButton", "AXMenuButton", "AXPopUpButton"],
        "link": ["AXLink"],
        "tab": ["AXTab", "AXRadioButton"],
        "checkbox": ["AXCheckBox"],
        "check": ["AXCheckBox"],
        "box": ["AXCheckBox", "AXTextField", "AXComboBox", "AXSearchField"],
        "switch": ["AXSwitch", "AXCheckBox", "AXToggle"],
        "toggle": ["AXSwitch", "AXCheckBox", "AXToggle"],
        "field": ["AXTextField", "AXSearchField", "AXComboBox", "AXTextArea"],
        "menu": ["AXMenuBarItem", "AXMenuButton", "AXPopUpButton", "AXMenuItem"],
        "item": ["AXMenuItem", "AXCell", "AXRow"],
        "icon": ["AXButton", "AXImage", "AXDockItem"],
        "slider": ["AXSlider"],
        "dropdown": ["AXPopUpButton", "AXComboBox", "AXMenuButton"],
    ]
}

/// The front window's elements at one moment.
public struct WindowElementSnapshot: Sendable, Hashable {
    public var app: FrontAppInfo?
    public var windowTitle: String?
    /// AppKit global points.
    public var windowFrame: CGRect?
    public var elements: [ElementSnapshot]
    /// The walk stopped at a node or time limit before covering the whole tree.
    public var isTruncated: Bool
    public var elapsed: Duration

    public init(app: FrontAppInfo?, windowTitle: String?, windowFrame: CGRect?, elements: [ElementSnapshot], isTruncated: Bool = false,
                elapsed: Duration = .zero) {
        self.app = app
        self.windowTitle = windowTitle
        self.windowFrame = windowFrame
        self.elements = elements
        self.isTruncated = isTruncated
        self.elapsed = elapsed
    }

    public func element(id: String) -> ElementSnapshot? { elements.first { $0.id == id } }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "elements": .array(elements.map(\.jsonValue)),
            "count": .number(Double(elements.count)),
            "truncated": .bool(isTruncated),
            "elapsedMs": .number((Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded()),
        ]
        if let app { object["app"] = app.jsonValue }
        if let windowTitle { object["windowTitle"] = .string(windowTitle) }
        if let windowFrame { object["windowFrame"] = windowFrame.jsonValue }
        return .object(object)
    }

    /// Compact lines for the brain, one per labeled control, with boxes in the screenshot's pixels when a capture is
    /// given (so the model can point by id or by box), else in AppKit global points:
    /// `e12 button "Save" [x,y,w,h]`. Elements outside the capture are left out.
    public func promptLines(in capture: CaptureGeometry? = nil, limit: Int = 250) -> [String] {
        var lines: [String] = []
        for element in elements where element.isActionable || element.role == "AXHeading" {
            guard let label = element.label else { continue }
            var box = element.frame
            if let capture {
                guard let visible = capture.visiblePixelRect(capture.pixelRect(fromAppKitRect: element.frame)) else { continue }
                box = visible
            }
            let numbers = [box.minX, box.minY, box.width, box.height].map { String(Int($0.rounded())) }.joined(separator: ",")
            let quoted = label.count > 80 ? String(label.prefix(79)) + "…" : label
            lines.append("\(element.id) \(element.kindName) \"\(quoted.replacingOccurrences(of: "\"", with: "'"))\" [\(numbers)]\(element.isEnabled ? "" : " disabled")")
            if lines.count >= limit { break }
        }
        return lines
    }
}
