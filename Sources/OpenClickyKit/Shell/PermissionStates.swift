import Foundation

// How OpenClicky turns what macOS reports about a permission into what Settings and onboarding show. macOS can't say
// "denied" for Screen Recording or Accessibility (both preflights only answer yes or no), and a Screen Recording grant
// made in System Settings isn't seen by the running process until it restarts. So the app remembers when it asked
// for each permission, and checks Screen Recording a second, live way once it has asked.

/// The permissions Settings → Permissions and onboarding show.
public enum PermissionKind: String, Sendable, CaseIterable, Codable, Hashable, Identifiable {
    case microphone, screenRecording, accessibility, speechRecognition, inputMonitoring
    public var id: String { rawValue }
}

/// What the user sees for one permission.
public enum PermissionState: String, Sendable, Equatable, Codable {
    case granted
    /// Asked before and still not allowed (or macOS says so outright).
    case denied
    /// Never asked: the first request shows the system prompt.
    case notDetermined
    /// Allowed in System Settings, but this running copy can't use it until it quits and opens again.
    case restartRequired
}

/// What a permission probe reads from macOS.
public enum PermissionReading: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// The API only says "not granted" (Screen Recording's and Accessibility's preflights), so whether the user was
    /// ever asked comes from the request log.
    case notGranted
}

public enum PermissionStateMapping {
    /// - Parameters:
    ///   - reading: what the process's own check says.
    ///   - askedBefore: OpenClicky asked for this permission before (any launch).
    ///   - grantedLive: a second check that sees grants made after launch (Screen Recording only); nil when not run.
    public static func state(_ reading: PermissionReading, askedBefore: Bool, grantedLive: Bool? = nil) -> PermissionState {
        switch reading {
        case .granted: return .granted
        case .denied: return .denied
        case .notDetermined:
            return grantedLive == true ? .restartRequired : .notDetermined
        case .notGranted:
            if grantedLive == true { return .restartRequired }
            return askedBefore ? .denied : .notDetermined
        }
    }
}

/// When OpenClicky asked for each permission, kept in app-preferences.json (`permissionRequests`).
public struct PermissionRequestLog: Sendable, Equatable {
    public var requestedAt: [PermissionKind: Date]

    public init(requestedAt: [PermissionKind: Date] = [:]) { self.requestedAt = requestedAt }

    public func askedBefore(_ kind: PermissionKind) -> Bool { requestedAt[kind] != nil }

    /// Reads the log from app-preferences.json.
    public static func load(from url: URL) -> PermissionRequestLog {
        let raw = AppPreferences.load(from: url).permissionRequests
        var log = PermissionRequestLog()
        for (key, date) in raw { if let kind = PermissionKind(rawValue: key) { log.requestedAt[kind] = date } }
        return log
    }

    /// Records a request in app-preferences.json, re-reading the file first so other preferences written since stay.
    @discardableResult
    public static func record(_ kind: PermissionKind, at date: Date = Date(), in url: URL) -> PermissionRequestLog {
        var preferences = AppPreferences.load(from: url)
        preferences.permissionRequests[kind.rawValue] = date
        try? preferences.save(to: url)
        return load(from: url)
    }
}

/// The command that opens the app again once this process has exited: a shell waits for the pid to go, then runs
/// `open` on the bundle. The pid and path go in as arguments, never into the script text.
public struct RelaunchCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    public static func make(pid: Int32, bundlePath: String) -> RelaunchCommand? {
        guard pid > 0, bundlePath.hasPrefix("/"), bundlePath.hasSuffix(".app") else { return nil }
        let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\""
        return RelaunchCommand(executable: "/bin/sh", arguments: ["-c", script, "openclicky-relaunch", String(pid), bundlePath])
    }
}
