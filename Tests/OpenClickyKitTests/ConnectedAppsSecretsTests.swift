import Foundation
import Testing
@testable import OpenClickyKit

// Secret headers and environment values from the connector form, the connectors section of the always-on
// instructions, and the rule that a turn which read connected apps doesn't act.

private func scratchRegistryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-connectors-\(UUID().uuidString)/connectors.json")
}

@Test func formSecretLinesGoToTheCredentialStoreAndNeverToConnectorsJSON() throws {
    let url = scratchRegistryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let credentials = InMemoryCredentialStore()
    var registry = ConnectorRegistry()

    let remote = ConnectorDraft(name: "Helpdesk", transport: .remote(URL(string: "https://helpdesk.example/mcp")!), auth: .bearer,
                                token: "tok-SECRET-1", accountLabel: "Work",
                                headerLines: "X-Api-Key: key-SECRET-2\n\n# a comment\nX-Workspace : ws-SECRET-3\nx-api-key: key-SECRET-4")
    let savedRemote = try remote.save(into: &registry, credentials: credentials)
    let command = ConnectorDraft(name: "Files", transport: .stdio(command: "npx", arguments: ["-y", "files-mcp"]),
                                 environmentLines: "FILES_TOKEN=env-SECRET-5\nREGION = eu-SECRET-6")
    let savedCommand = try command.save(into: &registry, credentials: credentials)
    try registry.save(to: url)

    // The file names each header and variable and the credential holding it, never a value.
    let text = try String(contentsOf: url, encoding: .utf8)
    for secret in ["tok-SECRET-1", "key-SECRET-2", "ws-SECRET-3", "key-SECRET-4", "env-SECRET-5", "eu-SECRET-6", "SECRET"] {
        #expect(!text.contains(secret), "connectors.json holds \(secret)")
    }
    let reloaded = try ConnectorRegistry.load(from: url)
    let helpdesk = try #require(reloaded.connector(id: savedRemote.id))
    #expect(helpdesk.auth == .bearer && helpdesk.accountLabel == "Work")
    // A later line for the same header (any case) replaces the earlier one.
    #expect(helpdesk.secretHeaders == ["x-api-key": ConnectorSecretNames.header("helpdesk", "x-api-key"),
                                       "X-Workspace": ConnectorSecretNames.header("helpdesk", "X-Workspace")])
    #expect(try credentials.secret(named: ConnectorSecretNames.header("helpdesk", "x-api-key")) == "key-SECRET-4")
    #expect(try credentials.secret(named: ConnectorSecretNames.header("helpdesk", "X-Workspace")) == "ws-SECRET-3")
    #expect(try credentials.secret(named: ConnectorSecretNames.bearer("helpdesk")) == "tok-SECRET-1")
    let files = try #require(reloaded.connector(id: savedCommand.id))
    #expect(files.environment == ["FILES_TOKEN": "connector-files-env-files-token", "REGION": "connector-files-env-region"])
    #expect(try credentials.secret(named: "connector-files-env-files-token") == "env-SECRET-5")

    // Every secret it names is stored, so both are ready to use.
    #expect(ConnectedAppsHub.summaries(of: reloaded, credentials: credentials).map(\.status) == [.ready, .ready])

    // Adding more later, then forgetting one.
    var updated = try ConnectorSecretLines.apply(try ConnectorSecretLines.parse("X-Region: r-SECRET-7", kind: .header), kind: .header,
                                                 to: helpdesk, credentials: credentials)
    #expect(updated.secretHeaders?.keys.sorted() == ["X-Region", "X-Workspace", "x-api-key"])
    updated = ConnectorSecretLines.remove("X-Workspace", kind: .header, from: updated, credentials: credentials)
    #expect(updated.secretHeaders?["X-Workspace"] == nil)
    #expect(try credentials.secret(named: ConnectorSecretNames.header("helpdesk", "X-Workspace")) == nil)
}

@Test func badSecretLinesSaveNothing() throws {
    let credentials = InMemoryCredentialStore()
    var registry = ConnectorRegistry()
    let cases: [(String, ConnectorTransport, ConnectorSecretLines.Problem)] = [
        ("X-Api-Key key", .remote(URL(string: "https://a.example/mcp")!), .malformed(line: 1, kind: .header)),
        ("Authorization: Bearer x", .remote(URL(string: "https://a.example/mcp")!), .authorizationHeader),
        ("Bad Header: x", .remote(URL(string: "https://a.example/mcp")!), .badName("Bad Header", kind: .header)),
        ("X-Empty:", .remote(URL(string: "https://a.example/mcp")!), .emptyValue("X-Empty")),
    ]
    for (lines, transport, problem) in cases {
        #expect(throws: problem) {
            try ConnectorDraft(name: "A", transport: transport, headerLines: lines).save(into: &registry, credentials: credentials)
        }
    }
    #expect(throws: ConnectorSecretLines.Problem.badName("lower_case", kind: .environment)) {
        try ConnectorDraft(name: "B", transport: .stdio(command: "x", arguments: []), environmentLines: "lower_case=1")
            .save(into: &registry, credentials: credentials)
    }
    #expect(registry.connectors.isEmpty)
    #expect(try credentials.storedNames().isEmpty)
    #expect(ConnectorSecretLines.Problem.malformed(line: 2, kind: .environment).description == "Line 2 needs the form NAME=value.")
}

@Test func alwaysOnInstructionsListConnectedAppsByNameAndWhatTheyHold() {
    func app(_ id: String, _ name: String, label: String? = nil, about: String?, status: ConnectedAppSummary.Status) -> ConnectedAppSummary {
        ConnectedAppSummary(id: id, name: name, accountLabel: label, kind: .remote, capability: about, status: status, allowsWrites: false,
                            location: "https://\(id).example/mcp")
    }
    let apps = [
        app("notion", "Notion", label: "Work", about: "Pages, databases and comments", status: .ready),
        app("linear", "Linear", about: nil, status: .ready),
        app("github", "GitHub", about: "Repos and issues", status: .needsSignIn),
        app("drive", "Drive", about: "Files", status: .disabled),
    ]
    let text = RealtimeInstructions.alwaysOn(toolNames: [ReadConnectedApps.toolName], connectedApps: apps)
    #expect(text.contains("The user's connected apps:\n- Notion (Work): Pages, databases and comments\n- Linear\n"))
    #expect(text.contains("Waiting on the user (sign-in or a key, in Settings → Connected Apps): GitHub."))
    #expect(!text.contains("Drive"), "an app the user turned off isn't mentioned")
    #expect(text.contains("read_connected_apps") && text.contains("don't open pages or start actions in the same reply"))
    // Without the read tool there is no advice to use it; without apps there is no section.
    let noTool = RealtimeInstructions.alwaysOn(connectedApps: apps)
    #expect(noTool.contains("- Notion (Work)") && !noTool.contains("look with read_connected_apps"))
    #expect(!RealtimeInstructions.alwaysOn(toolNames: [ReadConnectedApps.toolName]).contains("connected apps:"))
    let nothingReady = RealtimeInstructions.connectedAppsSection([apps[2]], canRead: true)
    #expect(nothingReady?.contains("- none can be used right now") == true)
    #expect(nothingReady?.contains("look with read_connected_apps") == false)
}

extension BrainRuntimeTests {
    @Test func aTurnThatReadConnectedAppsDoesNotOpenALinkAfterwards() async throws {
        let read = BrainProbeTool(ReadConnectedApps.toolName, kind: .read, result: ["status": "ok", "text": "Standup moved to 10:30."])
        let open = BrainProbeTool("open_url", kind: .deferredAction, result: ["status": "ok"])
        let show = BrainProbeTool("show_result", kind: .deferredAction, result: ["status": "ok"])
        let model = BrainScriptModel([
            [.call("r1", ReadConnectedApps.toolName, #"{"request":"when is standup"}"#), .finish(.toolCalls)],
            [.text("```js\nsay(\"Standup moved to 10:30. Opening the invite.\")\n```"),
             .call("o1", "open_url", #"{"url":"https://calendar.example/standup"}"#),
             .call("s1", "show_result", #"{"job":"notes"}"#), .finish(.toolCalls)],
            // The next turn, asked on its own.
            [.text("```js\nsay(\"Opening it.\")\n```"), .call("o2", "open_url", #"{"url":"https://calendar.example/standup"}"#), .finish(.toolCalls)],
        ])
        let runtime = BrainFixtures.runtime(model, tools: [read, open, show])
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("When is standup? Open the invite."))
        #expect(read.runs.count == 1)
        let deferred = events.compactMap { if case .deferredAction(let action) = $0 { action } else { nil } }
        try #require(deferred.map(\.name) == ["open_url", "show_result"])

        // After the narration the link stays closed, with a line for the user; a result card still shows.
        let refused = await runtime.performDeferred(deferred[0])
        #expect(open.runs.isEmpty)
        #expect(refused["status"] == "refused")
        #expect(ConnectedAppsReadGuard.note(in: refused) == ConnectedAppsReadGuard.spokenNote)
        #expect(!BrainToolResults.succeeded(refused))
        let shown = await runtime.performDeferred(deferred[1])
        #expect(show.runs.count == 1 && BrainToolResults.succeeded(shown))

        // The next turn hears why, and asking again on its own opens it.
        let next = try await BrainFixtures.events(runtime, BrainFixtures.input("Open the invite please."))
        try #require(model.requests.count == 3)
        let notes = model.requests[2].messages.last?.content.first.flatMap { if case .text(let text) = $0 { text } else { nil } } ?? ""
        #expect(notes.contains("[App] open_url did not work (refused)."))
        let again = next.compactMap { if case .deferredAction(let action) = $0 { action } else { nil } }
        try #require(again.map(\.name) == ["open_url"])
        _ = await runtime.performDeferred(again[0])
        #expect(open.runs.count == 1)
    }
}
