import Foundation
import Testing
@testable import OpenClickyKit

/// services.json, the services factory, the image-search service (fallbacks, people filter, page previews, favicons)
/// and the brain's lookup tools. All scripted; nothing touches the network or the Keychain.
@Suite struct LookupServicesTests {
    // MARK: Fakes

    struct FakeWeb: WebSearchProvider {
        var providerID = "fake-web"
        var results: [WebSearchResult] = []
        var error: Error?
        var onQuery: (@Sendable (WebSearchQuery) -> Void)?

        func search(_ query: WebSearchQuery) async throws -> [WebSearchResult] {
            onQuery?(query)
            if let error { throw error }
            return Array(results.prefix(query.clampedCount))
        }
    }

    struct FakeImages: ImageSearchProvider {
        var providerID: String
        var modes: Set<ImageSearchQuery.Mode> = [.subject, .web]
        var results: [ImageResult] = []
        var error: Error?

        func searchImages(_ query: ImageSearchQuery) async throws -> [ImageResult] {
            if let error { throw error }
            return results
        }
    }

    struct FakePlaces: PlaceSearchProvider {
        var providerID = "fake-places"
        var places: [Place] = []
        var onQuery: (@Sendable (PlaceQuery) -> Void)?

        func searchPlaces(_ query: PlaceQuery) async throws -> [Place] {
            onQuery?(query)
            return Array(places.prefix(query.clampedLimit))
        }
    }

    struct FakeQuotes: MarketQuoteProvider {
        var providerID = "fake-quotes"
        var error: Error?
        var onQuote: (@Sendable (String, QuoteRange) -> Void)?

        func quote(symbol: String, range: QuoteRange) async throws -> MarketQuote {
            onQuote?(symbol, range)
            if let error { throw error }
            return MarketQuote(symbol: symbol.uppercased(), name: "Apple Inc.", exchange: "NASDAQ", currency: "USD", price: 230.75,
                               change: 3.25, changePercent: 1.428571, open: 228.1, dayHigh: 231.5, dayLow: 227.25, previousClose: 227.5,
                               asOf: Date(timeIntervalSince1970: 1_793_320_000), isMarketOpen: true, range: range,
                               recentCloses: (0..<80).map { 227 + Double($0) / 20 }, startPrice: 227.5)
        }
    }

    /// Says an image shows people when its bytes start with "P".
    struct FakeDetector: PeopleDetecting {
        func containsPeople(_ imageData: Data) async throws -> Bool { imageData.first == UInt8(ascii: "P") }
    }

    /// Answers each URL with its own body, whatever order requests arrive in (the people filter downloads in parallel,
    /// so a queue of scripted responses would hand bodies to the wrong thumbnails at random).
    final class ByURLTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let bodies: [String: String]
        private var seen: [URL] = []
        var requestedURLs: [URL] { lock.withLock { seen } }

        init(_ bodies: [String: String]) { self.bodies = bodies }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try #require(request.url)
            lock.withLock { seen.append(url) }
            guard let body = bodies[url.absoluteString] else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"])!)
        }

        func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
            let (data, response) = try await self.data(for: request)
            return (AsyncThrowingStream { $0.yield(data); $0.finish() }, response)
        }
    }

    final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Value] = []
        func append(_ value: Value) { lock.withLock { _values.append(value) } }
        var values: [Value] { lock.withLock { _values } }
    }

    static func image(_ name: String, title: String? = nil, keywords: [String] = []) -> ImageResult {
        ImageResult(imageURL: URL(string: "https://img.example.com/\(name).jpg")!, thumbnailURL: URL(string: "https://img.example.com/t/\(name).jpg")!,
                    sourcePageURL: URL(string: "https://pages.example.com/\(name)"), title: title ?? name, provider: "fake", keywords: keywords)
    }

    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-services-\(UUID().uuidString)").appendingPathComponent("services.json")
    }

    // MARK: - services.json

    @Test func defaultsNeedNoKeyForPlacesAndPhotos() {
        let config = ServicesConfig.defaults
        #expect(config.choice(for: .webSearch).provider == .brave)
        #expect(config.choice(for: .imageSearch).provider == .wikimediaCommons)
        #expect(config.choice(for: .places).provider == .mapKit)
        #expect(config.choice(for: .marketData).provider == .twelveData)
        let issues = config.issues(credentials: InMemoryCredentialStore())
        #expect(Set(issues.map(\.service)) == [.webSearch, .marketData])
        #expect(issues.allSatisfy { $0.severity == .warning })
        #expect(issues.first { $0.service == .webSearch }?.message.contains("occtl key set brave") == true)
    }

    @Test func servicesFileRoundTripsWithReadableKeysAndNoSecrets() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try ServicesConfig.load(from: url) == .defaults) // no file yet

        var config = ServicesConfig.defaults
        config.services[.webSearch] = ServiceChoice(provider: .exa, credential: "exa-work")
        config.services[.marketData] = ServiceChoice(provider: .off)
        config.detectPeople = false
        try config.save(to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"web-search\""))
        #expect(text.contains("\"market-data\""))
        #expect(text.contains("\"exa-work\""))
        #expect(try ServicesConfig.load(from: url) == config)
        #expect(config.choice(for: .webSearch).credentialName == "exa-work")
        #expect(ServiceChoice(provider: .mapKit, credential: "ignored").credentialName == nil)
    }

    @Test func aFileWithOnlySomeServicesFallsBackPerService() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 1, "services": {"web-search": {"provider": "tavily"}}}"#.utf8).write(to: url)
        let config = try ServicesConfig.load(from: url)
        #expect(config.choice(for: .webSearch).provider == .tavily)
        #expect(config.choice(for: .webSearch).credentialName == "tavily")
        #expect(config.choice(for: .places).provider == .mapKit)
    }

    @Test func aBrokenFileSaysWhere() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 1, "services": {"web-search": {"provider": "google"}}}"#.utf8).write(to: url)
        do {
            _ = try ServicesConfig.load(from: url)
            Issue.record("expected an error")
        } catch let error as LookupError {
            guard case .invalidConfig(let message) = error else { Issue.record("wrong error"); return }
            #expect(message.contains("services.json"))
            #expect(message.contains("provider"))
        }
    }

    @Test func issuesCatchWrongProvidersInsecureURLsAndHostedSearchMismatch() {
        var config = ServicesConfig.defaults
        config.services[.places] = ServiceChoice(provider: .brave)
        config.services[.webSearch] = ServiceChoice(provider: .brainHosted)
        config.services[.marketData] = ServiceChoice(provider: .twelveData, baseURL: URL(string: "http://quotes.example.com"))
        config.services[.imageSearch] = ServiceChoice(provider: .wikimediaCommons, baseURL: URL(string: "http://localhost:8080/w/api.php"))
        let issues = config.issues(credentials: InMemoryCredentialStore(["twelve-data": "k"]), brainDialect: .openAIChat)
        #expect(issues.contains { $0.service == .places && $0.severity == .error && $0.message.contains("cannot do places") })
        #expect(issues.contains { $0.service == .marketData && $0.severity == .error && $0.message.contains("https") })
        #expect(!issues.contains { $0.service == .imageSearch }) // a local proxy is fine
        if HostedWebSearch.brainPassesHostedTools {
            #expect(issues.contains { $0.service == .webSearch && $0.message.contains("no hosted search") })
            #expect(!config.issues(credentials: nil, brainDialect: .anthropicMessages).contains { $0.service == .webSearch })
        } else {
            // Until the brain passes hosted tools through, every dialect is told web search is off.
            #expect(issues.contains { $0.service == .webSearch && $0.message.contains("does not hand hosted search") })
            #expect(config.issues(credentials: nil, brainDialect: .anthropicMessages).contains { $0.service == .webSearch })
        }
    }

    // MARK: - Factory

    @Test func factoryBuildsWhatTheKeysAllow() {
        let fakeHTTP = FakeHTTPTransport([])
        let mapKit = LookupAdapterTests.FakeMapKit()
        let none = LookupServices.make(config: .defaults, credentials: InMemoryCredentialStore(), http: fakeHTTP, mapKit: mapKit, peopleDetector: nil)
        #expect(none.webSearch == nil)
        #expect(none.unavailable[.webSearch] == "no Brave Search key is stored (occtl key set brave)")
        #expect(none.imageSearch?.providerIDs == ["wikimedia-commons"])
        #expect(none.places?.providerID == "mapkit")
        #expect(none.marketData == nil)
        #expect(none.unavailableError(.marketData).description.contains("occtl key set twelve-data"))

        var config = ServicesConfig.defaults
        config.services[.imageSearch] = ServiceChoice(provider: .brave)
        config.services[.webSearch] = ServiceChoice(provider: .tavily, credential: "tavily-personal")
        let keyed = LookupServices.make(config: config, credentials: InMemoryCredentialStore(["brave": "b", "tavily-personal": "t", "twelve-data": "q"]),
                                        http: fakeHTTP, mapKit: mapKit, peopleDetector: nil)
        #expect(keyed.webSearch?.providerID == "tavily")
        #expect(keyed.imageSearch?.providerIDs == ["brave", "wikimedia-commons"])
        #expect(keyed.marketData?.providerID == "twelve-data")
        #expect(keyed.unavailable.isEmpty)

        let braveNoKey = LookupServices.make(config: config, credentials: InMemoryCredentialStore(), http: fakeHTTP, mapKit: mapKit, peopleDetector: nil)
        #expect(braveNoKey.imageSearch?.providerIDs == ["wikimedia-commons"])
        #expect(braveNoKey.unavailable[.imageSearch] == nil)
        #expect(braveNoKey.notes[.imageSearch]?.contains("using Wikimedia Commons instead") == true)

        var off = ServicesConfig.defaults
        off.services[.places] = ServiceChoice(provider: .off)
        off.services[.webSearch] = ServiceChoice(provider: .brainHosted)
        off.services[.imageSearch] = ServiceChoice(provider: .off)
        let switchedOff = LookupServices.make(config: off, credentials: InMemoryCredentialStore(), http: fakeHTTP, mapKit: mapKit, peopleDetector: nil)
        #expect(switchedOff.places == nil && switchedOff.imageSearch == nil)
        #expect(switchedOff.hostedWebSearch)
        #expect(switchedOff.unavailableError(.webSearch).description.contains("brain's own provider"))
        #expect(switchedOff.unavailable[.places] == "it is switched off in Settings")
        #expect(fakeHTTP.requests.isEmpty)
    }

    // MARK: - Image search service

    @Test func imageSearchFallsThroughProvidersAndDeduplicates() async throws {
        let failing = FakeImages(providerID: "brave", error: ProviderError(provider: "brave", status: 500, message: "down"))
        let empty = FakeImages(providerID: "empty")
        let commons = FakeImages(providerID: "wikimedia-commons", modes: [.subject], results: [Self.image("a"), Self.image("a"), Self.image("b")])
        let service = ImageSearchService(providers: [failing, empty, commons], pagePreview: nil, peopleFilter: PeopleFilter(detector: nil))
        let found = try await service.search(ImageSearchQuery("bridge", count: 5))
        #expect(found.map(\.imageURL.lastPathComponent) == ["a.jpg", "b.jpg"])

        // Only Commons is configured: a web query still gets subject photos rather than nothing.
        let commonsOnly = ImageSearchService(providers: [commons], pagePreview: nil, peopleFilter: PeopleFilter(detector: nil))
        #expect(try await commonsOnly.search(ImageSearchQuery("bridge", mode: .web)).count == 2)

        // Every provider failing surfaces the first error.
        let broken = ImageSearchService(providers: [failing], pagePreview: nil, peopleFilter: PeopleFilter(detector: nil))
        await #expect(throws: ProviderError.self) { try await broken.search(ImageSearchQuery("bridge")) }
    }

    @Test func noPeopleQueriesDropFlaggedWordsAndDetectedFaces() async throws {
        let results = [
            Self.image("portrait", title: "Portrait of a woman on the bridge"),
            Self.image("crowd", keywords: ["Crowds in San Francisco"]),
            Self.image("tower"),
            Self.image("walkers"),
            Self.image("bridge"),
        ]
        // Thumbnails: "walkers" shows people (detector says so), the others are clear.
        let thumbnails = ["tower": "clear", "walkers": "People!", "bridge": "clear"]
        let http = ByURLTransport(Dictionary(uniqueKeysWithValues: thumbnails.map { ("https://img.example.com/t/\($0.key).jpg", $0.value) }))
        let filter = PeopleFilter(detector: FakeDetector(), http: http)
        let kept = await filter.withoutPeople(results, limit: 5)
        #expect(kept.map(\.title) == ["tower", "bridge"])
        #expect(kept.allSatisfy { $0.mayShowPeople == false })
        #expect(http.requestedURLs.count == 3) // word-flagged results are never downloaded
        #expect(http.requestedURLs.allSatisfy { $0.path.hasPrefix("/t/") }) // thumbnails, not originals

        let annotated = PeopleFilter.annotate(results)
        #expect(annotated[0].mayShowPeople == true)
        #expect(annotated[1].mayShowPeople == true)
        #expect(annotated[2].mayShowPeople == nil)
    }

    @Test func peopleFilterDropsWhatItCannotCheck() async throws {
        let http = FakeHTTPTransport([.body("nope", status: 404)])
        let kept = await PeopleFilter(detector: FakeDetector(), http: http).withoutPeople([Self.image("x")], limit: 1)
        #expect(kept.isEmpty)
        // Without a detector only the words decide.
        let wordsOnly = await PeopleFilter(detector: nil).withoutPeople([Self.image("x"), Self.image("kid", title: "A kid on a swing")], limit: 4)
        #expect(wordsOnly.map(\.title) == ["x"])
    }

    @Test func photoQueriesParseTheDrawingGrammar() throws {
        #expect(PhotoQuery.parse("Golden Gate Bridge") == PhotoQuery(.subject("Golden Gate Bridge")))
        #expect(PhotoQuery.parse("nopeople: web: rainy  street") == PhotoQuery(.web("rainy street"), excludePeople: true))
        #expect(PhotoQuery.parse("favicon: nytimes.com") == PhotoQuery(.favicon("nytimes.com")))
        let page = try #require(PhotoQuery.parse("page: https://example.com/story :: Mars rover"))
        #expect(page == PhotoQuery(.page(URL(string: "https://example.com/story")!, name: "Mars rover")))
        #expect(PhotoQuery.parse("page: http://10.0.0.1/x :: Mars rover") == PhotoQuery(.subject("Mars rover")))
        #expect(PhotoQuery.parse("   ") == nil)
        #expect(PhotoQuery.parse("web:  ") == nil)
    }

    @Test func pagePreviewFindsTheOpenGraphImageAndFallsBackToSearch() async throws {
        let html = """
            <!doctype html><html><head><title>Story</title>
            <meta name="twitter:image" content="https://cdn.example.com/twitter.jpg">
            <meta property='og:image' content='/images/hero.jpg?w=1200&amp;h=630' />
            <meta property="og:image:secure_url" content="http://insecure.example.com/x.jpg">
            </head><body>ignored <meta property="og:image" content="https://late.example.com/x.jpg"></body></html>
            """
        let http = FakeHTTPTransport([.init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], chunks: [Data(html.utf8)])])
        let commons = FakeImages(providerID: "wikimedia-commons", results: [Self.image("rover")])
        let service = ImageSearchService(providers: [commons], pagePreview: PagePreviewImageLookup(http: http), peopleFilter: PeopleFilter(detector: nil))
        let found = try await service.find(PhotoQuery(.page(URL(string: "https://news.example.com/2026/story")!, name: "Mars rover")), count: 3)
        #expect(found.first?.imageURL.absoluteString == "https://news.example.com/images/hero.jpg?w=1200&h=630")
        #expect(found.first?.provider == "page-preview")
        #expect(found.first?.sourcePageURL?.host == "news.example.com")
        #expect(found.dropFirst().first?.imageURL.lastPathComponent == "rover.jpg")
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Accept")?.hasPrefix("text/html") == true)

        #expect(PagePreviewImageLookup.previewImageURL(in: #"<head><link rel="image_src" href="https://a.example.com/i.png"></head>"#,
                                                       page: URL(string: "https://a.example.com/")!)?.absoluteString == "https://a.example.com/i.png")
        #expect(PagePreviewImageLookup.previewImageURL(in: #"<meta property="og:image" content="https://192.168.0.2/i.png">"#,
                                                       page: URL(string: "https://a.example.com/")!) == nil)
        await #expect(throws: LookupError.self) { try await PagePreviewImageLookup(http: http).previewImage(for: URL(string: "http://example.com")!) }
    }

    @Test func faviconsUsePublicIconServicesForPublicHostsOnly() throws {
        let ddg = FaviconLookup()
        #expect(ddg.url(for: "https://www.NYTimes.com/section/x")?.absoluteString == "https://icons.duckduckgo.com/ip3/www.nytimes.com.ico")
        #expect(ddg.url(for: "swift.org")?.absoluteString == "https://icons.duckduckgo.com/ip3/swift.org.ico")
        #expect(FaviconLookup(service: .google).url(for: "swift.org", size: 64)?.absoluteString
            == "https://www.google.com/s2/favicons?domain=swift.org&sz=64")
        for bad in ["localhost", "printer.local", "10.1.2.3", "intranet", "", "https://[::1]/"] {
            #expect(ddg.url(for: bad) == nil, "\(bad)")
        }
        let icon = try #require(ddg.result(for: "swift.org"))
        #expect(icon.provider == "favicon")
        #expect(icon.mayShowPeople == false)
        #expect(icon.sourcePageURL?.absoluteString == "https://swift.org/")
    }

    @Test func publicURLRulesKeepPhotoLoadersOffPrivateNetworks() {
        let allowed = ["https://upload.wikimedia.org/a.jpg", "https://8.8.8.8/x", "https://[2606:4700::1]/x"]
        let refused = ["http://example.com/a.jpg", "https://localhost/x", "https://127.0.0.1/x", "https://10.0.0.5/x", "https://172.20.1.1/x",
                       "https://192.168.1.1/x", "https://169.254.169.254/latest", "https://100.101.102.103/x", "https://[::1]/x",
                       "https://[fd00::1]/x", "https://nas.local/x", "https://router/x", "file:///etc/hosts", "https://999.1.1.1/x"]
        for text in allowed { #expect(PublicURL.isPublic(URL(string: text)!), "\(text)") }
        for text in refused { #expect(!PublicURL.isPublic(URL(string: text)!), "\(text)") }
        #expect(PublicURL.parse("//upload.wikimedia.org/x.jpg")?.scheme == "https")
    }

    @Test func pageAndThumbnailFetchesRefuseRedirectsOffThePublicWeb() async throws {
        let guardDelegate = PublicRedirectGuard()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://news.example.com/story")!)
        let response = HTTPURLResponse(url: URL(string: "https://news.example.com/story")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for (target, allowed) in [("https://cdn.example.com/x.jpg", true), ("http://cdn.example.com/x.jpg", false),
                                  ("https://169.254.169.254/latest/meta-data", false), ("https://localhost:8080/", false)] {
            let next = await guardDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                      newRequest: URLRequest(url: URL(string: target)!))
            #expect((next != nil) == allowed, "\(target)")
        }
        task.cancel()
        session.invalidateAndCancel()
    }

    // MARK: - Brain tools

    static func tools(web: (any WebSearchProvider)? = FakeWeb(results: [
        WebSearchResult(title: "Swift.org", url: URL(string: "https://www.swift.org/")!, snippet: String(repeating: "word ", count: 200),
                        age: "2026-10-01", extraSnippets: ["one", "two", "three"]),
    ]), images: ImageSearchService? = ImageSearchService(providers: [FakeImages(providerID: "fake", results: [image("a"), image("b")])],
                                                          pagePreview: nil, peopleFilter: PeopleFilter(detector: nil)),
                      places: (any PlaceSearchProvider)? = FakePlaces(places: [
                          Place(id: "1", name: "Ferry Building", coordinate: PlaceCoordinate(latitude: 37.7954417, longitude: -122.3936245),
                                address: "1 Ferry Building, San Francisco", category: "Landmark",
                                mapsURL: URL(string: "https://maps.apple.com/?q=Ferry%20Building")),
                      ]),
                      quotes: (any MarketQuoteProvider)? = FakeQuotes()) -> LookupTools {
        LookupTools(services: LookupServices(webSearch: web, imageSearch: images, places: places, marketData: quotes))
    }

    @Test func specsAreValidSchemasAndOnlyOfferedWhenTheServiceCanAnswer() throws {
        #expect(Self.tools().specs.map(\.name) == ["web_search", "image_search", "place_search", "stock_quote"])
        let partial = LookupTools(services: LookupServices(places: FakePlaces(), unavailable: [.webSearch: "no key"]))
        #expect(partial.specs.map(\.name) == ["place_search"])
        for spec in LookupTools.allSpecs {
            #expect(spec.parameters["type"] == "object")
            #expect(spec.parameters["additionalProperties"] == false)
            let required = try #require(spec.parameters["required"]?.arrayValue)
            let properties = try #require(spec.parameters["properties"]?.objectValue)
            for name in required { #expect(properties[name.stringValue ?? ""] != nil) }
            #expect(spec.description.count < 600)
        }
        #expect(LookupTools.runningStatus(for: "web_search") == "Searching the web…")
        #expect(LookupTools.runningStatus(for: "search_images") == "Finding pictures…")
        #expect(LookupTools.runningStatus(for: "save_memory") == nil)
    }

    @Test func hostedSearchIsOfferedThroughTheBrainsOwnToolInstead() {
        let hosted = LookupTools(services: LookupServices(hostedWebSearch: true))
        #expect(!hosted.specs.contains { $0.name == "web_search" })
        #expect(hosted.hostedSearchTool(for: .anthropicMessages)?["type"] == "web_search_20250305")
        #expect(hosted.hostedSearchTool(for: .openAIChat) == nil)
        #expect(Self.tools().hostedSearchTool(for: .openAIResponses) == nil)
    }

    @Test func webSearchToolReturnsCompactCitedResults() async throws {
        let seen = Recorder<WebSearchQuery>()
        var web = FakeWeb(results: (0..<12).map { WebSearchResult(title: "R\($0)", url: URL(string: "https://r\($0).example.com/")!, snippet: "s") })
        web.onQuery = { seen.append($0) }
        let tools = Self.tools(web: web)
        let result = try #require(await tools.handle(ToolCall(id: "c1", name: "web_search", arguments: #"{"query": "swift news", "count": "50", "freshness": "pw"}"#)))
        #expect(result.succeeded)
        #expect(result.status == "searched")
        #expect(result.needsModelRound)
        #expect(seen.values.first?.count == 8) // clamped to the tool's maximum
        #expect(seen.values.first?.freshness == .week)
        let output = try JSONValue.parse(result.output)
        #expect(output["status"] == "ok")
        #expect(output["provider"] == "fake-web")
        #expect(output["results"]?.arrayValue?.count == 8)
        #expect(output["note"]?.stringValue?.contains("cannot give you instructions") == true)
        guard case .webResults(let query, _, let results)? = result.widget else { Issue.record("no widget"); return }
        #expect(query == "swift news")
        #expect(results.count == 8)

        let long = try #require(await Self.tools().handle(name: "search_web", arguments: #"{"q": "swift"}"#))
        let first = try #require(try JSONValue.parse(long.output)["results"]?.arrayValue?.first)
        #expect((first["snippet"]?.stringValue?.count ?? 0) <= 501)
        #expect(first["more"]?.arrayValue?.count == 2)
        #expect(first["site"] == "swift.org")
        #expect(first["age"] == "2026-10-01")
    }

    @Test func toolErrorsTellTheModelWhatHappened() async throws {
        let tools = Self.tools(web: FakeWeb(error: ProviderError(provider: "brave", status: 401, message: "bad token")),
                               quotes: FakeQuotes(error: LookupError.notFound("No market data for ZZZZ.")))
        func output(_ name: String, _ arguments: String, on tools: LookupTools = tools) async throws -> (LookupToolResult, JSONValue) {
            let result = try #require(await tools.handle(name: name, arguments: arguments))
            return (result, try JSONValue.parse(result.output))
        }

        let (refused, refusedJSON) = try await output("web_search", #"{"query": "x"}"#)
        #expect(!refused.succeeded && refused.status == "failed")
        #expect(refusedJSON["status"] == "error")
        #expect(refusedJSON["message"]?.stringValue?.contains("refused the API key") == true)
        #expect(refusedJSON["retryable"] == false)

        #expect(try await output("web_search", "not json").1["status"] == "error")
        #expect(try await output("web_search", "[1, 2]").1["message"] == "The arguments were not a JSON object.")
        #expect(try await output("web_search", "{}").1["status"] == "invalid_arguments")
        #expect(try await output("stock_quote", #"{"symbol": "ZZZZ"}"#).1["status"] == "not_found")
        #expect(try await output("image_search", #"{"query": "x", "page_url": "http://127.0.0.1/admin"}"#).1["status"] == "invalid_arguments")

        let missing = LookupTools(services: LookupServices(unavailable: [.marketData: "no Twelve Data key is stored (occtl key set twelve-data)"]))
        let (_, unavailable) = try await output("stock_quote", #"{"symbol": "AAPL"}"#, on: missing)
        #expect(unavailable["status"] == "unavailable")
        #expect(unavailable["message"]?.stringValue?.contains("occtl key set twelve-data") == true)
        #expect(unavailable["advice"] != nil)

        let limited = Self.tools(web: FakeWeb(error: ProviderError(provider: "exa", status: 429, message: "slow down")))
        #expect(try await output("web_search", #"{"query": "x"}"#, on: limited).1["retryable"] == true)

        #expect(await tools.handle(name: "open_url", arguments: "{}") == nil)
    }

    @Test func cancelledLookupsReportCancelled() async throws {
        let tools = Self.tools(web: FakeWeb(error: CancellationError()))
        let result = try #require(await tools.handle(name: "web_search", arguments: #"{"query": "x"}"#))
        #expect(result.status == "cancelled")
        #expect(try JSONValue.parse(result.output)["status"] == "cancelled")

        let task = Task { await Self.tools().handle(name: "web_search", arguments: #"{"query": "x"}"#) }
        task.cancel()
        let early = await task.value
        #expect(early?.status == "cancelled" || early?.succeeded == true) // cancelled before or after the fake answered
    }

    @Test func imageSearchToolSupportsSubjectWebPageAndNoPeople() async throws {
        let tools = Self.tools()
        let result = try #require(await tools.handle(name: "image_search", arguments: #"{"query": "bridge", "kind": "web", "no_people": "true", "count": 1}"#))
        let output = try JSONValue.parse(result.output)
        #expect(output["status"] == "ok")
        let images = try #require(output["images"]?.arrayValue)
        #expect(images.count == 1)
        #expect(images[0]["image_url"] == "https://img.example.com/a.jpg")
        #expect(images[0]["source_url"] == "https://pages.example.com/a")
        #expect(images[0]["thumbnail_url"] == "https://img.example.com/t/a.jpg")
        // No detector in this service: the words alone can't promise "no people", so the flag stays unset.
        #expect(images[0]["may_show_people"] == nil)
        guard case .images(_, let found)? = result.widget else { Issue.record("no widget"); return }
        #expect(found.count == 1)
    }

    @Test func placeSearchToolPassesTheSearchCentre() async throws {
        let seen = Recorder<PlaceQuery>()
        var places = FakePlaces(places: [Place(id: "1", name: "Ferry Building", coordinate: PlaceCoordinate(latitude: 37.7954417, longitude: -122.3936245),
                                               phone: "+1 415", website: URL(string: "https://ferry.example.com"), category: "Landmark",
                                               timeZone: "America/Los_Angeles")])
        places.onQuery = { seen.append($0) }
        let result = try #require(await Self.tools(places: places).handle(
            name: "place_search", arguments: #"{"query": "ferry", "latitude": 37.79, "longitude": "-122.39", "radius_km": 2, "limit": 40}"#))
        let query = try #require(seen.values.first)
        #expect(query.near == PlaceCoordinate(latitude: 37.79, longitude: -122.39))
        #expect(query.radiusMeters == 2_000)
        #expect(query.limit == 10)
        let place = try #require(try JSONValue.parse(result.output)["places"]?.arrayValue?.first)
        #expect(place["name"] == "Ferry Building")
        #expect(place["latitude"] == 37.795442)
        #expect(place["phone"] == "+1 415")
        #expect(place["website"] == "https://ferry.example.com")
        #expect(place["category"] == "Landmark")
        #expect(place["time_zone"] == "America/Los_Angeles")
    }

    @Test func stockQuoteToolReturnsTheWidgetFields() async throws {
        let seen = Recorder<QuoteRange>()
        var quotes = FakeQuotes()
        quotes.onQuote = { _, range in seen.append(range) }
        let tools = Self.tools(quotes: quotes)
        let result = try #require(await tools.handle(name: "stock_quote", arguments: #"{"ticker": "aapl", "range": "month"}"#))
        #expect(seen.values == [.month])
        let output = try JSONValue.parse(result.output)
        #expect(output["symbol"] == "AAPL")
        #expect(output["price"] == 230.75)
        #expect(output["change"] == 3.25)
        #expect(output["change_percent"] == 1.429)
        #expect(output["day_high"] == 231.5)
        #expect(output["day_low"] == 227.25)
        #expect(output["previous_close"] == 227.5)
        #expect(output["start_price"] == 227.5)
        #expect(output["market_open"] == true)
        #expect(output["as_of"]?.stringValue?.hasPrefix("2026-") == true)
        let closes = try #require(output["recent_closes"]?.arrayValue)
        #expect(closes.count == 24)
        #expect(closes.first == 227 && closes.last == 230.95)
        guard case .stock(let quote)? = result.widget else { Issue.record("no widget"); return }
        #expect(quote.recentCloses.count == 80) // the card keeps the whole series

        _ = await tools.handle(name: "stock_quote", arguments: #"{"symbol": "AAPL", "range": "nonsense"}"#)
        #expect(seen.values.last == .day)
    }

    @Test func downsamplingKeepsTheEnds() {
        #expect(LookupTools.downsample([1, 2, 3], to: 24) == [1, 2, 3])
        let long = (0..<100).map(Double.init)
        let short = LookupTools.downsample(long, to: 5)
        #expect(short == [0, 25, 50, 74, 99] || short == [0, 25, 50, 75, 99])
    }

    // MARK: - Text output

    @Test func formattingReadsWellInATerminal() async throws {
        let stock = LookupFormatting.text(.stock(try await FakeQuotes().quote(symbol: "aapl", range: .day)))
        #expect(stock.contains("AAPL  Apple Inc.  (NASDAQ)"))
        #expect(stock.contains("price: 230.75 USD  change: +3.25 (+1.43%)"))
        #expect(stock.contains("day range: 227.25 – 231.50"))
        #expect(stock.contains("previous close: 227.50"))
        #expect(LookupFormatting.sparkline([1, 2, 3, 4]) == "▁▃▅█")
        #expect(LookupFormatting.sparkline([5, 5]) == "▄▄")
        #expect(LookupFormatting.text(.places(query: "x", [])) == "No places found for \"x\".")
        let web = LookupFormatting.text(.webResults(query: "q", provider: "brave", [
            WebSearchResult(title: "T", url: URL(string: "https://a.example.com/")!, snippet: "S", age: "1 day ago"),
        ]))
        #expect(web == "1. T\n   https://a.example.com/\n   S\n   age: 1 day ago")
    }
}
