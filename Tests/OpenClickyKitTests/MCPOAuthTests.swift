import Foundation
import Testing
@testable import OpenClickyKit

// PKCE, the browser sign-in against a fake authorization server on loopback, and token refresh.

@Test func pkceMatchesTheRFC7636Example() {
    // RFC 7636 Appendix B.
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(pkce.method == "S256")
    #expect(PKCE.isValidVerifier(pkce.verifier))
}

@Test func generatedVerifiersAreValidUniqueAndNeverPrinted() {
    let a = PKCE.generate(), b = PKCE.generate()
    #expect(a.verifier.count == 43)
    #expect(PKCE.isValidVerifier(a.verifier))
    #expect(a.verifier != b.verifier)
    #expect(a.challenge == PKCE.challenge(for: a.verifier))
    #expect(!a.challenge.contains("=") && !a.challenge.contains("+") && !a.challenge.contains("/"))
    #expect(!String(describing: a).contains(a.verifier))
    #expect(!PKCE.isValidVerifier("short"))
    #expect(!PKCE.isValidVerifier(String(repeating: "a", count: 42) + "!"))
}

/// An MCP server that wants OAuth, plus its authorization server, on one loopback port.
final class FakeAuthServer: @unchecked Sendable {
    private let lock = NSLock()
    private var server: LocalHTTPListener!
    private var codes: [String: (challenge: String, redirect: String, resource: String)] = [:]
    private(set) var tokenRequests: [[String: String]] = []
    private(set) var registrations: [JSONValue] = []
    private var issued = 0
    /// Access tokens the MCP endpoint accepts.
    private var validAccess: Set<String> = []
    var refreshDelay: TimeInterval = 0
    var refreshError: String?
    var rotateRefreshTokens = true
    var expiresIn = 3600

    init() throws {
        server = try LocalHTTPListener { [weak self] request in self?.handle(request) ?? .empty(503) }
    }

    deinit { server.stop() }

    var base: String { server.baseURL.absoluteString }
    var mcpURL: URL { URL(string: base + "/mcp")! }
    var tokenEndpoint: URL { URL(string: base + "/token")! }
    var tokenRequestCount: Int { lock.withLock { tokenRequests.count } }
    func lastTokenRequest() -> [String: String]? { lock.withLock { tokenRequests.last } }
    func accept(_ token: String) { _ = lock.withLock { validAccess.insert(token) } }

    private func handle(_ request: LocalHTTPListener.Request) -> LocalHTTPListener.Response {
        switch (request.method, request.path) {
        case ("POST", "/mcp"):
            let auth = request.header("authorization") ?? ""
            let ok = lock.withLock { auth.hasPrefix("Bearer ") && validAccess.contains(String(auth.dropFirst(7))) }
            guard ok else {
                return .json(["jsonrpc": "2.0", "id": .null, "error": ["code": -32001, "message": "unauthorized"]], status: 401, headers: [
                    "WWW-Authenticate": #"Bearer resource_metadata="\#(base)/.well-known/oauth-protected-resource/mcp", scope="files:read""#,
                ])
            }
            let body = request.json
            let id = body?["id"] ?? .null
            switch body?["method"]?.stringValue {
            case "server/discover":
                return .json(["jsonrpc": "2.0", "id": id, "result": ["supportedVersions": ["2026-07-28"], "capabilities": ["tools": [:]]]])
            case "tools/list":
                return .json(["jsonrpc": "2.0", "id": id, "result": ["tools": [["name": "list_files", "inputSchema": ["type": "object"]]]]])
            default:
                return .json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "nope"]], status: 404)
            }
        case ("GET", "/.well-known/oauth-protected-resource/mcp"):
            return .json(["resource": .string(base + "/mcp"), "authorization_servers": [.string(base)], "scopes_supported": ["files:read", "files:write"]])
        case ("GET", "/.well-known/oauth-authorization-server"):
            return .json([
                "issuer": .string(base),
                "authorization_endpoint": .string(base + "/authorize"),
                "token_endpoint": .string(base + "/token"),
                "registration_endpoint": .string(base + "/register"),
                "code_challenge_methods_supported": ["S256"],
                "scopes_supported": ["files:read", "files:write", "offline_access"],
                "response_types_supported": ["code"],
                "authorization_response_iss_parameter_supported": true,
            ])
        case ("POST", "/register"):
            let body = request.json ?? [:]
            lock.withLock { registrations.append(body) }
            return .json(["client_id": "client-abc", "redirect_uris": body["redirect_uris"] ?? [], "token_endpoint_auth_method": "none"], status: 201)
        case ("POST", "/token"):
            let form = request.formFields
            lock.withLock { tokenRequests.append(form) }
            return token(form)
        default:
            return .text("Not found", status: 404)
        }
    }

    /// What the authorization endpoint does after the user approves: remember the code's PKCE challenge.
    func approve(_ authorizationURL: URL) throws -> URL {
        let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("response_type") == "code", value("code_challenge_method") == "S256",
              let challenge = value("code_challenge"), let redirect = value("redirect_uri"), let state = value("state"),
              let resource = value("resource") else { throw URLError(.badURL) }
        let code = "code-\(UUID().uuidString.prefix(8))"
        lock.withLock { codes[code] = (challenge, redirect, resource) }
        var callback = URLComponents(string: redirect)!
        callback.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state),
                               URLQueryItem(name: "iss", value: base)]
        return callback.url!
    }

    private func token(_ form: [String: String]) -> LocalHTTPListener.Response {
        switch form["grant_type"] {
        case "authorization_code":
            let entry = lock.withLock { codes.removeValue(forKey: form["code"] ?? "") }
            guard let entry, let verifier = form["code_verifier"], PKCE.challenge(for: verifier) == entry.challenge,
                  form["redirect_uri"] == entry.redirect, form["resource"] == entry.resource, form["client_id"] == "client-abc" else {
                return .json(["error": "invalid_grant", "error_description": "bad code or verifier"], status: 400)
            }
            return issue(refresh: "refresh-1")
        case "refresh_token":
            if refreshDelay > 0 { Thread.sleep(forTimeInterval: refreshDelay) }
            if let refreshError { return .json(["error": .string(refreshError)], status: 400) }
            guard form["refresh_token"]?.hasPrefix("refresh-") == true, form["client_id"] == "client-abc" else {
                return .json(["error": "invalid_grant"], status: 400)
            }
            return issue(refresh: rotateRefreshTokens ? "refresh-rotated" : nil)
        default:
            return .json(["error": "unsupported_grant_type"], status: 400)
        }
    }

    private func issue(refresh: String?) -> LocalHTTPListener.Response {
        let access: String = lock.withLock {
            issued += 1
            let token = "access-\(issued)"
            validAccess.insert(token)
            return token
        }
        var body: [String: JSONValue] = ["access_token": .string(access), "token_type": "Bearer", "expires_in": .number(Double(expiresIn)),
                                         "scope": "files:read offline_access"]
        if let refresh { body["refresh_token"] = .string(refresh) }
        return .json(.object(body))
    }
}

@Suite(.serialized) struct MCPOAuthFlowTests {
    @Test func browserSignInDiscoversRegistersAndExchangesTheCode() async throws {
        let auth = try FakeAuthServer()
        let credentials = InMemoryCredentialStore()
        let store = MCPOAuthStore(credentials: credentials, connectorID: "files")
        let opened = URLBox()
        let flow = MCPOAuthFlow(store: store, openURL: { url in
            opened.set(url)
            // Play the browser: the user approves and the authorization server redirects to the loopback listener.
            let redirect = try auth.approve(url)
            _ = try await URLSession.shared.data(from: redirect)
        }, callbackTimeout: .seconds(10))

        let tokens = try await flow.signIn(serverURL: auth.mcpURL)
        #expect(tokens.accessToken == "access-1")
        #expect(tokens.refreshToken == "refresh-1")
        #expect(tokens.issuer == auth.base)
        #expect(tokens.resource == auth.base + "/mcp")
        #expect(tokens.requestedScopes == ["files:read", "offline_access"])
        #expect(try store.tokens() == tokens)
        #expect(try store.registration()?.clientID == "client-abc")

        // The authorization request.
        let url = try #require(opened.value)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.path == "/authorize")
        #expect(items["client_id"] == "client-abc")
        #expect(items["scope"] == "files:read offline_access")
        #expect(items["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        #expect(items["redirect_uri"]?.hasSuffix("/callback") == true)
        #expect(items["code_challenge"]?.count == 43)

        // Dynamic registration as a native public client.
        let registration = try #require(auth.registrations.first)
        #expect(registration["token_endpoint_auth_method"]?.stringValue == "none")
        #expect(registration["application_type"]?.stringValue == "native")
        #expect(registration["redirect_uris"]?.arrayValue?.first?.stringValue == items["redirect_uri"])

        // The tokens work against the MCP server through OAuthSession.
        let client = MCPClient(transport: MCPStreamableHTTPTransport(endpoint: auth.mcpURL, authorizer: OAuthSession(store: store)))
        #expect(try await client.listTools().map(\.name) == ["list_files"])
    }

    @Test func callbackWithTheWrongStateOrIssuerIsRejected() throws {
        let metadata = try #require(AuthorizationServerMetadata(json: [
            "issuer": "https://auth.example", "authorization_endpoint": "https://auth.example/a", "token_endpoint": "https://auth.example/t",
            "authorization_response_iss_parameter_supported": true,
        ]))
        #expect(throws: MCPOAuthError.stateMismatch) {
            _ = try MCPOAuthFlow.validate(OAuthCallback(code: "c", state: "evil", issuer: "https://auth.example"), expectedState: "good", metadata: metadata)
        }
        #expect(throws: MCPOAuthError.issuerMismatch) {
            _ = try MCPOAuthFlow.validate(OAuthCallback(code: "c", state: "good", issuer: "https://other.example"), expectedState: "good", metadata: metadata)
        }
        #expect(throws: MCPOAuthError.issuerMismatch) {
            _ = try MCPOAuthFlow.validate(OAuthCallback(code: "c", state: "good"), expectedState: "good", metadata: metadata)
        }
        #expect(throws: MCPOAuthError.authorizationDenied("access_denied: no")) {
            _ = try MCPOAuthFlow.validate(OAuthCallback(state: "good", issuer: "https://auth.example", error: "access_denied", errorDescription: "no"),
                                          expectedState: "good", metadata: metadata)
        }
        #expect(try MCPOAuthFlow.validate(OAuthCallback(code: "c", state: "good", issuer: "https://auth.example"), expectedState: "good", metadata: metadata) == "c")
    }

    @Test func redirectListenerAnswersOnlyItsCallbackPath() async throws {
        let listener = try OAuthRedirectListener()
        defer { listener.stop() }
        #expect(listener.redirectURI.host == "127.0.0.1")
        let base = "http://127.0.0.1:\(listener.port)"
        let (_, other) = try await URLSession.shared.data(from: URL(string: base + "/favicon.ico")!)
        #expect((other as? HTTPURLResponse)?.statusCode == 404)
        async let callback = listener.waitForCallback(timeout: .seconds(5))
        let (page, response) = try await URLSession.shared.data(from: URL(string: base + "/callback?code=xyz&state=s1&iss=https%3A%2F%2Fa.example")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("Sign-in finished"))
        let received = try await callback
        // A refusal gets its own page, not the "finished" one.
        let (refused, _) = try await URLSession.shared.data(from: URL(string: base + "/callback?error=access_denied&state=s2")!)
        #expect(String(decoding: refused, as: UTF8.self).contains("refused or cancelled"))
        #expect(received.code == "xyz")
        #expect(received.state == "s1")
        #expect(received.issuer == "https://a.example")
    }

    @Test func waitingForTheCallbackInAnAlreadyCancelledTaskStopsAtOnce() async throws {
        // Cancel lands before the listener starts waiting (for example while the browser is being opened).
        let listener = try OAuthRedirectListener()
        defer { listener.stop() }
        let started = ContinuousClock.now
        let wait = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await listener.waitForCallback(timeout: .seconds(20))
        }
        await #expect(throws: CancellationError.self) { _ = try await wait.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func discoveryURLsFollowTheSpecOrder() {
        let prm = MCPOAuthDiscovery.protectedResourceMetadataURLs(for: URL(string: "https://mcp.example.com/v1/mcp/")!)
        #expect(prm.map(\.absoluteString) == ["https://mcp.example.com/.well-known/oauth-protected-resource/v1/mcp",
                                              "https://mcp.example.com/.well-known/oauth-protected-resource"])
        let withPath = MCPOAuthDiscovery.authorizationServerMetadataURLs(for: URL(string: "https://auth.example.com/tenant1")!)
        #expect(withPath.map(\.absoluteString) == ["https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
                                                   "https://auth.example.com/.well-known/openid-configuration/tenant1",
                                                   "https://auth.example.com/tenant1/.well-known/openid-configuration"])
        #expect(MCPOAuthDiscovery.canonicalResource(URL(string: "HTTPS://MCP.Example.com/mcp/")!) == "https://mcp.example.com/mcp")
    }
}

@Suite(.serialized) struct OAuthRefreshTests {
    func seed(_ auth: FakeAuthServer, expiresIn seconds: TimeInterval, refresh: String? = "refresh-1") throws -> MCPOAuthStore {
        let store = MCPOAuthStore(credentials: InMemoryCredentialStore(), connectorID: "files")
        try store.save(OAuthClientRegistration(issuer: auth.base, clientID: "client-abc"))
        try store.save(OAuthTokenSet(accessToken: "access-old", refreshToken: refresh, expiresAt: Date().addingTimeInterval(seconds),
                                     issuer: auth.base, tokenEndpoint: auth.tokenEndpoint, clientID: "client-abc",
                                     resource: auth.base + "/mcp", requestedScopes: ["files:read"]))
        return store
    }

    @Test func validTokenIsUsedWithoutTouchingTheNetwork() async throws {
        let auth = try FakeAuthServer()
        let session = OAuthSession(store: try seed(auth, expiresIn: 3600))
        #expect(try await session.accessToken() == "access-old")
        #expect(auth.tokenRequestCount == 0)
    }

    @Test func tokenNearExpiryIsRefreshedAndStored() async throws {
        let auth = try FakeAuthServer()
        let store = try seed(auth, expiresIn: 30)
        let session = OAuthSession(store: store, refreshMargin: 60)
        #expect(try await session.accessToken() == "access-1")
        let form = try #require(auth.lastTokenRequest())
        #expect(form["grant_type"] == "refresh_token")
        #expect(form["refresh_token"] == "refresh-1")
        #expect(form["resource"] == auth.base + "/mcp")
        #expect(form["client_id"] == "client-abc")
        let saved = try #require(try store.tokens())
        #expect(saved.accessToken == "access-1")
        #expect(saved.refreshToken == "refresh-rotated")
        #expect(saved.requestedScopes == ["files:read"])
        #expect((saved.expiresAt?.timeIntervalSinceNow ?? 0) > 3000)
        // Fresh now: no second refresh.
        #expect(try await session.accessToken() == "access-1")
        #expect(auth.tokenRequestCount == 1)
    }

    @Test func refreshKeepsTheOldRefreshTokenWhenNotRotated() async throws {
        let auth = try FakeAuthServer()
        auth.rotateRefreshTokens = false
        let store = try seed(auth, expiresIn: -10)
        _ = try await OAuthSession(store: store).accessToken()
        #expect(try store.tokens()?.refreshToken == "refresh-1")
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let auth = try FakeAuthServer()
        auth.refreshDelay = 0.3
        let session = OAuthSession(store: try seed(auth, expiresIn: -10))
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<6 { group.addTask { try await session.accessToken() } }
            var all: [String] = []
            for try await token in group { all.append(token) }
            return all
        }
        #expect(Set(tokens) == ["access-1"])
        #expect(auth.tokenRequestCount == 1)
    }

    @Test func revokedGrantClearsTokensAndAsksForSignIn() async throws {
        let auth = try FakeAuthServer()
        auth.refreshError = "invalid_grant"
        let store = try seed(auth, expiresIn: -10)
        await #expect(throws: MCPOAuthError.needsSignIn) { _ = try await OAuthSession(store: store).accessToken() }
        #expect(try store.tokens() == nil)
        #expect(try store.registration() != nil) // kept for the next sign-in
    }

    @Test func otherRefreshFailuresKeepTheTokens() async throws {
        let auth = try FakeAuthServer()
        auth.refreshError = "temporarily_unavailable"
        let store = try seed(auth, expiresIn: -10)
        await #expect(throws: MCPOAuthError.refreshFailed("temporarily_unavailable")) { _ = try await OAuthSession(store: store).accessToken() }
        #expect(try store.tokens() != nil)
    }

    @Test func expiredTokenWithoutRefreshTokenNeedsSignIn() async throws {
        let auth = try FakeAuthServer()
        let store = try seed(auth, expiresIn: -10, refresh: nil)
        await #expect(throws: MCPOAuthError.needsSignIn) { _ = try await OAuthSession(store: store).accessToken() }
    }

    @Test func a401FromTheServerTriggersOneRefreshAndARetry() async throws {
        let auth = try FakeAuthServer()
        // The stored token looks valid but the server has revoked it.
        let store = try seed(auth, expiresIn: 3600)
        let client = MCPClient(transport: MCPStreamableHTTPTransport(endpoint: auth.mcpURL, authorizer: OAuthSession(store: store)))
        #expect(try await client.listTools().map(\.name) == ["list_files"])
        #expect(auth.tokenRequestCount == 1)
        #expect(try store.tokens()?.accessToken == "access-1")
    }

    @Test func tokenDescriptionsNeverShowSecrets() {
        let tokens = OAuthTokenSet(accessToken: "sekrit-access", refreshToken: "sekrit-refresh", issuer: "https://a", tokenEndpoint: URL(string: "https://a/t")!,
                                   clientID: "c", resource: "https://r")
        #expect(!tokens.description.contains("sekrit"))
        let registration = OAuthClientRegistration(issuer: "https://a", clientID: "c", clientSecret: "sekrit-client")
        #expect(!registration.description.contains("sekrit"))
    }
}

final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    func set(_ url: URL) { lock.withLock { stored = url } }
    var value: URL? { lock.withLock { stored } }
}
