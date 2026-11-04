import Foundation
import Testing
@testable import OpenClickyKit

/// The narrator's fallback order (#25): the voice slot, then another configured cloud voice, then the Apple voice; and
/// how the app finds that other cloud voice in the config.
@Suite(.timeLimit(.minutes(1)))
struct VoiceFallbackOrderTests {
    private func narrate(_ narrator: LineNarrator, _ lines: [String]) async -> NarrationReport {
        let narration = narrator.begin()
        for (index, line) in lines.enumerated() { narration.say(index, line) }
        narration.close()
        return await narration.waitUntilDone()
    }

    @Test func aFailedCloudVoiceFallsBackToTheOtherCloudVoiceBeforeTheAppleVoice() async throws {
        let trace = VoiceTrace()
        let voice = FakeVoiceClient(name: "voice", trace: trace)
        let alternate = FakeVoiceClient(name: "gemini", trace: trace)
        let apple = FakeVoiceClient(name: "apple", trace: trace)
        let clock = PlaybackClockDriver(speed: 8)
        let narrator = LineNarrator(voice: voice, fallback: apple, player: clock.player, voiceName: "Sarah",
                                    alternate: alternate, alternateVoiceName: "Kore",
                                    policy: LineNarrator.Policy(firstAudioTimeout: 2))
        voice.always(.fail("overloaded"))

        let report = await narrate(narrator, ["One.", "Two."])
        // The slot was tried and reopened once, then the other cloud voice took this line and the next.
        #expect(voice.spoken == ["One.", "One."])
        #expect(alternate.spoken == ["One.", "Two."])
        #expect(apple.spoken.isEmpty)
        #expect(report.fallbackLines == [0, 1])
        #expect(narrator.isUsingFallback && narrator.isUsingAlternate)
        #expect(alternate.voices == ["Kore", "Kore"])

        // The alternate fails too: the Apple voice is the last resort, for the rest of the same period.
        alternate.always(.fail("also down"))
        let second = await narrate(narrator, ["Three."])
        #expect(alternate.spoken.suffix(1) == ["Three."])
        #expect(apple.spoken == ["Three."])
        #expect(second.fallbackLines == [0])
        #expect(narrator.isUsingFallback && !narrator.isUsingAlternate)
        #expect(voice.spoken.count == 2)  // the slot isn't retried inside the period
    }

    @Test func withoutAnAlternateTheAppleVoiceStillTakesOver() async throws {
        let trace = VoiceTrace()
        let voice = FakeVoiceClient(name: "voice", trace: trace)
        let apple = FakeVoiceClient(name: "apple", trace: trace)
        let clock = PlaybackClockDriver(speed: 8)
        let narrator = LineNarrator(voice: voice, fallback: apple, player: clock.player, policy: LineNarrator.Policy(firstAudioTimeout: 2))
        voice.always(.fail("overloaded"))
        let report = await narrate(narrator, ["One."])
        #expect(apple.spoken == ["One."])
        #expect(report.fallbackLines == [0])
        #expect(!narrator.isUsingAlternate)
    }

    @Test func theSlotIsTriedAgainOnceTheFallbackPeriodEnds() async throws {
        let trace = VoiceTrace()
        let voice = FakeVoiceClient(name: "voice", trace: trace)
        let alternate = FakeVoiceClient(name: "gemini", trace: trace)
        let apple = FakeVoiceClient(name: "apple", trace: trace)
        let clock = PlaybackClockDriver(speed: 8)
        let now = LockedValue(Date(timeIntervalSince1970: 1_000))
        let narrator = LineNarrator(voice: voice, fallback: apple, player: clock.player, alternate: alternate,
                                    policy: LineNarrator.Policy(firstAudioTimeout: 2, fallbackPeriod: 600), now: { now.get() })
        voice.then(.fail("down"), .fail("still down"))
        _ = await narrate(narrator, ["One."])
        #expect(narrator.isUsingAlternate)
        now.set(Date(timeIntervalSince1970: 1_000 + 601))
        #expect(!narrator.isUsingFallback)
        _ = await narrate(narrator, ["Two."])
        #expect(voice.spoken.last == "Two.")
        #expect(alternate.spoken == ["One."])
    }

    // MARK: Finding the other cloud voice

    private func config(voiceProvider: String = "elevenlabs") -> OpenClickyConfig {
        OpenClickyConfig(version: 1, providers: [
            ProviderConfig(id: "elevenlabs", dialect: .elevenLabsSpeech, baseURL: URL(string: "https://api.elevenlabs.io"), credential: "elevenlabs"),
            ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic"),
            ProviderConfig(id: "gemini-tts", dialect: .geminiSpeech, baseURL: URL(string: "https://generativelanguage.googleapis.com"), credential: "gemini"),
            ProviderConfig(id: "apple-voices", dialect: .appleSpeechSynthesis),
        ], models: [], slots: [.voice: SlotSelection(provider: voiceProvider, model: voiceProvider == "elevenlabs" ? "eleven_flash_v2_5" : "gemini-3.8-flash-lite-tts")])
    }

    @Test func theAlternateIsAnotherCloudVoiceWithAStoredKey() throws {
        let catalog = try ModelCatalog.builtIn()
        let keys = InMemoryCredentialStore(["elevenlabs": "el-test", "gemini": "gm-test"])
        let alternate = try #require(EngineFactory(config: config(), catalog: catalog, credentials: keys, resilience: nil).alternateSpeechOutput())
        #expect(alternate.providerID == "gemini-tts")
        #expect(alternate.model == GeminiSpeechClient.defaultModel)
        #expect(alternate.client is GeminiSpeechClient)

        // The other way round: Gemini in the slot, ElevenLabs as the alternate.
        let flipped = try #require(EngineFactory(config: config(voiceProvider: "gemini-tts"), catalog: catalog, credentials: keys,
                                                 resilience: nil).alternateSpeechOutput())
        #expect(flipped.providerID == "elevenlabs")

        // Without the other provider's key there is no alternate (the Apple voice remains the fallback).
        let onlyOne = InMemoryCredentialStore(["elevenlabs": "el-test"])
        #expect(EngineFactory(config: config(), catalog: catalog, credentials: onlyOne, resilience: nil).alternateSpeechOutput() == nil)
    }

    @Test func anOnDeviceVoiceSlotHasNoCloudAlternate() throws {
        var config = config()
        config.slots[.voice] = SlotSelection(provider: "apple-voices", model: "system")
        let keys = InMemoryCredentialStore(["elevenlabs": "el-test", "gemini": "gm-test"])
        #expect(EngineFactory(config: config, catalog: try ModelCatalog.builtIn(), credentials: keys, resilience: nil).alternateSpeechOutput() == nil)
    }
}
