import AppKit
import OpenClickyKit
import SwiftUI

// Settings → Usage and Settings → Developer (docs/infra.md), plus the "Report a Bug" row for General.

struct UsageSettingsPage: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        let infra = services.infra
        let summary = infra.summary
        Form {
            if let warning = infra.warning {
                Section {
                    Label(warning, systemImage: infra.status.level == .reached ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(infra.status.level == .reached ? .red : .orange)
                }
            }
            Section {
                Picker("Period", selection: Binding(get: { infra.window }, set: { infra.window = $0 })) {
                    ForEach(InfraSettingsModel.Window.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    UsageFigure(title: "Spent", value: UsageFormat.cost(summary.total))
                    UsageFigure(title: "Calls", value: "\(summary.total.records)")
                    UsageFigure(title: "Tokens in / out",
                                value: "\(UsageFormat.tokens(summary.total.inputTokens)) / \(UsageFormat.tokens(summary.total.outputTokens))")
                    UsageFigure(title: "Audio", value: String(format: "%.0f s", summary.total.audioSeconds))
                }
                .padding(.vertical, 4)
                if summary.total.unpriced > 0 {
                    Text("\(summary.total.unpriced) call\(summary.total.unpriced == 1 ? " has" : "s have") no known price, so the total leaves them out (marked +). ≈ marks estimated prices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Usage on this Mac")
            }
            UsageTable(title: "By slot", rows: summary.bySlot)
            UsageTable(title: "By surface", rows: summary.bySurface)
            UsageTable(title: "By provider and model", rows: summary.byModel)
            UsageTable(title: "Background jobs", rows: summary.byJob)
            if !summary.recentTurns.isEmpty {
                Section("Recent turns") {
                    ForEach(summary.recentTurns.prefix(8), id: \.turn) { turn in
                        HStack {
                            Text(turn.at, format: .dateTime.month(.abbreviated).day().hour().minute()).foregroundStyle(.secondary)
                            Text(turn.surface)
                            Spacer()
                            Text("\(turn.totals.records) calls").foregroundStyle(.secondary)
                            Text(UsageFormat.cost(turn.totals)).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                }
            }
            UsageLimitsSection(infra: infra)
            Section {
                HStack {
                    Button("Refresh") { infra.reload() }
                    Button("Show Ledger in Finder") { infra.revealLedger() }
                    Spacer()
                }
                Text("Each call is one line in \(infra.ledger.directory.path), kept on this Mac only. Prices come from the model catalog or your own model declarations; occtl usage shows the same figures.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { infra.reload() }
    }
}

private struct UsageFigure: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}

private struct UsageTable: View {
    let title: String
    let rows: [String: UsageTotals]

    var body: some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows.sorted { $0.value.costUSD > $1.value.costUSD || ($0.value.costUSD == $1.value.costUSD && $0.key < $1.key) },
                        id: \.key) { key, totals in
                    HStack {
                        Text(key)
                        Spacer()
                        Text(detail(totals)).foregroundStyle(.secondary).font(.caption)
                        Text(UsageFormat.cost(totals)).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func detail(_ totals: UsageTotals) -> String {
        var parts = ["\(totals.records) call\(totals.records == 1 ? "" : "s")"]
        if totals.inputTokens + totals.outputTokens > 0 {
            parts.append("\(UsageFormat.tokens(totals.inputTokens)) in, \(UsageFormat.tokens(totals.outputTokens)) out")
        }
        if totals.audioSeconds > 0 { parts.append(String(format: "%.0f s audio", totals.audioSeconds)) }
        if totals.characters > 0 { parts.append("\(totals.characters) characters") }
        return parts.joined(separator: " · ")
    }
}

private struct UsageLimitsSection: View {
    let infra: InfraSettingsModel
    @ViewState private var daily = ""
    @ViewState private var monthly = ""
    @ViewState private var stop = false
    @ViewState private var warnAt = 0.8
    /// Why the last Save Limits saved nothing (an amount that couldn't be read).
    @ViewState private var problem: String?

    var body: some View {
        Section {
            LabeledContent("Spent today") { Text(UsageFormat.dollars(infra.spentToday)).monospacedDigit() }
            LabeledContent("Spent this month") { Text(UsageFormat.dollars(infra.spentMonth)).monospacedDigit() }
            HStack {
                TextField("Daily limit", text: $daily, prompt: Text("No daily limit"))
                Text("$ a day").foregroundStyle(.secondary)
            }
            HStack {
                TextField("Monthly limit", text: $monthly, prompt: Text("No monthly limit"))
                Text("$ a month").foregroundStyle(.secondary)
            }
            Picker("Warn at", selection: $warnAt) {
                ForEach([0.5, 0.8, 0.9], id: \.self) { Text("\(Int($0 * 100))% of a limit").tag($0) }
            }
            Toggle("Stop paid calls at the limit (otherwise only warn)", isOn: $stop)
            HStack {
                Spacer()
                Button("Save Limits") { save() }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if let message = infra.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Limits")
        } footer: {
            Text("Limits count every priced call on this Mac, from the app and from occtl. At a stopping limit the brain, the voice and listening answer that the limit is reached instead of calling the provider.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: load)
    }

    private func load() {
        daily = infra.limits.dailyUSD.map { String(format: "%.2f", $0) } ?? ""
        monthly = infra.limits.monthlyUSD.map { String(format: "%.2f", $0) } ?? ""
        stop = infra.limits.stopAtLimit
        warnAt = [0.5, 0.8, 0.9].min { abs($0 - infra.limits.warnAtFraction) < abs($1 - infra.limits.warnAtFraction) } ?? 0.8
    }

    private func save() {
        guard case .readable(let dailyUSD) = UsageLimitAmount(daily) else {
            problem = UsageLimitAmount.problem(daily, field: "daily")
            return
        }
        guard case .readable(let monthlyUSD) = UsageLimitAmount(monthly) else {
            problem = UsageLimitAmount.problem(monthly, field: "monthly")
            return
        }
        problem = nil
        infra.setLimits(daily: dailyUSD, monthly: monthlyUSD, stop: stop, warnAt: warnAt)
        // Show what was saved, so the fields never disagree with the limits in force.
        load()
    }
}

/// A dollar amount typed into a limit field. Empty means no limit. Accepts a "$", a decimal point or a decimal comma
/// ("2.50", "2,50") and thousands separators ("1,000", "1.000,50"); anything else is unreadable, and nothing is saved
/// rather than quietly turning the limit off.
enum UsageLimitAmount: Equatable {
    /// nil: no limit.
    case readable(Double?)
    case unreadable

    /// - Parameter groupingSeparator: the locale's thousands separator. A single "," or "." followed by exactly three
    ///   digits is read as thousands only when it is this one ("1,000" in the US, "1.000" in Germany).
    init(_ text: String, groupingSeparator: String = Locale.current.groupingSeparator ?? ",") {
        let trimmed = text.replacingOccurrences(of: "$", with: "").filter { !$0.isWhitespace }
        guard !trimmed.isEmpty else { self = .readable(nil); return }
        guard trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "," || $0 == ".") }), trimmed.contains(where: \.isNumber) else {
            self = .unreadable
            return
        }
        let separators = trimmed.filter { $0 == "," || $0 == "." }
        var normalized = trimmed
        if let last = separators.last {
            let grouping: Character = last == "," ? "." : ","
            if separators.contains(grouping) {
                // Both kinds: the last one is the decimal separator, and it may appear only once.
                guard separators.filter({ $0 == last }).count == 1 else { self = .unreadable; return }
                normalized = trimmed.filter { $0 != grouping }
            } else if separators.count > 1 {
                normalized = trimmed.filter { $0 != last }
            } else {
                let after = trimmed.split(separator: last, omittingEmptySubsequences: false).last ?? ""
                if after.count == 3, String(last) == groupingSeparator, trimmed.first != last {
                    normalized = trimmed.filter { $0 != last }
                }
            }
            normalized = normalized.replacingOccurrences(of: ",", with: ".")
        }
        guard let value = Double(normalized), value.isFinite else { self = .unreadable; return }
        self = .readable(value)
    }

    static func problem(_ text: String, field: String) -> String {
        "Couldn't read the \(field) limit \"\(text)\". Type an amount such as 2.50, or leave it empty for no limit. Nothing was saved."
    }
}

struct DeveloperSettingsPage: View {
    @Environment(HomeServices.self) private var services
    @ViewState private var showKeys = false

    var body: some View {
        let infra = services.infra
        Form {
            if infra.isOn(.brainStats) {
                Section {
                    if let stats = infra.brainStats {
                        LabeledContent("Session") { Text(stats.sessionID.prefix(8) + "…").font(.system(.body, design: .monospaced)) }
                        LabeledContent("Started") { Text(stats.startedAt, format: .dateTime.hour().minute().second()) }
                        LabeledContent("Turns") { Text("\(stats.turns)") }
                        LabeledContent("Thread items") { Text("\(stats.threadItems) (\(stats.screenshotsInThread) screenshots)") }
                        LabeledContent("Last request") { Text("\(UsageFormat.tokens(stats.lastInputTokens)) input tokens") }
                        LabeledContent("Compactions") { Text("\(stats.compactions); next check at \(UsageFormat.tokens(stats.nextCompactionCheck))") }
                    } else {
                        Text(infra.hasBrain ? "Loading…" : "The brain starts with the first turn.").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Start a Fresh Session") { infra.startFreshSession() }.disabled(infra.busy)
                        Button("Refresh") { infra.loadBrainStats() }
                        Spacer()
                    }
                } header: {
                    Text("Brain")
                } footer: {
                    Text("A fresh session ends the current thread (its memory notes are written) so the next question starts clean.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(infra.checks) { check in
                    HStack(alignment: .top) {
                        Image(systemName: icon(check.verdict)).foregroundStyle(color(check.verdict))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(check.slot.rawValue) · \(check.provider)").font(.callout.weight(.medium))
                            Text(check.line).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button(infra.checking ? "Checking…" : "Check Providers") { infra.checkProviders() }.disabled(infra.checking)
                    Spacer()
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Asks each provider's models list (free) to see whether it is reachable from this Mac and network. The same check runs by itself when a voice, listening or always-on session can't open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ReportBugSection()
            ForEach(FeatureFlag.Group.allCases, id: \.self) { group in
                let flags = FeatureFlag.developerSwitches.filter { $0.group == group }
                if !flags.isEmpty {
                    Section(group.title) {
                        ForEach(flags) { flag in
                            Toggle(isOn: Binding(get: { infra.isOn(flag) }, set: { infra.set(flag, $0) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(flag.title)
                                    Text(flag.summary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            // Flags for features OpenClicky hasn't built: shown so the choice is visible, not offered as switches.
            Section {
                ForEach(FeatureFlag.notBuilt) { flag in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(flag.title).foregroundStyle(.secondary)
                            Text(flag.summary).font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text("feature not built yet").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            } header: {
                Text("Not built yet")
            } footer: {
                Text("These stand in for HeyClicky switches whose features OpenClicky doesn't have yet. They become switches when the feature lands.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("HeyClicky's Clicky* keys (\(HeyClickyFlagKeys.all.count))", isExpanded: $showKeys) {
                    ForEach(HeyClickyFlagKeys.all) { key in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(key.key).font(.system(.caption, design: .monospaced))
                            Text(disposition(key.disposition)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Reset Flags to Defaults") { infra.resetFlags() }
                    Spacer()
                }
                if let message = infra.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Flags live in \(infra.flags.url?.path ?? "memory"); occtl flags reads and changes the same file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            infra.reload()
            infra.loadBrainStats()
        }
    }

    private func disposition(_ disposition: HeyClickyFlagKey.Disposition) -> String {
        switch disposition {
        case .flag(let id): "Covered by the flag \(id)"
        case .setting(let place): "Covered by \(place)"
        case .dropped(let why): "Dropped: \(why)"
        }
    }

    private func icon(_ verdict: ProviderVerdict?) -> String {
        switch verdict {
        case .reachable, .onDevice: "checkmark.circle.fill"
        case .rateLimited, .providerDown, .noAnswer, .unknown, nil: "exclamationmark.triangle.fill"
        default: "xmark.octagon.fill"
        }
    }

    private func color(_ verdict: ProviderVerdict?) -> Color {
        switch verdict {
        case .reachable, .onDevice: .green
        case .rateLimited, .providerDown, .noAnswer, .unknown, nil: .orange
        default: .red
        }
    }
}

/// "Report a Bug": a scrubbed diagnostics bundle saved on this Mac, shown in Finder, with a prefilled report to attach
/// it to. Used on the Developer page and on General.
struct ReportBugSection: View {
    @Environment(HomeServices.self) private var services
    @ViewState private var note = ""

    var body: some View {
        let infra = services.infra
        Section {
            TextField("What happened? (optional)", text: $note, axis: .vertical).lineLimit(2...4)
            HStack {
                Button("Report a Bug…") { infra.makeDiagnostics(note: note, openIssue: true) }.disabled(infra.busy)
                Button("Save Diagnostics Only") { infra.makeDiagnostics(note: note, openIssue: false) }.disabled(infra.busy)
                Spacer()
                if infra.busy { ProgressView().controlSize(.small) }
            }
            if let state = infra.reportState { Text(state).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Report a bug")
        } footer: {
            Text("Collects app state, your settings without keys, recent OpenClicky logs, displays and where the app is installed into a zip on this Mac, with keys, tokens and what you said or typed scrubbed out. Nothing is sent anywhere; attach the zip to the report yourself.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
