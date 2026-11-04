import Foundation
import Testing
@testable import OpenClickyKit

// Feature flags either switch something or say they can't: Developer offers only read flags as switches, flags whose
// feature lives in a regular setting point their HeyClicky keys at it, and the wired ones really gate their feature.

@Suite struct FeatureFlagWiringTests {
    @Test func everyDeveloperSwitchIsReadAndTheRestAreBadged() {
        #expect(!FeatureFlag.developerSwitches.isEmpty)
        for flag in FeatureFlag.developerSwitches {
            #expect(flag.readBy?.isEmpty == false, "\(flag.id) is offered as a switch but nothing reads it")
        }
        #expect(Set(FeatureFlag.developerSwitches.map(\.id)).union(FeatureFlag.notBuilt.map(\.id)) == Set(FeatureFlag.all.map(\.id)))
        #expect(FeatureFlag.notBuilt.allSatisfy { $0.readBy == nil })
        #expect(FeatureFlag.notBuilt.count <= 6, "the audit found 14 unread flags; at most six are left for unbuilt features")
        for id in ["drawing.sounds", "brain.reads-connected-apps", "brain.keeps-screens"] {
            #expect(FeatureFlag.named(id)?.isWired == true, "\(id) is read now")
        }
    }

    @Test func flagsCoveredBySettingsAreGoneAndTheirKeysPointAtTheSetting() {
        for id in ["drawing.captions", "agents.voice-announcements", "agents.cursor-announcements",
                   "agents.proactive-suggestions", "notch.upcoming-meetings"] {
            #expect(FeatureFlag.named(id) == nil, "\(id) is a regular setting, not a flag")
        }
        func setting(_ key: String) -> String? {
            guard case .setting(let where_)? = HeyClickyFlagKeys.all.first(where: { $0.key == key })?.disposition else { return nil }
            return where_
        }
        #expect(setting("ClickyUpcomingMeetingsEnabled")?.contains("meetingCountdown") == true)
        #expect(setting("ClickyAgentVoiceAnnouncementsEnabled")?.contains("voiceAnnouncements") == true)
        #expect(setting("ClickyAgentCursorTextAnnouncementsEnabled")?.contains("textAnnouncements") == true)
        #expect(setting("ClickyProactiveAgentSuggestionsEnabled")?.contains("suggestTasks") == true)
        #expect(setting("ClickyScreenDrawingSubtitles")?.contains("caption") == true)
        #expect(setting("ClickyScreenDrawingVoiceCaptions")?.contains("caption") == true)
    }

    @Test func connectedAppsFlagOffRemovesReadConnectedApps() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("flag-vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vault) }
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let registry = ConnectorRegistry(obsidian: ObsidianSettings(vaultPath: vault.path))
        var wiring = BrainWiring(connectedApps: ConnectedAppsWiring.make(registry: registry, credentials: InMemoryCredentialStore()))
        let flags = FeatureFlagStore(url: nil)
        wiring.apply(flags)
        #expect(wiring.tools().names.contains(ReadConnectedApps.toolName))
        #expect(!wiring.promptOptions().connectedApps.isEmpty)

        try flags.set(.brainReadsConnectedApps, false)
        wiring.apply(flags)
        #expect(!wiring.tools().names.contains(ReadConnectedApps.toolName))
        #expect(wiring.promptOptions().connectedApps.isEmpty, "the prompt doesn't list apps the brain can't read")
    }

    @Test func keepsScreensFlagRaisesThePruningLimit() throws {
        let flags = FeatureFlagStore(url: nil)
        var wiring = BrainWiring()
        wiring.apply(flags)
        let base = BrainPruningPolicy()
        #expect(wiring.pruning(base) == base)
        try flags.set(.brainKeepsScreens, true)
        wiring.apply(flags)
        #expect(wiring.pruning(base).keepImages == BrainWiring.keptScreens)
        #expect(wiring.pruning(base).imageSlack == base.imageSlack)
    }
}

@MainActor
@Test func drawingSoundsFlagOffSilencesTheDrawingSoundPlayer() async throws {
    let textures = FakeSpeechPlaybackBackend(), accents = FakeSpeechPlaybackBackend()
    let sounds = DrawingSoundPlayer(player: SpeechPlayer(backend: textures, pollInterval: nil, idleTimeout: 3600),
                                    accentPlayer: SpeechPlayer(backend: accents, pollInterval: nil, idleTimeout: 3600), volume: 1)
    let flags = FeatureFlagStore(url: nil)
    try flags.set(.drawingSounds, false)
    sounds.flags = flags
    sounds.schedule(DrawingSoundRecipe(at: 0, duration: 0.5, texture: "writing", accents: [.init(id: "gel-pop", at: 0)], mark: "a"), now: 0)
    try await Task.sleep(for: .milliseconds(150))
    #expect(textures.scheduledFrames == 0 && accents.scheduledFrames == 0, "drawing.sounds off plays nothing")

    try flags.set(.drawingSounds, true)
    sounds.schedule(DrawingSoundRecipe(at: 1, duration: 0.5, texture: "writing", accents: [.init(id: "gel-pop", at: 0)], mark: "b"), now: 1)
    #expect(await waitUntil { textures.scheduledFrames > 0 && accents.scheduledFrames > 0 })
}
