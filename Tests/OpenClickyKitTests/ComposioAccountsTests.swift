import Foundation
import Testing
@testable import OpenClickyKit

// Composio's connected accounts, the connect flow, session reuse and the skills that follow real connections, all
// against a scripted Composio. No network.

private let key = "ck_test_not_a_real_key"

private func account(_ id: String, _ toolkit: String, _ status: String, alias: String? = nil) -> String {
    #"{"id":"\#(id)","toolkit":{"slug":"\#(toolkit)"},"status":"\#(status)","alias":\#(alias.map { "\"\($0)\"" } ?? "null"),"user_id":"jeff@example.com","auth_config":{"id":"ac_1"}}"#
}

private func page(_ items: [String], next: String? = nil) -> FakeHTTPTransport.Scripted {
    .body(#"{"items":[\#(items.joined(separator: ","))],"next_cursor":\#(next.map { "\"\($0)\"" } ?? "null"),"total_items":\#(items.count)}"#)
}

private func session(_ id: String) -> FakeHTTPTransport.Scripted {
    .body(#"{"session_id":"\#(id)","mcp":{"type":"http","url":"https://backend.composio.dev/tool_router/\#(id)/mcp"},"tool_router_tools":[]}"#, status: 201)
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@Suite("Composio accounts")
struct ComposioAccountsTests {
    @Test func listingFollowsPagesAndReportsActiveToolkits() async throws {
        let fake = FakeHTTPTransport([
            page([account("ca_1", "gmail", "ACTIVE", alias: "work"), account("ca_2", "slack", "INITIATED")], next: "c2"),
            page([account("ca_3", "GoogleCalendar", "ACTIVE"), account("ca_4", "gmail", "ACTIVE")]),
            page([account("ca_1", "gmail", "ACTIVE"), account("ca_3", "googlecalendar", "ACTIVE")]),
        ])
        let client = ComposioClient(apiKey: key, http: fake)
        let accounts = try await client.connectedAccounts(userID: "jeff@example.com")
        #expect(accounts.map(\.id) == ["ca_1", "ca_2", "ca_3", "ca_4"])
        #expect(accounts[0].alias == "work" && accounts[0].isActive && accounts[1].isPending && !accounts[1].isActive)
        let first = try #require(fake.requests.first)
        #expect(first.httpMethod == "GET")
        #expect(first.url?.absoluteString == "https://backend.composio.dev/api/v3.1/connected_accounts?user_ids=jeff@example.com")
        #expect(first.value(forHTTPHeaderField: "x-api-key") == key)
        #expect(fake.requests[1].url?.query?.contains("cursor=c2") == true)

        #expect(try await client.activeToolkits(userID: "jeff@example.com") == ["gmail", "googlecalendar"])
        #expect(fake.requests[2].url?.query?.contains("statuses=ACTIVE") == true)
    }

    @Test func connectingOpensComposiosPageAndPollsUntilTheAccountIsActive() async throws {
        let fake = FakeHTTPTransport([
            // No Composio-managed auth config for Gmail yet: one is made.
            .body(#"{"items":[],"next_cursor":null,"total_items":0}"#),
            .body(#"{"toolkit":{"slug":"gmail"},"auth_config":{"id":"ac_gmail","auth_scheme":"OAUTH2","is_composio_managed":true}}"#, status: 201),
            .body(#"{"link_token":"lt_1","redirect_url":"https://connect.composio.dev/link/lt_1","expires_at":"2027-01-15T10:00:00Z","connected_account_id":"ca_9"}"#, status: 201),
            .body(account("ca_9", "gmail", "INITIATED")),
            .body(#"{"error":{"message":"busy"}}"#, status: 503),
            .body(account("ca_9", "gmail", "ACTIVE")),
        ])
        let client = ComposioClient(apiKey: key, http: fake)
        let link = try await client.startConnection(userID: "jeff@example.com", toolkit: "gmail")
        #expect(link.redirectURL.absoluteString == "https://connect.composio.dev/link/lt_1")
        #expect(link.connectedAccountID == "ca_9")
        #expect(fake.requests[0].url?.absoluteString.hasPrefix("https://backend.composio.dev/api/v3.1/auth_configs?toolkit_slug=gmail") == true)
        #expect(try fake.jsonBody(1)["auth_config"]?["type"] == "use_composio_managed_auth")
        #expect(try fake.jsonBody(2) == ["auth_config_id": "ac_gmail", "user_id": "jeff@example.com"])
        #expect(fake.requests[2].url?.path == "/api/v3.1/connected_accounts/link")

        let clock = ManualClock()
        let sleeps = Counter()
        let active = try await client.waitForConnection(accountID: "ca_9", timeout: 60, interval: 2, now: { clock.now },
                                                        sleep: { seconds in sleeps.add(); clock.advance(seconds) })
        #expect(active.isActive)
        #expect(sleeps.value == 2, "polled three times; a server hiccup in between didn't end it")
        #expect(fake.requests[3...].allSatisfy { $0.url?.path == "/api/v3.1/connected_accounts/ca_9" && $0.httpMethod == "GET" })
    }

    @Test func aConnectionThatNeverFinishesTimesOutAndAFailedOneComesBack() async throws {
        let pending = FakeHTTPTransport(Array(repeating: .body(account("ca_5", "slack", "INITIATED")), count: 10))
        let clock = ManualClock()
        let client = ComposioClient(apiKey: key, http: pending)
        await #expect(throws: ComposioError.connectionTimedOut) {
            _ = try await client.waitForConnection(accountID: "ca_5", timeout: 10, interval: 3, now: { clock.now }, sleep: { clock.advance($0) })
        }
        #expect(pending.requests.count == 5)

        let failed = FakeHTTPTransport([.body(account("ca_6", "slack", "FAILED"))])
        let result = try await ComposioClient(apiKey: key, http: failed).waitForConnection(accountID: "ca_6", sleep: { _ in })
        #expect(result.hasFailed && !result.isActive)
    }

    @Test func disconnectingDeletesTheAccountAndErrorsNeverCarryTheKey() async throws {
        let fake = FakeHTTPTransport([
            .body(#"{"success":true}"#),
            .body(#"{"error":{"message":"no account ca_x for key \#(key)"}}"#, status: 404),
        ])
        let client = ComposioClient(apiKey: key, http: fake)
        try await client.disconnect(accountID: "ca_1")
        #expect(fake.requests[0].httpMethod == "DELETE")
        #expect(fake.requests[0].url?.path == "/api/v3.1/connected_accounts/ca_1")
        do {
            try await client.disconnect(accountID: "ca_x")
            Issue.record("expected an error")
        } catch let error as ComposioError {
            #expect(!error.description.contains(key) && error.description.contains("404"))
        }
        await #expect(throws: ComposioError.missingKey) { try await ComposioClient(apiKey: "", http: fake).disconnect(accountID: "a") }
    }

    @Test func sessionsAreReusedUntilTheyExpireAndFailuresBackOff() async throws {
        let clock = ManualClock()
        let cache = ComposioSessionCache(lifetime: 600, initialBackoff: 5, maxBackoff: 20, now: { clock.now })
        let fake = FakeHTTPTransport([
            session("trs_1"),
            .body(#"{"error":{"message":"overloaded"}}"#, status: 503),
            .body(#"{"error":{"message":"overloaded"}}"#, status: 503),
            session("trs_2"),
            session("trs_3"),
        ])
        let client = ComposioClient(apiKey: key, http: fake)
        let first = try await cache.session(for: client, userID: "u", toolkits: ["slack", "gmail"])
        // The same user and toolkits (in any order) reuse it: one request, not one per launch.
        let again = try await cache.session(for: client, userID: "u", toolkits: ["gmail", "slack"])
        #expect(first.sessionID == "trs_1" && again.sessionID == "trs_1")
        #expect(fake.requests.count == 1)

        // Expired: asked again. Composio is down: the error comes back, and during the backoff nothing is sent.
        clock.advance(601)
        await #expect(throws: ComposioError.self) { _ = try await cache.session(for: client, userID: "u", toolkits: ["gmail", "slack"]) }
        #expect(fake.requests.count == 2)
        await #expect(throws: ComposioError.self) { _ = try await cache.session(for: client, userID: "u", toolkits: ["gmail", "slack"]) }
        #expect(fake.requests.count == 2, "backing off for 5 s")
        clock.advance(5)
        await #expect(throws: ComposioError.self) { _ = try await cache.session(for: client, userID: "u", toolkits: ["gmail", "slack"]) }
        #expect(fake.requests.count == 3)
        clock.advance(5)
        await #expect(throws: ComposioError.self) { _ = try await cache.session(for: client, userID: "u", toolkits: ["gmail", "slack"]) }
        #expect(fake.requests.count == 3, "the second failure waits 10 s")
        clock.advance(5)
        #expect(try await cache.session(for: client, userID: "u", toolkits: ["gmail", "slack"]).sessionID == "trs_2")
        #expect(await cache.creations == 2)

        // A sign-in or a settings change forgets it.
        await cache.invalidate(userID: "u")
        #expect(try await cache.session(for: client, userID: "u", toolkits: ["gmail", "slack"]).sessionID == "trs_3")
    }

    @Test func connectionsAndAgentExportsShareTheirEnvironmentsSession() async throws {
        let fake = FakeHTTPTransport([session("trs_7")])
        let environment = ConnectorEnvironment(credentials: InMemoryCredentialStore([ComposioClient.credentialName: key]), http: fake)
        let registry = ConnectorRegistry(composio: ComposioSettings(userID: "u1", toolkits: ["gmail"]))
        let exporter = ConnectedAppsAgentExporter(registry: registry, environment: environment)
        let first = await exporter.export()
        let second = await exporter.export()
        #expect(first.servers.map(\.key) == ["composio"] && second.servers.map(\.key) == ["composio"])
        #expect(fake.requests.count == 1, "two job launches, one Composio session")
    }

    @Test func aResetInSettingsDropsTheSessionJobLaunchesReuse() async throws {
        // Settings' hub and the job export are built with separate environments that share one session cache, as the
        // app builds them; a reset from Settings (a sign-in, connect or disconnect) makes the next launch ask again.
        let cache = ComposioSessionCache()
        let fake = FakeHTTPTransport([session("trs_1"), session("trs_2")])
        let credentials = InMemoryCredentialStore([ComposioClient.credentialName: key])
        let registry = ConnectorRegistry(composio: ComposioSettings(userID: "u1", toolkits: ["gmail"]))
        let exporter = ConnectedAppsAgentExporter(registry: registry,
                                                  environment: ConnectorEnvironment(credentials: credentials, http: fake, composioSessions: cache))
        let settingsHub = ConnectedAppsHub(registry: registry, environment: ConnectorEnvironment(credentials: credentials, composioSessions: cache))
        _ = await exporter.export()
        _ = await exporter.export()
        #expect(await cache.creations == 1)
        await settingsHub.reset(ComposioClient.connectorID)
        _ = await exporter.export()
        #expect(await cache.creations == 2, "the job launch after the reset gets a new session")

        // The brain's hub uses the app's shared cache too.
        let brain = ConnectedAppsWiring.make(registry: registry, credentials: credentials)
        let brainSessions = await brain.reader.hub.environment.composioSessions
        #expect(brainSessions === ComposioSessionCache.shared)
    }

    @Test func theToolkitDirectoryAsksComposioOnceAndFallsBackWhenItCant() async throws {
        let clock = ManualClock()
        let directory = ComposioToolkitDirectory(lifetime: 300, now: { clock.now })
        let credentials = InMemoryCredentialStore([ComposioClient.credentialName: key])
        let settings = ComposioSettings(userID: "jeff@example.com", toolkits: ["gmail", "slack"])
        let fake = FakeHTTPTransport([page([account("ca_1", "googledocs", "ACTIVE")])])
        #expect(await directory.activeToolkits(settings: settings, credentials: credentials, http: fake) == ["googledocs"])
        #expect(await directory.activeToolkits(settings: settings, credentials: credentials, http: fake) == ["googledocs"])
        #expect(fake.requests.count == 1)
        // No key, Composio off, or Composio unreachable: no answer (the listed toolkits apply).
        #expect(await directory.activeToolkits(settings: settings, credentials: InMemoryCredentialStore(), http: fake) == nil)
        var off = settings
        off.enabled = false
        #expect(await directory.activeToolkits(settings: off, credentials: credentials, http: fake) == nil)
        clock.advance(301)
        #expect(await directory.activeToolkits(settings: settings, credentials: credentials, http: FakeHTTPTransport([])) == nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

// MARK: - Skills follow real connections

@Test func integrationSkillsFollowOnlyReadyConnections() async throws {
    var registry = ConnectorRegistry()
    registry.connectors = [
        // Needs sign-in: no OAuth tokens stored.
        ConnectorPreset.named("linear")!.connector,
        // Missing its token.
        ConnectorConfig(id: "work-github", name: "Work GitHub", transport: .remote(URL(string: "https://api.githubcopilot.com/mcp/")!), auth: .bearer),
        // Ready: its secret header is stored.
        ConnectorConfig(id: "tracker", name: "Tracker", transport: .remote(URL(string: "https://mcp.atlassian.com/v1/sse")!),
                        secretHeaders: ["X-Key": "connector-tracker-header-x-key"]),
        // Missing a secret header value.
        ConnectorConfig(id: "notion", name: "Notion", transport: .remote(URL(string: "https://mcp.notion.com/mcp")!),
                        secretHeaders: ["X-Key": "connector-notion-header-x-key"]),
    ]
    registry.composio = ComposioSettings(userID: "me", toolkits: ["gmail"])
    let credentials = InMemoryCredentialStore(["connector-tracker-header-x-key": "v"])
    // Without credentials (the old behaviour) every enabled connector counts.
    #expect(IntegrationSkills.matching(registry: registry).map(\.name) == ["gmail", "jira", "linear", "notion", "github"])
    // With them, only what is ready: Composio without its key is out too.
    #expect(IntegrationSkills.matching(registry: registry, credentials: credentials).map(\.name) == ["jira"])
    try credentials.setSecret("ck", named: ComposioClient.credentialName)
    try credentials.setSecret("ghp", named: ConnectorSecretNames.bearer("work-github"))
    #expect(IntegrationSkills.matching(registry: registry, credentials: credentials).map(\.name) == ["gmail", "jira", "github"])
    // Composio's answer about active accounts wins over the listed toolkits.
    #expect(IntegrationSkills.matching(registry: registry, composioToolkits: ["slack", "googledocs"], credentials: credentials).map(\.name)
            == ["google-docs", "jira", "github"])

    // The async source for launches asks Composio (through the directory) and passes its answer on.
    let fake = FakeHTTPTransport([page([account("ca_1", "outlook", "ACTIVE")])])
    let sources = await AgentSkillSources.connected(library: nil, registry: registry, credentials: credentials,
                                                    directory: ComposioToolkitDirectory(), http: fake)
    let integrations = sources.filter { $0.origin == .integration }.map(\.name)
    #expect(integrations == ["outlook", "jira", "github"])
    #expect(fake.requests.first?.url?.query?.contains("user_ids=me") == true)
}
