import OpenClickyKit
import SwiftUI

/// Home → Chat: conversations on the left, the selected one on the right, and a box to type the next question.
struct HomeChatView: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        HStack(spacing: 0) {
            ConversationList()
                .frame(width: 250)
            Divider()
            VStack(spacing: 0) {
                Transcript()
                Divider()
                Composer()
            }
        }
    }
}

private struct ConversationList: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        let chat = services.chat
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations").font(.headline)
                Spacer()
                Button {
                    chat.newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New conversation")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if chat.sessions.isEmpty {
                Text("Nothing yet. Hold your talk keys and ask something, or type below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(chat.sessions) { session in
                            ConversationRow(session: session, selected: session.id == chat.selectedSessionID)
                                .onTapGesture { chat.select(session.id) }
                                .contextMenu {
                                    Button("Delete conversation", role: .destructive) { chat.delete(session.id) }
                                }
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
    }
}

private struct ConversationRow: View {
    let session: HistorySession
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title.isEmpty ? "Conversation" : session.title)
                    .font(.system(.callout, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(HomeFormat.relative(session.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !session.preview.isEmpty {
                Text(session.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Label("\(session.turnCount)", systemImage: "text.bubble").labelStyle(.titleAndIcon)
                if session.drawingCount > 0 {
                    Label("\(session.drawingCount)", systemImage: "scribble.variable").labelStyle(.titleAndIcon)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear))
        .contentShape(Rectangle())
    }
}

private struct Transcript: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        let chat = services.chat
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.turns.isEmpty && chat.pending == nil {
                        EmptyChat()
                    }
                    ForEach(chat.entries) { entry in
                        switch entry {
                        case .turn(let turn): TurnView(turn: turn).id(turn.id)
                        case .handOff(let handOff): HandOffView(handOff: handOff).id(handOff.id)
                        }
                    }
                    if let pending = chat.pending {
                        PendingView(pending: pending).id("pending")
                    }
                }
                .padding(20)
            }
            // Newest at the bottom, like a chat; jumps (not animates) when another conversation is picked.
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.turns.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: chat.pending?.lines.count) { _, _ in
                proxy.scrollTo("pending", anchor: .bottom)
            }
        }
    }
}

private struct EmptyChat: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask OpenClicky anything").font(.title3.weight(.semibold))
            Text("\(services.talkKeys.settings.voice.phrase) and talk to ask about what's on your screen; OpenClicky answers out loud and can point and draw. Typed questions here get a written answer.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 40)
    }
}

private struct TurnView: View {
    let turn: HistoryTurn
    @Environment(HomeServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !turn.words.isEmpty {
                HStack {
                    Spacer(minLength: 80)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(turn.words)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                        Text("\(turn.source == .voice ? "Spoken" : turn.source == .text ? "Typed" : "OpenClicky")\(turn.frontApp.map { " in \($0)" } ?? "") · \(HomeFormat.time(turn.startedAt))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let trigger = turn.trigger {
                Text(HomeFormat.trigger(trigger))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    if turn.outcome == .failed {
                        Label(turn.replyText.isEmpty ? "That answer failed." : turn.replyText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        if let detail = turn.errorDetail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    } else if !turn.replyText.isEmpty {
                        Text(turn.replyText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if turn.outcome == .cancelled {
                        Text("Stopped before answering.").foregroundStyle(.secondary)
                    }
                    if turn.hasDrawing {
                        DrawingThumb(turn: turn)
                    }
                    if !turn.tools.isEmpty || !turn.statuses.isEmpty {
                        Text((turn.statuses.isEmpty ? turn.tools : turn.statuses).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(HomeFormat.meta(turn))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.secondary.opacity(0.12)))
                Spacer(minLength: 80)
            }
        }
    }
}

/// A job started or came back, between the turns.
private struct HandOffView: View {
    let handOff: HistoryHandOff

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: handOff.kind == .started ? "arrow.up.forward.circle" : "arrow.down.backward.circle")
            VStack(alignment: .leading, spacing: 2) {
                Text(handOff.kind == .started ? "Started a job: \(handOff.title)" : "\(handOff.title) came back"
                     + (handOff.outcome.map { $0 == "done" ? "" : " (\($0))" } ?? ""))
                    .font(.caption.weight(.medium))
                if let spoken = handOff.spoken, handOff.kind == .cameBack {
                    Text(spoken).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                Text(HomeFormat.time(handOff.at)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct DrawingThumb: View {
    let turn: HistoryTurn
    @Environment(HomeServices.self) private var services

    var body: some View {
        let drawings = services.drawings
        Group {
            if let image = drawings.thumbnails[turn.id] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.secondary.opacity(0.3)))
                    .onTapGesture {
                        drawings.selectedID = turn.id
                        services.chat.section = .drawings
                    }
            } else {
                Label("Drew on the screen", systemImage: "scribble.variable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onAppear { drawings.renderNow(HistoryDrawing(turn: turn)) }
            }
        }
    }
}

private struct PendingView: View {
    let pending: HomeChatModel.Pending

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 80)
                Text(pending.question)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if pending.lines.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(pending.status ?? "Thinking…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(pending.lines.joined(separator: " "))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.secondary.opacity(0.12)))
                Spacer(minLength: 80)
            }
        }
    }
}

private struct Composer: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        @Bindable var chat = services.chat
        VStack(alignment: .leading, spacing: 6) {
            if let error = chat.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Type a question…", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.secondary.opacity(0.35)))
                    .onSubmit { chat.send() }
                Button {
                    chat.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .buttonStyle(.borderless)
                .disabled(!chat.canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }
}

enum HomeFormat {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return time(date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func meta(_ turn: HistoryTurn) -> String {
        var parts: [String] = []
        if let model = turn.model { parts.append(model) }
        if let first = turn.timings.firstLineMs { parts.append("first line \(seconds(first))") }
        if let total = turn.timings.totalMs { parts.append("\(seconds(total)) total") }
        if let usage = turn.usage { parts.append("\(usage.input + usage.output) tokens") }
        if let narration = turn.narration, narration != "completed" { parts.append(narration) }
        return parts.joined(separator: " · ")
    }

    static func seconds(_ ms: Int) -> String { String(format: "%.1f s", Double(ms) / 1000) }

    static func trigger(_ trigger: String) -> String {
        switch trigger {
        case "job_report": "A background job came back"
        case "tour": "Welcome tour"
        case "did_step", "clicked_target": "You followed a step"
        default: "OpenClicky spoke up (\(trigger))"
        }
    }
}
