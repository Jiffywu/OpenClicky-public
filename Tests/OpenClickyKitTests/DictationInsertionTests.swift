import Foundation
import Testing
@testable import OpenClickyKit

// MARK: Strategy table

@Test func strategyOrderForNativeFields() {
    let table = InsertionStrategyTable.standard
    let textArea = makeFocus("notes", bundleID: "com.apple.Notes", role: "AXTextArea").context
    #expect(table.strategies(for: textArea) == [.accessibilitySelectedText, .paste, .typing])
    let textField = makeFocus("subject", bundleID: "com.apple.mail", role: "AXTextField").context
    #expect(table.strategies(for: textField) == [.accessibilitySelectedText, .accessibilityValue, .paste, .typing])
}

@Test func strategyOrderForTerminalsBrowsersElectronAndCustomViews() {
    let table = InsertionStrategyTable.standard
    for bundleID in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.google.Chrome", "com.apple.Safari",
                     "com.tinyspeck.slackmacgap", "com.sublimetext.4", "com.tencent.xinWeChat", "com.openai.chat",
                     "com.jetbrains.intellij"] {
        let context = makeFocus("", bundleID: bundleID, role: "AXTextArea").context
        #expect(table.strategies(for: context) == [.paste, .typing], "\(bundleID)")
    }
    // An unlisted app detected as Electron at runtime.
    let unknown = makeFocus("", bundleID: "com.example.someelectronapp", role: "AXTextArea").context
    #expect(table.strategies(for: unknown) == [.accessibilitySelectedText, .paste, .typing])
    #expect(table.strategies(for: unknown, isElectron: true) == [.paste, .typing])
    // Something that isn't a text element (a canvas, a web view without AX text): paste or type.
    var canvas = makeFocus("", bundleID: "com.example.paint", role: "AXGroup").context
    canvas.isEditable = false
    #expect(table.strategies(for: canvas) == [.paste, .typing])
}

@Test func perAppOverridesWin() {
    let table = InsertionStrategyTable(overrides: ["com.apple.Notes": [.typing], "com.apple.Terminal": [.typing]])
    #expect(table.strategies(for: makeFocus("", bundleID: "com.apple.Notes").context) == [.typing])
    #expect(table.strategies(for: makeFocus("", bundleID: "com.apple.Terminal").context) == [.typing])
    #expect(table.strategies(for: makeFocus("", bundleID: "com.apple.TextEdit").context).first == .accessibilitySelectedText)
}

// MARK: Inserter

@Test func insertsThroughAccessibilityIntoANativeField() async {
    let system = FakeInsertionSystem()
    let focus = makeFocus("Hello", caret: 5)
    system.focus = focus
    system.values["field-1"] = "Hello"
    system.selections["field-1"] = UTF16Range(location: 5, length: 0)
    let report = await TextInserter(system: system).insert("world.", into: focus)
    #expect(report.outcome == .inserted(.accessibilitySelectedText))
    #expect(report.insertedText == " world.")
    #expect(system.values["field-1"] == "Hello world.")
    #expect(system.fakePasteboard.transientWrites.isEmpty)
}

@Test func accessibilityWriteThatIsIgnoredFallsBackToPaste() async {
    let system = FakeInsertionSystem()
    let focus = makeFocus("", caret: 0)
    system.focus = focus
    system.values["field-1"] = ""
    system.axSelectedTextBehavior = .ignored
    system.fakePasteboard.simulateUserCopy("user clipboard")
    let report = await TextInserter(system: system).insert("Typed by voice", into: focus)
    #expect(report.outcome == .inserted(.paste))
    #expect(report.attempts.map(\.strategy) == [.accessibilitySelectedText, .paste])
    #expect(report.attempts[0].note == "AX write had no effect")
    #expect(system.pastes.count == 1)
    #expect(system.pastes[0].clipboard == "Typed by voice")
    // The user's clipboard is back afterwards.
    #expect(system.fakePasteboard.string == "user clipboard")
}

@Test func terminalsGetPasteAndNeverANewline() async {
    let system = FakeInsertionSystem()
    let focus = makeFocus("$ ", bundleID: "com.apple.Terminal", appName: "Terminal")
    system.focus = focus
    let report = await TextInserter(system: system).insert("git status\nls -la", into: focus)
    #expect(report.outcome == .inserted(.paste))
    #expect(report.insertedText == "git status ls -la")
    #expect(!system.pastes[0].clipboard!.contains("\n"))
}

@Test func typingIsTheLastResortBeforeTheClipboard() async {
    let system = FakeInsertionSystem()
    let focus = makeFocus("", bundleID: "com.google.Chrome", appName: "Chrome")
    system.focus = focus
    system.pasteWorks = false
    let report = await TextInserter(system: system).insert("hello", into: focus)
    #expect(report.outcome == .inserted(.typing))
    #expect(system.typed == ["hello"])

    system.typingWorks = false
    let failed = await TextInserter(system: system).insert("hello", into: focus)
    #expect(failed.outcome == .copiedToClipboard(.strategiesFailed))
    #expect(failed.copiedToClipboard)
    #expect(system.fakePasteboard.string == "hello")
}

@Test func typedLineBreaksInChatAppsUseShiftReturn() async {
    let system = FakeInsertionSystem()
    system.pasteWorks = false
    let slack = makeFocus("", bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")
    system.focus = slack
    #expect(await TextInserter(system: system).insert("first line\nsecond line", into: slack).outcome == .inserted(.typing))
    let notes = makeFocus("", bundleID: "com.google.Chrome", appName: "Chrome")
    system.focus = notes
    _ = await TextInserter(system: system).insert("first line\nsecond line", into: notes)
    #expect(system.typedWithShiftNewlines == [true, false])
    #expect(system.typed == ["first line\nsecond line", "first line\nsecond line"])
}

@Test func lateAccessibilityUpdatesAreNotTypedTwice() async {
    let system = FakeInsertionSystem()
    let focus = makeFocus("", caret: 0)
    system.focus = focus
    system.values["field-1"] = ""
    system.axSelectedTextBehavior = .ignored
    // The app applies the write a moment later.
    system.duringPastePause = { system.values["field-1"] = "Late but there" }
    let report = await TextInserter(system: system).insert("Late but there", into: focus)
    #expect(report.outcome == .inserted(.accessibilitySelectedText))
    #expect(system.pastes.isEmpty)
}

@Test func refusesSecureFieldsAndSecureEventInputWithoutTouchingTheClipboard() async {
    let system = FakeInsertionSystem()
    system.fakePasteboard.simulateUserCopy("keep me")
    let password = makeFocus("", role: "AXTextField", subrole: "AXSecureTextField")
    #expect(password.context.isSecure)
    system.focus = password
    let refused = await TextInserter(system: system).insert("hunter two", into: password)
    #expect(refused.outcome == .refused(.secureField))
    #expect(!refused.copiedToClipboard)

    let field = makeFocus("")
    system.focus = field
    system.secureInput = true
    let blocked = await TextInserter(system: system).insert("hello there", into: field)
    #expect(blocked.outcome == .refused(.secureEventInput))
    #expect(system.fakePasteboard.string == "keep me")
    #expect(system.pastes.isEmpty && system.typed.isEmpty)

    // Focus moved into a password field after the key went down.
    system.secureInput = false
    system.focus = makeFocus("", pid: 42, role: "AXTextField", subrole: "AXSecureTextField")
    #expect(await TextInserter(system: system).insert("hello", into: field).outcome == .refused(.secureField))
}

@Test func focusMovedToAnotherAppLeavesTheTextOnTheClipboard() async {
    let system = FakeInsertionSystem()
    let captured = makeFocus("", pid: 42)
    system.focus = makeFocus("", element: "other", bundleID: "com.apple.Safari", pid: 77)
    let report = await TextInserter(system: system).insert("Remember the milk", into: captured)
    #expect(report.outcome == .copiedToClipboard(.focusLost))
    #expect(system.fakePasteboard.string == "Remember the milk")
}

@Test func withoutAccessibilityTheTextIsSalvagedToTheClipboard() async {
    let system = FakeInsertionSystem()
    system.trusted = false
    let report = await TextInserter(system: system).insert("Salvage me", into: makeFocus(""))
    #expect(report.outcome == .refused(.accessibilityPermission))
    #expect(report.copiedToClipboard)
    #expect(system.fakePasteboard.string == "Salvage me")
}

@Test func valueRewriteHandlesASelectionInAOneLineField() async {
    let system = FakeInsertionSystem()
    let snapshot = FocusSnapshot(appName: "Mail", bundleID: "com.apple.mail", processID: 42, role: "AXTextField",
                                 value: "Meet at 3pm today", selection: UTF16Range(location: 8, length: 3),
                                 isValueSettable: true, isSelectedTextSettable: true)
    let captured = CapturedFocus(context: FocusContext(snapshot: snapshot), element: FocusElement("field-1" as NSString))
    #expect(captured.context.selectedText == "3pm")
    system.focus = captured
    system.values["field-1"] = "Meet at 3pm today"
    system.axSelectedTextBehavior = .refused
    let report = await TextInserter(system: system).insert("4pm", into: captured)
    #expect(report.outcome == .inserted(.accessibilityValue))
    #expect(system.values["field-1"] == "Meet at 4pm today")
    #expect(system.selections["field-1"] == UTF16Range(location: 11, length: 0))
}

@Test func nothingToInsertForBlankText() async {
    let report = await TextInserter(system: FakeInsertionSystem()).insert("  \n ", into: makeFocus(""))
    #expect(report.outcome == .nothingToInsert)
}

// MARK: Spacing and key chunks

@Test func insertionSpacingFitsTheCaret() {
    #expect(InsertionText.prepare("world", before: "Hello", after: "", singleLine: false) == " world")
    #expect(InsertionText.prepare("world", before: "Hello ", after: "", singleLine: false) == "world")
    #expect(InsertionText.prepare("big", before: "a ", after: "dog", singleLine: false) == "big ")
    #expect(InsertionText.prepare(", right?", before: "Okay", after: "", singleLine: false) == ", right?")
    #expect(InsertionText.prepare("name", before: "(", after: ")", singleLine: false) == "name")
    #expect(InsertionText.prepare("一起吃饭", before: "我们", after: "", singleLine: false) == "一起吃饭")
    #expect(InsertionText.prepare("line one\n\nline two", before: "", after: "", singleLine: true) == "line one line two")
    #expect(InsertionText.prepare("line one\nline two", before: "", after: "", singleLine: false) == "line one\nline two")
}

@Test func typingChunksNeverSplitCharactersAndSendNewlinesAsReturn() {
    let chunks = KeyTypingChunks.split("ab👍🏽c\nd", maxUnits: 4)
    #expect(chunks.last == .text(Array("d".utf16)))
    #expect(chunks.contains(.newline))
    let joined = chunks.compactMap { if case .text(let u) = $0 { String(decoding: u, as: UTF16.self) } else { nil } }.joined()
    #expect(joined == "ab👍🏽cd")
    for case .text(let units) in chunks { #expect(String(utf16CodeUnits: units, count: units.count).unicodeScalars.allSatisfy { $0.value != 0xFFFD }) }
}

// MARK: Pasteboard save and restore

@Test func pasteRestoresEveryItemAndType() async {
    let system = FakeInsertionSystem()
    let image = Data([0x89, 0x50, 0x4E, 0x47])
    let original = PasteboardSnapshot(items: [
        .init([.init(type: "public.utf8-plain-text", data: Data("first".utf8)), .init(type: "public.html", data: Data("<b>first</b>".utf8))]),
        .init([.init(type: "public.png", data: image)]),
    ])
    system.fakePasteboard.restore(original)
    let focus = makeFocus("", bundleID: "com.google.Chrome")
    system.focus = focus
    let report = await TextInserter(system: system, pasteRestoreDelay: 0.3).insert("pasted", into: focus)
    #expect(report.outcome == .inserted(.paste))
    #expect(system.pauses == [0.3])
    #expect(system.fakePasteboard.transientWrites == ["pasted"])
    #expect(system.fakePasteboard.snapshot() == original)
}

@Test func pasteLeavesTheClipboardAloneIfTheUserCopiesMeanwhile() async {
    let system = FakeInsertionSystem()
    system.fakePasteboard.simulateUserCopy("old")
    let focus = makeFocus("", bundleID: "com.google.Chrome")
    system.focus = focus
    system.duringPastePause = { system.fakePasteboard.simulateUserCopy("copied during paste") }
    _ = await TextInserter(system: system).insert("pasted", into: focus)
    #expect(system.fakePasteboard.string == "copied during paste")
}

@Test func transientWritesAreMarkedForClipboardManagers() {
    let pasteboard = InMemoryPasteboard()
    let count = pasteboard.writeTransientText("secret-ish")
    #expect(count == pasteboard.changeCount)
    let types = pasteboard.snapshot().items.first?.representations.map(\.type) ?? []
    #expect(types.contains(PasteboardMarkers.transient))
    #expect(types.contains(PasteboardMarkers.autoGenerated))
    // An empty snapshot restores to an empty clipboard.
    pasteboard.restore(PasteboardSnapshot(items: []))
    #expect(pasteboard.snapshot().isEmpty)
}
