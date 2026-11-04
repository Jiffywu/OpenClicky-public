import AppKit
import OpenClickyKit
import SwiftUI

/// Fixtures and extra renders for Settings → Usage and Developer in `--render-snapshots`.
@MainActor
enum InfraSnapshots {
    /// A fixture ledger: three voice turns, a typed turn, always-on replies, dictation and lookups over the last days.
    static func writeUsage(into directory: URL, now: Date) {
        let ledger = UsageLedger(directory: directory, now: { now })
        let book = PriceBook.builtIn()
        func add(_ slot: SlotID?, _ surface: UsageSurface, _ provider: String, _ model: String, _ measure: UsageMeasure, ago: TimeInterval,
                 turn: String? = nil, dialect: ProviderDialect? = nil) {
            let price = slot == nil ? book.servicePrice(provider) : book.price(model: model, dialect: dialect)
            ledger.record(UsageRecord(at: now.addingTimeInterval(-ago), slot: slot?.rawValue ?? UsageRecord.lookupsSlot, surface: surface.rawValue,
                                      provider: provider, model: model, turn: turn, client: "app", measure: measure,
                                      costUSD: price?.cost(of: measure), estimate: price?.estimate))
        }
        for (index, ago) in [600.0, 3_000, 7_200].enumerated() {
            let turn = "fixture-turn-\(index)"
            add(.stt, .voiceTurn, "apple-speech", "on-device", UsageMeasure(audioSeconds: 3.4), ago: ago, turn: turn, dialect: .appleSpeech)
            add(.brain, .voiceTurn, "anthropic", "claude-haiku-5-5", UsageMeasure(inputTokens: 13_800, cachedInputTokens: 12_100, outputTokens: 420),
                ago: ago - 2, turn: turn, dialect: .anthropicMessages)
            add(.voice, .voiceTurn, "elevenlabs", "eleven_flash_v2_5", UsageMeasure(audioSeconds: 6.1, characters: 96), ago: ago - 4, turn: turn,
                dialect: .elevenLabsSpeech)
        }
        add(nil, .voiceTurn, "brave", "web-search", UsageMeasure(requests: 1), ago: 3_001, turn: "fixture-turn-1")
        add(.brain, .typedTurn, "anthropic", "claude-haiku-5-5", UsageMeasure(inputTokens: 9_200, cachedInputTokens: 8_000, outputTokens: 310),
            ago: 20_000, turn: "fixture-typed", dialect: .anthropicMessages)
        add(.brainFast, .dictation, "openrouter", "openai/gpt-5-nano", UsageMeasure(inputTokens: 640, outputTokens: 180), ago: 30_000)
        add(.realtimeVoice, .realtime, "gemini-live", "gemini-3.8-live",
            UsageMeasure(inputTokens: 743, outputTokens: 66, audioInputTokens: 261, audioOutputTokens: 66), ago: 90_000, dialect: .geminiLive)
        add(.brain, .chat, "anthropic", "claude-sonnet-5-5", UsageMeasure(inputTokens: 21_000, cachedInputTokens: 18_000, outputTokens: 900),
            ago: 200_000, turn: "fixture-chat", dialect: .anthropicMessages)
    }

    static func render<V: View>(services: HomeServices, settings: () -> V, size: NSSize, out: (String) -> URL) throws {
        let infra = services.infra
        services.settingsPage = .usage
        try EvidenceSnapshots.render(settings(), size: size, dark: true, to: out("settings-usage-dark"))
        // A stopping daily limit that today's fixture spending has passed.
        try infra.ledger.setLimits(UsageLimits(dailyUSD: 0.01, monthlyUSD: 5, warnAtFraction: 0.8, stopAtLimit: true))
        infra.reload()
        try EvidenceSnapshots.render(settings(), size: size, to: out("settings-usage-limit"))
        try infra.ledger.setLimits(UsageLimits())
        infra.reload()

        services.settingsPage = .developer
        let stats = BrainSessionStats.make(sessionID: "7F3C2A91-5E0B-4D7A-9C11-2B8E4F6A0D35", startedAt: Date().addingTimeInterval(-1_800),
                                      lastTurnAt: Date().addingTimeInterval(-60), turns: 6, threadItems: 19, screenshotsInThread: 2,
                                      lastInputTokens: 13_812, nextCompactionCheck: 60_000, compactions: 0)
        infra.showFixture(checks: [
            .init(slot: .stt, provider: "apple-speech", verdict: .onDevice, line: "Runs on this Mac."),
            .init(slot: .voice, provider: "elevenlabs", verdict: .reachable, line: "Reachable (api.elevenlabs.io answered HTTP 200 in 0.23 s)."),
            .init(slot: .brain, provider: "anthropic", verdict: .reachable, line: "Reachable (api.anthropic.com answered HTTP 200 in 0.24 s)."),
            .init(slot: .realtimeVoice, provider: "openai-realtime", verdict: .regionUnsupported,
                  line: "OpenAI doesn't offer its service in your country or region, so always-on voice can't connect. Choose another provider for it in Settings → Models."),
        ], brainStats: stats, reportState: "Saved openclicky-diagnostics-20261031-110900.zip.")
        try EvidenceSnapshots.render(settings(), size: size, to: out("settings-developer-checks"))
        try EvidenceSnapshots.render(settings(), size: size, dark: true, to: out("settings-developer-dark"))
        // Whole pages (taller than the window) so the flags, the key list and every usage table show.
        let tall = NSSize(width: 670, height: 2_900)
        try EvidenceSnapshots.render(DeveloperSettingsPage().environment(services).environment(services.model), size: tall,
                                     to: out("settings-developer-full"))
        try EvidenceSnapshots.render(UsageSettingsPage().environment(services).environment(services.model),
                                     size: NSSize(width: 670, height: 1_900), to: out("settings-usage-full"))
    }
}
