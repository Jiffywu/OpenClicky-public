import Foundation
import Testing
@testable import OpenClickyKit

// Turn binding, tab ownership, tidy-up, counters and access expiry for the `browser` tool, run through the real
// bridge service, the native-host relay and a fake extension.

/// The service plus a connected fake extension that answers like the real one (tabs 101, 102 … for `open`).
private final class TurnRig: @unchecked Sendable {
    let paths: BrowserBridgePaths
    let service: BrowserBridgeService
    let client: MCPHTTPClient
    var fake: FakeExtension
    private let lock = NSLock()
    private var nextTab = 101
    private var openTabs: [Int: JSONValue] = [:]
    /// Operations the fake stays silent on (to make them time out).
    var silent: Set<String> = []
    /// The user pressed Stop and not Resume: every command is refused, as the extension does.
    var paused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }
    private var _paused = false

    init(connect: Bool = true) async throws {
        paths = try makeBridgePaths()
        service = try BrowserBridgeService(paths: paths, allowedExtensionIDs: [ChromeExtensionIdentity.extensionID])
        service.toolEnvironment.approveChange = { _ in true }
        let endpoint = try service.start()
        client = MCPHTTPClient(url: endpoint.url, token: endpoint.token, timeout: 20)
        _ = try await client.initialize()
        fake = FakeExtension(paths: paths)
        if connect { try self.connect() }
    }

    func connect(profile: String = "8a6e0c55-3f1b-4f7a-9d44-0b1c2d3e4f50") throws {
        let before = service.bridge.peers.count
        fake = FakeExtension(paths: paths)
        fake.onCommand = { [unowned self] command in self.reply(command) }
        try fake.sendHello(profile: profile)
        _ = eventually { self.service.bridge.peers.count == before + 1 }
    }

    func reply(_ command: JSONValue) -> JSONValue? {
        let operation = command["operation"]?.stringValue ?? ""
        if lock.withLock({ silent.contains(operation) }) { return nil }
        let id = command["id"] ?? .null
        let args = command["args"] ?? .object([:])
        if paused, operation != "sweep" {
            return ["type": "result", "id": id, "ok": false, "code": "paused", "error": "The user pressed Stop in the OpenClicky extension."]
        }
        switch operation {
        case "tabs":
            let opened = lock.withLock { openTabs.keys.sorted().compactMap { openTabs[$0] } }
            let base = FakeExtension.standardReply(command)["result"]?["tabs"]?.arrayValue ?? []
            return ["type": "result", "id": id, "ok": true, "result": ["tabs": .array(base + opened)]]
        case "open":
            let tab = lock.withLock { () -> Int in
                defer { nextTab += 1 }
                openTabs[nextTab] = ["id": .number(Double(nextTab)), "title": "Opened", "url": args["url"] ?? "", "active": false]
                return nextTab
            }
            return ["type": "result", "id": id, "ok": true,
                    "result": ["tabId": .number(Double(tab)), "title": "Opened", "url": args["url"] ?? "", "note": .string("Opened tab \(tab).")]]
        case "close":
            let ids = args["tabIds"]?.arrayValue ?? args["tabId"].map { [$0] } ?? []
            lock.withLock { for tab in ids { if let value = tab.intValue { openTabs[value] = nil } } }
            return ["type": "result", "id": id, "ok": true, "result": ["closed": .array(ids), "missing": []]]
        case "keep":
            return ["type": "result", "id": id, "ok": true, "result": ["tabId": args["tabId"] ?? .null, "why": args["why"] ?? "result", "kept": true]]
        case "screenshot":
            return ["type": "result", "id": id, "ok": true,
                    "result": ["tabId": 7, "mimeType": "image/jpeg", "data": .string(Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()),
                               "title": "News", "url": "https://www.news.example.com/today"]]
        case "snapshot":
            return ["type": "result", "id": id, "ok": false, "error": "Ref e9 is unknown."]
        case "click":
            return ["type": "result", "id": id, "ok": true,
                    "result": ["tabId": 7, "note": "Clicked [e2] button \"Save\".", "navigated": false, "url": "http://127.0.0.1/test",
                               "changes": ["added": [["ref": "e9", "role": "dialog", "name": "Saved"]], "removed": [], "omitted": 0]]]
        default:
            return FakeExtension.standardReply(command)
        }
    }

    func commands(_ operation: String? = nil) -> [JSONValue] {
        fake.messages.filter { $0["type"] == "command" && (operation == nil || $0["operation"]?.stringValue == operation) }
    }

    func stop() {
        fake.disconnect()
        service.stop()
        removeBridgePaths(paths)
    }
}

/// Calls the browser tool over raw HTTP so the request can carry the job header.
private func callBrowser(_ rig: TurnRig, _ arguments: JSONValue, job: String?, meta: JSONValue? = nil) async throws -> JSONValue {
    let endpoint = try #require(rig.service.endpoint)
    var params: [String: JSONValue] = ["name": "browser", "arguments": arguments]
    if let meta { params["_meta"] = meta }
    let body: JSONValue = ["jsonrpc": "2.0", "id": "1", "method": "tools/call", "params": .object(params)]
    var request = URLRequest(url: endpoint.url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
    if let job { request.setValue(job, forHTTPHeaderField: BrowserCallIdentity.jobHeader) }
    request.httpBody = Data(body.jsonString().utf8)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    let (data, _) = try await URLSession(configuration: configuration).data(for: request)
    return try JSONDecoder().decode(JSONValue.self, from: data)["result"] ?? .null
}

private func text(_ result: JSONValue) -> String {
    (result["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
}

// MARK: Identity

@Test func callIdentityComesFromCodexMetadataAndTheJobHeader() {
    let codex = BrowserCallIdentity.from(meta: ["x-codex-turn-metadata": ["thread_id": "th-1", "turn_id": "tu-1"]])
    #expect(codex == BrowserCallIdentity(jobID: nil, threadID: "th-1", turnID: "tu-1"))
    let encoded = BrowserCallIdentity.from(meta: ["x-codex-turn-metadata": .string(#"{"threadId":"th-2","turnId":"tu-2"}"#)])
    #expect(encoded.threadID == "th-2" && encoded.turnID == "tu-2")
    let header = BrowserCallIdentity.from(meta: ["x-openclicky-job": "job-7"])
    #expect(header.jobID == "job-7" && !header.isEmpty)
    #expect(BrowserCallIdentity.from(meta: nil).isEmpty)
    #expect(BrowserCallIdentity.from(meta: ["x-openclicky-job": "  "]).isEmpty)
}

@Test func theMCPServerForwardsOnlyOpenClickyHeadersAndModelsCannotForgeThem() async throws {
    let seen = MetaBox()
    let tool = MCPTool(name: "echo", description: "d", inputSchema: ["type": "object"]) { _, meta in
        seen.set(meta)
        return MCPToolResult(content: [.text("ok")])
    }
    let server = MCPHTTPServer(name: "t", version: "1", token: "tok", tools: [tool])
    let call: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                           "params": ["name": "echo", "arguments": [:], "_meta": ["x-openclicky-job": "forged", "progressToken": 3]]]
    _ = await server.handleMessage(call, headers: MCPHTTPServer.forwardedHeaders(["x-openclicky-job": "job-1", "authorization": "Bearer tok"]))
    #expect(seen.value?["x-openclicky-job"] == "job-1")
    #expect(seen.value?["authorization"] == nil)
    #expect(seen.value?["progressToken"] == 3)
    _ = await server.handleMessage(call)
    #expect(seen.value?["x-openclicky-job"] == nil, "a job id written into _meta by the caller is dropped")
}

private final class MetaBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: JSONValue?
    func set(_ value: JSONValue?) { lock.withLock { stored = value } }
    var value: JSONValue? { lock.withLock { stored } }
}

// MARK: Turns

@Test func callsAfterTheTurnEndsAreRefusedAndUnboundCallsStillWork() async throws {
    let rig = try await TurnRig()
    defer { rig.stop() }
    rig.service.turns.beginTurn(jobID: "job-1", title: "Weekly groceries")
    let bound = try await callBrowser(rig, ["operation": "tabs"], job: "job-1")
    #expect(bound["isError"] == false)
    #expect(rig.commands("tabs").last?["task"] == "job-1")

    _ = await rig.service.endTurn(jobID: "job-1")
    let late = try await callBrowser(rig, ["operation": "tabs"], job: "job-1")
    #expect(late["isError"] == true)
    #expect(text(late) == "The agent turn ended.")
    #expect(late["structuredContent"]?["kind"] == "turnEnded")
    #expect(rig.commands("tabs").count == 1, "the refused call never reached the browser")

    // Codex's thread id finds the job too.
    rig.service.turns.beginTurn(jobID: "job-1")
    rig.service.turns.noteThread(jobID: "job-1", threadID: "thread-9")
    let byThread = try await callBrowser(rig, ["operation": "tabs"], job: nil, meta: ["x-codex-turn-metadata": ["thread_id": "thread-9", "turn_id": "x"]])
    #expect(byThread["isError"] == false)
    #expect(rig.commands("tabs").last?["task"] == "job-1")

    // A call with no identity (occtl) or from a job this process never saw works unbound.
    #expect(try await callBrowser(rig, ["operation": "tabs"], job: nil)["isError"] == false)
    #expect(try await callBrowser(rig, ["operation": "tabs"], job: "someone-else")["isError"] == false)
    #expect(rig.commands("tabs").last?["task"] == "")
}

@Test func aReconnectedBrowserRefusesTheRestOfTheTurn() async throws {
    let rig = try await TurnRig()
    defer { rig.stop() }
    rig.service.turns.beginTurn(jobID: "job-2")
    #expect(try await callBrowser(rig, ["operation": "tabs"], job: "job-2")["isError"] == false)

    rig.fake.disconnect()
    #expect(eventually { rig.service.bridge.peers.isEmpty })
    try rig.connect()
    let after = try await callBrowser(rig, ["operation": "tabs"], job: "job-2")
    #expect(text(after) == "Browser connection changed. Start a new turn.")
    #expect(after["structuredContent"]?["kind"] == "connectionChanged")
    #expect(rig.commands("tabs").isEmpty, "nothing went to the new connection")

    // The next turn binds to the new connection.
    _ = await rig.service.endTurn(jobID: "job-2")
    rig.service.turns.beginTurn(jobID: "job-2")
    #expect(try await callBrowser(rig, ["operation": "tabs"], job: "job-2")["isError"] == false)
}

@Test func turnEndClosesOnlyTheTabsTheTurnOpenedAndDidNotKeep() async throws {
    let rig = try await TurnRig()
    defer { rig.stop() }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ocb-job-\(UUID().uuidString.prefix(6))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    rig.service.turns.beginTurn(jobID: "job-3", title: "Compare flight prices", folder: folder)

    let first = try await callBrowser(rig, ["operation": "open", "url": "https://example.com/a"], job: "job-3")
    #expect(first["structuredContent"]?["tabId"] == 101)
    #expect(rig.commands("open").last?["groupTitle"] == "✈️ Compare flight prices")
    _ = try await callBrowser(rig, ["operation": "open", "url": "https://example.com/b"], job: "job-3")
    _ = try await callBrowser(rig, ["operation": "open", "url": "https://example.com/c"], job: "job-3")

    // The user's own tab (7) can't be closed; a tab this job opened can.
    let foreign = try await callBrowser(rig, ["operation": "close", "tabId": 7], job: "job-3")
    #expect(foreign["isError"] == true)
    #expect(text(foreign).contains("isn't one of them"))
    #expect(rig.commands("close").isEmpty)
    let closed = try await callBrowser(rig, ["operation": "close", "tabId": 103], job: "job-3")
    #expect(text(closed) == "Closed tab 103.")
    // Another job can't close this job's tab either.
    rig.service.turns.beginTurn(jobID: "job-other")
    #expect(try await callBrowser(rig, ["operation": "close", "tabId": 101], job: "job-other")["isError"] == true)

    let kept = try await callBrowser(rig, ["operation": "keep", "tabId": 102, "why": "result"], job: "job-3")
    #expect(text(kept) == "Tab 102 stays open after this turn (result).")
    let shot = try await callBrowser(rig, ["operation": "screenshot", "save": true], job: "job-3")
    let saved = try #require(shot["structuredContent"]?["saved"]?.stringValue)
    #expect(saved.hasPrefix(folder.appendingPathComponent("output").path + "/news-example-com-"))
    #expect(saved.hasSuffix(".jpg"))
    #expect(FileManager.default.contents(atPath: saved) == Data([0xFF, 0xD8, 0xFF, 0xD9]))
    #expect(text(shot).contains("Saved to \(saved)"))
    _ = try await callBrowser(rig, ["operation": "click", "ref": "e2"], job: "job-3")
    #expect(try await callBrowser(rig, ["operation": "snapshot"], job: "job-3")["isError"] == true)

    let usage = try #require(await rig.service.endTurn(jobID: "job-3"))
    let tidy = try #require(rig.commands("close").last)
    #expect(tidy["args"]?["tabIds"] == [101], "only the opened, unkept tab; never the user's tab or the kept one")
    #expect(tidy["args"]?["tidy"] == true)
    #expect(usage.operationCount == 9)
    #expect(usage.operationCounts["open"] == 3 && usage.operationCounts["close"] == 2 && usage.operationCounts["snapshot"] == 1)
    #expect(usage.errorCount == 2, "the refused close of the user's tab and the failed snapshot; the other job's refusal is its own")
    #expect(usage.tabsOpened == 3 && usage.tabsKept == 1 && usage.tabsClosed == 2)
    #expect(usage.screenshots == 1 && usage.screenshotsSaved == 1)
    #expect(usage.endedAt != nil && !usage.stoppedByUser && !usage.accessEndedByTimeout)
    #expect(usage.summary.hasPrefix("browser: 9 calls"))

    // Keep lasts one turn: the kept tab closes at the end of the next one unless kept again.
    rig.service.turns.beginTurn(jobID: "job-3")
    _ = await rig.service.endTurn(jobID: "job-3")
    #expect(rig.commands("close").last?["args"]?["tabIds"] == [102])
}

@Test func anActingTimeoutEndsAccessButAReadTimeoutDoesNot() async throws {
    let rig = try await TurnRig()
    defer { rig.stop() }
    rig.service.toolEnvironment.timeoutLimit = 1
    rig.silent = ["click", "read"]
    rig.service.turns.beginTurn(jobID: "job-4")

    let read = try await callBrowser(rig, ["operation": "read"], job: "job-4")
    #expect(text(read).contains("Nothing was changed, so one retry is safe"))
    #expect(try await callBrowser(rig, ["operation": "tabs"], job: "job-4")["isError"] == false, "a read timeout keeps access")

    let click = try await callBrowser(rig, ["operation": "click", "ref": "e1"], job: "job-4")
    #expect(text(click).hasPrefix("Browser action timed out. Its outcome is unknown"))
    let after = try await callBrowser(rig, ["operation": "tabs"], job: "job-4")
    #expect(after["isError"] == true)
    #expect(after["structuredContent"]?["kind"] == "accessEnded")
    let usage = try #require(await rig.service.endTurn(jobID: "job-4"))
    #expect(usage.timeoutCount == 2 && usage.accessEndedByTimeout)

    // A new turn has access again.
    rig.service.turns.beginTurn(jobID: "job-4")
    #expect(try await callBrowser(rig, ["operation": "tabs"], job: "job-4")["isError"] == false)
}

@Test func afterStopTheTurnLeavesItsTabsToTheUser() async throws {
    let rig = try await TurnRig()
    defer { rig.stop() }
    rig.silent = ["wait_for"]
    rig.service.turns.beginTurn(jobID: "job-5")
    _ = try await callBrowser(rig, ["operation": "open", "url": "https://example.com"], job: "job-5")
    async let waiting = callBrowser(rig, ["operation": "wait_for", "text": "never", "timeout": 30], job: "job-5")
    #expect(eventually { !rig.commands("wait_for").isEmpty })
    try rig.fake.send(["type": "stop"])
    let stopped = try await waiting
    #expect(stopped["structuredContent"]?["kind"] == "stopped")
    let usage = try #require(await rig.service.endTurn(jobID: "job-5"))
    #expect(usage.stoppedByUser)
    #expect(rig.commands("close").isEmpty, "nothing is tidied after Stop")
}

@Test func aStopBetweenCallsAlsoHandsTheTurnsTabsToTheUser() async throws {
    let rig = try await TurnRig()
    defer { rig.stop() }
    rig.service.turns.beginTurn(jobID: "job-8")
    let binding = BrowserTurnRegistry.Binding.job(id: "job-8", turn: 1)
    _ = try await callBrowser(rig, ["operation": "open", "url": "https://shop.example.com/checkout"], job: "job-8")
    #expect(rig.service.turns.owns(101, binding))

    // Stop while the agent is thinking: nothing is in flight, but the app hears it and lets go of the tab.
    rig.paused = true
    try rig.fake.send(["type": "stop"])
    #expect(eventually { !rig.service.turns.owns(101, binding) })
    // The agent's next call is refused as the user's Stop, not as an ordinary failure.
    let refused = try await callBrowser(rig, ["operation": "tabs"], job: "job-8")
    #expect(refused["structuredContent"]?["kind"] == "stopped")
    rig.paused = false

    let usage = try #require(await rig.service.endTurn(jobID: "job-8"))
    #expect(usage.stoppedByUser)
    #expect(rig.commands("close").isEmpty, "the tab the user took over stays open")
}

@Test func aCallRefusedWhileStoppedCountsAsTheUsersStop() async throws {
    // Stop pressed while the app wasn't listening: the first the turn hears of it is a refused call.
    let rig = try await TurnRig()
    defer { rig.stop() }
    rig.service.turns.beginTurn(jobID: "job-8b")
    _ = try await callBrowser(rig, ["operation": "open", "url": "https://example.com"], job: "job-8b")
    rig.paused = true
    let refused = try await callBrowser(rig, ["operation": "click", "ref": "e1"], job: "job-8b")
    #expect(refused["structuredContent"]?["kind"] == "stopped")
    let usage = try #require(await rig.service.endTurn(jobID: "job-8b"))
    #expect(usage.stoppedByUser)
    #expect(rig.commands("close").isEmpty)
}

@Test func argumentsOutsideTheSchemaNeverReachTheBrowser() async throws {
    let rig = try await TurnRig()
    defer { rig.stop() }
    rig.service.turns.beginTurn(jobID: "job-11")
    _ = try await callBrowser(rig, ["operation": "open", "url": "https://example.com"], job: "job-11")
    // An owned tabId with the tidy-up's list riding along (a page could talk an agent into it).
    let closed = try await callBrowser(rig, ["operation": "close", "tabId": 101, "tabIds": [7, 8], "tidy": true, "task": "job-other"], job: "job-11")
    #expect(closed["isError"] == false)
    let sent = try #require(rig.commands("close").last)
    #expect(sent["args"] == ["tabId": 101])
    #expect(sent["task"] == "job-11")
}

@Test func aTurnStaysWithItsBrowserWhenAnotherOneConnects() async throws {
    let rig = try await TurnRig()
    defer { rig.stop() }
    rig.service.turns.beginTurn(jobID: "job-9")
    _ = try await callBrowser(rig, ["operation": "open", "url": "https://example.com/a"], job: "job-9")

    // A second browser (Arc) connects and becomes the newest connection.
    let arc = FakeExtension(paths: rig.paths)
    arc.onCommand = { FakeExtension.standardReply($0) }
    defer { arc.disconnect() }
    try arc.sendHello(profile: "1d0b7d2e-6a55-4c0f-9a51-3e2f7c9d8b40")
    #expect(eventually { rig.service.bridge.peers.count == 2 })
    let arcCommands = { arc.messages.filter { $0["type"] == "command" && $0["operation"] != "sweep" } }

    let later = try await callBrowser(rig, ["operation": "tabs"], job: "job-9")
    #expect(later["isError"] == false, "the turn carries on in its own browser")
    #expect(rig.commands("tabs").count == 2) // The open approval's target check and this call.

    _ = await rig.service.endTurn(jobID: "job-9")
    let tidy = try #require(rig.commands("close").last)
    #expect(tidy["args"]?["tabIds"] == [101], "the tab closes in the browser it was opened in")
    #expect(tidy["task"] == "job-9")
    #expect(arcCommands().isEmpty, "nothing of this turn went to the other browser")
}

@Test func aLateTidyUpNeverEndsTheTurnThatFollowed() async throws {
    let rig = try await TurnRig()
    defer { rig.stop() }
    rig.service.turns.beginTurn(jobID: "job-10")
    _ = try await callBrowser(rig, ["operation": "open", "url": "https://example.com/a"], job: "job-10")
    // The app ends the turn in order with the job's events; the next turn starts before the tidy-up runs.
    let ending = try #require(rig.service.turns.endTurn(jobID: "job-10"))
    rig.service.turns.beginTurn(jobID: "job-10")
    let usage = try #require(await rig.service.tidy(ending))
    #expect(usage.tabsOpened == 1)
    #expect(rig.commands("close").last?["args"]?["tabIds"] == [101])
    let next = try await callBrowser(rig, ["operation": "tabs"], job: "job-10")
    #expect(next["isError"] == false, "the next turn is still running")
}

@Test func aJobCallingWithoutABrowserAsksForChromeSetupOnce() async throws {
    let rig = try await TurnRig(connect: false)
    defer { rig.stop() }
    let asked = Counter()
    rig.service.toolEnvironment.askForChromeSetup = { job in
        asked.add(job)
        return true
    }
    rig.service.turns.beginTurn(jobID: "job-6")
    let first = try await callBrowser(rig, ["operation": "open", "url": "https://example.com"], job: "job-6")
    #expect(text(first).contains("asked the user to connect Chrome"))
    let second = try await callBrowser(rig, ["operation": "tabs"], job: "job-6")
    #expect(text(second).contains("No OpenClicky browser extension is connected"))
    #expect(asked.values == ["job-6"])
    // Calls without a job never ask.
    _ = try await callBrowser(rig, ["operation": "tabs"], job: nil)
    #expect(asked.values == ["job-6"])
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
}

@Test func aReconnectingBrowserIsToldWhichJobsStillRun() async throws {
    let rig = try await TurnRig(connect: false)
    defer { rig.stop() }
    rig.service.turns.beginTurn(jobID: "job-live")
    rig.service.turns.beginTurn(jobID: "job-done")
    _ = rig.service.turns.endTurn(jobID: "job-done")
    try rig.connect()
    #expect(eventually { !rig.commands("sweep").isEmpty })
    #expect(rig.commands("sweep").first?["args"]?["running"] == ["job-live"])
}

@Test func toolsListDescribesTheBridgeStateAndEachOperationsRisk() async throws {
    let rig = try await TurnRig(connect: false)
    defer { rig.stop() }
    rig.service.toolEnvironment.chromiumInstalled = { true }
    var tool = try #require(try await rig.client.listTools().first)
    #expect(tool["description"]?.stringValue?.contains("Right now no browser is connected") == true)
    let hints = try #require(tool["_meta"]?[BrowserTool.operationHintsKey])
    #expect(hints["snapshot"]?["readOnlyHint"] == true && hints["snapshot"]?["destructiveHint"] == false)
    #expect(hints["click"]?["readOnlyHint"] == false && hints["click"]?["destructiveHint"] == true)
    #expect(hints["close"]?["destructiveHint"] == false && hints["keep"]?["readOnlyHint"] == true)
    #expect(tool["annotations"]?["openWorldHint"] == true)

    rig.service.toolEnvironment.chromiumInstalled = { false }
    tool = try #require(try await rig.client.listTools().first)
    #expect(tool["description"]?.stringValue == BrowserTool.noChromiumDescription)

    try rig.connect()
    tool = try #require(try await rig.client.listTools().first)
    #expect(tool["description"]?.stringValue == BrowserTool.description)
}

// MARK: Launch wiring

@Test func browserServerCarriesTheJobHeaderIntoBothHarnesses() throws {
    var server = AgentMCPServer(name: "openclicky_browser", transport: .http(URL(string: "http://127.0.0.1:5/mcp")!), bearerToken: "secret")
    #expect(server.identifyingJob("job-1") == server, "servers without a job header are unchanged")
    server.jobHeaderName = BrowserCallIdentity.jobHeader
    let launched = server.identifyingJob("job-1")
    let variable = try #require(launched.secretHeaders[BrowserCallIdentity.jobHeader])
    #expect(launched.secretValues[variable] == "job-1")
    #expect(launched.harnessSecrets[variable] == "job-1")
    // Claude Code reads the value from its aliased variable; Codex from env_http_headers.
    let claude = ClaudeCodeHarness.mcpConfig([launched], aliases: ClaudeCodeHarness.mcpVariableAliases([launched]))
    #expect(claude.contains(BrowserCallIdentity.jobHeader) && !claude.contains("job-1"))
    let discovered = AgentMCPDiscovery.browserServer(file: try {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        try Data(#"{"url":"http://127.0.0.1:9/mcp","token":"t"}"#.utf8).write(to: file)
        return file
    }(), isAlive: { _ in true })
    #expect(discovered?.jobHeaderName == BrowserCallIdentity.jobHeader)
}

// MARK: Pieces

@Test func groupTitlesAndScreenshotNamesFollowTheJob() throws {
    #expect(BrowserGroupTitle.make(title: "Weekly groceries") == "🛒 Weekly groceries")
    #expect(BrowserGroupTitle.make(title: "Check my inbox") == "📧 Check my inbox")
    #expect(BrowserGroupTitle.make(title: "Something else") == "🔎 Something else")
    #expect(BrowserGroupTitle.make(title: nil) == "🔎 OpenClicky")
    #expect(BrowserScreenshotFile.slug(for: "https://www.news.example.com/x") == "news-example-com")
    #expect(BrowserScreenshotFile.slug(for: "not a url") == "page")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ocb-shot-\(UUID().uuidString.prefix(6))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let one = try BrowserScreenshotFile.save(Data([1]), url: "https://a.example", inJobFolder: folder, at: date)
    let two = try BrowserScreenshotFile.save(Data([2]), url: "https://a.example", inJobFolder: folder, at: date)
    #expect(one.deletingLastPathComponent().lastPathComponent == "output")
    #expect(two.lastPathComponent == one.deletingPathExtension().lastPathComponent + "-2.jpg")
}
