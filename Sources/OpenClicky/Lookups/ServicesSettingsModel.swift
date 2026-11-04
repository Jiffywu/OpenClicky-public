import Foundation
import OpenClickyKit

/// State behind the Services settings page: services.json, which keys are stored, and the last test of each service.
@MainActor
@Observable
final class ServicesSettingsModel {
    enum TestState: Equatable {
        case running
        case passed(String)
        case failed(String)
    }

    private(set) var config: ServicesConfig
    private(set) var issues: [ServiceIssue] = []
    /// Credential name → whether a key is stored.
    private(set) var storedKeys: [String: Bool] = [:]
    private(set) var tests: [LookupService: TestState] = [:]
    /// The run each service's Test button started last. A result from an older run (before the provider or key
    /// changed, or a second tap) is dropped instead of being shown under the new setting.
    private var testRuns: [LookupService: UUID] = [:]
    private(set) var loadError: String?

    let credentials: any CredentialStore
    let url: URL
    /// The brain slot's dialect, so choosing hosted search can be checked against it.
    var brainDialect: ProviderDialect?

    init(credentials: any CredentialStore, url: URL = ServicesConfig.defaultURL, brainDialect: ProviderDialect? = nil) {
        self.credentials = credentials
        self.url = url
        self.brainDialect = brainDialect
        do {
            config = try ServicesConfig.load(from: url)
        } catch {
            config = .defaults
            loadError = "\(error) Showing the defaults; saving will replace the file."
        }
        refresh()
    }

    // MARK: Reading

    func choice(_ service: LookupService) -> ServiceChoice { config.choice(for: service) }

    func issues(for service: LookupService) -> [ServiceIssue] { issues.filter { $0.service == service } }

    func hasKey(_ service: LookupService) -> Bool {
        guard let name = choice(service).credentialName else { return true }
        return storedKeys[name] ?? false
    }

    // MARK: Changing

    func setProvider(_ provider: LookupProviderKind, for service: LookupService) {
        var choice = config.choice(for: service)
        guard choice.provider != provider else { return }
        choice.provider = provider
        // A custom credential name or base URL belongs to the old vendor.
        choice.credential = nil
        choice.baseURL = nil
        config.services[service] = choice
        clearTest(service)
        save()
    }

    func setCredentialName(_ name: String, for service: LookupService) {
        var choice = config.choice(for: service)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        choice.credential = trimmed.isEmpty || trimmed == choice.provider.defaultCredential ? nil : trimmed
        config.services[service] = choice
        save()
    }

    func storeKey(_ key: String, for service: LookupService) {
        guard let name = choice(service).credentialName else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try credentials.setSecret(trimmed, named: name)
        } catch {
            loadError = "Couldn't store the key: \(error)"
        }
        clearTest(service)
        refresh()
    }

    func removeKey(for service: LookupService) {
        guard let name = choice(service).credentialName else { return }
        try? credentials.removeSecret(named: name)
        clearTest(service)
        refresh()
    }

    func setCommonsFallback(_ on: Bool) {
        config.commonsFallback = on
        save()
    }

    func setDetectPeople(_ on: Bool) {
        config.detectPeople = on
        save()
    }

    func setFavicons(_ service: FaviconService) {
        config.favicons = service
        save()
    }

    // MARK: Testing

    /// Runs one sample lookup through the same tool handler the brain uses.
    func test(_ service: LookupService) {
        let run = UUID()
        testRuns[service] = run
        tests[service] = .running
        let services = LookupServices.make(config: config, credentials: credentials)
        let (tool, arguments) = Self.sample(for: service)
        Task {
            let result = await LookupTools(services: services).handle(name: tool, arguments: arguments.jsonString())
            guard self.testRuns[service] == run else { return }
            self.tests[service] = Self.testState(result)
        }
    }

    private func clearTest(_ service: LookupService) {
        testRuns[service] = nil
        tests[service] = nil
    }

    static func sample(for service: LookupService) -> (String, JSONValue) {
        switch service {
        case .webSearch: (LookupTools.webSearch, ["query": "Swift programming language", "count": 3])
        case .imageSearch: (LookupTools.imageSearch, ["query": "Golden Gate Bridge", "count": 2])
        case .places: (LookupTools.placeSearch, ["query": "Ferry Building, San Francisco", "limit": 2])
        case .marketData: (LookupTools.stockQuote, ["symbol": "AAPL"])
        }
    }

    static func testState(_ result: LookupToolResult?) -> TestState {
        guard let result else { return .failed("Not a lookup tool.") }
        guard result.succeeded, let widget = result.widget else {
            let message = (try? JSONValue.parse(result.output))?["message"]?.stringValue ?? "The lookup failed."
            return .failed(message)
        }
        switch widget {
        case .webResults(_, let provider, let results):
            return results.first.map { .passed("\(provider): \($0.title) (\($0.site))") } ?? .failed("No results came back.")
        case .images(_, let images):
            return images.first.map { .passed("\($0.provider): \($0.title ?? $0.imageURL.lastPathComponent)") } ?? .failed("No images came back.")
        case .places(_, let places):
            return places.first.map { .passed("\($0.name)\($0.address.map { ", \($0)" } ?? "")") } ?? .failed("No places came back.")
        case .stock(let quote):
            return .passed("\(quote.symbol) \(LookupFormatting.text(.stock(quote)).split(separator: "\n").dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")")
        }
    }

    // MARK: Persistence

    private func save() {
        do {
            try config.save(to: url)
            loadError = nil
        } catch {
            loadError = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() {
        var stored: [String: Bool] = [:]
        for service in LookupService.allCases {
            guard let name = config.choice(for: service).credentialName else { continue }
            let secret = (try? credentials.secret(named: name)) ?? nil
            stored[name] = !(secret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        storedKeys = stored
        issues = config.issues(credentials: credentials, brainDialect: brainDialect)
    }
}
