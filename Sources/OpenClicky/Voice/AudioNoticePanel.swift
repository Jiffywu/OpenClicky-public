import AppKit
import OpenClickyKit
import SwiftUI

/// A sound-trouble notice with its buttons ("Your Mac is muted… [Unmute]", "Switched to the built-in microphone…
/// [Microphone Settings]"): a small dark card under the notch pill that can be clicked without activating OpenClicky or
/// taking the keyboard from the app the user is in.
struct AudioNoticeView: View {
    let notice: AudioNotice
    var onAction: (AudioNotice.Action) -> Void = { _ in }
    var onClose: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(notice.tone == .error ? Color.orange : Color.white)
                .frame(width: 22, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = notice.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !notice.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(notice.actions.enumerated()), id: \.offset) { index, action in
                            Button(action.label) { onAction(action) }
                                .buttonStyle(NoticeButtonStyle(prominent: index == 0))
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 400, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    private var symbol: String {
        switch notice.kind {
        case .outputMuted: "speaker.slash.fill"
        case .outputZeroVolume: "speaker.fill"
        case .microphoneRebuilding: "arrow.triangle.2.circlepath"
        case .microphoneFailedOver: "mic.badge.xmark"
        case .microphoneDead, .microphoneDeadAir: "mic.slash.fill"
        case .microphoneOverflow: "waveform.badge.exclamationmark"
        case .microphonePermission: "lock.fill"
        }
    }
}

private struct NoticeButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(prominent ? Color.white.opacity(configuration.isPressed ? 0.7 : 0.95)
                                                 : Color.white.opacity(configuration.isPressed ? 0.3 : 0.18)))
    }
}

/// The card's window: floats over every app on every Space, takes clicks on its first touch, never becomes key.
final class AudioNoticePanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons answer the first click even though the panel is never key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows one notice at a time under the notch of the display with the pointer, and hides it after its lifetime (or when
/// a button or the close mark is pressed). A newer notice replaces the one showing.
@MainActor
final class AudioNoticePanelController {
    private var panel: AudioNoticePanel?
    private var hideTask: Task<Void, Never>?
    private(set) var showing: AudioNotice?

    var windowNumber: Int? { panel?.isVisible == true ? panel?.windowNumber : nil }

    func show(_ notice: AudioNotice, onAction: @escaping (AudioNotice.Action) -> Void) {
        let panel = self.panel ?? AudioNoticePanel()
        self.panel = panel
        showing = notice
        let view = FirstClickHostingView(rootView: AudioNoticeView(notice: notice, onAction: { [weak self] action in
            self?.hide()
            onAction(action)
        }, onClose: { [weak self] in self?.hide() }).padding(12))
        panel.contentView = view
        let size = view.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // Below the notch pill (which hangs from the top edge).
        let top = frame.maxY - ((screen?.safeAreaInsets.top ?? 0) > 0 ? 92 : 64)
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        hideTask?.cancel()
        let lifetime = notice.lifetime
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled, let self, self.showing == notice else { return }
            self.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        showing = nil
        panel?.orderOut(nil)
    }
}

/// `OpenClicky --render-audio-notices <folder>`: every sound-trouble notice as the card shows it, offscreen (no
/// permission, no device, no volume change).
@MainActor
enum AudioNoticeSnapshots {
    static func run(into folder: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var tracker = MicTroubleTracker()
            var notices: [(String, AudioNotice)] = []
            notices.append(("notice-muted", AudioNotice.unheard(.muted, copied: true, volume: 0.6)))
            notices.append(("notice-muted-at-zero", AudioNotice.unheard(.muted, copied: true, volume: 0)))
            notices.append(("notice-zero-volume", AudioNotice.unheard(.zeroVolume, copied: true, volume: 0)))
            if let notice = tracker.handle(.rebuilding(.allZeros)) { notices.append(("notice-mic-rebuilding", notice)) }
            if let notice = tracker.handle(.failedOver(from: "USB Audio Mic", to: "MacBook Air Microphone")) { notices.append(("notice-mic-failed-over", notice)) }
            if let notice = tracker.handle(.irrecoverable(.noAudio)) { notices.append(("notice-mic-dead", notice)) }
            if let notice = tracker.handle(.overflow(dropped: 40)) { notices.append(("notice-mic-overflow", notice)) }
            let dead = MicPressSummary(duration: 1.5, chunks: 36, audibleChunks: 0, peak: 0)
            _ = tracker.pressEnded(dead)
            if let notice = tracker.pressEnded(dead) { notices.append(("notice-mic-dead-air", notice)) }
            if let notice = MicTroubleTracker.permissionNotice(.denied) { notices.append(("notice-mic-permission", notice)) }
            for (name, notice) in notices {
                let card = ZStack {
                    LinearGradient(colors: [Color(white: 0.82), Color(white: 0.68)], startPoint: .top, endPoint: .bottom)
                    AudioNoticeView(notice: notice)
                }
                try EvidenceSnapshots.render(card, size: NSSize(width: 460, height: 190), to: folder.appendingPathComponent(name + ".png"))
            }
            // Settings > Voice's microphone, echo-cancellation and quiet-time sections (a fixture voice loop; nothing
            // is started, so no mic, no monitor and no key tap).
            let fixture = try EvidenceSnapshots.Fixture()
            let loop = VoiceLoopController(model: fixture.model, home: fixture.services, settingsURL: nil)
            fixture.model.voiceLoop = loop
            let sections = Form { MicrophoneSettingsSections() }.formStyle(.grouped)
                .environment(fixture.model).environment(fixture.services)
            try EvidenceSnapshots.render(sections, size: NSSize(width: 680, height: 760), to: folder.appendingPathComponent("settings-microphone-sections.png"))
            // The same after the chosen mic failed over to the built-in one: the warning with its "Try … again" button.
            // The trouble monitor listens to a capture device that is never started; the card itself isn't shown.
            loop.audio.startMicTrouble(microphone: SharedMicrophone(device: CaptureMicrophoneDevice()))
            loop.audio.micTrouble?.onNotice = nil
            loop.audio.micTrouble?.handle(.failedOver(from: "USB Audio Mic", to: "MacBook Air Microphone"))
            let failedOver = Form { MicrophoneSettingsSections() }.formStyle(.grouped)
                .environment(fixture.model).environment(fixture.services)
            try EvidenceSnapshots.render(failedOver, size: NSSize(width: 680, height: 820),
                                         to: folder.appendingPathComponent("settings-microphone-failed-over.png"))
            loop.audio.micTrouble?.stop()
            try? FileManager.default.removeItem(at: fixture.root)
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }
}
