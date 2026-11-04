import CoreGraphics
import Foundation

// Converts what OpenClicky sees (captures, context, element snapshots, all in AppKit global points) into the turn
// contract's types (docs/turn-contract.md), whose frames are Quartz global points: origin at the top-left corner of the
// main display, y down. And back, so the app can point at what the brain names.

// MARK: - Screens

extension DesktopLayout {
    /// Where a display sits relative to the main display, in the words a person would use: "left", "right",
    /// "above", "below", "upper left", … Nil for the main display itself or for overlapping (mirrored) frames.
    public func placement(of display: DisplayGeometry) -> String? {
        guard let primary, primary.id != display.id else { return nil }
        let main = primary.frame, frame = display.frame
        var horizontal: String?
        var vertical: String?
        if frame.maxX <= main.minX { horizontal = "left" } else if frame.minX >= main.maxX { horizontal = "right" }
        // AppKit y grows upward.
        if frame.minY >= main.maxY { vertical = "above" } else if frame.maxY <= main.minY { vertical = "below" }
        switch (vertical, horizontal) {
        case (nil, nil): return nil
        case (let v?, nil): return v
        case (nil, let h?): return h
        case (let v?, let h?): return "\(v == "above" ? "upper" : "lower") \(h)"
        }
    }
}

extension ScreenCapture {
    /// How a turn's prompt names this screen: "main display" or "display 2 (left)". The number is the reading-order
    /// screen number, so it stays the same whichever display the pointer is on.
    public func turnLabel(in layout: DesktopLayout) -> String {
        if display.isPrimary || layout.displays.count <= 1 { return "main display" }
        let placement = layout.placement(of: display)
        return "display \(screenNumber)" + (placement.map { " (\($0))" } ?? "")
    }

    /// This capture as the turn contract's screenshot (display frame in Quartz global points).
    public func turnScreenshot(in layout: DesktopLayout) -> TurnScreenshot {
        TurnScreenshot(jpeg: imageData, label: turnLabel(in: layout), isCursorScreen: isCursorScreen,
                       pixelSize: CGSize(width: pixelWidth, height: pixelHeight), displayFrame: layout.quartzRect(fromAppKit: display.frame))
    }
}

extension Array where Element == ScreenCapture {
    /// The turn's screenshots: the pointer's display first, then the others in reading order.
    public func turnScreenshots(in layout: DesktopLayout) -> [TurnScreenshot] {
        let ordered = filter(\.isCursorScreen) + filter { !$0.isCursorScreen }
        return ordered.map { $0.turnScreenshot(in: layout) }
    }
}

extension CaptureGeometry {
    /// The pixel mapping of a screenshot that came with a turn (its frame is Quartz global; this type works in AppKit).
    public init(turnScreenshot: TurnScreenshot, layout: DesktopLayout) {
        self.init(displayFrame: layout.appKitRect(fromQuartz: turnScreenshot.displayFrame),
                  pixelWidth: Int(turnScreenshot.pixelSize.width.rounded()), pixelHeight: Int(turnScreenshot.pixelSize.height.rounded()))
    }
}

extension Array where Element == TurnScreenshot {
    /// The screenshot a model's answer refers to: the one with `label` (case-insensitive) or the 1-based display
    /// number in it ("display 2", "screen 2", "2"), else the pointer's screen, else the first.
    public func screenshot(named name: String?) -> TurnScreenshot? {
        let cursor = first(where: \.isCursorScreen) ?? first
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return cursor }
        if let exact = first(where: { $0.label.lowercased() == raw }) { return exact }
        if ["main", "main display", "main screen", "primary"].contains(raw), let main = first(where: { $0.label == "main display" }) { return main }
        let digits = raw.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
        if let digits, let numbered = first(where: { $0.label.hasPrefix("display \(digits)") }) { return numbered }
        return cursor
    }
}

// MARK: - Elements

extension ElementSnapshot {
    /// The element as the turn contract's pointing handle, or nil when it has no words to be called by or no size.
    public func turnElement(in layout: DesktopLayout, maxLabelCharacters: Int = 80) -> TurnElement? {
        guard let label, frame.width > 0, frame.height > 0 else { return nil }
        let short = label.count > maxLabelCharacters ? String(label.prefix(maxLabelCharacters - 1)) + "…" : label
        return TurnElement(id: id, role: kindName, label: short, frame: layout.quartzRect(fromAppKit: frame))
    }
}

extension WindowElementSnapshot {
    /// Labeled controls and headings that are at least partly on a display, in document order, for the brain to point
    /// at by id. Decorative text is left out to keep the prompt small.
    public func turnElements(in layout: DesktopLayout, limit: Int = 150) -> [TurnElement] {
        var result: [TurnElement] = []
        for element in elements where element.isActionable || element.role == "AXHeading" {
            guard result.count < limit else { break }
            guard layout.displays.contains(where: { $0.frame.intersects(element.frame) }) else { continue }
            if let turn = element.turnElement(in: layout) { result.append(turn) }
        }
        return result
    }
}

extension TurnElement {
    /// The element's frame in AppKit global points (what overlays and `PointingDestination` use).
    public func appKitFrame(in layout: DesktopLayout) -> CGRect { layout.appKitRect(fromQuartz: frame) }
}

extension PointingDestination {
    /// Point at an element the brain named by id.
    public static func element(_ element: TurnElement, in layout: DesktopLayout) -> PointingDestination {
        .rect(element.appKitFrame(in: layout))
    }

    /// A pixel of a turn screenshot, as a model answers.
    public static func pixel(_ pixel: CGPoint, in screenshot: TurnScreenshot, layout: DesktopLayout) -> PointingDestination {
        .pixel(pixel, CaptureGeometry(turnScreenshot: screenshot, layout: layout))
    }

    /// A Quartz global point (top-left origin of the main display), as Accessibility and the window list report.
    public static func quartzPoint(_ point: CGPoint, in layout: DesktopLayout) -> PointingDestination {
        .point(layout.appKitPoint(fromQuartz: point))
    }

    public static func quartzRect(_ rect: CGRect, in layout: DesktopLayout) -> PointingDestination {
        .rect(layout.appKitRect(fromQuartz: rect))
    }
}

extension Array where Element == TurnElement {
    /// The element with `id`, else the best match for a spoken label ("the Save button").
    public func element(idOrLabel query: String) -> TurnElement? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let byID = first(where: { $0.id == trimmed }) { return byID }
        // Score through the same matcher the app uses on live snapshots; roles here are already friendly names.
        let snapshots = map { ElementSnapshot(id: $0.id, role: ElementRoles.axRole(forKindName: $0.role), title: $0.label, frame: $0.frame) }
        guard let match = ElementLabelMatcher.bestMatch(for: trimmed, in: snapshots) else { return nil }
        return first { $0.id == match.element.id }
    }
}

extension ElementRoles {
    /// The AX role a friendly kind name ("button", "link") stands for; unknown names map to a generic role.
    static func axRole(forKindName name: String) -> String {
        switch name {
        case "button": "AXButton"
        case "pop-up menu": "AXPopUpButton"
        case "checkbox": "AXCheckBox"
        case "radio button": "AXRadioButton"
        case "switch": "AXSwitch"
        case "link": "AXLink"
        case "menu item": "AXMenuItem"
        case "menu": "AXMenuBarItem"
        case "tab": "AXTab"
        case "text field", "password field": "AXTextField"
        case "text area": "AXTextArea"
        case "search field": "AXSearchField"
        case "slider": "AXSlider"
        case "text": "AXStaticText"
        case "heading": "AXHeading"
        case "image": "AXImage"
        case "cell": "AXCell"
        case "row": "AXRow"
        case "disclosure triangle": "AXDisclosureTriangle"
        default: "AX" + name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }
    }
}

// MARK: - Context

extension ScreenContext {
    /// The turn contract's context: front app, window, open document (text capped at `documentCharacters`), the
    /// selection (never from password fields) and, when given, the front window's elements for pointing.
    public func turnContext(elements snapshot: WindowElementSnapshot? = nil, documentCharacters: Int = 20_000,
                            selectionCharacters: Int = 4_000, elementLimit: Int = 150,
                            localTime: Date = Date(), timeZone: TimeZone = .current) -> TurnContext {
        var turn = TurnContext(localTime: localTime, timeZone: timeZone, frontApp: frontApp?.name, frontAppBundleID: frontApp?.bundleIdentifier,
                               windowTitle: window?.title.flatMap { $0.isEmpty ? nil : $0 })
        if let document {
            turn.documentTitle = document.title
            turn.documentURL = document.kind == .webPage ? document.reference : URL(fileURLWithPath: document.reference).absoluteString
            if let text = document.text, !text.isEmpty, documentCharacters > 0 {
                let cut = ReadableText.truncate(text, maxCharacters: documentCharacters)
                turn.documentText = cut.text
                turn.documentTruncated = cut.truncated || document.isTruncated
            } else {
                turn.documentTruncated = document.isTruncated
            }
        }
        if let focus, !focus.isSecure, let selected = focus.selectedText, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            turn.selectedText = ReadableText.truncate(selected, maxCharacters: selectionCharacters).text
        }
        if let snapshot { turn.elements = snapshot.turnElements(in: layout, limit: elementLimit) }
        return turn
    }

    /// "[App] …" notes the brain should see with this turn: things about the document it can't learn from pixels.
    public var turnAppNotes: [String] {
        guard let document else { return [] }
        var notes: [String] = []
        if document.accessDenied {
            notes.append("[App] macOS refused to let OpenClicky read the open file, so only what is visible on screen is known about it.")
        }
        if let folder = document.awaitingFolderAccess {
            notes.append("[App] The open file is in \(folder.displayName), which OpenClicky hasn't been allowed to read yet; only what is visible is known.")
        }
        return notes
    }
}

/// The turn contract's types as JSON, for `occtl` and logs. Image bytes are summarized, never included.
public enum TurnContractJSON {
    public static func context(_ context: TurnContext) -> JSONValue {
        var object: [String: JSONValue] = [
            "localTime": .string(ISO8601DateFormatter().string(from: context.localTime)),
            "timeZone": .string(context.timeZone.identifier),
            "documentTruncated": .bool(context.documentTruncated),
            "elements": .array(context.elements.map(element)),
        ]
        let optionals: [(String, String?)] = [
            ("frontApp", context.frontApp), ("frontAppBundleID", context.frontAppBundleID), ("windowTitle", context.windowTitle),
            ("documentTitle", context.documentTitle), ("documentURL", context.documentURL), ("documentText", context.documentText),
            ("selectedText", context.selectedText), ("highlightDescription", context.highlightDescription),
            ("drawingOnScreen", context.drawingOnScreen), ("trigger", context.trigger),
        ]
        for (key, value) in optionals { if let value { object[key] = .string(value) } }
        return .object(object)
    }

    public static func element(_ element: TurnElement) -> JSONValue {
        ["id": .string(element.id), "role": .string(element.role), "label": .string(element.label), "frame": element.frame.jsonValue]
    }

    public static func screenshot(_ screenshot: TurnScreenshot) -> JSONValue {
        [
            "label": .string(screenshot.label),
            "isCursorScreen": .bool(screenshot.isCursorScreen),
            "pixelSize": ["width": .number(Double(screenshot.pixelSize.width)), "height": .number(Double(screenshot.pixelSize.height))],
            "displayFrame": screenshot.displayFrame.jsonValue,
            "jpegBytes": .number(Double(screenshot.jpeg.count)),
        ]
    }
}
