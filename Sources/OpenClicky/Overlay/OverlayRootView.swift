import AppKit
import Combine
import OpenClickyKit
import SwiftUI

/// What OpenClicky shows over one display, bottom to top: the drawing canvas (with 3D figures), the draw-to-ask ink and
/// the guided walkthrough's target ring, the buddy pointer, the spoken caption, the listening bubble by the pointer, the
/// notch pill (or always-on voice's state), and the walkthrough's step pill. The notch pill, caption and bubble appear on the display the pointer is
/// on; the step pill on the display with the target.
struct OverlayRootView: View {
    let screen: NSScreen
    @Environment(AppModel.self) private var model
    @ViewState private var mouse: CGPoint = .zero
    @ViewState private var pointerHere = false
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            DrawingCanvasView(layer: model.drawings.layer(for: screen))
                .frame(width: screen.frame.width, height: screen.frame.height)
            // The ink while the talk keys are held, and the ring around the control a walkthrough waits on.
            PointingOverlayLayer(screenFrame: screen.frame, model: model.pointing)
                .frame(width: screen.frame.width, height: screen.frame.height)
            BuddyPointerLayer(screenFrame: screen.frame, controller: model.pointer)
            GeometryReader { proxy in
                ZStack {
                    if pointerHere {
                        if showsBubble {
                            ListeningBubble(turn: model.turn, level: model.micLevel)
                                .position(x: mouse.x + 28, y: mouse.y + 28)
                                .transition(.scale.combined(with: .opacity))
                        }
                        if model.voiceLoopSettings.showsCaptions, let caption {
                            LiveCaption(text: caption, index: model.turn.captionIndex, screen: screen)
                                .position(x: proxy.size.width / 2, y: proxy.size.height - 96)
                        }
                        VStack {
                            NotchPill(turn: model.turn, timings: model.lastTimings, showsTimings: model.voiceLoopSettings.showsTimings,
                                      micLevel: model.micLevel, notchWidth: notchWidth, alwaysOn: model.alwaysOn,
                                      alwaysOnKeyPhrase: model.alwaysOnKeyPhrase)
                            Spacer()
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                        // The interactive notch shows the pill itself when it is on.
                        .opacity(model.notchPanelActive ? 0 : 1)
                    }
                    if let status = model.pointing.status, showsWalkthroughStatus {
                        // Below the notch pill, which can show at the same time (the next step being prepared).
                        WalkthroughStep(status: status)
                            .position(x: proxy.size.width / 2, y: screen.safeAreaInsets.top > 0 ? 100 : 84)
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(width: screen.frame.width, height: screen.frame.height, alignment: .topLeading)
        .ignoresSafeArea()
        .animation(.spring(duration: 0.25), value: model.turn.phase)
        .animation(.easeInOut(duration: 0.2), value: model.turn.caption)
        .animation(.easeInOut(duration: 0.2), value: model.turn.notice)
        .animation(.easeInOut(duration: 0.2), value: model.pointing.status)
        .animation(.easeInOut(duration: 0.2), value: model.alwaysOn.voice)
        .onReceive(timer) { _ in updateMouse() }
        .allowsHitTesting(false)
    }

    private var showsBubble: Bool { model.turn.phase == .listening }

    /// The line being spoken, or while always-on talks, the end of its reply so far.
    private var caption: String? {
        if let caption = model.turn.caption, model.turn.phase.isBusy { return caption }
        guard model.alwaysOn.state == .on, model.alwaysOn.voice == .speaking else { return nil }
        return model.alwaysOn.replyTail()
    }

    /// The step counter shows on the display with the target (or the main display while no target waits).
    private var showsWalkthroughStatus: Bool {
        if let target = model.pointing.target { return screen.frame.intersects(target.frame) }
        return screen == NSScreen.main
    }

    /// Width of the camera housing on Macs with a notch, from the menu bar areas either side of it.
    private var notchWidth: CGFloat {
        guard screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, right.minX - left.maxX)
    }

    /// NSEvent.mouseLocation is global, bottom-left origin; the view's origin is the screen's top-left.
    private func updateMouse() {
        let global = NSEvent.mouseLocation
        let here = screen.frame.contains(global)
        if here != pointerHere { pointerHere = here }
        guard here, model.turn.phase == .listening else { return }
        mouse = CGPoint(x: global.x - screen.frame.minX, y: screen.frame.maxY - global.y)
    }
}

/// "Step 2 · Export a PDF · Click Export · Esc to stop", over the screen while a walkthrough runs.
struct WalkthroughStep: View {
    let status: GuidedStatus

    var body: some View {
        HStack(spacing: 8) {
            Text("Step \(status.step)").font(.system(size: 12, weight: .bold))
            if let task = status.task { Text(task).font(.system(size: 12, weight: .medium)).lineLimit(1) }
            if !status.caption.isEmpty { Text("· \(status.caption)").font(.system(size: 12)).lineLimit(1) }
            Text("· Esc to stop").font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.accentColor.opacity(0.92)))
        .fixedSize()
        .allowsHitTesting(false)
    }
}


/// The caption as it is heard: word by word in step with the audio the speech player has actually played (when the
/// setting is on and the line is the one playing), with the drawing's beat chips under it when asked for.
struct LiveCaption: View {
    let text: String
    let index: Int?
    let screen: NSScreen
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.voiceLoopSettings
        if settings.captionsWordByWord || settings.showsBeatChips {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                CaptionPlate(text: text, revealed: settings.captionsWordByWord ? revealed() : nil, size: settings.captionSize,
                             beats: settings.showsBeatChips ? beats(at: context.date) : nil)
            }
        } else {
            CaptionPlate(text: text, size: settings.captionSize)
        }
    }

    private func revealed() -> Int? {
        guard let index, let position = model.speechPosition(), position.lineIndex == index else { return nil }
        return CaptionWords(text).revealed(elapsed: position.elapsed, duration: position.duration)
    }

    /// Asked of the engine about eight times a second, not every frame.
    private func beats(at date: Date) -> DrawingBeats? {
        BeatsCache.shared.beats(at: date) { model.drawings.beats(for: screen) }
    }
}

@MainActor
private final class BeatsCache {
    static let shared = BeatsCache()
    private var last: (date: Date, beats: DrawingBeats?)?

    func beats(at date: Date, fetch: () -> DrawingBeats?) -> DrawingBeats? {
        if let last, date.timeIntervalSince(last.date) < 0.12 { return last.beats }
        let beats = fetch()
        last = (date, beats)
        return beats
    }
}
