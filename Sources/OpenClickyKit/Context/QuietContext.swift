import AppKit
import CoreAudio
import Foundation

// Quiet contexts (docs/audio-robustness.md): while the user is on a call, recording, or in a Focus (Do Not Disturb),
// OpenClicky doesn't speak up on its own. Job reports, routine notices, meeting countdowns and onboarding prompts are
// held and come back when the quiet ends. Anything the user asks for still answers as usual.
//
// Detection uses only what a normal app may read without extra permissions: which processes are recording from the
// microphone (CoreAudio's process list, macOS 14.2+), the running apps, and the
// Focus database when Full Disk Access has been granted.

/// Why a Focus counts as on.
public enum FocusModeReason: Sendable, Hashable, Codable {
    /// Turned on by hand (Control Center, a shortcut, the Focus menu).
    case manuallyEnabled(mode: String?)
    /// On by a schedule in System Settings > Focus.
    case scheduled(mode: String?)
    /// Retained for decoding older simulated readings; menu visibility no longer establishes active Focus.
    case shownInMenuBar

    public var label: String {
        switch self {
        case .manuallyEnabled(let mode): "\(mode ?? "a Focus") is on"
        case .scheduled(let mode): "\(mode ?? "a Focus") is on by schedule"
        case .shownInMenuBar: "a Focus is on"
        }
    }
}

/// Why OpenClicky keeps quiet.
public enum QuietContextReason: Sendable, Hashable, Codable {
    /// A call app (or a browser) is using the microphone.
    case onCall(app: String?)
    /// Another app is recording from the microphone.
    case microphoneBusy(app: String?)
    case focus(FocusModeReason)

    public var label: String {
        switch self {
        case .onCall(let app): app.map { "on a call in \($0)" } ?? "on a call"
        case .microphoneBusy(let app): app.map { "\($0) is using the microphone" } ?? "another app is using the microphone"
        case .focus(let reason): reason.label
        }
    }

    public var isCall: Bool {
        switch self {
        case .onCall, .microphoneBusy: true
        case .focus: false
        }
    }
}

/// Everything that makes now a quiet moment (empty: not quiet).
public struct QuietContext: Sendable, Hashable, Codable {
    public var reasons: [QuietContextReason]

    public init(reasons: [QuietContextReason] = []) { self.reasons = reasons }

    public static let none = QuietContext()

    public var isQuiet: Bool { !reasons.isEmpty }
    public var onCall: Bool { reasons.contains(where: \.isCall) }
    public var inFocus: Bool { reasons.contains { if case .focus = $0 { true } else { false } } }

    /// "on a call in Zoom; Work is on", or "not quiet".
    public var summary: String { reasons.isEmpty ? "not quiet" : reasons.map(\.label).joined(separator: "; ") }

    /// What the held items wait for, for a notice ("until your call ends").
    public var untilPhrase: String {
        if onCall { return "until your call ends" }
        if inFocus { return "until your Focus ends" }
        return "until you're free"
    }
}

// MARK: - Focus

/// One reading of the Focus state, with notes on what each source could see (for `occtl quiet status`).
public struct FocusModeReading: Sendable, Hashable {
    public var reason: FocusModeReason?
    public var notes: [String]

    public init(reason: FocusModeReason? = nil, notes: [String] = []) {
        self.reason = reason
        self.notes = notes
    }
}

public protocol FocusStatusReading: Sendable {
    func read(now: Date) -> FocusModeReading
}

/// The Focus database in `~/Library/DoNotDisturb/DB`: `Assertions.json` holds a Focus turned on by hand,
/// `ModeConfigurations.json` the modes with their schedules. macOS only lets apps with Full Disk Access read it; without
/// that the reading says so and finds nothing.
public struct FocusDatabaseReader: FocusStatusReading {
    public var directory: URL
    public var calendar: Calendar

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB"),
                calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
    }

    public func read(now: Date) -> FocusModeReading {
        let assertions: Data
        do {
            assertions = try Data(contentsOf: directory.appendingPathComponent("Assertions.json"))
        } catch {
            return FocusModeReading(notes: ["Focus database: not readable (\(Self.why(error)))"])
        }
        let configurations = try? Data(contentsOf: directory.appendingPathComponent("ModeConfigurations.json"))
        let modes = configurations.map(Self.modes(from:)) ?? [:]
        if let manual = Self.manualMode(from: assertions) {
            return FocusModeReading(reason: .manuallyEnabled(mode: modes[manual]?.name ?? Self.friendlyName(manual)),
                                notes: ["Focus database: \(manual) turned on by hand"])
        }
        return FocusModeReading(notes: ["Focus database: no Focus on (\(modes.count) mode(s) configured)"])
    }

    /// A schedule trigger: on from start to end (wrapping past midnight) on the weekdays in the mask (bit 0 Sunday).
    public struct Schedule: Sendable, Hashable {
        public var startMinute: Int
        public var endMinute: Int
        public var weekdays: Int

        public init(startMinute: Int, endMinute: Int, weekdays: Int) {
            self.startMinute = startMinute
            self.endMinute = endMinute
            self.weekdays = weekdays
        }

        public func covers(_ date: Date, calendar: Calendar) -> Bool {
            let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
            guard let weekday = parts.weekday else { return false }
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            func on(_ day: Int) -> Bool { weekdays & (1 << ((day - 1 + 7) % 7)) != 0 }
            if startMinute == endMinute { return false }
            if startMinute < endMinute { return on(weekday) && minute >= startMinute && minute < endMinute }
            // Overnight: the evening part belongs to today's slot, the morning part to yesterday's.
            if minute >= startMinute { return on(weekday) }
            if minute < endMinute { return on(weekday == 1 ? 7 : weekday - 1) }
            return false
        }
    }

    public struct Mode: Sendable, Hashable {
        public var name: String?
        public var schedules: [Schedule]
    }

    /// The mode identifier of the newest manual assertion, if any.
    static func manualMode(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return nil }
        for entry in entries {
            let records = entry["storeAssertionRecords"] as? [[String: Any]] ?? []
            let newest = records.max { ($0["assertionStartDateTimestamp"] as? Double ?? 0) < ($1["assertionStartDateTimestamp"] as? Double ?? 0) }
            if let details = newest?["assertionDetails"] as? [String: Any],
               let mode = details["assertionDetailsModeIdentifier"] as? String {
                return mode
            }
        }
        return nil
    }

    /// Mode names and enabled schedule triggers by mode identifier.
    static func modes(from data: Data) -> [String: Mode] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return [:] }
        var modes: [String: Mode] = [:]
        for entry in entries {
            guard let configurations = entry["modeConfigurations"] as? [String: Any] else { continue }
            for (identifier, value) in configurations {
                guard let configuration = value as? [String: Any] else { continue }
                let name = (configuration["mode"] as? [String: Any])?["name"] as? String
                let triggers = ((configuration["triggers"] as? [String: Any])?["triggers"] as? [[String: Any]]) ?? []
                let schedules = triggers.compactMap { trigger -> Schedule? in
                    guard (trigger["class"] as? String)?.hasSuffix("ScheduleTrigger") == true,
                          (trigger["enabledSetting"] as? Int ?? 0) == 2 else { return nil }
                    func int(_ key: String) -> Int { trigger[key] as? Int ?? 0 }
                    return Schedule(startMinute: int("timePeriodStartTimeHour") * 60 + int("timePeriodStartTimeMinute"),
                                    endMinute: int("timePeriodEndTimeHour") * 60 + int("timePeriodEndTimeMinute"),
                                    weekdays: trigger["timePeriodWeekdays"] as? Int ?? 0x7F)
                }
                modes[identifier] = Mode(name: name, schedules: schedules)
            }
        }
        return modes
    }

    static func friendlyName(_ identifier: String) -> String? {
        if identifier.hasSuffix(".default") { return "Do Not Disturb" }
        let last = identifier.split(separator: ".").last.map(String.init)
        return last?.capitalized
    }

    static func why(_ error: Error) -> String {
        let code = (error as NSError).code
        if code == NSFileReadNoPermissionError || (error as NSError).underlyingErrors.contains(where: { ($0 as NSError).code == 1 }) {
            return "needs Full Disk Access"
        }
        if code == NSFileReadNoSuchFileError { return "no file" }
        return (error as NSError).localizedDescription
    }
}

/// Menu visibility is diagnostic only. A pinned Focus item can remain visible while Focus is off.
public struct ControlCenterFocusIndicator: FocusStatusReading {
    public var read: @Sendable () -> Bool?

    public init(read: @escaping @Sendable () -> Bool? = ControlCenterFocusIndicator.menuBarFlag) { self.read = read }

    public func read(now: Date) -> FocusModeReading {
        switch read() {
        case true?: FocusModeReading(notes: ["menu bar: Focus item visible; active state unknown because the item may be pinned"])
        case false?: FocusModeReading(notes: ["menu bar: Focus item hidden; active state unknown"])
        case nil: FocusModeReading(notes: ["menu bar: no Focus item; active state unknown"])
        }
    }

    /// Control Center's own preference for the Focus item's visibility.
    public static let menuBarFlag: @Sendable () -> Bool? = {
        let domain = "com.apple.controlcenter" as CFString
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue("NSStatusItem Visible FocusModes" as CFString, domain)
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }
}

/// Every Focus source together: the first that finds a Focus wins; notes from all of them.
public struct SystemFocusStatus: FocusStatusReading {
    public var sources: [any FocusStatusReading]

    public init(sources: [any FocusStatusReading] = [FocusDatabaseReader(), ControlCenterFocusIndicator()]) {
        self.sources = sources
    }

    public func read(now: Date) -> FocusModeReading {
        var notes: [String] = []
        var reason: FocusModeReason?
        for source in sources {
            let reading = source.read(now: now)
            notes += reading.notes
            if reason == nil { reason = reading.reason }
        }
        return FocusModeReading(reason: reason, notes: notes)
    }
}

/// A Focus state set by hand (tests, `occtl quiet simulate`).
public final class FixedFocusStatus: FocusStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private var reason: FocusModeReason?

    public init(_ reason: FocusModeReason? = nil) { self.reason = reason }

    public func set(_ reason: FocusModeReason?) { lock.withLock { self.reason = reason } }

    public func read(now: Date) -> FocusModeReading { FocusModeReading(reason: lock.withLock { reason }, notes: ["fixed"]) }
}

// MARK: - Calls

/// A process recording from an input device now.
public struct AudioInputUser: Sendable, Hashable {
    public var pid: Int32?
    public var bundleID: String?
    public var name: String?
    /// A regular app (with a Dock icon), not a helper or daemon.
    public var isRegularApp: Bool

    public init(pid: Int32? = nil, bundleID: String?, name: String? = nil, isRegularApp: Bool = true) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRegularApp = isRegularApp
    }
}

public protocol AudioInputUsageReading: Sendable {
    /// Who records from the microphone now. Nil when this Mac can't say per process (before macOS 14.2) and the input
    /// isn't running either; a single anonymous user when only "the input is running somewhere" is known.
    func inputUsers() -> [AudioInputUser]
}

/// CoreAudio's process list (macOS 14.2+): each process object says whether it is recording. Older systems fall back to
/// whether the default input is running in any process. Reading it needs no permission.
public struct CoreAudioInputUsage: AudioInputUsageReading {
    public init() {}

    public func inputUsers() -> [AudioInputUser] {
        if #available(macOS 14.2, *) { return Self.processUsers() }
        guard let input = AudioDevices.defaultDeviceID(input: true) else { return [] }
        let running: UInt32 = AudioDevices.scalar(input, kAudioDevicePropertyDeviceIsRunningSomewhere, default: 0)
        return running != 0 ? [AudioInputUser(bundleID: nil, isRegularApp: false)] : []
    }

    @available(macOS 14.2, *)
    static func processUsers() -> [AudioInputUser] {
        var address = AudioDevices.address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { raw in AudioObjectGetPropertyData(system, &address, 0, nil, &size, raw.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.compactMap { id -> AudioInputUser? in
            let recording: UInt32 = AudioDevices.scalar(id, kAudioProcessPropertyIsRunningInput, default: 0)
            guard recording != 0 else { return nil }
            let pid: pid_t = AudioDevices.scalar(id, kAudioProcessPropertyPID, default: pid_t(-1))
            let bundle = AudioDevices.string(id, kAudioProcessPropertyBundleID)
            let app = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
            return AudioInputUser(pid: pid > 0 ? pid : nil, bundleID: bundle ?? app?.bundleIdentifier, name: app?.localizedName,
                                  isRegularApp: app?.activationPolicy == .regular)
        }
    }
}

/// Input users set by hand (tests, `occtl quiet simulate`).
public final class FixedInputUsage: AudioInputUsageReading, @unchecked Sendable {
    private let lock = NSLock()
    private var users: [AudioInputUser]

    public init(_ users: [AudioInputUser] = []) { self.users = users }

    public func set(_ users: [AudioInputUser]) { lock.withLock { self.users = users } }

    public func inputUsers() -> [AudioInputUser] { lock.withLock { users } }
}

/// On a call: a call app (or a browser, for Meet and the like) is recording from the mic. Another regular app recording
/// counts as "microphone busy" (a voice memo, a screen recording with sound), which is just as good a reason to keep
/// quiet. OpenClicky's own capture and the system's always-listening helpers don't count.
public struct CallPresenceDetector: Sendable {
    /// Bundle-identifier prefixes of apps that make calls, with a name to show.
    public static let callApps: [(prefix: String, name: String)] = [
        ("com.apple.FaceTime", "FaceTime"), ("us.zoom.", "Zoom"), ("com.microsoft.teams", "Microsoft Teams"),
        ("Cisco-Systems.Spark", "Webex"), ("com.webex.", "Webex"), ("com.cisco.webex", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"), ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("desktop.WhatsApp", "WhatsApp"), ("com.skype.", "Skype"), ("ru.keepcoder.Telegram", "Telegram"),
        ("org.telegram.", "Telegram"), ("com.apple.mobilephone", "Phone"), ("com.google.meet", "Google Meet"),
        ("com.around.", "Around"), ("com.loom.", "Loom"), ("com.ringcentral.", "RingCentral"), ("com.gotomeeting", "GoTo Meeting"),
        ("com.logmein.", "GoTo"), ("com.amazon.Amazon-Chime", "Amazon Chime"), ("com.bluejeans.", "BlueJeans"),
    ]
    /// Browsers: recording from one is nearly always a web call.
    public static let browsers: [(prefix: String, name: String)] = [
        ("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"), ("com.apple.WebKit", "Safari"),
        ("company.thebrowser.", "Arc"), ("org.mozilla.firefox", "Firefox"), ("com.microsoft.edgemac", "Edge"),
        ("com.brave.Browser", "Brave"), ("com.vivaldi.Vivaldi", "Vivaldi"), ("com.operasoftware.", "Opera"),
    ]
    /// System helpers that hold the mic without the user recording anything ("Hey Siri", dictation, the audio server).
    public static let ignoredPrefixes = ["com.apple.corespeech", "com.apple.siri", "com.apple.SpeechRecognitionCore",
                                         "com.apple.assistant", "com.apple.audio.", "com.apple.coreaudiod", "com.apple.voicememod",
                                         "com.apple.dictation", "com.apple.accessibility.heard"]

    public var usage: any AudioInputUsageReading
    /// OpenClicky's own bundle identifiers (the app, occtl's) whose recording doesn't count.
    public var ownBundleIDs: Set<String>
    /// Our own process ids.
    public var ownPIDs: Set<Int32>

    public init(usage: any AudioInputUsageReading = CoreAudioInputUsage(), ownBundleIDs: Set<String> = CallPresenceDetector.defaultOwnIDs,
                ownPIDs: Set<Int32> = [ProcessInfo.processInfo.processIdentifier]) {
        self.usage = usage
        self.ownBundleIDs = ownBundleIDs
        self.ownPIDs = ownPIDs
    }

    public static var defaultOwnIDs: Set<String> {
        Set([Bundle.main.bundleIdentifier, "app.openclicky", "app.openclicky.OpenClicky"].compactMap { $0 })
    }

    /// Uses this fallback only when input is running but macOS cannot identify its process.
    public func detect(unattributedInput: QuietContextReason? = .microphoneBusy(app: nil)) -> QuietContextReason? {
        let users = usage.inputUsers().filter { user in
            if let pid = user.pid, ownPIDs.contains(pid) { return false }
            guard let bundle = user.bundleID else { return true }
            if ownBundleIDs.contains(bundle) || ownBundleIDs.contains(where: { bundle.hasPrefix($0 + ".") }) { return false }
            return !Self.ignoredPrefixes.contains { bundle.hasPrefix($0) }
        }
        guard !users.isEmpty else { return nil }
        for user in users {
            if let bundle = user.bundleID, let app = Self.callApps.first(where: { bundle.hasPrefix($0.prefix) }) {
                return .onCall(app: app.name)
            }
        }
        for user in users {
            if let bundle = user.bundleID, let browser = Self.browsers.first(where: { bundle.hasPrefix($0.prefix) }) {
                return .onCall(app: browser.name)
            }
        }
        // Another app recording (a regular app), or an input running somewhere when that's all the system can say.
        if let app = users.first(where: \.isRegularApp) { return .microphoneBusy(app: app.name ?? app.bundleID) }
        if users.contains(where: { $0.bundleID == nil && $0.pid == nil }) { return unattributedInput }
        return nil
    }
}

// MARK: - The monitor

/// Reads the Focus and call state on a timer and reports changes. `refresh()` reads at once.
@MainActor
public final class QuietContextMonitor {
    public struct Sources: Sendable {
        public var focus: any FocusStatusReading
        public var calls: CallPresenceDetector?
        /// Whether OpenClicky itself holds the mic right now (its own recording never counts as a call).
        public var ownCaptureActive: @Sendable () -> Bool

        public init(focus: any FocusStatusReading = SystemFocusStatus(), calls: CallPresenceDetector? = CallPresenceDetector(),
                    ownCaptureActive: @escaping @Sendable () -> Bool = { false }) {
            self.focus = focus
            self.calls = calls
            self.ownCaptureActive = ownCaptureActive
        }
    }

    public var sources: Sources
    public var interval: TimeInterval
    public private(set) var context = QuietContext.none
    /// The Focus sources' notes from the last reading.
    public private(set) var notes: [String] = []
    public var onChange: ((QuietContext) -> Void)?
    private var timer: Task<Void, Never>?
    private let now: @Sendable () -> Date

    public init(sources: Sources = Sources(), interval: TimeInterval = 5, now: @escaping @Sendable () -> Date = Date.init) {
        self.sources = sources
        self.interval = interval
        self.now = now
    }

    public func start() {
        guard timer == nil else { return }
        refresh()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.interval ?? 5) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Reads every source now; reports a change.
    @discardableResult
    public func refresh() -> QuietContext {
        var reasons: [QuietContextReason] = []
        // Identified external recorders still count while we capture. Only unattributed input can be our own mic;
        // in that case keep the last call reading instead of treating our capture as another app.
        let fallback: QuietContextReason? = sources.ownCaptureActive()
            ? context.reasons.first(where: \.isCall) : .microphoneBusy(app: nil)
        if let call = sources.calls?.detect(unattributedInput: fallback) {
            reasons.append(call)
        }
        let focus = sources.focus.read(now: now())
        notes = focus.notes
        if let reason = focus.reason { reasons.append(.focus(reason)) }
        let fresh = QuietContext(reasons: reasons)
        if fresh != context {
            context = fresh
            onChange?(fresh)
        }
        return fresh
    }
}

// MARK: - Holding proactive surfaces

/// Things OpenClicky would bring up on its own, which wait while it's quiet.
public enum ProactiveKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// A background job came back (a spoken report turn).
    case jobReport = "job_report"
    /// A routine run came back.
    case routineNotice = "routine_notice"
    /// "Your meeting starts in 5 minutes."
    case meetingCountdown = "meeting_countdown"
    /// Onboarding asking the user to carry on.
    case onboardingPrompt = "onboarding_prompt"
}

public struct ProactiveItem: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var kind: ProactiveKind
    public var title: String
    /// What the surface needs to show it later (a report turn's note, an event id).
    public var payload: String
    public var createdAt: Date
    /// After this it isn't worth showing (a meeting that has started).
    public var expiresAt: Date?

    public init(id: String = UUID().uuidString, kind: ProactiveKind, title: String, payload: String = "", createdAt: Date,
                expiresAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.payload = payload
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// The quiet-context model: decides whether a proactive item shows now, waits, or is dropped, and hands back what waited
/// once the quiet ends. Pure value type with injected time.
public struct QuietGate: Sendable, Hashable {
    public struct Policy: Sendable, Hashable {
        /// Kinds held during a call (or another app recording).
        public var holdDuringCalls: Set<ProactiveKind>
        /// Kinds held during a Focus.
        public var holdDuringFocus: Set<ProactiveKind>
        /// Kinds dropped instead of held during a call (a countdown to a meeting the user is probably in).
        public var dropDuringCalls: Set<ProactiveKind>
        /// Held items older than this are dropped when the quiet ends.
        public var maxHold: TimeInterval
        /// Hold nothing (the user turned the quiet behaviour off).
        public var enabled: Bool

        public init(holdDuringCalls: Set<ProactiveKind> = Set(ProactiveKind.allCases),
                    holdDuringFocus: Set<ProactiveKind> = Set(ProactiveKind.allCases),
                    dropDuringCalls: Set<ProactiveKind> = [.meetingCountdown], maxHold: TimeInterval = 4 * 3600, enabled: Bool = true) {
            self.holdDuringCalls = holdDuringCalls
            self.holdDuringFocus = holdDuringFocus
            self.dropDuringCalls = dropDuringCalls
            self.maxHold = maxHold
            self.enabled = enabled
        }
    }

    public enum Decision: Sendable, Hashable {
        case deliver
        case hold
        case drop(String)
    }

    public var policy: Policy
    public private(set) var context: QuietContext = .none
    public private(set) var held: [ProactiveItem] = []

    public init(policy: Policy = Policy()) { self.policy = policy }

    /// Something wants to show. `.hold` keeps it until the quiet ends.
    public mutating func offer(_ item: ProactiveItem, now: Date) -> Decision {
        if let expires = item.expiresAt, expires <= now { return .drop("expired") }
        guard policy.enabled, context.isQuiet else { return .deliver }
        if context.onCall, policy.dropDuringCalls.contains(item.kind) { return .drop("dropped during a call") }
        let holds = (context.onCall && policy.holdDuringCalls.contains(item.kind))
            || (context.inFocus && policy.holdDuringFocus.contains(item.kind))
        guard holds else { return .deliver }
        held.removeAll { $0.id == item.id }
        held.append(item)
        return .hold
    }

    /// The context changed. Returns the held items to show now (all of them once it isn't quiet any more, in arrival
    /// order, without expired or too-old ones; those that are no longer held by the new context otherwise).
    public mutating func update(_ new: QuietContext, now: Date) -> (release: [ProactiveItem], dropped: [ProactiveItem]) {
        context = new
        var release: [ProactiveItem] = []
        var dropped: [ProactiveItem] = []
        var keep: [ProactiveItem] = []
        for item in held {
            let stale = item.expiresAt.map { $0 <= now } ?? false || now.timeIntervalSince(item.createdAt) > policy.maxHold
            if stale {
                dropped.append(item)
            } else if !policy.enabled || !new.isQuiet || !stillHeld(item) {
                release.append(item)
            } else {
                keep.append(item)
            }
        }
        held = keep
        return (release, dropped)
    }

    public mutating func withdraw(_ id: String) { held.removeAll { $0.id == id } }

    private func stillHeld(_ item: ProactiveItem) -> Bool {
        (context.onCall && policy.holdDuringCalls.contains(item.kind)) || (context.inFocus && policy.holdDuringFocus.contains(item.kind))
    }

    /// "2 job reports are waiting until your call ends" (nil when nothing waits).
    public var heldSummary: String? {
        guard !held.isEmpty else { return nil }
        let count = held.count
        return "\(count) thing\(count == 1 ? " is" : "s are") waiting \(context.untilPhrase)."
    }
}

/// The quiet-context model at work: the monitor's readings feed the gate, `offer` asks whether a proactive item may
/// show now, and what waited comes back through `onRelease` once the quiet ends. The app routes job and routine
/// reports, the onboarding prompt and meeting countdowns through it; `occtl quiet simulate` drives it with fixed
/// sources.
@MainActor
public final class QuietHold {
    public let monitor: QuietContextMonitor
    public private(set) var gate: QuietGate
    /// Held items to show now (the quiet ended), in arrival order.
    public var onRelease: (([ProactiveItem]) -> Void)?
    /// Held items that went stale and won't be shown.
    public var onDrop: (([ProactiveItem]) -> Void)?
    public var onContextChange: ((QuietContext) -> Void)?
    public var onLog: ((String) -> Void)?
    private let now: @Sendable () -> Date

    public init(monitor: QuietContextMonitor = QuietContextMonitor(), policy: QuietGate.Policy = .init(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.monitor = monitor
        gate = QuietGate(policy: policy)
        self.now = now
    }

    public var context: QuietContext { gate.context }
    public var held: [ProactiveItem] { gate.held }

    /// Whether OpenClicky keeps quiet now: a call or Focus is on and the user hasn't turned holding off. Notifications
    /// go silent only then.
    public var isQuiet: Bool { gate.policy.enabled && gate.context.isQuiet }

    public var policy: QuietGate.Policy {
        get { gate.policy }
        set {
            gate.policy = newValue
            apply(gate.context)
        }
    }

    public func start() {
        monitor.onChange = { [weak self] context in self?.apply(context) }
        monitor.start()
        apply(monitor.context)
    }

    public func stop() { monitor.stop() }

    /// Whether `item` shows now. Reads the sources first, so a call that just started counts.
    @discardableResult
    public func offer(_ item: ProactiveItem) -> QuietGate.Decision {
        monitor.refresh()
        let decision = gate.offer(item, now: now())
        switch decision {
        case .deliver: break
        case .hold: onLog?("holding \(item.kind.rawValue) \"\(item.title)\" \(gate.context.untilPhrase) (\(gate.context.summary))")
        case .drop(let why): onLog?("dropping \(item.kind.rawValue) \"\(item.title)\": \(why)")
        }
        return decision
    }

    public func withdraw(_ id: String) { gate.withdraw(id) }

    /// Reads the sources now (and releases what waited if the quiet is over).
    public func refresh() { monitor.refresh() }

    private func apply(_ context: QuietContext) {
        let previous = gate.context
        let (release, dropped) = gate.update(context, now: now())
        if previous != context { onLog?("quiet context: \(context.summary)") }
        onContextChange?(context)
        if !dropped.isEmpty {
            onLog?("dropped \(dropped.count) stale held item(s)")
            onDrop?(dropped)
        }
        if !release.isEmpty {
            onLog?("releasing \(release.count) held item(s)")
            onRelease?(release)
        }
    }
}
