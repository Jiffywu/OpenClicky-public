import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Testing
@testable import OpenClickyKit

// Media pieces (Resources/js/media-api.js), the engine's request/patch hook, the resolver and the painter's cards.

private func host(_ clock: VirtualClock = VirtualClock()) throws -> DrawingEngineHost {
    try DrawingEngineHost(clock: { clock.now })
}

private func marks(_ events: [DrawingEvent]) -> [DrawingMark] {
    events.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
}

private func requests(_ events: [DrawingEvent]) -> [DrawingMediaRequest] { events.compactMap(DrawingMediaRequest.init(event:)) }

private func runNow(_ host: DrawingEngineHost, _ program: String) -> [DrawingEvent] {
    var events = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now)))
    events += host.perform(.append(program))
    events += host.perform(.end)
    events += host.perform(.drain)
    return events
}

/// A solid-colour image standing in for a downloaded photo.
private func solid(_ hex: String, width: Int = 40, height: Int = 30) -> DrawingMediaImage {
    let color = DrawingColor(hex: hex)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return DrawingMediaImage(context.makeImage()!)
}

private func pngData(_ hex: String) -> Data {
    let image = solid(hex, width: 24, height: 16).image
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Fake lookups that count their calls.
final class FakeMediaLookups: DrawingMediaLookups, @unchecked Sendable {
    let lock = NSLock()
    var photoCalls: [PhotoQuery] = []
    var placeCalls = 0
    var quoteCalls = 0
    var failWith: Error?

    func photo(_ query: PhotoQuery) async throws -> DrawingPhoto {
        lock.withLock { photoCalls.append(query) }
        if let failWith { throw failWith }
        return DrawingPhoto(image: solid("#E5484D"), result: ImageResult(imageURL: URL(string: "https://upload.example.org/bridge.jpg")!,
                                                                        sourcePageURL: URL(string: "https://commons.example.org/File:Bridge")!,
                                                                        title: "A bridge", provider: "fake", license: "CC BY 4.0"))
    }

    func place(_ query: PlaceQuery) async throws -> Place {
        lock.withLock { placeCalls += 1 }
        if let failWith { throw failWith }
        return Place(id: "p1", name: "Ferry Building", coordinate: PlaceCoordinate(latitude: 37.7955, longitude: -122.3937),
                     address: "1 Ferry Building, San Francisco, CA", category: "Market")
    }

    func map(around coordinate: PlaceCoordinate, size: CGSize) async -> DrawingMediaImage? { solid("#9FD3A8") }

    func quote(symbol: String, range: QuoteRange) async throws -> MarketQuote {
        lock.withLock { quoteCalls += 1 }
        if let failWith { throw failWith }
        return MarketQuote(symbol: symbol, name: "Example Corp", currency: "USD", price: 231.4, change: 2.3, changePercent: 1.004,
                           previousClose: 229.1, range: range, recentCloses: [229.1, 229.8, 230.2, 229.5, 230.9, 231.4], startPrice: 229.1)
    }

    func favicon(host: String) async throws -> DrawingMediaImage { solid("#3380FF", width: 16, height: 16) }
}

@Suite struct DrawingMediaTests {
    @Test func mediaPiecesPushLoadingCardsAndAskTheHostRightAway() throws {
        let events = runNow(try host(), """
        photo(40, 40, 260, 200, "Golden Gate Bridge", "The bridge", {people: false})
        photo(340, 40, 200, 160, "harbor at night", {web: true})
        photo(600, 40, 200, 160, "https://www.swift.org/blog/", "Swift")
        place(40, 300, 300, "Ferry Building, San Francisco", {near: [37.79, -122.39]})
        stock(380, 300, 260, "$aapl", {range: "1m"})
        source(700, 300, "https://en.wikipedia.org/wiki/Bridge", "Wikipedia")
        """)
        let painted = marks(events)
        let asked = requests(events)
        #expect(painted.map(\.kind).filter { $0 != "text" } == ["photo", "photo", "photo", "place", "stock", "favicon"])
        #expect(painted.filter { $0.kind != "text" }.allSatisfy { $0.json["state"]?.stringValue == "loading" })
        #expect(asked.map(\.kind) == [.photo, .photo, .photo, .place, .stock, .favicon])
        #expect(asked[0].query == "nopeople: Golden Gate Bridge")
        #expect(asked[1].query == "web: harbor at night")
        #expect(asked[2].query == "page: https://www.swift.org/blog/ :: Swift")
        #expect(asked[3].near == PlaceCoordinate(latitude: 37.79, longitude: -122.39))
        #expect(asked[4].symbol == "AAPL" && asked[4].range == .month)
        #expect(asked[5].host == "en.wikipedia.org")
        // Each request names its mark, and the mark carries the request's ref.
        for request in asked {
            let mark = painted.first { $0.id == request.markID }
            #expect(mark?.json["ref"]?.stringValue == request.ref)
        }
        // The source credit also writes its words next to the icon.
        #expect(painted.contains { $0.kind == "text" && $0.json["text"]?.stringValue == "Wikipedia" })
    }

    @Test func badMediaCallsWarnAndDrawNothing() throws {
        let events = runNow(try host(), """
        photo(10, 10, 100, 100, "")
        stock(10, 10, 200, "not a ticker!")
        favicon(10, 10, "localhost")
        place(10, 10, NaN, "x")
        """)
        #expect(marks(events).isEmpty)
        #expect(requests(events).isEmpty)
        let warned = events.compactMap { if case .warning(let m) = $0 { m } else { nil } }
        #expect(warned.count == 4)
    }

    @Test func aDrawingAsksForAtMostTwelveLookups() throws {
        let events = runNow(try host(), "for (let i = 0; i < 15; i++) photo(10 + i * 5, 10, 80, 80, 'cat ' + i)")
        #expect(requests(events).count == 12)
        #expect(events.contains { if case .warning(let m) = $0 { m.contains("at most 12") } else { false } })
    }

    @Test func aPatchFillsTheMarkAndRepaintsItInPlace() throws {
        let clock = VirtualClock()
        let engine = try host(clock)
        let first = runNow(engine, #"stock(40, 40, 260, "AAPL")"#)
        let ref = try #require(requests(first).first?.ref)
        clock.now += 2
        let patched = engine.perform(.patch(ref: ref, fields: ["state": "ready", "price": 231.4, "changePercent": 1.25, "currency": "USD",
                                                                "id": "hijack", "start": 99, "do": "box"]))
        let mark = try #require(marks(patched).first)
        #expect(mark.json["edit"]?.stringValue == "patch")
        #expect(mark.json["state"]?.stringValue == "ready")
        #expect(mark.json["price"]?.doubleValue == 231.4)
        // Identity and timing stay the engine's: the card is repainted where and as it was.
        #expect(mark.kind == "stock" && mark.id != "hijack" && mark.start == 0)
        #expect(mark.json["base"]?.doubleValue == clock.now)
        // The card's state text (what follow-up turns read) shows the quote.
        #expect(engine.describe().contains("AAPL $231.40 (+1.25%)"))
    }

    @Test func answersForACardThatWasReplacedAreDropped() throws {
        let engine = try host()
        let ref = try #require(requests(runNow(engine, #"photo(10, 10, 100, 100, "owl")"#)).first?.ref)
        _ = runNow(engine, #"photo(10, 10, 100, 100, "owl")"#)
        #expect(marks(engine.perform(.patch(ref: ref, fields: ["state": "ready"]))).isEmpty)
        // Unknown refs and junk are ignored too.
        #expect(marks(engine.perform(.patch(ref: "q999", fields: ["state": "ready"]))).isEmpty)
        #expect(marks(engine.perform(.patch(ref: ref, fields: "not an object"))).isEmpty)
    }

    @Test func anAnswerThatArrivesBeforeItsBeatRidesWithTheMark() throws {
        let clock = VirtualClock()
        let engine = try host(clock)
        var events = engine.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .speech)))
        events += engine.perform(.append("""
        step(1)
        say("Here is the bridge.")
        photo(40, 40, 260, 200, "Golden Gate Bridge")
        """))
        events += engine.perform(.end)
        let ref = try #require(requests(events).first?.ref)
        #expect(marks(events).isEmpty)  // held for its line
        #expect(marks(engine.perform(.patch(ref: ref, fields: ["state": "ready", "image": "k"]))).isEmpty)
        clock.now += 0.5
        let released = marks(engine.perform(.lineStarted(0, 2)))
        let photo = try #require(released.first { $0.kind == "photo" })
        #expect(photo.json["state"]?.stringValue == "ready")
        #expect(photo.json["edit"] == nil)
    }

    @Test func requestsDecodeAndShareKeys() {
        let a = DrawingMediaRequest(ref: "q1", mark: "m1", json: ["kind": "photo", "query": "  owl   at  night "])
        let b = DrawingMediaRequest(ref: "q2", mark: "m2", json: ["kind": "photo", "query": "owl at night"])
        #expect(a?.query == "owl at night")
        #expect(a?.cacheKey == b?.cacheKey)
        #expect(DrawingMediaRequest(ref: "q3", mark: "m3", json: ["kind": "photo"]) == nil)
        #expect(DrawingMediaRequest(ref: "q3", mark: "m3", json: ["kind": "video", "query": "x"]) == nil)
        let far = DrawingMediaRequest(ref: "q4", mark: "m4", json: ["kind": "place", "query": "cafe", "near": [123, 500]])
        #expect(far?.near == nil)
    }

    @MainActor @Test func theResolverLooksEachThingUpOnceAndPatchesTheSession() async throws {
        let lookups = FakeMediaLookups()
        let resolver = DrawingMediaResolver(lookups: lookups)
        let session = try DrawingSession(canvas: .init(width: 800, height: 600))
        DrawingSnapshot.adopt(session.layer)
        var asked: [String] = []
        session.onEvent = { event in if case .ask(let text) = event { asked.append(text) } }
        resolver.attach(to: session)
        session.begin(DrawingBeginOptions(width: 800, height: 600, pace: .now))
        session.append("""
        photo(20, 20, 240, 180, "Golden Gate Bridge", "The bridge")
        photo(300, 20, 240, 180, "Golden Gate Bridge")
        stock(20, 300, 260, "AAPL")
        place(320, 300, 300, "Ferry Building")
        favicon(700, 20, "swift.org")
        """)
        session.end()
        await session.settle()
        await resolver.settle()
        await session.settle()
        #expect(lookups.photoCalls.count == 1)
        #expect(lookups.quoteCalls == 1 && lookups.placeCalls == 1)
        #expect(resolver.store.count == 3)  // one photo, one map, one icon
        let photos = session.painter.markIDs.compactMap { session.painter.layer(forMark: $0) }.filter { $0.sublayers?.first?.name == "photo" }
        #expect(photos.count == 2)
        for photo in photos {
            #expect(names(photo).contains("image"))
        }
        // The resolver kept the session's own event handler.
        #expect(asked.isEmpty)
    }

    @Test func lookupFailuresBecomeAFailedCardWithAReason() async {
        let lookups = FakeMediaLookups()
        lookups.failWith = LookupError.unavailable(service: "Market data", reason: "no Twelve Data key is stored")
        let request = DrawingMediaRequest(ref: "q1", markID: "m1", kind: .stock, symbol: "AAPL")
        let resolution = await request.resolve(with: lookups)
        #expect(resolution.fields["state"]?.stringValue == "failed")
        #expect(resolution.fields["reason"]?.stringValue?.contains("Twelve Data") == true)
    }

    @Test func photosSkipPrivateHostsAndPeopleAndTakeTheNextCandidate() async throws {
        struct Provider: ImageSearchProvider {
            let providerID = "fake"
            let modes: Set<ImageSearchQuery.Mode> = [.subject, .web]
            func searchImages(_ query: ImageSearchQuery) async throws -> [ImageResult] {
                [ImageResult(imageURL: URL(string: "https://192.168.1.20/private.jpg")!, provider: "fake"),
                 ImageResult(imageURL: URL(string: "https://img.example.org/crowd.jpg")!, provider: "fake"),
                 ImageResult(imageURL: URL(string: "https://img.example.org/bridge.png")!, title: "Bridge", provider: "fake")]
            }
        }
        struct Detector: PeopleDetecting {
            let peopleBytes: Data
            func containsPeople(_ imageData: Data) async throws -> Bool { imageData == peopleBytes }
        }
        let crowd = pngData("#202020"), bridge = pngData("#E5484D")
        let web = FakeHTTPTransport([
            .init(headers: ["Content-Type": "image/png"], chunks: [crowd]),
            .init(headers: ["Content-Type": "image/png"], chunks: [bridge]),
        ])
        var services = LookupServices()
        services.imageSearch = ImageSearchService(providers: [Provider()], pagePreview: nil, peopleFilter: PeopleFilter(detector: nil))
        let lookups = LiveDrawingMediaLookups(services: services, loader: DrawingImageLoader(http: web), maps: nil,
                                              peopleDetector: Detector(peopleBytes: crowd))
        let photo = try await lookups.photo(PhotoQuery(.subject("bridge"), excludePeople: true))
        #expect(photo.result.title == "Bridge")
        #expect(web.requests.map { $0.url?.host } == ["img.example.org", "img.example.org"])  // the private host was never asked
        #expect(photo.image.image.width == 24)
    }

    @Test func theImageLoaderRefusesWhatIsNotAPublicImage() async {
        let loader = DrawingImageLoader(http: FakeHTTPTransport([.body("<html>", contentType: "text/html"),
                                                                 .init(headers: ["Content-Type": "image/png"], chunks: [Data(count: 2_000)])]),
                                        maxBytes: 1_000)
        await #expect(throws: DrawingMediaError.notPublic) { try await loader.load(URL(string: "http://example.org/a.png")!) }
        await #expect(throws: DrawingMediaError.notPublic) { try await loader.load(URL(string: "https://10.0.0.3/a.png")!) }
        await #expect(throws: DrawingMediaError.notAnImage) { try await loader.load(URL(string: "https://example.org/page")!) }
        await #expect(throws: DrawingMediaError.tooLarge) { try await loader.load(URL(string: "https://example.org/big.png")!) }
    }

    @Test func sparklinesSpanTheBoxAndMarkTheBasis() {
        let box = CGRect(x: 10, y: 20, width: 100, height: 50)
        let line = DrawingPainter.sparkline([1, 3, 2], basis: 1, in: box)
        let bounds = line.path.boundingBoxOfPath
        #expect(abs(bounds.minX - 10) < 0.01 && abs(bounds.maxX - 110) < 0.01)
        #expect(bounds.minY >= 20 && bounds.maxY <= 70)
        let basis = try? #require(line.baseline?.boundingBoxOfPath)
        // The basis is the lowest value here, so its line sits under every close.
        #expect((basis?.minY ?? 0) >= bounds.maxY - 0.01)
        #expect(DrawingPainter.money(231.4, currency: "USD") == "$231.40")
        #expect(DrawingPainter.money(1234.6, currency: "EUR") == "€1,235")
        #expect(DrawingMediaRequest.thin(Array(stride(from: 0.0, to: 100, by: 1)), to: 10).count == 10)
        #expect(DrawingMediaRequest.thin(Array(stride(from: 0.0, to: 100, by: 1)), to: 10).last == 99)
    }

    @Test func cardWordsAreShortenedToFit() {
        let lines = DrawingPainter.wrap("A very long place name that keeps going and going", style: .ui, size: 12, width: 120, maxLines: 2)
        #expect(lines.count == 2)
        #expect(lines.last?.hasSuffix("…") == true)
        #expect(DrawingPainter.wrap("Short", style: .ui, size: 12, width: 120, maxLines: 2) == ["Short"])
    }

    @MainActor @Test func aRehearsalPaintsTheAnswersOnTheVirtualClock() throws {
        let store = DrawingMediaStore()
        store.put(solid("#E5484D", width: 60, height: 40), for: "photo|Golden Gate Bridge")
        var options = DrawingRehearsal.Options()
        options.width = 400
        options.height = 300
        options.backdrop = .color("#FFFFFF")
        options.media = DrawingRehearsalMedia(store: store, answers: ["photo|Golden Gate Bridge": ["state": "ready", "image": "photo|Golden Gate Bridge"]],
                                              delay: 1.5)
        let program = """
        step(1)
        say("Here is the bridge.")
        photo(50, 50, 300, 200, "Golden Gate Bridge", "", {tilt: 0})
        """
        // Before the answer: the placeholder well; after: the photo itself.
        options.at = 1.2
        let early = try DrawingRehearsal.run(program: program, options: options)
        options.at = 3
        let late = try DrawingRehearsal.run(program: program, options: options)
        let before = DrawingSnapshot.pixel(early.image, x: 200, y: 140)
        let after = DrawingSnapshot.pixel(late.image, x: 200, y: 140)
        #expect(before.r < 240 && before.r > 200 && abs(before.r - before.g) < 12)  // the grey well
        #expect(after.r > 200 && after.g < 110 && after.b < 110)                      // the red photo
    }
}

private func names(_ layer: CALayer) -> [String] {
    var out: [String] = []
    func walk(_ l: CALayer) {
        if let name = l.name { out.append(name) }
        l.sublayers?.forEach(walk)
    }
    walk(layer)
    return out
}

@Suite struct DrawingPlacePickTests {
    @Test func aPlaceCardPrefersTheLandmarkOverAStreetNamedAfterIt() {
        let street = Place(id: "a", name: "Avenue Gustave Eiffel", coordinate: PlaceCoordinate(latitude: 48.858, longitude: 2.294), address: "75007 Paris")
        let tower = Place(id: "b", name: "Tour Eiffel", coordinate: PlaceCoordinate(latitude: 48.858, longitude: 2.294), category: "Landmark")
        #expect(LiveDrawingMediaLookups.bestPlace(for: "Eiffel Tower, Paris, France", in: [street, tower])?.id == "b")
        // With nothing to tell them apart, the provider's order stands.
        let other = Place(id: "c", name: "Somewhere", coordinate: PlaceCoordinate(latitude: 0, longitude: 0))
        #expect(LiveDrawingMediaLookups.bestPlace(for: "cafe", in: [other, street])?.id == "c")
        #expect(LiveDrawingMediaLookups.bestPlace(for: "cafe", in: []) == nil)
    }
}

@Suite struct DrawingPlaceRetryTests {
    final class FakePlaces: PlaceSearchProvider, @unchecked Sendable {
        let providerID = "fake"
        var queries: [PlaceQuery] = []
        func searchPlaces(_ query: PlaceQuery) async throws -> [Place] {
            queries.append(query)
            if query.near != nil {
                return [Place(id: "street", name: "Avenue Gustave Eiffel", coordinate: PlaceCoordinate(latitude: 48.8577, longitude: 2.2951))]
            }
            return [Place(id: "tower", name: "Eiffel Tower", coordinate: PlaceCoordinate(latitude: 48.8583, longitude: 2.2945), category: "Landmark")]
        }
    }

    @Test func aStreetFoundNearbyIsSwappedForTheLandmark() async throws {
        let fake = FakePlaces()
        var services = LookupServices()
        services.places = fake
        let lookups = LiveDrawingMediaLookups(services: services, maps: nil)
        let place = try await lookups.place(PlaceQuery("Eiffel Tower, Paris", near: PlaceCoordinate(latitude: 48.8584, longitude: 2.2945)))
        #expect(place.id == "tower")
        #expect(fake.queries.count == 2 && fake.queries[1].near == nil)
        #expect(abs(LiveDrawingMediaLookups.meters(PlaceCoordinate(latitude: 48.8584, longitude: 2.2945),
                                                   PlaceCoordinate(latitude: 48.8584, longitude: 2.3045)) - 732) < 5)
    }
}

/// Review fix: a cached answer brings its picture back when the store has dropped it.
@Suite struct DrawingMediaCacheTests {
    @MainActor @Test func aCachedAnswerRestoresAPictureTheStoreDropped() async throws {
        let lookups = FakeMediaLookups()
        let resolver = DrawingMediaResolver(lookups: lookups, store: DrawingMediaStore(capacity: 1))
        let bridge = DrawingMediaRequest(ref: "q1", markID: "m1", kind: .photo, query: "Golden Gate Bridge")
        let icon = DrawingMediaRequest(ref: "q2", markID: "m2", kind: .favicon, host: "swift.org")
        var patched: [String] = []
        resolver.handle(.request(ref: bridge.ref, mark: bridge.markID, json: ["kind": "photo", "query": "Golden Gate Bridge"])) { ref, _ in patched.append(ref) }
        await resolver.settle()
        resolver.handle(.request(ref: icon.ref, mark: icon.markID, json: ["kind": "favicon", "host": "swift.org"])) { ref, _ in patched.append(ref) }
        await resolver.settle()
        #expect(resolver.store.image(bridge.cacheKey) == nil)     // evicted by the icon (capacity 1)
        let again = await resolver.lookup(bridge).value
        #expect(again.isReady && lookups.photoCalls.count == 1)  // answered from the cache
        #expect(resolver.store.image(bridge.cacheKey) != nil)     // and its picture is back for the painter
        #expect(patched == ["q1", "q2"])
    }
}

/// Review fix: MKMapSnapshotter never calls back once cancelled, so cancelling a place lookup used to hang its task.
@Suite struct CancellableCallbackTests {
    /// A job like a cancelled MKMapSnapshotter: it remembers the callback and never calls it.
    final class SilentJob: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        var callback: (@Sendable (Result<Int, Error>) -> Void)?
        func start(_ finish: @escaping @Sendable (Result<Int, Error>) -> Void) { lock.withLock { callback = finish } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    @Test func cancellingAJobThatNeverCallsBackEndsTheWaitAtOnce() async throws {
        let job = SilentJob()
        let task = Task { try await CancellableCallback.run(start: job.start, cancel: job.cancel) }
        try await Task.sleep(for: .milliseconds(30))
        let started = Date()
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(job.lock.withLock { job.cancelled })
        if case .failure(let error) = result { #expect(error is CancellationError) } else { Issue.record("expected a cancellation") }
        // A late callback after the cancellation is ignored (no double resume).
        job.lock.withLock { job.callback }?(.success(7))
    }

    @Test func theFirstCallbackWinsAndACancelledTaskNeverStartsWaiting() async throws {
        let value = try await CancellableCallback.run(start: { finish in finish(.success(1)); finish(.success(2)) }, cancel: {})
        #expect(value == 1)
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CancellableCallback.run(start: { (_: @escaping @Sendable (Result<Int, Error>) -> Void) in }, cancel: {})
        }
        if case .failure(let error) = await early.result { #expect(error is CancellationError) } else { Issue.record("expected a cancellation") }
    }
}
