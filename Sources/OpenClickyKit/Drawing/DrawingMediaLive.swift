import CoreGraphics
import Foundation
import ImageIO
import MapKit

/// Downloads a picture for a drawing: public https hosts only (redirects included, through
/// `URLSessionTransport.publicWebOnly`), a capped size, image bodies only, decoded straight to a bounded thumbnail.
public struct DrawingImageLoader: Sendable {
    let http: any HTTPTransport
    let userAgent: String
    public var maxBytes: Int
    public var maxPixels: Int
    public var maxSide: Int

    public init(http: any HTTPTransport = URLSessionTransport.publicWebOnly, userAgent: String = LookupEndpoint.defaultUserAgent,
                maxBytes: Int = 8_000_000, maxPixels: Int = 50_000_000, maxSide: Int = 1200) {
        self.http = http
        self.userAgent = userAgent
        self.maxBytes = maxBytes
        self.maxPixels = maxPixels
        self.maxSide = maxSide
    }

    /// The raw bytes, checked to be a public image no larger than `maxBytes`.
    public func download(_ url: URL) async throws -> Data {
        guard PublicURL.isPublic(url) else { throw DrawingMediaError.notPublic }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (stream, response) = try await http.stream(for: request)
        guard (200..<300).contains(response.statusCode) else { throw DrawingMediaError.httpStatus(response.statusCode) }
        if let final = response.url, !PublicURL.isPublic(final) { throw DrawingMediaError.notPublic }
        if let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(), !type.isEmpty,
           !type.hasPrefix("image/"), !type.hasPrefix("application/octet-stream") {
            throw DrawingMediaError.notAnImage
        }
        if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > maxBytes {
            throw DrawingMediaError.tooLarge
        }
        var data = Data()
        for try await chunk in stream {
            data.append(chunk)
            if data.count > maxBytes { throw DrawingMediaError.tooLarge }
        }
        return data
    }

    /// Decode on a GCD queue (not a Swift concurrency thread): the header is checked before any pixels are decoded.
    public func decode(_ data: Data) async throws -> DrawingMediaImage {
        let maxPixels = self.maxPixels, maxSide = self.maxSide
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let image = try VisionPeopleDetector.preparedImage(from: data, maxPixels: maxPixels, maxSide: maxSide)
                    continuation.resume(returning: DrawingMediaImage(image))
                } catch {
                    continuation.resume(throwing: DrawingMediaError.notAnImage)
                }
            }
        }
    }

    public func load(_ url: URL) async throws -> DrawingMediaImage {
        try await decode(try await download(url))
    }
}

/// A small map image around a coordinate, for place cards.
public protocol DrawingMapSnapshotting: Sendable {
    func snapshot(around coordinate: PlaceCoordinate, size: CGSize, spanMeters: Double) async throws -> DrawingMediaImage
}

/// Apple Maps through `MKMapSnapshotter`. No key and no location permission.
public struct MapKitMapSnapshotter: DrawingMapSnapshotting {
    public init() {}

    public func snapshot(around coordinate: PlaceCoordinate, size: CGSize, spanMeters: Double) async throws -> DrawingMediaImage {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                            latitudinalMeters: spanMeters, longitudinalMeters: spanMeters * Double(size.width / max(size.height, 1)))
        options.size = size
        options.mapType = .standard
        options.showsBuildings = false
        options.pointOfInterestFilter = .excludingAll
        options.appearance = NSAppearance(named: .aqua)
        let box = SnapshotterBox(MKMapSnapshotter(options: options))
        // A snapshot cancelled while loading never calls its completion handler (checked on macOS 27), so the
        // cancellation itself has to answer the waiting task.
        return try await CancellableCallback.run(start: { finish in
            box.value.start(with: DispatchQueue.global(qos: .userInitiated)) { snapshot, error in
                if let snapshot, let image = snapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    finish(.success(DrawingMediaImage(image)))
                } else {
                    finish(.failure(error ?? DrawingMediaError.notAnImage))
                }
            }
        }, cancel: { box.value.cancel() })
    }

    /// `MKMapSnapshotter` is not Sendable; it is only started once and cancelled.
    private final class SnapshotterBox: @unchecked Sendable {
        let value: MKMapSnapshotter
        init(_ value: MKMapSnapshotter) { self.value = value }
    }
}

/// Awaits a callback-based job that may never call back once cancelled (`MKMapSnapshotter`): a cancelled task gets
/// `CancellationError` at once, and a callback after that (or a second one) is ignored.
enum CancellableCallback {
    static func run<Value: Sendable>(start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void,
                                     cancel: @escaping @Sendable () -> Void) async throws -> Value {
        let once = Once<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                guard once.attach(continuation) else { return }   // cancelled before it started
                start { once.finish($0) }
            }
        } onCancel: {
            cancel()
            once.finish(.failure(CancellationError()))
        }
    }

    /// Resumes the continuation with the first result, whichever side (callback or cancellation) comes first.
    private final class Once<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var early: Result<Value, Error>?
        private var done = false

        /// False when a result (the cancellation) came before the continuation; it has been resumed with it.
        func attach(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
            let pending = lock.withLock { () -> Result<Value, Error>? in
                if let early { return early }
                self.continuation = continuation
                return nil
            }
            guard let pending else { return true }
            continuation.resume(with: pending)
            return false
        }

        func finish(_ result: Result<Value, Error>) {
            let waiting = lock.withLock { () -> CheckedContinuation<Value, Error>? in
                guard !done else { return nil }
                done = true
                if continuation == nil { early = result }
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: result)
        }
    }
}

/// Media lookups over OpenClicky's lookup services (docs/lookups.md): photos through the image-search slot (public
/// https results, `nopeople:` checked by the people filter and checked again on the photo actually shown), places
/// through MapKit with a map snapshot, quotes through market data, and site icons from the public favicon service.
public struct LiveDrawingMediaLookups: DrawingMediaLookups {
    public var services: LookupServices
    public var loader: DrawingImageLoader
    public var maps: (any DrawingMapSnapshotting)?
    /// Looks at the photo that will actually be shown when the query said `nopeople:`.
    public var peopleDetector: (any PeopleDetecting)?
    /// Candidates tried per photo before giving up.
    public var candidates: Int

    public init(services: LookupServices, loader: DrawingImageLoader = DrawingImageLoader(),
                maps: (any DrawingMapSnapshotting)? = MapKitMapSnapshotter(), peopleDetector: (any PeopleDetecting)? = VisionPeopleDetector(),
                candidates: Int = 4) {
        self.services = services
        self.loader = loader
        self.maps = maps
        self.peopleDetector = peopleDetector
        self.candidates = candidates
    }

    public func photo(_ query: PhotoQuery) async throws -> DrawingPhoto {
        guard let search = services.imageSearch else { throw services.unavailableError(.imageSearch) }
        let results = try await search.find(query, count: candidates)
        var lastError: Error = DrawingMediaError.noUsablePhoto
        var sawPeople = false
        for result in results where result.mayShowPeople != true || !query.excludePeople {
            try Task.checkCancellation()
            // The smaller rendition first: a card is a few hundred points wide.
            let urls = [result.thumbnailURL, result.imageURL].compactMap { $0 }.filter(PublicURL.isPublic)
            for url in urls {
                do {
                    let data = try await loader.download(url)
                    if query.excludePeople, let peopleDetector, (try? await peopleDetector.containsPeople(data)) != false {
                        sawPeople = true
                        break
                    }
                    return DrawingPhoto(image: try await loader.decode(data), result: result)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
        }
        throw sawPeople ? DrawingMediaError.showsPeople : lastError
    }

    public func place(_ query: PlaceQuery) async throws -> Place {
        guard let places = services.places else { throw services.unavailableError(.places) }
        var wider = query
        wider.limit = max(query.limit, 5)
        let found = try await places.searchPlaces(wider)
        let best = Self.bestPlace(for: query.text, in: found)
        // A search around `near` sometimes finds only a street named after the place; the same words without the
        // region usually find the landmark itself. Take it when it is close to where the program said.
        if let near = query.near, best?.category == nil {
            wider.near = nil
            if let landmark = Self.bestPlace(for: query.text, in: (try? await places.searchPlaces(wider)) ?? []), landmark.category != nil,
               Self.meters(near, landmark.coordinate) <= 5_000 {
                return landmark
            }
        }
        guard let best else { throw LookupError.notFound("No place matched \"\(query.text)\".") }
        return best
    }

    /// Great-circle distance in metres.
    static func meters(_ a: PlaceCoordinate, _ b: PlaceCoordinate) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * rad, dLon = (b.longitude - a.longitude) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// A card shows one place: prefer a point of interest (it has a category) whose name shares words with the
    /// query over a street address that merely contains one of them. Ties keep the provider's order.
    static func bestPlace(for query: String, in places: [Place]) -> Place? {
        let wanted = Set(ElementLabelMatcher.normalize(query).split(separator: " ").map(String.init))
        func score(_ place: Place) -> Double {
            let words = Set(ElementLabelMatcher.normalize(place.name).split(separator: " ").map(String.init))
            let shared = Double(words.intersection(wanted).count) / Double(max(1, words.count))
            return shared + (place.category != nil ? 0.5 : 0)
        }
        return places.enumerated().max { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa != sb ? sa < sb : a.offset > b.offset
        }?.element
    }

    public func map(around coordinate: PlaceCoordinate, size: CGSize) async -> DrawingMediaImage? {
        try? await maps?.snapshot(around: coordinate, size: size, spanMeters: 900)
    }

    public func quote(symbol: String, range: QuoteRange) async throws -> MarketQuote {
        guard let market = services.marketData else { throw services.unavailableError(.marketData) }
        return try await market.quote(symbol: symbol, range: range)
    }

    /// A picture at a direct address (`image()`): public https only, the loader's size and type guards.
    public func image(at url: URL) async throws -> DrawingMediaImage {
        try await loader.load(url)
    }

    /// The configured icon service first, then the other one (each knows sites the other doesn't).
    public func favicon(host: String) async throws -> DrawingMediaImage {
        let preferred = services.imageSearch?.favicons.service ?? .duckDuckGo
        let order = [preferred] + FaviconService.allCases.filter { $0 != preferred }
        var lastError: Error = DrawingMediaError.notPublic
        for service in order {
            guard let url = FaviconLookup(service: service).url(for: host, size: 64) else { continue }
            do {
                return try await loader.load(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
