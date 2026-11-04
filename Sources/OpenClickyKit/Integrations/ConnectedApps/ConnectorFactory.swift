// Turns a connector's saved settings plus its Keychain secrets into a live MCP transport, and wraps every kind of
// connected app (MCP server, Obsidian vault, Composio session) behind one tool interface.

import Foundation

/// Something that offers MCP-style tools.
public protocol ConnectedAppSource: Sendable {
    func listTools() async throws -> [MCPToolDefinition]
    func callTool(_ name: String, arguments: JSONValue) async throws -> MCPToolResult
    /// Server name and protocol revision, when there is a server to describe.
    func serverDescription() async throws -> MCPServerDescription?
    func close() async
}

/// An MCP server reached through `MCPClient`.
public struct MCPClientSource: ConnectedAppSource {
    public let client: MCPClient

    public init(client: MCPClient) { self.client = client }

    public func listTools() async throws -> [MCPToolDefinition] { try await client.listTools() }
    public func callTool(_ name: String, arguments: JSONValue) async throws -> MCPToolResult {
        try await client.callTool(name, arguments: arguments)
    }
    public func serverDescription() async throws -> MCPServerDescription? { try await client.connect() }
    public func close() async { await client.close() }
}

/// What connectors need from the outside world. Tests swap in fakes.
public struct ConnectorEnvironment: Sendable {
    public var credentials: any CredentialStore
    public var http: any HTTPTransport
    /// OpenClicky's own environment. Local servers inherit only its basic variables (HOME, USER, locale…) and a
    /// widened PATH; see `MCPCommandResolver.environment`.
    public var processEnvironment: [String: String]
    public var clientInfo: MCPImplementation
    public var requestTimeout: Duration
    public var probeTimeout: Duration
    public var composioBaseURL: URL
    /// Composio tool-router sessions, reused while fresh. The app passes `ComposioSessionCache.shared` to every
    /// environment it builds (Settings, the brain, job launches), so a reset from Settings reaches all of them; the
    /// default is a cache of this environment's own.
    public var composioSessions: ComposioSessionCache

    public init(credentials: any CredentialStore, http: any HTTPTransport = URLSessionTransport(),
                processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                clientInfo: MCPImplementation = MCPImplementation(name: "OpenClicky", version: "1.0"),
                requestTimeout: Duration = .seconds(60), probeTimeout: Duration = .seconds(10),
                composioBaseURL: URL = ComposioClient.defaultBaseURL, composioSessions: ComposioSessionCache = ComposioSessionCache()) {
        self.composioSessions = composioSessions
        self.credentials = credentials
        self.http = http
        self.processEnvironment = processEnvironment
        self.clientInfo = clientInfo
        self.requestTimeout = requestTimeout
        self.probeTimeout = probeTimeout
        self.composioBaseURL = composioBaseURL
    }

    var clientOptions: MCPClient.Options {
        MCPClient.Options(clientInfo: clientInfo, probeTimeout: probeTimeout, requestTimeout: requestTimeout)
    }
}

public enum ConnectorSetupError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A secret the connector needs is not in the Keychain.
    case missingSecret(connector: String, credential: String)
    case commandNotFound(String)
    case notConfigured(String)

    public var description: String {
        switch self {
        case .missingSecret(let connector, let credential):
            "\(connector) needs a secret that isn't saved yet (Keychain item \"\(credential)\"). Add it in Settings → Connected Apps or with: occtl key set \(credential)"
        case .commandNotFound(let command):
            "Couldn't find \"\(command)\" on this Mac. Install it, or enter its full path."
        case .notConfigured(let app): "\(app) isn't set up."
        }
    }
}

public struct ConnectorFactory: Sendable {
    public var environment: ConnectorEnvironment

    public init(environment: ConnectorEnvironment) { self.environment = environment }

    /// A transport for one connector. Throws when a secret is missing or a command can't be found.
    public func transport(for connector: ConnectorConfig) throws -> any MCPMessageTransport {
        switch connector.transport {
        case .remote(let url):
            var headers: [String: String] = [:]
            for (header, credential) in connector.secretHeaders ?? [:] {
                headers[header] = try secret(credential, for: connector)
            }
            return MCPStreamableHTTPTransport(endpoint: url, http: environment.http, authorizer: try authorizer(for: connector),
                                              staticHeaders: headers)
        case .stdio(let command, let arguments):
            var extra: [String: String] = [:]
            for (variable, credential) in connector.environment ?? [:] {
                extra[variable] = try secret(credential, for: connector)
            }
            let childEnvironment = MCPCommandResolver.environment(base: environment.processEnvironment, adding: extra)
            guard let executable = MCPCommandResolver.resolve(command, searchPath: childEnvironment["PATH"] ?? "") else {
                throw ConnectorSetupError.commandNotFound(command)
            }
            return MCPStdioTransport(launch: MCPStdioLaunch(executable: executable, arguments: arguments, environment: childEnvironment))
        }
    }

    public func client(for connector: ConnectorConfig) throws -> MCPClient {
        MCPClient(transport: try transport(for: connector), options: environment.clientOptions)
    }

    /// Bearer, OAuth or nothing.
    public func authorizer(for connector: ConnectorConfig) throws -> (any MCPAuthorizer)? {
        switch connector.auth {
        case .none: nil
        case .bearer: StaticBearerAuthorizer(token: try secret(ConnectorSecretNames.bearer(connector.id), for: connector))
        case .oauth: OAuthSession(store: oauthStore(for: connector), http: environment.http)
        }
    }

    public func oauthStore(for connector: ConnectorConfig) -> MCPOAuthStore {
        MCPOAuthStore(credentials: environment.credentials, connectorID: connector.id)
    }

    /// A Composio session as a tool source.
    public func composioSource(settings: ComposioSettings) async throws -> MCPClientSource {
        guard let key = try? environment.credentials.secret(named: ComposioClient.credentialName), !key.isEmpty else {
            throw ComposioError.missingKey
        }
        let composio = ComposioClient(apiKey: key, baseURL: environment.composioBaseURL, http: environment.http)
        let session = try await environment.composioSessions.session(for: composio, userID: settings.userID, toolkits: settings.toolkits)
        let transport = MCPStreamableHTTPTransport(endpoint: session.mcpURL, http: environment.http,
                                                   staticHeaders: composio.mcpHeaders(for: session.mcpURL))
        return MCPClientSource(client: MCPClient(transport: transport, options: environment.clientOptions))
    }

    private func secret(_ name: String, for connector: ConnectorConfig) throws -> String {
        guard let value = try environment.credentials.secret(named: name), !value.isEmpty else {
            throw ConnectorSetupError.missingSecret(connector: connector.name, credential: name)
        }
        return value
    }
}
