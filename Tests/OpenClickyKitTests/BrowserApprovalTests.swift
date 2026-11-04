import Foundation
import Testing
@testable import OpenClickyKit

@Test(arguments: [
    JSONValue.object(["operation": "click", "tabId": 7, "ref": "e2"]),
    JSONValue.object(["operation": "open", "url": "https://example.com"]),
    JSONValue.object(["operation": "press", "tabId": 7, "key": "Enter"]),
    JSONValue.object(["operation": "batch", "tabId": 7, "steps": [["operation": "click", "ref": "e2"]]]),
])
func browserChangesWithoutAnApproverNeverReachTheExtension(arguments: JSONValue) async throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let service = try BrowserBridgeService(paths: paths)
    let endpoint = try service.start()
    defer { service.stop() }
    let fake = FakeExtension(paths: paths)
    defer { fake.disconnect() }
    fake.onCommand = FakeExtension.standardReply
    try fake.sendHello()
    try #require(eventually { service.bridge.isConnected })
    let client = MCPHTTPClient(url: endpoint.url, token: endpoint.token, timeout: 10)
    let result = try await client.callTool("browser", arguments: arguments)
    #expect(result["isError"] == true)
    #expect(fake.messages.filter { $0["type"] == "command" && $0["operation"] != "sweep" }.isEmpty)
}

private struct ApprovalRig {
    let paths: BrowserBridgePaths
    let service: BrowserBridgeService
    let fake: FakeExtension

    init() throws {
        paths = try makeBridgePaths()
        service = try BrowserBridgeService(paths: paths)
        try service.start()
        fake = FakeExtension(paths: paths)
        fake.onCommand = FakeExtension.standardReply
        try fake.sendHello()
        try #require(eventually { service.bridge.isConnected })
    }

    func close() { fake.disconnect(); service.stop(); removeBridgePaths(paths) }
    var changes: [JSONValue] { fake.messages.filter { $0["operation"] == "click" || $0["operation"] == "batch" } }
    var click: JSONValue { ["operation": "click", "ref": "e2"] }
}

@Test(arguments: [false, true])
func aBrowserChangeRunsOnlyForItsOwnApproval(approved: Bool) async throws {
    let rig = try ApprovalRig()
    defer { rig.close() }
    rig.service.toolEnvironment.approveChange = { request in
        #expect(request.operation == "click")
        #expect(request.arguments["tabId"] == 7)
        #expect(request.target?["url"] == "http://127.0.0.1/test")
        return approved
    }
    let result = await BrowserTool.perform(rig.click, meta: nil, environment: rig.service.toolEnvironment)
    #expect(result.isError == !approved)
    #expect(rig.changes.count == (approved ? 1 : 0))
    if approved { #expect(rig.changes.first?["args"]?["tabId"] == 7) }
}

@Test func readsWorkWithoutAChangeApprovalHandler() async throws {
    let rig = try ApprovalRig()
    defer { rig.close() }
    let result = await BrowserTool.perform(["operation": "read", "tabId": 7], meta: nil, environment: rig.service.toolEnvironment)
    #expect(result.isError == false)
    #expect(result.structuredContent?["text"] == "Hello from the test page.")
}

@Test func browserApprovalCannotMoveToADifferentPageOrTurn() async throws {
    let rig = try ApprovalRig()
    defer { rig.close() }
    rig.service.toolEnvironment.approveChange = { _ in
        rig.fake.onCommand = { command in
            if command["operation"] == "tabs" {
                return ["type": "result", "id": command["id"]!, "ok": true,
                        "result": ["tabs": [["id": 7, "url": "https://different.example/", "active": true]]]]
            }
            return FakeExtension.standardReply(command)
        }
        return true
    }
    let changedPage = await BrowserTool.perform(rig.click, meta: nil, environment: rig.service.toolEnvironment)
    #expect(changedPage.structuredContent?["kind"] == "approvalExpired")
    #expect(rig.changes.isEmpty)

    rig.fake.onCommand = FakeExtension.standardReply
    rig.service.turns.beginTurn(jobID: "job")
    rig.service.toolEnvironment.approveChange = { _ in
        _ = rig.service.turns.endTurn(jobID: "job")
        rig.service.turns.beginTurn(jobID: "job")
        return true
    }
    let changedTurn = await BrowserTool.perform(rig.click, meta: ["x-openclicky-job": "job"], environment: rig.service.toolEnvironment)
    #expect(changedTurn.structuredContent?["kind"] == "approvalExpired")
    #expect(rig.changes.isEmpty)
}

private actor ApprovalPause {
    var waiting = false
    var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool {
        await withCheckedContinuation { continuation in self.continuation = continuation; waiting = true }
    }
    func allow() { continuation?.resume(returning: true); continuation = nil }
}

@Test func cancelledBrowserApprovalDoesNotDispatchTheChange() async throws {
    let rig = try ApprovalRig()
    defer { rig.close() }
    let pause = ApprovalPause()
    rig.service.toolEnvironment.approveChange = { _ in await pause.wait() }
    let call = Task { await BrowserTool.perform(rig.click, meta: nil, environment: rig.service.toolEnvironment) }
    try #require(await agentEventually { await pause.waiting })
    call.cancel()
    await pause.allow()
    #expect(await call.value.structuredContent?["kind"] == "approvalDeclined")
    #expect(rig.changes.isEmpty)
}

@Test func aDeclinedBatchDoesNotRunAnyStep() async throws {
    let rig = try ApprovalRig()
    defer { rig.close() }
    rig.service.toolEnvironment.approveChange = { _ in false }
    let result = await BrowserTool.perform(["operation": "batch", "steps": [
        ["operation": "fill", "ref": "e1", "text": "private message"], ["operation": "click", "ref": "e2"],
    ]], meta: nil, environment: rig.service.toolEnvironment)
    #expect(result.structuredContent?["kind"] == "approvalDeclined")
    #expect(rig.changes.isEmpty)
}

private func browserApprovalManager(_ temp: AgentTempDir) -> AgentManager {
    AgentManager(store: AgentJobStore(paths: temp.paths), harnesses: [ScriptedHarness()]) { _ in
        AgentLaunchSettings(harness: .codex, model: nil, providerID: AgentLaunchSettings.loginProviderID, auth: .harnessLogin,
                            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"])
    }
}

@Test func aModelCannotAnswerItsOwnBrowserApproval() async throws {
    let temp = AgentTempDir()
    let manager = browserApprovalManager(temp)
    let job = try await manager.spawn(AgentSpawnRequest(task: "Review a page", title: "Review"), waitForStart: true).record
    let confirmation = Task { await manager.confirm(job.id, summary: "Allow browser click?", kind: .browserAction) }
    try #require(await agentEventually { await manager.job(job.id)?.pendingRequest?.kind == .browserAction })
    let request = try #require(await manager.job(job.id)?.pendingRequest)
    let arguments: JSONValue = ["job_id": .string(job.id), "request_id": .string(request.id), "decision": "approve", "always": true]
    let denied = await AgentTools(manager: manager).callJSON(name: "sessions_answer_request", arguments: arguments.jsonString())
    #expect(denied["status"] == "error")
    #expect(denied["message"]?.stringValue?.contains("must be confirmed in OpenClicky's user controls") == true)
    #expect(await manager.job(job.id)?.pendingRequest?.id == request.id)
    #expect(try await manager.answer(job.id, requestID: request.id, decision: .approve(always: false), fromUser: true) == .answered)
    #expect(await confirmation.value == .approve(always: false))
    #expect(await manager.job(job.id)?.pendingRequest == nil)
    await manager.shutdown()
}

@Test func cancellingABrowserConfirmationRemovesItsUserPrompt() async throws {
    let temp = AgentTempDir()
    let manager = browserApprovalManager(temp)
    let job = try await manager.spawn(AgentSpawnRequest(task: "Review a page", title: "Review"), waitForStart: true).record
    let confirmation = Task { await manager.confirm(job.id, summary: "Allow browser click?", kind: .browserAction) }
    try #require(await agentEventually { await manager.job(job.id)?.pendingRequest?.kind == .browserAction })
    confirmation.cancel()
    #expect(await confirmation.value == nil)
    #expect(await agentEventually { await manager.job(job.id)?.pendingRequest == nil })
    await manager.shutdown()
}
