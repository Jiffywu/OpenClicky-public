import AppKit
import OpenClickyKit
import SwiftUI

/// State behind Settings → Connected Apps: the saved connectors, their status, tests and browser sign-ins.
/// Edits are saved to connectors.json right away; secrets go to the Keychain.
@MainActor
@Observable
final class ConnectedAppsModel {
    private(set) var registry: ConnectorRegistry
    private(set) var apps: [ConnectedAppSummary] = []
    private(set) var testResults: [String: ConnectorTestResult] = [:]
    /// Apps with an operation in flight (test, sign-in).
    private(set) var busy: Set<String> = []
    /// Apps waiting for the user to finish signing in in the browser.
    private(set) var awaitingBrowser: Set<String> = []
    /// Vault folders found by `findObsidianVaults()`; nil until the user asks. Looking means listing ~/Documents and
    /// iCloud Drive, which macOS guards with a privacy prompt, so it never happens just because Settings opened.
    private(set) var discoveredVaults: [URL]?
    var message: String?

    /// Where connecting an app through Composio stands.
    enum ComposioFlow: Equatable {
        case idle
        case loading
        /// The sign-in page is open in the browser; waiting for the account to turn up.
        case waiting(toolkit: String)
        case failed(String)
    }

    /// The user's Composio accounts (all statuses), from the last refresh.
    private(set) var composioAccounts: [ComposioConnectedAccount] = []
    private(set) var composioFlow: ComposioFlow = .idle
    /// Accounts being disconnected.
    private(set) var disconnecting: Set<String> = []
    @ObservationIgnored private var composioTask: Task<Void, Never>?
    /// Talks to Composio (tests and renders use a fake transport).
    @ObservationIgnored var composioHTTP: any HTTPTransport = URLSessionTransport()
    @ObservationIgnored var composioBaseURL = ComposioClient.defaultBaseURL
    @ObservationIgnored var openInBrowser: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

    let credentials: any CredentialStore
    private let hub: ConnectedAppsHub
    private let registryURL: URL
    private var signInTasks: [String: Task<Void, Never>] = [:]

    init(credentials: any CredentialStore = KeychainCredentialStore(), registryURL: URL = ConnectorRegistry.defaultURL) {
        self.credentials = credentials
        self.registryURL = registryURL
        let loaded = (try? ConnectorRegistry.load(from: registryURL)) ?? ConnectorRegistry()
        registry = loaded
        // The app's one Composio session cache, so resetting Composio here also drops the sessions job launches and
        // the brain reuse.
        hub = ConnectedAppsHub(registry: loaded, environment: ConnectorEnvironment(credentials: credentials, composioSessions: .shared))
        refreshSummaries()
    }

    var availablePresets: [ConnectorPreset] {
        ConnectorPreset.all.filter { preset in !registry.connectors.contains { $0.preset == preset.id } }
    }

    func connector(_ id: String) -> ConnectorConfig? { registry.connector(id: id) }

    // MARK: Saving

    private func commit(_ change: (inout ConnectorRegistry) throws -> Void) {
        var updated = registry
        do {
            try change(&updated)
            try updated.save(to: registryURL)
            registry = updated
            message = nil
        } catch {
            message = String(describing: error)
        }
        refreshSummaries()
        let snapshot = registry
        Task { await hub.update(registry: snapshot) }
    }

    private func refreshSummaries() {
        apps = ConnectedAppsHub.summaries(of: registry, credentials: credentials)
    }

    // MARK: Adding

    func addPreset(_ preset: ConnectorPreset, token: String?) {
        commit { registry in
            let added = try registry.add(preset.connector)
            if added.auth == .bearer, let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                try credentials.setSecret(token, named: ConnectorSecretNames.bearer(added.id))
            }
        }
    }

    /// Adds a remote server, with optional secret header lines (`Header-Name: value`). Returns true when it was saved.
    @discardableResult
    func addRemote(name: String, url text: String, auth: ConnectorAuth, token: String, label: String, headerLines: String = "") -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ConnectorRegistry.isAcceptableRemoteURL(url) else {
            message = ConnectorRegistryError.invalidURL(URL(string: trimmed).map(ConnectorRegistry.redacted) ?? trimmed).description
            return false
        }
        if auth == .bearer, token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = "Paste the server's token, or choose another sign-in method."
            return false
        }
        var saved = false
        let draft = ConnectorDraft(name: name, transport: .remote(url), auth: auth, token: token, accountLabel: label, headerLines: headerLines)
        commit { registry in
            try draft.save(into: &registry, credentials: credentials)
            saved = true
        }
        return saved
    }

    /// Adds a local server from a command line such as `npx -y some-mcp-server`, with optional secret environment lines
    /// (`NAME=value`).
    @discardableResult
    func addCommand(name: String, commandLine: String, label: String, environmentLines: String = "") -> Bool {
        let words = Self.splitCommandLine(commandLine)
        guard let command = words.first else {
            message = "Type the command line that launches this MCP server, for example npx -y some-mcp-server."
            return false
        }
        var saved = false
        let draft = ConnectorDraft(name: name, transport: .stdio(command: command, arguments: Array(words.dropFirst())), accountLabel: label,
                                   environmentLines: environmentLines)
        commit { registry in
            try draft.save(into: &registry, credentials: credentials)
            saved = true
        }
        return saved
    }

    /// Adds or replaces secret headers (remote) or environment values (command) on a saved connector. Returns true
    /// when they were stored.
    @discardableResult
    func setSecretLines(_ id: String, _ text: String) -> Bool {
        guard let connector = registry.connector(id: id) else { return false }
        let kind: ConnectorSecretLines.Kind = connector.transport.remoteURL == nil ? .environment : .header
        var saved = false
        commit { registry in
            let lines = try ConnectorSecretLines.parse(text, kind: kind)
            guard !lines.isEmpty, let current = registry.connector(id: id) else { return }
            registry.update(try ConnectorSecretLines.apply(lines, kind: kind, to: current, credentials: credentials))
            saved = true
        }
        if saved { Task { await hub.reset(id) } }
        return saved
    }

    /// Forgets one secret header or environment value.
    func removeSecret(_ id: String, name: String) {
        guard let connector = registry.connector(id: id) else { return }
        let kind: ConnectorSecretLines.Kind = connector.transport.remoteURL == nil ? .environment : .header
        commit { registry in
            guard let current = registry.connector(id: id) else { return }
            registry.update(ConnectorSecretLines.remove(name, kind: kind, from: current, credentials: credentials))
        }
        Task { await hub.reset(id) }
    }

    func remove(_ id: String) {
        signInTasks[id]?.cancel()
        commit { registry in
            let removed = try registry.remove(id)
            for name in ConnectorSecretNames.all(for: removed) { try? credentials.removeSecret(named: name) }
        }
        testResults[id] = nil
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        commit { registry in
            if id == ObsidianVault.connectorID, registry.connector(id: id) == nil {
                registry.obsidian?.enabled = enabled
            } else if id == ComposioClient.connectorID, registry.connector(id: id) == nil {
                registry.composio?.enabled = enabled
            } else if var connector = registry.connector(id: id) {
                connector.enabled = enabled
                registry.update(connector)
            }
        }
    }

    func setAllowWrites(_ id: String, _ allow: Bool) {
        commit { registry in
            guard var connector = registry.connector(id: id) else { return }
            connector.allowWrites = allow ? true : nil
            registry.update(connector)
        }
    }

    func setToken(_ id: String, _ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commit { registry in
            try credentials.setSecret(trimmed, named: ConnectorSecretNames.bearer(id))
            if var connector = registry.connector(id: id), connector.auth != .bearer {
                connector.auth = .bearer
                registry.update(connector)
            }
        }
        Task { await hub.reset(id) }
    }

    // MARK: Testing and signing in

    func test(_ id: String) {
        busy.insert(id)
        Task {
            let result = await hub.test(id)
            testResults[id] = result
            busy.remove(id)
            // Save the derived capability line unless the user wrote one.
            if case .reachable(_, _, _, _, let capability?) = result, let connector = registry.connector(id: id),
               connector.capabilityDescription == nil {
                commit { registry in
                    var updated = connector
                    updated.capabilityDescription = capability
                    registry.update(updated)
                }
            }
        }
    }

    func signIn(_ id: String) {
        guard let connector = registry.connector(id: id), let url = connector.transport.remoteURL else { return }
        signInTasks[id]?.cancel()
        busy.insert(id)
        awaitingBrowser.insert(id)
        let store = MCPOAuthStore(credentials: credentials, connectorID: id)
        let flow = MCPOAuthFlow(store: store, openURL: { authorizationURL in
            await MainActor.run { _ = NSWorkspace.shared.open(authorizationURL) }
        }, preregisteredClientID: connector.oauthClientID)
        signInTasks[id] = Task {
            defer {
                busy.remove(id)
                awaitingBrowser.remove(id)
                signInTasks[id] = nil
            }
            do {
                try await flow.signIn(serverURL: url)
                if connector.auth != .oauth {
                    commit { registry in
                        // Re-read it: the user may have changed the connector while the browser was open.
                        guard var updated = registry.connector(id: id) else { return }
                        updated.auth = .oauth
                        registry.update(updated)
                    }
                } else {
                    refreshSummaries()
                }
                await hub.reset(id)
                message = "Signed in to \(connector.name)."
                test(id)
            } catch is CancellationError {
                message = nil
            } catch {
                message = String(describing: error)
            }
        }
    }

    func cancelSignIn(_ id: String) { signInTasks[id]?.cancel() }

    func signOut(_ id: String) {
        try? MCPOAuthStore(credentials: credentials, connectorID: id).clearTokens()
        testResults[id] = nil
        refreshSummaries()
        Task { await hub.reset(id) }
    }

    // MARK: Obsidian and Composio

    func chooseObsidianVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Vault"
        panel.message = "Choose the folder that holds your Obsidian notes."
        // The panel falls back to its usual folder when this one doesn't exist. Not checked here: even a lookup in
        // iCloud Drive can raise a privacy prompt, and the open panel itself needs no permission.
        panel.directoryURL = ObsidianVault.iCloudVaultsFolder()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setObsidianVault(url.path)
    }

    /// Looks for vaults in iCloud Drive's Obsidian folder, ~/Documents and ~/Obsidian. Only on request: macOS may ask
    /// the user to allow access to those folders.
    func findObsidianVaults() {
        discoveredVaults = ObsidianVault.discoverVaults()
    }

    func setObsidianVault(_ path: String) {
        commit { registry in
            let vault = try ObsidianVault(path: path)
            registry.obsidian = ObsidianSettings(vaultPath: vault.root.path)
        }
    }

    func removeObsidian() { commit { $0.obsidian = nil } }

    func saveComposio(userID: String, toolkits: String, key: String) {
        let user = userID.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else {
            message = "Enter the Composio user id your apps are connected under."
            return
        }
        commit { registry in
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty { try credentials.setSecret(trimmedKey, named: ComposioClient.credentialName) }
            let kits = toolkits.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0).lowercased() }
            registry.composio = ComposioSettings(userID: user, toolkits: kits)
        }
    }

    func removeComposio() {
        composioTask?.cancel()
        composioAccounts = []
        composioFlow = .idle
        commit { $0.composio = nil }
    }

    private var composioClient: ComposioClient? {
        guard registry.composio != nil, let key = try? credentials.secret(named: ComposioClient.credentialName), !key.isEmpty else { return nil }
        return ComposioClient(apiKey: key, baseURL: composioBaseURL, http: composioHTTP)
    }

    /// The browser sign-in of a Composio connection is under way.
    var isConnectingComposio: Bool {
        if case .waiting = composioFlow { return true }
        return false
    }

    /// Asks Composio which accounts the user has connected. Does nothing while a connection is under way: that task
    /// lists the accounts itself when it finishes, and cancelling it would leave the new account unwired.
    func refreshComposioAccounts() {
        guard !isConnectingComposio, let client = composioClient, let user = registry.composio?.userID else { return }
        composioTask?.cancel()
        composioFlow = .loading
        composioTask = Task {
            do {
                composioAccounts = try await client.connectedAccounts(userID: user).sorted { ($0.toolkit, $0.id) < ($1.toolkit, $1.id) }
                composioFlow = .idle
            } catch is CancellationError {
            } catch {
                composioFlow = .failed(String(describing: error))
            }
        }
    }

    /// Connects an app (a Composio toolkit slug such as "gmail"): opens Composio's sign-in page in the browser and
    /// waits until the account is active, then lists the accounts again.
    func connectComposio(toolkit raw: String) {
        let toolkit = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "")
        guard !toolkit.isEmpty else { return }
        guard let client = composioClient, let user = registry.composio?.userID else {
            message = "Save your Composio user id and API key first."
            return
        }
        composioTask?.cancel()
        composioFlow = .waiting(toolkit: toolkit)
        let open = openInBrowser
        composioTask = Task {
            do {
                let link = try await client.startConnection(userID: user, toolkit: toolkit)
                open(link.redirectURL)
                let account = try await client.waitForConnection(accountID: link.connectedAccountID)
                if account.isActive {
                    message = "Connected \(toolkit) in Composio."
                    composioFlow = .idle
                } else {
                    composioFlow = .failed("Composio says the \(toolkit) connection \(account.status.lowercased()).")
                }
                await ComposioToolkitDirectory.shared.forget()
                await hub.reset(ComposioClient.connectorID)
                composioAccounts = try await client.connectedAccounts(userID: user).sorted { ($0.toolkit, $0.id) < ($1.toolkit, $1.id) }
            } catch is CancellationError {
                composioFlow = .idle
            } catch {
                composioFlow = .failed(String(describing: error))
            }
        }
    }

    func cancelComposioConnect() {
        composioTask?.cancel()
        composioFlow = .idle
    }

    func disconnectComposio(_ accountID: String) {
        guard let client = composioClient else { return }
        disconnecting.insert(accountID)
        Task {
            defer { disconnecting.remove(accountID) }
            do {
                try await client.disconnect(accountID: accountID)
                composioAccounts.removeAll { $0.id == accountID }
                await ComposioToolkitDirectory.shared.forget()
                await hub.reset(ComposioClient.connectorID)
            } catch {
                message = String(describing: error)
            }
        }
    }

    /// Evidence renders: fixed accounts and flow state, with no call to Composio.
    func showComposioFixture(accounts: [ComposioConnectedAccount], flow: ComposioFlow) {
        composioAccounts = accounts
        composioFlow = flow
    }

    var hasComposioKey: Bool { (try? credentials.secret(named: ComposioClient.credentialName))?.isEmpty == false }

    // MARK: Helpers

    /// Splits a command line on spaces, keeping quoted parts together.
    static func splitCommandLine(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var hasWord = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasWord = true
            } else if character == " " || character == "\t" {
                if hasWord { words.append(current) }
                current = ""
                hasWord = false
            } else {
                current.append(character)
                hasWord = true
            }
        }
        if hasWord { words.append(current) }
        return words
    }
}
