import AppKit
import Observation
import OpenClickyKit
import SwiftUI

/// The small text panel the text key opens near the pointer: type a question, press Return, and the answer is drawn
/// on the screen and shown here (and read aloud when Settings says so). It takes keyboard focus without activating
/// OpenClicky, so the app the user is asking about stays in front. Escape or the text key again closes it.
@MainActor
@Observable
final class TypedTurnPanel: NSObject, NSWindowDelegate {
    var onSubmit: ((String) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    private let model: AppModel
    @ObservationIgnored private var panel: TypedPanelWindow?
    private let draft = TypedDraft()

    init(model: AppModel) { self.model = model }

    private(set) var isVisible = false

    /// The panel's window number, so screenshots leave it out.
    var windowNumbers: [Int] { panel.map { [$0.windowNumber] } ?? [] }

    static let size = CGSize(width: 440, height: 250)

    func show(near point: CGPoint) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = CGPoint(x: point.x + 14, y: point.y - Self.size.height - 14)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - Self.size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: true)
        draft.focusToken += 1
        panel.makeKeyAndOrderFront(nil)
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
        onVisibilityChange?(visible)
    }

    private func makePanel() -> TypedPanelWindow {
        let panel = TypedPanelWindow(contentRect: CGRect(origin: .zero, size: Self.size),
                                     styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        let view = TypedTurnView(draft: draft, submit: { [weak self] text in self?.onSubmit?(text) }, close: { [weak self] in self?.hide() })
            .environment(model)
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking back into the app being asked about closes the panel, unless an answer is still coming in.
        if !model.turn.phase.isBusy || model.turn.kind != .typed { hide() }
    }
}

final class TypedPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class TypedDraft {
    var text = ""
    /// Bumped each time the panel opens, to put the cursor back in the field.
    var focusToken = 0
}

struct TypedTurnView: View {
    let draft: TypedDraft
    let submit: (String) -> Void
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var draft = draft
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill").foregroundStyle(Color.accentColor)
                TextField("Ask about what's on your screen…", text: $draft.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit(send)
                if model.turn.kind == .typed, model.turn.phase.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))

            if model.turn.kind == .typed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if let words = model.turn.words {
                            Text(words).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        if let status = model.turn.status {
                            Label(status, systemImage: "magnifyingglass").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.turn.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                        }
                        if let notice = model.turn.notice {
                            Label(notice.title, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            } else {
                Text("Return sends · Esc closes. The answer is drawn on your screen.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: TypedTurnPanel.size.width, height: TypedTurnPanel.size.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .onExitCommand(perform: close)
        .onAppear { focused = true }
        .onChange(of: draft.focusToken) { _, _ in focused = true }
    }

    private func send() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft.text = ""
        submit(text)
    }
}
