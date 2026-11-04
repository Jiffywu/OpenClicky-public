import Foundation
import ServiceManagement

// Settings → General's behaviour switches and what the app does with them at launch: the login item (registered once,
// on the first launch from Applications), Show in Dock, Show in screen recordings, and where the app is installed.

/// App-wide behaviour preferences, `~/Library/Application Support/OpenClicky/app-preferences.json`. Missing keys take
/// their defaults, so older files keep working.
public struct AppPreferences: Codable, Sendable, Equatable {
    /// A Dock icon and an app menu (regular activation policy) instead of a menu-bar-only accessory.
    public var showInDock: Bool
    /// Whether other apps' recordings and screen shares may show OpenClicky's overlays (the pointer, captions, panels).
    public var showInScreenRecordings: Bool
    /// The first launch from a stable location registered (or tried to register) the login item. Later launches
    /// leave the login item to the user.
    public var loginItemFirstLaunchHandled: Bool
    /// The install-location warning the user dismissed (by bundle path), so it isn't shown again for that copy.
    public var dismissedInstallWarningPath: String?
    /// When OpenClicky last asked for each permission (`PermissionKind` raw value), so a permission still off after
    /// a request shows as denied instead of "not asked yet" (see `PermissionRequestLog`).
    public var permissionRequests: [String: Date]

    public init(showInDock: Bool = false, showInScreenRecordings: Bool = true, loginItemFirstLaunchHandled: Bool = false,
                dismissedInstallWarningPath: String? = nil, permissionRequests: [String: Date] = [:]) {
        self.showInDock = showInDock
        self.showInScreenRecordings = showInScreenRecordings
        self.loginItemFirstLaunchHandled = loginItemFirstLaunchHandled
        self.dismissedInstallWarningPath = dismissedInstallWarningPath
        self.permissionRequests = permissionRequests
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppPreferences()
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? d.showInDock
        showInScreenRecordings = try c.decodeIfPresent(Bool.self, forKey: .showInScreenRecordings) ?? d.showInScreenRecordings
        loginItemFirstLaunchHandled = try c.decodeIfPresent(Bool.self, forKey: .loginItemFirstLaunchHandled) ?? d.loginItemFirstLaunchHandled
        dismissedInstallWarningPath = try c.decodeIfPresent(String.self, forKey: .dismissedInstallWarningPath)
        permissionRequests = (try? c.decodeIfPresent([String: Date].self, forKey: .permissionRequests)) ?? [:]
    }

    public static var defaultURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("app-preferences.json")
    }

    /// The saved preferences, or defaults when there is no file or it can't be read.
    public static func load(from url: URL = defaultURL) -> AppPreferences {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AppPreferences.self, from: $0) } ?? AppPreferences()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Install location

/// Where the running app lives, and what that means. macOS runs a quarantined app opened from Downloads or a disk image
/// from a random read-only copy (App Translocation); a login item or browser manifest pointing there breaks on the
/// next launch, and permissions granted to it don't carry over.
public struct InstallLocation: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// /Applications.
        case applications
        /// ~/Applications.
        case userApplications
        /// A randomized read-only copy macOS made because the app is still quarantined.
        case translocated
        /// Running straight from a mounted disk image.
        case diskImage
        /// ~/Downloads or ~/Desktop.
        case downloads
        /// Not inside an .app bundle (`swift run`, a build folder).
        case development
        /// Some other folder (a build's `dist/`, ~/Developer).
        case elsewhere
    }

    public var kind: Kind
    public var bundlePath: String

    public init(kind: Kind, bundlePath: String) {
        self.kind = kind
        self.bundlePath = bundlePath
    }

    /// Classifies a bundle URL (`Bundle.main.bundleURL`).
    public static func classify(bundleURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> InstallLocation {
        let path = bundleURL.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        let kind: Kind
        if bundleURL.pathExtension != "app" {
            kind = .development
        } else if path.contains("/AppTranslocation/") {
            kind = .translocated
        } else if path.hasPrefix("/Volumes/") {
            kind = .diskImage
        } else if path.hasPrefix("/Applications/") {
            kind = .applications
        } else if path.hasPrefix(homePath + "/Applications/") {
            kind = .userApplications
        } else if path.hasPrefix(homePath + "/Downloads/") || path.hasPrefix(homePath + "/Desktop/") {
            kind = .downloads
        } else {
            kind = .elsewhere
        }
        return InstallLocation(kind: kind, bundlePath: path)
    }

    /// In an Applications folder: the login item is registered on first launch and the location is never questioned.
    public var isInstalled: Bool { kind == .applications || kind == .userApplications }

    /// A login item may point here (it would still be here after a restart).
    public var allowsLoginItem: Bool { isInstalled || kind == .elsewhere }

    /// What to tell the user, or nil when the location is fine.
    public var advice: String? {
        switch kind {
        case .applications, .userApplications:
            return nil
        case .translocated:
            return "macOS is running OpenClicky from a temporary read-only copy because it was opened straight from where it was downloaded. Quit, move OpenClicky to Applications, and open it from there; permissions and the login item then stick."
        case .diskImage:
            return "OpenClicky is running from a disk image. Drag it to Applications and open it from there, or it will be gone when the image is ejected."
        case .downloads:
            return "OpenClicky is running from \(URL(fileURLWithPath: bundlePath).deletingLastPathComponent().lastPathComponent). Move it to Applications so updates, permissions and the login item keep working."
        case .development:
            return "This is a development build (not an .app bundle). Launch at login and browser setup are off."
        case .elsewhere:
            return "OpenClicky isn't in Applications (\(URL(fileURLWithPath: bundlePath).deletingLastPathComponent().path)). It works from here, but it won't add itself to your login items until it's in Applications."
        }
    }
}

// MARK: - Login item

/// The app's login item as macOS reports it.
public enum LoginItemStatus: String, Sendable, Equatable {
    case enabled
    /// Registered, but the user has to switch it on in System Settings → General → Login Items.
    case requiresApproval
    case notRegistered
    /// macOS can't find the app to register (not an .app, or an unsigned build).
    case notFound

    public var label: String {
        switch self {
        case .enabled: "On"
        case .requiresApproval: "Waiting for your approval in System Settings → General → Login Items"
        case .notRegistered: "Off"
        case .notFound: "Unavailable for this copy of OpenClicky"
        }
    }
}

/// Registers the app as a login item. `MainAppLoginItem` uses `SMAppService.mainApp`; tests use a fake.
public protocol LoginItemControlling: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// The running app's own login item (`SMAppService.mainApp`).
public struct MainAppLoginItem: LoginItemControlling {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }

    /// Opens System Settings → General → Login Items, where the user approves it.
    public static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// HeyClicky adds itself to the login items on its first launch only. OpenClicky does the same, but only from an
/// Applications folder (a copy in Downloads or a build folder is often not the one the user keeps), and never when
/// `OPENCLICKY_NO_LOGIN_ITEM` is set (development and evidence runs).
public enum LoginItemPolicy {
    public static let environmentOptOut = "OPENCLICKY_NO_LOGIN_ITEM"

    public enum Decision: Sendable, Equatable {
        case register
        case skip(String)
        case alreadyHandled
    }

    public static func firstLaunchDecision(preferences: AppPreferences, location: InstallLocation,
                                           environment: [String: String] = ProcessInfo.processInfo.environment) -> Decision {
        if preferences.loginItemFirstLaunchHandled { return .alreadyHandled }
        if let value = environment[environmentOptOut], !value.isEmpty, value != "0" { return .skip("\(environmentOptOut) is set") }
        guard location.isInstalled else { return .skip("not in an Applications folder (\(location.kind.rawValue))") }
        return .register
    }

    /// Applies the first-launch decision: registers when due and records that the first launch was handled. Returns
    /// the updated preferences and a line for the log.
    public static func applyOnLaunch(preferences: AppPreferences, location: InstallLocation, service: any LoginItemControlling,
                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> (AppPreferences, String) {
        var updated = preferences
        switch firstLaunchDecision(preferences: preferences, location: location, environment: environment) {
        case .alreadyHandled:
            return (updated, "login item: first launch already handled (status \(service.status.rawValue))")
        case .skip(let reason):
            return (updated, "login item: not registered, \(reason)")
        case .register:
            updated.loginItemFirstLaunchHandled = true
            do {
                try service.register()
                return (updated, "login item: registered on first launch (status \(service.status.rawValue))")
            } catch {
                // Not retried on later launches; the switch in Settings → General stays available.
                return (updated, "login item: registering failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Window capture roles

/// What the capture policy needs to know about a window to give it a role.
public struct WindowTraits: Sendable, Hashable {
    public var className: String
    public var isTitled: Bool
    public var ignoresMouseEvents: Bool

    public init(className: String, isTitled: Bool, ignoresMouseEvents: Bool) {
        self.className = className
        self.isTitled = isTitled
        self.ignoresMouseEvents = ignoresMouseEvents
    }
}

public enum WindowCaptureRoles {
    /// The role for one of OpenClicky's windows, or nil for system-owned windows the app shouldn't touch (the menu
    /// bar item, menus, tooltips).
    ///
    /// - Click-through windows without a title bar (the overlay with the pointer and drawings, the dictation HUD, the
    ///   take-over shield) are left out of OpenClicky's own screenshots.
    /// - Other untitled panels (the typed-question panel, the jobs HUD, the take-over card) are ambient chrome: also
    ///   left out of its screenshots.
    /// - Titled windows (Settings, Home, onboarding) are standalone: always visible to recordings and screenshots.
    public static func role(for traits: WindowTraits) -> OwnWindowCapturePolicy.Role? {
        let name = traits.className
        if ["StatusBar", "Menu", "ToolTip", "Popover"].contains(where: name.contains) { return nil }
        if traits.isTitled { return .standalone }
        return traits.ignoresMouseEvents ? .hiddenFromOwnCaptures : .ambientChrome
    }
}
