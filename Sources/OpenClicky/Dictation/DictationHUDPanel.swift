import AppKit
import SwiftUI

/// A borderless, click-through panel that floats the dictation HUD over every app without taking focus.
final class DictationHUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows, moves and hides the HUD panel.
@MainActor
final class DictationHUDPanelController {
    private var panel: DictationHUDPanel?
    private var hosting: NSHostingView<DictationHUDView>?

    /// `fieldFrame` is the focused field in Accessibility coordinates (top-left origin of the main display).
    func show(_ content: DictationHUDContent, near fieldFrame: CGRect?) {
        let panel = self.panel ?? DictationHUDPanel()
        self.panel = panel
        if let hosting {
            hosting.rootView = DictationHUDView(content: content)
        } else {
            let view = NSHostingView(rootView: DictationHUDView(content: content))
            panel.contentView = view
            hosting = view
        }
        let size = hosting?.fittingSize ?? NSSize(width: 200, height: 44)
        panel.setFrame(NSRect(origin: Self.origin(for: size, near: fieldFrame), size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    /// Below the field when there's room, above it otherwise; without a field, low and centered on the screen with
    /// the mouse.
    static func origin(for size: NSSize, near fieldFrame: CGRect?) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if let field = fieldFrame, field.width > 0 {
            // Accessibility uses a top-left origin; AppKit a bottom-left one.
            let cocoa = NSRect(x: field.minX, y: primaryHeight - field.maxY, width: field.width, height: field.height)
            let screen = NSScreen.screens.first { $0.frame.intersects(cocoa) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? cocoa
            let x = min(max(cocoa.minX + 4, visible.minX + 8), visible.maxX - size.width - 8)
            var y = cocoa.minY - size.height - 8
            if y < visible.minY + 8 { y = min(cocoa.maxY + 8, visible.maxY - size.height - 8) }
            return NSPoint(x: x, y: y)
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 72)
    }
}
