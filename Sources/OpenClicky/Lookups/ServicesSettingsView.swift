import OpenClickyKit
import SwiftUI

/// Settings → Services: which provider answers web search, image search, places and market data, and the keys they
/// use. Saved to services.json; keys go to the Keychain. Embed it as a Settings tab:
///
///     ServicesSettingsView(model: ServicesSettingsModel(credentials: appModel.credentials))
///         .tabItem { Label("Services", systemImage: "magnifyingglass") }
struct ServicesSettingsView: View {
    let model: ServicesSettingsModel

    var body: some View {
        Form {
            if let error = model.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
            }
            ForEach(LookupService.allCases, id: \.self) { service in
                ServiceSection(model: model, service: service)
            }
            Section("Photos in drawings") {
                Toggle("Fall back to Wikimedia Commons when the chosen search finds nothing", isOn: Binding(
                    get: { model.config.commonsFallback ?? true }, set: { model.setCommonsFallback($0) }))
                Toggle("Check “no people” photos on this Mac with Vision", isOn: Binding(
                    get: { model.config.detectPeople ?? true }, set: { model.setDetectPeople($0) }))
                Picker("Site icons from", selection: Binding(
                    get: { model.config.favicons ?? .duckDuckGo }, set: { model.setFavicons($0) })) {
                    Text("DuckDuckGo").tag(FaviconService.duckDuckGo)
                    Text("Google").tag(FaviconService.google)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
    }
}

private struct ServiceSection: View {
    let model: ServicesSettingsModel
    let service: LookupService
    @ViewState private var keyDraft = ""
    @ViewState private var credentialDraft = ""

    private var choice: ServiceChoice { model.choice(service) }

    var body: some View {
        Section {
            Picker("Provider", selection: Binding(get: { choice.provider }, set: { model.setProvider($0, for: service) })) {
                ForEach(service.allowedProviders, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            if let name = choice.credentialName {
                HStack {
                    SecureField(model.hasKey(service) ? "Key stored in the Keychain (\(name))" : "Paste your \(choice.provider.displayName) key",
                                text: $keyDraft)
                    Button(model.hasKey(service) ? "Replace" : "Save") {
                        model.storeKey(keyDraft, for: service)
                        keyDraft = ""
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.hasKey(service) {
                        Button("Remove", role: .destructive) { model.removeKey(for: service) }
                    }
                }
                HStack {
                    TextField("Credential name", text: $credentialDraft, prompt: Text(choice.provider.defaultCredential ?? ""))
                        .onSubmit { model.setCredentialName(credentialDraft, for: service) }
                    if let page = choice.provider.keyPage {
                        Link("Get a key", destination: page)
                    }
                }
                .font(.callout)
            }
            if choice.provider == .brainHosted {
                Text("The brain model's own provider searches the web inside its answer (OpenAI Responses or Anthropic Messages brains only).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(model.issues(for: service).enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                    .font(.callout)
            }
            if choice.provider != .off && choice.provider != .brainHosted {
                HStack {
                    Button("Test") { model.test(service) }
                        .disabled(model.tests[service] == .running)
                    testLine
                }
            }
        } header: {
            Text(Self.title(service))
        }
        .onAppear { credentialDraft = choice.credential ?? "" }
        .onChange(of: choice.provider) {
            credentialDraft = choice.credential ?? ""
            keyDraft = ""
        }
    }

    @ViewBuilder private var testLine: some View {
        switch model.tests[service] {
        case .running?:
            ProgressView().controlSize(.small)
        case .passed(let text)?:
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout).lineLimit(2)
        case .failed(let text)?:
            Label(text, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout).lineLimit(3)
        case nil:
            EmptyView()
        }
    }

    static func title(_ service: LookupService) -> String {
        switch service {
        case .webSearch: "Web search (answers about current things)"
        case .imageSearch: "Image search (photos in drawings and galleries)"
        case .places: "Places (map cards)"
        case .marketData: "Market data (stock cards)"
        }
    }
}
