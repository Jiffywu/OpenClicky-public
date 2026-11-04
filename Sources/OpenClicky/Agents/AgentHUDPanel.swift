import AppKit
import Observation
import SwiftUI

/// A floating, non-activating panel at the top right of the main screen that hosts the agent HUD. It never takes
/// focus from the app the user is working in, and it stays put across Spaces.
@MainActor
@Observable
final class AgentHUDPanel: NSObject, NSWindowDelegate {
    @ObservationIgnored private var panel: NSPanel?
    private let model: AgentHUDModel
    private(set) var isVisible = false
    @ObservationIgnored var onVisibilityChange: (() -> Void)?
    /// Where `openclicky:` links in job reports and cards go (the app's URL router); set before the panel first shows.
    var openURL: OpenURLAction?

    init(model: AgentHUDModel) { self.model = model }

    /// The panel's frame while it is on screen.
    var visibleFrame: NSRect? { isVisible ? panel?.frame : nil }

    func toggle() { isVisible ? hide() : show() }

    func setVisible(_ visible: Bool) { visible ? show() : hide() }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        updateVisibility(panel.isVisible)
    }

    func hide() {
        panel?.orderOut(nil)
        updateVisibility(false)
    }

    func windowWillClose(_ notification: Notification) { updateVisibility(false) }

    private func updateVisibility(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        onVisibilityChange?()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        let host = NSHostingView(rootView: AgentHUDView(model: model, onClose: { [weak self] in self?.hide() }).environment(\.openURL, openURL ?? OpenURLAction { _ in .systemAction }))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 12,
                              width: size.width, height: size.height), display: true)
    }
}
