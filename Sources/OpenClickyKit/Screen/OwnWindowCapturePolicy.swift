import AppKit
import Foundation

/// A window OpenClicky owns, as the capture policy sees it. `NSWindow` conforms; tests use stand-ins.
@MainActor
public protocol CapturePolicyWindow: AnyObject {
    var windowNumber: Int { get }
    var sharingType: NSWindow.SharingType { get set }
}

extension NSWindow: CapturePolicyWindow {}

/// Keeps track of OpenClicky's own windows and decides two things for each:
/// - whether OpenClicky's own screenshots leave it out (the pointer, captions and overlay chrome must never reach the
///   model, or it will talk about itself), and
/// - whether other apps' recordings and screen sharing may see it (the user's "show in screen recordings" choice).
///
/// Since macOS 15, `sharingType = .none` no longer hides a window from ScreenCaptureKit, so own captures exclude
/// windows by number (`exclusion`) regardless of the sharing setting.
@MainActor
public final class OwnWindowCapturePolicy {
    public enum Role: Sendable, Hashable {
        /// The buddy pointer, captions, rings: left out of OpenClicky's own screenshots.
        case hiddenFromOwnCaptures
        /// Overlay chrome the user may want in their recordings but the model never needs (status pills, the notch).
        case ambientChrome
        /// Regular windows (settings, chat): always visible to recordings, and captured like any app's window.
        case standalone
    }

    private struct Entry {
        weak var window: (any CapturePolicyWindow)?
        var role: Role
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Whether other apps' recordings and screen shares may show OpenClicky's overlays. When off, overlays ask macOS
    /// to keep them out of other apps' captures (where macOS still honors that).
    public var showInScreenRecordings: Bool {
        didSet { if showInScreenRecordings != oldValue { applyAll() } }
    }

    public init(showInScreenRecordings: Bool = true) {
        self.showInScreenRecordings = showInScreenRecordings
    }

    public func register(_ window: any CapturePolicyWindow, role: Role) {
        entries[ObjectIdentifier(window)] = Entry(window: window, role: role)
        apply(to: window, role: role)
    }

    public func unregister(_ window: any CapturePolicyWindow) {
        entries[ObjectIdentifier(window)] = nil
    }

    /// The sharing type a window with `role` should have under the current setting.
    public func sharingType(for role: Role) -> NSWindow.SharingType {
        switch role {
        case .standalone: .readOnly
        case .hiddenFromOwnCaptures, .ambientChrome: showInScreenRecordings ? .readOnly : .none
        }
    }

    /// Window numbers to leave out of OpenClicky's own screenshots.
    public var excludedWindowNumbers: Set<Int> {
        prune()
        return Set(entries.values.compactMap { entry in
            guard entry.role != .standalone, let number = entry.window?.windowNumber, number > 0 else { return nil }
            return number
        })
    }

    /// The exclusion to pass to `ScreenCaptureOptions`. `extra` adds windows registered elsewhere (e.g. overlay panels).
    public func exclusion(adding extra: [Int] = []) -> CaptureExclusion {
        CaptureExclusion(windowNumbers: excludedWindowNumbers.union(extra.filter { $0 > 0 }))
    }

    public var registeredCount: Int {
        prune()
        return entries.count
    }

    private func applyAll() {
        prune()
        for entry in entries.values {
            if let window = entry.window { apply(to: window, role: entry.role) }
        }
    }

    private func apply(to window: any CapturePolicyWindow, role: Role) {
        let wanted = sharingType(for: role)
        if window.sharingType != wanted { window.sharingType = wanted }
    }

    private func prune() {
        entries = entries.filter { $0.value.window != nil }
    }
}
