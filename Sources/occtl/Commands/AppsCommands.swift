import Foundation
import OpenClickyKit

/// `occtl apps …`: connected apps (MCP connectors, Obsidian, Composio).
enum AppsCommands {
    static let usageText = """
    Usage:
      occtl apps list                                   connected apps and their status
      occtl apps presets                                official servers you can add by name
      occtl apps add <name> <url> [--bearer|--oauth|--none] [--label L] [--client-id ID]
      occtl apps add <preset> [--label L]               add GitHub, Notion or Linear (see presets)
      occtl apps add-command <name> <command> [args…]   a local server started on this Mac (stdio)
      occtl apps env <name> <VARIABLE>                  store a secret environment value for a local server (reads stdin)
      occtl apps header <name> <Header-Name>            store a secret request header for a remote server (reads stdin)
      occtl apps token <name>                           store or replace a bearer token (reads stdin)
      occtl apps signin <name>                          sign in with your browser (OAuth)
      occtl apps signout <name>
      occtl apps test <name>                            connect, list tools, save a capability line
      occtl apps tools <name>                           tools with [read]/[write]
      occtl apps call <name> <tool> [json] [--allow-write]
      occtl apps read "<request>" [--app <name>]        what the brain's read_connected_apps would return
      occtl apps enable|disable <name>
      occtl apps rm <name>
      occtl apps obsidian <vault-folder>|off
      occtl apps composio <user-id> [toolkit…]|off      uses your Composio key (occtl key set composio)
      occtl apps composio-accounts [user-id] [--active] the accounts Composio has connected for the user (read-only)
      occtl apps export codex|claude|instructions|env   what background agents get (env prints names only)
    Connectors are saved in \(ConnectorRegistry.defaultURL.path); secrets stay in the Keychain.
    """

    static let command = OcctlCommand(name: "apps", usage: "apps <list|add|test|tools|…>   connected apps (MCP connectors, Obsidian, Composio)") { args in
        guard let sub = args.first else { fail(usageText) }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list": try list()
        case "presets": presets()
        case "add": try add(rest)
        case "add-command": try addCommand(rest)
        case "env": try storeEnvironment(rest)
        case "header": try storeHeader(rest)
        case "token": try storeToken(rest)
        case "signin", "sign-in": try await signIn(rest)
        case "signout", "sign-out": try signOut(rest)
        case "test": try await test(rest)
        case "tools": try await tools(rest)
        case "call": try await call(rest)
        case "read": try await read(rest)
        case "enable", "disable": try setEnabled(rest, sub == "enable")
        case "rm", "remove": try remove(rest)
        case "obsidian": try obsidian(rest)
        case "composio": try composio(rest)
        case "composio-accounts": try await composioAccounts(rest)
        case "export": try await export(rest)
        default: fail(usageText)
        }
    }

    static var credentials: any CredentialStore { KeychainCredentialStore() }

    static func load() throws -> ConnectorRegistry { try ConnectorRegistry.load() }

    static func hub(_ registry: ConnectorRegistry) -> ConnectedAppsHub {
        ConnectedAppsHub(registry: registry, environment: ConnectorEnvironment(credentials: credentials))
    }

    /// A connector id, or Obsidian/Composio by name.
    static func appID(_ name: String, in registry: ConnectorRegistry) -> String {
        if let connector = registry.connector(name) { return connector.id }
        let lowered = name.lowercased()
        if lowered == ObsidianVault.connectorID || lowered == ComposioClient.connectorID { return lowered }
        fail(ConnectorRegistryError.notFound(name).description)
    }

    static func connector(_ args: [String], _ registry: ConnectorRegistry, usage: String) -> ConnectorConfig {
        guard let name = args.first else { fail("Usage: occtl apps \(usage)") }
        guard let connector = registry.connector(name) else { fail(ConnectorRegistryError.notFound(name).description) }
        return connector
    }

    /// `--flag value` from the arguments, removing both.
    static func option(_ flag: String, in args: inout [String]) -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        guard index + 1 < args.count else { fail("\(flag) needs a value.") }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }

    static func flag(_ flag: String, in args: inout [String]) -> Bool {
        guard let index = args.firstIndex(of: flag) else { return false }
        args.remove(at: index)
        return true
    }

    /// Runs a connector operation, turning failures into a readable line instead of a raw error dump.
    static func reported<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            fail(ConnectedAppsHub.classify(error).summary)
        }
    }

    // MARK: Listing

    static func list() throws {
        let apps = ConnectedAppsHub.summaries(of: try load(), credentials: credentials)
        guard !apps.isEmpty else {
            print("No connected apps yet. Try: occtl apps presets, occtl apps add <name> <url>, occtl apps obsidian <folder>")
            return
        }
        for app in apps {
            print("\(app.id)  \(app.labelledName)  [\(app.kind.rawValue), \(app.status.rawValue)]\(app.allowsWrites ? "  writes allowed" : "")")
            print("    \(app.location)")
            if let capability = app.capability { print("    \(capability)") }
        }
    }

    static func presets() {
        for preset in ConnectorPreset.all {
            print("\(preset.id)  \(preset.name)  \(preset.url.absoluteString)  [\(preset.auth.rawValue)]")
            print("    \(preset.note) Docs: \(preset.docsURL.absoluteString)")
        }
        print("Add one with: occtl apps add <preset>. Any other MCP server: occtl apps add <name> <url>")
    }

    // MARK: Adding and secrets

    static func add(_ input: [String]) throws {
        var args = input
        let label = option("--label", in: &args)
        let clientID = option("--client-id", in: &args)
        var auth: ConnectorAuth?
        if flag("--bearer", in: &args) { auth = .bearer }
        if flag("--oauth", in: &args) { auth = .oauth }
        if flag("--none", in: &args) { auth = ConnectorAuth.none }
        guard let name = args.first else { fail(usageText) }
        var registry = try load()
        var config: ConnectorConfig
        if args.count == 1 {
            guard let preset = ConnectorPreset.named(name) else {
                fail("\"\(name)\" isn't a preset. Give a URL too: occtl apps add <name> <url>. Presets: \(ConnectorPreset.all.map(\.id).joined(separator: ", "))")
            }
            config = preset.connector
            if let auth { config.auth = auth }
        } else {
            guard let url = URL(string: args[1]), url.scheme != nil else { fail(ConnectorRegistryError.invalidURL(args[1]).description) }
            config = ConnectorConfig(id: "", name: name, transport: .remote(url), auth: auth ?? .none)
            if let preset = ConnectorPreset.all.first(where: { $0.url == url }) {
                config.preset = preset.id
                if auth == nil { config.auth = preset.auth }
            }
        }
        config.accountLabel = label
        config.oauthClientID = clientID
        if registry.connectors.contains(where: { $0.id == config.id }) { config.id = "" } // let add() pick a free id
        let added = try registry.add(config)
        if added.auth == .bearer {
            print("Paste the bearer token for \(added.name) (API key or personal access token).")
            if let preset = ConnectorPreset.named(added.preset ?? ""), let help = preset.tokenHelpURL { print("Create one at \(help.absoluteString)") }
            let token = CoreCommands.readSecretFromStdin()
            guard !token.isEmpty else { fail("No token given; nothing saved.") }
            try credentials.setSecret(token, named: ConnectorSecretNames.bearer(added.id))
        }
        try registry.save()
        print("Added \(added.labelledName) as \"\(added.id)\" (\(added.transport.summary), auth: \(added.auth.rawValue)).")
        switch added.auth {
        case .oauth: print("Next: occtl apps signin \(added.id)")
        default: print("Next: occtl apps test \(added.id)")
        }
    }

    static func addCommand(_ input: [String]) throws {
        var args = input
        let label = option("--label", in: &args)
        guard args.count >= 2 else { fail("Usage: occtl apps add-command <name> <command> [args…]") }
        var registry = try load()
        let added = try registry.add(ConnectorConfig(id: "", name: args[0], transport: .stdio(command: args[1], arguments: Array(args.dropFirst(2))),
                                                     accountLabel: label))
        try registry.save()
        print("Added \(added.labelledName) as \"\(added.id)\" (\(added.transport.summary)).")
        print("Secrets it needs from the environment: occtl apps env \(added.id) <VARIABLE>. Then: occtl apps test \(added.id)")
    }

    static func storeEnvironment(_ args: [String]) throws {
        guard args.count == 2 else { fail("Usage: occtl apps env <name> <VARIABLE>") }
        var registry = try load()
        var config = connector(args, registry, usage: "env <name> <VARIABLE>")
        guard config.transport.remoteURL == nil else { fail("\(config.name) is a remote server; use occtl apps header or token.") }
        let variable = args[1]
        guard variable.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }), !variable.isEmpty else {
            fail("Environment variable names use A–Z, 0–9 and _.")
        }
        let value = CoreCommands.readSecretFromStdin()
        guard !value.isEmpty else { fail("Empty value; nothing saved.") }
        let credential = ConnectorSecretNames.environment(config.id, variable)
        try credentials.setSecret(value, named: credential)
        config.environment = (config.environment ?? [:]).merging([variable: credential]) { _, new in new }
        registry.update(config)
        try registry.save()
        print("Stored \(variable) for \(config.name) in the Keychain (\(credential)).")
    }

    static func storeHeader(_ args: [String]) throws {
        guard args.count == 2 else { fail("Usage: occtl apps header <name> <Header-Name>") }
        var registry = try load()
        var config = connector(args, registry, usage: "header <name> <Header-Name>")
        guard config.transport.remoteURL != nil else { fail("\(config.name) is a local command; use occtl apps env.") }
        let header = args[1]
        guard header.lowercased() != "authorization" else { fail("For Authorization use: occtl apps token \(config.id)") }
        let value = CoreCommands.readSecretFromStdin()
        guard !value.isEmpty else { fail("Empty value; nothing saved.") }
        let credential = ConnectorSecretNames.header(config.id, header)
        try credentials.setSecret(value, named: credential)
        config.secretHeaders = (config.secretHeaders ?? [:]).merging([header: credential]) { _, new in new }
        registry.update(config)
        try registry.save()
        print("Stored the \(header) header for \(config.name) in the Keychain.")
    }

    static func storeToken(_ args: [String]) throws {
        var registry = try load()
        var config = connector(args, registry, usage: "token <name>")
        let token = CoreCommands.readSecretFromStdin()
        guard !token.isEmpty else { fail("Empty token; nothing saved.") }
        try credentials.setSecret(token, named: ConnectorSecretNames.bearer(config.id))
        config.auth = .bearer
        registry.update(config)
        try registry.save()
        print("Stored a bearer token for \(config.name).")
    }

    // MARK: Sign-in

    static func signIn(_ args: [String]) async throws {
        var registry = try load()
        var config = connector(args, registry, usage: "signin <name>")
        guard let url = config.transport.remoteURL else { fail("\(config.name) runs on this Mac; it has no browser sign-in.") }
        let environment = ConnectorEnvironment(credentials: credentials)
        let displayName = config.name
        let flow = MCPOAuthFlow(store: ConnectorFactory(environment: environment).oauthStore(for: config), openURL: { authorizationURL in
            print("Opening your browser to sign in to \(displayName)…\nIf it doesn't open, visit:\n\(authorizationURL.absoluteString)")
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [authorizationURL.absoluteString]
            try? open.run()
        }, preregisteredClientID: config.oauthClientID)
        let tokens = try await flow.signIn(serverURL: url)
        if config.auth != .oauth {
            config.auth = .oauth
            registry.update(config)
            try registry.save()
        }
        print("Signed in to \(config.name)\(tokens.scope.map { " (scopes: \($0))" } ?? ""). Next: occtl apps test \(config.id)")
    }

    static func signOut(_ args: [String]) throws {
        let config = connector(args, try load(), usage: "signout <name>")
        try MCPOAuthStore(credentials: credentials, connectorID: config.id).clearTokens()
        print("Signed out of \(config.name).")
    }

    // MARK: Using

    static func test(_ args: [String]) async throws {
        guard let name = args.first else { fail("Usage: occtl apps test <name>") }
        var registry = try load()
        let id = appID(name, in: registry)
        let hub = hub(registry)
        let result = await hub.test(id)
        await hub.shutdown()
        print(result.summary)
        if case .reachable(_, _, _, _, let capability?) = result, var config = registry.connector(id: id), config.capabilityDescription == nil {
            config.capabilityDescription = capability
            registry.update(config)
            try registry.save()
            print("Capability: \(capability)")
        }
        if !result.isReachable { exit(1) }
    }

    static func tools(_ args: [String]) async throws {
        guard let name = args.first else { fail("Usage: occtl apps tools <name>") }
        let registry = try load()
        let hub = hub(registry)
        let id = appID(name, in: registry)
        let tools = try await reported { try await hub.tools(for: id) }
        await hub.shutdown()
        for tool in tools {
            let access = ToolSafety.isArgumentGated(tool, appID: id) ? "read*" : ToolSafety.access(of: tool).rawValue
            print("[\(access)] \(tool.name)\(tool.title.map { " (\($0))" } ?? "")")
            if let description = tool.description?.split(separator: "\n").first { print("    \(description.prefix(160))") }
        }
        print("\(tools.count) tool\(tools.count == 1 ? "" : "s").\(tools.contains(where: { ToolSafety.isArgumentGated($0, appID: id) }) ? " read* = read-only only when every action it runs reads." : "")")
    }

    static func call(_ input: [String]) async throws {
        var args = input
        let allowWrite = flag("--allow-write", in: &args)
        guard args.count >= 2 else { fail("Usage: occtl apps call <name> <tool> [json] [--allow-write]") }
        let registry = try load()
        let id = appID(args[0], in: registry)
        let arguments = try args.count > 2 ? JSONValue.parse(args[2]) : [:]
        let hub = hub(registry)
        let tools = try await reported { try await hub.tools(for: id) }
        guard let tool = tools.first(where: { $0.name == args[1] }) else { fail("No tool \(args[1]). See: occtl apps tools \(args[0])") }
        if ToolSafety.access(ofCall: tool, arguments: arguments, appID: id) == .write, !allowWrite {
            fail("\(tool.name) may change something. Add --allow-write to run it anyway.")
        }
        let result = try await reported { try await hub.call(appID: id, tool: tool.name, arguments: arguments) }
        await hub.shutdown()
        print(result.text)
        if result.isError { exit(1) }
    }

    static func read(_ input: [String]) async throws {
        var args = input
        let app = option("--app", in: &args)
        guard let request = args.first else { fail("Usage: occtl apps read \"<request>\" [--app <name>]") }
        let hub = hub(try load())
        let outcome = await ReadConnectedApps(hub: hub).run(request: request, app: app)
        await hub.shutdown()
        print(outcome.text)
        print("[\(outcome.status); calls: \(outcome.calls.map { "\($0.appID).\($0.tool)\($0.succeeded ? "" : " (failed)")" }.joined(separator: ", "))]")
    }

    static func setEnabled(_ args: [String], _ enabled: Bool) throws {
        guard let name = args.first else { fail("Usage: occtl apps enable|disable <name>") }
        var registry = try load()
        switch appID(name, in: registry) {
        case ObsidianVault.connectorID where registry.connector(id: ObsidianVault.connectorID) == nil:
            guard registry.obsidian != nil else { fail("Obsidian isn't set up. occtl apps obsidian <folder>") }
            registry.obsidian?.enabled = enabled
        case ComposioClient.connectorID where registry.connector(id: ComposioClient.connectorID) == nil:
            guard registry.composio != nil else { fail("Composio isn't set up. occtl apps composio <user-id>") }
            registry.composio?.enabled = enabled
        case let id:
            var config = registry.connector(id: id)!
            config.enabled = enabled
            registry.update(config)
        }
        try registry.save()
        print("\(enabled ? "Enabled" : "Disabled") \(name).")
    }

    static func remove(_ args: [String]) throws {
        guard let name = args.first else { fail("Usage: occtl apps rm <name>") }
        var registry = try load()
        let removed = try registry.remove(name)
        for credential in ConnectorSecretNames.all(for: removed) { try? credentials.removeSecret(named: credential) }
        try registry.save()
        print("Removed \(removed.labelledName) and its Keychain items.")
    }

    static func obsidian(_ args: [String]) throws {
        guard let path = args.first else {
            let found = ObsidianVault.discoverVaults()
            fail("Usage: occtl apps obsidian <vault-folder>|off\(found.isEmpty ? "" : "\nVaults found:\n" + found.map { "  \($0.path)" }.joined(separator: "\n"))")
        }
        var registry = try load()
        if path == "off" {
            registry.obsidian = nil
            try registry.save()
            print("Obsidian removed.")
            return
        }
        let vault = try ObsidianVault(path: path)
        registry.obsidian = ObsidianSettings(vaultPath: vault.root.path)
        try registry.save()
        let count = (try? vault.notes().count) ?? 0
        print("Obsidian vault set to \(vault.root.path) (\(count) note\(count == 1 ? "" : "s")\(ObsidianVault.looksLikeVault(vault.root) ? "" : "; no .obsidian folder, used as a plain Markdown folder")).")
    }

    static func composio(_ args: [String]) throws {
        guard let user = args.first else { fail("Usage: occtl apps composio <user-id> [toolkit…]|off") }
        var registry = try load()
        if user == "off" {
            registry.composio = nil
            try registry.save()
            print("Composio removed.")
            return
        }
        registry.composio = ComposioSettings(userID: user, toolkits: Array(args.dropFirst()))
        try registry.save()
        let hasKey = (try? credentials.secret(named: ComposioClient.credentialName))?.isEmpty == false
        print("Composio set for user \(user).\(hasKey ? " Next: occtl apps test composio" : " Add your key: occtl key set \(ComposioClient.credentialName)")")
    }

    /// Asks Composio which accounts the user has connected (the list Settings → Connected apps shows). Read-only.
    static func composioAccounts(_ args: [String]) async throws {
        let activeOnly = args.contains("--active")
        let named = args.first { !$0.hasPrefix("--") }
        guard let user = named ?? (try? load())?.composio?.userID else {
            fail("Usage: occtl apps composio-accounts [user-id] [--active] (or set one with occtl apps composio <user-id>)")
        }
        guard let key = try? credentials.secret(named: ComposioClient.credentialName), !key.isEmpty else {
            fail("No Composio key. occtl key set \(ComposioClient.credentialName)")
        }
        let client = ComposioClient(apiKey: key)
        let accounts = try await client.connectedAccounts(userID: user, statuses: activeOnly ? ["ACTIVE"] : nil)
        print("Composio accounts for \(user): \(accounts.count)")
        for account in accounts {
            print("  \(account.toolkit)  \(account.status)  \(account.alias ?? account.id)")
        }
        let active = Array(Set(accounts.filter(\.isActive).map { $0.toolkit.lowercased() })).sorted()
        print("Skills follow: \(active.isEmpty ? "no Composio toolkit" : active.joined(separator: ", "))")
    }

    static func export(_ args: [String]) async throws {
        let format = args.first ?? "codex"
        let export = await ConnectedAppsAgentExporter(registry: try load(), environment: ConnectorEnvironment(credentials: credentials)).export()
        switch format {
        case "codex": print(export.codexConfigTOML())
        case "claude": print(export.claudeCodeMCPConfig())
        case "instructions": print(export.instructions())
        case "env": export.jobEnvironment.keys.sorted().forEach { print($0) }
        default: fail("Usage: occtl apps export codex|claude|instructions|env")
        }
    }
}
