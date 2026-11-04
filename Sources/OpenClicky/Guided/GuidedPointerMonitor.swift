import AppKit
import OpenClickyKit

/// Watches the user's clicks, pointer, drags, scrolls, keys, front app and Space anywhere on the Mac while a walkthrough
/// is active (a step waiting, or a follow-up being prepared), and hands them to the walkthrough. It only observes:
/// global monitors can't consume or change events. Global key monitoring needs Accessibility permission; mouse events
/// arrive without it on current macOS, but this is unverified on this build (see docs/guided.md).
@MainActor
final class GuidedPointerMonitor {
    private let guided: GuidedWalkthroughController
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    init(guided: GuidedWalkthroughController) {
        self.guided = guided
    }

    /// The workspace observers count too: the global event monitor may be refused while they are installed.
    var isRunning: Bool { !monitors.isEmpty || !observers.isEmpty }

    /// Watch only while a walkthrough is active: the pointer stream is not needed otherwise.
    func setActive(_ active: Bool) {
        if active, !isRunning { start() } else if !active, isRunning { stop() }
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved,
                                           .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.guided.handle(.appChanged(bundle)) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.guided.handle(.spaceChanged) }
        })
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    private func handle(_ event: NSEvent) {
        // NSEvent.mouseLocation is AppKit global (bottom-left origin), the walkthrough's space.
        let point = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: guided.handle(.mouseDown(point))
        case .mouseMoved: guided.handle(.mouseMoved(point))
        // A drag is work on a manual step (a slider, a file), not just the pointer passing by.
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: guided.handle(.mouseDragged(point))
        case .scrollWheel: guided.handle(.scroll)
        case .keyDown: guided.handle(event.keyCode == 53 ? .escape : .keyDown)
        default: break
        }
    }
}
