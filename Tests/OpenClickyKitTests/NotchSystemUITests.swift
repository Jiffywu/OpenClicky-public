import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let display = CGRect(x: 0, y: 0, width: 1710, height: 1112)

private func window(_ owner: String, _ bundle: String?, layer: Int = 0, _ frame: CGRect, pid: Int32 = 100, alpha: Double = 1) -> SystemWindowInfo {
    SystemWindowInfo(ownerName: owner, bundleID: bundle, pid: pid, layer: layer, bounds: frame, alpha: alpha)
}

@Suite("Notch system UI and geometry")
struct NotchSystemUITests {
    let detector = SystemUIDetector()

    @Test func ordinaryDesktopsDoNotTriggerAYield() {
        // A locked-screen-free desktop like the one seen live: the menu bar, Control Center's menu-bar items, the
        // Dock bar, apps and a notification banner.
        let windows = [
            window("Window Server", nil, layer: 24, CGRect(x: 0, y: 0, width: 1710, height: 38)),
            window("Control Center", "com.apple.controlcenter", layer: 25, CGRect(x: 1500, y: 0, width: 40, height: 37)),
            window("Dock", "com.apple.dock", layer: 20, CGRect(x: 300, y: 1030, width: 1100, height: 82)),
            window("Notification Center", "com.apple.notificationcenterui", layer: 23, CGRect(x: 1330, y: 50, width: 370, height: 90)),
            window("Google Chrome", "com.google.Chrome", CGRect(x: 0, y: 38, width: 1710, height: 1015)),
            window("Spotlight", "com.apple.Spotlight", layer: 25, CGRect(x: 1400, y: 0, width: 30, height: 37)),
            // The Dock's own window can span the display at the Dock level while only the bar is drawn, and the same
            // process as Notification Center draws desktop widgets below every window.
            window("Dock", "com.apple.dock", layer: 20, display),
            window("Notification Center", "com.apple.notificationcenterui", layer: -2147483603, CGRect(x: 40, y: 80, width: 340, height: 700)),
        ]
        #expect(detector.reasons(in: windows, displays: [display]).isEmpty)
    }

    @Test func recognisesEachSystemSurface() {
        func reasons(_ w: SystemWindowInfo) -> Set<NotchYieldReason> { detector.reasons(in: [w], displays: [display]) }
        #expect(reasons(window("Spotlight", "com.apple.Spotlight", layer: 26, CGRect(x: 505, y: 260, width: 700, height: 60))) == [.spotlight])
        #expect(reasons(window("Control Center", "com.apple.controlcenter", layer: 101, CGRect(x: 1300, y: 40, width: 330, height: 480)))
            == [.controlCenter])
        #expect(reasons(window("Notification Center", "com.apple.notificationcenterui", layer: 23, CGRect(x: 1330, y: 38, width: 380, height: 1074)))
            == [.notificationCenter])
        #expect(reasons(window("SystemUIServer", "com.apple.systemuiserver", layer: 101, CGRect(x: 1200, y: 38, width: 240, height: 300)))
            == [.systemMenu])
        #expect(reasons(window("screencaptureui", "com.apple.screencaptureui", layer: 25, CGRect(x: 500, y: 980, width: 700, height: 60)))
            == [.screenshotUI])
        #expect(reasons(window("screencaptureui", "com.apple.screencaptureui", layer: 1000, display)) == [.windowPicker])
        #expect(reasons(window("Dock", "com.apple.dock", layer: 18, display)) == [.missionControl])
        #expect(reasons(window("Dock", "com.apple.dock", layer: 27, display)) == [.missionControl])
        #expect(reasons(window("Dock", "com.apple.dock", layer: SystemUIDetector.dockLevel, display)).isEmpty,
                "a full-display window at the Dock's own level is the Dock, not Mission Control")
        // Transparent or tiny windows never count.
        #expect(reasons(window("Dock", "com.apple.dock", layer: 27, display, alpha: 0)).isEmpty)
        #expect(reasons(window("Dock", "com.apple.dock", layer: -2147483623, display)).isEmpty, "the desktop picture level isn't Mission Control")
        #expect(NotchYieldReason.missionControl.hidesOverlays && NotchYieldReason.screenshotUI.hidesOverlays && !NotchYieldReason.spotlight.hidesOverlays)
    }

    @Test func hardLimitsStopAStuckYield() {
        var coordinator = NotchYieldCoordinator(limits: [.screenshotUI: 45])
        #expect(coordinator.update([.screenshotUI, .spotlight], now: t0) == [.screenshotUI, .spotlight])
        #expect(coordinator.update([.screenshotUI, .spotlight], now: t0.addingTimeInterval(44)) == [.screenshotUI, .spotlight])
        // After 45 s the screenshot UI is ignored (OpenClicky comes back) until it actually goes away.
        #expect(coordinator.update([.screenshotUI, .spotlight], now: t0.addingTimeInterval(46)) == [.spotlight])
        #expect(coordinator.timedOutReasons == [.screenshotUI])
        #expect(coordinator.update([.screenshotUI], now: t0.addingTimeInterval(100)).isEmpty)
        #expect(coordinator.update([], now: t0.addingTimeInterval(101)).isEmpty)
        #expect(coordinator.update([.screenshotUI], now: t0.addingTimeInterval(102)) == [.screenshotUI], "a new screenshot UI is obeyed again")
    }

    @Test func fullscreenMeansTheFrontAppFillsTheDisplay() {
        let second = CGRect(x: 1710, y: 0, width: 1920, height: 1080)
        let windows = [
            window("Keynote", "com.apple.iWork.Keynote", second, pid: 7),
            window("Safari", "com.apple.Safari", CGRect(x: 0, y: 38, width: 1710, height: 1074), pid: 8),
        ]
        #expect(FullscreenDetector.fullscreenDisplays(windows: windows, displays: [display, second], frontPID: 7) == [1])
        #expect(FullscreenDetector.fullscreenDisplays(windows: windows, displays: [display, second], frontPID: 8).isEmpty,
                "a zoomed window below the menu bar is not full screen")
        #expect(FullscreenDetector.fullscreenDisplays(windows: windows, displays: [display, second], frontPID: nil).isEmpty)
    }

    @Test func fullscreenBelowTheHousingCountsOnlyWithoutTheMenuBar() {
        // On a display with a camera housing a full-screen app sits below it: the window is the display minus the
        // housing's 37.5 pt, the same frame a zoomed window gets. The menu bar's window tells them apart.
        let belowHousing = window("Safari", "com.apple.Safari", CGRect(x: 0, y: 37.5, width: 1710, height: 1074.5), pid: 8)
        let menuBar = window("Window Server", nil, layer: FullscreenDetector.menuBarLevel, CGRect(x: 0, y: 0, width: 1710, height: 38), pid: 90)
        #expect(FullscreenDetector.fullscreenDisplays(windows: [belowHousing], displays: [display], frontPID: 8, housingInsets: [37.5]) == [0])
        #expect(FullscreenDetector.fullscreenDisplays(windows: [menuBar, belowHousing], displays: [display], frontPID: 8,
                                                      housingInsets: [37.5]).isEmpty, "a zoomed window under a visible menu bar")
        #expect(FullscreenDetector.fullscreenDisplays(windows: [belowHousing], displays: [display], frontPID: 8).isEmpty,
                "without a housing the window must fill the display")
        // A menu bar on another display doesn't count against this one.
        let second = CGRect(x: 1710, y: 0, width: 1920, height: 1080)
        let otherMenuBar = window("Window Server", nil, layer: FullscreenDetector.menuBarLevel, CGRect(x: 1710, y: 0, width: 1920, height: 25), pid: 90)
        #expect(FullscreenDetector.fullscreenDisplays(windows: [otherMenuBar, belowHousing], displays: [display, second], frontPID: 8,
                                                      housingInsets: [37.5, 0]) == [0])
    }

    @Test func geometryFindsTheHousingAndHitAreas() {
        // The live MacBook Air: 1710×1112 with a 208-pt housing, 37.5 pt tall.
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1112), safeAreaTop: 37.5,
                                     auxiliaryTopLeft: CGRect(x: 0, y: 1074.5, width: 751, height: 37.5),
                                     auxiliaryTopRight: CGRect(x: 959, y: 1074.5, width: 751, height: 37.5))
        #expect(geometry.notchRect == CGRect(x: 751, y: 1074.5, width: 208, height: 37.5))
        #expect(geometry.hotZone.contains(CGPoint(x: 855, y: 1100)))
        #expect(!geometry.hotZone.contains(CGPoint(x: 855, y: 1000)))
        #expect(geometry.panelFrame == CGRect(x: 515, y: 632, width: 680, height: 480))
        let card = geometry.contentRect(for: .liveEvent(MutedReplyPolicy.event(copied: "hi", lineCount: 1, now: t0)))
        #expect(card.width == 460 && card.maxY == 1112 && card.midX == 855)
        let withButtons = geometry.contentSize(for: .liveEvent(NotchLiveEvent(id: "j", kind: .jobLaunched(jobID: "j", title: "x"), postedAt: t0)))
        #expect(card.height == 37.5 + 80 && withButtons.height == 37.5 + 96, "cards without buttons are shorter")
        #expect(geometry.contentRect(for: .hidden(.fullscreen)).isNull)
        #expect(geometry.panelPoint(fromGlobal: CGPoint(x: 515, y: 1112)) == .zero)

        // A display to the right without a housing (aux areas in any coordinate space only lend their widths).
        let plain = NotchGeometry(screenFrame: CGRect(x: 1710, y: 0, width: 1920, height: 1080), safeAreaTop: 0, auxiliaryTopLeft: nil,
                                  auxiliaryTopRight: nil)
        #expect(!plain.hasNotch)
        #expect(plain.hotZone.contains(CGPoint(x: 1710 + 960, y: 1079)))
        #expect(plain.contentSize(for: .tucked) == CGSize(width: 200, height: 6))
        let offset = NotchGeometry(screenFrame: CGRect(x: -1512, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                   auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 662, height: 32),
                                   auxiliaryTopRight: CGRect(x: 850, y: 950, width: 662, height: 32))
        #expect(offset.notchRect == CGRect(x: -850, y: 950, width: 188, height: 32))
    }
}
