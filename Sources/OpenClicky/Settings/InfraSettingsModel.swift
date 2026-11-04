import AppKit
import Observation
import OpenClickyKit

/// State behind Settings → Usage and Settings → Developer: the usage ledger and its limits, the feature flags, the
/// brain session's stats, provider checks and the diagnostics bundle behind "Report a Bug" (docs/infra.md).
@MainActor
@Observable
final class InfraSettingsModel {
    enum Window: Int, CaseIterable, Identifiable {
        case today = 1, week = 7, month = 30
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .today: "Today"
            case .week: "7 days"
            case .month: "30 days"
            }
        }
    }

    struct ProviderCheck: Identifiable, Hashable {
        var id: String { slot.rawValue }
        var slot: SlotID
        var provider: String
        var verdict: ProviderVerdict?
        var line: String
    }

    @ObservationIgnored let ledger: UsageLedger
    @ObservationIgnored let flags: FeatureFlagStore
    @ObservationIgnored private let model: AppModel
    var window: Window = .week { didSet { reload() } }
    private(set) var summary: UsageSummary
    private(set) var limits: UsageLimits
    private(set) var status: UsageLimitStatus = .unlimited
    private(set) var spentToday = 0.0
    private(set) var spentMonth = 0.0
    /// Shown in the menu and on the Usage page when spending nears or passes a limit.
    private(set) var warning: String?
    private(set) var flagValues: [String: Bool] = [:]
    private(set) var brainStats: BrainSessionStats?
    private(set) var checks: [ProviderCheck] = []
    private(set) var checking = false
    private(set) var reportState: String?
    private(set) var busy = false
    private(set) var message: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Says each limit crossing once (a notification and a notch event).
    @ObservationIgnored private var alerter = UsageLimitAlerter()
    /// Called once for each limit crossing as records arrive.
    @ObservationIgnored var limitAlertHandlers: [(UsageLimitAlert) -> Void] = []

    /// - Parameters:
    ///   - ledger: The folder the app's engines write to (the installed `ProviderResilience`'s ledger in the live app).
    ///   - flags: flags.json.
    init(model: AppModel, ledger: UsageLedger = UsageLedger(), flags: FeatureFlagStore = FeatureFlagStore()) {
        self.model = model
        self.ledger = ledger
        self.flags = flags
        summary = UsageSummary(records: [], from: Date(), to: Date())
        limits = ledger.limits()
        reload()
        alerter.seed(status, now: Date())
    }

    /// Follows records as the running app writes them: the warning updates, and an open Usage page refreshes.
    func follow(_ live: UsageLedger) {
        live.onRecord = { [weak self] _, status in
            Task { @MainActor in self?.recordArrived(status) }
        }
    }

    private func recordArrived(_ status: UsageLimitStatus) {
        self.status = status
        warning = status.message
        if let alert = alerter.observe(status, now: Date()) {
            for handler in limitAlertHandlers { handler(alert) }
        }
        // Many records arrive in a turn; refresh at most every couple of seconds.
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.refreshTask = nil
            self?.reload()
        }
    }

    // MARK: Usage

    func reload() {
        summary = ledger.summary(days: window.rawValue)
        limits = ledger.limits()
        status = ledger.limitStatus()
        warning = status.message
        (spentToday, spentMonth) = ledger.spending()
        flagValues = Dictionary(uniqueKeysWithValues: flags.snapshot().map { ($0.flag.id, $0.value) })
    }

    func setLimits(daily: Double?, monthly: Double?, stop: Bool, warnAt: Double) {
        do {
            try ledger.setLimits(UsageLimits(dailyUSD: daily.flatMap { $0 > 0 ? $0 : nil }, monthlyUSD: monthly.flatMap { $0 > 0 ? $0 : nil },
                                             warnAtFraction: warnAt, stopAtLimit: stop))
            message = "Limits saved."
        } catch {
            message = "Couldn't save the limits: \(error.localizedDescription)"
        }
        reload()
    }

    func revealLedger() {
        try? FileManager.default.createDirectory(at: ledger.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([ledger.directory])
    }

    // MARK: Flags

    func isOn(_ flag: FeatureFlag) -> Bool { flagValues[flag.id] ?? flag.defaultValue }

    /// A flag was switched in Settings → Developer (the voice loop shows or hides the floating latency stats).
    @ObservationIgnored var onFlagChange: ((FeatureFlag) -> Void)?

    func set(_ flag: FeatureFlag, _ value: Bool) {
        do {
            try flags.set(flag, value)
            if ProviderResilience.flagsRead.contains(flag) { refreshResilience() }
            message = flag.readBy == nil ? "Saved. Nothing reads \(flag.title.lowercased()) yet." :
                "Saved. \(flag.title) applies to engines built from now on."
        } catch {
            message = "Couldn't save the flag: \(error.localizedDescription)"
        }
        reload()
        onFlagChange?(flag)
    }

    func resetFlags() {
        try? flags.reset()
        refreshResilience()
        reload()
    }

    /// Retries, diagnosis and the ledger are read when the app installs its `ProviderResilience`; install it again so
    /// engines built from now on follow the flags as they are now.
    private func refreshResilience() {
        guard let current = ProviderResilience.installed else { return }
        let next = current.refreshed(flags: flags)
        ProviderResilience.install(next)
        if let live = next.recorder as? UsageLedger { follow(live) }
    }

    // MARK: Brain

    /// The runtime the relay holds now. Reading its stats needs no reservation; ending its session goes through the
    /// relay, which keeps the runtime from being replaced until that finishes.
    private var brain: BrainRuntime? { model.voiceLoop?.brainRelay.brain as? BrainRuntime }

    var hasBrain: Bool { brain != nil }

    func loadBrainStats() {
        guard let brain else { return }
        Task { [weak self] in
            let stats = await brain.stats
            self?.brainStats = stats
        }
    }

    /// Ends the brain's session (its memory notes are written) so the next turn starts a fresh thread.
    func startFreshSession() {
        guard brain != nil, let relay = model.voiceLoop?.brainRelay else {
            message = "The brain isn't running yet; the first turn starts a fresh session anyway."
            return
        }
        busy = true
        Task { [weak self] in
            await relay.endSession()
            let stats = await (relay.brain as? BrainRuntime)?.stats
            self?.brainStats = stats
            self?.busy = false
            self?.message = "Started a fresh brain session."
        }
    }

    // MARK: Providers

    /// Probes each network slot's provider (its models list) and words what came back.
    func checkProviders() {
        let config = model.config
        let credentials = model.credentials
        checking = true
        checks = []
        Task { [weak self] in
            var results: [ProviderCheck] = []
            let probe = ProviderProbe()
            for slot in SlotID.allCases {
                guard let selection = config.selection(for: slot), let provider = config.provider(selection.provider) else { continue }
                guard ProviderProbe.probeURL(for: provider) != nil else {
                    results.append(ProviderCheck(slot: slot, provider: provider.id, verdict: .onDevice, line: "Runs on this Mac."))
                    continue
                }
                let key = provider.credential.flatMap { try? credentials.secret(named: $0) }
                guard let result = await probe.probe(provider, apiKey: key) else { continue }
                var verdict = ProviderProbe.classify(result)
                if key == nil, verdict == .keyRejected { verdict = .reachable }
                let diagnosis = ProviderDiagnosis(providerID: provider.id,
                                                  providerName: ProviderProbe.displayName(host: result.url.host ?? "", providerID: provider.id),
                                                  host: result.url.host ?? provider.id, purpose: .init(slot: slot), verdict: verdict,
                                                  probe: result.summary, failure: "check")
                results.append(ProviderCheck(slot: slot, provider: provider.id, verdict: verdict,
                                             line: verdict == .reachable ? "Reachable (\(result.summary))." : diagnosis.explanation))
            }
            self?.checks = results
            self?.checking = false
        }
    }

    // MARK: Diagnostics

    /// Writes a scrubbed diagnostics bundle and shows it in Finder; with `openIssue`, also opens a prefilled bug
    /// report to attach it to.
    func makeDiagnostics(note: String, openIssue: Bool) {
        busy = true
        reportState = "Collecting diagnostics…"
        Task { [weak self] in
            guard let inputs = await self?.diagnosticsInputs(note: note) else { return }
            let result = await Task.detached { Result { try DiagnosticsBundle.write(inputs) } }.value
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let report):
                self.reportState = "Saved \(report.zip?.lastPathComponent ?? report.folder.lastPathComponent)"
                    + (report.logTimedOut ? " (the log took too long and was cut short)." : ".")
                NSWorkspace.shared.activateFileViewerSelecting([report.zip ?? report.folder])
                if openIssue, let url = DiagnosticsBundle.issueURL(summary: report.summary) { NSWorkspace.shared.open(url) }
            case .failure(let error):
                self.reportState = "Couldn't write diagnostics: \(error.localizedDescription)"
            }
        }
    }

    /// What the diagnostics bundle is written from: the app's state, config, credential states, flags, usage and
    /// the brain session's stats.
    func diagnosticsInputs(note: String) async -> DiagnosticsInputs {
        let config = model.config
        let credentials = DiagnosticsInputs.credentialStates(config: config, store: model.credentials)
        var state: [String: JSONValue] = [
            "turnPhase": .string(String(describing: model.turn.phase)),
            "alwaysOn": .bool(model.alwaysOn.isActive),
            "configIssues": .array(model.issues.map { .string($0.message) }),
            "permissions": .object(Dictionary(uniqueKeysWithValues: PermissionsCenter.Permission.allCases.map {
                ($0.title, JSONValue.string(String(describing: model.permissions.states[$0] ?? .notDetermined)))
            })),
        ]
        if let timings = model.lastTimings { state["lastTimings"] = .string(timings.report()) }
        let stats = await brain?.stats
        return DiagnosticsInputs(client: "OpenClicky", appState: state, config: config, credentials: credentials, flags: flags,
                                 usage: ledger, brainStats: stats, note: note)
    }
}

extension InfraSettingsModel {
    /// Evidence renders: fixed provider checks and brain stats, without a probe or a running brain.
    func showFixture(checks: [ProviderCheck], brainStats: BrainSessionStats?, reportState: String? = nil) {
        self.checks = checks
        self.brainStats = brainStats
        self.reportState = reportState
    }
}
