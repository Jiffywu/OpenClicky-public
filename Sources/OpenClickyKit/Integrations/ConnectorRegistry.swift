// The user's connected apps: MCP connectors (remote URL or a command on this Mac), the Obsidian vault and an
// optional Composio account. Stored as JSON next to config.json
// (`~/Library/Application Support/OpenClicky/connectors.json`). Like config.json it never holds a secret:
// bearer tokens, OAuth tokens, header values and environment values live in the Keychain under the names in
// `ConnectorSecretNames`.

import Foundation

/// How OpenClicky reaches a connector.
public enum ConnectorTransport: Sendable, Hashable, Codable {
    /// A Streamable HTTP endpoint.
    case remote(URL)
    /// A local server started as a child process speaking MCP over stdio.
    case stdio(command: String, arguments: [String])

    private enum CodingKeys: String, CodingKey { case type, url, command, arguments }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "remote": self = .remote(try container.decode(URL.self, forKey: .url))
        case "stdio": self = .stdio(command: try container.decode(String.self, forKey: .command),
                                    arguments: try container.decodeIfPresent([String].self, forKey: .arguments) ?? [])
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown transport \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .remote(let url):
            try container.encode("remote", forKey: .type)
            try container.encode(url, forKey: .url)
        case .stdio(let command, let arguments):
            try container.encode("stdio", forKey: .type)
            try container.encode(command, forKey: .command)
            try container.encode(arguments, forKey: .arguments)
        }
    }

    public var remoteURL: URL? { if case .remote(let url) = self { url } else { nil } }

    /// "https://mcp.example.com/mcp" or "npx -y some-server".
    public var summary: String {
        switch self {
        case .remote(let url): url.absoluteString
        case .stdio(let command, let arguments): ([command] + arguments).joined(separator: " ")
        }
    }
}

/// How a connector proves who the user is.
public enum ConnectorAuth: String, Sendable, Hashable, Codable, CaseIterable {
    /// Nothing, or only `secretHeaders`/`environment` values.
    case none
    /// A fixed token (API key, personal access token) sent as `Authorization: Bearer`.
    case bearer
    /// Browser sign-in with OAuth 2.1 + PKCE; tokens refresh automatically.
    case oauth
}

/// One connected app backed by an MCP server.
public struct ConnectorConfig: Sendable, Hashable, Codable, Identifiable {
    /// Stable slug (`[a-z0-9-]`): Keychain item names, agent server keys and env var names derive from it.
    public var id: String
    /// What the user calls it ("Notion", "Work GitHub").
    public var name: String
    public var transport: ConnectorTransport
    public var auth: ConnectorAuth
    public var enabled: Bool
    /// Which account this is ("Work", "jeff@…"), shown to the brain and agents so they pick the right one.
    public var accountLabel: String?
    /// One line on what it can do; derived from the tool names after a successful test unless the user wrote one.
    public var capabilityDescription: String?
    /// A client id the user registered with the server's OAuth provider (when it has no dynamic registration).
    public var oauthClientID: String?
    /// Extra request headers whose values are secrets: header name → credential name in the Keychain.
    public var secretHeaders: [String: String]?
    /// stdio only: environment variables whose values are secrets: variable name → credential name.
    public var environment: [String: String]?
    /// Lets `read_connected_apps` call tools that are not clearly read-only. Off by default.
    public var allowWrites: Bool?
    /// The preset this came from, if any.
    public var preset: String?

    public init(id: String, name: String, transport: ConnectorTransport, auth: ConnectorAuth = .none, enabled: Bool = true,
                accountLabel: String? = nil, capabilityDescription: String? = nil, oauthClientID: String? = nil,
                secretHeaders: [String: String]? = nil, environment: [String: String]? = nil, allowWrites: Bool? = nil,
                preset: String? = nil) {
        self.id = id
        self.name = name
        self.transport = transport
        self.auth = auth
        self.enabled = enabled
        self.accountLabel = accountLabel
        self.capabilityDescription = capabilityDescription
        self.oauthClientID = oauthClientID
        self.secretHeaders = secretHeaders
        self.environment = environment
        self.allowWrites = allowWrites
        self.preset = preset
    }

    /// "Notion (Work)".
    public var labelledName: String { accountLabel.map { "\(name) (\($0))" } ?? name }
}

/// Settings for the local Obsidian vault.
public struct ObsidianSettings: Sendable, Hashable, Codable {
    public var vaultPath: String
    public var enabled: Bool

    public init(vaultPath: String, enabled: Bool = true) {
        self.vaultPath = vaultPath
        self.enabled = enabled
    }
}

/// Settings for the optional Composio adapter (used only with the user's own Composio API key).
public struct ComposioSettings: Sendable, Hashable, Codable {
    /// The user id OpenClicky creates Composio sessions for (any stable string, e.g. an email).
    public var userID: String
    /// Toolkits to enable in the session; empty means Composio's default.
    public var toolkits: [String]
    public var enabled: Bool

    public init(userID: String, toolkits: [String] = [], enabled: Bool = true) {
        self.userID = userID
        self.toolkits = toolkits
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case userID, toolkits, enabled }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(String.self, forKey: .userID)
        toolkits = try container.decodeIfPresent([String].self, forKey: .toolkits) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

public enum ConnectorRegistryError: Error, Equatable, CustomStringConvertible {
    case duplicate(String)
    case notFound(String)
    case invalidURL(String)
    case invalidName

    public var description: String {
        switch self {
        case .duplicate(let name): "A connector named \"\(name)\" already exists."
        case .notFound(let name): "No connector named \"\(name)\". See: occtl apps list"
        case .invalidURL(let text): "\"\(text)\" isn't a usable server URL. Use an https:// address with no user name or password in it (plain http:// works only for servers on this Mac)."
        case .invalidName: "Connector names need at least one letter or digit."
        }
    }
}

public struct ConnectorRegistry: Sendable, Hashable, Codable {
    public var version: Int
    public var connectors: [ConnectorConfig]
    public var obsidian: ObsidianSettings?
    public var composio: ComposioSettings?

    public init(version: Int = 1, connectors: [ConnectorConfig] = [], obsidian: ObsidianSettings? = nil, composio: ComposioSettings? = nil) {
        self.version = version
        self.connectors = connectors
        self.obsidian = obsidian
        self.composio = composio
    }

    /// `connectors.json` next to config.json, or the file named by `OPENCLICKY_CONNECTORS_FILE` (tests, scripts).
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["OPENCLICKY_CONNECTORS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("connectors.json")
    }

    /// Ids the built-in apps use; user connectors get a suffix instead.
    public static let reservedIDs: Set<String> = [ObsidianVault.connectorID, ComposioClient.connectorID]

    /// The saved registry, or an empty one when there is no file yet.
    public static func load(from url: URL = defaultURL) throws -> ConnectorRegistry {
        guard FileManager.default.fileExists(atPath: url.path) else { return ConnectorRegistry() }
        return try JSONDecoder().decode(ConnectorRegistry.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The connector with exactly this id.
    public func connector(id: String) -> ConnectorConfig? { connectors.first { $0.id == id } }

    /// Finds a connector by id or by name (case-insensitive).
    public func connector(_ idOrName: String) -> ConnectorConfig? {
        connectors.first { $0.id == idOrName } ?? connectors.first { $0.name.caseInsensitiveCompare(idOrName) == .orderedSame }
    }

    public var enabledConnectors: [ConnectorConfig] { connectors.filter(\.enabled) }

    /// Adds a connector, giving it a unique id derived from its name when `id` is empty.
    @discardableResult
    public mutating func add(_ connector: ConnectorConfig) throws -> ConnectorConfig {
        var connector = connector
        guard !connector.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ConnectorRegistryError.invalidName }
        if connectors.contains(where: { $0.name.caseInsensitiveCompare(connector.name) == .orderedSame }) {
            throw ConnectorRegistryError.duplicate(connector.name)
        }
        if case .remote(let url) = connector.transport, !Self.isAcceptableRemoteURL(url) {
            throw ConnectorRegistryError.invalidURL(Self.redacted(url))
        }
        let base = Self.slug(connector.id.isEmpty ? connector.name : connector.id)
        guard !base.isEmpty else { throw ConnectorRegistryError.invalidName }
        var candidate = base
        var counter = 2
        while connectors.contains(where: { $0.id == candidate }) || Self.reservedIDs.contains(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        connector.id = candidate
        connectors.append(connector)
        return connector
    }

    @discardableResult
    public mutating func remove(_ idOrName: String) throws -> ConnectorConfig {
        guard let found = connector(idOrName) else { throw ConnectorRegistryError.notFound(idOrName) }
        connectors.removeAll { $0.id == found.id }
        return found
    }

    public mutating func update(_ connector: ConnectorConfig) {
        guard let index = connectors.firstIndex(where: { $0.id == connector.id }) else { return }
        connectors[index] = connector
    }

    /// https anywhere; plain http only for this Mac (local development servers). A user name or password in the
    /// URL is refused: connectors.json, `occtl apps list` and agent configs show the URL, so it must not carry a
    /// secret (use a bearer token or a secret header instead).
    public static func isAcceptableRemoteURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty, url.fragment == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    /// The URL for messages, with any user name and password replaced by "•••".
    public static func redacted(_ url: URL) -> String {
        guard url.user != nil || url.password != nil, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        guard let text = components.string, let schemeEnd = text.range(of: "://") else { return "(a URL with credentials)" }
        return text.replacingCharacters(in: schemeEnd, with: "://•••@")
    }

    /// Lower-case letters, digits and single hyphens.
    public static func slug(_ text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) { result.unicodeScalars.append(scalar) }
            else if !result.isEmpty, result.last != "-" { result.append("-") }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return String(result.prefix(40))
    }
}

/// Keychain item names for connector secrets. All are `[a-z0-9-]` so the `OPENCLICKY_KEY_<NAME>` environment
/// override of `KeychainCredentialStore` works for them too.
public enum ConnectorSecretNames {
    public static func bearer(_ id: String) -> String { "connector-\(id)-bearer" }
    public static func oauthTokens(_ id: String) -> String { "connector-\(id)-oauth" }
    public static func oauthClient(_ id: String) -> String { "connector-\(id)-oauth-client" }
    public static func header(_ id: String, _ header: String) -> String { "connector-\(id)-header-\(ConnectorRegistry.slug(header))" }
    public static func environment(_ id: String, _ variable: String) -> String { "connector-\(id)-env-\(ConnectorRegistry.slug(variable))" }

    /// Every item a connector may own, for clean removal.
    public static func all(for connector: ConnectorConfig) -> [String] {
        [bearer(connector.id), oauthTokens(connector.id), oauthClient(connector.id)]
            + (connector.secretHeaders ?? [:]).values.filter { $0.hasPrefix("connector-\(connector.id)-") }
            + (connector.environment ?? [:]).values.filter { $0.hasPrefix("connector-\(connector.id)-") }
    }
}

// MARK: - Presets

/// Official remote MCP servers the settings window and `occtl apps add <preset>` offer. Each URL and auth
/// method was checked against the vendor's own documentation on 2026-10-30. Anything else can be added by URL
/// (Settings → Connected Apps → Add by URL, or `occtl apps add <name> <url>`).
public struct ConnectorPreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var url: URL
    public var auth: ConnectorAuth
    /// Shown next to the add button.
    public var note: String
    /// Where to create a token for bearer auth.
    public var tokenHelpURL: URL?
    public var docsURL: URL

    public static let all: [ConnectorPreset] = [
        // https://github.com/github/github-mcp-server/blob/main/docs/remote-server.md: hosted at
        // https://api.githubcopilot.com/mcp/ ("/readonly" variants exist). GitHub's OAuth for it needs a
        // registered OAuth app, so the preset uses a personal access token as a bearer token.
        ConnectorPreset(id: "github", name: "GitHub", url: URL(string: "https://api.githubcopilot.com/mcp/")!, auth: .bearer,
                        note: "Uses a GitHub personal access token.",
                        tokenHelpURL: URL(string: "https://github.com/settings/personal-access-tokens"),
                        docsURL: URL(string: "https://github.com/github/github-mcp-server/blob/main/docs/remote-server.md")!),
        // https://developers.notion.com/docs/get-started-with-mcp: Streamable HTTP at https://mcp.notion.com/mcp,
        // OAuth in the browser (Business/Enterprise workspaces can also issue MCP bearer tokens).
        ConnectorPreset(id: "notion", name: "Notion", url: URL(string: "https://mcp.notion.com/mcp")!, auth: .oauth,
                        note: "Sign in with Notion in your browser.", tokenHelpURL: nil,
                        docsURL: URL(string: "https://developers.notion.com/docs/get-started-with-mcp")!),
        // https://linear.app/docs/mcp: Streamable HTTP at https://mcp.linear.app/mcp (read-only at /mcp/readonly),
        // OAuth 2.1 with dynamic client registration, or a Linear API key as a bearer token.
        ConnectorPreset(id: "linear", name: "Linear", url: URL(string: "https://mcp.linear.app/mcp")!, auth: .oauth,
                        note: "Sign in with Linear in your browser, or use a Linear API key.",
                        tokenHelpURL: URL(string: "https://linear.app/settings/account/security"),
                        docsURL: URL(string: "https://linear.app/docs/mcp")!),
    ]

    public static func named(_ text: String) -> ConnectorPreset? {
        all.first { $0.id == text.lowercased() || $0.name.caseInsensitiveCompare(text) == .orderedSame }
    }

    public var connector: ConnectorConfig {
        ConnectorConfig(id: id, name: name, transport: .remote(url), auth: auth, preset: id)
    }
}
