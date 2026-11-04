import Foundation

/// The Codex settings OpenClicky generates for a job, written either as `config.toml` in OpenClicky's own
/// `CODEX_HOME` or as `-c key=value` overrides when Codex runs on the user's own home (its ChatGPT login).
///
/// It never holds a secret. A bring-your-own-key provider names the environment variable Codex reads the key
/// from (`env_key`); MCP servers name the variable holding their bearer token (`bearer_token_env_var`).
public struct CodexConfig: Sendable, Equatable {
    /// A custom `model_providers` entry built from the agent slot's provider.
    public struct Provider: Sendable, Equatable {
        public var id: String
        public var name: String
        public var baseURL: String
        /// Name of the environment variable holding the key; nil for keyless local servers.
        public var envKey: String?
        public var headers: [String: String]

        public init(id: String = "openclicky", name: String, baseURL: String, envKey: String?, headers: [String: String] = [:]) {
            self.id = id
            self.name = name
            self.baseURL = baseURL
            self.envKey = envKey
            self.headers = headers
        }
    }

    public var model: String?
    public var reasoningEffort: String?
    public var provider: Provider?
    public var approvalPolicy: String
    public var sandboxMode: String
    public var networkAccess: Bool
    public var mcpServers: [AgentMCPServer]
    /// SKILL.md files of the skills OpenClicky installed, each enabled with a `skills.config` entry (Codex 0.165.0
    /// matches a path selector against the SKILL.md file, not its folder). Left out of `-c` overrides, where the
    /// array would replace the user's own `skills.config` list.
    public var skillFiles: [String] = []
    /// Folders Codex treats as trusted projects (the job roots), so it loads their AGENTS.md without asking.
    public var trustedProjects: [String]
    /// Codex features a job runs without (`features.<name> = false`).
    public var disabledFeatures: [String]
    /// MCP servers from the user's own Codex config to switch off for the job (`mcp_servers.<name>.enabled = false`).
    public var disabledServers: [String]
    /// Environment variables Codex needs itself (the key's `env_key`, MCP bearer tokens) but must not pass on to the
    /// commands the agent runs. Codex hands KEY/TOKEN variables to those commands by default
    /// (`shell_environment_policy.ignore_default_excludes` is true), where a prompt-injected command could read
    /// them. Written as `shell_environment_policy.filters.<VAR> = "exclude"` in OpenClicky's own home only: on the
    /// user's home a `filters` override would switch off their own legacy `exclude` list for the job (checked
    /// against codex-cli 0.165.0), and runs there carry no OpenClicky key.
    public var hiddenVariables: [String]
    /// Context tokens at which Codex compacts the thread (`model_auto_compact_token_limit`); nil keeps its default.
    public var autoCompactTokenLimit: Int?

    /// Features that would bring the user's own Codex setup into a job: installed plugins and their MCP servers,
    /// ChatGPT connectors, Codex's memory of the user, user hooks, and screen control. Unknown names are ignored by
    /// Codex, so older and newer versions both accept the list.
    public static let isolatedFeatures = ["plugins", "apps", "memories", "hooks", "computer_use", "browser_use", "in_app_browser"]

    public init(model: String?, reasoningEffort: String? = nil, provider: Provider?, approvalMode: AgentApprovalMode,
                mcpServers: [AgentMCPServer] = [], trustedProjects: [String] = [],
                disabledFeatures: [String] = CodexConfig.isolatedFeatures, disabledServers: [String] = [],
                hiddenVariables: [String] = [], autoCompactTokenLimit: Int? = nil) {
        self.autoCompactTokenLimit = autoCompactTokenLimit
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.provider = provider
        switch approvalMode {
        case .ask:
            approvalPolicy = "on-request"
            sandboxMode = "workspace-write"
        case .fullAccess:
            approvalPolicy = "never"
            sandboxMode = "danger-full-access"
        }
        networkAccess = true
        self.mcpServers = mcpServers
        self.trustedProjects = trustedProjects
        self.disabledFeatures = disabledFeatures
        self.disabledServers = disabledServers
        self.hiddenVariables = hiddenVariables
    }

    /// Key/value pairs in file order: dotted keys and TOML values.
    public func entries() -> [(key: String, value: TOMLValue)] {
        var entries: [(String, TOMLValue)] = []
        if let model { entries.append(("model", .string(model))) }
        if let reasoningEffort { entries.append(("model_reasoning_effort", .string(reasoningEffort))) }
        if let autoCompactTokenLimit, autoCompactTokenLimit > 0 {
            entries.append(("model_auto_compact_token_limit", .number(Double(autoCompactTokenLimit))))
        }
        if let provider { entries.append(("model_provider", .string(provider.id))) }
        entries.append(("approval_policy", .string(approvalPolicy)))
        entries.append(("sandbox_mode", .string(sandboxMode)))
        entries.append(("analytics.enabled", .bool(false)))
        // The user's own notify program (run after every turn) has no business with background jobs.
        entries.append(("notify", .array([])))
        if sandboxMode == "workspace-write" {
            entries.append(("sandbox_workspace_write.network_access", .bool(networkAccess)))
        }
        for feature in disabledFeatures { entries.append(("features.\(TOMLValue.key(feature))", .bool(false))) }
        if let provider {
            let base = "model_providers.\(TOMLValue.key(provider.id))"
            entries.append(("\(base).name", .string(provider.name)))
            entries.append(("\(base).base_url", .string(provider.baseURL)))
            if let envKey = provider.envKey { entries.append(("\(base).env_key", .string(envKey))) }
            entries.append(("\(base).wire_api", .string("responses")))
            if !provider.headers.isEmpty {
                entries.append(("\(base).http_headers", .table(provider.headers.mapValues { .string($0) })))
            }
        }
        for server in mcpServers {
            let base = "mcp_servers.\(TOMLValue.key(server.name))"
            for (key, value) in Self.settings(of: server) { entries.append(("\(base).\(key)", value)) }
        }
        let ours = Set(mcpServers.map(\.name))
        for name in disabledServers where !ours.contains(name) {
            entries.append(("mcp_servers.\(TOMLValue.key(name)).enabled", .bool(false)))
        }
        for name in hiddenVariables {
            entries.append(("shell_environment_policy.filters.\(TOMLValue.key(name))", .string("exclude")))
        }
        for project in trustedProjects {
            entries.append(("projects.\(TOMLValue.key(project)).trust_level", .string("trusted")))
        }
        if !skillFiles.isEmpty {
            entries.append(("skills.config", .array(skillFiles.map { .table(["path": .string($0), "enabled": .bool(true)]) })))
        }
        return entries
    }

    /// One MCP server's `mcp_servers.<name>` keys, in file order.
    static func settings(of server: AgentMCPServer) -> [(key: String, value: TOMLValue)] {
        var settings: [(String, TOMLValue)] = []
        switch server.transport {
        case .http(let url):
            settings.append(("url", .string(url.absoluteString)))
            if server.bearerToken != nil { settings.append(("bearer_token_env_var", .string(server.tokenEnvironmentVariable))) }
            if !server.secretHeaders.isEmpty {
                settings.append(("env_http_headers", .table(server.secretHeaders.mapValues { .string($0) })))
            }
        case .stdio(let command, let arguments):
            settings.append(("command", .string(command)))
            settings.append(("args", .array(arguments.map { .string($0) })))
            if !server.environment.isEmpty { settings.append(("env", .table(server.environment.mapValues { .string($0) }))) }
            if !server.forwardedVariables.isEmpty { settings.append(("env_vars", .array(server.forwardedVariables.sorted().map { .string($0) }))) }
        }
        settings.append(("startup_timeout_sec", .number(server.startupTimeout)))
        settings.append(("tool_timeout_sec", .number(server.toolTimeout)))
        return settings
    }

    /// `config.toml` text: top-level keys first, then one table per dotted prefix.
    public func renderTOML() -> String {
        var lines = [
            "# Written by OpenClicky for its background agents. Regenerated before every launch.",
            "# Holds no secrets: keys and tokens reach Codex only through the environment variables named here.",
            "",
        ]
        var tables: [(String, [(String, TOMLValue)])] = []
        for (key, value) in entries() {
            let parts = TOMLValue.splitKey(key)
            if parts.count == 1 {
                lines.append("\(parts[0]) = \(value.rendered)")
                continue
            }
            let table = parts.dropLast().joined(separator: ".")
            if let index = tables.firstIndex(where: { $0.0 == table }) {
                tables[index].1.append((parts.last!, value))
            } else {
                tables.append((table, [(parts.last!, value)]))
            }
        }
        for (table, values) in tables {
            lines.append("")
            lines.append("[\(table)]")
            for (key, value) in values { lines.append("\(key) = \(value.rendered)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The same settings as `-c key=value` arguments, for runs on the user's own Codex home. Project trust is left
    /// out: its key is a folder path, and the job's thread names its folder, approval policy and sandbox itself.
    /// Environment filters are left out too (see `hiddenVariables`).
    ///
    /// Codex's `-c` parser splits a key at every dot and doesn't read quoted segments (codex-cli 0.165.0), so a user
    /// server named "my.server" can't be reached as `mcp_servers."my.server".enabled`: Codex then fails to load its
    /// config and the job never starts. Every MCP server setting therefore goes in one inline table,
    /// `mcp_servers={ "my.server" = { enabled = false }, … }`, which merges with the user's file. It comes first
    /// because it replaces whatever earlier `-c` arguments put under `mcp_servers`.
    public func overrideArguments() -> [String] {
        var servers: [String: TOMLValue] = [:]
        for server in mcpServers {
            servers[server.name] = .table(Dictionary(Self.settings(of: server).map { ($0.key, $0.value) }, uniquingKeysWith: { $1 }))
        }
        for name in disabledServers where servers[name] == nil { servers[name] = .table(["enabled": .bool(false)]) }
        let skipped = ["mcp_servers.", "projects.", "shell_environment_policy.", "skills."]
        let rest = entries().filter { entry in !skipped.contains { entry.key.hasPrefix($0) } }
        return (servers.isEmpty ? [] : ["-c", "mcp_servers=\(TOMLValue.table(servers).rendered)"])
            + rest.flatMap { ["-c", "\($0.key)=\($0.value.rendered)"] }
    }
}

/// The few TOML values OpenClicky writes.
public indirect enum TOMLValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var rendered: String {
        switch self {
        case .string(let text): Self.quote(text)
        case .bool(let flag): flag ? "true" : "false"
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .array(let items): "[" + items.map(\.rendered).joined(separator: ", ") + "]"
        case .table(let values): "{ " + values.sorted { $0.key < $1.key }.map { "\(key($0.key)) = \($0.value.rendered)" }.joined(separator: ", ") + " }"
        }
    }

    private func key(_ name: String) -> String { Self.key(name) }

    /// A bare key when possible, else a quoted one.
    public static func key(_ name: String) -> String {
        let bare = !name.isEmpty && name.unicodeScalars.allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "_" || $0 == "-"
        }
        return bare ? name : quote(name)
    }

    public static func quote(_ text: String) -> String {
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

    /// Splits a dotted key, keeping quoted segments (which may contain dots) whole.
    static func splitKey(_ key: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in key {
            if inQuotes {
                current.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inQuotes = false }
            } else if character == "\"" {
                inQuotes = true
                current.append(character)
            } else if character == "." {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }
}
