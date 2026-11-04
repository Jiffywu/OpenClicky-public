import OpenClickyKit
import SwiftUI

/// Settings → Connected Apps: add MCP connectors (official presets, any URL, or a command on this Mac), sign in
/// with the browser, test, turn off or remove them; pick an Obsidian vault; optionally use Composio with your own key.
/// Add it to the settings TabView with:
/// `ConnectedAppsSettings().tabItem { Label("Connected Apps", systemImage: "puzzlepiece.extension") }`
struct ConnectedAppsSettings: View {
    @ViewState private var model: ConnectedAppsModel

    init(model: ConnectedAppsModel? = nil) {
        _model = ViewState(wrappedValue: model ?? ConnectedAppsModel())
    }

    var body: some View {
        Form {
            if let message = model.message {
                Section {
                    Label(message, systemImage: "info.circle").font(.callout)
                }
            }
            Section {
                if model.apps.isEmpty {
                    Text("No apps yet. Add one below. Connected apps let the buddy look things up for you, and background jobs use the same apps.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.apps) { app in
                    ConnectedAppRow(app: app, model: model)
                }
            } header: {
                Text("Connected apps")
            } footer: {
                Text("The buddy only reads from these apps. Sending, creating or changing things happens in background jobs, which ask first.")
            }
            if !model.availablePresets.isEmpty {
                Section("Add an official server") {
                    ForEach(model.availablePresets) { preset in PresetRow(preset: preset, model: model) }
                }
            }
            AddRemoteSection(model: model)
            AddCommandSection(model: model)
            ObsidianSection(model: model)
            ComposioSection(model: model)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Rows

private struct ConnectedAppRow: View {
    let app: ConnectedAppSummary
    let model: ConnectedAppsModel
    @ViewState private var tokenDraft = ""
    @ViewState private var editingToken = false
    @ViewState private var secretsDraft = ""
    @ViewState private var editingSecrets = false

    private var connector: ConnectorConfig? { model.connector(app.id) }
    private var isBusy: Bool { model.busy.contains(app.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(app.labelledName).font(.headline)
                StatusBadge(status: app.status)
                Spacer()
                Toggle("On", isOn: Binding(get: { app.status != .disabled }, set: { model.setEnabled(app.id, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text(app.location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let capability = app.capability { Text(capability).font(.callout) }
            if let result = model.testResults[app.id] {
                Label(result.summary, systemImage: result.isReachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(result.isReachable ? .green : .orange)
            }
            if model.awaitingBrowser.contains(app.id) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").font(.caption)
                    Button("Cancel") { model.cancelSignIn(app.id) }.controlSize(.small)
                }
            }
            if let connector, !secretNames(connector).isEmpty {
                HStack(spacing: 6) {
                    Text(connector.transport.remoteURL == nil ? "Secret variables:" : "Secret headers:").font(.caption).foregroundStyle(.secondary)
                    ForEach(secretNames(connector), id: \.self) { name in
                        HStack(spacing: 2) {
                            Text(name).font(.caption.monospaced())
                            Button { model.removeSecret(app.id, name: name) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).controlSize(.mini).help("Forget \(name)")
                        }
                    }
                }
            }
            if editingSecrets, let connector {
                VStack(alignment: .leading, spacing: 4) {
                    SecretLinesEditor(kind: connector.transport.remoteURL == nil ? .environment : .header, text: $secretsDraft)
                    HStack {
                        Spacer()
                        Button("Cancel") { editingSecrets = false; secretsDraft = "" }
                        Button("Save") {
                            if model.setSecretLines(app.id, secretsDraft) { secretsDraft = ""; editingSecrets = false }
                        }
                        .disabled(secretsDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if editingToken {
                HStack {
                    SecureField("Paste a token or API key", text: $tokenDraft)
                    Button("Save") {
                        model.setToken(app.id, tokenDraft)
                        tokenDraft = ""
                        editingToken = false
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { editingToken = false }
                }
            }
            HStack {
                Button(isBusy && !model.awaitingBrowser.contains(app.id) ? "Testing…" : "Test") { model.test(app.id) }
                    .disabled(isBusy || app.status == .disabled)
                if let connector, connector.transport.remoteURL != nil {
                    if connector.auth == .oauth || app.status == .needsSignIn {
                        Button(app.status == .needsSignIn ? "Sign In…" : "Sign In Again…") { model.signIn(app.id) }.disabled(isBusy)
                        if app.status == .ready, connector.auth == .oauth { Button("Sign Out") { model.signOut(app.id) } }
                    }
                    if connector.auth != .oauth || app.status != .ready {
                        Button(connector.auth == .bearer ? "Replace Token…" : "Use a Token…") { editingToken = true }
                    }
                }
                if let connector, app.kind == .remote || app.kind == .command {
                    Button(connector.transport.remoteURL == nil ? "Secret Variables…" : "Secret Headers…") { editingSecrets = true }
                }
                Spacer()
                if let connector {
                    Toggle("Let the buddy change things", isOn: Binding(get: { connector.allowWrites ?? false },
                                                                       set: { model.setAllowWrites(app.id, $0) }))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Off: the buddy only reads from this app. Background jobs can always use it.")
                }
                Button("Remove", role: .destructive) {
                    switch app.kind {
                    case .obsidian: model.removeObsidian()
                    case .composio: model.removeComposio()
                    default: model.remove(app.id)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func secretNames(_ connector: ConnectorConfig) -> [String] {
        (connector.transport.remoteURL == nil ? connector.environment : connector.secretHeaders).map { Array($0.keys).sorted() } ?? []
    }

    private var icon: String {
        switch app.kind {
        case .remote: "globe"
        case .command: "terminal"
        case .obsidian: "note.text"
        case .composio: "square.grid.2x2"
        }
    }
}

private struct StatusBadge: View {
    let status: ConnectedAppSummary.Status

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var text: String {
        switch status {
        case .ready: "Ready"
        case .needsSignIn: "Needs sign-in"
        case .missingSecret: "Missing key"
        case .disabled: "Off"
        }
    }

    private var color: Color {
        switch status {
        case .ready: .green
        case .needsSignIn, .missingSecret: .orange
        case .disabled: .secondary
        }
    }
}

private struct PresetRow: View {
    let preset: ConnectorPreset
    let model: ConnectedAppsModel
    @ViewState private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(preset.name).font(.headline)
                Text(preset.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("Docs", destination: preset.docsURL).font(.caption)
                Button(preset.auth == .oauth ? "Add and Sign In…" : "Add") {
                    model.addPreset(preset, token: token)
                    token = ""
                    if preset.auth == .oauth, let added = model.registry.connectors.last(where: { $0.preset == preset.id }) {
                        model.signIn(added.id)
                    }
                }
                .disabled(preset.auth == .bearer && token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(preset.note).font(.caption).foregroundStyle(.secondary)
            if preset.auth == .bearer {
                HStack {
                    SecureField("Token", text: $token)
                    if let help = preset.tokenHelpURL { Link("Create one", destination: help).font(.caption) }
                }
            }
        }
    }
}

// MARK: - Adding

private struct AddRemoteSection: View {
    let model: ConnectedAppsModel
    @ViewState private var name = ""
    @ViewState private var url = ""
    @ViewState private var auth: ConnectorAuth = .oauth
    @ViewState private var token = ""
    @ViewState private var label = ""
    @ViewState private var headerLines = ""

    var body: some View {
        Section {
            TextField("Name", text: $name, prompt: Text("Helpdesk"))
            TextField("Server URL", text: $url, prompt: Text(verbatim: "https://example.com/mcp"))
            Picker("Sign-in", selection: $auth) {
                Text("Sign in with browser").tag(ConnectorAuth.oauth)
                Text("API key or token").tag(ConnectorAuth.bearer)
                Text("None").tag(ConnectorAuth.none)
            }
            if auth == .bearer { SecureField("Token", text: $token) }
            TextField("Account label (optional)", text: $label, prompt: Text("Work"))
            SecretLinesEditor(kind: .header, text: $headerLines)
            HStack {
                Spacer()
                Button(auth == .oauth ? "Add and Sign In…" : "Add") {
                    guard model.addRemote(name: name, url: url, auth: auth, token: token, label: label, headerLines: headerLines) else { return }
                    if auth == .oauth, let added = model.registry.connectors.last { model.signIn(added.id) }
                    name = ""; url = ""; token = ""; label = ""; headerLines = ""
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Add a server by URL")
        } footer: {
            Text("Any MCP server that speaks Streamable HTTP. Tokens and header values are kept in your Keychain, never in connectors.json.")
        }
    }
}

private struct AddCommandSection: View {
    let model: ConnectedAppsModel
    @ViewState private var name = ""
    @ViewState private var commandLine = ""
    @ViewState private var label = ""
    @ViewState private var environmentLines = ""

    var body: some View {
        Section {
            TextField("Name", text: $name, prompt: Text("Files"))
            TextField("Command", text: $commandLine, prompt: Text(verbatim: "npx -y @example/mcp-server"))
            TextField("Account label (optional)", text: $label)
            SecretLinesEditor(kind: .environment, text: $environmentLines)
            HStack {
                Spacer()
                Button("Add") {
                    guard model.addCommand(name: name, commandLine: commandLine, label: label, environmentLines: environmentLines) else { return }
                    name = ""; commandLine = ""; label = ""; environmentLines = ""
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || commandLine.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Add a command on this Mac")
        } footer: {
            Text("Starts a local MCP server when needed. Environment values are kept in your Keychain and handed to the server when it starts.")
        }
    }
}

private struct ObsidianSection: View {
    let model: ConnectedAppsModel

    var body: some View {
        Section {
            if let obsidian = model.registry.obsidian {
                HStack {
                    Text(obsidian.vaultPath).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…") { model.chooseObsidianVault() }
                }
            } else {
                HStack {
                    Text("No vault chosen").foregroundStyle(.secondary)
                    Spacer()
                    if model.discoveredVaults == nil { Button("Find Vaults") { model.findObsidianVaults() } }
                    Button("Choose Vault…") { model.chooseObsidianVault() }
                }
                if let vaults = model.discoveredVaults {
                    if vaults.isEmpty {
                        Text("No vaults found in iCloud Drive, Documents or ~/Obsidian.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(vaults, id: \.self) { vault in
                        HStack {
                            Text(vault.lastPathComponent)
                            Text(vault.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Use") { model.setObsidianVault(vault.path) }
                        }
                    }
                }
            }
        } header: {
            Text("Obsidian")
        } footer: {
            Text("OpenClicky reads and writes the Markdown files in this folder directly. No account needed.")
        }
    }
}

private struct ComposioSection: View {
    let model: ConnectedAppsModel
    @ViewState private var userID = ""
    @ViewState private var toolkits = ""
    @ViewState private var key = ""
    @ViewState private var toolkitToConnect = ""

    var body: some View {
        Section {
            TextField("User id", text: $userID, prompt: Text(model.registry.composio?.userID ?? "you@example.com"))
            TextField("Toolkits (optional)", text: $toolkits, prompt: Text("gmail, googlecalendar"))
            SecureField(model.hasComposioKey ? "API key saved in Keychain" : "Composio API key", text: $key)
            HStack {
                Spacer()
                if model.registry.composio != nil { Button("Remove", role: .destructive) { model.removeComposio() } }
                Button("Save") {
                    model.saveComposio(userID: userID.isEmpty ? model.registry.composio?.userID ?? "" : userID, toolkits: toolkits, key: key)
                    key = ""
                }
                .disabled(userID.isEmpty && model.registry.composio == nil)
            }
            if model.registry.composio != nil, model.hasComposioKey {
                ComposioAccountsList(model: model, toolkitToConnect: $toolkitToConnect)
            }
        } header: {
            Text("Composio (optional)")
        } footer: {
            Text("Uses your own Composio account and API key. Connect an app here (it opens Composio's sign-in page) or in Composio's dashboard; background jobs and the buddy then see the apps that are connected.")
        }
        .onAppear { if model.registry.composio != nil, model.hasComposioKey, model.composioAccounts.isEmpty { model.refreshComposioAccounts() } }
    }
}

/// Secret header (`Header-Name: value`) or environment (`NAME=value`) lines, one per line. Values go to the Keychain.
struct SecretLinesEditor: View {
    let kind: ConnectorSecretLines.Kind
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind == .header ? "Secret headers (optional), one per line" : "Secret environment variables (optional), one per line")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .frame(minHeight: 44, maxHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(kind == .header ? "X-Api-Key: …" : "API_TOKEN=…")
                            .font(.callout.monospaced()).foregroundStyle(.tertiary).padding(8).allowsHitTesting(false)
                    }
                }
        }
    }
}

/// The user's Composio accounts with Disconnect, and connecting another app through Composio's sign-in page.
private struct ComposioAccountsList: View {
    let model: ConnectedAppsModel
    @Binding var toolkitToConnect: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Connected accounts").font(.subheadline.weight(.semibold))
                Spacer()
                if model.composioFlow == .loading { ProgressView().controlSize(.small) }
                Button("Refresh") { model.refreshComposioAccounts() }.controlSize(.small).disabled(model.isConnectingComposio)
            }
            if model.composioAccounts.isEmpty, model.composioFlow != .loading {
                Text("No apps connected for this user yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.composioAccounts) { account in
                HStack(spacing: 8) {
                    Image(systemName: account.isActive ? "checkmark.circle.fill" : account.hasFailed ? "xmark.octagon.fill" : "clock")
                        .foregroundStyle(account.isActive ? .green : account.hasFailed ? .red : .orange)
                    Text(account.toolkit).font(.callout.weight(.medium))
                    Text(account.alias ?? account.id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Text(account.status.capitalized).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.disconnecting.contains(account.id) ? "Disconnecting…" : "Disconnect", role: .destructive) {
                        model.disconnectComposio(account.id)
                    }
                    .controlSize(.small)
                    .disabled(model.disconnecting.contains(account.id))
                }
            }
            switch model.composioFlow {
            case .waiting(let toolkit):
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Finish connecting \(toolkit) in your browser…").font(.caption)
                    Button("Cancel") { model.cancelComposioConnect() }.controlSize(.small)
                }
            case .failed(let problem):
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            case .idle, .loading:
                EmptyView()
            }
            HStack {
                TextField("App to connect", text: $toolkitToConnect, prompt: Text("gmail, slack, notion…"))
                Button("Connect…") {
                    model.connectComposio(toolkit: toolkitToConnect)
                    toolkitToConnect = ""
                }
                .disabled(toolkitToConnect.trimmingCharacters(in: .whitespaces).isEmpty || {
                    if case .waiting = model.composioFlow { true } else { false }
                }())
            }
        }
        .padding(.top, 4)
    }
}
