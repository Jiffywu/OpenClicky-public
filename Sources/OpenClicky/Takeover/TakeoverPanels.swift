import AppKit
import SwiftUI

/// The consent card's panel: floats over every app, can take keyboard focus (Return approves, Escape declines)
/// without activating OpenClicky, and sits centered in the lower part of the display that has the pointer.
final class TakeoverConsentPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .modalPanel
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TakeoverConsentPanelController {
    private var panel: TakeoverConsentPanel?

    var windowNumber: Int? { panel?.isVisible == true ? panel?.windowNumber : nil }

    func show(_ content: TakeoverConsentCardContent, onApprove: @escaping () -> Void, onDecline: @escaping () -> Void) {
        let panel = self.panel ?? TakeoverConsentPanel()
        self.panel = panel
        let view = NSHostingView(rootView: TakeoverConsentCard(content: content, onApprove: onApprove, onDecline: onDecline).padding(24))
        panel.contentView = view
        let size = view.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.28, width: size.width, height: size.height),
                       display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() { panel?.orderOut(nil) }
}

/// One click-through panel per display for the drive overlay, above everything including the menu bar.
final class TakeoverOverlayPanel: NSPanel {
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

/// What every overlay panel shows; the panels read it.
@MainActor
@Observable
final class TakeoverOverlayModel {
    var content = TakeoverOverlayContent()
    /// The drive cursor in AppKit global points.
    var cursorGlobal: CGPoint?
}

private struct TakeoverOverlayRoot: View {
    let model: TakeoverOverlayModel
    let screenFrame: CGRect

    var body: some View {
        var content = model.content
        content.cursor = model.cursorGlobal.flatMap { point in
            screenFrame.insetBy(dx: -1, dy: -1).contains(point)
                ? CGPoint(x: point.x - screenFrame.minX, y: screenFrame.maxY - point.y) : nil
        }
        if content.cursor == nil { content.cursorLabel = nil }
        return TakeoverOverlayView(content: content, size: screenFrame.size)
    }
}

@MainActor
final class TakeoverOverlayController {
    let model = TakeoverOverlayModel()
    private var panels: [TakeoverOverlayPanel] = []

    var windowNumbers: [Int] { panels.map(\.windowNumber) }

    func show(dryRun: Bool) {
        hide()
        model.content = TakeoverOverlayContent(isDryRun: dryRun)
        model.cursorGlobal = nil
        for screen in NSScreen.screens {
            let panel = TakeoverOverlayPanel(screen: screen)
            panel.contentView = NSHostingView(rootView: TakeoverOverlayRoot(model: model, screenFrame: screen.frame))
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}
