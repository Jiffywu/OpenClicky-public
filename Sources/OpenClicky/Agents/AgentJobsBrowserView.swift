import OpenClickyKit
import SwiftUI

/// Home → Agents: the job list (preview text, unseen badge, earlier runs, archive) beside the selected job's
/// transcript, rebuilt from its files so it reads the same after a relaunch.
struct AgentJobsBrowserView: View {
    let model: AgentHUDModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            list
                .frame(width: 290)
            Divider()
            Group {
                if let id = model.selectedJobID, let item = model.feed.item(id) {
                    AgentTranscriptView(item: item, model: model)
                } else {
                    ContentUnavailableView("Pick a job", systemImage: "text.bubble",
                                           description: Text("Its asks, what the agent said and did, and its results show here."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(model.showArchived ? "Archived" : "Jobs").font(.headline)
                if model.unseenCount > 0, !model.showArchived {
                    Text("\(model.unseenCount) new")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                Button(model.showArchived ? "Back to jobs" : "Archived (\(model.archivedCount))") {
                    model.showArchived.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(!model.showArchived && model.archivedCount == 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            if model.listItems.isEmpty {
                Text(model.showArchived ? "Nothing archived." : "No background jobs yet. Ask OpenClicky to research, write or build something and it runs here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.listItems) { item in
                            AgentJobListRow(item: item, model: model, selected: model.selectedJobID == item.id)
                        }
                    }
                    .padding(6)
                }
            }
        }
    }
}

private struct AgentJobListRow: View {
    let item: AgentActivityFeed.Item
    let model: AgentHUDModel
    let selected: Bool

    private var record: AgentJobRecord { item.record }

    var body: some View {
        Button { model.select(item.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(record.isUnseen ? Color.accentColor : Color.clear)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                    .accessibilityLabel(record.isUnseen ? Text("New result") : Text(""))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.lastReport?.title ?? record.report?.title ?? record.title)
                            .font(.system(.callout, weight: record.isUnseen ? .semibold : .medium))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(Self.when(record.updatedAt, now: model.now))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(model.preview(item))
                        .font(.caption)
                        .foregroundStyle(record.status == .failed ? Color.red : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        AgentStatusTag(status: record.status)
                        if record.runs.count > 1 {
                            Text("\(record.runs.count) runs").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let name = record.agentName {
                            Text(name).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(record.isUnseen ? "Mark as Seen" : "Mark as New") { model.markSeen(record.id, record.isUnseen) }
            Button(record.isArchived == true ? "Unarchive" : "Archive") { model.setArchived(record.id, record.isArchived != true) }
            Button("Show Folder") { model.openFolder(record.id) }
        }
    }

    static func when(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

struct AgentStatusTag: View {
    let status: AgentJobStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .queued: "queued"
        case .running: "working"
        case .needsYou: "needs you"
        case .done: "done"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }

    private var color: Color {
        switch status {
        case .queued: .gray
        case .running: .blue
        case .needsYou: .orange
        case .done: .green
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

/// One job's turns: each run's ask, then what the agent said, thought and did, the files it touched, and how it ended.
struct AgentTranscriptView: View {
    let item: AgentActivityFeed.Item
    let model: AgentHUDModel
    @ViewState private var followUp = ""

    private var record: AgentJobRecord { item.record }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let turns = model.transcript(item.id)?.turns ?? []
                    if turns.isEmpty {
                        Text("No runs recorded yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(turns) { turn in
                        AgentTurnView(turn: turn, isLatest: turn.number == turns.count, record: record, model: model)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !record.status.isActive || record.status == .needsYou {
                Divider()
                HStack(spacing: 6) {
                    TextField(record.waitingStep != nil ? "Tell it you're done, or anything else…" : "Follow up…", text: $followUp)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Send", action: send).disabled(followUp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
                .padding(10)
            }
        }
    }

    private func send() {
        model.followUp(record.id, text: followUp)
        followUp = ""
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.lastReport?.title ?? record.report?.title ?? record.title).font(.title3.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            AgentStatusTag(status: record.status)
            Button { model.setArchived(record.id, record.isArchived != true) } label: {
                Image(systemName: record.isArchived == true ? "tray.and.arrow.up" : "archivebox")
            }
            .buttonStyle(.borderless)
            .help(record.isArchived == true ? "Unarchive" : "Archive")
            Button { model.openFolder(record.id) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Show the job folder")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let name = record.agentName { parts.append("kept agent \(name)") }
        parts.append(record.harness == .codex ? "Codex" : "Claude Code")
        if let model = record.model { parts.append(model) }
        parts.append(record.runs.count == 1 ? "1 run" : "\(record.runs.count) runs")
        return parts.joined(separator: " · ")
    }
}

private struct AgentTurnView: View {
    let turn: AgentTranscript.Turn
    let isLatest: Bool
    let record: AgentJobRecord
    let model: AgentHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Run \(turn.number)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(Self.time(turn.startedAt)).font(.caption).foregroundStyle(.tertiary)
                if turn.routineID != nil { Label("routine", systemImage: "calendar.badge.clock").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if let outcome = turn.outcome { Text(outcome.rawValue).font(.caption2).foregroundStyle(.secondary) }
            }
            // The ask, on the right like a chat message.
            HStack {
                Spacer(minLength: 40)
                Text(turn.ask)
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !turn.plan.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(turn.plan.enumerated()), id: \.offset) { _, step in
                        Label(step.step, systemImage: step.status == .completed ? "checkmark.circle.fill" : step.status == .inProgress ? "circle.dotted" : "circle")
                            .font(.caption)
                            .foregroundStyle(step.status == .completed ? Color.secondary : Color.primary)
                    }
                }
            }
            ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in
                stepView(step)
            }
            if let report = turn.report {
                VStack(alignment: .leading, spacing: 6) {
                    if !report.spoken.isEmpty {
                        Text(report.spoken).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    }
                    if let answer = report.answer, let outcome = answer.outcome, outcome != report.spoken {
                        Text(outcome).font(.callout).foregroundStyle(.secondary)
                    }
                    if !report.markdown.isEmpty {
                        Text(Self.inline(AgentText.shorten(report.markdown, limit: 1_200)))
                            .font(.callout).foregroundStyle(.primary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !turn.files.isEmpty {
                        ForEach(turn.files.prefix(8), id: \.path) { file in
                            Button { model.open(file.path) } label: {
                                Label("\(URL(fileURLWithPath: file.path).lastPathComponent) · \(file.change)", systemImage: "doc")
                            }
                            .buttonStyle(.link).font(.caption)
                        }
                    }
                    if let question = report.question {
                        Label(question, systemImage: "questionmark.circle").font(.callout).foregroundStyle(.orange)
                    }
                    if let step = report.waitFor {
                        HStack {
                            Label(step.step, systemImage: "hand.point.right").font(.callout).foregroundStyle(.orange)
                            Spacer()
                            if isLatest, record.waitingStep != nil {
                                Button("I'm done") { model.continueStep(record.id) }.controlSize(.small)
                            }
                        }
                    }
                    if !turn.suggestedNext.isEmpty {
                        ChipFlow(spacing: 6) {
                            ForEach(turn.suggestedNext.prefix(3), id: \.self) { next in
                                Button { model.followUp(record.id, text: next) } label: {
                                    Label(next, systemImage: "arrow.turn.down.right").font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(!isLatest || record.status.isActive && record.status != .needsYou)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let error = turn.error {
                Label(AgentText.firstLine(error, limit: 300), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            } else if isLatest, record.status.isActive {
                Label(record.lastProgress ?? "Working…", systemImage: "ellipsis").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func stepView(_ step: AgentTranscript.Step) -> some View {
        switch step.kind {
        case .message:
            Text(Self.inline(step.text)).font(.callout).fixedSize(horizontal: false, vertical: true)
        case .thinking:
            Label(step.text, systemImage: "brain").font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
        case .tool:
            Label(step.text, systemImage: "terminal").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
        case .file:
            Label(step.text, systemImage: "doc.badge.plus").font(.caption).foregroundStyle(.secondary)
        case .approval:
            Label(step.text, systemImage: "hand.raised").font(.caption).foregroundStyle(.orange)
        case .error:
            Label(step.text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(3)
        case .note:
            Text(step.text).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }
}
