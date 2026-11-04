import Foundation
import Testing
@testable import OpenClickyKit

// Validation, timeouts and formatting for the browser tool's operations (snapshot, extract, fill, batch, close, keep
// and screenshot save), without a browser.

@Test func newOperationsAreValidatedBeforeAnythingIsSent() {
    #expect(BrowserTool.validate(.snapshot, [:]) == nil)
    #expect(BrowserTool.validate(.extract, ["maxChars": 9000]) == nil)
    #expect(BrowserTool.validate(.fill, ["ref": "e1", "text": "hello"]) == nil)
    #expect(BrowserTool.validate(.fill, ["ref": "e1"]) == "fill needs text.")
    #expect(BrowserTool.validate(.fill, ["text": "x"]) == "fill needs a ref from snapshot.")
    #expect(BrowserTool.validate(.fill, ["ref": "e1", "text": .string(String(repeating: "a", count: 20_001))]) != nil)
    #expect(BrowserTool.validate(.close, [:]) == "close needs a tabId.")
    #expect(BrowserTool.validate(.close, ["tabId": "seven"]) == "tabId must be a number from tabs or open.")
    #expect(BrowserTool.validate(.close, ["tabId": 7]) == nil)
    #expect(BrowserTool.validate(.keep, ["tabId": 7]) != nil, "keep needs a reason")
    #expect(BrowserTool.validate(.keep, ["tabId": 7, "why": "forever"]) != nil)
    #expect(BrowserTool.validate(.keep, ["tabId": 7, "why": "waiting"]) == nil)
    #expect(BrowserTool.validate(.screenshot, ["save": true]) == nil)
}

@Test func batchStepsAreCheckedOneByOneAndNothingRunsOnABadStep() {
    let good: [JSONValue] = [["operation": "open", "url": "https://example.com"], ["operation": "fill", "ref": "e1", "text": "Jeff"],
                             ["operation": "click", "ref": "e2"], ["operation": "wait_for", "text": "Hello"]]
    #expect(BrowserTool.validate(.batch, ["steps": .array(good)]) == nil)
    #expect(BrowserTool.validate(.batch, [:]) == "batch needs steps: 1 to 20 of them.")
    #expect(BrowserTool.validate(.batch, ["steps": []]) != nil)
    let tooMany = JSONValue.array(Array(repeating: ["operation": "scroll", "direction": "down"], count: 21))
    #expect(BrowserTool.validate(.batch, ["steps": tooMany])?.contains("at most 20 steps") == true)
    #expect(BrowserTool.validate(.batch, ["steps": [["operation": "click", "ref": "e1"], ["operation": "click"]]])
        == "Step 2: click needs a ref from snapshot. Nothing ran.")
    #expect(BrowserTool.validate(.batch, ["steps": [["operation": "screenshot"]]])?.hasPrefix("Step 1: screenshot can't be a batch step") == true)
    #expect(BrowserTool.validate(.batch, ["steps": [["operation": "batch"]]]) != nil, "no nested batches")
    #expect(BrowserTool.validate(.batch, ["steps": [["operation": "open", "url": "file:///etc/hosts"]]])
        == "Step 1: open needs an http(s) url. Nothing ran.")
    #expect(BrowserTool.validate(.batch, ["steps": [["operation": "click", "ref": "e1", "tabId": 3]]])?.contains("give tabId once") == true)
    #expect(BrowserTool.validate(.batch, ["steps": ["click"]]) == "Step 1 needs an operation. Nothing ran.")
    // The batchable set is exactly the page-level actions.
    #expect(Set(BrowserTool.Operation.allCases.filter(\.isBatchable).map(\.rawValue))
        == ["open", "navigate", "click", "type", "fill", "select", "press", "scroll", "wait_for", "back"])
}

@Test func batchTimeoutsAddUpButNeverOutlastTheLongestCall() {
    let short: JSONValue = [["operation": "click", "ref": "e1"], ["operation": "wait_for", "text": "x", "timeout": 5]]
    #expect(BrowserTool.timeout(for: .batch, ["steps": short]) == 10 + 20 + 5)
    let long = JSONValue.array(Array(repeating: ["operation": "open", "url": "https://example.com"], count: 20))
    #expect(BrowserTool.timeout(for: .batch, ["steps": long]) == BrowserTool.longestCall)
    #expect(BrowserTool.timeout(for: .close, [:]) == 15 && BrowserTool.timeout(for: .keep, [:]) == 15)
    #expect(BrowserTool.isReadOnlyBatch(["steps": [["operation": "wait_for", "text": "a"]]]))
    #expect(!BrowserTool.isReadOnlyBatch(["steps": short]))
}

@Test func operationClassesMatchWhatTheyDo() {
    let readOnly = Set(BrowserTool.Operation.allCases.filter(\.isReadOnly).map(\.rawValue))
    #expect(readOnly == ["status", "tabs", "read", "snapshot", "extract", "wait_for", "screenshot", "keep"])
    let destructive = Set(BrowserTool.Operation.allCases.filter(\.isDestructive).map(\.rawValue))
    #expect(destructive == ["navigate", "click", "type", "fill", "select", "press", "back", "batch"])
    #expect(readOnly.isDisjoint(with: destructive))
    #expect(BrowserTool.Operation.allCases.count == 19)
    // Room for the deferred debugger operations: none of their names is taken by something else.
    for later in ["upload", "download", "dialog", "click_at", "hover_at", "drag_at", "javascript"] {
        #expect(BrowserTool.Operation(rawValue: later) == nil)
    }
}

@Test func actionResultsListWhatChangedOnThePage() {
    let result: JSONValue = [
        "tabId": 7, "note": "Clicked [e4] button \"Say hello\".", "navigated": false, "title": "Test", "url": "http://127.0.0.1/p",
        "changes": [
            "added": [["ref": "e9", "role": "button", "name": "Undo"]],
            "removed": [["ref": "e4", "role": "button", "name": "Say hello"]],
            "omitted": 2,
        ],
    ]
    let text = BrowserTool.formatAction(.click, result)
    #expect(text.contains("Clicked [e4] button \"Say hello\". Now on tab 7: Test — http://127.0.0.1/p"))
    #expect(text.contains("Changes: 1 new, 1 gone, 2 more not listed."))
    #expect(text.contains("+ [e9] button \"Undo\""))
    #expect(text.contains("- [e4] button \"Say hello\""))
    let quiet = BrowserTool.formatAction(.scroll, ["note": "Scrolled down.", "changes": ["added": [], "removed": [], "omitted": 0]])
    #expect(quiet.hasSuffix("No elements appeared, went away or changed."))
    // A field whose value changed is one "~" line, not a removal and an addition.
    let typed = BrowserTool.formatAction(.fill, ["note": "Filled [e1].", "changes": [
        "added": [], "removed": [], "omitted": 0,
        "changed": [["ref": "e1", "role": "textbox", "name": "Your name", "value": "Grace"]],
    ]])
    #expect(typed.contains("Changes: 0 new, 0 gone, 1 changed."))
    #expect(typed.contains("~ [e1] textbox \"Your name\" value=\"Grace\""))
    let navigated = BrowserTool.formatAction(.click, ["note": "Clicked.", "navigated": true])
    #expect(navigated.contains("snapshot again") && !navigated.contains("Changes"))
    // open lists the new tab's elements, so no separate snapshot is needed.
    let opened = BrowserTool.formatAction(.open, ["tabId": 12, "note": "Opened tab 12.", "url": "https://e.com", "title": "E",
                                                  "elements": [["ref": "e1", "role": "link", "name": "Home"]], "grouped": false])
    #expect(opened.contains("[e1] link \"Home\"") && opened.contains("isn't in a tab group"))
}

@Test func snapshotExtractBatchCloseAndKeepReadWell() {
    let snapshot = BrowserTool.format(.snapshot, ["tabId": 3, "title": "T", "url": "https://e.com", "elements": [["ref": "e1", "role": "textbox", "name": "Name"]]])
    let snapshotText = snapshot.content.first.flatMap { if case .text(let t) = $0 { t } else { nil } } ?? ""
    #expect(snapshotText.contains("[e1] textbox \"Name\"") && !snapshotText.contains("Page text"))

    let extract = BrowserTool.formatExtract([
        "tabId": 3, "title": "Prices", "url": "https://e.com/p", "text": "Plans and prices", "textTruncated": true,
        "tables": [["caption": "Plans", "rows": [["Plan", "Price"], ["Basic", "$5 | month"]], "rowsOmitted": 4]],
    ])
    #expect(extract.contains("Plans and prices\n(text truncated"))
    #expect(extract.contains("Table 1: Plans\n| Plan | Price |\n| Basic | $5 / month |\n… 4 more rows"))

    let batch = BrowserTool.formatBatch([
        "tabId": 5, "title": "Form", "url": "https://e.com/f", "total": 3, "failed": 2,
        "steps": [["operation": "fill", "ok": true, "note": "Filled [e1] textbox \"Name\"."],
                  ["operation": "click", "ok": false, "error": "Ref e7 is unknown."]],
        "changes": ["added": [], "removed": [], "omitted": 0],
    ])
    #expect(batch.contains("1. fill: Filled [e1] textbox \"Name\"."))
    #expect(batch.contains("2. click: FAILED: Ref e7 is unknown."))
    #expect(batch.contains("Stopped at step 2 of 3; the steps after it didn't run."))

    #expect(BrowserTool.formatClose(["closed": [4, 5], "missing": [6]]) == "Closed tabs 4, 5. Already gone: 6.")
    #expect(BrowserTool.formatClose(["closed": [], "missing": []]) == "Nothing to close.")
    let tabs = BrowserTool.formatTabs(["tabs": [["id": 1, "title": "Mine", "url": "https://a", "mine": true], ["id": 2, "title": "Yours", "url": "https://b", "focused": true]]])
    #expect(tabs == "tab 1 (opened by this job): Mine — https://a\ntab 2 (focused): Yours — https://b")
}

@Test func aScreenshotSavedOutsideAJobSaysWhy() {
    let shot = BrowserTool.format(.screenshot, ["tabId": 1, "data": "AAAA", "title": "T", "url": "https://e.com",
                                                "note": .string(BrowserScreenshotFile.notSavedNote)])
    let caption = shot.content.first.flatMap { if case .text(let t) = $0 { t } else { nil } } ?? ""
    #expect(caption.hasSuffix("Not saved: only a job's screenshots are kept in its folder."))
    #expect(shot.structuredContent?["data"] == nil)
}

@Test func aFailedBatchStepMakesTheCallAnError() {
    let environment = BrowserToolEnvironment(bridge: nil)
    let result = BrowserTool.finish(.batch, [:], ["steps": [["operation": "click", "ok": false, "error": "x"]], "failed": 1, "total": 1],
                                    binding: .unbound, environment: environment)
    #expect(result.isError)
    let fine = BrowserTool.finish(.batch, [:], ["steps": [["operation": "click", "ok": true]], "total": 1], binding: .unbound, environment: environment)
    #expect(!fine.isError)
}
