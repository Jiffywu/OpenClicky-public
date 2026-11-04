import Foundation
import Testing
@testable import OpenClickyKit

/// One controller wired to fakes, plus a stream of finished sessions.
@MainActor
private final class Harness {
    let system = FakeInsertionSystem()
    let mic = FakeMicrophone()
    let stt: ScriptedSpeechToText
    let model: RecordingLanguageModel
    let directory = temporaryDirectory()
    let vocabulary: DictationVocabularyStore
    let archive: DictationTranscriptArchive
    let controller: DictationController
    let reports: AsyncStream<DictationSessionReport>
    var phases: [DictationStatus.Phase] = []

    init(script: [TranscriptEvent], reply: String = "So the demo is on Thursday.", focus: CapturedFocus = makeFocus("Note: "),
         timing: DictationEngagementMachine.Timing = .init(), learn: Bool = false) {
        stt = ScriptedSpeechToText(script)
        model = RecordingLanguageModel(.reply(reply))
        vocabulary = DictationVocabularyStore(url: directory.appendingPathComponent("vocabulary.json"))
        archive = DictationTranscriptArchive(directory: directory.appendingPathComponent("DictationTranscripts"))
        system.focus = focus
        if let element = focus.element, let id = element.raw as? String {
            system.values[id] = focus.context.beforeText + focus.context.selectedText + focus.context.afterText
            system.selections[id] = UTF16Range(location: focus.context.beforeText.utf16.count, length: focus.context.selectedText.utf16.count)
        }
        let stt = self.stt, model = self.model
        let services = DictationController.Services(
            focus: FixedFocusReader(focus: focus), audio: mic, speechToText: { stt },
            cleaner: { DictationCleaner(client: model, options: DictationCleanupOptions(model: "fast", minimumWords: 3, timeout: 5)) },
            inserter: TextInserter(system: system, pasteRestoreDelay: 0), vocabulary: vocabulary, archive: archive,
            // Scripted sessions end by themselves; the timeout only guards against a hang, so a busy machine can't trip it.
            language: "en", keytermSeeds: ["OpenClicky"], learnCorrections: learn, finalTranscriptTimeout: 10, learnDelay: 60,
            resultDisplaySeconds: 60)
        controller = DictationController(services: services, timing: timing)
        let (stream, continuation) = AsyncStream<DictationSessionReport>.makeStream()
        reports = stream
        controller.onSessionFinished = { continuation.yield($0) }
        controller.onStatusChange = { [weak self] in self?.phases.append($0.phase) }
    }

    func nextReport() async -> DictationSessionReport? {
        for await report in reports { return report }
        return nil
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func dictationTypesTheCleanedTranscriptIntoTheField() async throws {
    let h = Harness(script: [.interim("um so the"), .final("um so the demo"), .final(" is on thursday")])
    try await h.vocabulary.update { $0.add("Thursday") }
    h.controller.begin()
    #expect(h.controller.isCapturing)
    #expect(h.controller.status.phase == .listening)
    h.controller.commit()
    let report = try #require(await h.nextReport())

    #expect(report.rawTranscript == "um so the demo is on thursday")
    #expect(report.cleanup?.source == .model)
    #expect(report.result == .typed(appName: "TextEdit"))
    #expect(h.system.values["field-1"] == "Note: So the demo is on Thursday.")
    #expect(h.controller.status.phase == .done(.typed(appName: "TextEdit")))
    #expect(h.phases.contains(.listening) && h.phases.contains(.finishing) && h.phases.contains(.inserting))

    // The stt slot got the language and the merged keyterms; the mic was opened and closed once.
    #expect(h.stt.languages == ["en"])
    #expect(h.stt.keywords.first == ["Thursday", "OpenClicky"])
    #expect(h.mic.starts == 1 && h.mic.stops == 1)
    #expect(h.stt.sessions.first?.finished == true)
    #expect(h.stt.sessions.first?.audio.count == 640)

    // The cleanup prompt saw the field's text and the vocabulary.
    let prompt = try #require(h.model.requests.first).messages[1].text
    #expect(prompt.contains("text before caret: \"Note: \""))
    #expect(prompt.contains("Thursday, OpenClicky"))

    let entries = try await h.archive.entries(on: Date())
    #expect(entries.count == 1)
    #expect(entries.first?.text == "So the demo is on Thursday.")
    #expect(entries.first?.raw == "um so the demo is on thursday")
    #expect(entries.first?.outcome == "typed")
    #expect(entries.first?.app == "TextEdit")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aQuickTapIsDiscardedAndAHoldTypes() async throws {
    let timing = DictationEngagementMachine.Timing(minimumHold: 0.3, doubleTapWindow: 0.05, bounceGrace: 0.01)
    let h = Harness(script: [.final("hello there my friend")], reply: "Hello there, my friend.", timing: timing)
    h.controller.handle(.chordDown(at: 0))
    h.controller.handle(.chordUp(at: 0.1))
    #expect(h.controller.isCapturing) // still listening while a second tap may come
    // No second tap comes, so the double-tap timer throws the tap away (however late it runs on a busy machine).
    #expect(await waitUntil { !h.controller.isCapturing })
    #expect(h.controller.status.phase == .idle)
    #expect(h.system.values["field-1"] == "Note: ")

    h.controller.handle(.chordDown(at: 10))
    h.controller.handle(.chordUp(at: 11))
    let report = try #require(await h.nextReport())
    #expect(report.result == .typed(appName: "TextEdit"))
    #expect(h.system.values["field-1"] == "Note: Hello there, my friend.")
    #expect(h.mic.starts == 2)
    #expect(h.stt.sessions.count == 2)
    #expect(h.stt.sessions[0].cancelled)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func handsFreeDoubleTapThenTapTypes() async throws {
    let timing = DictationEngagementMachine.Timing(minimumHold: 0.3, doubleTapWindow: 0.4, bounceGrace: 0.01)
    let h = Harness(script: [.final("write the summary tonight")], reply: "Write the summary tonight.", timing: timing)
    h.controller.handle(.chordDown(at: 0))
    h.controller.handle(.chordUp(at: 0.1))
    h.controller.handle(.chordDown(at: 0.2))
    #expect(h.controller.status.engagement == .handsFreeLocked)
    h.controller.handle(.chordUp(at: 0.3))
    #expect(h.controller.isCapturing)
    h.controller.handle(.chordDown(at: 5))
    let report = try #require(await h.nextReport())
    #expect(report.result == .typed(appName: "TextEdit"))
    #expect(h.mic.starts == 1)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func silenceTypesNothing() async throws {
    let h = Harness(script: [])
    h.controller.begin()
    h.controller.commit()
    let report = try #require(await h.nextReport())
    #expect(report.result == .nothingHeard)
    #expect(h.model.requests.isEmpty)
    #expect(h.system.pastes.isEmpty)
    #expect(try await h.archive.entries(on: Date()).isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func shortUtterancesSkipTheModel() async throws {
    let h = Harness(script: [.final("uh thanks")], focus: makeFocus("Done. "))
    h.controller.begin()
    h.controller.commit()
    let report = try #require(await h.nextReport())
    #expect(report.cleanup?.source == .skippedShort)
    #expect(h.model.requests.isEmpty)
    #expect(h.system.values["field-1"] == "Done. Thanks")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func passwordFieldsAreRefusedAndNotArchived() async throws {
    let password = makeFocus("", role: "AXTextField", subrole: "AXSecureTextField")
    let h = Harness(script: [.final("my secret phrase is here")], focus: password)
    h.controller.begin()
    h.controller.commit()
    let report = try #require(await h.nextReport())
    #expect(report.result == .refused(.secureField))
    #expect(h.model.requests.isEmpty)
    #expect(h.system.fakePasteboard.string == nil)
    #expect(try await h.archive.entries(on: Date()).isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func withoutSpeechToTextTheHUDExplains() async {
    let system = FakeInsertionSystem()
    let services = DictationController.Services(
        focus: FixedFocusReader(focus: nil), audio: FakeMicrophone(), speechToText: { nil }, cleaner: { nil },
        inserter: TextInserter(system: system))
    let controller = DictationController(services: services)
    controller.begin()
    #expect(!controller.isCapturing)
    guard case .failed(let message) = controller.status.phase else { Issue.record("expected failure"); return }
    #expect(message.contains("stt"))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func correctionsMadeAfterTypingAreLearned() async throws {
    let h = Harness(script: [.final("ship it with open clicky today")], reply: "Ship it with open clicky today.",
                    focus: makeFocus("Plan: "), learn: true)
    var learned: [LearnedCorrection] = []
    h.controller.onLearned = { learned = $0 }
    h.controller.begin()
    h.controller.commit()
    _ = try #require(await h.nextReport())
    #expect(h.system.values["field-1"] == "Plan: Ship it with open clicky today.")

    // The user fixes the product name by hand.
    h.system.values["field-1"] = "Plan: Ship it with OpenClicky today."
    let found = await h.controller.learnNow()
    #expect(found.map(\.corrected) == ["OpenClicky"])
    #expect(learned.map(\.original) == ["open clicky"])
    let saved = await h.vocabulary.load()
    #expect(saved.corrections.first?.original == "open clicky")
    // Next time, the transcript is fixed before cleanup.
    #expect(saved.applyCorrections(to: "try open clicky now") == "try OpenClicky now")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aDroppedSpeechSessionTypesWhatWasHeardWithoutWaitingForRelease() async throws {
    let system = FakeInsertionSystem()
    let focus = makeFocus("")
    system.focus = focus
    system.values["field-1"] = ""
    let services = DictationController.Services(
        focus: FixedFocusReader(focus: focus), audio: FakeMicrophone(),
        speechToText: { FailingSpeechToText(heardBeforeFailure: "remember to call the bank") }, cleaner: { nil },
        inserter: TextInserter(system: system), learnCorrections: false, resultDisplaySeconds: 60)
    let controller = DictationController(services: services)
    let (reports, continuation) = AsyncStream<DictationSessionReport>.makeStream()
    controller.onSessionFinished = { continuation.yield($0) }
    controller.handle(.chordDown(at: 0)) // still holding; the session drops on its own
    var report: DictationSessionReport?
    for await next in reports { report = next; break }
    #expect(report?.rawTranscript == "remember to call the bank")
    #expect(report?.result == .typed(appName: "TextEdit"))
    #expect(system.values["field-1"] == "Remember to call the bank")
    #expect(!controller.isCapturing)
    // Letting go afterwards is harmless.
    controller.handle(.chordUp(at: 2))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aSpeechSessionThatCannotConnectSaysSo() async throws {
    let services = DictationController.Services(
        focus: FixedFocusReader(focus: makeFocus("")), audio: FakeMicrophone(),
        speechToText: { FailingSpeechToText(heardBeforeFailure: nil) }, cleaner: { nil },
        inserter: TextInserter(system: FakeInsertionSystem()), resultDisplaySeconds: 60)
    let controller = DictationController(services: services)
    let (reports, continuation) = AsyncStream<DictationSessionReport>.makeStream()
    controller.onSessionFinished = { continuation.yield($0) }
    controller.begin()
    for await report in reports {
        #expect(report.result == .nothingHeard)
        break
    }
    guard case .failed(let message) = controller.status.phase else { Issue.record("expected a failure, got \(controller.status.phase)"); return }
    #expect(message.contains("could not connect"))
}
