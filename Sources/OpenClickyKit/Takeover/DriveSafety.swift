import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// What is under a point, or has keyboard focus, as far as the Mac can tell. Fields the probe could not read are nil.
public struct DriveTargetInfo: Sendable, Hashable {
    public var ownerPID: Int32?
    public var ownerBundleID: String?
    public var ownerName: String?
    public var windowTitle: String?
    /// The Accessibility element's role and subrole ("AXSecureTextField" marks a password field).
    public var role: String?
    public var subrole: String?
    public var label: String?

    public init(ownerPID: Int32? = nil, ownerBundleID: String? = nil, ownerName: String? = nil, windowTitle: String? = nil,
                role: String? = nil, subrole: String? = nil, label: String? = nil) {
        self.ownerPID = ownerPID
        self.ownerBundleID = ownerBundleID
        self.ownerName = ownerName
        self.windowTitle = windowTitle
        self.role = role
        self.subrole = subrole
        self.label = label
    }

    public var isSecureField: Bool { role == "AXSecureTextField" || subrole == "AXSecureTextField" }
}

/// Reads the Mac for the safety check: which window and element sit under a point, what has keyboard focus,
/// whether secure keyboard entry is on, and where the pointer is. `MacTakeoverProbe` reads the real Mac; tests and
/// `occtl takeover plan` use `StaticTakeoverProbe`.
public protocol TakeoverEnvironmentProbe: Sendable {
    /// `point` in Quartz global points.
    func target(atQuartz point: CGPoint) async -> DriveTargetInfo?
    func focusedTarget() async -> DriveTargetInfo?
    /// macOS turns secure keyboard entry on while a password field has focus (and some terminals turn it on by
    /// choice); synthesized typing would go nowhere useful and must not be attempted.
    func isSecureInputEnabled() async -> Bool
    /// The pointer, in Quartz global points.
    func cursorLocation() async -> CGPoint
}

/// A probe with fixed answers: elements and windows given up front (by Quartz rectangle), a focused target, a
/// secure-input flag and a cursor. Answers nil wherever nothing was given, as the real probe does without
/// permissions.
public struct StaticTakeoverProbe: TakeoverEnvironmentProbe {
    public struct Region: Sendable, Hashable {
        /// Quartz global points.
        public var frame: CGRect
        public var info: DriveTargetInfo
        public init(frame: CGRect, info: DriveTargetInfo) {
            self.frame = frame
            self.info = info
        }
    }

    /// Front to back: the first region containing a point answers for it.
    public var regions: [Region]
    public var focused: DriveTargetInfo?
    public var secureInput: Bool
    public var cursor: CGPoint

    public init(regions: [Region] = [], focused: DriveTargetInfo? = nil, secureInput: Bool = false, cursor: CGPoint = .zero) {
        self.regions = regions
        self.focused = focused
        self.secureInput = secureInput
        self.cursor = cursor
    }

    /// Regions for an observation's elements, so password fields in the element list are refused like on a live Mac.
    public static func regions(for observation: DriveObservation, ownerName: String? = nil) -> [Region] {
        observation.elements.map { element in
            Region(frame: observation.layout.quartzRect(fromAppKit: element.frame),
                   info: DriveTargetInfo(ownerBundleID: observation.frontApp?.bundleIdentifier,
                                         ownerName: ownerName ?? observation.frontApp?.name, role: element.role,
                                         subrole: element.subrole, label: element.label))
        }
    }

    public func target(atQuartz point: CGPoint) async -> DriveTargetInfo? {
        regions.first { $0.frame.contains(point) }?.info
    }

    public func focusedTarget() async -> DriveTargetInfo? { focused }
    public func isSecureInputEnabled() async -> Bool { secureInput }
    public func cursorLocation() async -> CGPoint { cursor }
}

/// Why an action was refused. The description is written for the model, which reads it as the action's result.
public enum DriveRefusal: Sendable, Hashable, CustomStringConvertible {
    case passwordField
    case secureInput
    /// A system security, permission or settings window.
    case systemWindow(String)
    /// One of OpenClicky's own windows (its consent card, overlay or settings).
    case ownWindow
    case forbiddenShortcut(String)
    case textTooLong(count: Int, limit: Int)
    case controlCharacters
    case offScreen(String)
    case overLimit(String)

    public var code: String {
        switch self {
        case .passwordField: "password_field"
        case .secureInput: "secure_input"
        case .systemWindow: "system_window"
        case .ownWindow: "own_window"
        case .forbiddenShortcut: "forbidden_shortcut"
        case .textTooLong: "text_too_long"
        case .controlCharacters: "control_characters"
        case .offScreen: "off_screen"
        case .overLimit: "over_limit"
        }
    }

    public var description: String {
        switch self {
        case .passwordField:
            "Refused: that is a password field. OpenClicky never clicks or types into password fields; ask the user to do this part."
        case .secureInput:
            "Refused: secure keyboard entry is on (a password field has focus), so nothing was typed. Ask the user to do this part."
        case .systemWindow(let name):
            "Refused: \(name) is a system security, permission or settings window. The user has to handle it themselves."
        case .ownWindow:
            "Refused: that is OpenClicky's own window. Work in the user's apps only."
        case .forbiddenShortcut(let combo):
            "Refused: \(combo) can lock, log out, force quit or empty the Trash. It is never sent during a take-over."
        case .textTooLong(let count, let limit):
            "Refused: \(count) characters is more than the \(limit) a single type action may enter. Split it up."
        case .controlCharacters:
            "Refused: the text has control characters. Use the key action for special keys."
        case .offScreen(let detail):
            "Refused: \(detail)"
        case .overLimit(let detail):
            "Refused: \(detail)"
        }
    }
}

/// The rules every input action passes before the actuator sees it.
public struct TakeoverSafetyPolicy: Sendable {
    /// Apps whose windows are never clicked, scrolled or typed into: authentication and permission prompts,
    /// System Settings, the keychain and password managers built into macOS, the login window.
    public var blockedBundleIDs: Set<String>
    /// The same, by process name, for windows whose owner has no bundle ID.
    public var blockedProcessNames: Set<String>
    /// OpenClicky's own process: its card, overlay and settings are off limits to the model.
    public var ownProcessID: Int32?
    public var ownBundleID: String?
    public var maximumTypeLength: Int
    public var maximumHoldSeconds: Double
    public var maximumKeyRepeat: Int
    public var maximumScrollAmount: Int
    /// Combinations that lock the screen, log out, force quit or empty the Trash.
    public var forbiddenShortcuts: [KeyCombo]

    public init(blockedBundleIDs: Set<String> = TakeoverSafetyPolicy.systemBundleIDs,
                blockedProcessNames: Set<String> = TakeoverSafetyPolicy.systemProcessNames,
                ownProcessID: Int32? = nil, ownBundleID: String? = nil, maximumTypeLength: Int = 2000,
                maximumHoldSeconds: Double = 5, maximumKeyRepeat: Int = 50, maximumScrollAmount: Int = 30,
                forbiddenShortcuts: [KeyCombo] = TakeoverSafetyPolicy.dangerousShortcuts) {
        self.blockedBundleIDs = blockedBundleIDs
        self.blockedProcessNames = blockedProcessNames
        self.ownProcessID = ownProcessID
        self.ownBundleID = ownBundleID
        self.maximumTypeLength = maximumTypeLength
        self.maximumHoldSeconds = maximumHoldSeconds
        self.maximumKeyRepeat = maximumKeyRepeat
        self.maximumScrollAmount = maximumScrollAmount
        self.forbiddenShortcuts = forbiddenShortcuts
    }

    public static let systemBundleIDs: Set<String> = [
        "com.apple.SecurityAgent",                     // admin password and authorization dialogs
        "com.apple.LocalAuthentication.UIAgent",       // Touch ID and password sheets
        "com.apple.coreautha",
        "com.apple.coreservices.uiagent",              // "downloaded from the Internet" and other Gatekeeper prompts
        "com.apple.UserNotificationCenter",            // system alerts, including older permission prompts
        "com.apple.accessibility.universalAccessAuthWarn", // "would like to control this computer" prompts
        "com.apple.tccd",
        "com.apple.CoreLocationAgent",
        "com.apple.systempreferences",                 // System Settings (and System Preferences)
        "com.apple.Settings",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
    ]

    public static let systemProcessNames: Set<String> = [
        "SecurityAgent", "coreautha", "LocalAuthenticationRemoteService", "CoreServicesUIAgent", "UserNotificationCenter",
        "universalAccessAuthWarn", "tccd", "CoreLocationAgent", "System Settings", "System Preferences", "Keychain Access",
        "Passwords", "loginwindow", "ScreenSaverEngine",
    ]

    public static let dangerousShortcuts: [KeyCombo] = [
        KeyCombo(modifiers: [.command, .option], key: DriveKey(name: "Escape", keyCode: CGKeyCode(kVK_Escape))),       // Force Quit
        KeyCombo(modifiers: [.control, .command], key: DriveKey(name: "q", keyCode: CGKeyCode(kVK_ANSI_Q))),            // lock screen
        KeyCombo(modifiers: [.shift, .command], key: DriveKey(name: "q", keyCode: CGKeyCode(kVK_ANSI_Q))),              // log out
        KeyCombo(modifiers: [.option, .shift, .command], key: DriveKey(name: "q", keyCode: CGKeyCode(kVK_ANSI_Q))),     // log out now
        KeyCombo(modifiers: [.shift, .command], key: DriveKey(name: "BackSpace", keyCode: CGKeyCode(kVK_Delete))),      // empty Trash
        KeyCombo(modifiers: [.option, .shift, .command], key: DriveKey(name: "BackSpace", keyCode: CGKeyCode(kVK_Delete))),
        KeyCombo(modifiers: [.shift, .command], key: DriveKey(name: "Delete", keyCode: CGKeyCode(kVK_ForwardDelete))),
        KeyCombo(modifiers: [.option, .shift, .command], key: DriveKey(name: "Delete", keyCode: CGKeyCode(kVK_ForwardDelete))),
    ]

    public static let standard = TakeoverSafetyPolicy()

    /// The standard rules plus OpenClicky's own process.
    public static func standard(ownProcessID: Int32?, ownBundleID: String?) -> TakeoverSafetyPolicy {
        TakeoverSafetyPolicy(ownProcessID: ownProcessID, ownBundleID: ownBundleID)
    }

    /// A combination is forbidden when it presses a forbidden shortcut's key with at least its modifiers: extra
    /// modifiers never make it safe (shift+option+cmd+Escape, held, force-quits the front app at once).
    public func isForbidden(_ combo: KeyCombo) -> Bool {
        forbiddenShortcuts.contains { $0.key.keyCode == combo.key.keyCode && combo.modifiers.isSuperset(of: $0.modifiers) }
    }

    /// The refusal for a window or element owner, if it is off limits.
    public func refusal(forOwner info: DriveTargetInfo) -> DriveRefusal? {
        if let ownProcessID, info.ownerPID == ownProcessID { return .ownWindow }
        if let ownBundleID, info.ownerBundleID == ownBundleID { return .ownWindow }
        if let bundle = info.ownerBundleID, blockedBundleIDs.contains(bundle) {
            return .systemWindow(info.ownerName ?? bundle)
        }
        if let name = info.ownerName, blockedProcessNames.contains(name) { return .systemWindow(name) }
        return nil
    }
}

/// Checks each placed action against the policy and the live state of the Mac. A nil answer means it may run.
public struct TakeoverSafetyGuard: Sendable {
    public var policy: TakeoverSafetyPolicy
    public var probe: any TakeoverEnvironmentProbe

    public init(policy: TakeoverSafetyPolicy = .standard, probe: any TakeoverEnvironmentProbe) {
        self.policy = policy
        self.probe = probe
    }

    public func check(_ action: ResolvedDriveAction) async -> DriveRefusal? {
        switch action {
        case .move:
            // Hovering never changes anything; where it leads is checked when something is clicked.
            return nil
        case .click(let point, _, _, _), .mouseDown(let point):
            return await checkPointer(at: point, refusesPasswordFields: true)
        case .mouseUp(let point):
            return await checkPointer(at: point, refusesPasswordFields: false)
        case .drag(let from, let to, _):
            if let refusal = await checkPointer(at: from, refusesPasswordFields: true) { return refusal }
            return await checkPointer(at: to, refusesPasswordFields: false)
        case .scroll(let point, _, let amount, _):
            if amount > policy.maximumScrollAmount {
                return .overLimit("scroll at most \(policy.maximumScrollAmount) clicks at a time.")
            }
            return await checkPointer(at: point, refusesPasswordFields: false)
        case .type(let text):
            if text.count > policy.maximumTypeLength { return .textTooLong(count: text.count, limit: policy.maximumTypeLength) }
            if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }) {
                return .controlCharacters
            }
            return await checkKeyboard()
        case .key(let combo, let count):
            if policy.isForbidden(combo) { return .forbiddenShortcut(combo.summary) }
            if count > policy.maximumKeyRepeat { return .overLimit("repeat a key at most \(policy.maximumKeyRepeat) times.") }
            return await checkKeyboard()
        case .holdKey(let combo, let seconds):
            if policy.isForbidden(combo) { return .forbiddenShortcut(combo.summary) }
            if seconds > policy.maximumHoldSeconds {
                return .overLimit("hold a key for at most \(DriveAction.format(policy.maximumHoldSeconds)) seconds.")
            }
            return await checkKeyboard()
        }
    }

    private func checkPointer(at point: CGPoint, refusesPasswordFields: Bool) async -> DriveRefusal? {
        guard let info = await probe.target(atQuartz: point) else { return nil }
        if let refusal = policy.refusal(forOwner: info) { return refusal }
        if refusesPasswordFields, info.isSecureField { return .passwordField }
        return nil
    }

    private func checkKeyboard() async -> DriveRefusal? {
        if await probe.isSecureInputEnabled() { return .secureInput }
        guard let focused = await probe.focusedTarget() else { return nil }
        if let refusal = policy.refusal(forOwner: focused) { return refusal }
        if focused.isSecureField { return .passwordField }
        return nil
    }
}
