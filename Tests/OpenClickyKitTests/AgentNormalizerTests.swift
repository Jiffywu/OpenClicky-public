import Foundation
import Testing
@testable import OpenClickyKit

private let folder = URL(fileURLWithPath: "/tmp/job", isDirectory: true)

@Test func recordedCodexTurnNormalizes() throws {
    var normalizer = CodexEventNormalizer(folder: folder)
    var events: [AgentEvent] = []
    for message in AgentFixtures.lines(AgentFixtures.codexTurn) {
        events += normalizer.notification(method: message["method"]?.stringValue ?? "", params: message["params"] ?? .null)
    }
    #expect(events.first == .log("Model metadata for `fake-model` not found. Defaulting to fallback metadata; this can degrade performance and cause issues."))
    #expect(events.contains(.turnStarted))
    #expect(events.contains(.progress("Running: mkdir -p output && printf hello > output/hello.txt")))
    #expect(events.contains(.usage(AgentTokenUsage(input: 240, cachedInput: 0, output: 60))))
    guard case .turnFinished(.completed, let text?, nil) = events.last else { Issue.record("\(events)"); return }
    let report = AgentFinalReport.parse(text)
    #expect(report.spoken == "Done. I wrote hello into output/hello.txt.")
    #expect(report.title == "Hello File")
    #expect(report.files == ["output/hello.txt"])
    #expect(report.markdown == "I created output/hello.txt with the word hello.")
    // Only one agent message: nothing was commentary.
    #expect(!events.contains { if case .commentary = $0 { true } else { false } })
}

@Test func recordedCodexApprovalRequestMapsAndAnswers() throws {
    let message = try JSONValue.parse(AgentFixtures.codexApprovalRequest)
    let method = try #require(message["method"]?.stringValue)
    let request = try #require(CodexEventNormalizer.approvalRequest(method: method, id: "0", params: message["params"] ?? .null))
    #expect(request.kind == .command)
    #expect(request.summary == "Run mkdir -p output && printf hello > output/hello.txt")
    #expect(request.reason == "Needs to write outside the sandbox")
    let params = message["params"] ?? .null
    #expect(CodexEventNormalizer.response(method: method, params: params, decision: .approve(always: false)) == ["decision": "accept"])
    // acceptForSession isn't offered here, so "always" falls back to accept.
    #expect(CodexEventNormalizer.response(method: method, params: params, decision: .approve(always: true)) == ["decision": "accept"])
    #expect(CodexEventNormalizer.response(method: method, params: params, decision: .decline) == ["decision": "decline"])
}

@Test func codexQuestionsAndPermissionRequests() {
    let question: JSONValue = ["threadId": "t", "turnId": "u", "itemId": "i", "isBlocking": true,
                               "questions": [["id": "q1", "header": "Format", "question": "PDF or Word?", "options": [["label": "PDF"], ["label": "Word"]]]]]
    let request = CodexEventNormalizer.approvalRequest(method: "item/tool/requestUserInput", id: "7", params: question)
    #expect(request?.kind == .question)
    #expect(request?.summary == "PDF or Word?")
    #expect(request?.options == ["PDF", "Word"])
    #expect(CodexEventNormalizer.response(method: "item/tool/requestUserInput", params: question, decision: .answer("PDF"))
            == ["answers": ["q1": ["answers": ["PDF"]]]])

    let permissions: JSONValue = ["threadId": "t", "turnId": "u", "itemId": "i", "permissions": ["network": ["enabled": true], "fileSystem": .null]]
    #expect(CodexEventNormalizer.approvalRequest(method: "item/permissions/requestApproval", id: "8", params: permissions)?.summary == "Allow network access")
    #expect(CodexEventNormalizer.response(method: "item/permissions/requestApproval", params: permissions, decision: .approve(always: true))
            == ["permissions": ["network": ["enabled": true], "fileSystem": .null], "scope": "session"])
    #expect(CodexEventNormalizer.approvalRequest(method: "account/chatgptAuthTokens/refresh", id: "9", params: [:]) == nil)
}

@Test func codexCommentaryReasoningAndFailures() {
    var normalizer = CodexEventNormalizer(folder: folder)
    _ = normalizer.notification(method: "turn/started", params: ["turn": ["id": "u"]])
    #expect(normalizer.notification(method: "item/completed", params: ["item": ["type": "reasoning", "id": "r", "summary": ["**Checking the sources**\n\nI will look…"]]])
            == [.thinking("Checking the sources")])
    #expect(normalizer.notification(method: "item/completed", params: ["item": ["type": "agentMessage", "id": "a", "text": "Looking now.", "phase": "commentary"]])
            == [.commentary("Looking now.")])
    #expect(normalizer.notification(method: "item/completed", params: ["item": ["type": "agentMessage", "id": "b", "text": "First draft."]]) == [])
    #expect(normalizer.notification(method: "item/completed", params: ["item": ["type": "agentMessage", "id": "c", "text": "Final."]]) == [.commentary("First draft.")])
    #expect(normalizer.notification(method: "item/completed", params: ["item": ["type": "commandExecution", "id": "x", "command": "/bin/zsh -lc 'false'", "status": "failed", "exitCode": 1]])
            == [.progress("Command failed (exit 1): false")])
    #expect(normalizer.notification(method: "error", params: ["error": ["message": "stream disconnected"], "willRetry": true])
            == [.error("stream disconnected", fatal: false)])
    #expect(normalizer.notification(method: "turn/completed", params: ["turn": ["id": "u", "status": "failed", "items": [], "error": ["message": "quota"]]])
            == [.turnFinished(.failed, finalText: "Final.", error: "quota")])
}

@Test func recordedClaudeTurnNormalizes() throws {
    var normalizer = ClaudeEventNormalizer(folder: folder)
    var events: [AgentEvent] = []
    var permission: AgentApprovalRequest?
    for message in AgentFixtures.lines(AgentFixtures.claudeTurn) {
        if message["type"]?.stringValue == "control_request" {
            permission = ClaudeEventNormalizer.approvalRequest(id: message["request_id"]?.stringValue ?? "", request: message["request"] ?? .null)
        }
        events += normalizer.message(message)
    }
    #expect(events.first == .sessionStarted(threadID: "b90579e4-1fc1-44da-b0ca-1f1409ecbec2"))
    #expect(events.contains(.progress("Running: Write hello file")))
    #expect(permission?.summary == "Run mkdir -p output && printf hello > output/hello.txt")
    #expect(permission?.reason == "Write hello file")
    #expect(events.contains(.usage(AgentTokenUsage(input: 200, cachedInput: 0, output: 40))))
    guard case .turnFinished(.completed, let text?, nil) = events.last else { Issue.record("\(events)"); return }
    #expect(AgentFinalReport.parse(text).spoken == "Done. I wrote hello into output/hello.txt.")
}

@Test func claudeFailuresSubagentsAndRetries() {
    var normalizer = ClaudeEventNormalizer(folder: folder)
    #expect(normalizer.message(["type": "system", "subtype": "api_retry", "attempt": 2, "max_retries": 10])
            == [.error("Model request failed; retrying (2 of 10)", fatal: false)])
    // A subagent's text is progress, not the report.
    #expect(normalizer.message(["type": "assistant", "parent_tool_use_id": "toolu_9", "message": ["content": [["type": "text", "text": "Sub result"]]]])
            == [.commentary("Sub result")])
    #expect(normalizer.message(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "t1", "name": "mcp__browser__extract", "input": [:]]]]])
            == [.progress("Using browser: extract")])
    #expect(normalizer.message(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "is_error": true]]]])
            == [.progress("mcp__browser__extract didn't work")])
    #expect(normalizer.message(["type": "result", "subtype": "error_max_turns", "is_error": true, "errors": ["Reached the turn limit"]])
            == [.turnFinished(.failed, finalText: nil, error: "Reached the turn limit")])
}

// MARK: - Final report parsing

@Test func finalReportBlockIsParsed() {
    let text = """
    **Three flights** under $400. The best is Tuesday.

    | Flight | Price |
    |---|---|
    | UA 12 | $312 |

    <REPORT>
    say: I found three flights under four hundred dollars; Tuesday's is cheapest.
    title: Cheap Flights To Denver
    files:
    - output/flights.csv
    - `output/notes.md`
    next:
    - Book the Tuesday flight
    - Watch prices for a week
    question: none
    </REPORT>
    """
    let report = AgentFinalReport.parse(text)
    #expect(report.spoken == "I found three flights under four hundred dollars; Tuesday's is cheapest.")
    #expect(report.title == "Cheap Flights To Denver")
    #expect(report.files == ["output/flights.csv", "output/notes.md"])
    #expect(report.nextSteps == ["Book the Tuesday flight", "Watch prices for a week"])
    #expect(report.question == nil)
    #expect(report.markdown.hasPrefix("**Three flights**"))
    #expect(report.markdown.hasSuffix("| UA 12 | $312 |"))
}

@Test func finalReportWithoutBlockSpeaksTheFirstSentence() {
    let report = AgentFinalReport.parse("## Result\n**Done:** the [spreadsheet](https://x.test) has 40 rows. More below.")
    #expect(report.spoken == "Result")
    let plain = AgentFinalReport.parse("The spreadsheet has **40 rows** now. I also fixed the dates.")
    #expect(plain.spoken == "The spreadsheet has 40 rows now.")
    #expect(plain.files.isEmpty)
}

@Test func finalReportToleratesMissingCloseTagAndQuestions() {
    let report = AgentFinalReport.parse("Stuck on one thing.\n<report>\nsay: I need your login to continue.\nquestion: Which account should I use?\n")
    #expect(report.spoken == "I need your login to continue.")
    #expect(report.question == "Which account should I use?")
    #expect(report.markdown == "Stuck on one thing.")
}

@Test func reportFilesResolveInsideTheFolderAndSkipScratch() throws {
    let temp = AgentTempDir()
    let job = temp.url.appendingPathComponent("job", isDirectory: true)
    for path in ["output/a.txt", "tmp/b.txt"] {
        let url = job.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
    }
    let report = AgentFinalReport(markdown: "", spoken: "", files: ["output/a.txt", "tmp/b.txt", "output/missing.txt", "https://example.com/x"])
    let resolved = report.resolvedFiles(in: job)
    #expect(resolved.map(\.lastPathComponent) == ["a.txt", "x"])
}

@Test func multiLineCommandsBecomeOneProgressLine() {
    var codex = CodexEventNormalizer(folder: folder)
    let heredoc = "python3 - <<'PY'\nfrom pathlib import Path\nPath('output/hello.txt').write_text('hello')\nPY"
    let events = codex.notification(method: "item/started", params: ["item": ["type": "commandExecution", "id": "c", "command": .string(heredoc),
                                                                              "commandActions": [["type": "unknown", "command": .string(heredoc)]]]])
    #expect(events == [.progress("Running: python3 - <<'PY' from pathlib import Path Path('output/hello.txt').write_text('hello') PY")])
    #expect(ClaudeEventNormalizer.toolStarted(name: "Bash", input: ["command": "ls\n  -la"]) == [.progress("Running: ls -la")])
    #expect(AgentText.oneLine("a\n\n  b\tc", limit: 4) == "a b…")
}
