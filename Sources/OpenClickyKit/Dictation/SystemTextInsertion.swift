import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The real operating-system side of insertion: Accessibility writes, synthesized key events and the clipboard.
/// Sending key events and writing through Accessibility both need Accessibility permission.
public final class SystemTextInsertion: TextInsertionSystem, @unchecked Sendable {
    public let pasteboard: any PasteboardAccess
    private let reader: AccessibilityFocusReader

    public init(reader: AccessibilityFocusReader = AccessibilityFocusReader(), pasteboard: any PasteboardAccess = SystemPasteboard()) {
        self.reader = reader
        self.pasteboard = pasteboard
    }

    public func isAccessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    /// On while any app has asked for secure keyboard entry; key events then don't reach other apps reliably,
    /// and typing could land in a password prompt.
    public func isSecureEventInputEnabled() -> Bool { IsSecureEventInputEnabled() }

    public func currentFocus() -> CapturedFocus? { try? reader.captureFocus().get() }

    public func frontmostProcessID() -> Int32? {
        let systemWide = AXUIElementCreateSystemWide()
        if let app = AX.element(systemWide, "AXFocusedApplication") {
            var pid: pid_t = 0
            if AXUIElementGetPid(app, &pid) == .success { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public func isElectron(processID: Int32) -> Bool {
        let app = NSRunningApplication(processIdentifier: processID)
        return AppTraits.isElectron(bundleID: app?.bundleIdentifier, bundleURL: app?.bundleURL)
    }

    public func value(of element: FocusElement) -> String? { reader.value(of: element) }

    public func setSelectedText(_ text: String, on element: FocusElement) -> Bool {
        guard let ax = axElement(element) else { return false }
        return AXUIElementSetAttributeValue(ax, "AXSelectedText" as CFString, text as CFString) == .success
    }

    public func setValue(_ value: String, caret: Int, on element: FocusElement) -> Bool {
        guard let ax = axElement(element) else { return false }
        guard AXUIElementSetAttributeValue(ax, "AXValue" as CFString, value as CFString) == .success else { return false }
        _ = AX.setRange(ax, "AXSelectedTextRange", UTF16Range(location: caret, length: 0))
        return true
    }

    public func postPaste(to processID: Int32) async -> Bool {
        // The key that means V with Command held in the user's layout (not always the QWERTY V position).
        let key = await MainActor.run { KeyboardLayoutKeys.pasteKeyCode }
        // A private event source keeps modifier keys the user may still be holding out of the shortcut.
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    public func type(_ text: String, to processID: Int32, shiftNewlines: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        for chunk in KeyTypingChunks.split(text) {
            switch chunk {
            case .newline:
                guard postKey(CGKeyCode(kVK_Return), flags: shiftNewlines ? .maskShift : [], source: source) else { return false }
            case .text(let units):
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
                down.flags = []
                up.flags = []
                units.withUnsafeBufferPointer { buffer in
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            usleep(2_500)
        }
        return true
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags, source: CGEventSource) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func axElement(_ element: FocusElement) -> AXUIElement? {
        guard CFGetTypeID(element.raw as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return (element.raw as! AXUIElement)
    }
}

/// Splits text into key-event payloads: runs of at most `maxUnits` UTF-16 units (never splitting a surrogate pair)
/// and separate newlines, which are sent as the Return key.
public enum KeyTypingChunks {
    public enum Chunk: Equatable, Sendable {
        case text([UTF16.CodeUnit])
        case newline
    }

    public static func split(_ text: String, maxUnits: Int = 16) -> [Chunk] {
        var chunks: [Chunk] = []
        var current: [UTF16.CodeUnit] = []
        func flush() {
            if !current.isEmpty { chunks.append(.text(current)) }
            current.removeAll()
        }
        for character in text {
            if character.isNewline {
                flush()
                chunks.append(.newline)
                continue
            }
            let units = Array(String(character).utf16)
            if current.count + units.count > maxUnits { flush() }
            current += units
        }
        flush()
        return chunks
    }
}
