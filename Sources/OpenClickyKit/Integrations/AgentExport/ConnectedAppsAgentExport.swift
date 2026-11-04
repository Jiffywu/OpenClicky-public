// Gives background agents (Codex CLI, Claude Code) the same connected apps the brain has.
//
// The exporter turns the registry into MCP server entries for the harness's config. Secrets never go into a
// config file or onto a command line: each one is named by an environment variable, and the harness puts the
// value in the job's environment (`environment` below). OAuth connectors get a freshly refreshed access token
// at export time, so export right before launching a job.
//
// Codex: `[mcp_servers.<key>]` with `url`, `bearer_token_env_var`, `env_http_headers`, or `command`, `args`,
// `env`, `env_vars` (field names checked against the Codex MCP docs on 2026-10-30).
// Claude Code: `--mcp-config` JSON `{"mcpServers": {...}}` whose values use `${VAR}` expansion.

import Foundation

/// One MCP server offered to an agent job.
public struct AgentConnectorServer: Sendable, Hashable {
    public enum Transport: Sendable, Hashable {
        /// `headerVariables`: header name → environment variable holding its value.
        case http(url: URL, bearerTokenVariable: String?, headerVariables: [String: String])
        /// `environmentVariables`: variables the server needs, forwarded from the job's environment.
        /// `path`: a PATH that finds the command's runtime (node, uv, …) even when launched from a GUI app.
        case stdio(command: String, arguments: [String], environmentVariables: [String], path: String)
    }

    /// Server name in the agent's config and tool names (`[a-z0-9_-]`).
    public var key: String
    public var displayName: String
    public var accountLabel: String?
    public var capability: String?
    public var transport: Transport
    public var startupTimeoutSeconds: Double
    public var toolTimeoutSeconds: Double
}

public struct ConnectedAppsAgentExport: Sendable {
    public var servers: [AgentConnectorServer]
    /// Secret values for the job's environment, keyed by variable name. Never write these to disk.
    public var environment: [String: String]
    public var obsidianVaultPath: String?
    /// Apps that could not be offered, with the reason (shown to the agent so it can tell the user).
    public var unavailable: [(name: String, reason: String)]

    public init(servers: [AgentConnectorServer] = [], environment: [String: String] = [:], obsidianVaultPath: String? = nil,
                unavailable: [(name: String, reason: String)] = []) {
        self.servers = servers
        self.environment = environment
        self.obsidianVaultPath = obsidianVaultPath
        self.unavailable = unavailable
    }

    public static let obsidianVariable = "OBSIDIAN_VAULT_PATH"

    /// Variables the job needs, values included (secrets and the vault path).
    public var jobEnvironment: [String: String] {
        var all = environment
        if let obsidianVaultPath { all[Self.obsidianVariable] = obsidianVaultPath }
        return all
    }

    // MARK: Codex

    /// `config.toml` text: one `[mcp_servers.<key>]` table per server.
    public func codexConfigTOML() -> String {
        var out: [String] = []
        for server in servers {
            let table = "mcp_servers.\(TOML.key(server.key))"
            out.append("[\(table)]")
            for (key, value) in codexEntries(server) { out.append("\(key) = \(value)") }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// The same settings as `-c key=value` overrides (`codex -c …` / app-server config overrides).
    public func codexConfigOverrides() -> [String] {
        servers.flatMap { server in
            codexEntries(server).map { "mcp_servers.\(TOML.key(server.key)).\($0.0)=\($0.1)" }
        }
    }

    private func codexEntries(_ server: AgentConnectorServer) -> [(String, String)] {
        var entries: [(String, String)] = []
        switch server.transport {
        case .http(let url, let bearer, let headers):
            entries.append(("url", TOML.string(url.absoluteString)))
            if let bearer { entries.append(("bearer_token_env_var", TOML.string(bearer))) }
            if !headers.isEmpty { entries.append(("env_http_headers", TOML.inlineTable(headers))) }
        case .stdio(let command, let arguments, let variables, let path):
            entries.append(("command", TOML.string(command)))
            entries.append(("args", TOML.array(arguments)))
            entries.append(("env", TOML.inlineTable(["PATH": path])))
            if !variables.isEmpty { entries.append(("env_vars", TOML.array(variables))) }
        }
        entries.append(("startup_timeout_sec", TOML.number(server.startupTimeoutSeconds)))
        entries.append(("tool_timeout_sec", TOML.number(server.toolTimeoutSeconds)))
        return entries
    }

    // MARK: Claude Code

    /// JSON for `claude --mcp-config`. Secrets appear only as `${VAR}` references.
    public func claudeCodeMCPConfig() -> String {
        var entries: [String: JSONValue] = [:]
        for server in servers {
            switch server.transport {
            case .http(let url, let bearer, let headers):
                var values: [String: JSONValue] = [:]
                if let bearer { values["Authorization"] = .string("Bearer ${\(bearer)}") }
                for (header, variable) in headers { values[header] = .string("${\(variable)}") }
                var entry: [String: JSONValue] = ["type": "http", "url": .string(url.absoluteString)]
                if !values.isEmpty { entry["headers"] = .object(values) }
                entries[server.key] = .object(entry)
            case .stdio(let command, let arguments, let variables, let path):
                var env: [String: JSONValue] = ["PATH": .string(path)]
                for variable in variables { env[variable] = .string("${\(variable)}") }
                entries[server.key] = ["type": "stdio", "command": .string(command), "args": .array(arguments.map { .string($0) }),
                                       "env": .object(env)]
            }
        }
        return JSONValue.object(["mcpServers": .object(entries)]).jsonString()
    }

    // MARK: Instructions

    /// The "Connected apps" section of a job's instructions.
    public func instructions() -> String {
        var lines = ["## Connected apps"]
        if servers.isEmpty {
            lines.append("No connected apps are offered to this job. If the task needs one, tell the user which app to connect in OpenClicky's Settings → Connected Apps.")
        } else {
            lines.append("These MCP servers are the user's own accounts:")
            for server in servers {
                var line = "- `\(server.key)`: \(server.displayName)"
                if let label = server.accountLabel { line += " (\(label) account)" }
                if let capability = server.capability { line += ". \(capability)" }
                lines.append(line)
            }
            lines.append("""
            - Tool lists change over time. Look through a server's current tools before you tell the user an app lacks a feature.
            - Before messaging other people, posting publicly, spending money, or deleting anything, confirm the exact action with the user first.
            - Never run sign-in, OAuth or auth CLI commands yourself. If an app says you're not authorized, tell the user to sign in again in OpenClicky's Settings → Connected Apps.
            """)
        }
        if !unavailable.isEmpty {
            lines.append("Not available right now: " + unavailable.map { "\($0.name) (\($0.reason))" }.joined(separator: "; ") + ".")
        }
        if let obsidianVaultPath {
            lines.append("""
            ## Obsidian notes
            The user's Obsidian vault is the folder \(obsidianVaultPath) (also in `$\(Self.obsidianVariable)`). Each note is a Markdown file, linked to others with [[wiki links]]; open, grep and edit the files directly. Get the user's go-ahead first for anything that removes, relocates or renames a note, and for edits that span many notes. Leave the `.obsidian` settings folder alone.
            """)
        }
        return lines.joined(separator: "\n")
    }
}

extension ConnectedAppsAgentExport: CustomStringConvertible {
    /// Safe to log: variable names only, never values.
    public var description: String {
        "ConnectedAppsAgentExport(servers: \(servers.map(\.key)), env: \(environment.keys.sorted()), obsidian: \(obsidianVaultPath ?? "none"), unavailable: \(unavailable.map(\.name)))"
    }
}

// MARK: - Exporter

public struct ConnectedAppsAgentExporter: Sendable {
    public var registry: ConnectorRegistry
    public var environment: ConnectorEnvironment
    public var toolTimeoutSeconds: Double
    public var startupTimeoutSeconds: Double

    public init(registry: ConnectorRegistry, environment: ConnectorEnvironment, toolTimeoutSeconds: Double = 900,
                startupTimeoutSeconds: Double = 30) {
        self.registry = registry
        self.environment = environment
        self.toolTimeoutSeconds = toolTimeoutSeconds
        self.startupTimeoutSeconds = startupTimeoutSeconds
    }

    /// `OPENCLICKY_APP_<KEY>_TOKEN`.
    public static func bearerVariable(_ key: String) -> String { "OPENCLICKY_APP_\(variablePart(key))_TOKEN" }
    /// `OPENCLICKY_APP_<KEY>_HEADER_<NAME>`.
    public static func headerVariable(_ key: String, _ header: String) -> String {
        "OPENCLICKY_APP_\(variablePart(key))_HEADER_\(variablePart(header))"
    }
    public static let composioKeyVariable = "OPENCLICKY_COMPOSIO_API_KEY"

    static func variablePart(_ text: String) -> String {
        String(text.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }

    /// Server keys: the connector id with only `[a-z0-9_-]`.
    static func serverKey(_ id: String) -> String {
        let key = String(id.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
        return key.isEmpty ? "app" : key
    }

    public func export() async -> ConnectedAppsAgentExport {
        var export = ConnectedAppsAgentExport()
        let credentials = environment.credentials
        func secret(_ name: String) -> String? {
            guard let value = try? credentials.secret(named: name), !value.isEmpty else { return nil }
            return value
        }

        for connector in registry.connectors where connector.enabled {
            let key = Self.serverKey(connector.id)
            do {
                var values: [String: String] = [:]
                let transport: AgentConnectorServer.Transport
                switch connector.transport {
                case .remote(let url):
                    var bearerVariable: String?
                    switch connector.auth {
                    case .none: break
                    case .bearer:
                        guard let token = secret(ConnectorSecretNames.bearer(connector.id)) else { throw ExportProblem("its token isn't saved") }
                        bearerVariable = Self.bearerVariable(key)
                        values[bearerVariable!] = token
                    case .oauth:
                        let session = OAuthSession(store: MCPOAuthStore(credentials: credentials, connectorID: connector.id), http: environment.http)
                        guard let token = try? await session.accessToken() else { throw ExportProblem("needs sign-in") }
                        bearerVariable = Self.bearerVariable(key)
                        values[bearerVariable!] = token
                    }
                    var headerVariables: [String: String] = [:]
                    for (header, credential) in connector.secretHeaders ?? [:] {
                        guard let value = secret(credential) else { throw ExportProblem("the \(header) value isn't saved") }
                        let variable = Self.headerVariable(key, header)
                        headerVariables[header] = variable
                        values[variable] = value
                    }
                    transport = .http(url: url, bearerTokenVariable: bearerVariable, headerVariables: headerVariables)
                case .stdio(let command, let arguments):
                    let path = MCPCommandResolver.searchPath(base: environment.processEnvironment["PATH"])
                    guard let executable = MCPCommandResolver.resolve(command, searchPath: path) else {
                        throw ExportProblem("\(command) isn't installed")
                    }
                    for (variable, credential) in connector.environment ?? [:] {
                        guard let value = secret(credential) else { throw ExportProblem("\(variable) isn't saved") }
                        values[variable] = value
                    }
                    transport = .stdio(command: executable.path, arguments: arguments,
                                       environmentVariables: values.keys.sorted(), path: path)
                }
                // Two local servers can't both own one variable with different values.
                if let clash = values.first(where: { export.environment[$0.key] != nil && export.environment[$0.key] != $0.value }) {
                    throw ExportProblem("\(clash.key) is already used by another app")
                }
                export.environment.merge(values) { _, new in new }
                export.servers.append(AgentConnectorServer(key: key, displayName: connector.name, accountLabel: connector.accountLabel,
                                                           capability: connector.capabilityDescription, transport: transport,
                                                           startupTimeoutSeconds: startupTimeoutSeconds, toolTimeoutSeconds: toolTimeoutSeconds))
            } catch let problem as ExportProblem {
                export.unavailable.append((connector.labelledName, problem.reason))
            } catch {
                export.unavailable.append((connector.labelledName, String(describing: error)))
            }
        }

        if let obsidian = registry.obsidian, obsidian.enabled {
            if let vault = try? ObsidianVault(path: obsidian.vaultPath) {
                export.obsidianVaultPath = vault.root.path
            } else {
                export.unavailable.append(("Obsidian", "the vault folder is missing"))
            }
        }

        if let composio = registry.composio, composio.enabled, registry.connector(id: ComposioClient.connectorID) == nil {
            if let key = secret(ComposioClient.credentialName) {
                let client = ComposioClient(apiKey: key, baseURL: environment.composioBaseURL, http: environment.http)
                do {
                    let session = try await environment.composioSessions.session(for: client, userID: composio.userID, toolkits: composio.toolkits)
                    var headers: [String: String] = [:]
                    if let header = client.mcpKeyHeaderName(for: session.mcpURL) {
                        headers[header] = Self.composioKeyVariable
                        export.environment[Self.composioKeyVariable] = key
                    }
                    export.servers.append(AgentConnectorServer(
                        key: ComposioClient.connectorID, displayName: "Composio", accountLabel: composio.userID,
                        capability: "Apps connected in the user's Composio account. Search its tools to find the right one for an app, then run it.",
                        transport: .http(url: session.mcpURL, bearerTokenVariable: nil, headerVariables: headers),
                        startupTimeoutSeconds: startupTimeoutSeconds, toolTimeoutSeconds: toolTimeoutSeconds))
                } catch {
                    export.unavailable.append(("Composio", "couldn't be reached right now"))
                }
            } else {
                export.unavailable.append(("Composio", "its API key isn't saved"))
            }
        }
        return export
    }

    private struct ExportProblem: Error {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }
}

// MARK: - TOML values

enum TOML {
    static func key(_ text: String) -> String {
        let bare = !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return bare ? text : string(text)
    }

    static func string(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func array(_ items: [String]) -> String { "[" + items.map(string).joined(separator: ", ") + "]" }

    static func inlineTable(_ values: [String: String]) -> String {
        "{ " + values.sorted { $0.key < $1.key }.map { "\(key($0.key)) = \(string($0.value))" }.joined(separator: ", ") + " }"
    }

    /// A TOML float (Codex reads its timeouts as seconds in floating point).
    static func number(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value)).0" : String(value)
    }
}
