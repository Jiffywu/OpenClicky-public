import AppKit
import OpenClickyKit
import SwiftUI

/// The structured part of a result card (`<answer>`): up to two blocks of numbers, a short list, receipts for what
/// was done, a draft to copy, or choices to tap, plus the answer's note and link.
struct AgentAnswerSection: View {
    let answer: AgentAnswer
    let model: AgentResultCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if answer.quiet == true, answer.blocks.isEmpty {
                Label("Nothing new since the last run", systemImage: "moon.zzz")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(answer.blocks, id: \.self) { block in
                switch block {
                case .numbers: numbers
                case .list: list
                case .done: receipts
                case .draft: draft
                case .ask: choices
                }
            }
            if let note = answer.note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let next = answer.next {
                Button {
                    if let url = URL(string: next.open), url.scheme != nil { NSWorkspace.shared.open(url) }
                    else { NSWorkspace.shared.open(URL(fileURLWithPath: next.open)) }
                } label: {
                    Label(next.label, systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }

    // MARK: Numbers

    @ViewBuilder private var numbers: some View {
        let items = answer.numbers ?? []
        switch answer.numbersLook {
        case .hero?:
            if let number = items.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(number.value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(number.label).font(.callout).foregroundStyle(.secondary)
                }
            }
        case .progress?:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, number in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(number.label).font(.callout)
                            Spacer()
                            Text("\(number.value) of \(number.of ?? "?")").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Self.fraction(number)).tint(.accentColor)
                    }
                }
            }
        default:
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, number in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(number.value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(number.label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let was = number.was {
                            Label("was \(was)", systemImage: Self.trendSymbol(number))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Self.trendColor(number))
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    static func fraction(_ number: AgentAnswer.Number) -> Double {
        guard let value = Self.numeric(number.value), let total = number.of.flatMap(Self.numeric), total > 0 else { return 0 }
        return min(1, max(0, value / total))
    }

    static func numeric(_ text: String) -> Double? {
        Double(text.filter { $0.isNumber || $0 == "." || $0 == "-" })
    }

    static func trendSymbol(_ number: AgentAnswer.Number) -> String {
        guard let now = numeric(number.value), let before = number.was.flatMap(numeric) else { return "arrow.left.arrow.right" }
        return now > before ? "arrow.up.right" : now < before ? "arrow.down.right" : "equal"
    }

    static func trendColor(_ number: AgentAnswer.Number) -> Color {
        guard let better = number.better, let now = numeric(number.value), let before = number.was.flatMap(numeric), now != before else {
            return .secondary
        }
        return (now > before) == (better == .higher) ? .green : .red
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array((answer.list ?? []).enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if answer.ranked == true {
                        Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(index == 0 ? Color.accentColor : .secondary)
                            .frame(width: 16)
                    } else {
                        Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary).frame(width: 16)
                    }
                    Text(item.text).font(.callout.weight(answer.ranked == true && index == 0 ? .semibold : .regular))
                    Spacer(minLength: 4)
                    if let detail = item.detail {
                        Text(detail).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Done

    private var receipts: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array((answer.done ?? []).enumerated()), id: \.offset) { _, receipt in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    (Text(receipt.did).fontWeight(.semibold) + Text(" " + receipt.what))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let link = receipt.link {
                        Button {
                            if link.hasPrefix("/") { NSWorkspace.shared.open(URL(fileURLWithPath: link)) }
                            else if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                        } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Draft

    @ViewBuilder private var draft: some View {
        if let draft = answer.draft {
            VStack(alignment: .leading, spacing: 6) {
                if let to = draft.to {
                    Text("To \(to)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(draft.text)
                    .font(.callout)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button { model.copy(draft.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .controlSize(.small)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: 3).padding(.vertical, 6) }
        }
    }

    // MARK: Ask

    private var choices: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array((answer.ask ?? []).enumerated()), id: \.offset) { _, choice in
                let picked = model.sent.contains(choice.reply)
                Button { model.choose(choice) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: picked ? "checkmark.circle.fill" : (choice.file != nil ? "doc" : "circle"))
                            .foregroundStyle(picked ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(choice.answer ?? choice.file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "").font(.callout.weight(.medium))
                            if let detail = choice.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(picked ? 0.2 : 0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(picked || model.pending.contains(choice.reply))
            }
        }
    }
}

/// What a needs-you card asks for besides a question: a step only the user can do ("I'm done"), or routines the
/// agent wants to set up (Set up / Not now).
struct AgentCardRequestSection: View {
    let card: AgentResultCard
    let model: AgentResultCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let step = card.userStep {
                Label(step.step, systemImage: "hand.point.right")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let page = step.page {
                    if let url = URL(string: page), url.scheme?.hasPrefix("http") == true {
                        Button(page) { NSWorkspace.shared.open(url) }.buttonStyle(.link).font(.caption).lineLimit(1)
                    } else {
                        Text(page).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Skip", role: .destructive) { model.respond(.decline, to: .step, done: "Skipped. The job won't wait for it.") }
                    Button("I'm done") { model.respond(.approve(always: false), to: .step, done: "Thanks. It's carrying on.") }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
                .disabled(model.responded.contains(.step))
            }
            ForEach(Array(card.routineProposals.enumerated()), id: \.offset) { _, proposal in
                Label(proposal.summary, systemImage: "calendar.badge.clock")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.routineProposals.isEmpty {
                HStack {
                    Spacer()
                    Button("Not now") { model.respond(.decline, to: .routines, done: "No routine was set up.") }
                    Button(card.routineProposals.count == 1 ? "Set it up" : "Set them up") {
                        model.respond(.approve(always: false), to: .routines, done: "Done. It's in Settings → Routines.")
                    }
                    .keyboardShortcut(card.userStep == nil ? .defaultAction : nil)
                }
                .controlSize(.small)
                .disabled(model.responded.contains(.routines))
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
