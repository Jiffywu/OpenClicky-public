import AppKit
import Observation
import OpenClickyKit
import SwiftUI

/// The card shown when the brain calls `show_result` (or the user opens a finished job): what came back, the files,
/// and the agent's next steps as chips that send a follow-up to the same job.
@MainActor
@Observable
final class AgentResultCardModel {
    private(set) var card: AgentResultCard?
    /// Chips already sent for the card on screen.
    private(set) var sent: Set<String> = []
    private(set) var pending: Set<String> = []
    @ObservationIgnored private var generation = UUID()
    private(set) var status: String?
    var reply = ""

    /// Sends a follow-up to the card's job (the manager's `send`).
    @ObservationIgnored var sendFollowUp: ((String, String) async throws -> Void)?
    /// Answers the card's job (the manager's `answer`, by job id and request id): "I'm done" for a user step (no
    /// request id), yes or no to the proposed routines (their confirmation's id).
    @ObservationIgnored var answerJob: ((String, String?, AgentApprovalDecision) async throws -> Void)?
    /// Called once a follow-up went out (the app plays the launch sound).
    @ObservationIgnored var onSent: (() -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?

    init(card: AgentResultCard? = nil) { self.card = card }

    func show(_ report: AgentJobReport) {
        card = AgentResultCard(report: report)
        sent = []
        pending = []
        generation = UUID()
        status = nil
        reply = ""
        responded = []
    }

    func tap(_ chip: String) {
        guard let card, sendFollowUp != nil, !sent.contains(chip), !pending.contains(chip) else { return }
        pending.insert(chip)
        send(AgentResultCard.followUp(for: chip), to: card, chip: chip)
    }

    func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let card, !text.isEmpty else { return }
        reply = ""
        send(text, to: card)
    }

    private func send(_ text: String, to card: AgentResultCard, chip: String? = nil) {
        guard let sendFollowUp else { return }
        let generation = self.generation
        status = "Sending…"
        Task { [weak self] in
            do {
                try await sendFollowUp(card.report.jobID, text)
                guard let self, self.generation == generation else { return }
                if let chip { self.pending.remove(chip); self.sent.insert(chip) }
                self.status = "Sent to \(card.report.agentName ?? card.title). You'll hear back when it's done."
                self.onSent?()
            } catch {
                guard let self, self.generation == generation else { return }
                if let chip { self.pending.remove(chip) }
                self.status = "Couldn't send that: \(error)"
            }
        }
    }

    /// A choice from the answer's ask block: sent to the job as the user's reply.
    func choose(_ choice: AgentAnswer.Choice) {
        guard let card else { return }
        let text = choice.reply
        guard !text.isEmpty, !sent.contains(text), !pending.contains(text) else { return }
        pending.insert(text)
        send(text, to: card, chip: text)
    }

    /// What a card button answers: the user step, or the routines the report proposed. Each is answered on its own.
    enum Request: Hashable { case step, routines }

    /// "I'm done" or "Skip" on a user step, or yes/no to the proposed routines.
    func respond(_ decision: AgentApprovalDecision, to request: Request, done: String) {
        guard let card, let answerJob, !responded.contains(request) else { return }
        let requestID = request == .routines ? card.report.routineRequestID : nil
        let generation = self.generation
        status = "Sending…"
        Task { [weak self] in
            do {
                try await answerJob(card.report.jobID, requestID, decision)
                guard let self, self.generation == generation else { return }
                self.status = done
                self.responded.insert(request)
                if case .approve = decision, request == .step { self.onSent?() }
            } catch {
                guard let self, self.generation == generation else { return }
                self.status = "Couldn't send that: \(error)"
            }
        }
    }

    /// The card's user step and routine question that have been answered.
    private(set) var responded: Set<Request> = []

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied."
    }

    func open(_ file: AgentResultCard.File) {
        if file.isLink, let url = URL(string: file.location) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: file.location))
        }
    }

    func reveal(_ file: AgentResultCard.File) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.location)])
    }

    /// Opens the preview pane on the card's report and files, at `file` (or the first file).
    func preview(_ file: AgentResultCard.File? = nil) {
        guard let card else { return }
        FilePreviewWindow.shared.show(FilePreviewModel(card: card, selecting: file?.location))
    }

    func dismiss() { onDismiss?() }
}

struct AgentResultCardView: View {
    let model: AgentResultCardModel

    var body: some View {
        Group {
            if let card = model.card {
                content(card)
            } else {
                EmptyView()
            }
        }
    }

    private func content(_ card: AgentResultCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: card.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(tint(card))
                    .frame(width: 34, height: 34)
                    .background(tint(card).opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.headline).lineLimit(2)
                    Text(card.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { model.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            Text(card.summary)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            if let answer = card.answer {
                AgentAnswerSection(answer: answer, model: model)
            }

            if card.userStep != nil || !card.routineProposals.isEmpty {
                AgentCardRequestSection(card: card, model: model)
            }

            if !card.body.isEmpty, card.answer == nil || card.answer?.blocks.isEmpty == true {
                ScrollView {
                    MarkdownDocumentView(blocks: Array(MarkdownBlockParser.parse(card.body).prefix(12)), compact: true)
                        .foregroundStyle(.primary.opacity(0.85))
                }
                .frame(maxHeight: 170)
                .overlay(alignment: .bottomTrailing) {
                    Button { model.preview() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .help("Read it in full")
                }
            }

            if let question = card.question {
                VStack(alignment: .leading, spacing: 6) {
                    Label(question, systemImage: "questionmark.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        TextField("Your answer", text: Bindable(model).reply)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.sendReply() }
                        Button("Send") { model.sendReply() }
                            .disabled(model.reply.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if !card.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(card.files) { file in
                        HStack(spacing: 6) {
                            Image(systemName: file.isLink ? "link" : "doc")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Button(file.name) { model.open(file) }
                                .buttonStyle(.link)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button { model.preview(file) } label: { Image(systemName: "eye") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Preview")
                            if !file.isLink {
                                Button { model.reveal(file) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .help("Show in Finder")
                            }
                        }
                        .font(.callout)
                    }
                }
            }

            if !card.chips.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ChipFlow(spacing: 6) {
                        ForEach(card.chips, id: \.self) { chip in
                            let done = model.sent.contains(chip)
                            Button { model.tap(chip) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: done ? "checkmark" : "arrow.turn.down.right")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(chip).lineLimit(2).multilineTextAlignment(.leading)
                                }
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(done ? 0.25 : 0.12), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35)))
                                .contentShape(Capsule())
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .disabled(done || model.pending.contains(chip))
                            .help("Ask the agent to do this next")
                        }
                    }
                }
            }

            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private func tint(_ card: AgentResultCard) -> Color {
        switch card.report.outcome {
        case .done: .green
        case .needsYou: .orange
        case .failed: .red
        case .stopped: .gray
        }
    }
}

/// Lays chips out left to right, wrapping to new rows.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 348
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(width, widest), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The result card with the link action its Markdown links use.
struct AgentResultCardHost: View {
    let model: AgentResultCardModel
    let openURL: OpenURLAction

    var body: some View {
        AgentResultCardView(model: model).environment(\.openURL, openURL)
    }
}

/// A floating, non-activating panel near the top right that hosts the result card. It closes from its button, after
/// a while when it isn't hovered, or when another card replaces it.
@MainActor
final class AgentResultCardPanel {
    let model: AgentResultCardModel
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// Seconds a card stays up untouched.
    var lingers: TimeInterval = 90
    /// A frame to stay clear of (the agent HUD, when it is up).
    var avoid: (() -> NSRect?)?
    /// Whether the pointer is on the card; nil checks the panel's frame against the real pointer.
    var isHovered: (() -> Bool)?
    /// Where links in the card go: the app's router, so `openclicky:` links open in place instead of round-tripping
    /// through LaunchServices. Set before the first card shows (HomeServices.start sets it with the HUD's).
    var openURL: OpenURLAction?

    init(model: AgentResultCardModel = AgentResultCardModel()) {
        self.model = model
        model.onDismiss = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ report: AgentJobReport) {
        model.show(report)
        let panel = preparedPanel()
        panel.contentView?.layoutSubtreeIfNeeded()
        position(panel)
        panel.orderFrontRegardless()
        armHideTimer()
    }

    /// Hides the card after `lingers` seconds, or looks again later while the pointer is on it. Looking again leaves
    /// the card as it is: a half-typed reply, sent chips and a send in progress stay.
    func armHideTimer() {
        hideTask?.cancel()
        let lingers = self.lingers
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lingers))
            guard !Task.isCancelled, let self else { return }
            let hovered = self.isHovered?() ?? self.panel.map { $0.frame.contains(NSEvent.mouseLocation) } ?? false
            if hovered { self.armHideTimer(); return }
            self.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // The reply field needs key focus, which a non-activating panel only takes when asked.
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: AgentResultCardHost(model: model, openURL: openURL ?? OpenURLAction { _ in .systemAction }))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    /// The panel, made on first use and kept for later cards.
    @discardableResult
    func preparedPanel() -> NSPanel {
        if let panel { return panel }
        let made = makePanel()
        panel = made
        return made
    }

    /// The card's hosting view, once a card has shown (tests check the link action it carries).
    var hostingView: NSHostingView<AgentResultCardHost>? { panel?.contentView as? NSHostingView<AgentResultCardHost> }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let visible = screen.visibleFrame
        var right = visible.maxX - 16
        if let other = avoid?(), other.intersects(NSRect(x: right - size.width, y: visible.maxY - size.height - 12, width: size.width, height: size.height)) {
            right = other.minX - 12
        }
        panel.setFrame(NSRect(x: max(visible.minX + 16, right - size.width), y: visible.maxY - size.height - 12,
                              width: size.width, height: size.height), display: true)
    }
}
