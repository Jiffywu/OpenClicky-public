import AppKit
import OpenClickyKit
import SwiftUI

/// One display's notch: a borderless, non-activating panel just above the menu bar, top centre. It is as big as the
/// open notch; only the visible part takes clicks (the manager flips `ignoresMouseEvents` as the pointer moves), so
/// the menu bar and windows under the empty part keep working. It becomes key only for the chat composer.
final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Set before the level: making a panel floating resets its level to `.floating`.
        isFloatingPanel = true
        // Above the menu bar (24) and status items (25), as HeyClicky's notch panel is (26, seen in the live window list).
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // The notch is always black: dark controls keep the composer's placeholder and the switches legible in Light Mode.
        appearance = NSAppearance(named: .darkAqua)
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps windows below the menu bar; the notch belongs in it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Keeps a notch panel on every display and feeds the presenter: the pointer 30 times a second (hover dwell, whether
/// it is over the panel), clicks elsewhere, and twice a second the window list (system UI to step aside for, full-
/// screen apps). Display and Space changes rebuild or re-probe at once.
@MainActor
final class NotchWindowManager {
    private(set) var panels: [UInt32: NotchPanel] = [:]
    private let model: NotchModel
    private let makeContent: (UInt32) -> AnyView
    private var pointerTimer: Timer?
    private var probeTimer: Timer?
    private var globalClicks: Any?
    private var localClicks: Any?
    private var observers: [NSObjectProtocol] = []
    private var yields = NotchYieldCoordinator()
    private var overlaysYielding = false
    private var visible: [UInt32: Bool] = [:]
    /// OpenClicky's own-window capture policy: the panels are ambient chrome (out of its own screenshots; in other
    /// apps' recordings when the user allows it).
    var capturePolicy: OwnWindowCapturePolicy?
    /// The full-screen overlays should step aside too (screenshot UI, a picker, Mission Control).
    var onOverlayYield: ((Bool) -> Void)?
    /// What the probe saw, for the log.
    var onProbe: ((Set<NotchYieldReason>, Set<UInt32>) -> Void)?

    init(model: NotchModel, makeContent: @escaping (UInt32) -> AnyView) {
        self.model = model
        self.makeContent = makeContent
    }

    var windowNumbers: [Int] { panels.values.map(\.windowNumber) }

    func start() {
        rebuild()
        let pointer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pointerTick() } }
        RunLoop.main.add(pointer, forMode: .common)
        pointerTimer = pointer
        let probing = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.probe() } }
        probing.tolerance = 0.1
        RunLoop.main.add(probing, forMode: .common)
        probeTimer = probing
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps (global) and in OpenClicky's other windows (local) fold the open notch.
        globalClicks = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }
        localClicks = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                if !(event.window is NotchPanel) { self?.clickedOutside() }
            }
            return event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        })
        probe()
    }

    func stop() {
        pointerTimer?.invalidate()
        probeTimer?.invalidate()
        pointerTimer = nil
        probeTimer = nil
        if let globalClicks { NSEvent.removeMonitor(globalClicks) }
        if let localClicks { NSEvent.removeMonitor(localClicks) }
        globalClicks = nil
        localClicks = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        for panel in panels.values {
            capturePolicy?.unregister(panel)
            panel.orderOut(nil)
        }
        panels.removeAll()
        if overlaysYielding { onOverlayYield?(false) }
        overlaysYielding = false
    }

    /// Gives the active display's panel the keyboard, for the composer (OpenClicky stays in the background).
    func focusComposer() {
        guard let id = model.presenter.activeDisplay ?? NSScreen.main?.displayID, let panel = panels[id] else { return }
        panel.ignoresMouseEvents = false
        panel.makeKey()
    }

    /// Hands the keyboard back to the app in front after the notch folds.
    func releaseKeyFocus() {
        for panel in panels.values where panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    // MARK: Displays

    private func rebuild() {
        var geometries: [UInt32: NotchGeometry] = [:]
        var next: [UInt32: NotchPanel] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let geometry = NotchGeometry(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                         auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea)
            geometries[id] = geometry
            let panel = panels[id] ?? NotchPanel(frame: geometry.panelFrame)
            panel.setFrame(geometry.panelFrame, display: true)
            if panels[id] == nil {
                let host = NSHostingView(rootView: makeContent(id))
                host.frame = CGRect(origin: .zero, size: geometry.panelFrame.size)
                panel.contentView = host
                capturePolicy?.register(panel, role: .ambientChrome)
            }
            next[id] = panel
        }
        for (id, panel) in panels where next[id] == nil {
            capturePolicy?.unregister(panel)
            panel.orderOut(nil)
        }
        panels = next
        visible = [:]
        model.setGeometries(geometries)
        applyVisibility()
    }

    private func applyVisibility() {
        for (id, panel) in panels {
            let show = !model.currentSurface(on: id).isHidden
            guard visible[id] != show else { continue }
            visible[id] = show
            if show { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
    }

    // MARK: Pointer

    private func pointerTick() {
        let location = NSEvent.mouseLocation
        if let (id, geometry) = model.geometries.first(where: { Self.screen($0.value.screenFrame, contains: location) }) {
            let content = geometry.contentRect(for: model.currentSurface(on: id))
            model.send(.pointer(display: id, inHotZone: Self.contains(geometry.hotZone, location),
                                inPanel: Self.contains(content, location)))
        } else {
            model.send(.tick)
        }
        for (id, panel) in panels {
            guard let geometry = model.geometries[id] else { continue }
            let inside = Self.contains(geometry.contentRect(for: model.currentSurface(on: id)), location)
            if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        }
        applyVisibility()
    }

    private func clickedOutside() {
        guard model.isExpanded else { return }
        // A click that lands on the open panel's own content isn't outside (a global event can still race in).
        let location = NSEvent.mouseLocation
        if let id = model.presenter.activeDisplay, let geometry = model.geometries[id],
           Self.contains(geometry.contentRect(for: model.currentSurface(on: id)), location) { return }
        model.send(.clickOutside)
    }

    /// Top edge inclusive: the pointer can sit on the very top row of a display.
    static func screen(_ frame: CGRect, contains point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }

    static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        guard !rect.isNull else { return false }
        return point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    // MARK: System UI

    private func probe() {
        let layout = DesktopLayout.current()
        let own = ProcessInfo.processInfo.processIdentifier
        let windows = SystemWindowList.snapshot().filter { $0.pid != own }
        let displays = SystemWindowList.displayBounds(layout)
        let detected = SystemUIDetector().reasons(in: windows, displays: displays.map(\.bounds))
        let active = yields.update(detected, now: Date())
        if active != model.presenter.yielding { model.send(.yield(active)) }
        var fullscreen: Set<UInt32> = []
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            let insets = displays.map { model.geometries[$0.id]?.notchHeight ?? 0 }
            let indices = FullscreenDetector.fullscreenDisplays(windows: windows, displays: displays.map(\.bounds), frontPID: front.processIdentifier,
                                                                housingInsets: insets)
            fullscreen = Set(indices.map { displays[$0].id })
        }
        if fullscreen != model.presenter.fullscreenDisplays { model.send(.fullscreen(fullscreen)) }
        let hideOverlays = active.contains(where: \.hidesOverlays)
        if hideOverlays != overlaysYielding {
            overlaysYielding = hideOverlays
            onOverlayYield?(hideOverlays)
        }
        onProbe?(active, fullscreen)
        applyVisibility()
    }
}
