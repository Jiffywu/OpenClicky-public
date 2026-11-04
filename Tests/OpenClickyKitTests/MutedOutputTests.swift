import Foundation
import Testing
@testable import OpenClickyKit

// Muted or zero-volume output: detection, the clipboard copy and notice, the Unmute and Set volume buttons, and the
// voice loop answering silently (docs/audio-robustness.md). Nothing here touches the Mac's real volume.

@Suite struct OutputVolumeStateTests {
    @Test func silenceIsMutedOrZeroAndDevicesWithoutControlsCountAsAudible() {
        #expect(OutputVolumeState(muted: true, volume: 0.6).silence == .muted)
        #expect(OutputVolumeState(muted: false, volume: 0).silence == .zeroVolume)
        #expect(OutputVolumeState(muted: false, volume: 0.0005).silence == .zeroVolume)
        #expect(OutputVolumeState(muted: false, volume: 1.0 / 16).silence == nil)
        #expect(OutputVolumeState(muted: nil, volume: nil).silence == nil)
        #expect(OutputVolumeState(muted: true, volume: 0).silence == .muted)
        #expect(OutputVolumeState(deviceName: "Speakers", muted: true, volume: 0.5).summary == "Speakers: muted, volume 50%")
    }

    @Test func theRealOutputCanBeReadWithoutChangingIt() {
        // Reads only (the Mac stays as it is). A machine with no output device returns nil.
        let state = CoreAudioOutputVolume().read()
        if let state { #expect(state.volume.map { (0...1).contains($0) } ?? true) }
    }
}

@MainActor
@Suite struct MutedOutputGuardTests {
    @Test func anUnheardReplyIsCopiedAndTheNoticeOffersTheFix() throws {
        let output = FakeOutputVolume(OutputVolumeState(deviceName: "Speakers", muted: true, volume: 0.6))
        let pasteboard = InMemoryPasteboard()
        let guardian = MutedOutputGuard(output: output, pasteboard: pasteboard)
        #expect(guardian.outputSilence() == .muted)
        let notice = try #require(guardian.replyWasUnheard(UnheardReply(silence: .muted, text: "The capital is Paris. It's on the Seine.",
                                                                       kind: .voice)))
        #expect(pasteboard.snapshot().items.first?.representations.first?.data == Data("The capital is Paris. It's on the Seine.".utf8))
        #expect(notice.kind == .outputMuted)
        #expect(notice.title.contains("muted"))
        #expect(notice.detail == "I copied my reply to the clipboard.")
        #expect(notice.actions == [.unmute])

        // Nothing changed until the button is pressed.
        #expect(output.log.isEmpty)
        #expect(try guardian.perform(.unmute))
        #expect(output.log == ["mute:false"])
        #expect(guardian.outputSilence() == nil)
        #expect(try guardian.perform(.microphoneSettings) == false)
    }

    @Test func zeroVolumeAndMutedAtZeroBothOfferSetVolume() throws {
        let output = FakeOutputVolume(OutputVolumeState(muted: false, volume: 0))
        let guardian = MutedOutputGuard(output: output, pasteboard: InMemoryPasteboard())
        let zero = try #require(guardian.replyWasUnheard(UnheardReply(silence: .zeroVolume, text: "Hi.", kind: .typed)))
        #expect(zero.kind == .outputZeroVolume && zero.actions == [.setVolume(0.5)])
        output.current = OutputVolumeState(muted: true, volume: 0)
        let both = try #require(guardian.replyWasUnheard(UnheardReply(silence: .muted, text: "Hi.", kind: .voice)))
        #expect(both.actions == [.setVolume(0.5)])
        try guardian.perform(.setVolume(0.5))
        #expect(output.log == ["volume:0.50"])
        #expect(output.current?.muted == false && output.current?.volume == 0.5)
    }

    @Test func nothingToCopyMeansNoNoticeAndTheCheckCanBeTurnedOff() {
        let output = FakeOutputVolume(OutputVolumeState(muted: true, volume: 1))
        let guardian = MutedOutputGuard(output: output, pasteboard: InMemoryPasteboard())
        #expect(guardian.replyWasUnheard(UnheardReply(silence: .muted, text: "  ", kind: .voice)) == nil)
        guardian.enabled = false
        #expect(guardian.outputSilence() == nil)
    }
}

/// An output check a test flips by hand.
@MainActor
final class FixedOutputCheck: TurnOutputChecking {
    var silence: OutputSilence?
    init(_ silence: OutputSilence?) { self.silence = silence }
    func outputSilence() -> OutputSilence? { silence }
}

@MainActor
@Suite struct MutedTurnTests {
    @Test func aMutedMacGetsTheAnswerSilentlyWithCaptionsAndTheReplyForTheClipboard() async throws {
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Paris is the capital.", "It sits on the Seine."])])
        rig.orchestrator.services.output = FixedOutputCheck(.muted)
        await rig.ask()
        #expect(await rig.waitForRecords(1))
        let record = try #require(rig.records.first)
        // Nothing was spoken; the drawing didn't wait for a voice; captions carried the lines.
        #expect(rig.voice.spoken.isEmpty && rig.fallback.spoken.isEmpty)
        #expect(rig.trace.filtered("draw.begin") == ["draw.begin:now"])
        #expect(rig.displays.contains { $0.caption == "It sits on the Seine." })
        #expect(record.outcome == .completed)
        let unheard = try #require(record.unheardReply)
        #expect(unheard.silence == .muted)
        #expect(unheard.text == "Paris is the capital. It sits on the Seine.")
        #expect(unheard.kind == .voice)
        #expect(record.notice == TurnNotice.unheard(.muted, copied: true))
        #expect(rig.orchestrator.display.notice?.title.contains("muted") == true)
    }

    @Test func anAudibleMacSpeaksAsUsual() async throws {
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Hello."])])
        rig.orchestrator.services.output = FixedOutputCheck(nil)
        await rig.ask()
        #expect(await rig.waitForRecords(1))
        #expect(rig.voice.spoken == ["Hello."])
        #expect(rig.records.first?.unheardReply == nil)
    }

    @Test func typedAnswersThatArentReadAloudArentUnheard() async throws {
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Shown, not said."])])
        rig.orchestrator.services.output = FixedOutputCheck(.zeroVolume)
        rig.orchestrator.submitTyped("what is this")
        #expect(await rig.waitForRecords(1))
        #expect(rig.records.first?.unheardReply == nil)

        rig.orchestrator.settings.speaksTypedAnswers = true
        rig.orchestrator.submitTyped("and this")
        #expect(await rig.waitForRecords(2))
        #expect(rig.records.last?.unheardReply?.silence == .zeroVolume)
        #expect(rig.records.last?.unheardReply?.kind == .typed)
        #expect(rig.voice.spoken.isEmpty)
    }

    @Test func aReportTurnWhileMutedIsCopiedToo() async throws {
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Your export finished."])])
        rig.orchestrator.services.output = FixedOutputCheck(.muted)
        rig.orchestrator.runReportTurn(note: "[Jobs came back] one job")
        #expect(await rig.waitForRecords(1))
        #expect(rig.records.first?.unheardReply?.kind == .report)
        #expect(rig.records.first?.unheardReply?.text == "Your export finished.")
    }
}
