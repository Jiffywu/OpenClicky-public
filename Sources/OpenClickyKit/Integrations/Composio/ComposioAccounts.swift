// Composio connected accounts and session reuse, with the user's own Composio API key.
//
// Checked against Composio's REST API reference (v3.1) on 2026-11-03:
// - `GET  /connected_accounts?user_ids=…&statuses=…&cursor=…` lists accounts as `items` (each with `id`,
//   `toolkit.slug`, `status`, `alias`, `user_id`) and a `next_cursor`.
// - `GET  /auth_configs?toolkit_slug=…&is_composio_managed=true` lists auth configs; `POST /auth_configs` with
//   `{"toolkit": {"slug"}, "auth_config": {"type": "use_composio_managed_auth"}}` creates a Composio-managed one.
// - `POST /connected_accounts/link` with `{"auth_config_id", "user_id", "callback_url"}` answers 201 with a hosted
//   sign-in `redirect_url` and the new `connected_account_id`, which turns `ACTIVE` once the user finishes.
// - `GET  /connected_accounts/{id}` reads one account; `DELETE /connected_accounts/{id}` removes it.
// All take the project key in `x-api-key`.

import Foundation

/// One account the user connected in Composio (a Gmail, a Slack workspace…).
public struct ComposioConnectedAccount: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    /// The toolkit slug ("gmail", "googlecalendar").
    public var toolkit: String
    /// Composio's status: INITIALIZING, INITIATED, ACTIVE, FAILED, EXPIRED, INACTIVE…
    public var status: String
    public var alias: String?
    public var userID: String?

    public init(id: String, toolkit: String, status: String, alias: String? = nil, userID: String? = nil) {
        self.id = id
        self.toolkit = toolkit
        self.status = status
        self.alias = alias
        self.userID = userID
    }

    public var isActive: Bool { status.uppercased() == "ACTIVE" }
    /// The user is still signing in.
    public var isPending: Bool { ["INITIALIZING", "INITIATED"].contains(status.uppercased()) }
    /// The connection can't finish any more.
    public var hasFailed: Bool { ["FAILED", "EXPIRED", "INACTIVE"].contains(status.uppercased()) }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let toolkit = json["toolkit"]?["slug"]?.stringValue ?? json["toolkit_slug"]?.stringValue else {
            return nil
        }
        self.init(id: id, toolkit: toolkit, status: json["status"]?.stringValue ?? "UNKNOWN", alias: json["alias"]?.stringValue,
                  userID: json["user_id"]?.stringValue)
    }
}

/// A started connection: the page to open in the browser and the account it creates.
public struct ComposioConnectionLink: Sendable, Hashable {
    public var redirectURL: URL
    public var connectedAccountID: String
    public var expiresAt: String?
}

extension ComposioError {
    /// The user didn't finish signing in in time.
    public static let connectionTimedOut = ComposioError.http(status: 408, message: "The sign-in wasn't finished in time.")
}

extension ComposioClient {
    // MARK: Requests

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKeyForEnvironment, forHTTPHeaderField: "x-api-key")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.jsonString().utf8)
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> JSONValue {
        guard !apiKeyForEnvironment.isEmpty else { throw ComposioError.missingKey }
        let (data, response) = try await http.data(for: request)
        let json = data.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(response.statusCode) else {
            let message = json?["error"]?["message"]?.stringValue ?? json?["message"]?.stringValue
                ?? String(decoding: data.prefix(500), as: UTF8.self)
            throw ComposioError.http(status: response.statusCode, message: redact(message))
        }
        return json ?? .null
    }

    // MARK: Connected accounts

    /// The user's accounts (all statuses unless `statuses` narrows them), following Composio's pages (at most 20).
    public func connectedAccounts(userID: String, statuses: [String]? = nil, toolkit: String? = nil) async throws -> [ComposioConnectedAccount] {
        var accounts: [ComposioConnectedAccount] = []
        var cursor: String?
        for _ in 0..<20 {
            var query = [URLQueryItem(name: "user_ids", value: userID)]
            if let statuses, !statuses.isEmpty { query.append(URLQueryItem(name: "statuses", value: statuses.joined(separator: ","))) }
            if let toolkit { query.append(URLQueryItem(name: "toolkit_slugs", value: toolkit)) }
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page = try await send(request("GET", "connected_accounts", query: query))
            accounts += (page["items"]?.arrayValue ?? []).compactMap(ComposioConnectedAccount.init(json:))
            guard let next = page["next_cursor"]?.stringValue, !next.isEmpty, next != cursor else { break }
            cursor = next
        }
        return accounts
    }

    /// Toolkits with at least one active account, lower-cased and sorted.
    public func activeToolkits(userID: String) async throws -> [String] {
        let accounts = try await connectedAccounts(userID: userID, statuses: ["ACTIVE"])
        return Array(Set(accounts.filter(\.isActive).map { $0.toolkit.lowercased() })).sorted()
    }

    public func connectedAccount(id: String) async throws -> ComposioConnectedAccount {
        let json = try await send(request("GET", "connected_accounts/\(id)"))
        guard let account = ComposioConnectedAccount(json: json) else { throw ComposioError.invalidResponse }
        return account
    }

    /// Removes an account from Composio (the agent and the buddy stop seeing that app).
    public func disconnect(accountID: String) async throws {
        _ = try await send(request("DELETE", "connected_accounts/\(accountID)"))
    }

    /// The Composio-managed auth config for a toolkit, created when the project has none yet.
    public func managedAuthConfigID(toolkit: String) async throws -> String {
        let list = try await send(request("GET", "auth_configs", query: [URLQueryItem(name: "toolkit_slug", value: toolkit),
                                                                     URLQueryItem(name: "is_composio_managed", value: "true")]))
        if let id = list["items"]?.arrayValue?.first(where: { $0["is_disabled"]?.boolValue != true })?["id"]?.stringValue { return id }
        let created = try await send(request("POST", "auth_configs", body: [
            "toolkit": ["slug": .string(toolkit)], "auth_config": ["type": "use_composio_managed_auth"],
        ]))
        guard let id = created["auth_config"]?["id"]?.stringValue ?? created["id"]?.stringValue else { throw ComposioError.invalidResponse }
        return id
    }

    /// Starts connecting `toolkit` for `userID`: the hosted sign-in page to open, and the account it will become.
    public func startConnection(userID: String, toolkit: String, callbackURL: URL? = nil) async throws -> ComposioConnectionLink {
        let authConfig = try await managedAuthConfigID(toolkit: toolkit)
        var body: [String: JSONValue] = ["auth_config_id": .string(authConfig), "user_id": .string(userID)]
        if let callbackURL { body["callback_url"] = .string(callbackURL.absoluteString) }
        let json = try await send(request("POST", "connected_accounts/link", body: .object(body)))
        guard let text = json["redirect_url"]?.stringValue, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let account = json["connected_account_id"]?.stringValue else {
            throw ComposioError.invalidResponse
        }
        return ComposioConnectionLink(redirectURL: url, connectedAccountID: account, expiresAt: json["expires_at"]?.stringValue)
    }

    /// Polls an account until the user finishes signing in (ACTIVE), the connection fails, or `timeout` passes.
    public func waitForConnection(accountID: String, timeout: TimeInterval = 300, interval: TimeInterval = 2,
                                  now: @Sendable () -> Date = { Date() },
                                  sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) })
        async throws -> ComposioConnectedAccount {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            // A brief hiccup while the user is in the browser isn't the end of the connection.
            if let account = try? await connectedAccount(id: accountID) {
                if account.isActive || account.hasFailed { return account }
            }
            guard now() < deadline else { throw ComposioError.connectionTimedOut }
            try await sleep(interval)
        }
    }
}

// MARK: - Session reuse

/// Reuses Composio tool-router sessions instead of creating one for every connection and every job launch. A
/// session is kept for `lifetime`; a failed create waits out a growing backoff before Composio is asked again (the
/// same error comes back meanwhile), so a missing network or a bad key doesn't turn into a request per call.
public actor ComposioSessionCache {
    public static let shared = ComposioSessionCache()

    struct Key: Hashable {
        var base: String
        var userID: String
        var toolkits: [String]
        /// Sessions belong to a key; another key never reuses them.
        var keyFingerprint: Int
    }

    private struct Entry {
        var session: ComposioSession
        var createdAt: Date
    }

    private struct Failure {
        var error: ComposioError
        var retryAt: Date
        var attempts: Int
    }

    public let lifetime: TimeInterval
    public let initialBackoff: TimeInterval
    public let maxBackoff: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]
    private var failures: [Key: Failure] = [:]
    /// How many sessions were created (tests check reuse).
    public private(set) var creations = 0

    public init(lifetime: TimeInterval = 30 * 60, initialBackoff: TimeInterval = 5, maxBackoff: TimeInterval = 5 * 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.lifetime = lifetime
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.now = now
    }

    func key(_ client: ComposioClient, userID: String, toolkits: [String]) -> Key {
        Key(base: client.baseURL.absoluteString, userID: userID, toolkits: toolkits.map { $0.lowercased() }.sorted(),
            keyFingerprint: client.apiKeyForEnvironment.hashValue)
    }

    /// A live session for `userID` and `toolkits`: the cached one while it is fresh, else a new one.
    public func session(for client: ComposioClient, userID: String, toolkits: [String] = []) async throws -> ComposioSession {
        let key = key(client, userID: userID, toolkits: toolkits)
        let current = now()
        if let entry = entries[key], current.timeIntervalSince(entry.createdAt) < lifetime { return entry.session }
        if let failure = failures[key], current < failure.retryAt { throw failure.error }
        do {
            let session = try await client.createSession(userID: userID, toolkits: toolkits)
            creations += 1
            entries[key] = Entry(session: session, createdAt: now())
            failures[key] = nil
            return session
        } catch {
            let composio = (error as? ComposioError) ?? .http(status: 0, message: String(describing: error))
            let attempts = (failures[key]?.attempts ?? 0) + 1
            let wait = min(maxBackoff, initialBackoff * pow(2, Double(attempts - 1)))
            failures[key] = Failure(error: composio, retryAt: now().addingTimeInterval(wait), attempts: attempts)
            entries[key] = nil
            throw error
        }
    }

    /// Forgets the sessions for a user (the MCP endpoint refused one, or the settings changed).
    public func invalidate(userID: String? = nil) {
        entries = entries.filter { userID != nil && $0.key.userID != userID }
        failures = failures.filter { userID != nil && $0.key.userID != userID }
    }
}

// MARK: - Which toolkits are connected

/// The toolkits with an active Composio account, asked of Composio at most once per `lifetime` (job launches ask
/// often). Nil when Composio isn't set up or couldn't be asked: callers fall back to the toolkits listed in Settings.
public actor ComposioToolkitDirectory {
    public static let shared = ComposioToolkitDirectory()

    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var cached: (key: String, toolkits: [String], at: Date)?

    public init(lifetime: TimeInterval = 5 * 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.lifetime = lifetime
        self.now = now
    }

    public func activeToolkits(settings: ComposioSettings?, credentials: any CredentialStore, baseURL: URL = ComposioClient.defaultBaseURL,
                               http: any HTTPTransport = URLSessionTransport()) async -> [String]? {
        guard let settings, settings.enabled,
              let key = try? credentials.secret(named: ComposioClient.credentialName), !key.isEmpty else { return nil }
        let cacheKey = "\(baseURL.absoluteString)|\(settings.userID)|\(key.hashValue)"
        if let cached, cached.key == cacheKey, now().timeIntervalSince(cached.at) < lifetime { return cached.toolkits }
        let client = ComposioClient(apiKey: key, baseURL: baseURL, http: http)
        guard let toolkits = try? await client.activeToolkits(userID: settings.userID) else { return nil }
        cached = (cacheKey, toolkits, now())
        return toolkits
    }

    public func forget() { cached = nil }
}
