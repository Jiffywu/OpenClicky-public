import CoreGraphics
import Foundation

// Photos, place cards, stock cards and site icons in drawings (docs/dsl-media.md). The media pieces
// (`Resources/js/media-api.js`) push a card in a "loading" state and send a `request` event; the host looks the thing up
// here while the voice talks and answers with `DrawingSession.patch(ref, fields)`. Images never enter JavaScript: the
// patch names them by key, and the painter reads them from a `DrawingMediaStore`.

/// What a media piece asked for, decoded from the engine's `request` event.
public struct DrawingMediaRequest: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case photo, place, stock, favicon
        /// A picture from a direct address (`image()`).
        case image
    }

    public var ref: String
    public var markID: String
    public var kind: Kind
    /// The photo query (`[nopeople:] name | web: words | page: url :: name`) or the place to look up.
    public var query: String?
    public var symbol: String?
    public var range: QuoteRange
    public var host: String?
    public var near: PlaceCoordinate?
    /// The picture's address for `image` (public https only).
    public var url: URL?

    public init(ref: String, markID: String, kind: Kind, query: String? = nil, symbol: String? = nil, range: QuoteRange = .day,
                host: String? = nil, near: PlaceCoordinate? = nil, url: URL? = nil) {
        self.url = url
        self.ref = ref
        self.markID = markID
        self.kind = kind
        self.query = query
        self.symbol = symbol
        self.range = range
        self.host = host
        self.near = near
    }

    /// A media request, or nil for other plugins' requests and malformed ones.
    public init?(event: DrawingEvent) {
        guard case .request(let ref, let mark, let json) = event else { return nil }
        self.init(ref: ref, mark: mark, json: json)
    }

    public init?(ref: String, mark: String, json: JSONValue) {
        guard let raw = json["kind"]?.stringValue, let kind = Kind(rawValue: raw) else { return nil }
        self.init(ref: ref, markID: mark, kind: kind)
        query = json["query"]?.stringValue.flatMap { Self.clean($0, max: 700) }
        symbol = json["symbol"]?.stringValue.flatMap { Self.clean($0, max: 20) }
        host = json["host"]?.stringValue.flatMap { Self.clean($0, max: 253) }
        url = json["url"]?.stringValue.flatMap { Self.clean($0, max: 1000) }.flatMap(URL.init(string:))
            .flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        if let raw = json["range"]?.stringValue, let parsed = QuoteRange(rawValue: raw) { range = parsed }
        if let pair = json["near"]?.arrayValue, pair.count == 2, let lat = pair[0].doubleValue, let lon = pair[1].doubleValue {
            let coordinate = PlaceCoordinate(latitude: lat, longitude: lon)
            if coordinate.isValid { near = coordinate }
        }
        switch kind {
        case .photo, .place: if query == nil { return nil }
        case .stock: if symbol == nil { return nil }
        case .favicon: if host == nil { return nil }
        case .image: if url == nil { return nil }
        }
    }

    /// The same lookup gives the same answer: requests with equal keys share one result and one image.
    public var cacheKey: String {
        switch kind {
        case .photo: "photo|\(query ?? "")"
        case .place: "place|\(query ?? "")|\(near.map { "\($0.latitude),\($0.longitude)" } ?? "")"
        case .stock: "stock|\(symbol ?? "")|\(range.rawValue)"
        case .favicon: "favicon|\(host ?? "")"
        case .image: "image|\(url?.absoluteString ?? "")"
        }
    }

    static func clean(_ text: String, max: Int) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(max))
    }
}

/// A decoded image that may cross actors (CGImage is immutable).
public struct DrawingMediaImage: @unchecked Sendable {
    public let image: CGImage

    public init(_ image: CGImage) { self.image = image }

    public var aspect: Double { image.height > 0 ? Double(image.width) / Double(image.height) : 1 }
}

/// A photo chosen for a drawing: the image and where it came from.
public struct DrawingPhoto: Sendable {
    public var image: DrawingMediaImage
    public var result: ImageResult

    public init(image: DrawingMediaImage, result: ImageResult) {
        self.image = image
        self.result = result
    }
}

/// The lookups behind media pieces. `LiveDrawingMediaLookups` uses the lookup services; tests pass fakes.
public protocol DrawingMediaLookups: Sendable {
    /// The best photo for a query, already downloaded, guarded and decoded.
    func photo(_ query: PhotoQuery) async throws -> DrawingPhoto
    func place(_ query: PlaceQuery) async throws -> Place
    /// A small map around the place for its card, or nil when maps are unavailable.
    func map(around coordinate: PlaceCoordinate, size: CGSize) async -> DrawingMediaImage?
    func quote(symbol: String, range: QuoteRange) async throws -> MarketQuote
    func favicon(host: String) async throws -> DrawingMediaImage
    /// The picture at a direct address, downloaded with the photo guards and decoded.
    func image(at url: URL) async throws -> DrawingMediaImage
}

extension DrawingMediaLookups {
    /// Lookups that can't fetch addresses (older fakes) refuse them.
    public func image(at url: URL) async throws -> DrawingMediaImage { throw DrawingMediaError.notPublic }
}

/// Images that media marks name by key. Shared by the resolver (writes) and the painter (reads).
public final class DrawingMediaStore: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    public func image(_ key: String) -> CGImage? { lock.withLock { images[key] } }

    public func put(_ image: DrawingMediaImage, for key: String) {
        lock.withLock {
            if images[key] == nil { order.append(key) }
            images[key] = image.image
            while order.count > capacity { images[order.removeFirst()] = nil }
        }
    }

    public var count: Int { lock.withLock { images.count } }
}

/// The answer to one request: the fields that patch the mark and the images they name.
public struct DrawingMediaResolution: Sendable {
    public var fields: JSONValue
    public var images: [String: DrawingMediaImage]

    public init(fields: JSONValue, images: [String: DrawingMediaImage] = [:]) {
        self.fields = fields
        self.images = images
    }

    public var isReady: Bool { fields["state"]?.stringValue == "ready" }

    public static func failed(_ reason: String) -> DrawingMediaResolution {
        DrawingMediaResolution(fields: ["state": "failed", "reason": .string(String(reason.prefix(160)))])
    }
}

extension DrawingMediaRequest {
    /// Look the request up and turn the answer into mark fields. Never throws: failures become `state: "failed"`.
    public func resolve(with lookups: any DrawingMediaLookups) async -> DrawingMediaResolution {
        do {
            switch kind {
            case .photo:
                guard let text = query, let parsed = PhotoQuery.parse(text) else { return .failed("the photo query is empty") }
                let photo = try await lookups.photo(parsed)
                let key = cacheKey
                var fields: [String: JSONValue] = [
                    "state": "ready", "image": .string(key), "aspect": .number((photo.image.aspect * 1000).rounded() / 1000),
                    "provider": .string(photo.result.provider),
                ]
                if let title = photo.result.title.flatMap({ Self.clean($0, max: 120) }) { fields["title"] = .string(title) }
                if let credit = photo.result.credit.flatMap({ Self.clean($0, max: 120) }) { fields["credit"] = .string(credit) }
                if let license = photo.result.license.flatMap({ Self.clean($0, max: 40) }) { fields["license"] = .string(license) }
                let page = photo.result.sourcePageURL ?? photo.result.imageURL
                fields["source"] = .string(LookupText.displayHost(page))
                fields["sourceURL"] = .string(page.absoluteString)
                return DrawingMediaResolution(fields: .object(fields), images: [key: photo.image])

            case .place:
                guard let text = query else { return .failed("nothing to look up") }
                let place = try await lookups.place(PlaceQuery(text, limit: 1, near: near))
                var fields: [String: JSONValue] = [
                    "state": "ready", "title": .string(String(place.name.prefix(120))),
                    "lat": .number(place.coordinate.latitude), "lon": .number(place.coordinate.longitude),
                ]
                if let address = place.address { fields["address"] = .string(String(address.prefix(200))) }
                if let category = place.category { fields["category"] = .string(String(category.prefix(60))) }
                if let maps = place.mapsURL { fields["mapsURL"] = .string(maps.absoluteString) }
                if let phone = place.phone { fields["phone"] = .string(phone) }
                if let website = place.website { fields["website"] = .string(website.absoluteString) }
                var images: [String: DrawingMediaImage] = [:]
                if let map = await lookups.map(around: place.coordinate, size: CGSize(width: 640, height: 360)) {
                    let key = cacheKey + "|map"
                    fields["map"] = .string(key)
                    images[key] = map
                }
                return DrawingMediaResolution(fields: .object(fields), images: images)

            case .stock:
                guard let symbol else { return .failed("no ticker") }
                let quote = try await lookups.quote(symbol: symbol, range: range)
                var fields: [String: JSONValue] = [
                    "state": "ready", "symbol": .string(quote.symbol), "price": .number(quote.price), "range": .string(quote.range.rawValue),
                    "closes": .array(Self.thin(quote.recentCloses, to: 60).map { .number(($0 * 10_000).rounded() / 10_000) }),
                ]
                if let name = quote.name { fields["company"] = .string(String(name.prefix(80))) }
                if let currency = quote.currency { fields["currency"] = .string(currency) }
                if let change = quote.change { fields["change"] = .number(change) }
                if let percent = quote.changePercent { fields["changePercent"] = .number(percent) }
                if let basis = quote.startPrice ?? quote.previousClose { fields["basis"] = .number(basis) }
                if let asOf = quote.asOf { fields["asOf"] = .string(ISO8601DateFormatter().string(from: asOf)) }
                if let open = quote.isMarketOpen { fields["marketOpen"] = .bool(open) }
                return DrawingMediaResolution(fields: .object(fields))

            case .image:
                guard let url else { return .failed("no address") }
                guard PublicURL.isPublic(url) else { return .failed(DrawingMediaError.notPublic.description) }
                let image = try await lookups.image(at: url)
                let key = cacheKey
                return DrawingMediaResolution(fields: [
                    "state": "ready", "image": .string(key), "aspect": .number((image.aspect * 1000).rounded() / 1000),
                    "source": .string(LookupText.displayHost(url)), "sourceURL": .string(url.absoluteString),
                ], images: [key: image])

            case .favicon:
                guard let host else { return .failed("no site") }
                let image = try await lookups.favicon(host: host)
                let key = cacheKey
                return DrawingMediaResolution(fields: ["state": "ready", "image": .string(key)], images: [key: image])
            }
        } catch is CancellationError {
            return .failed("cancelled")
        } catch let error as LookupError {
            return .failed(error.description)
        } catch let error as DrawingMediaError {
            return .failed(error.description)
        } catch {
            return .failed("the lookup failed")
        }
    }

    /// At most `count` values, evenly picked, always keeping the last (the latest price).
    static func thin(_ values: [Double], to count: Int) -> [Double] {
        let finite = values.filter(\.isFinite)
        guard finite.count > count, count > 1 else { return finite }
        return (0..<count).map { finite[Int((Double($0) * Double(finite.count - 1) / Double(count - 1)).rounded())] }
    }
}

public enum DrawingMediaError: Error, Sendable, Equatable, CustomStringConvertible {
    case notPublic
    case tooLarge
    case notAnImage
    case httpStatus(Int)
    case noUsablePhoto
    case showsPeople

    public var description: String {
        switch self {
        case .notPublic: "the image is not on a public https host"
        case .tooLarge: "the image is too large"
        case .notAnImage: "the download was not an image"
        case .httpStatus(let code): "the image server answered \(code)"
        case .noUsablePhoto: "no usable photo was found"
        case .showsPeople: "every photo found showed people"
        }
    }
}

/// Answers media requests for a live drawing: runs each lookup once (requests with the same key share it), stores the
/// images, and patches the marks when the answers arrive.
///
///     let media = DrawingMediaResolver(lookups: LiveDrawingMediaLookups(services: services))
///     media.attach(to: session)   // after setting session.onEvent
@MainActor
public final class DrawingMediaResolver {
    public let lookups: any DrawingMediaLookups
    public let store: DrawingMediaStore
    /// Called with each answer as it is patched in (logs, tests).
    public var onResolved: ((DrawingMediaRequest, DrawingMediaResolution) -> Void)?

    private var running: [String: Task<DrawingMediaResolution, Never>] = [:]
    private var answered: [String: DrawingMediaResolution] = [:]
    private var answeredOrder: [String] = []
    private var waiting: [UUID: Task<Void, Never>] = [:]
    private let cacheLimit = 64

    public init(lookups: any DrawingMediaLookups, store: DrawingMediaStore = DrawingMediaStore()) {
        self.lookups = lookups
        self.store = store
    }

    /// Route a session's media requests here and let its painter read the images. Keeps any `onEvent` already set.
    public func attach(to session: DrawingSession) {
        session.painter.media = store
        let previous = session.onEvent
        session.onEvent = { [weak self, weak session] event in
            if let self, let session { _ = self.handle(event) { ref, fields in session.patch(ref, fields: fields) } }
            previous?(event)
        }
    }

    /// Start answering `event` if it is a media request; `patch` delivers the answer. Returns false for other events.
    @discardableResult
    public func handle(_ event: DrawingEvent, patch: @escaping @MainActor (String, JSONValue) -> Void) -> Bool {
        guard let request = DrawingMediaRequest(event: event) else { return false }
        let task = lookup(request)
        let id = UUID()
        waiting[id] = Task { [weak self] in
            let resolution = await task.value
            guard let self else { return }
            self.waiting[id] = nil
            guard !Task.isCancelled else { return }
            self.remember(request, resolution)
            patch(request.ref, resolution.fields)
            self.onResolved?(request, resolution)
        }
        return true
    }

    /// The answer for a request: cached, already running, or a new lookup.
    public func lookup(_ request: DrawingMediaRequest) -> Task<DrawingMediaResolution, Never> {
        let key = request.cacheKey
        if let done = answered[key] {
            // The store may have dropped this answer's pictures since (it keeps the latest 64); put them back.
            for (imageKey, image) in done.images where store.image(imageKey) == nil { store.put(image, for: imageKey) }
            return Task { done }
        }
        if let task = running[key] { return task }
        let lookups = self.lookups
        let store = self.store
        let task = Task.detached(priority: .userInitiated) { () -> DrawingMediaResolution in
            let resolution = await request.resolve(with: lookups)
            for (imageKey, image) in resolution.images { store.put(image, for: imageKey) }
            return resolution
        }
        running[key] = task
        return task
    }

    /// Wait until every answer started so far has been patched in.
    public func settle() async {
        while let task = waiting.values.first {
            await task.value
            // A task removes itself when it finishes; one cancelled before it started may not have.
            if let id = waiting.first(where: { $0.value == task })?.key { waiting[id] = nil }
        }
    }

    /// Drop lookups still running (a new turn started) and forget their requests.
    public func cancelAll() {
        for task in waiting.values { task.cancel() }
        waiting.removeAll()
        for task in running.values { task.cancel() }
        running.removeAll()
    }

    private func remember(_ request: DrawingMediaRequest, _ resolution: DrawingMediaResolution) {
        let key = request.cacheKey
        running[key] = nil
        // Failures are retried next time (a key may have been added, the network may be back).
        guard resolution.isReady else { return }
        if answered[key] == nil { answeredOrder.append(key) }
        answered[key] = resolution
        while answeredOrder.count > cacheLimit { answered[answeredOrder.removeFirst()] = nil }
    }
}
