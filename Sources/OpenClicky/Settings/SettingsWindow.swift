import AppKit
import SwiftUI

/// The Settings window, owned by the app rather than SwiftUI's `Settings` scene: since macOS 14 the scene opens only
/// from a SwiftUI view's `openSettings` action (the old `showSettingsWindow:` action does nothing), and links, Home,
/// launch and the menu all need to open it on a given page. One instance; closing hides it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(services: HomeServices) {
        let root = SettingsView()
            .environment(services)
            .environment(services.model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620), styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "OpenClicky Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 860, height: 620))
        window.setFrameAutosaveName("OpenClicky.Settings")
        window.delegate = self
        window.center()
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
