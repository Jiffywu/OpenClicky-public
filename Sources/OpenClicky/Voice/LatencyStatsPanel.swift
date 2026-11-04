import AppKit
import OpenClickyKit
import SwiftUI

/// The floating latency stats panel (Settings → Developer → Floating latency stats): the last turn's timings, cache
/// hit, request size and the brain's thread, in the top-right corner. Click-through and without a title bar, so
/// `WindowCaptureRegistrar` gives it the `hiddenFromOwnCaptures` role and OpenClicky's own screenshots leave it out.
@MainActor
final class LatencyStatsPanelController {
    private(set) var panel: LatencyStatsPanel?
    private let model = LatencyStatsModel()
    /// Registers the panel's capture role as soon as it exists (the app's registrar would also find it on its sweep).
    var register: ((NSWindow) -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows (or refreshes) the panel with this content.
    func show(_ content: LatencyHUDContent) {
        model.content = content
        let panel = self.panel ?? makePanel()
        place(panel)
        panel.orderFrontRegardless()
    }

    /// Updates the content without showing a hidden panel.
    func update(_ content: LatencyHUDContent) { model.content = content }

    func hide() { panel?.orderOut(nil) }

    /// Makes the panel (without showing it), for tests and the evidence render.
    @discardableResult
    func makePanel() -> LatencyStatsPanel {
        if let panel { return panel }
        let panel = LatencyStatsPanel(contentRect: NSRect(origin: .zero, size: LatencyStatsPanel.size))
        panel.contentView = NSHostingView(rootView: LatencyStatsView(model: model))
        self.panel = panel
        register?(panel)
        return panel
    }

    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - LatencyStatsPanel.size.width - 16, y: frame.maxY - LatencyStatsPanel.size.height - 16))
    }
}

/// A borderless, non-activating, click-through panel above other windows.
final class LatencyStatsPanel: NSPanel {
    static let size = NSSize(width: 300, height: 320)

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        ignoresMouseEvents = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class LatencyStatsModel {
    var content = LatencyHUDContent.make(timings: nil, stats: nil)
}

struct LatencyStatsView: View {
    let model: LatencyStatsModel

    var body: some View {
        let content = model.content
        VStack(alignment: .leading, spacing: 4) {
            Text(content.title).font(.system(size: 12, weight: .semibold))
            ForEach(Array(content.rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.label).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(row.value).fontWeight(row.emphasized ? .semibold : .regular)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            if let footer = content.footer {
                Divider()
                Text(footer).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(width: LatencyStatsPanel.size.width, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(width: LatencyStatsPanel.size.width, height: LatencyStatsPanel.size.height, alignment: .topLeading)
    }
}

/// `OpenClicky --render-latency-hud <folder>`: the panel offscreen with a sample voice turn and brain session.
@MainActor
enum LatencyHUDSnapshots {
    static func run(into folder: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let model = LatencyStatsModel()
            model.content = LatencyHUDContent.make(timings: sampleTimings(), stats: sampleStats())
            let card = ZStack {
                LinearGradient(colors: [Color(white: 0.85), Color(white: 0.7)], startPoint: .top, endPoint: .bottom)
                LatencyStatsView(model: model)
            }
            try EvidenceSnapshots.render(card, size: NSSize(width: 340, height: 360), to: folder.appendingPathComponent("latency-hud.png"))
            let dark = ZStack {
                Color(white: 0.15)
                LatencyStatsView(model: model)
            }
            try EvidenceSnapshots.render(dark, size: NSSize(width: 340, height: 360), dark: true,
                                         to: folder.appendingPathComponent("latency-hud-dark.png"))
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }

    /// A voice turn shaped like the cheap-config live runs in docs/latency.md.
    static func sampleTimings() -> TurnTimings {
        let start = Date(timeIntervalSince1970: 1_793_700_000)
        func at(_ ms: Double) -> Date { start.addingTimeInterval(ms / 1000) }
        var timings = TurnTimings(kind: .voice)
        timings.pressedAt = at(-1_800)
        timings.releasedAt = at(0)
        timings.transcriptAt = at(410)
        timings.captureStartedAt = at(410)
        timings.captureFinishedAt = at(530)
        timings.requestStartedAt = at(560)
        timings.firstTokenAt = at(1_310)
        timings.firstLineAt = at(1_520)
        timings.firstAudioAt = at(1_760)
        timings.firstLineHeardAt = at(1_850)
        timings.brainFinishedAt = at(2_900)
        timings.finishedAt = at(5_400)
        timings.model = "claude-haiku-5-5"
        timings.usage = TokenUsage(inputTokens: 18_400, cachedInputTokens: 15_900, outputTokens: 210, cacheWriteTokens: 2_100)
        timings.requestBodyBytes = 412_000
        return timings
    }

    static func sampleStats() -> BrainSessionStats {
        BrainSessionStats.make(sessionID: "7F3C2A91", startedAt: Date(timeIntervalSince1970: 1_793_698_000), lastTurnAt: nil, turns: 6,
                               threadItems: 23, screenshotsInThread: 3, lastInputTokens: 18_400, nextCompactionCheck: 60_000,
                               compactions: 1)
    }
}
