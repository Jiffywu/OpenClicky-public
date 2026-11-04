import Foundation
import Testing
@testable import OpenClickyKit

/// Lookup adapters scripted with the response shapes each API documents (Brave Search web and image references,
/// https://docs.exa.ai/reference/search, https://docs.tavily.com/documentation/api-reference/endpoint/search,
/// the MediaWiki Action API with formatversion=2, https://twelvedata.com/docs). No network, no real keys.
@Suite struct LookupAdapterTests {
    static let key = "lookup-test-key-not-real-1234"

    static func endpoint(_ fake: FakeHTTPTransport, base: URL, key: String? = key) -> LookupEndpoint {
        LookupEndpoint(baseURL: base, apiKey: key, http: fake)
    }

    static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    // MARK: - Brave web search

    static let braveWeb = """
        {"type": "search", "query": {"original": "swift 6 release"},
         "web": {"type": "search", "family_friendly": true, "results": [
           {"type": "search_result", "title": "Announcing <strong>Swift 6</strong>",
            "url": "https://www.swift.org/blog/announcing-swift-6/",
            "description": "Swift 6 brings <strong>data-race</strong> safety &amp; much more &#39;by default&#39;.",
            "age": "2 days ago", "page_age": "2026-10-28T09:00:00", "language": "en",
            "meta_url": {"scheme": "https", "netloc": "swift.org", "hostname": "www.swift.org", "path": "› blog"},
            "extra_snippets": ["Complete concurrency checking is on.", "<b>Typed</b> throws arrive."]},
           {"type": "search_result", "title": "", "url": "http://example.org/old", "description": "Plain http is fine for a link.",
            "page_age": "2025-01-02T00:00:00"},
           {"type": "search_result", "title": "Not a web link", "url": "ftp://files.example.org/x", "description": "dropped"}
         ]}}
        """

    @Test func braveWebSendsTheDocumentedRequestAndKeepsTheKeyOutOfTheURL() async throws {
        let fake = FakeHTTPTransport([.body(Self.braveWeb)])
        let search = BraveWebSearch(endpoint: Self.endpoint(fake, base: BraveWebSearch.defaultBaseURL))
        let results = try await search.search(WebSearchQuery("  swift 6\n release ", count: 50, freshness: .week))

        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/res/v1/web/search")
        #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == Self.key)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("OpenClicky/") == true)
        let query = Self.query(request)
        #expect(query["q"] == "swift 6 release")
        #expect(query["count"] == "20") // Brave allows at most 20
        #expect(query["freshness"] == "pw")
        #expect(query["extra_snippets"] == "true")
        #expect(!(request.url?.absoluteString.contains(Self.key) ?? true))

        #expect(results.count == 2)
        #expect(results[0].title == "Announcing Swift 6")
        #expect(results[0].snippet == "Swift 6 brings data-race safety & much more 'by default'.")
        #expect(results[0].age == "2 days ago")
        #expect(results[0].extraSnippets == ["Complete concurrency checking is on.", "Typed throws arrive."])
        #expect(results[0].site == "swift.org")
        #expect(results[1].title == "example.org") // empty title falls back to the host
        #expect(results[1].age == "2025-01-02") // page_age when there is no age text
    }

    @Test func braveFreshnessCodesMatchTheDocs() {
        #expect(BraveWebSearch.freshnessCode(.any) == nil)
        #expect(BraveWebSearch.freshnessCode(.day) == "pd")
        #expect(BraveWebSearch.freshnessCode(.month) == "pm")
        #expect(BraveWebSearch.freshnessCode(.year) == "py")
    }

    @Test func braveWithoutAKeyFailsBeforeTouchingTheNetwork() async throws {
        let fake = FakeHTTPTransport([])
        let search = BraveWebSearch(endpoint: Self.endpoint(fake, base: BraveWebSearch.defaultBaseURL, key: "  "))
        await #expect(throws: LookupError.unavailable(service: "Web search", reason: "no Brave Search API key is stored")) {
            try await search.search(WebSearchQuery("anything"))
        }
        #expect(fake.requests.isEmpty)
    }

    @Test func braveBlankQueryIsRejected() async throws {
        let fake = FakeHTTPTransport([])
        let search = BraveWebSearch(endpoint: Self.endpoint(fake, base: BraveWebSearch.defaultBaseURL))
        await #expect(throws: LookupError.self) { try await search.search(WebSearchQuery(" \n\t ")) }
        #expect(fake.requests.isEmpty)
    }

    @Test func braveErrorBodyBecomesAProviderErrorWithTheKeyRedacted() async throws {
        let body = """
            {"type": "ErrorResponse", "error": {"id": "e-1", "status": 401, "code": "SUBSCRIPTION_TOKEN_INVALID",
             "detail": "The provided subscription token \(Self.key) is invalid.", "meta": {}}, "time": 1}
            """
        let fake = FakeHTTPTransport([.body(body, status: 401)])
        let search = BraveWebSearch(endpoint: Self.endpoint(fake, base: BraveWebSearch.defaultBaseURL))
        do {
            _ = try await search.search(WebSearchQuery("x"))
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.status == 401)
            #expect(error.provider == "brave")
            #expect(error.message.contains("is invalid"))
            #expect(!error.description.contains(Self.key))
            #expect(error.message.contains("[redacted]"))
        }
    }

    @Test func adaptersDoNotLeakTheKeyThroughDescriptions() {
        let fake = FakeHTTPTransport([])
        let endpoint = Self.endpoint(fake, base: BraveWebSearch.defaultBaseURL)
        let described = [String(describing: BraveWebSearch(endpoint: endpoint)), String(reflecting: BraveImageSearch(endpoint: endpoint)),
                         String(describing: ExaWebSearch(endpoint: endpoint)), String(describing: TavilyWebSearch(endpoint: endpoint)),
                         String(describing: TwelveDataQuotes(endpoint: endpoint)), "\(TwelveDataQuotes(endpoint: endpoint))"]
        for text in described { #expect(!text.contains(Self.key)) }
    }

    @Test func unreadableBodyIsReportedWithoutCrashing() async throws {
        let fake = FakeHTTPTransport([.body("<html>gateway</html>", contentType: "text/html")])
        let search = BraveWebSearch(endpoint: Self.endpoint(fake, base: BraveWebSearch.defaultBaseURL))
        await #expect(throws: ProviderError.self) { try await search.search(WebSearchQuery("x")) }
    }

    // MARK: - Brave image search

    static let braveImages = """
        {"type": "images", "query": {"original": "golden gate bridge"}, "results": [
          {"type": "image_result", "title": "Golden Gate Bridge at sunset", "url": "https://travel.example.com/sf/golden-gate",
           "source": "travel.example.com", "page_fetched": "2026-09-01T00:00:00Z",
           "thumbnail": {"src": "https://imgs.search.brave.com/abc/rs:fit:500:0/g.jpg", "width": 500, "height": 333},
           "properties": {"url": "https://travel.example.com/img/golden-gate.jpg", "placeholder": "https://imgs.search.brave.com/ph",
                          "width": 1600, "height": 1066},
           "meta_url": {"scheme": "https", "netloc": "travel.example.com", "hostname": "travel.example.com",
                        "favicon": "https://imgs.search.brave.com/fav"}, "confidence": "high"},
          {"type": "image_result", "title": "LAN camera", "url": "https://intranet.example.com/x",
           "thumbnail": {"src": "http://10.0.0.2/t.jpg"}, "properties": {"url": "http://192.168.1.4/a.jpg"}},
          {"type": "image_result", "title": "Only a thumbnail", "url": "https://b.example.com/p",
           "thumbnail": {"src": "https://imgs.search.brave.com/def/t.jpg", "width": 500, "height": 500},
           "properties": {"url": "http://b.example.com/insecure.jpg"}}
        ]}
        """

    @Test func braveImagesKeepPublicHTTPSImagesAndTheirPages() async throws {
        let fake = FakeHTTPTransport([.body(Self.braveImages)])
        let search = BraveImageSearch(endpoint: Self.endpoint(fake, base: BraveWebSearch.defaultBaseURL))
        let images = try await search.searchImages(ImageSearchQuery("golden gate bridge", count: 5, mode: .web))

        let request = try #require(fake.requests.first)
        #expect(request.url?.path == "/res/v1/images/search")
        #expect(Self.query(request)["safesearch"] == "strict")
        #expect(Self.query(request)["count"] == "5")
        #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == Self.key)

        #expect(images.count == 2)
        #expect(images[0].imageURL.absoluteString == "https://travel.example.com/img/golden-gate.jpg")
        #expect(images[0].thumbnailURL?.host == "imgs.search.brave.com")
        #expect(images[0].sourcePageURL?.absoluteString == "https://travel.example.com/sf/golden-gate")
        #expect(images[0].width == 1600 && images[0].height == 1066)
        #expect(images[0].credit == "travel.example.com")
        // An http original falls back to Brave's https thumbnail, with the thumbnail's size.
        #expect(images[1].imageURL.absoluteString == "https://imgs.search.brave.com/def/t.jpg")
        #expect(images[1].width == 500)
        #expect(images.allSatisfy { PublicURL.isPublic($0.imageURL) })
    }

    // MARK: - Exa

    static let exaResponse = """
        {"requestId": "b5947044c4b78efa9552a7c89b306d95", "resolvedSearchType": "neural",
         "results": [
           {"title": "Swift 6 concurrency guide", "url": "https://blog.example.com/swift-6", "id": "https://blog.example.com/swift-6",
            "publishedDate": "2026-10-12T00:00:00.000Z", "author": "A. Writer", "image": "https://blog.example.com/cover.png",
            "favicon": "https://blog.example.com/favicon.ico",
            "highlights": ["Strict   concurrency is the default in the Swift 6 language mode.", "Sendable checking catches races."],
            "highlightScores": [0.61, 0.48]},
           {"title": null, "url": "https://exa.ai/notes", "id": "x", "publishedDate": null, "summary": "A short summary of the page."},
           {"title": "No URL", "id": "y"}
         ],
         "searchTime": 412.5, "costDollars": {"total": 0.005, "search": {"neural": 0.005}}}
        """

    @Test func exaPostsTheDocumentedBodyAndReadsHighlights() async throws {
        let fake = FakeHTTPTransport([.body(Self.exaResponse)])
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let search = ExaWebSearch(endpoint: Self.endpoint(fake, base: ExaWebSearch.defaultBaseURL), now: { now })
        let results = try await search.search(WebSearchQuery("swift 6 concurrency", count: 3, freshness: .month))

        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.exa.ai/search")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == Self.key)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try fake.jsonBody()
        #expect(body["query"] == "swift 6 concurrency")
        #expect(body["type"] == "auto")
        #expect(body["numResults"] == 3)
        #expect(body["contents"]?["highlights"]?["maxCharacters"] == 600)
        let start = try #require(body["startPublishedDate"]?.stringValue)
        #expect(start == LookupDates.iso(now.addingTimeInterval(-31 * 86_400)))

        #expect(results.count == 2)
        #expect(results[0].snippet == "Strict concurrency is the default in the Swift 6 language mode.")
        #expect(results[0].extraSnippets == ["Sendable checking catches races."])
        #expect(results[0].age == "2026-10-12")
        #expect(results[1].title == "exa.ai")
        #expect(results[1].snippet == "A short summary of the page.")
        #expect(results[1].age == nil)
    }

    @Test func exaWithoutFreshnessSendsNoDate() async throws {
        let fake = FakeHTTPTransport([.body(#"{"requestId": "r", "results": []}"#)])
        let search = ExaWebSearch(endpoint: Self.endpoint(fake, base: ExaWebSearch.defaultBaseURL))
        let results = try await search.search(WebSearchQuery("x"))
        #expect(results.isEmpty)
        #expect(try fake.jsonBody()["startPublishedDate"] == nil)
    }

    @Test func exaErrorShapeIsRead() async throws {
        let fake = FakeHTTPTransport([.body(#"{"requestId": "r", "error": "Invalid API key", "tag": "INVALID_API_KEY"}"#, status: 401)])
        let search = ExaWebSearch(endpoint: Self.endpoint(fake, base: ExaWebSearch.defaultBaseURL))
        do {
            _ = try await search.search(WebSearchQuery("x"))
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.status == 401)
            #expect(error.message == "Invalid API key")
        }
    }

    // MARK: - Tavily

    static let tavilyResponse = """
        {"query": "openclicky", "follow_up_questions": null, "answer": null, "images": [],
         "results": [
           {"title": "Lakers   win", "url": "https://news.example.com/lakers", "content": "The Lakers won   last night.",
            "score": 0.81, "raw_content": null, "published_date": "2026-10-29", "favicon": "https://news.example.com/f.ico"},
           {"title": "Undated", "url": "https://other.example.com/", "content": "No date detected.", "score": 0.4,
            "raw_content": null, "published_date": null}
         ],
         "response_time": "1.67", "usage": {"credits": 1}, "request_id": "123e4567-e89b-12d3-a456-426614174111"}
        """

    @Test func tavilyPostsWithABearerKeyAndReadsPublishedDates() async throws {
        let fake = FakeHTTPTransport([.body(Self.tavilyResponse)])
        let search = TavilyWebSearch(endpoint: Self.endpoint(fake, base: TavilyWebSearch.defaultBaseURL))
        let results = try await search.search(WebSearchQuery("lakers score", count: 4, freshness: .day))

        let request = try #require(fake.requests.first)
        #expect(request.url?.absoluteString == "https://api.tavily.com/search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
        let body = try fake.jsonBody()
        #expect(body["query"] == "lakers score")
        #expect(body["search_depth"] == "basic")
        #expect(body["max_results"] == 4)
        #expect(body["time_range"] == "day")
        #expect(body["include_published_date"] == true)
        #expect(body["api_key"] == nil)

        #expect(results.map(\.title) == ["Lakers win", "Undated"])
        #expect(results[0].snippet == "The Lakers won last night.")
        #expect(results[0].age == "2026-10-29")
        #expect(results[1].age == nil)
    }

    @Test func tavilyErrorBodiesAreRead() async throws {
        let fake = FakeHTTPTransport([
            .body(#"{"detail": {"error": "Unauthorized: missing or invalid API key."}}"#, status: 401),
            .body(#"{"detail": [{"loc": ["body", "max_results"], "msg": "Input should be less than or equal to 20", "type": "less_than_equal", "input": 99}]}"#, status: 422),
        ])
        let search = TavilyWebSearch(endpoint: Self.endpoint(fake, base: TavilyWebSearch.defaultBaseURL))
        for expected in ["Unauthorized: missing or invalid API key.", "max_results: Input should be less than or equal to 20"] {
            do {
                _ = try await search.search(WebSearchQuery("x"))
                Issue.record("expected an error")
            } catch let error as ProviderError {
                #expect(error.message == expected)
            }
        }
    }

    // MARK: - Wikimedia Commons

    static let commonsResponse = """
        {"batchcomplete": true, "continue": {"gsroffset": 4, "continue": "gsroffset||"},
         "query": {"pages": [
           {"pageid": 11, "ns": 6, "title": "File:Golden Gate Bridge at dusk.jpg", "index": 2,
            "imageinfo": [{"size": 3200000, "width": 4000, "height": 3000,
              "thumburl": "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/GGB.jpg/640px-GGB.jpg?utm_source=commons.wikimedia.org&utm_campaign=imageinfo",
              "thumbwidth": 640, "thumbheight": 480,
              "url": "https://upload.wikimedia.org/wikipedia/commons/a/ab/GGB.jpg?utm_source=commons.wikimedia.org&utm_content=original",
              "descriptionurl": "https://commons.wikimedia.org/wiki/File:Golden_Gate_Bridge_at_dusk.jpg",
              "mime": "image/jpeg",
              "extmetadata": {
                "ObjectName": {"value": "Golden Gate Bridge at dusk", "source": "commons-desc-page"},
                "ImageDescription": {"value": "The bridge <i>at dusk</i> from Marin", "source": "commons-desc-page"},
                "Artist": {"value": "<a href=\\"//commons.wikimedia.org/wiki/User:Jane\\">Jane Doe</a>", "source": "commons-desc-page"},
                "LicenseShortName": {"value": "CC BY-SA 4.0", "source": "commons-desc-page"},
                "Categories": {"value": "Golden Gate Bridge|Bridges in California", "source": "commons-categories"}}}]},
           {"pageid": 12, "ns": 6, "title": "File:Crowd on the bridge.jpg", "index": 1,
            "imageinfo": [{"size": 31000000, "width": 9000, "height": 6000,
              "thumburl": "https://upload.wikimedia.org/wikipedia/commons/thumb/c/cd/Crowd.jpg/640px-Crowd.jpg",
              "thumbwidth": 640, "thumbheight": 427,
              "url": "https://upload.wikimedia.org/wikipedia/commons/c/cd/Crowd.jpg",
              "descriptionurl": "https://commons.wikimedia.org/wiki/File:Crowd_on_the_bridge.jpg",
              "mime": "image/jpeg",
              "extmetadata": {"Categories": {"value": "People on bridges|Crowds in San Francisco"}}}]},
           {"pageid": 13, "ns": 6, "title": "File:Bridge diagram.tif", "index": 3,
            "imageinfo": [{"size": 900000, "width": 2000, "height": 1000,
              "thumburl": "https://upload.wikimedia.org/wikipedia/commons/thumb/d/de/Diagram.tif/lossy-page1-640px-Diagram.tif.jpg",
              "thumbwidth": 640, "thumbheight": 320,
              "url": "https://upload.wikimedia.org/wikipedia/commons/d/de/Diagram.tif",
              "descriptionurl": "https://commons.wikimedia.org/wiki/File:Bridge_diagram.tif", "mime": "image/tiff"}]},
           {"pageid": 14, "ns": 6, "title": "File:Bridge plans.pdf", "index": 4,
            "imageinfo": [{"size": 100, "url": "https://upload.wikimedia.org/x.pdf", "mime": "application/pdf"}]}
         ]}}
        """

    @Test func commonsAsksTheActionAPIAndReadsLicencesInRankOrder() async throws {
        let fake = FakeHTTPTransport([.body(Self.commonsResponse)])
        let search = WikimediaCommonsImageSearch(endpoint: Self.endpoint(fake, base: WikimediaCommonsImageSearch.defaultBaseURL, key: nil))
        let images = try await search.searchImages(ImageSearchQuery("Golden Gate Bridge", count: 4))

        let request = try #require(fake.requests.first)
        #expect(request.url?.host == "commons.wikimedia.org")
        #expect(request.url?.path == "/w/api.php")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("OpenClicky") == true)
        let query = Self.query(request)
        #expect(query["action"] == "query")
        #expect(query["formatversion"] == "2")
        #expect(query["generator"] == "search")
        #expect(query["gsrsearch"] == "Golden Gate Bridge filetype:bitmap")
        #expect(query["gsrnamespace"] == "6")
        #expect(query["gsrlimit"] == "4")
        #expect(query["prop"] == "imageinfo")
        #expect(query["iiprop"] == "url|size|mime|extmetadata")
        #expect(request.url?.absoluteString.contains("%7C") == true) // the pipes are percent-encoded

        #expect(images.count == 3) // the PDF is dropped
        // Search rank (`index`), not array order.
        #expect(images[0].sourcePageURL?.absoluteString == "https://commons.wikimedia.org/wiki/File:Crowd_on_the_bridge.jpg")
        // A 31 MB original is swapped for the thumbnail.
        #expect(images[0].imageURL.absoluteString.contains("640px-Crowd.jpg"))
        #expect(images[0].width == 640)
        #expect(images[0].keywords.contains("People on bridges"))

        let bridge = images[1]
        #expect(bridge.imageURL.absoluteString == "https://upload.wikimedia.org/wikipedia/commons/a/ab/GGB.jpg")
        #expect(bridge.thumbnailURL?.query == nil) // utm_* stripped
        #expect(bridge.title == "Golden Gate Bridge at dusk")
        #expect(bridge.credit == "Jane Doe")
        #expect(bridge.license == "CC BY-SA 4.0")
        #expect(bridge.width == 4000)
        #expect(bridge.keywords.contains("The bridge at dusk from Marin"))
        #expect(bridge.provider == "wikimedia-commons")
        // TIFF cannot be shown, so its JPEG rendition is used.
        #expect(images[2].imageURL.absoluteString.hasSuffix(".tif.jpg"))
    }

    @Test func commonsHandlesNoHitsAndAPIErrors() async throws {
        let fake = FakeHTTPTransport([
            .body(#"{"batchcomplete": true}"#),
            .body(#"{"error": {"code": "badvalue", "info": "Unrecognized value for parameter \"gsrsort\".", "docref": "See api.php"}, "servedby": "mw1"}"#),
        ])
        let search = WikimediaCommonsImageSearch(endpoint: Self.endpoint(fake, base: WikimediaCommonsImageSearch.defaultBaseURL, key: nil))
        #expect(try await search.searchImages(ImageSearchQuery("zzzz")).isEmpty)
        do {
            _ = try await search.searchImages(ImageSearchQuery("x"))
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.message.hasPrefix("Unrecognized value"))
        }
    }

    @Test func commonsFileTitles() {
        #expect(WikimediaCommonsImageSearch.fileTitle("File:Golden_Gate_Bridge,_2018.jpeg") == "Golden Gate Bridge, 2018")
        #expect(WikimediaCommonsImageSearch.fileTitle("File:Version 1.2 of a map") == "Version 1.2 of a map")
        #expect(WikimediaCommonsImageSearch.fileTitle(nil) == nil)
    }

    // MARK: - Twelve Data

    static let twelveQuote = """
        {"symbol": "AAPL", "name": "Apple Inc.", "exchange": "NASDAQ", "mic_code": "XNGS", "currency": "USD",
         "datetime": "2026-10-30", "timestamp": 1793304000, "last_quote_at": 1793320000,
         "open": "228.10001", "high": "231.5", "low": "227.25", "close": "230.75", "volume": "41234500",
         "previous_close": "227.5", "change": "3.25", "percent_change": "1.42857", "average_volume": "50000000",
         "rolling_1day_change": "3.25", "is_market_open": true,
         "fifty_two_week": {"low": "164.08", "high": "260.1", "low_change": "66.67", "high_change": "-29.35",
                            "low_change_percent": "40.6", "high_change_percent": "-11.3", "range": "164.08 - 260.1"}}
        """

    static let twelveSeriesIntraday = """
        {"meta": {"symbol": "AAPL", "interval": "5min", "currency": "USD", "exchange_timezone": "America/New_York",
                  "exchange": "NASDAQ", "mic_code": "XNGS", "type": "Common Stock"},
         "values": [
           {"datetime": "2026-10-30 09:40:00", "open": "229", "high": "229.5", "low": "228.9", "close": "229.4", "volume": "100"},
           {"datetime": "2026-10-30 09:35:00", "open": "228.5", "high": "229", "low": "228.4", "close": "228.9", "volume": "100"},
           {"datetime": "2026-10-30 09:30:00", "open": "228.1", "high": "228.6", "low": "228", "close": "228.5", "volume": "100"},
           {"datetime": "2026-10-29 15:55:00", "open": "227.4", "high": "227.6", "low": "227.3", "close": "227.5", "volume": "100"},
           {"datetime": "bad", "close": "n/a"}
         ],
         "status": "ok"}
        """

    @Test func twelveDataQuotesWithAHeaderKeyAndBuildsASparkline() async throws {
        let fake = FakeHTTPTransport([.body(Self.twelveQuote), .body(Self.twelveSeriesIntraday)])
        let provider = TwelveDataQuotes(endpoint: Self.endpoint(fake, base: TwelveDataQuotes.defaultBaseURL))
        let quote = try await provider.quote(symbol: " $aapl ", range: .day)

        #expect(fake.requests.count == 2)
        for request in fake.requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "apikey \(Self.key)")
            #expect(!(request.url?.absoluteString.contains(Self.key) ?? true))
            #expect(Self.query(request)["symbol"] == "AAPL")
        }
        #expect(fake.requests[0].url?.path == "/quote")
        #expect(fake.requests[1].url?.path == "/time_series")
        #expect(Self.query(fake.requests[1])["interval"] == "5min")
        #expect(Self.query(fake.requests[1])["outputsize"] == "80")

        #expect(quote.symbol == "AAPL")
        #expect(quote.name == "Apple Inc.")
        #expect(quote.price == 230.75)
        #expect(quote.change == 3.25)
        #expect(quote.changePercent == 1.42857)
        #expect(quote.dayHigh == 231.5 && quote.dayLow == 227.25)
        #expect(quote.previousClose == 227.5)
        #expect(quote.isMarketOpen == true)
        #expect(quote.asOf == Date(timeIntervalSince1970: 1_793_320_000)) // last_quote_at, not the candle start
        // Only the latest session, oldest first; the unparsable row is dropped.
        #expect(quote.recentCloses == [228.5, 228.9, 229.4])
        #expect(quote.startPrice == 227.5) // a one-day sparkline starts at the previous close
    }

    @Test func twelveDataRangesUseDocumentedIntervals() async throws {
        #expect(TwelveDataQuotes.series(for: .week) == ("30min", 70))
        #expect(TwelveDataQuotes.series(for: .month) == ("1day", 22))
        #expect(TwelveDataQuotes.series(for: .year) == ("1week", 52))

        let daily = """
            {"meta": {"symbol": "MSFT", "interval": "1day"}, "status": "ok", "values": [
              {"datetime": "2026-10-30", "close": "410"}, {"datetime": "2026-10-29", "close": "405"}, {"datetime": "2026-10-28", "close": "400"}]}
            """
        let fake = FakeHTTPTransport([.body(Self.twelveQuote.replacingOccurrences(of: "AAPL", with: "MSFT")), .body(daily)])
        let quote = try await TwelveDataQuotes(endpoint: Self.endpoint(fake, base: TwelveDataQuotes.defaultBaseURL)).quote(symbol: "msft", range: .month)
        #expect(quote.recentCloses == [400, 405, 410])
        #expect(quote.startPrice == 400)
        #expect(quote.range == .month)
    }

    @Test func twelveDataUnknownSymbolIsNotFoundAndKeysAreRedacted() async throws {
        let notFound = #"{"code": 404, "message": "**symbol** not found: ZZZZQ. Please specify it correctly according to API Documentation.", "status": "error", "meta": {"symbol": "ZZZZQ"}}"#
        let badKey = #"{"code": 401, "message": "**apikey** parameter is incorrect or not specified. You sent \#(Self.key).", "status": "error"}"#
        let fake = FakeHTTPTransport([.body(notFound), .body(badKey, status: 401)])
        let provider = TwelveDataQuotes(endpoint: Self.endpoint(fake, base: TwelveDataQuotes.defaultBaseURL))
        do {
            _ = try await provider.quote(symbol: "ZZZZQ", range: .day)
            Issue.record("expected an error")
        } catch let error as LookupError {
            guard case .notFound(let message) = error else { Issue.record("wrong error \(error)"); return }
            #expect(message.contains("ZZZZQ"))
        }
        do {
            _ = try await provider.quote(symbol: "AAPL", range: .day)
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.status == 401)
            #expect(!error.description.contains(Self.key))
        }
    }

    @Test func twelveDataQuoteSurvivesAFailedSeries() async throws {
        let fake = FakeHTTPTransport([.body(Self.twelveQuote), .body(#"{"code": 429, "message": "You have run out of API credits for the current minute.", "status": "error"}"#, status: 429)])
        let quote = try await TwelveDataQuotes(endpoint: Self.endpoint(fake, base: TwelveDataQuotes.defaultBaseURL)).quote(symbol: "AAPL", range: .day)
        #expect(quote.price == 230.75)
        #expect(quote.recentCloses.isEmpty)
        #expect(quote.startPrice == 227.5)
    }

    @Test func tickerSymbolsAreNormalizedAndChecked() throws {
        #expect(try MarketSymbol.normalize(" brk.b ") == "BRK.B")
        #expect(try MarketSymbol.normalize("eur/usd") == "EUR/USD")
        #expect(try MarketSymbol.normalize("^GSPC") == "^GSPC")
        #expect(throws: LookupError.self) { try MarketSymbol.normalize("AAPL&apikey=x") }
        #expect(throws: LookupError.self) { try MarketSymbol.normalize("") }
        #expect(throws: LookupError.self) { try MarketSymbol.normalize("ÄPPLE") }
    }

    // MARK: - MapKit

    final class FakeMapKit: MapKitLocalSearching, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [MapKitSearchRequest] = []
        let items: [MapKitItem]
        let error: Error?

        init(items: [MapKitItem] = [], error: Error? = nil) {
            self.items = items
            self.error = error
        }

        var requests: [MapKitSearchRequest] { lock.withLock { _requests } }

        func search(_ request: MapKitSearchRequest) async throws -> [MapKitItem] {
            lock.withLock { _requests.append(request) }
            if let error { throw error }
            return items
        }
    }

    static let ferryBuilding = MapKitItem(
        identifier: "I6C2B5E1F", name: "Ferry Building", coordinate: PlaceCoordinate(latitude: 37.79544, longitude: -122.39362),
        address: "1 Ferry Building, San Francisco, CA 94111, United States", phone: "+1 (415) 983-8030",
        url: URL(string: "https://www.ferrybuildingmarketplace.com"), category: "MKPOICategoryLandmark", timeZone: "America/Los_Angeles")

    @Test func mapKitPlacesCarryNameCoordinateAddressPhoneURLAndCategory() async throws {
        let fake = FakeMapKit(items: [
            Self.ferryBuilding,
            Self.ferryBuilding, // duplicates collapse
            MapKitItem(name: "Blue Bottle Coffee", coordinate: PlaceCoordinate(latitude: 37.7962, longitude: -122.3940),
                       url: URL(string: "javascript:alert(1)"), category: "MKPOICategoryCafe"),
            MapKitItem(name: "  ", coordinate: PlaceCoordinate(latitude: 1, longitude: 1)),
            MapKitItem(name: "Nowhere", coordinate: PlaceCoordinate(latitude: 200, longitude: 0)),
        ])
        let search = MapKitPlaceSearch(backend: fake)
        let places = try await search.searchPlaces(PlaceQuery("coffee near the Ferry Building", limit: 5,
                                                              near: PlaceCoordinate(latitude: 37.79, longitude: -122.39), radiusMeters: 5))

        let request = try #require(fake.requests.first)
        #expect(request.query == "coffee near the Ferry Building")
        #expect(request.center == PlaceCoordinate(latitude: 37.79, longitude: -122.39))
        #expect(request.radiusMeters == 100) // clamped up from 5 m

        #expect(places.count == 2)
        let ferry = places[0]
        #expect(ferry.id == "I6C2B5E1F")
        #expect(ferry.name == "Ferry Building")
        #expect(ferry.coordinate.latitude == 37.79544)
        #expect(ferry.address == "1 Ferry Building, San Francisco, CA 94111, United States")
        #expect(ferry.phone == "+1 (415) 983-8030")
        #expect(ferry.website?.host == "www.ferrybuildingmarketplace.com")
        #expect(ferry.category == "Landmark")
        #expect(ferry.timeZone == "America/Los_Angeles")
        #expect(ferry.mapsURL?.absoluteString == "https://maps.apple.com/?q=Ferry%20Building&ll=37.795440,-122.393620")
        #expect(places[1].category == "Cafe")
        #expect(places[1].website == nil) // only http(s) links
        #expect(places[1].id.hasPrefix("Blue Bottle Coffee@37.79620"))
    }

    @Test func mapKitRejectsBadInputBeforeSearching() async throws {
        let fake = FakeMapKit()
        let search = MapKitPlaceSearch(backend: fake)
        await #expect(throws: LookupError.self) { try await search.searchPlaces(PlaceQuery("  ")) }
        await #expect(throws: LookupError.self) {
            try await search.searchPlaces(PlaceQuery("cafe", near: PlaceCoordinate(latitude: .nan, longitude: 0)))
        }
        #expect(fake.requests.isEmpty)
        _ = try await search.searchPlaces(PlaceQuery("cafe", radiusMeters: .infinity))
        #expect(fake.requests.first?.radiusMeters == 10_000)
    }

    @Test func mapKitCategoryNames() {
        #expect(MapKitPlaceSearch.categoryName("MKPOICategoryAmusementPark") == "Amusement Park")
        #expect(MapKitPlaceSearch.categoryName("MKPOICategoryEVCharger") == "EV Charger")
        #expect(MapKitPlaceSearch.categoryName("MKPOICategoryATM") == "ATM")
        #expect(MapKitPlaceSearch.categoryName(nil) == nil)
        #expect(SystemMapKitLocalSearch.oneLine("1 Ferry Building\nSan Francisco, CA  94111\n\nUnited States")
            == "1 Ferry Building, San Francisco, CA 94111, United States")
    }

    // MARK: - Hosted search

    @Test func hostedSearchDefinitionsFollowEachProvidersDocs() throws {
        let openAI = try #require(HostedWebSearch.toolDefinition(for: .openAIResponses, allowedDomains: ["swift.org", " "],
                                                                 countryCode: "us", timeZone: "America/Los_Angeles"))
        #expect(openAI["type"] == "web_search")
        #expect(openAI["filters"]?["allowed_domains"] == ["swift.org"])
        #expect(openAI["user_location"]?["type"] == "approximate")
        #expect(openAI["user_location"]?["country"] == "US")

        let anthropic = try #require(HostedWebSearch.toolDefinition(for: .anthropicMessages, maxUses: 3))
        #expect(anthropic["type"] == "web_search_20250305")
        #expect(anthropic["name"] == "web_search")
        #expect(anthropic["max_uses"] == 3)
        #expect(anthropic["user_location"] == nil)

        #expect(HostedWebSearch.toolDefinition(for: .openAIChat) == nil)
        #expect(!HostedWebSearch.isSupported(by: .deepgramListen))
    }
}
