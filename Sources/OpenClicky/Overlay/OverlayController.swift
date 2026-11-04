import AppKit
import SwiftUI

/// A transparent, click-through panel over one display. OpenClicky draws its pointer, captions and drawings
/// here. Panels float above normal windows, appear on every Space and over full-screen apps, and never take focus.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Keeps one overlay panel per connected display, rebuilt when displays change.
@MainActor
final class OverlayController {
    private(set) var panels: [CGDirectDisplayID: OverlayPanel] = [:]
    private var screenObserver: NSObjectProtocol?
    /// Stepped aside for system UI (`setHidden`).
    private(set) var isHidden = false
    private let makeContent: (NSScreen) -> AnyView

    init(makeContent: @escaping (NSScreen) -> AnyView) {
        self.makeContent = makeContent
    }

    func start() {
        rebuild()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        for panel in panels.values {
            if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        }
    }

    /// Window numbers of every overlay panel, so screen capture can leave them out.
    var windowNumbers: [Int] { panels.values.map(\.windowNumber) }

    private func rebuild() {
        var next: [CGDirectDisplayID: OverlayPanel] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let panel = panels[id] ?? OverlayPanel(screen: screen)
            panel.setFrame(screen.frame, display: true)
            if panel.contentView == nil || panels[id] == nil {
                panel.contentView = NSHostingView(rootView: makeContent(screen))
            }
            if !isHidden { panel.orderFrontRegardless() }
            next[id] = panel
        }
        for (id, panel) in panels where next[id] == nil { panel.orderOut(nil) }
        panels = next
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
