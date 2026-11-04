import Foundation

/// What a job gets at launch on top of its settings: more MCP servers, more instruction sections and plain
/// environment variables for its commands.
public struct AgentLaunchExtras: Sendable {
    public var mcpServers: [AgentMCPServer]
    /// Instruction sections appended to the job's developer instructions.
    public var instructions: [String]
    /// Plain variables for the job's commands (never secrets; those travel with their MCP server).
    public var environment: [String: String]

    public init(mcpServers: [AgentMCPServer] = [], instructions: [String] = [], environment: [String: String] = [:]) {
        self.mcpServers = mcpServers
        self.instructions = instructions
        self.environment = environment
    }

    public static let none = AgentLaunchExtras()

    /// Both sets together; servers named twice keep the first.
    public func merged(with other: AgentLaunchExtras) -> AgentLaunchExtras {
        var names = Set(mcpServers.map(\.name))
        var servers = mcpServers
        for server in other.mcpServers where names.insert(server.name).inserted { servers.append(server) }
        return AgentLaunchExtras(mcpServers: servers, instructions: instructions + other.instructions,
                                 environment: environment.merging(other.environment) { mine, _ in mine })
    }
}

extension ConnectedAppsAgentExport {
    /// The export as MCP servers a harness can be given. Secret values ride in `secretValues` and the bearer token,
    /// named by the same variables the export chose; the stdio servers' PATH is plain configuration.
    public func agentServers() -> [AgentMCPServer] {
        servers.map { server in
            switch server.transport {
            case .http(let url, let bearerVariable, let headerVariables):
                var secrets: [String: String] = [:]
                for variable in headerVariables.values { secrets[variable] = environment[variable] }
                return AgentMCPServer(name: server.key, transport: .http(url), bearerToken: bearerVariable.flatMap { environment[$0] },
                                      tokenEnvironmentVariable: bearerVariable, startupTimeout: server.startupTimeoutSeconds,
                                      toolTimeout: server.toolTimeoutSeconds, secretHeaders: headerVariables, secretValues: secrets)
            case .stdio(let command, let arguments, let variables, let path):
                var secrets: [String: String] = [:]
                for variable in variables { secrets[variable] = environment[variable] }
                return AgentMCPServer(name: server.key, transport: .stdio(command: command, arguments: arguments),
                                      startupTimeout: server.startupTimeoutSeconds, toolTimeout: server.toolTimeoutSeconds,
                                      forwardedVariables: variables, environment: ["PATH": path], secretValues: secrets)
            }
        }
    }

    /// The servers, the Connected apps (and Obsidian) instruction section and `OBSIDIAN_VAULT_PATH`.
    public func launchExtras() -> AgentLaunchExtras {
        var environment: [String: String] = [:]
        if let obsidianVaultPath { environment[Self.obsidianVariable] = obsidianVaultPath }
        return AgentLaunchExtras(mcpServers: agentServers(), instructions: [instructions()], environment: environment)
    }
}

/// Exports the user's connected apps for every job launch: reads the connector registry, runs
/// `ConnectedAppsAgentExporter` (fresh OAuth tokens, a Composio session), and routes OAuth apps through
/// `AgentConnectorRelay` so their tokens are refreshed for as long as the job runs.
public actor AgentConnectedApps {
    public nonisolated let registryURL: URL
    public nonisolated let relay: AgentConnectorRelay
    private let environment: ConnectorEnvironment
    private var sessions: [String: OAuthSession] = [:]

    public init(registryURL: URL = ConnectorRegistry.defaultURL, environment: ConnectorEnvironment,
                relay: AgentConnectorRelay? = nil) {
        self.registryURL = registryURL
        self.environment = environment
        self.relay = relay ?? AgentConnectorRelay(http: environment.http)
    }

    /// What connected apps add to the job being launched now. A registry that can't be read adds a note saying so.
    public func extras() async -> AgentLaunchExtras {
        let registry: ConnectorRegistry
        do {
            registry = try ConnectorRegistry.load(from: registryURL)
        } catch {
            return AgentLaunchExtras(instructions: ["## Connected apps\nOpenClicky couldn't read the user's connected apps right now, so none are offered to this job."])
        }
        var export = await ConnectedAppsAgentExporter(registry: registry, environment: environment).export()
        relayOAuthApps(&export, registry: registry)
        return export.launchExtras()
    }

    /// OAuth apps go through the relay: the job holds the relay's token, the relay holds a session that refreshes the
    /// app's token. An app the relay can't serve keeps the token exported at launch.
    private func relayOAuthApps(_ export: inout ConnectedAppsAgentExport, registry: ConnectorRegistry) {
        for connector in registry.connectors where connector.enabled && connector.auth == .oauth {
            guard case .remote(let upstream) = connector.transport else { continue }
            let key = ConnectedAppsAgentExporter.serverKey(connector.id)
            guard let index = export.servers.firstIndex(where: { $0.key == key }),
                  case .http(_, let bearer?, let headers) = export.servers[index].transport else { continue }
            let session = sessions[connector.id]
                ?? OAuthSession(store: MCPOAuthStore(credentials: environment.credentials, connectorID: connector.id), http: environment.http)
            sessions[connector.id] = session
            guard let local = try? relay.route(key: key, upstream: upstream, token: { force in try await session.accessToken(forceRefresh: force) })
            else { continue }
            export.servers[index].transport = .http(url: local.url, bearerTokenVariable: bearer, headerVariables: headers)
            export.environment[bearer] = local.token
        }
    }
}
