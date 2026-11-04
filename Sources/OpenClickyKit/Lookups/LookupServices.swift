import Foundation

/// The lookup services, built from services.json and the stored keys. A service that cannot run (no key, switched
/// off) is nil, with the reason in `unavailable`, so the brain is simply not offered that tool.
public struct LookupServices: Sendable {
    public var webSearch: (any WebSearchProvider)?
    public var imageSearch: ImageSearchService?
    public var places: (any PlaceSearchProvider)?
    public var marketData: (any MarketQuoteProvider)?
    /// Web search is left to the brain's own provider (`HostedWebSearch`).
    public var hostedWebSearch: Bool
    /// Why each missing service is missing, worded for the user.
    public var unavailable: [LookupService: String]
    /// Services that work but not as configured (image search falling back to Commons without a Brave key).
    public var notes: [LookupService: String] = [:]

    public init(webSearch: (any WebSearchProvider)? = nil, imageSearch: ImageSearchService? = nil,
                places: (any PlaceSearchProvider)? = nil, marketData: (any MarketQuoteProvider)? = nil,
                hostedWebSearch: Bool = false, unavailable: [LookupService: String] = [:]) {
        self.webSearch = webSearch
        self.imageSearch = imageSearch
        self.places = places
        self.marketData = marketData
        self.hostedWebSearch = hostedWebSearch
        self.unavailable = unavailable
    }

    /// Builds every service the config and the stored keys allow.
    /// - Parameters:
    ///   - http: The network for the lookup APIs.
    ///   - webHTTP: The network for third-party pages and thumbnails (page previews, the people check). Defaults to
    ///     `http` when that is a test transport, else to `URLSessionTransport.publicWebOnly`.
    ///   - mapKit: The MapKit seam; tests pass a fake.
    ///   - peopleDetector: Thumbnail checker for no-people photos; nil uses only the word heuristic.
    public static func make(config: ServicesConfig, credentials: any CredentialStore, http: any HTTPTransport = URLSessionTransport(),
                            webHTTP: (any HTTPTransport)? = nil,
                            mapKit: any MapKitLocalSearching = SystemMapKitLocalSearch(),
                            peopleDetector: (any PeopleDetecting)? = VisionPeopleDetector()) -> LookupServices {
        var services = LookupServices()
        let pageHTTP = webHTTP ?? (http is URLSessionTransport ? URLSessionTransport.publicWebOnly : http)
        // Lookup requests are counted in the usage ledger when the app or occtl installed one (docs/infra.md).
        let http = ProviderResilience.installed?.lookupTransport(http) ?? http

        func endpoint(_ service: LookupService) -> Result<LookupEndpoint?, LookupError> {
            let choice = config.choice(for: service)
            guard service.allowedProviders.contains(choice.provider) else {
                return .failure(.unavailable(service: service.title, reason: "\(choice.provider.rawValue) cannot do \(service.title.lowercased())"))
            }
            if choice.provider == .off { return .failure(.unavailable(service: service.title, reason: "it is switched off in Settings")) }
            guard let base = choice.baseURL ?? choice.provider.defaultBaseURL else { return .success(nil) }
            // Never hand a key to a cleartext link off this Mac.
            if let problem = ServicesConfig.baseURLProblem(base) {
                return .failure(.unavailable(service: service.title, reason: problem))
            }
            var key: String?
            if let name = choice.credentialName {
                key = (try? credentials.secret(named: name)).flatMap { LookupText.nonEmpty($0) }
                guard key != nil else {
                    return .failure(.unavailable(service: service.title,
                                                 reason: "no \(choice.provider.displayName) key is stored (occtl key set \(name))"))
                }
            }
            return .success(LookupEndpoint(baseURL: base, apiKey: key, http: http))
        }

        func note(_ service: LookupService, _ error: LookupError) {
            if case .unavailable(_, let reason) = error { services.unavailable[service] = reason }
        }

        // Web search.
        switch (config.choice(for: .webSearch).provider, endpoint(.webSearch)) {
        case (.brainHosted, _): services.hostedWebSearch = true
        case (.brave, .success(let e?)): services.webSearch = BraveWebSearch(endpoint: e)
        case (.exa, .success(let e?)): services.webSearch = ExaWebSearch(endpoint: e)
        case (.tavily, .success(let e?)): services.webSearch = TavilyWebSearch(endpoint: e)
        case (_, .failure(let error)): note(.webSearch, error)
        default: services.unavailable[.webSearch] = "no web search provider is chosen"
        }

        // Image search: the chosen provider, then Commons as a keyless fallback.
        let imageChoice = config.choice(for: .imageSearch).provider
        if imageChoice != .off {
            var providers: [any ImageSearchProvider] = []
            switch (imageChoice, endpoint(.imageSearch)) {
            case (.brave, .success(let e?)): providers.append(BraveImageSearch(endpoint: e))
            case (.wikimediaCommons, .success(let e?)): providers.append(WikimediaCommonsImageSearch(endpoint: e))
            case (_, .failure(let error)): note(.imageSearch, error)
            default: break
            }
            if config.commonsFallback ?? true, !providers.contains(where: { $0.providerID == "wikimedia-commons" }) {
                providers.append(WikimediaCommonsImageSearch(endpoint: LookupEndpoint(baseURL: WikimediaCommonsImageSearch.defaultBaseURL, http: http)))
            }
            if !providers.isEmpty {
                services.imageSearch = ImageSearchService(
                    providers: providers, favicons: FaviconLookup(service: config.favicons ?? .duckDuckGo),
                    pagePreview: PagePreviewImageLookup(http: pageHTTP),
                    peopleFilter: PeopleFilter(detector: (config.detectPeople ?? true) ? peopleDetector : nil, http: pageHTTP))
                // A fallback is running, so the missing key is a note, not an outage.
                if let reason = services.unavailable.removeValue(forKey: .imageSearch) {
                    services.notes[.imageSearch] = "\(reason); using Wikimedia Commons instead"
                }
            }
        } else {
            services.unavailable[.imageSearch] = "it is switched off in Settings"
        }

        // Places.
        switch config.choice(for: .places).provider {
        case .mapKit: services.places = MapKitPlaceSearch(backend: mapKit)
        case .off: services.unavailable[.places] = "it is switched off in Settings"
        default: if case .failure(let error) = endpoint(.places) { note(.places, error) }
        }

        // Market data.
        switch (config.choice(for: .marketData).provider, endpoint(.marketData)) {
        case (.twelveData, .success(let e?)): services.marketData = TwelveDataQuotes(endpoint: e)
        case (_, .failure(let error)): note(.marketData, error)
        default: services.unavailable[.marketData] = "no market data provider is chosen"
        }
        return services
    }

    /// Whether a service can answer now.
    public func isAvailable(_ service: LookupService) -> Bool {
        switch service {
        case .webSearch: webSearch != nil
        case .imageSearch: imageSearch != nil
        case .places: places != nil
        case .marketData: marketData != nil
        }
    }

    /// The error a caller gets for a missing service.
    public func unavailableError(_ service: LookupService) -> LookupError {
        if service == .webSearch && hostedWebSearch {
            return .unavailable(service: service.title, reason: "web search is done by the brain's own provider")
        }
        return .unavailable(service: service.title, reason: unavailable[service] ?? "it is not set up")
    }
}
