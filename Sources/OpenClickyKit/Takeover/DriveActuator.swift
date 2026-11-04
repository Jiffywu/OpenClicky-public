import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Performs placed actions. Every test, `occtl takeover plan` and `occtl takeover simulate` use `DryRunActuator`,
/// which records and never touches the Mac. Only the app builds a `CGEventActuator` with `HIDEventPoster`, and only
/// for a drive the user approved.
public protocol DriveActuating: Sendable {
    /// True when nothing reaches the Mac's input.
    var isDryRun: Bool { get }
    /// Performs one action, checking `stop` before each event it would post.
    func perform(_ action: ResolvedDriveAction, stop: TakeoverStopSwitch) async throws
    /// Lets go of any mouse button or key still held down. Called whenever a drive ends, however it ends.
    func releaseAll() async
}

/// Records what it was asked to do. Never posts an event.
public final class DryRunActuator: DriveActuating {
    private let log = OSAllocatedUnfairLock<[ResolvedDriveAction]>(initialState: [])

    public init() {}

    public var isDryRun: Bool { true }

    public func perform(_ action: ResolvedDriveAction, stop: TakeoverStopSwitch) async throws {
        try stop.check()
        log.withLock { $0.append(action) }
    }

    public func releaseAll() async {}

    /// Everything performed so far, in order.
    public var performed: [ResolvedDriveAction] { log.withLock { $0 } }
}

/// Where the CGEvent actuator's events go. `HIDEventPoster` is the real Mac; `RecordingEventPoster` keeps a
/// description of each event and posts nothing, so the event sequences can be tested.
public protocol DriveEventPosting: Sendable {
    func post(_ event: CGEvent)
}

/// Posts to the HID event tap: real mouse and keyboard input. Needs Accessibility permission.
public struct HIDEventPoster: DriveEventPosting {
    public init() {}
    public func post(_ event: CGEvent) { event.post(tap: .cghidEventTap) }
}

/// What one synthesized event carried.
public struct PostedEvent: Sendable, Hashable {
    public var type: CGEventType
    /// Quartz global points.
    public var location: CGPoint
    public var flags: CGEventFlags
    public var keyCode: Int64
    public var clickState: Int64
    /// Wheel deltas (lines): axis 1 is vertical (positive scrolls up), axis 2 horizontal (positive scrolls left).
    public var scrollVertical: Int64
    public var scrollHorizontal: Int64
    /// Text carried by a keyboard event (typing).
    public var text: String?
    /// `eventSourceUserData`: OpenClicky's marker on every event it synthesizes.
    public var marker: Int64

    public init(_ event: CGEvent) {
        type = event.type
        location = event.location
        flags = event.flags
        keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        clickState = event.getIntegerValueField(.mouseEventClickState)
        scrollVertical = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        scrollHorizontal = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        marker = event.getIntegerValueField(.eventSourceUserData)
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 32)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        text = length > 0 ? String(utf16CodeUnits: buffer, count: length) : nil
    }

    public static func == (a: PostedEvent, b: PostedEvent) -> Bool {
        a.type == b.type && a.location == b.location && a.flags == b.flags && a.keyCode == b.keyCode && a.clickState == b.clickState
            && a.scrollVertical == b.scrollVertical && a.scrollHorizontal == b.scrollHorizontal && a.text == b.text && a.marker == b.marker
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(type.rawValue)
        hasher.combine(location.x)
        hasher.combine(location.y)
        hasher.combine(keyCode)
        hasher.combine(text)
    }
}

/// Keeps a description of every event and posts nothing.
public final class RecordingEventPoster: DriveEventPosting {
    private let log = OSAllocatedUnfairLock<[PostedEvent]>(initialState: [])
    public init() {}
    public func post(_ event: CGEvent) {
        let described = PostedEvent(event)
        log.withLock { $0.append(described) }
    }
    public var events: [PostedEvent] { log.withLock { $0 } }
}

/// Performs actions with Core Graphics events, in Quartz global points.
///
/// - Every event carries `syntheticEventMarker` in `eventSourceUserData`, so the user-input monitor can tell the
///   drive's own events from the user's.
/// - The stop switch is checked before each event. Once it trips, only releases (mouse up, key up) are posted, so a
///   stopped drive never leaves a button or key held down.
/// - Typing uses Unicode keyboard events (layout independent); key combinations use ANSI virtual key codes.
public final class CGEventActuator: DriveActuating {
    /// "OCDRIV" in ASCII.
    public static let syntheticEventMarker: Int64 = 0x4F43_4452_4956

    public struct Pacing: Sendable, Hashable {
        public var dragSteps: Int
        public var dragStepSeconds: Double
        public var clickGapSeconds: Double
        public var typingChunkSeconds: Double
        public var keyGapSeconds: Double
        /// UTF-16 units per typing event (CGEvent carries at most 20).
        public var typingChunkLength: Int

        public init(dragSteps: Int = 12, dragStepSeconds: Double = 0.012, clickGapSeconds: Double = 0.04,
                    typingChunkSeconds: Double = 0.018, keyGapSeconds: Double = 0.03, typingChunkLength: Int = 16) {
            self.dragSteps = dragSteps
            self.dragStepSeconds = dragStepSeconds
            self.clickGapSeconds = clickGapSeconds
            self.typingChunkSeconds = typingChunkSeconds
            self.keyGapSeconds = keyGapSeconds
            self.typingChunkLength = min(max(typingChunkLength, 1), 20)
        }
    }

    private struct Held: Sendable {
        var leftButtonAt: CGPoint?
        var keys: [(code: CGKeyCode, flags: UInt64)] = []
        var pointer: CGPoint?
    }

    public struct Failure: Error, Sendable, CustomStringConvertible {
        public var description: String
    }

    private let poster: any DriveEventPosting
    private let timing: any DriveTiming
    public let pacing: Pacing
    private let held = OSAllocatedUnfairLock(initialState: Held())

    public init(poster: any DriveEventPosting, timing: any DriveTiming = ContinuousTiming(), pacing: Pacing = Pacing()) {
        self.poster = poster
        self.timing = timing
        self.pacing = pacing
    }

    public var isDryRun: Bool { false }

    public func perform(_ action: ResolvedDriveAction, stop: TakeoverStopSwitch) async throws {
        try stop.check()
        switch action {
        case .move(let point):
            try move(to: point, stop: stop)
        case .click(let point, let button, let count, let modifiers):
            try move(to: point, stop: stop)
            for index in 1...max(1, min(count, 3)) {
                try mouse(button, down: true, at: point, clickState: index, flags: modifiers.cgFlags, stop: stop)
                try mouse(button, down: false, at: point, clickState: index, flags: modifiers.cgFlags, stop: stop, release: true)
                if index < count { try await timing.sleep(seconds: pacing.clickGapSeconds, stop: stop) }
            }
        case .mouseDown(let point):
            try move(to: point, stop: stop)
            try mouse(.left, down: true, at: point, clickState: 1, flags: [], stop: stop)
            held.withLock { $0.leftButtonAt = point }
        case .mouseUp(let point):
            if held.withLock({ $0.leftButtonAt }) != nil { try move(to: point, stop: stop) }
            try mouse(.left, down: false, at: point, clickState: 1, flags: [], stop: stop, release: true)
            held.withLock { $0.leftButtonAt = nil }
        case .drag(let from, let to, let modifiers):
            try move(to: from, stop: stop)
            try mouse(.left, down: true, at: from, clickState: 1, flags: modifiers.cgFlags, stop: stop)
            held.withLock { $0.leftButtonAt = from }
            do {
                let steps = max(pacing.dragSteps, 1)
                for step in 1...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                    try emit(mouseEvent(.leftMouseDragged, at: point, button: .left, flags: modifiers.cgFlags), stop: stop)
                    held.withLock { $0.leftButtonAt = point; $0.pointer = point }
                    try await timing.sleep(seconds: pacing.dragStepSeconds, stop: stop)
                }
            } catch {
                await releaseAll()
                throw error
            }
            try mouse(.left, down: false, at: to, clickState: 1, flags: modifiers.cgFlags, stop: stop, release: true)
            held.withLock { $0.leftButtonAt = nil }
        case .scroll(let point, let direction, let amount, let modifiers):
            try move(to: point, stop: stop)
            for index in 0..<max(amount, 1) {
                try emit(scrollEvent(direction, at: point, flags: modifiers.cgFlags), stop: stop)
                if index < amount - 1 { try await timing.sleep(seconds: 0.01, stop: stop) }
            }
        case .type(let text):
            try await type(text, stop: stop)
        case .key(let combo, let count):
            for index in 0..<max(count, 1) {
                try press(combo, stop: stop)
                if index < count - 1 { try await timing.sleep(seconds: pacing.keyGapSeconds, stop: stop) }
            }
        case .holdKey(let combo, let seconds):
            let flags = combo.modifiers.cgFlags
            try emit(keyEvent(combo.key.keyCode, down: true, flags: flags.union(combo.key.modifierFlag ?? [])), stop: stop)
            held.withLock { $0.keys.append((combo.key.keyCode, flags.rawValue)) }
            do {
                try await timing.sleep(seconds: seconds, stop: stop)
            } catch {
                await releaseAll()
                throw error
            }
            try emit(keyEvent(combo.key.keyCode, down: false, flags: flags), stop: stop, release: true)
            held.withLock { state in state.keys.removeAll { $0.code == combo.key.keyCode } }
        }
    }

    public func releaseAll() async {
        let state = held.withLock { state -> Held in
            let copy = state
            state.leftButtonAt = nil
            state.keys = []
            return copy
        }
        let dummy = TakeoverStopSwitch()
        if let point = state.leftButtonAt {
            try? emit(mouseEvent(.leftMouseUp, at: point, button: .left, flags: []), stop: dummy, release: true)
        }
        for key in state.keys.reversed() {
            try? emit(keyEvent(key.code, down: false, flags: CGEventFlags(rawValue: key.flags)), stop: dummy, release: true)
        }
    }

    // MARK: - Events

    private func move(to point: CGPoint, stop: TakeoverStopSwitch) throws {
        let dragging = held.withLock { $0.leftButtonAt } != nil
        try emit(mouseEvent(dragging ? .leftMouseDragged : .mouseMoved, at: point, button: .left, flags: []), stop: stop)
        held.withLock {
            $0.pointer = point
            if dragging { $0.leftButtonAt = point }
        }
    }

    private func mouse(_ button: DriveMouseButton, down: Bool, at point: CGPoint, clickState: Int, flags: CGEventFlags,
                       stop: TakeoverStopSwitch, release: Bool = false) throws {
        let type: CGEventType
        switch (button, down) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (.middle, true): type = .otherMouseDown
        case (.middle, false): type = .otherMouseUp
        }
        let event = mouseEvent(type, at: point, button: button, flags: flags)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        try emit(event, stop: stop, release: release)
    }

    private func mouseEvent(_ type: CGEventType, at point: CGPoint, button: DriveMouseButton, flags: CGEventFlags) -> CGEvent? {
        let source = CGEventSource(stateID: .privateState)
        let cgButton: CGMouseButton = button == .right ? .right : button == .middle ? .center : .left
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton)
        event?.flags = flags
        return event
    }

    private func scrollEvent(_ direction: DriveScrollDirection, at point: CGPoint, flags: CGEventFlags) -> CGEvent? {
        // Line units; wheel 1 is vertical (positive scrolls the content up, toward the top), wheel 2 horizontal
        // (positive scrolls toward the left).
        let vertical: Int32 = direction == .up ? 1 : direction == .down ? -1 : 0
        let horizontal: Int32 = direction == .left ? 1 : direction == .right ? -1 : 0
        let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .privateState), units: .line, wheelCount: 2,
                            wheel1: vertical, wheel2: horizontal, wheel3: 0)
        event?.location = point
        event?.flags = flags
        return event
    }

    private func keyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) -> CGEvent? {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: code, keyDown: down)
        event?.flags = flags
        return event
    }

    private func press(_ combo: KeyCombo, stop: TakeoverStopSwitch) throws {
        let flags = combo.modifiers.cgFlags
        try emit(keyEvent(combo.key.keyCode, down: true, flags: flags.union(combo.key.modifierFlag ?? [])), stop: stop)
        // Always let go of a key that went down, even if the stop switch tripped in between.
        try emit(keyEvent(combo.key.keyCode, down: false, flags: flags), stop: stop, release: true)
    }

    private func type(_ text: String, stop: TakeoverStopSwitch) async throws {
        var run: [UniChar] = []
        func flush() async throws {
            var index = 0
            while index < run.count {
                let chunk = Array(run[index..<min(index + pacing.typingChunkLength, run.count)])
                // A surrogate pair must not be split across two events.
                var end = chunk.count
                if end < run.count - index, UTF16.isLeadSurrogate(chunk[end - 1]) { end -= 1 }
                let piece = Array(chunk[0..<max(end, 1)])
                try emitText(piece, stop: stop)
                index += piece.count
                try await timing.sleep(seconds: pacing.typingChunkSeconds, stop: stop)
            }
            run.removeAll()
        }
        for character in text {
            switch character {
            case "\n", "\r\n", "\r":
                try await flush()
                try press(KeyCombo(key: DriveKey(name: "Return", keyCode: CGKeyCode(kVK_Return))), stop: stop)
            case "\t":
                try await flush()
                try press(KeyCombo(key: DriveKey(name: "Tab", keyCode: CGKeyCode(kVK_Tab))), stop: stop)
            default:
                run.append(contentsOf: String(character).utf16)
            }
        }
        try await flush()
    }

    private func emitText(_ units: [UniChar], stop: TakeoverStopSwitch) throws {
        for down in [true, false] {
            let event = keyEvent(0, down: down, flags: [])
            units.withUnsafeBufferPointer { buffer in
                event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            try emit(event, stop: stop, release: !down)
        }
    }

    /// Marks and posts one event. Refuses everything but releases once the stop switch has tripped.
    private func emit(_ event: CGEvent?, stop: TakeoverStopSwitch, release: Bool = false) throws {
        guard let event else { throw Failure(description: "Core Graphics could not create the event.") }
        if !release { try stop.check() }
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        poster.post(event)
    }
}
