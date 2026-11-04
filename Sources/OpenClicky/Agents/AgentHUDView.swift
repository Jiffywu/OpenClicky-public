import OpenClickyKit
import SwiftUI

/// The agent HUD: background jobs and kept agents with live progress, what each is waiting on, and its result.
struct AgentHUDView: View {
    let model: AgentHUDModel
    var maxRows = 8
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.panelItems.isEmpty {
                Text("No background jobs yet. Ask OpenClicky to research, write or build something and it runs here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.panelItems.prefix(maxRows)) { item in
                    AgentJobRow(item: item, model: model)
                    if item.id != model.panelItems.prefix(maxRows).last?.id { Divider().opacity(0.4) }
                }
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .foregroundStyle(.secondary)
            Text("Agents").font(.headline)
            Spacer()
            let working = model.feed.active.count - model.feed.needsYouCount
            if model.feed.needsYouCount > 0 {
                AgentBadge(text: "\(model.feed.needsYouCount) need\(model.feed.needsYouCount == 1 ? "s" : "") you", color: .orange)
            }
            if working > 0 {
                AgentBadge(text: "\(working) working", color: .blue)
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").padding(5).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Background Jobs")
                .help("Hide this panel. Background jobs keep running.")
            }
        }
    }
}

private struct AgentJobRow: View {
    let item: AgentActivityFeed.Item
    let model: AgentHUDModel
    @ViewState private var reply = ""

    private var record: AgentJobRecord { item.record }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AgentStatusDot(status: record.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.lastReport?.title ?? record.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if record.status.isActive {
                    Text(model.elapsed(item))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text(item.headline)
                .font(.callout)
                .foregroundStyle(record.status == .failed ? Color.red : Color.primary.opacity(0.85))
                .lineLimit(record.status.isActive ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)

            if let progress = item.planProgress, record.status.isActive {
                AgentPlanBar(fraction: progress)
                if let index = item.plan.firstIndex(where: { $0.status == .inProgress }) {
                    Text("Step \(index + 1) of \(item.plan.count) · \(item.plan[index].step)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            let earlier = item.lines.dropLast().filter { !$0.hasPrefix("Working on: ") }.suffix(3)
            if record.status == .running, !earlier.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(earlier.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }

            actions
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let name = record.agentName { parts.append("kept agent \(name)") }
        parts.append(record.harness == .codex ? "Codex" : "Claude Code")
        if let model = record.model { parts.append(model) }
        if record.provider == AgentLaunchSettings.loginProviderID { parts.append("own sign-in") }
        if record.runs.count > 1 { parts.append("run \(record.runs.count)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        if let request = record.pendingRequest {
            VStack(alignment: .leading, spacing: 6) {
                if let reason = request.reason {
                    if request.kind == .browserAction {
                        ScrollView {
                            Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                    } else {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                if request.kind == .question {
                    if let options = request.options {
                        HStack { ForEach(options, id: \.self) { option in Button(option) { model.reply(record.id, text: option) } } }
                            .controlSize(.small)
                    }
                    replyField
                } else {
                    HStack(spacing: 8) {
                        if request.kind == .browserAction {
                            Button("Allow this action") { model.approve(record.id) }
                        } else {
                            Button("Allow") { model.approve(record.id) }.keyboardShortcut(.defaultAction)
                            Button("Always allow") { model.approve(record.id, always: true) }
                        }
                        Button("Don't allow", role: .destructive) { model.decline(record.id) }
                    }
                    .controlSize(.small)
                }
            }
        } else if record.status == .needsYou, let step = record.waitingStep {
            HStack(spacing: 8) {
                Text(step.page ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("I'm done") { model.continueStep(record.id) }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        } else if record.status == .needsYou, record.report?.question != nil {
            replyField
        } else if record.status == .running || record.status == .queued {
            HStack {
                Spacer()
                Button("Stop") { model.interrupt(record.id) }.controlSize(.small)
            }
        } else {
            let files = item.lastReport?.files ?? []
            HStack(spacing: 6) {
                ForEach(files.prefix(3), id: \.self) { file in
                    Button { model.open(file) } label: {
                        Label(Self.name(of: file), systemImage: Self.icon(for: file)).lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                Button { model.openFolder(record.id) } label: {
                    Image(systemName: "folder").foregroundStyle(.secondary).padding(4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the job folder")
            }
            .controlSize(.small)
        }
    }

    private var replyField: some View {
        HStack(spacing: 6) {
            TextField("Answer…", text: $reply)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            Button("Send", action: send).disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
    }

    private func send() {
        model.reply(record.id, text: reply)
        reply = ""
    }

    static func name(of file: String) -> String {
        if let url = URL(string: file), url.scheme?.hasPrefix("http") == true { return url.host ?? file }
        return URL(fileURLWithPath: file).lastPathComponent
    }

    static func icon(for file: String) -> String {
        if file.hasPrefix("http") { return "link" }
        switch URL(fileURLWithPath: file).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "csv", "xlsx", "numbers": return "tablecells"
        case "md", "txt", "rtf", "docx", "pages": return "doc.text"
        case "html", "htm": return "globe"
        case "swift", "py", "js", "ts", "sh", "json": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

/// How much of the agent's plan is done. Drawn in SwiftUI so it looks the same in the panel and in snapshots.
private struct AgentPlanBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(Color.blue).frame(width: max(6, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel(Text("Plan \(Int(fraction * 100)) percent done"))
    }
}

private struct AgentStatusDot: View {
    let status: AgentJobStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: status == .running ? 3 : 0).scaleEffect(1.8))
            .accessibilityLabel(Text(status.rawValue))
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

private struct AgentBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
