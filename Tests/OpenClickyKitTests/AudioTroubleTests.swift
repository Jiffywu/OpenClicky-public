import Foundation
import Testing
@testable import OpenClickyKit

// Microphone trouble: dead-air presses, the capture's trouble events, the failover pin, the shared mic's per-stream
// summaries, and the start cue that waits for the mic (docs/audio-robustness.md).

private func press(_ seconds: TimeInterval, chunks: Int, audible: Int) -> MicPressSummary {
    MicPressSummary(duration: seconds, chunks: chunks, audibleChunks: audible, peak: audible > 0 ? 0.2 : 0)
}

/// The tracker behind a reference, so its mutating calls can sit inside `#expect`.
final class TrackerRef {
    var tracker: MicTroubleTracker
    init(_ tracker: MicTroubleTracker = MicTroubleTracker()) { self.tracker = tracker }
    func pressEnded(_ summary: MicPressSummary) -> AudioNotice? { tracker.pressEnded(summary) }
    func handle(_ event: MicrophoneCapture.Event) -> AudioNotice? { tracker.handle(event) }
    func microphoneChosen() { tracker.microphoneChosen() }
    var consecutiveDeadAir: Int { tracker.consecutiveDeadAir }
    var failedOverTo: String? { tracker.failedOverTo }
}

@Suite struct MicTroubleTrackerTests {
    @Test func deadAirIsNoAudioOrOnlyZerosAndTapsNeverCount() {
        #expect(press(2, chunks: 0, audible: 0).deadAir(minimumPress: 0.8) == .noAudio)
        #expect(press(2, chunks: 50, audible: 0).deadAir(minimumPress: 0.8) == .allZeros)
        #expect(press(2, chunks: 50, audible: 3).deadAir(minimumPress: 0.8) == nil)
        #expect(press(0.3, chunks: 0, audible: 0).deadAir(minimumPress: 0.8) == nil)
    }

    @Test func twoDeadAirPressesInARowEscalateToTheTroubleNotice() throws {
        let tracker = TrackerRef()
        #expect(tracker.pressEnded(press(1.5, chunks: 0, audible: 0)) == nil)
        #expect(tracker.consecutiveDeadAir == 1)
        let notice = try #require(tracker.pressEnded(press(1.2, chunks: 30, audible: 0)))
        #expect(notice.kind == .microphoneDeadAir)
        #expect(notice.actions.contains(.microphoneSettings))
        #expect(notice.detail?.contains("only silence") == true)
        #expect(notice.detail?.contains("last 2 times") == true)
        // A third one still says so; one press with sound starts the count again.
        #expect(tracker.pressEnded(press(1.2, chunks: 0, audible: 0))?.kind == .microphoneDeadAir)
        #expect(tracker.pressEnded(press(1.2, chunks: 30, audible: 12)) == nil)
        #expect(tracker.consecutiveDeadAir == 0)
        #expect(tracker.pressEnded(press(1.2, chunks: 0, audible: 0)) == nil)
    }

    @Test func tapsBetweenDeadPressesNeitherCountNorReset() {
        let tracker = TrackerRef()
        _ = tracker.pressEnded(press(1.5, chunks: 0, audible: 0))
        #expect(tracker.pressEnded(press(0.2, chunks: 2, audible: 2)) == nil)
        #expect(tracker.consecutiveDeadAir == 1)
        #expect(tracker.pressEnded(press(1.5, chunks: 0, audible: 0))?.kind == .microphoneDeadAir)
    }

    @Test func captureEventsBecomeNoticesWithTheRightButtons() throws {
        let tracker = TrackerRef()
        let rebuilding = try #require(tracker.handle(.rebuilding(.allZeros)))
        #expect(rebuilding.kind == .microphoneRebuilding && rebuilding.tone == .info && rebuilding.actions.isEmpty)

        let failover = try #require(tracker.handle(.failedOver(from: "USB Mic", to: "MacBook Air Microphone")))
        #expect(failover.kind == .microphoneFailedOver)
        #expect(failover.title.contains("MacBook Air Microphone"))
        #expect(failover.detail?.contains("USB Mic stopped sending audio") == true)
        #expect(failover.actions == [.microphoneSettings])
        #expect(tracker.failedOverTo == "MacBook Air Microphone")

        let dead = try #require(tracker.handle(.irrecoverable(.noAudio)))
        #expect(dead.kind == .microphoneDead && dead.tone == .error)
        #expect(dead.actions == [.microphoneSettings, .soundSettings])

        #expect(tracker.handle(.failed("engine stopped"))?.detail == "engine stopped")
        for quiet in [MicrophoneCapture.Event.running(device: "x"), .routeChanged(reason: "y"), .holdingBluetooth(seconds: 8), .closed] {
            #expect(tracker.handle(quiet) == nil)
        }

        tracker.microphoneChosen()
        #expect(tracker.failedOverTo == nil && tracker.consecutiveDeadAir == 0)
    }

    @Test func overflowIsReportedOncePerPressPastTheThreshold() {
        let tracker = TrackerRef(MicTroubleTracker(policy: .init(overflowNoticeAt: 10)))
        #expect(tracker.handle(.overflow(dropped: 3)) == nil)
        #expect(tracker.handle(.overflow(dropped: 12))?.kind == .microphoneOverflow)
        #expect(tracker.handle(.overflow(dropped: 40)) == nil)
        _ = tracker.pressEnded(press(2, chunks: 50, audible: 40))
        #expect(tracker.handle(.overflow(dropped: 11))?.kind == .microphoneOverflow)
    }

    @Test func permissionNoticesPointAtPrivacySettings() {
        #expect(MicTroubleTracker.permissionNotice(.denied)?.actions == [.microphonePrivacy])
        #expect(MicTroubleTracker.permissionNotice(.restricted)?.kind == .microphonePermission)
        #expect(MicTroubleTracker.permissionNotice(.authorized) == nil)
        #expect(MicTroubleTracker.permissionNotice(.notDetermined) == nil)
    }

    @Test func actionLabelsReadAsButtons() {
        #expect(AudioNotice.Action.setVolume(0.5).label == "Set volume to 50%")
        #expect(AudioNotice.Action.unmute.label == "Unmute")
        #expect(AudioNotice.Action.microphoneSettings.label == "Microphone Settings")
    }
}

@Suite struct MicInputPinTests {
    @Test func aUserChoiceDropsTheFailoverPin() {
        var pin = MicInputPin(selected: "usb-mic")
        #expect(pin.effective == "usb-mic")
        pin.failOver(to: "built-in")
        #expect(pin.effective == "built-in" && pin.isFailedOver)
        // Picking the same dead mic again tries it again.
        let retried = pin.select("usb-mic")
        #expect(retried)
        #expect(pin.effective == "usb-mic" && !pin.isFailedOver)
        // Picking the system default after a failover also drops the pin.
        pin.failOver(to: "built-in")
        let toDefault = pin.select(nil)
        #expect(toDefault)
        #expect(pin.effective == nil)
        let unchanged = pin.select(nil)
        #expect(!unchanged)
    }

    @Test func aCaptureStartsFromACarriedOverPinAndASelectionDropsIt() {
        // No permission needed: nothing is opened.
        let capture = MicrophoneCapture(options: .init(deviceUID: "usb-mic", failoverUID: "built-in"))
        #expect(capture.inputPin == MicInputPin(selected: "usb-mic", failover: "built-in"))
        capture.selectDevice(uid: "other-mic")
        #expect(capture.inputPin == MicInputPin(selected: "other-mic", failover: nil))
        capture.close()
    }
}

/// A device that streams scripted chunks while open, can say when it's live, and records selections.
final class ScriptedMicDevice: SharedMicrophoneDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var ticker: Task<Void, Never>?
    private var _selected: [String?] = []
    private var _live = false
    private var handler: (@Sendable (MicrophoneCapture.Event) -> Void)?
    /// What each 10 ms chunk holds.
    var amplitude: Int16 = 0
    /// Delay before the first chunk ("the mic coming up").
    var startDelay: Duration = .zero
    var failover: String?

    func start(format: PCMFormat) throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let samples = format.sampleRate / 100
        let amplitude = self.amplitude, delay = startDelay
        let ticker = Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.lock.withLock { self?._live = true }
            while !Task.isCancelled {
                continuation.yield(PCMConverter.pcm16(fromSamples: (0..<samples).map { $0 % 2 == 0 ? amplitude : -amplitude }))
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        lock.withLock {
            self.ticker?.cancel()
            self.continuation?.finish()
            self.continuation = continuation
            self.ticker = ticker
            _live = false
        }
        return stream
    }

    func stop(keepWarm: Bool) {
        lock.withLock {
            ticker?.cancel()
            continuation?.finish()
            continuation = nil
            ticker = nil
            _live = false
        }
    }

    var level: Float { 0 }

    func waitUntilLive(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ _live }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func select(deviceUID: String?) {
        lock.withLock {
            _selected.append(deviceUID)
            failover = nil
        }
    }

    var failoverPin: String? { lock.withLock { failover } }

    func setEventHandler(_ handler: (@Sendable (MicrophoneCapture.Event) -> Void)?) { lock.withLock { self.handler = handler } }
    func emit(_ event: MicrophoneCapture.Event) { lock.withLock { handler }?(event) }
    var selections: [String?] { lock.withLock { _selected } }
}

final class SummaryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(SharedMicrophone.User, MicPressSummary)] = []
    func add(_ user: SharedMicrophone.User, _ summary: MicPressSummary) { lock.withLock { entries.append((user, summary)) } }
    var all: [(SharedMicrophone.User, MicPressSummary)] { lock.withLock { entries } }
}

@MainActor
@Suite struct SharedMicrophoneTroubleTests {
    @Test func aStoppedPressIsSummedUpForDeadAirCounting() async throws {
        let device = ScriptedMicDevice()
        let shared = SharedMicrophone(device: device)
        let log = SummaryLog()
        shared.onStreamEnded = { user, summary in log.add(user, summary) }
        let stream = try shared.turns.start(format: .speech16k)
        let reader = Task { for await _ in stream {} }
        try await Task.sleep(for: .milliseconds(120))
        shared.turns.stop()
        _ = await reader.value
        #expect(await waitUntil { log.all.count == 1 })
        let (user, summary) = try #require(log.all.first)
        #expect(user == .turns)
        #expect(summary.chunks >= 5)
        #expect(summary.audibleChunks == 0)
        #expect(summary.duration >= 0.1)
        #expect(summary.deadAir(minimumPress: 0.1) == .allZeros)
    }

    @Test func audibleChunksCountAndAHandedOverStreamIsNotReported() async throws {
        let device = ScriptedMicDevice()
        device.amplitude = 4_000
        let shared = SharedMicrophone(device: device)
        let log = SummaryLog()
        shared.onStreamEnded = { user, summary in log.add(user, summary) }
        let first = try shared.turns.start(format: .speech16k)
        let firstReader = Task { for await _ in first {} }
        try await Task.sleep(for: .milliseconds(50))
        // Always-on takes the mic: the press's stream ends without its own stop.
        let second = try shared.alwaysOn.start(format: .speech24k)
        let secondReader = Task { for await _ in second {} }
        _ = await firstReader.value
        try await Task.sleep(for: .milliseconds(50))
        shared.alwaysOn.stop()
        _ = await secondReader.value
        #expect(await waitUntil { log.all.count == 1 })
        #expect(log.all.map(\.0) == [.alwaysOn])
        #expect(log.all.first.map { $0.1.audibleChunks > 0 } == true)
    }

    @Test func selectionsAndEventsGoThroughToTheDevice() async throws {
        let device = ScriptedMicDevice()
        device.failover = "built-in"
        let shared = SharedMicrophone(device: device)
        #expect(shared.failoverPin == "built-in")
        let events = LockedBox<[MicrophoneCapture.Event]>([])
        shared.onCaptureEvent = { event in events.mutate { $0.append(event) } }
        device.emit(.failedOver(from: "USB", to: "Built-in"))
        #expect(events.value == [.failedOver(from: "USB", to: "Built-in")])
        shared.selectDevice(uid: "usb-2")
        #expect(device.selections == ["usb-2"])
        #expect(shared.failoverPin == nil)
    }

    /// Review fix: a reader that falls behind loses the newest chunks and the drops come out as `.overflow` (before, the
    /// pass-through buffered without limit, so the capture's overflow event could never fire on the real device).
    @Test func aReaderThatFallsBehindGetsTheOverflowEvent() async throws {
        let device = ScriptedMicDevice()
        let shared = SharedMicrophone(device: device, maxBufferedChunks: 4)
        let events = LockedBox<[MicrophoneCapture.Event]>([])
        shared.onCaptureEvent = { event in events.mutate { $0.append(event) } }
        let stream = try shared.turns.start(format: .speech16k)
        // Nobody reads until 25 chunks have been dropped (the tracker's notice threshold).
        #expect(await waitUntil(.seconds(20)) { events.value.contains(.overflow(dropped: 25)) })
        #expect(events.value.first == .overflow(dropped: 1))
        shared.turns.stop()
        var kept = 0
        for await _ in stream { kept += 1 }
        #expect(kept == 4)
        var tracker = MicTroubleTracker()
        #expect(events.value.compactMap { tracker.handle($0) }.map(\.kind) == [.microphoneOverflow])
    }

    @Test func theTurnHandleSaysWhenThePressIsLive() async throws {
        let device = ScriptedMicDevice()
        device.startDelay = .milliseconds(60)
        let shared = SharedMicrophone(device: device)
        #expect(await shared.turns.waitUntilLive(timeout: 0.05) == false) // not holding the mic
        let stream = try shared.turns.start(format: .speech16k)
        let reader = Task { for await _ in stream {} }
        // The limit only guards against a hang (the suite runs in parallel on a busy machine).
        #expect(await shared.turns.waitUntilLive(timeout: 10))
        shared.turns.stop()
        _ = await reader.value
    }
}

final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

// MARK: - The start cue waits for the mic

/// A turn mic that goes live when the test says so (or never).
@MainActor
final class GatedTurnMicrophone: TurnMicrophone, TurnMicrophoneReadiness {
    let trace: VoiceTrace
    var live = false
    private var continuation: AsyncStream<Data>.Continuation?
    private var ticker: Task<Void, Never>?

    init(trace: VoiceTrace) { self.trace = trace }

    func start(format: PCMFormat) throws -> AsyncStream<Data> {
        live = false
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        let bytes = format.bytesPerSecond / 100
        ticker = Task {
            while !Task.isCancelled {
                continuation.yield(Data(count: bytes))
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        trace.add("mic.start")
        return stream
    }

    func stop() {
        ticker?.cancel()
        continuation?.finish()
        continuation = nil
        trace.add("mic.stop")
    }

    var level: Float { 0 }

    func waitUntilLive(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if live { trace.add("mic.live"); return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

@MainActor
final class RecordingCues: TurnCuePlaying {
    let trace: VoiceTrace
    init(trace: VoiceTrace) { self.trace = trace }
    func play(_ cue: UICue) { trace.add("cue:\(cue.rawValue)") }
}

@MainActor
@Suite struct StartCueTests {
    @Test func theStartCuePlaysOnlyOnceTheMicIsLive() async throws {
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Done."])])
        let mic = GatedTurnMicrophone(trace: rig.trace)
        rig.orchestrator.services.microphone = mic
        rig.orchestrator.services.cues = RecordingCues(trace: rig.trace)
        rig.orchestrator.settings.startCueTimeout = 10
        rig.orchestrator.pressBegan()
        try await Task.sleep(for: .milliseconds(80))
        #expect(rig.trace.filtered("cue:").isEmpty)
        mic.live = true
        #expect(await rig.wait(10) { !rig.trace.filtered("cue:startListening").isEmpty })
        let liveAt = try #require(rig.trace.index(of: "mic.live"))
        let cueAt = try #require(rig.trace.index(of: "cue:startListening"))
        #expect(liveAt < cueAt)
        try await Task.sleep(for: .milliseconds(80))
        rig.orchestrator.pressEnded()
        #expect(await rig.waitForRecords(1))
        #expect(rig.trace.filtered("cue:") == ["cue:startListening", "cue:stopListening"])
    }

    @Test func aMicThatNeverGoesLiveGetsNoStartCue() async throws {
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Done."])])
        let mic = GatedTurnMicrophone(trace: rig.trace)
        rig.orchestrator.services.microphone = mic
        rig.orchestrator.services.cues = RecordingCues(trace: rig.trace)
        rig.orchestrator.settings.startCueTimeout = 0.1
        var logs: [String] = []
        rig.orchestrator.onLog = { logs.append($0) }
        rig.orchestrator.pressBegan()
        #expect(await rig.wait(10) { logs.contains { $0.hasPrefix("start cue skipped") } })
        rig.orchestrator.pressCancelled()
        #expect(rig.trace.filtered("cue:startListening").isEmpty)
    }

    @Test func aPressLetGoBeforeTheMicIsLiveGetsNoLateStartCue() async throws {
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Done."])])
        let mic = GatedTurnMicrophone(trace: rig.trace)
        rig.orchestrator.services.microphone = mic
        rig.orchestrator.services.cues = RecordingCues(trace: rig.trace)
        rig.orchestrator.pressBegan()
        try await Task.sleep(for: .milliseconds(30))
        rig.orchestrator.pressEnded()
        mic.live = true
        // Let the turn finish (the rig mustn't go away under it).
        #expect(await rig.waitForRecords(1))
        #expect(rig.trace.filtered("cue:") == ["cue:stopListening"])
    }

    @Test func aMicThatCantTellGetsTheCueAtOnce() async throws {
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Done."])])
        rig.orchestrator.services.cues = RecordingCues(trace: rig.trace)
        rig.orchestrator.pressBegan()
        #expect(rig.trace.filtered("cue:") == ["cue:startListening"])
        rig.orchestrator.pressCancelled()
    }
}

// MARK: - Cue preloading and settings

@Test func cuesArePreloadedWithoutOpeningAnyDevice() {
    let backend = FakeSpeechPlaybackBackend()
    let player = SpeechPlayer(backend: backend, pollInterval: nil)
    let cues = CuePlayer(player: player)
    #expect(cues.preloaded.isEmpty)
    cues.preload()
    #expect(cues.preloaded == Set(UICue.allCases))
    #expect(backend.startCount == 0)
    #expect(!player.isOutputRunning)
}

@Test func voiceLoopSettingsKeepOldFilesAndRoundTripTheNewKeys() throws {
    let old = try JSONDecoder().decode(VoiceLoopSettings.self, from: Data(#"{"playsCues": false}"#.utf8))
    #expect(old.playsCues == false)
    #expect(old.microphoneUID == nil)
    #expect(old.echoCancellation == .automatic)
    #expect(old.holdsDuringQuiet && old.handlesMutedOutput)

    let weird = try JSONDecoder().decode(VoiceLoopSettings.self, from: Data(#"{"echoCancellation": "sometimes"}"#.utf8))
    #expect(weird.echoCancellation == .automatic)

    var settings = VoiceLoopSettings()
    settings.microphoneUID = "usb-mic"
    settings.echoCancellation = .off
    settings.holdsDuringQuiet = false
    settings.handlesMutedOutput = false
    let decoded = try JSONDecoder().decode(VoiceLoopSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
}
