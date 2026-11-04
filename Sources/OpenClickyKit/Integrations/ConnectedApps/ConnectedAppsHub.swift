// The live set of connected apps: every enabled MCP connector, the Obsidian vault and Composio, behind one tool
// interface with cached connections and tool lists. The brain's `read_connected_apps`, `occtl apps` and the
// settings window all go through it.

import Foundation

/// A connected app as the prompt, the settings window and `occtl apps list` show it.
public struct ConnectedAppSummary: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case remote
        case command
        case obsidian
        case composio
    }

    public enum Status: String, Sendable, Hashable {
        case ready
        /// OAuth connector without tokens.
        case needsSignIn = "needs-sign-in"
        /// A bearer token, header value or environment value is missing from the Keychain.
        case missingSecret = "missing-secret"
        case disabled
    }

    public var id: String
    public var name: String
    public var accountLabel: String?
    public var kind: Kind
    public var capability: String?
    public var status: Status
    /// `read_connected_apps` may call this app's write tools too.
    public var allowsWrites: Bool
    /// Where it is: a URL, a command line or a vault path.
    public var location: String

    public var labelledName: String { accountLabel.map { "\(name) (\($0))" } ?? name }
}

/// The outcome of `ConnectedAppsHub.test`.
public enum ConnectorTestResult: Sendable, Hashable {
    case reachable(toolCount: Int, readToolCount: Int, server: String?, protocolVersion: String?, capability: String?)
    case needsSignIn(String)
    case unauthorized(String)
    case failed(String)

    public var isReachable: Bool { if case .reachable = self { true } else { false } }

    public var summary: String {
        switch self {
        case .reachable(let count, let reads, let server, let version, _):
            "Connected\(server.map { " to \($0)" } ?? "")\(version.map { " (MCP \($0))" } ?? ""): \(count) tool\(count == 1 ? "" : "s"), \(reads) read-only."
        case .needsSignIn(let detail): "Needs sign-in: \(detail)"
        case .unauthorized(let detail): "Not authorized: \(detail)"
        case .failed(let detail): "Failed: \(detail)"
        }
    }
}

public actor ConnectedAppsHub {
    public private(set) var registry: ConnectorRegistry
    public let environment: ConnectorEnvironment
    private var factory: ConnectorFactory { ConnectorFactory(environment: environment) }
    private var sources: [String: any ConnectedAppSource] = [:]
    private var toolCache: [String: [MCPToolDefinition]] = [:]

    public init(registry: ConnectorRegistry, environment: ConnectorEnvironment) {
        self.registry = registry
        self.environment = environment
    }

    /// Swap in an edited registry. Connections whose settings changed are closed and reopened on next use.
    public func update(registry new: ConnectorRegistry) async {
        let old = registry
        registry = new
        var stale: [String] = []
        for id in sources.keys {
            switch id {
            case ObsidianVault.connectorID: if old.obsidian != new.obsidian { stale.append(id) }
            case ComposioClient.connectorID: if old.composio != new.composio { stale.append(id) }
            default: if old.connector(id: id) != new.connector(id: id) { stale.append(id) }
            }
        }
        for id in stale { await drop(id) }
    }

    /// Forget a cached connection (after sign-in, a new token or an edit). For Composio the session goes too, so the
    /// next use asks for a fresh one.
    public func reset(_ appID: String) async {
        if appID == ComposioClient.connectorID { await environment.composioSessions.invalidate() }
        await drop(appID)
    }

    public func shutdown() async {
        for source in sources.values { await source.close() }
        sources.removeAll()
        toolCache.removeAll()
    }

    // MARK: Listing

    /// Every app, enabled or not, with its status. Order: connectors as added, then Obsidian, then Composio.
    public func summaries() -> [ConnectedAppSummary] {
        Self.summaries(of: registry, credentials: environment.credentials)
    }

    public nonisolated static func summaries(of registry: ConnectorRegistry, credentials: any CredentialStore) -> [ConnectedAppSummary] {
        var result = registry.connectors.map { connector in
            ConnectedAppSummary(id: connector.id, name: connector.name, accountLabel: connector.accountLabel,
                                kind: connector.transport.remoteURL == nil ? .command : .remote,
                                capability: connector.capabilityDescription, status: status(of: connector, credentials: credentials),
                                allowsWrites: connector.allowWrites ?? false, location: connector.transport.summary)
        }
        if let obsidian = registry.obsidian {
            result.append(ConnectedAppSummary(id: ObsidianVault.connectorID, name: "Obsidian", accountLabel: nil, kind: .obsidian,
                                              capability: "Search, read and write Markdown notes in a local vault",
                                              status: obsidian.enabled ? .ready : .disabled, allowsWrites: false,
                                              location: obsidian.vaultPath))
        }
        if let composio = registry.composio {
            let hasKey = (try? credentials.secret(named: ComposioClient.credentialName))?.isEmpty == false
            result.append(ConnectedAppSummary(id: ComposioClient.connectorID, name: "Composio", accountLabel: composio.userID,
                                              kind: .composio,
                                              capability: composio.toolkits.isEmpty ? "Apps connected in your Composio account"
                                                  : "Apps in your Composio account: \(composio.toolkits.joined(separator: ", "))",
                                              status: !composio.enabled ? .disabled : hasKey ? .ready : .missingSecret,
                                              allowsWrites: false, location: ComposioClient.defaultBaseURL.host ?? "composio"))
        }
        return result
    }

    static func status(of connector: ConnectorConfig, credentials: any CredentialStore) -> ConnectedAppSummary.Status {
        guard connector.enabled else { return .disabled }
        func has(_ name: String) -> Bool { (try? credentials.secret(named: name))?.isEmpty == false }
        let secrets = Array((connector.secretHeaders ?? [:]).values) + Array((connector.environment ?? [:]).values)
        if !secrets.allSatisfy(has) { return .missingSecret }
        switch connector.auth {
        case .none: return .ready
        case .bearer: return has(ConnectorSecretNames.bearer(connector.id)) ? .ready : .missingSecret
        case .oauth:
            let tokens = try? MCPOAuthStore(credentials: credentials, connectorID: connector.id).tokens()
            return tokens == nil ? .needsSignIn : .ready
        }
    }

    /// Ids of apps that are enabled and have what they need to connect.
    public func usableAppIDs() -> [String] { summaries().filter { $0.status == .ready }.map(\.id) }

    // MARK: Tools

    public func tools(for appID: String, refresh: Bool = false) async throws -> [MCPToolDefinition] {
        if !refresh, let cached = toolCache[appID] { return cached }
        let source = try await source(for: appID)
        let tools = try await source.listTools()
        toolCache[appID] = tools
        return tools
    }

    public func call(appID: String, tool: String, arguments: JSONValue = [:]) async throws -> MCPToolResult {
        do {
            return try await source(for: appID).callTool(tool, arguments: arguments)
        } catch let error as MCPClientError {
            // A dead local server or a lost connection: start over on the next call.
            switch error {
            case .processExited, .launchFailed, .sessionExpired: await drop(appID)
            default: break
            }
            throw error
        }
    }

    /// Connects from scratch (no cached connection), lists the tools and reports what happened. Never throws.
    public func test(_ appID: String) async -> ConnectorTestResult {
        await drop(appID)
        do {
            let source = try await source(for: appID)
            let description = try await source.serverDescription()
            let tools = try await source.listTools()
            toolCache[appID] = tools
            let name = summaries().first { $0.id == appID }?.name
            return .reachable(toolCount: tools.count, readToolCount: tools.filter { ToolSafety.access(of: $0) == .read }.count,
                              server: description?.serverInfo.map { $0.title ?? $0.name }, protocolVersion: description?.protocolVersion,
                              capability: CapabilityDeriver.describe(tools, appName: name))
        } catch {
            await drop(appID)
            return Self.classify(error)
        }
    }

    /// A readable outcome for any connector error.
    public static func classify(_ error: Error) -> ConnectorTestResult {
        switch error {
        case MCPOAuthError.needsSignIn: return .needsSignIn("sign in with your browser first.")
        case MCPClientError.unauthorized(let challenge):
            return .unauthorized("the server answered HTTP 401\(challenge?.errorDescription.map { " (\($0))" } ?? ""). Check the token or sign in again.")
        case MCPClientError.forbidden(let challenge):
            return .unauthorized("the server answered HTTP 403\(challenge?.error.map { " (\($0))" } ?? "").")
        case let error as URLError:
            return .failed("couldn't reach the server (\(error.code == .timedOut ? "timed out" : error.localizedDescription)).")
        default:
            return .failed(String(describing: error))
        }
    }

    // MARK: Sources

    func source(for appID: String) async throws -> any ConnectedAppSource {
        if let existing = sources[appID] { return existing }
        let source: any ConnectedAppSource
        switch appID {
        case ObsidianVault.connectorID where registry.connector(id: appID) == nil:
            guard let settings = registry.obsidian, settings.enabled else { throw ConnectorSetupError.notConfigured("Obsidian") }
            source = ObsidianToolSource(vault: try ObsidianVault(path: settings.vaultPath))
        case ComposioClient.connectorID where registry.connector(id: appID) == nil:
            guard let settings = registry.composio, settings.enabled else { throw ConnectorSetupError.notConfigured("Composio") }
            source = try await factory.composioSource(settings: settings)
        default:
            guard let connector = registry.connector(id: appID) else { throw ConnectorRegistryError.notFound(appID) }
            guard connector.enabled else { throw ConnectorSetupError.notConfigured("\(connector.name) is turned off, so it") }
            source = MCPClientSource(client: try factory.client(for: connector))
        }
        // Creating a Composio session suspends; another caller may have opened this app meanwhile. Keep theirs.
        if let existing = sources[appID] {
            await source.close()
            return existing
        }
        sources[appID] = source
        return source
    }

    /// Lets tests and the app put in a ready source (for example a fake).
    public func install(_ source: any ConnectedAppSource, for appID: String) {
        sources[appID] = source
        toolCache[appID] = nil
    }

    private func drop(_ appID: String) async {
        toolCache[appID] = nil
        if let source = sources.removeValue(forKey: appID) { await source.close() }
    }
}
