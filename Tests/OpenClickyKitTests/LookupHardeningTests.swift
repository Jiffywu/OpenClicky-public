import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenClickyKit

/// Regression tests from the lookups review: input a model or a server controls must never crash the app, the
/// public-web guards must hold against every way of writing a private address, keys stay off cleartext links and out
/// of printed values, and cancellation reaches the caller.
@Suite struct LookupHardeningTests {
    typealias Fixtures = LookupServicesTests

    // MARK: - Numbers outside Int's range

    @Test func toolArgumentsOutsideIntRangeAreClampedNotFatal() async throws {
        let webQueries = Fixtures.Recorder<WebSearchQuery>()
        let placeQueries = Fixtures.Recorder<PlaceQuery>()
        let symbols = Fixtures.Recorder<String>()
        let tools = Fixtures.tools(
            web: Fixtures.FakeWeb(results: [], onQuery: { webQueries.append($0) }),
            places: Fixtures.FakePlaces(onQuery: { placeQueries.append($0) }),
            quotes: Fixtures.FakeQuotes(onQuote: { symbol, _ in symbols.append(symbol) }))

        let web = await tools.handle(name: "web_search", arguments: #"{"query": "swift", "count": 1e300}"#)
        #expect(web?.succeeded == true)
        #expect(webQueries.values.last?.count == tools.maxWebResults)

        let negative = await tools.handle(name: "web_search", arguments: #"{"query": "swift", "count": "-9e99"}"#)
        #expect(negative?.succeeded == true)
        #expect(webQueries.values.last?.count == 1)

        let images = await tools.handle(name: "image_search", arguments: #"{"query": "bridge", "count": 1e20}"#)
        #expect(images?.succeeded == true)

        let places = await tools.handle(name: "place_search", arguments: #"{"query": "cafe", "limit": 1e300, "radius_km": 1e300}"#)
        #expect(places?.succeeded == true)
        #expect(placeQueries.values.last?.limit == tools.maxPlaces)

        // A number where text is expected is read as text, never through a trapping Int conversion.
        let stock = await tools.handle(name: "stock_quote", arguments: #"{"symbol": 1e300}"#)
        #expect(stock != nil)
        let small = await tools.handle(name: "stock_quote", arguments: #"{"symbol": 7203}"#)
        #expect(small?.succeeded == true)
        #expect(symbols.values.last == "7203")
    }

    @Test func providerNumbersOutsideIntRangeAreDroppedNotFatal() throws {
        let brave = try JSONValue.parse("""
            {"results": [{"title": "Bridge", "url": "https://pages.example.com/b",
              "thumbnail": {"src": "https://imgs.search.brave.com/t.jpg", "width": 1e300, "height": -1e300},
              "properties": {"url": "https://cdn.example.com/b.jpg", "width": 1e300, "height": "1e40"}}]}
            """)
        let braveImages = BraveImageSearch.results(from: brave)
        #expect(braveImages.count == 1)
        #expect(braveImages.first?.width == nil)
        #expect(braveImages.first?.height == nil)

        let commons = try JSONValue.parse("""
            {"query": {"pages": [
              {"index": 1e300, "title": "File:A.jpg", "imageinfo": [{"url": "https://upload.wikimedia.org/a.jpg",
                "descriptionurl": "https://commons.wikimedia.org/wiki/File:A.jpg", "thumburl": "https://upload.wikimedia.org/t/a.jpg",
                "size": 1e300, "width": 1e300, "height": 600, "mime": "image/jpeg"}]},
              {"index": 2, "title": "File:B.jpg", "imageinfo": [{"url": "https://upload.wikimedia.org/b.jpg",
                "thumburl": "https://upload.wikimedia.org/t/b.jpg", "size": 1000, "width": 800, "height": 600, "mime": "image/jpeg"}]}
            ]}}
            """)
        let found = WikimediaCommonsImageSearch().results(from: commons)
        #expect(found.map(\.title) == ["B", "A"])
        // An absurd byte count is not "small enough": the scaled rendition is used instead of the original.
        #expect(found.last?.imageURL.absoluteString == "https://upload.wikimedia.org/t/a.jpg")
    }

    @Test func twelveDataErrorCodesOutsideIntRangeAreNotFatal() async throws {
        let fake = FakeHTTPTransport([.body(#"{"code": 1e300, "message": "odd", "status": "error"}"#)])
        let quotes = TwelveDataQuotes(endpoint: LookupEndpoint(baseURL: TwelveDataQuotes.defaultBaseURL, apiKey: "k-1234567", http: fake))
        await #expect(throws: ProviderError.self) { try await quotes.quote(symbol: "AAPL", range: .day) }
    }

    // MARK: - Public-web rules

    @Test func publicURLRefusesEveryWayOfWritingAPrivateAddress() {
        let refused = [
            // IPv4 shorthand, hex and octal forms the system resolver accepts (127.1 and 0x7f.0.0.1 are loopback).
            "https://127.1/x", "https://0x7f.0.0.1/x", "https://0x7f000001/x", "https://0177.0.0.1/x", "https://010.0.0.1/x",
            "https://127.0.0.1./x", "https://192.168.1.1../x",
            // Uncompressed, IPv4-compatible, IPv4-mapped, NAT64, site-local, multicast, zoned and unspecified IPv6.
            "https://[0:0:0:0:0:0:0:1]/x", "https://[0000::0001]/x", "https://[::127.0.0.1]/x", "https://[::ffff:127.0.0.1]/x",
            "https://[::ffff:7f00:1]/x", "https://[64:ff9b::a00:1]/x", "https://[fec0::1]/x", "https://[ff02::1]/x",
            "https://[fe80::1%25en0]/x", "https://[::]/x", "https://[2002:c0a8:101::1]/x",
            // Reserved and documentation IPv4 ranges.
            "https://198.18.0.1/x", "https://192.0.2.10/x", "https://192.0.0.1/x", "https://203.0.113.5/x", "https://0.0.0.0/x",
        ]
        for text in refused { #expect(!PublicURL.isPublic(URL(string: text)!), "\(text)") }

        let allowed = ["https://8.8.8.8/x", "https://1.1.1.1/x", "https://[2606:4700:4700::1111]/x", "https://[2001:4860::8888]/x",
                       "https://1password.com/x", "https://123.example.org/x", "https://upload.wikimedia.org/a.jpg",
                       "https://swift.org./x"]
        for text in allowed { #expect(PublicURL.isPublic(URL(string: text)!), "\(text)") }
    }

    /// The redirect guard must be the delegate a real URLSession consults, for whole bodies and for streams.
    @Test func publicWebOnlySessionStopsARealRedirectOffThePublicWeb() async throws {
        // Every path this test asks for sits under its own prefix. Under the parallel suite, or with other test runs on
        // the machine, a straggling connection meant for someone else can land on this recycled loopback port (seen
        // as a stray "GET /"); it isn't a request from us and mustn't count.
        let ours = "/\(UUID().uuidString)"
        let paths = Fixtures.Recorder<String>()
        let server = LoopbackHTTPServer { request in
            guard request.path.hasPrefix(ours + "/") else { return HTTPResponse(status: 404) }
            paths.append(String(request.path.dropFirst(ours.count)))
            if request.path.hasPrefix(ours + "/start") {
                return HTTPResponse(status: 302, headers: ["Location": ours + "/secret"], body: Data())
            }
            return HTTPResponse(status: 200, headers: ["Content-Type": "text/plain"], body: Data("secret".utf8))
        }
        let port = try server.start()
        defer { server.stop() }
        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(ours)\(path)")! }

        // Control: an ordinary session follows the redirect, so the server really redirects.
        let plain = URLSessionTransport(session: URLSession(configuration: .ephemeral))
        let (_, followed) = try await plain.data(for: URLRequest(url: url("/start-control")))
        #expect(followed.statusCode == 200)
        #expect(paths.values == ["/start-control", "/secret"])

        let guarded = URLSessionTransport.publicWebOnly
        let (body, response) = try await guarded.data(for: URLRequest(url: url("/start-data")))
        #expect(response.statusCode == 302)
        #expect(String(decoding: body, as: UTF8.self) != "secret")

        let (stream, streamed) = try await guarded.stream(for: URLRequest(url: url("/start-stream")))
        for try await _ in stream {}
        #expect(streamed.statusCode == 302)
        #expect(paths.values == ["/start-control", "/secret", "/start-data", "/start-stream"])
    }

    // MARK: - Keys

    @Test func keysAreNeverSentOverPlainHTTPToARemoteHost() {
        let credentials = InMemoryCredentialStore(["brave": "brave-key-1234", "twelve-data": "td-key-1234"])
        var config = ServicesConfig.defaults
        config.services[.webSearch] = ServiceChoice(provider: .brave, baseURL: URL(string: "http://search-proxy.example.com/res/v1"))
        config.services[.marketData] = ServiceChoice(provider: .twelveData, baseURL: URL(string: "https://192.168.1.20/td"))
        let services = LookupServices.make(config: config, credentials: credentials, http: FakeHTTPTransport([]),
                                           mapKit: LookupAdapterTests.FakeMapKit(items: []), peopleDetector: nil)
        #expect(services.webSearch == nil)
        #expect(services.unavailable[.webSearch]?.contains("https") == true)
        #expect(services.marketData != nil) // https to a LAN proxy is encrypted, so it may carry the key
        // The issue list says the same thing as the factory.
        #expect(config.issues(credentials: credentials).contains { $0.service == .webSearch && $0.severity == .error })

        // https anywhere public, and plain http to this Mac, are fine.
        config.services[.webSearch] = ServiceChoice(provider: .brave, baseURL: URL(string: "https://search-proxy.example.com/res/v1"))
        config.services[.marketData] = ServiceChoice(provider: .twelveData, baseURL: URL(string: "http://[::1]:8080/td"))
        let fixed = LookupServices.make(config: config, credentials: credentials, http: FakeHTTPTransport([]),
                                        mapKit: LookupAdapterTests.FakeMapKit(items: []), peopleDetector: nil)
        #expect(fixed.webSearch != nil)
        #expect(fixed.marketData != nil)
        #expect(!config.issues(credentials: credentials).contains { $0.severity == .error })
    }

    @Test func anEndpointNeverPrintsItsKey() {
        let key = "endpoint-secret-key-98765"
        let endpoint = LookupEndpoint(baseURL: URL(string: "https://user:pass@api.example.com/v1?token=abc")!, apiKey: key,
                                      http: FakeHTTPTransport([]))
        var dumped = ""
        dump(endpoint, to: &dumped)
        let texts = [String(describing: endpoint), String(reflecting: endpoint), "\(endpoint)", dumped,
                     String(describing: BraveWebSearch(endpoint: endpoint))]
        for text in texts {
            #expect(!text.contains(key), "\(text)")
            #expect(!text.contains("pass"), "\(text)")
            #expect(!text.contains("abc"), "\(text)")
        }
        #expect(String(describing: endpoint).contains("api.example.com"))
    }

    // MARK: - Cancellation and repeated work

    /// A detector that never finishes on its own; it ends when its task is cancelled.
    struct HangingDetector: PeopleDetecting {
        func containsPeople(_ imageData: Data) async throws -> Bool {
            try await Task.sleep(for: .seconds(30))
            return false
        }
    }

    @Test func cancellingANoPeopleSearchReportsCancellationNotNoResults() async throws {
        let fake = FakeHTTPTransport((0..<6).map { _ in .body("thumbnail", contentType: "image/jpeg") })
        let service = ImageSearchService(
            providers: [Fixtures.FakeImages(providerID: "only", results: [Fixtures.image("a"), Fixtures.image("b")])],
            pagePreview: nil, peopleFilter: PeopleFilter(detector: HangingDetector(), http: fake))
        let task = Task { try await service.search(ImageSearchQuery("tower", count: 2, excludePeople: true)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        let tools = LookupTools(services: LookupServices(imageSearch: service))
        let toolTask = Task { await tools.handle(name: "image_search", arguments: #"{"query": "tower", "no_people": true}"#) }
        try await Task.sleep(for: .milliseconds(100))
        toolTask.cancel()
        let result = await toolTask.value
        #expect(result?.status == "cancelled")
    }

    final class CountingImages: ImageSearchProvider, @unchecked Sendable {
        let providerID = "counting"
        let modes: Set<ImageSearchQuery.Mode> = [.subject, .web]
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func searchImages(_ query: ImageSearchQuery) async throws -> [ImageResult] {
            lock.withLock { count += 1 }
            return []
        }
    }

    @Test func aPageQueryWithNothingFoundSearchesOnce() async throws {
        let provider = CountingImages()
        // The page has no preview picture.
        let page = FakeHTTPTransport([.body("<html><head><title>x</title></head></html>", contentType: "text/html")])
        let service = ImageSearchService(providers: [provider], pagePreview: PagePreviewImageLookup(http: page),
                                         peopleFilter: PeopleFilter(detector: nil))
        let found = try await service.find(PhotoQuery(.page(URL(string: "https://news.example.com/a")!, name: "Some bridge")))
        #expect(found.isEmpty)
        #expect(provider.calls == 1)
    }

    // MARK: - Page previews

    @Test func pagePreviewFindsTheHeadEndWhenItIsSplitAcrossChunks() async throws {
        let head = #"<html><head><meta property="og:image" content="https://cdn.example.com/lead.jpg"></he"#
        // After the head: a body far bigger than the read limit, in many small chunks.
        var chunks = [Data(head.utf8), Data("ad>\n".utf8)]
        chunks += (0..<5_000).map { _ in Data("<p>filler line</p>\n".utf8) }
        let fake = FakeHTTPTransport([.init(headers: ["Content-Type": "text/html; charset=utf-8"], chunks: chunks)])
        let lookup = PagePreviewImageLookup(http: fake, maxBytes: 4_096)
        let image = try await lookup.previewImage(for: URL(string: "https://news.example.com/story")!)
        #expect(image?.imageURL.absoluteString == "https://cdn.example.com/lead.jpg")
        #expect(PagePreviewImageLookup.headEnds(in: Data("x</HEAD>".utf8), searchingFrom: 0))
        #expect(PagePreviewImageLookup.headEnds(in: Data("</he".utf8) + Data("ad>".utf8), searchingFrom: 4))
        #expect(!PagePreviewImageLookup.headEnds(in: Data("<header>".utf8), searchingFrom: 0))
    }

    // MARK: - People check on device

    static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func peopleDetectorScalesLargeImagesAndRefusesHugeOrBrokenOnes() async throws {
        let wide = try Self.png(width: 3_000, height: 200)
        let prepared = try VisionPeopleDetector.preparedImage(from: wide, maxPixels: 40_000_000, maxSide: 1_024)
        #expect(max(prepared.width, prepared.height) <= 1_024)

        // Bigger than allowed by its header: refused before anything decodes it.
        let detector = VisionPeopleDetector(maxPixels: 100_000)
        await #expect(throws: VisionPeopleDetector.ImageError.self) { _ = try await detector.containsPeople(try Self.png(width: 400, height: 400)) }
        await #expect(throws: VisionPeopleDetector.ImageError.self) { _ = try await detector.containsPeople(Data("not an image".utf8)) }

        // A plain picture with nobody in it passes.
        #expect(try await VisionPeopleDetector().containsPeople(try Self.png(width: 320, height: 240)) == false)
    }

    // MARK: - services.json

    /// The docs promise that a service the file leaves out gets its default; that includes leaving them all out.
    @Test func aServicesFileWithoutServicesOrVersionMeansTheDefaults() throws {
        let url = Fixtures.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data("{}".utf8).write(to: url)
        let empty = try ServicesConfig.load(from: url)
        #expect(empty.version == 1)
        for service in LookupService.allCases { #expect(empty.choice(for: service) == service.defaultChoice) }

        try Data(#"{"detectPeople": false}"#.utf8).write(to: url)
        let toggles = try ServicesConfig.load(from: url)
        #expect(toggles.detectPeople == false)
        #expect(toggles.choice(for: .places).provider == .mapKit)

        // Still strict about what it does say.
        try Data(#"{"services": {"places": {"provider": "carrier-pigeon"}}}"#.utf8).write(to: url)
        #expect(throws: LookupError.self) { try ServicesConfig.load(from: url) }
    }

    // MARK: - Hosted search honesty

    @Test func hostedSearchSaysWebSearchIsOffUntilTheBrainPassesItThrough() {
        var config = ServicesConfig.defaults
        config.services[.webSearch] = ServiceChoice(provider: .brainHosted)
        let issues = config.issues(credentials: InMemoryCredentialStore(), brainDialect: .anthropicMessages)
        if HostedWebSearch.brainPassesHostedTools {
            #expect(!issues.contains { $0.service == .webSearch })
        } else {
            #expect(issues.contains { $0.service == .webSearch && $0.severity == .warning && $0.message.contains("Brave") })
        }
    }
}
