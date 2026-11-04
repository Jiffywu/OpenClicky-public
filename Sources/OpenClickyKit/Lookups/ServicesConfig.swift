import Foundation

/// The non-model services the brain and drawings call (parity §2.5 `other:*` slots).
public enum LookupService: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case webSearch = "web-search"
    case imageSearch = "image-search"
    case places
    case marketData = "market-data"

    public var title: String {
        switch self {
        case .webSearch: "Web search"
        case .imageSearch: "Image search"
        case .places: "Places"
        case .marketData: "Market data"
        }
    }

    /// Providers that can fill this service, the default first.
    public var allowedProviders: [LookupProviderKind] {
        switch self {
        case .webSearch: [.brave, .exa, .tavily, .brainHosted, .off]
        case .imageSearch: [.wikimediaCommons, .brave, .off]
        case .places: [.mapKit, .off]
        case .marketData: [.twelveData, .off]
        }
    }

    public var defaultChoice: ServiceChoice { ServiceChoice(provider: allowedProviders[0]) }
}

/// A vendor (or system framework) behind a lookup service.
public enum LookupProviderKind: String, Codable, Sendable, CaseIterable {
    case brave
    case exa
    case tavily
    /// The brain model's provider searches by itself (see `HostedWebSearch`).
    case brainHosted = "brain-hosted"
    case wikimediaCommons = "wikimedia-commons"
    case mapKit = "mapkit"
    case twelveData = "twelve-data"
    /// The service is switched off; its brain tool is not offered.
    case off

    public var displayName: String {
        switch self {
        case .brave: "Brave Search"
        case .exa: "Exa"
        case .tavily: "Tavily"
        case .brainHosted: "The brain's own search (OpenAI or Anthropic)"
        case .wikimediaCommons: "Wikimedia Commons (no key)"
        case .mapKit: "Apple Maps (no key)"
        case .twelveData: "Twelve Data"
        case .off: "Off"
        }
    }

    public var needsKey: Bool { defaultCredential != nil }

    /// The Keychain credential name used when the config does not name one.
    public var defaultCredential: String? {
        switch self {
        case .brave: "brave"
        case .exa: "exa"
        case .tavily: "tavily"
        case .twelveData: "twelve-data"
        case .brainHosted, .wikimediaCommons, .mapKit, .off: nil
        }
    }

    public var defaultBaseURL: URL? {
        switch self {
        case .brave: BraveWebSearch.defaultBaseURL
        case .exa: ExaWebSearch.defaultBaseURL
        case .tavily: TavilyWebSearch.defaultBaseURL
        case .wikimediaCommons: WikimediaCommonsImageSearch.defaultBaseURL
        case .twelveData: TwelveDataQuotes.defaultBaseURL
        case .brainHosted, .mapKit, .off: nil
        }
    }

    /// Where the user gets a key.
    public var keyPage: URL? {
        switch self {
        case .brave: URL(string: "https://api-dashboard.search.brave.com/")
        case .exa: URL(string: "https://dashboard.exa.ai/api-keys")
        case .tavily: URL(string: "https://app.tavily.com/")
        case .twelveData: URL(string: "https://twelvedata.com/account/api-keys")
        case .brainHosted, .wikimediaCommons, .mapKit, .off: nil
        }
    }
}

/// The provider for one service and the name of the credential it uses.
public struct ServiceChoice: Codable, Sendable, Hashable {
    public var provider: LookupProviderKind
    /// Keychain credential name. Nil means the provider's default name (`brave`, `exa`, `tavily`, `twelve-data`).
    public var credential: String?
    /// Override for proxies or regional endpoints. Nil uses the vendor's public API.
    public var baseURL: URL?

    public init(provider: LookupProviderKind, credential: String? = nil, baseURL: URL? = nil) {
        self.provider = provider
        self.credential = credential
        self.baseURL = baseURL
    }

    /// The credential name actually used.
    public var credentialName: String? {
        guard provider.needsKey else { return nil }
        return LookupText.nonEmpty(credential) ?? provider.defaultCredential
    }
}

public struct ServiceIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var service: LookupService
    public var message: String

    public var description: String { "\(severity.rawValue) [\(service.rawValue)]: \(message)" }
}

/// Which provider fills each lookup service. Stored on its own, next to config.json, at
/// `~/Library/Application Support/OpenClicky/services.json`, so the model-slot config stays untouched.
/// Like config.json it only names credentials; keys stay in the Keychain.
public struct ServicesConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var services: [LookupService: ServiceChoice]
    /// Image search: also try Wikimedia Commons when the chosen provider finds nothing. Default on.
    public var commonsFallback: Bool?
    public var favicons: FaviconService?
    /// No-people photos: check thumbnails on device with Vision, not just their words. Default on.
    public var detectPeople: Bool?

    public init(version: Int = 1, services: [LookupService: ServiceChoice] = [:], commonsFallback: Bool? = nil,
                favicons: FaviconService? = nil, detectPeople: Bool? = nil) {
        self.version = version
        self.services = services
        self.commonsFallback = commonsFallback
        self.favicons = favicons
        self.detectPeople = detectPeople
    }

    private enum CodingKeys: String, CodingKey { case version, services, commonsFallback, favicons, detectPeople }

    /// Every key is optional: a missing `version` is 1 and a missing `services` leaves each service at its default,
    /// as `choice(for:)` does for a service the file leaves out. Values that are present must still be valid.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        services = try container.decodeIfPresent([LookupService: ServiceChoice].self, forKey: .services) ?? [:]
        commonsFallback = try container.decodeIfPresent(Bool.self, forKey: .commonsFallback)
        favicons = try container.decodeIfPresent(FaviconService.self, forKey: .favicons)
        detectPeople = try container.decodeIfPresent(Bool.self, forKey: .detectPeople)
    }

    /// Brave for web search, Commons for photos, MapKit for places, Twelve Data for quotes. Only places and photos
    /// work before any key is stored.
    public static let defaults = ServicesConfig(services: Dictionary(uniqueKeysWithValues: LookupService.allCases.map { ($0, $0.defaultChoice) }))

    public static var defaultURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("services.json")
    }

    /// The saved config, or the defaults when no file exists yet.
    public static func load(from url: URL = defaultURL) throws -> ServicesConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return .defaults }
        do {
            return try JSONDecoder().decode(ServicesConfig.self, from: Data(contentsOf: url))
        } catch let error as DecodingError {
            throw LookupError.invalidConfig("\(url.path) is not a valid services config: \(Self.explain(error))")
        }
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The choice for a service, falling back to the default for services the file does not mention.
    public func choice(for service: LookupService) -> ServiceChoice { services[service] ?? service.defaultChoice }

    /// Problems that keep a service from working. A missing key is a warning: the rest of OpenClicky still runs,
    /// that one tool is just not offered. `brainDialect` lets brain-hosted search be checked against the brain slot.
    public func issues(credentials: (any CredentialStore)?, brainDialect: ProviderDialect? = nil) -> [ServiceIssue] {
        var issues: [ServiceIssue] = []
        for service in LookupService.allCases {
            let choice = choice(for: service)
            guard service.allowedProviders.contains(choice.provider) else {
                issues.append(.init(severity: .error, service: service,
                                    message: "\(choice.provider.displayName) cannot do \(service.title.lowercased()). Choose one of: "
                                        + service.allowedProviders.map(\.rawValue).joined(separator: ", ") + "."))
                continue
            }
            if let base = choice.baseURL, let problem = Self.baseURLProblem(base) {
                issues.append(.init(severity: .error, service: service, message: problem))
            }
            if choice.provider == .brainHosted {
                if !HostedWebSearch.brainPassesHostedTools {
                    issues.append(.init(severity: .warning, service: service,
                                        message: "OpenClicky's brain does not hand hosted search to its provider yet, so web search is off. "
                                            + "Choose Brave, Exa or Tavily for now."))
                } else if let brainDialect, !HostedWebSearch.isSupported(by: brainDialect) {
                    issues.append(.init(severity: .warning, service: service,
                                        message: "The brain's provider (\(brainDialect.rawValue)) has no hosted search; web search is off."))
                }
            }
            if let name = choice.credentialName, let credentials {
                let stored = (try? credentials.secret(named: name)).flatMap { LookupText.nonEmpty($0) } != nil
                if !stored {
                    issues.append(.init(severity: .warning, service: service,
                                        message: "\(service.title) needs a \(choice.provider.displayName) key. Store it with: occtl key set \(name)"))
                }
            }
        }
        return issues
    }

    static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    }

    /// Why a base URL must not receive a key, or nil when it may. Keys travel only over https, or over plain http to a
    /// server on this Mac (the rule config.json's providers follow too).
    static func baseURLProblem(_ url: URL) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        guard url.host?.isEmpty == false, scheme == "https" || (scheme == "http" && isLoopback(url)) else {
            return "Base URL \(ProviderContext.redacted(url)) must be https (plain http only to a server on this Mac)."
        }
        return nil
    }

    private static func explain(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}
