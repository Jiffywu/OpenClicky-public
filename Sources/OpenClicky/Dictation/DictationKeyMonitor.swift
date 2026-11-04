import AppKit
import OpenClickyKit

/// Watches the dictation chord anywhere on the Mac and reports presses, releases, other keys and Escape with event
/// timestamps. The engagement rules (hold, double-tap hands-free, bounce) live in `DictationEngagementMachine`.
/// Global key monitoring needs Accessibility permission.
@MainActor
final class DictationKeyMonitor {
    /// The modifier keys that must be held, exactly.
    var chord: NSEvent.ModifierFlags
    var onInput: ((DictationEngagementMachine.Input) -> Void)?
    var onEscape: (() -> Void)?
    /// Other keys only matter while dictation is engaged; the coordinator says when.
    var wantsOtherKeys: () -> Bool = { false }

    private(set) var isChordDown = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    static let relevantFlags: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]
    static let escapeKeyCode: UInt16 = 53

    init(chord: NSEvent.ModifierFlags) { self.chord = chord }

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isChordDown = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == Self.escapeKeyCode {
                onEscape?()
            } else if wantsOtherKeys() {
                onInput?(.otherKey(at: event.timestamp))
            }
            return
        }
        let down = event.modifierFlags.intersection(Self.relevantFlags) == chord
        if down && !isChordDown {
            isChordDown = true
            onInput?(.chordDown(at: event.timestamp))
        } else if !down && isChordDown {
            isChordDown = false
            onInput?(.chordUp(at: event.timestamp))
        }
    }

    static func flags(for modifiers: [DictationModifier]) -> NSEvent.ModifierFlags {
        modifiers.reduce(into: NSEvent.ModifierFlags()) { flags, modifier in
            switch modifier {
            case .control: flags.insert(.control)
            case .option: flags.insert(.option)
            case .command: flags.insert(.command)
            case .shift: flags.insert(.shift)
            case .function: flags.insert(.function)
            }
        }
    }

    /// "fn ⌃", in the order macOS menus use.
    static func label(for modifiers: [DictationModifier]) -> String {
        let set = Set(modifiers)
        var parts: [String] = []
        if set.contains(.function) { parts.append("fn") }
        var symbols = ""
        if set.contains(.control) { symbols += "⌃" }
        if set.contains(.option) { symbols += "⌥" }
        if set.contains(.shift) { symbols += "⇧" }
        if set.contains(.command) { symbols += "⌘" }
        if !symbols.isEmpty { parts.append(symbols) }
        return parts.joined(separator: " ")
    }
}
