import Foundation

// The parts of macOS the app tools touch, behind protocols so tests never open a browser, write the clipboard,
// run AppleScript or ask for a permission. Production implementations are in MacAppToolSystem.swift; scripted
// fakes are in AppToolFakes.swift. AppleScript goes through the Kit's shared `AppleScriptRunning` seam and
// `AppleScriptError` (Context/BrowserPageScripting.swift).

/// Opening things and asking about installed apps.
public protocol AppToolWorkspace: Sendable {
    /// Opens an http(s) URL in the user's default browser. False when nothing could open it.
    func openInDefaultBrowser(_ url: URL) async -> Bool
    /// Opens a URL with whatever app handles its scheme (`spotify:` URIs).
    func open(_ url: URL) async -> Bool
    /// Shows a file or folder selected in a Finder window.
    func revealInFinder(_ fileURL: URL) async -> Bool
    func isInstalled(bundleID: String) async -> Bool
    func isRunning(bundleID: String) async -> Bool
}

public protocol AppToolPasteboard: Sendable {
    /// Replaces the clipboard with plain text. False when the pasteboard refused it.
    func copy(_ text: String) async -> Bool
}

extension AppleScriptError {
    /// errAEEventNotPermitted: the user has not allowed (or has refused) Automation for the target app.
    public static let notPermittedCode = -1743
    /// errAEEventWouldRequireUserConsent: the consent prompt could not be shown.
    public static let wouldRequireConsentCode = -1744

    /// The user has to allow OpenClicky to control the app in System Settings > Privacy & Security > Automation.
    public var isNotPermitted: Bool { code == Self.notPermittedCode || code == Self.wouldRequireConsentCode }

    /// The app tools' runner stopped a script at its time limit.
    public static let scriptTimedOut = AppleScriptError(code: nil, message: "The script took too long and was stopped.")
}

/// Bundle identifiers the tools look for.
public enum AppBundleID {
    public static let spotify = "com.spotify.client"
    public static let music = "com.apple.Music"
}
