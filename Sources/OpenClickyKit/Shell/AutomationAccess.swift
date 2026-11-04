import CoreServices
import Foundation

// Automation (Apple Events) checks shared by the page reader and Settings → Permissions, and the "What agents can
// reach" summary: Automation per scripted browser and the guarded folders read before.

/// Automation (Apple Events) permission for one target app, checked without prompting unless asked to.
public enum AutomationPermission: Sendable, Hashable {
    case granted
    case denied
    /// The user hasn't been asked yet; sending an event would show the system prompt.
    case notDetermined
    case targetNotRunning
    case unknown(Int32)

    public static func status(forBundleIdentifier bundleIdentifier: String, askIfNeeded: Bool) -> AutomationPermission {
        AutomationProbe.system.status(bundleIdentifier, askIfNeeded)
    }

    /// A short word for Settings.
    public var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        case .targetNotRunning: "Open it to check"
        case .unknown(let code): "Unknown (\(code))"
        }
    }

    /// The System Settings pane where Automation is switched per app.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}

/// The Automation check, injectable for tests. `system` asks macOS (`AEDeterminePermissionToAutomateTarget`).
public struct AutomationProbe: Sendable {
    public var status: @Sendable (_ bundleIdentifier: String, _ askIfNeeded: Bool) -> AutomationPermission

    public init(status: @escaping @Sendable (String, Bool) -> AutomationPermission) { self.status = status }

    public static let system = AutomationProbe { bundleIdentifier, askIfNeeded in
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let address = target.aeDesc else { return .unknown(-1) }
        let wildcard = AEEventClass(0x2A2A_2A2A) // '****'
        let status = AEDeterminePermissionToAutomateTarget(address, wildcard, AEEventID(wildcard), askIfNeeded)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .targetNotRunning
        default: return .unknown(status)
        }
    }
}

extension ScriptableBrowser {
    public var displayName: String {
        switch self {
        case .safari: "Safari"
        case .safariTechnologyPreview: "Safari Technology Preview"
        case .chrome: "Google Chrome"
        case .chromeBeta: "Chrome Beta"
        case .chromeCanary: "Chrome Canary"
        case .chromium: "Chromium"
        case .arc: "Arc"
        case .edge: "Microsoft Edge"
        case .edgeBeta: "Edge Beta"
        case .brave: "Brave"
        case .braveBeta: "Brave Beta"
        case .vivaldi: "Vivaldi"
        }
    }
}

/// What OpenClicky and its agents can reach right now: Automation for each installed browser it scripts, and which
/// protected folders it has read from before (a first read from the others shows the system prompt).
public struct AgentReach: Sendable, Equatable {
    public struct BrowserRow: Sendable, Equatable, Identifiable {
        public var browser: ScriptableBrowser
        public var permission: AutomationPermission
        public var id: String { browser.rawValue }

        public init(browser: ScriptableBrowser, permission: AutomationPermission) {
            self.browser = browser
            self.permission = permission
        }
    }

    public struct FolderRow: Sendable, Equatable, Identifiable {
        public var folder: GuardedFolder
        public var readBefore: Bool
        public var id: String { folder.rawValue }

        public init(folder: GuardedFolder, readBefore: Bool) {
            self.folder = folder
            self.readBefore = readBefore
        }
    }

    public var browsers: [BrowserRow]
    public var folders: [FolderRow]

    public init(browsers: [BrowserRow], folders: [FolderRow]) {
        self.browsers = browsers
        self.folders = folders
    }

    /// Checks without prompting. `isInstalled` filters the browsers to the ones on this Mac.
    public static func check(probe: AutomationProbe = .system, ledger: GuardedFolderLedger,
                             isInstalled: (ScriptableBrowser) -> Bool) -> AgentReach {
        let browsers = ScriptableBrowser.allCases.filter(isInstalled).map {
            BrowserRow(browser: $0, permission: probe.status($0.bundleIdentifier, false))
        }
        let folders = GuardedFolder.allCases.map { FolderRow(folder: $0, readBefore: ledger.hasRead(from: $0)) }
        return AgentReach(browsers: browsers, folders: folders)
    }
}
