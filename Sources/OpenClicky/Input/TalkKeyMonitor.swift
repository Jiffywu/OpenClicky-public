import AppKit
import CoreGraphics
import OpenClickyKit

/// Watches the talk keys anywhere on the Mac with a CGEventTap on its own thread and turns them into gestures
/// (`TalkKeyGestureMachine`): hold the voice chord, double-tap the text key, triple-tap it (reserved for always-on),
/// the dictation chord, and Escape.
///
/// The tap is active (it can swallow Escape when there is something to stop) when Accessibility is granted, listen-only
/// with Input Monitoring alone, and falls back to NSEvent monitors otherwise. It retries every few seconds, so granting
/// the permission later starts it without a relaunch. Escape is swallowed only while `escapeGate` says so.
///
/// The active tap filters keyboard events only; clicks and scrolls (which only tell the gesture machine a tap was not a
/// tap) are observed with NSEvent monitors, which can't hold them up. macOS doesn't announce that Accessibility was
/// taken away, and an active tap left running then can hold up input, so the active tap checks every few seconds that it
/// may still filter events and steps down to a listen-only tap or monitors when it may not.
@MainActor
final class TalkKeyMonitor {
    enum Mode: Equatable {
        case off
        /// A CGEventTap that can swallow Escape.
        case activeTap
        /// A listen-only CGEventTap: Escape also reaches the front app.
        case listenOnlyTap
        /// No tap could be created (no permission yet): NSEvent monitors, which see modifier changes but not other apps'
        /// keys.
        case eventMonitors
    }

    /// Modifiers that matter for talk keys (for NSEvent-based callers such as onboarding).
    static let relevantFlags: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]
    static let escapeKeyCode: UInt16 = 53

    var keys: TalkKeySettings {
        didSet { machine.keys = keys }
    }
    var onGesture: ((TalkKeyGestureMachine.Output) -> Void)?
    /// Whether the app still has a voice question open. A double-tapped question the app ignored or ended another way
    /// is dropped from the gesture machine before the next key event, so the next double tap starts a new one.
    var voicePressIsOpen: (() -> Bool)?
    /// Read on the tap thread for every Escape: swallow it only when it stops something of ours.
    let escapeGate = EscapeGate()
    private(set) var mode: Mode = .off {
        didSet { if mode != oldValue { onModeChange?(mode) } }
    }
    var onModeChange: ((Mode) -> Void)?

    private var machine: TalkKeyGestureMachine
    private var tap: EventTapThread?
    private var monitors: [Any] = []
    private var tickTimer: Timer?
    private var retryTimer: Timer?

    init(keys: TalkKeySettings = .defaults) {
        self.keys = keys
        machine = TalkKeyGestureMachine(keys: keys)
    }

    func start() {
        stop()
        attach()
        // A permission granted later upgrades the monitors to a tap; one taken away steps the active tap down.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.mode {
                case .activeTap:
                    guard !EventTapThread.canFilterEvents() else { return }
                    self.detach()
                    self.mode = .off
                    self.attach()
                case .eventMonitors, .listenOnlyTap:
                    self.attach()
                case .off:
                    break
                }
            }
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        detach()
        mode = .off
    }

    private func attach() {
        let previous = mode
        let deliver: @Sendable (RawKeyEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.process(event) } }
        }
        if let thread = EventTapThread.make(listenOnly: false, gate: escapeGate, deliver: deliver) {
            detach()
            tap = thread
            addMonitors(for: [.leftMouseDown, .rightMouseDown, .scrollWheel])
            mode = .activeTap
            return
        }
        if previous == .listenOnlyTap { return }
        if let thread = EventTapThread.make(listenOnly: true, gate: escapeGate, deliver: deliver) {
            detach()
            tap = thread
            mode = .listenOnlyTap
            return
        }
        if previous == .eventMonitors { return }
        detach()
        addMonitors(for: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel])
        mode = .eventMonitors
    }

    /// NSEvent monitors see copies of events; they never delay or swallow them.
    private func addMonitors(for mask: NSEvent.EventTypeMask) {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let raw = RawKeyEvent(event) else { return }
            MainActor.assumeIsolated { self?.process(raw) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in handler(event); return event }) {
            monitors.append(local)
        }
    }

    private func detach() {
        tap?.stop()
        tap = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func process(_ event: RawKeyEvent) {
        if machine.isVoiceHeld, voicePressIsOpen?() == false { machine.voicePressEnded() }
        let outputs: [TalkKeyGestureMachine.Output]
        switch event {
        case .modifiers(let held, let time): outputs = machine.modifiersChanged(held, at: time)
        case .key(let code, let time): outputs = machine.keyDown(isEscape: code == Self.escapeKeyCode, at: time)
        case .activity(let time): outputs = machine.otherActivity(at: time)
        }
        outputs.forEach { onGesture?($0) }
        scheduleTick()
    }

    /// A double tap waits to see whether a third tap comes; fire it when the window closes.
    private func scheduleTick() {
        tickTimer?.invalidate()
        tickTimer = nil
        guard let deadline = machine.pendingDeadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime) + 0.005
        tickTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let outputs = self.machine.tick(at: ProcessInfo.processInfo.systemUptime)
                outputs.forEach { self.onGesture?($0) }
                self.scheduleTick()
            }
        }
    }
}

/// Whether Escape should be swallowed right now; set on the main actor, read on the tap thread.
final class EscapeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var consumesEscape: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// One key event, reduced to what the gesture machine needs. Times are seconds since boot.
enum RawKeyEvent: Sendable {
    case modifiers(Set<DictationModifier>, TimeInterval)
    case key(UInt16, TimeInterval)
    case activity(TimeInterval)

    init?(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged: self = .modifiers(Self.modifiers(event.modifierFlags), event.timestamp)
        case .keyDown: self = .key(event.keyCode, event.timestamp)
        case .leftMouseDown, .rightMouseDown, .scrollWheel: self = .activity(event.timestamp)
        default: return nil
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Set<DictationModifier> {
        var set = Set<DictationModifier>()
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.command) { set.insert(.command) }
        if flags.contains(.shift) { set.insert(.shift) }
        if flags.contains(.function) { set.insert(.function) }
        return set
    }

    static func modifiers(_ flags: CGEventFlags) -> Set<DictationModifier> {
        var set = Set<DictationModifier>()
        if flags.contains(.maskControl) { set.insert(.control) }
        if flags.contains(.maskAlternate) { set.insert(.option) }
        if flags.contains(.maskCommand) { set.insert(.command) }
        if flags.contains(.maskShift) { set.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { set.insert(.function) }
        return set
    }
}

/// A CGEventTap with its own thread and run loop, so a busy main thread never delays (or times out) key handling.
final class EventTapThread: Thread, @unchecked Sendable {
    private let box: TapBox
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    private init(box: TapBox) {
        self.box = box
        super.init()
        name = "app.openclicky.talk-keys"
        qualityOfService = .userInteractive
    }

    /// A running tap, or nil when macOS refuses one (no Accessibility for an active tap, no Input Monitoring for a
    /// listen-only one).
    static func make(listenOnly: Bool, gate: EscapeGate, deliver: @escaping @Sendable (RawKeyEvent) -> Void) -> EventTapThread? {
        let box = TapBox(gate: gate, listenOnly: listenOnly, deliver: deliver)
        // An active tap filters only the keys it may swallow (Escape) and the modifiers; a listen-only tap can't hold
        // anything up, so it also watches clicks and scrolls.
        let types: [CGEventType] = listenOnly ? [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
                                              : [.flagsChanged, .keyDown]
        var mask: CGEventMask = 0
        for type in types { mask |= CGEventMask(1) << CGEventMask(type.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: listenOnly ? .listenOnly : .defaultTap, eventsOfInterest: mask,
                                           callback: talkKeyTapCallback, userInfo: Unmanaged.passUnretained(box).toOpaque())
        else { return nil }
        box.port = port
        let thread = EventTapThread(box: box)
        thread.start()
        thread.ready.wait()
        return thread
    }

    /// Whether this process may still filter events (Accessibility). Creating an active tap is the dependable check:
    /// `AXIsProcessTrusted()` can keep saying yes after the app is removed from the list. The probe tap is closed at once.
    static func canFilterEvents() -> Bool {
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue),
                                           callback: talkKeyTapCallback, userInfo: nil)
        else { return false }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        return true
    }

    override func main() {
        guard let port = box.port, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            ready.signal()
            return
        }
        let loop = CFRunLoopGetCurrent()
        lock.withLock { runLoop = loop }
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        ready.signal()
        CFRunLoopRun()
        CFRunLoopRemoveSource(loop, source, .commonModes)
    }

    func stop() {
        if let port = box.port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop = lock.withLock({ runLoop }) { CFRunLoopStop(loop) }
    }
}

/// What the C callback reaches through `userInfo`.
private final class TapBox: @unchecked Sendable {
    let gate: EscapeGate
    let listenOnly: Bool
    let deliver: @Sendable (RawKeyEvent) -> Void
    var port: CFMachPort?

    init(gate: EscapeGate, listenOnly: Bool, deliver: @escaping @Sendable (RawKeyEvent) -> Void) {
        self.gate = gate
        self.listenOnly = listenOnly
        self.deliver = deliver
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off; turn it straight back on.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            deliver(.modifiers(RawKeyEvent.modifiers(event.flags), Self.seconds(event)))
        case .keyDown:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !repeating { deliver(.key(code, Self.seconds(event))) }
            if code == TalkKeyMonitorConstants.escape, !listenOnly, gate.consumesEscape { return nil }
        case .leftMouseDown, .rightMouseDown, .scrollWheel:
            deliver(.activity(Self.seconds(event)))
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Event timestamps are nanoseconds since boot, like `ProcessInfo.systemUptime`.
    static func seconds(_ event: CGEvent) -> TimeInterval { Double(event.timestamp) / 1_000_000_000 }
}

private enum TalkKeyMonitorConstants {
    static let escape: UInt16 = 53
}

private func talkKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<TapBox>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}
