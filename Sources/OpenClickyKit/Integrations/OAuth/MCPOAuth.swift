// OAuth 2.1 authorization-code + PKCE sign-in for remote MCP servers, token storage in the Keychain, and
// token refresh.
//
// Follows https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization (checked 2026-10-30):
// - Client registration priority: a pre-registered client id if the user entered one; Client ID Metadata
//   Documents need an HTTPS-hosted document OpenClicky doesn't have, so they are skipped; then Dynamic Client
//   Registration (RFC 7591, deprecated but widely deployed) with `application_type: "native"`; otherwise the
//   user is asked for a client id or an API key.
// - Registrations are kept per authorization server (`issuer`) and never reused with a different one.
// - The authorization request carries `code_challenge` (S256), `state`, `resource` (RFC 8707) and the scopes
//   from the 401 challenge, or else the resource's `scopes_supported`; `offline_access` is added when the
//   authorization server lists it, so a refresh token can be issued.
// - The response's `iss` is checked against the recorded issuer as RFC 9207 §2.4 and the spec's table say,
//   before the code goes anywhere; on mismatch the error fields are not shown either.
// - The token request repeats `resource` and sends `code_verifier`. Refresh uses `grant_type=refresh_token`
//   and keeps the old refresh token unless the server rotates it.
// - The redirect is a loopback listener on 127.0.0.1 (RFC 8252 §7.3).

import Foundation

// MARK: - Stored state

/// Tokens for one connector. Lives in the Keychain as JSON; descriptions never show the secrets.
public struct OAuthTokenSet: Codable, Sendable, Hashable {
    public var accessToken: String
    public var tokenType: String
    public var refreshToken: String?
    public var expiresAt: Date?
    /// Scopes the server granted (space separated), if it said.
    public var scope: String?
    /// Where the tokens came from; refresh goes back there.
    public var issuer: String
    public var tokenEndpoint: URL
    public var clientID: String
    public var resource: String
    /// Scopes OpenClicky asked for, kept so a step-up request can add to them instead of replacing them.
    public var requestedScopes: [String]

    public init(accessToken: String, tokenType: String = "Bearer", refreshToken: String? = nil, expiresAt: Date? = nil,
                scope: String? = nil, issuer: String, tokenEndpoint: URL, clientID: String, resource: String,
                requestedScopes: [String] = []) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.issuer = issuer
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.resource = resource
        self.requestedScopes = requestedScopes
    }

    /// True when the access token expires within `margin` seconds of `now`. Tokens without an expiry are
    /// treated as valid until the server rejects them.
    public func isExpired(at now: Date, margin: TimeInterval) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= margin
    }
}

extension OAuthTokenSet: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "OAuthTokenSet(issuer: \(issuer), client: \(clientID), access: <redacted>, refresh: \(refreshToken == nil ? "none" : "<redacted>"), expires: \(expiresAt.map { "\($0)" } ?? "unknown"))"
    }
    public var debugDescription: String { description }
}

/// The OAuth client OpenClicky registered (or was given) at one authorization server.
public struct OAuthClientRegistration: Codable, Sendable, Hashable {
    public var issuer: String
    public var clientID: String
    public var clientSecret: String?
    /// `none`, `client_secret_post` or `client_secret_basic`.
    public var tokenEndpointAuthMethod: String
    /// The exact redirect URI registered (dynamic registration binds it, port included).
    public var redirectURI: String?
    /// True when the user typed the client id rather than OpenClicky registering one.
    public var preregistered: Bool

    public init(issuer: String, clientID: String, clientSecret: String? = nil, tokenEndpointAuthMethod: String = "none",
                redirectURI: String? = nil, preregistered: Bool = false) {
        self.issuer = issuer
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
        self.redirectURI = redirectURI
        self.preregistered = preregistered
    }
}

extension OAuthClientRegistration: CustomStringConvertible {
    public var description: String {
        "OAuthClientRegistration(issuer: \(issuer), client: \(clientID), secret: \(clientSecret == nil ? "none" : "<redacted>"))"
    }
}

/// Keychain items for one connector's OAuth state.
public struct MCPOAuthStore: Sendable {
    public let credentials: any CredentialStore
    public let connectorID: String

    public init(credentials: any CredentialStore, connectorID: String) {
        self.credentials = credentials
        self.connectorID = connectorID
    }

    public var tokenCredentialName: String { ConnectorSecretNames.oauthTokens(connectorID) }
    public var registrationCredentialName: String { ConnectorSecretNames.oauthClient(connectorID) }

    public func tokens() throws -> OAuthTokenSet? {
        guard let text = try credentials.secret(named: tokenCredentialName) else { return nil }
        return try? Self.decoder.decode(OAuthTokenSet.self, from: Data(text.utf8))
    }

    public func save(_ tokens: OAuthTokenSet) throws {
        try credentials.setSecret(String(decoding: try Self.encoder.encode(tokens), as: UTF8.self), named: tokenCredentialName)
    }

    public func registration() throws -> OAuthClientRegistration? {
        guard let text = try credentials.secret(named: registrationCredentialName) else { return nil }
        return try? Self.decoder.decode(OAuthClientRegistration.self, from: Data(text.utf8))
    }

    public func save(_ registration: OAuthClientRegistration) throws {
        try credentials.setSecret(String(decoding: try Self.encoder.encode(registration), as: UTF8.self), named: registrationCredentialName)
    }

    /// Signs out: forgets tokens. The client registration is kept so the next sign-in skips registering.
    public func clearTokens() throws { try credentials.removeSecret(named: tokenCredentialName) }

    public func clearAll() throws {
        try credentials.removeSecret(named: tokenCredentialName)
        try credentials.removeSecret(named: registrationCredentialName)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

// MARK: - Redirect listener

/// What came back to the loopback redirect.
public struct OAuthCallback: Sendable, Hashable {
    public var code: String?
    public var state: String?
    public var issuer: String?
    public var error: String?
    public var errorDescription: String?
}

/// Waits for one browser redirect on `http://127.0.0.1:<port>/callback`. Other paths get 404.
public final class OAuthRedirectListener: @unchecked Sendable {
    public let redirectURI: URL
    private let server: LocalHTTPListener
    private let lock = NSLock()
    private var received: OAuthCallback?
    private var waiter: CheckedContinuation<OAuthCallback, Error>?

    /// Binds `port` (0 = any free port).
    public init(port: UInt16 = 0) throws {
        let box = CallbackBox()
        do {
            server = try LocalHTTPListener(port: port) { request in
                guard request.method == "GET", request.path == "/callback" else { return .text("Not found", status: 404) }
                let query = request.queryItems
                box.deliver(OAuthCallback(code: query["code"], state: query["state"], issuer: query["iss"],
                                          error: query["error"], errorDescription: query["error_description"]))
                let page = query["error"] == nil ? OAuthRedirectListener.donePage : OAuthRedirectListener.refusedPage
                return .text(page, contentType: "text/html; charset=utf-8")
            }
        } catch {
            throw MCPOAuthError.callbackPortUnavailable
        }
        redirectURI = URL(string: "http://127.0.0.1:\(server.port)/callback")!
        box.listener = self
    }

    public var port: UInt16 { server.port }

    /// The first callback, or `MCPOAuthError.timedOut`. Cancelling the task stops waiting.
    public func waitForCallback(timeout: Duration) async throws -> OAuthCallback {
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(.failure(MCPOAuthError.timedOut))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<OAuthCallback, Error>? = lock.withLock {
                    if let received { return .success(received) }
                    // A cancel that arrived before this point found no waiter to resume; honour it here.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    public func stop() { server.stop() }

    fileprivate func finish(_ result: Result<OAuthCallback, Error>) {
        let continuation: CheckedContinuation<OAuthCallback, Error>? = lock.withLock {
            if case .success(let callback) = result, received == nil { received = callback }
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume(with: result)
    }

    /// Small pages written for OpenClicky; they carry no data back from the query.
    static let donePage = page("Sign-in finished. OpenClicky has what it needs, so this tab can go.")
    static let refusedPage = page("The sign-in was refused or cancelled. Head back to OpenClicky if you want another try.")

    private static func page(_ message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>OpenClicky</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;background:#16161a;color:#eee;display:grid;place-items:center;height:100vh;margin:0}</style>
        </head><body><p>\(message)</p></body></html>
        """
    }
}

/// Lets the server's handler (created before `self` exists) reach the listener.
private final class CallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _listener: OAuthRedirectListener?
    var listener: OAuthRedirectListener? {
        get { lock.withLock { _listener } }
        set { lock.withLock { _listener = newValue } }
    }

    func deliver(_ callback: OAuthCallback) { listener?.finish(.success(callback)) }
}

// MARK: - Sign-in flow

public struct MCPOAuthFlow: Sendable {
    public var http: any HTTPTransport
    public var store: MCPOAuthStore
    /// Opens the authorization URL in the user's browser.
    public var openURL: @Sendable (URL) async throws -> Void
    public var clientName: String
    public var callbackTimeout: Duration
    /// A client id the user registered with the server themselves, if any.
    public var preregisteredClientID: String?
    public var preregisteredClientSecret: String?

    public init(http: any HTTPTransport = URLSessionTransport(), store: MCPOAuthStore,
                openURL: @escaping @Sendable (URL) async throws -> Void, clientName: String = "OpenClicky",
                callbackTimeout: Duration = .seconds(300), preregisteredClientID: String? = nil, preregisteredClientSecret: String? = nil) {
        self.http = http
        self.store = store
        self.openURL = openURL
        self.clientName = clientName
        self.callbackTimeout = callbackTimeout
        self.preregisteredClientID = preregisteredClientID
        self.preregisteredClientSecret = preregisteredClientSecret
    }

    /// Runs the whole browser sign-in and stores the tokens. `challenge` is the 401 that prompted it, if known;
    /// without one the server is probed first. `extraScopes` are unioned in (step-up after `insufficient_scope`).
    @discardableResult
    public func signIn(serverURL: URL, challenge: WWWAuthenticateChallenge? = nil, extraScopes: [String] = []) async throws -> OAuthTokenSet {
        var challenge = challenge
        if challenge == nil { challenge = try await probeChallenge(serverURL) }
        let target = try await MCPOAuthDiscovery(http: http).discover(serverURL: serverURL, challenge: challenge)

        let previous = try? store.tokens()
        var scopes = target.scopes
        for scope in (previous?.issuer == target.metadata.issuer ? previous?.requestedScopes ?? [] : []) + extraScopes where !scopes.contains(scope) {
            scopes.append(scope)
        }
        if target.metadata.scopesSupported?.contains("offline_access") == true, !scopes.contains("offline_access") {
            scopes.append("offline_access")
        }

        // Reuse the registered redirect port when there is one; dynamic registrations bind the exact URI.
        let saved = try? store.registration()
        let reusable = saved.flatMap { $0.issuer == target.metadata.issuer || OAuthTokenSet.sameIssuer($0.issuer, target.metadata.issuer) ? $0 : nil }
        let listener = try openListener(preferring: reusable?.redirectURI)
        defer { listener.stop() }
        let registration = try await clientRegistration(for: target.metadata, redirectURI: listener.redirectURI, saved: reusable)

        let pkce = PKCE.generate()
        let state = PKCE.randomURLSafeString(byteCount: 24)
        let authorizationURL = Self.authorizationURL(metadata: target.metadata, clientID: registration.clientID,
                                                     redirectURI: listener.redirectURI, pkce: pkce, state: state,
                                                     resource: target.resource, scopes: scopes)
        try await openURL(authorizationURL)
        let callback = try await listener.waitForCallback(timeout: callbackTimeout)
        let code = try Self.validate(callback, expectedState: state, metadata: target.metadata)

        var form: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", listener.redirectURI.absoluteString),
            ("code_verifier", pkce.verifier),
            ("resource", target.resource),
        ]
        let response = try await OAuthTokenEndpoint(http: http).request(endpoint: target.metadata.tokenEndpoint, form: &form,
                                                                         registration: registration)
        guard let tokens = response.tokenSet(issuer: target.metadata.issuer, tokenEndpoint: target.metadata.tokenEndpoint,
                                             clientID: registration.clientID, resource: target.resource, requestedScopes: scopes,
                                             previousRefreshToken: nil, now: Date()) else {
            throw MCPOAuthError.tokenExchangeFailed(response.errorSummary ?? "the token endpoint returned no access token")
        }
        try store.save(tokens)
        return tokens
    }

    /// An unauthenticated request to learn the server's challenge.
    func probeChallenge(_ serverURL: URL) async throws -> WWWAuthenticateChallenge? {
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let version = MCPProtocolVersion.preferredModern
        request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("server/discover", forHTTPHeaderField: "Mcp-Method")
        let meta = MCPRequestContext.modernMeta(version: version, clientInfo: MCPImplementation(name: clientName, version: "1.0"))
        request.httpBody = MCPOutgoingMessage(id: .number(0), method: "server/discover", params: ["_meta": meta]).encoded
        let (_, response) = try await http.data(for: request)
        if response.statusCode == 401 || response.statusCode == 403 {
            return WWWAuthenticateChallenge.bearer(from: response.value(forHTTPHeaderField: "WWW-Authenticate"))
                ?? WWWAuthenticateChallenge(scheme: "Bearer")
        }
        throw MCPOAuthError.serverDoesNotRequireOAuth
    }

    private func openListener(preferring redirect: String?) throws -> OAuthRedirectListener {
        if let redirect, let port = URLComponents(string: redirect)?.port, let listener = try? OAuthRedirectListener(port: UInt16(port)) {
            return listener
        }
        return try OAuthRedirectListener()
    }

    /// Pre-registered client, else a saved dynamic registration for this redirect URI, else a new one.
    func clientRegistration(for metadata: AuthorizationServerMetadata, redirectURI: URL,
                            saved: OAuthClientRegistration?) async throws -> OAuthClientRegistration {
        if let preregisteredClientID, !preregisteredClientID.isEmpty {
            let registration = OAuthClientRegistration(
                issuer: metadata.issuer, clientID: preregisteredClientID, clientSecret: preregisteredClientSecret,
                tokenEndpointAuthMethod: preregisteredClientSecret == nil ? "none"
                    : (metadata.tokenEndpointAuthMethodsSupported?.contains("client_secret_basic") == true ? "client_secret_basic" : "client_secret_post"),
                redirectURI: redirectURI.absoluteString, preregistered: true)
            try store.save(registration)
            return registration
        }
        if let saved, !saved.preregistered, saved.redirectURI == redirectURI.absoluteString { return saved }
        guard let endpoint = metadata.registrationEndpoint else { throw MCPOAuthError.clientRegistrationUnavailable }

        let body: JSONValue = [
            "client_name": .string(clientName),
            "redirect_uris": [.string(redirectURI.absoluteString)],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.jsonString().utf8)
        let (data, response) = try await http.data(for: request)
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(response.statusCode), let clientID = json?["client_id"]?.stringValue else {
            let reason = [json?["error"]?.stringValue, json?["error_description"]?.stringValue].compactMap { $0 }.joined(separator: ": ")
            throw MCPOAuthError.clientRegistrationFailed(reason.isEmpty ? "HTTP \(response.statusCode)" : reason)
        }
        let registration = OAuthClientRegistration(
            issuer: metadata.issuer, clientID: clientID, clientSecret: json?["client_secret"]?.stringValue,
            tokenEndpointAuthMethod: json?["token_endpoint_auth_method"]?.stringValue ?? "none",
            redirectURI: redirectURI.absoluteString)
        try store.save(registration)
        return registration
    }

    public static func authorizationURL(metadata: AuthorizationServerMetadata, clientID: String, redirectURI: URL, pkce: PKCE,
                                        state: String, resource: String, scopes: [String]) -> URL {
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource),
        ]
        if !scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " "))) }
        components.percentEncodedQuery = items.map { "\(OAuthForm.encode($0.name))=\(OAuthForm.encode($0.value ?? ""))" }.joined(separator: "&")
        return components.url!
    }

    /// RFC 9207 §2.4 issuer check, then state, then the authorization outcome. Returns the code.
    static func validate(_ callback: OAuthCallback, expectedState: String, metadata: AuthorizationServerMetadata) throws -> String {
        if let issuer = callback.issuer {
            guard issuer == metadata.issuer else { throw MCPOAuthError.issuerMismatch }
        } else if metadata.authorizationResponseIssParameterSupported {
            throw MCPOAuthError.issuerMismatch
        }
        guard callback.state == expectedState else { throw MCPOAuthError.stateMismatch }
        if let error = callback.error {
            throw MCPOAuthError.authorizationDenied([error, callback.errorDescription].compactMap { $0 }.joined(separator: ": "))
        }
        guard let code = callback.code, !code.isEmpty else { throw MCPOAuthError.authorizationDenied("no authorization code came back") }
        return code
    }
}

extension OAuthTokenSet {
    static func sameIssuer(_ a: String, _ b: String) -> Bool { MCPOAuthDiscovery.sameIssuer(a, b) }
}

// MARK: - Token endpoint

enum OAuthForm {
    /// `application/x-www-form-urlencoded` percent-encoding: everything but unreserved characters.
    static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func body(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }
}

struct OAuthTokenResponse: Sendable {
    var status: Int
    var json: JSONValue?

    var error: String? { json?["error"]?.stringValue }

    /// The OAuth error code and description only, never the raw body.
    var errorSummary: String? {
        guard let error else { return (200..<300).contains(status) ? nil : "HTTP \(status)" }
        return [error, json?["error_description"]?.stringValue].compactMap { $0 }.joined(separator: ": ")
    }

    func tokenSet(issuer: String, tokenEndpoint: URL, clientID: String, resource: String, requestedScopes: [String],
                  previousRefreshToken: String?, now: Date) -> OAuthTokenSet? {
        guard (200..<300).contains(status), let access = json?["access_token"]?.stringValue, !access.isEmpty else { return nil }
        let expiresIn = json?["expires_in"]?.doubleValue ?? json?["expires_in"]?.stringValue.flatMap(Double.init)
        return OAuthTokenSet(accessToken: access, tokenType: json?["token_type"]?.stringValue ?? "Bearer",
                             refreshToken: json?["refresh_token"]?.stringValue ?? previousRefreshToken,
                             // Whole seconds, so the Keychain copy (seconds since 1970) reads back identical.
                             expiresAt: expiresIn.map { Date(timeIntervalSince1970: (now.timeIntervalSince1970 + $0).rounded(.down)) },
                             scope: json?["scope"]?.stringValue,
                             issuer: issuer, tokenEndpoint: tokenEndpoint, clientID: clientID, resource: resource,
                             requestedScopes: requestedScopes)
    }
}

struct OAuthTokenEndpoint: Sendable {
    let http: any HTTPTransport

    /// Posts a token request with the client's authentication. `form` gets `client_id` (and the secret for
    /// `client_secret_post`) added.
    func request(endpoint: URL, form: inout [(String, String)], registration: OAuthClientRegistration?,
                 clientID fallbackClientID: String? = nil) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let clientID = registration?.clientID ?? fallbackClientID ?? ""
        switch (registration?.tokenEndpointAuthMethod, registration?.clientSecret) {
        case ("client_secret_basic", let secret?):
            let pair = "\(OAuthForm.encode(clientID)):\(OAuthForm.encode(secret))"
            request.setValue("Basic \(Data(pair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        case ("client_secret_post", let secret?):
            form.append(("client_id", clientID))
            form.append(("client_secret", secret))
        default:
            form.append(("client_id", clientID))
        }
        request.httpBody = OAuthForm.body(form)
        let (data, response) = try await http.data(for: request)
        return OAuthTokenResponse(status: response.statusCode, json: try? JSONDecoder().decode(JSONValue.self, from: data))
    }
}

// MARK: - Session (refresh)

/// Hands out a valid access token for one connector, refreshing it shortly before it expires. Concurrent
/// callers share one refresh. Use it as the `MCPAuthorizer` of a Streamable HTTP transport.
public actor OAuthSession: MCPAuthorizer {
    public let store: MCPOAuthStore
    private let http: any HTTPTransport
    private let now: @Sendable () -> Date
    private let refreshMargin: TimeInterval
    private var refreshing: Task<OAuthTokenSet, Error>?

    public init(store: MCPOAuthStore, http: any HTTPTransport = URLSessionTransport(),
                refreshMargin: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.http = http
        self.refreshMargin = refreshMargin
        self.now = now
    }

    /// A usable access token. Throws `MCPOAuthError.needsSignIn` when the user must sign in again.
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = try store.tokens() else { throw MCPOAuthError.needsSignIn }
        if !forceRefresh, !tokens.isExpired(at: now(), margin: refreshMargin) { return tokens.accessToken }
        return try await refresh(tokens).accessToken
    }

    public nonisolated func authorizationHeader() async throws -> String? {
        "Bearer \(try await accessToken())"
    }

    /// After a 401: refresh once. Returns false (so the 401 surfaces) when there is nothing to refresh with.
    public nonisolated func recover(from challenge: WWWAuthenticateChallenge?) async -> Bool {
        (try? await accessToken(forceRefresh: true)) != nil
    }

    private func refresh(_ tokens: OAuthTokenSet) async throws -> OAuthTokenSet {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.performRefresh(tokens) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func performRefresh(_ tokens: OAuthTokenSet) async throws -> OAuthTokenSet {
        guard let refreshToken = tokens.refreshToken else {
            throw MCPOAuthError.needsSignIn
        }
        let registration = (try? store.registration()).flatMap { MCPOAuthDiscovery.sameIssuer($0.issuer, tokens.issuer) && $0.clientID == tokens.clientID ? $0 : nil }
        var form: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("resource", tokens.resource),
        ]
        let response = try await OAuthTokenEndpoint(http: http).request(endpoint: tokens.tokenEndpoint, form: &form,
                                                                         registration: registration, clientID: tokens.clientID)
        if let fresh = response.tokenSet(issuer: tokens.issuer, tokenEndpoint: tokens.tokenEndpoint, clientID: tokens.clientID,
                                         resource: tokens.resource, requestedScopes: tokens.requestedScopes,
                                         previousRefreshToken: refreshToken, now: now()) {
            try store.save(fresh)
            return fresh
        }
        // The grant is dead (revoked, expired, client gone): forget it so the UI shows "Sign in".
        if ["invalid_grant", "invalid_client", "unauthorized_client"].contains(response.error ?? "") {
            try? store.clearTokens()
            throw MCPOAuthError.needsSignIn
        }
        throw MCPOAuthError.refreshFailed(response.errorSummary ?? "HTTP \(response.status)")
    }
}
