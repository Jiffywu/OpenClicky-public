import Foundation
import Testing
@testable import OpenClickyKit

/// At key-down the app is in front but has no focused element yet; afterwards it reports `later`.
private final class LateFocusReader: FocusReading, @unchecked Sendable {
    let lock = NSLock()
    var reads = 0
    let appName: String
    let processID: Int32
    let later: CapturedFocus

    init(appName: String, processID: Int32, later: CapturedFocus) {
        self.appName = appName
        self.processID = processID
        self.later = later
    }

    func captureFocus() -> Result<CapturedFocus, FocusReadError> {
        let first = lock.withLock {
            reads += 1
            return reads == 1
        }
        return first ? .failure(.noFocusedElement(appName: appName, processID: processID)) : .success(later)
    }
}

@MainActor
private func dictate(reader: LateFocusReader, system: FakeInsertionSystem) async -> DictationSessionReport? {
    let services = DictationController.Services(
        focus: reader, audio: FakeMicrophone(), speechToText: { ScriptedSpeechToText([.final("see you at noon")]) },
        cleaner: { nil }, inserter: TextInserter(system: system, pasteRestoreDelay: 0), learnCorrections: false,
        resultDisplaySeconds: 60)
    let controller = DictationController(services: services)
    let (reports, continuation) = AsyncStream<DictationSessionReport>.makeStream()
    controller.onSessionFinished = { continuation.yield($0) }
    controller.begin()
    try? await Task.sleep(for: .milliseconds(30))
    controller.commit()
    for await report in reports { return report }
    return nil
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aFieldMissedAtKeyDownIsReadAgainInTheSameApp() async throws {
    let field = makeFocus("Hi ", appName: "Notes", pid: 42)
    let system = FakeInsertionSystem()
    system.focus = field
    system.values["field-1"] = "Hi "
    let report = try #require(await dictate(reader: LateFocusReader(appName: "Notes", processID: 42, later: field), system: system))
    #expect(report.focus?.element != nil)
    #expect(report.insertion?.outcome == .inserted(.accessibilitySelectedText))
    #expect(system.values["field-1"] == "Hi see you at noon")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func textNeverLandsInAnAppThatCameToTheFrontLater() async throws {
    // Key-down was in Notes (pid 42); by the time the words are ready, Mail (pid 77) has focus.
    let mail = makeFocus("", element: "mail-body", appName: "Mail", pid: 77)
    let system = FakeInsertionSystem()
    system.focus = mail
    system.values["mail-body"] = ""
    let report = try #require(await dictate(reader: LateFocusReader(appName: "Notes", processID: 42, later: mail), system: system))
    #expect(report.focus?.context.processID == 42)
    #expect(report.result == .copiedToClipboard(.focusLost))
    #expect(system.values["mail-body"] == "")
    #expect(system.fakePasteboard.string == "See you at noon")
}

@Test func keyDownFocusKeepsTheAppWhenTheElementIsMissing() {
    struct Failing: FocusReading {
        let error: FocusReadError
        func captureFocus() -> Result<CapturedFocus, FocusReadError> { .failure(error) }
    }
    let placeholder = DictationController.keyDownFocus(Failing(error: .noFocusedElement(appName: "Notes", processID: 42)))
    #expect(placeholder?.context.processID == 42)
    #expect(placeholder?.context.appName == "Notes")
    #expect(placeholder?.element == nil)
    #expect(placeholder?.context.isEditable == false)
    #expect(DictationController.keyDownFocus(Failing(error: .noFocusedElement(appName: "Notes"))) == nil)
    #expect(DictationController.keyDownFocus(Failing(error: .notTrusted)) == nil)
}

@MainActor @Test func theCommandVKeyIsFoundInTheCurrentLayout() {
    // On this Mac's layout some key types "v" with Command held; ANSI layouts put it at the V position.
    let code = KeyboardLayoutKeys.keyCode(typing: "v", withCommand: true)
    #expect(code != nil)
    #expect(KeyboardLayoutKeys.pasteKeyCode == code)
    #expect(KeyboardLayoutKeys.keyCode(typing: "\u{1F600}", withCommand: false) == nil)
}
