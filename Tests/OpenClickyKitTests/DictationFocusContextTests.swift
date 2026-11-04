import Foundation
import Testing
@testable import OpenClickyKit

@Test func focusContextReadsTheTextAroundTheCaret() {
    let snapshot = FocusSnapshot(appName: "Notes", bundleID: "com.apple.Notes", processID: 9, role: "AXTextArea",
                                 value: "Shopping: eggs, milk, bread", selection: UTF16Range(location: 16, length: 5),
                                 isSelectedTextSettable: true)
    let context = FocusContext(snapshot: snapshot)
    #expect(context.beforeText == "Shopping: eggs, ")
    #expect(context.selectedText == "milk,")
    #expect(context.afterText == " bread")
    #expect(context.characterCount == 27)
    #expect(context.isValueReadable && context.isEditable && !context.isSingleLine && !context.isSecure)
    #expect(context.surface == .document)
}

@Test func focusContextClipsLongTextToTheWindowWithoutSplittingEmoji() {
    let value = String(repeating: "a", count: 100) + "👍" + "bc" + String(repeating: "z", count: 100)
    let caret = 100 + 2 + 2 // after "👍bc" in UTF-16 units
    let snapshot = FocusSnapshot(role: "AXTextArea", value: value, selection: UTF16Range(location: caret, length: 0))
    let context = FocusContext(snapshot: snapshot, window: SurroundingTextWindow(before: 3, after: 2))
    // The window would start inside the emoji's surrogate pair; it moves forward instead of producing garbage.
    #expect(context.beforeText == "bc")
    #expect(context.afterText == "zz")
    let wider = FocusContext(snapshot: snapshot, window: SurroundingTextWindow(before: 4, after: 2))
    #expect(wider.beforeText == "👍bc")
}

@Test func focusContextUsesWindowsReadForLongValues() {
    let snapshot = FocusSnapshot(role: "AXTextArea", windowBefore: "…the end of a long paragraph ", windowAfter: "and more.",
                                 selection: UTF16Range(location: 90_000, length: 0), characterCount: 120_000)
    let context = FocusContext(snapshot: snapshot, window: SurroundingTextWindow(before: 10, after: 4))
    #expect(context.beforeText == "paragraph ")
    #expect(context.afterText == "and ")
    #expect(context.isValueReadable)
}

@Test func focusContextDetectsSecureAndSingleLineFields() {
    let password = FocusContext(snapshot: FocusSnapshot(role: "AXTextField", subrole: "AXSecureTextField", value: "••••",
                                                        selectedText: "••", selection: UTF16Range(location: 4, length: 0)))
    #expect(password.isSecure)
    #expect(password.beforeText.isEmpty && password.selectedText.isEmpty && !password.isValueReadable)
    #expect(password.selection == nil)

    let described = FocusContext(snapshot: FocusSnapshot(role: "AXTextField", roleDescription: "secure text field"))
    #expect(described.isSecure)

    #expect(FocusContext(snapshot: FocusSnapshot(role: "AXTextField")).isSingleLine)
    #expect(FocusContext(snapshot: FocusSnapshot(role: "AXComboBox")).isSingleLine)
    #expect(!FocusContext(snapshot: FocusSnapshot(role: "AXTextArea")).isSingleLine)
    let search = FocusContext(snapshot: FocusSnapshot(role: "AXTextField", subrole: "AXSearchField"))
    #expect(search.isSingleLine && search.surface == .search)
    // A web element that is not a text role but is writable still counts as editable.
    #expect(FocusContext(snapshot: FocusSnapshot(role: "AXGroup", isValueSettable: true)).isEditable)
    #expect(!FocusContext(snapshot: FocusSnapshot(role: "AXButton")).isEditable)
}

@Test func focusContextNamesTheSiteAndSurfaceInBrowsers() {
    let snapshot = FocusSnapshot(bundleID: "com.google.Chrome", role: "AXTextArea", value: "",
                                 url: URL(string: "https://App.Slack.com/client/T1/C2"))
    let context = FocusContext(snapshot: snapshot)
    #expect(context.siteHost == "app.slack.com")
    #expect(context.surface == .chat)
    #expect(AppTraits.surface(bundleID: "com.apple.Safari", siteHost: "www.github.dev", role: nil, subrole: nil) == .code)
    #expect(AppTraits.surface(bundleID: "com.apple.dt.Xcode", siteHost: nil, role: "AXTextArea", subrole: nil) == .code)
    #expect(AppTraits.surface(bundleID: "com.example.unknown", siteHost: nil, role: nil, subrole: nil) == .general)
}

@Test func chromiumAndElectronAppsNeedManualAccessibility() throws {
    #expect(AppTraits.needsManualAccessibility(bundleID: "com.google.Chrome", bundleURL: nil))
    #expect(AppTraits.needsManualAccessibility(bundleID: "com.tinyspeck.slackmacgap", bundleURL: nil))
    #expect(!AppTraits.needsManualAccessibility(bundleID: "com.apple.Safari", bundleURL: nil))

    // An unlisted app is recognized as Electron by the framework inside its bundle.
    let bundle = temporaryDirectory().appendingPathComponent("Some.app")
    try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
                                            withIntermediateDirectories: true)
    #expect(AppTraits.isElectron(bundleID: "com.example.some", bundleURL: bundle))
    #expect(AppTraits.needsManualAccessibility(bundleID: "com.example.some", bundleURL: bundle))
    #expect(!AppTraits.isElectron(bundleID: "com.example.some", bundleURL: bundle.deletingLastPathComponent()))
}

@Test func focusContextRoundTripsAsJSON() throws {
    let context = makeFocus("Hello", bundleID: "com.apple.mail", appName: "Mail").context
    let data = try JSONEncoder().encode(context)
    #expect(try JSONDecoder().decode(FocusContext.self, from: data) == context)
}
