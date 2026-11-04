import AppKit
import OpenClickyKit
import SwiftUI

/// The Home window, opened from the menu bar. One instance; closing hides it.
@MainActor
final class HomeWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let services: HomeServices

    init(services: HomeServices) {
        self.services = services
        let root = HomeView()
            .environment(services)
            .environment(services.model)
            .environment(\.openURL, services.router.openURLAction)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "OpenClicky"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 1040, height: 680))
        window.setFrameAutosaveName("OpenClicky.Home")
        window.delegate = self
        window.center()
    }

    func show() {
        services.chat.reload()
        services.drawings.reload()
        services.skills.reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() { window.orderOut(nil) }
}

/// The first-run window. Closing it mid-way saves where the user stopped; the menu offers to resume.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    let flow: OnboardingModel

    init(services: HomeServices) {
        flow = OnboardingModel(services: services)
        let root = OnboardingView(flow: flow)
            .environment(services)
            .environment(services.model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Welcome to OpenClicky"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.delegate = self
        window.center()
        flow.onClose = { [weak self] in self?.window.orderOut(nil) }
    }

    func show(restart: Bool) {
        if restart { flow.send(.restart) }
        flow.begin()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        flow.closedByUser()
    }
}
