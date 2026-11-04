import Foundation

// The non-model service slots (parity §2.5): web search, image search, places and market data. HeyClicky got all of
// these from its own server (`/web-search`, `/agent/web-search`, `image-search`, `place-search`, `stock-quote`);
// OpenClicky calls a public API with the user's own key, or a keyless source (Wikimedia Commons, MapKit).
// Each service is a small protocol so the brain tools, the drawing photo loader and the widgets never care which
// vendor answered. See docs/lookups.md.

// MARK: - Web search

/// How recent results must be. Providers map it to their own filter.
public enum SearchFreshness: String, Codable, Sendable, CaseIterable {
    case any, day, week, month, year

    /// The cutoff date for providers that filter by a start date.
    func startDate(now: Date) -> Date? {
        let day: TimeInterval = 86_400
        switch self {
        case .any: return nil
        case .day: return now.addingTimeInterval(-day)
        case .week: return now.addingTimeInterval(-7 * day)
        case .month: return now.addingTimeInterval(-31 * day)
        case .year: return now.addingTimeInterval(-365 * day)
        }
    }
}

public struct WebSearchQuery: Sendable, Hashable {
    public var text: String
    /// Wanted results. Providers clamp it to what they allow; 1...20 here.
    public var count: Int
    public var freshness: SearchFreshness

    public init(_ text: String, count: Int = 5, freshness: SearchFreshness = .any) {
        self.text = text
        self.count = count
        self.freshness = freshness
    }

    /// The count every adapter actually asks for.
    var clampedCount: Int { min(max(count, 1), 20) }
}

public struct WebSearchResult: Sendable, Hashable, Codable {
    public var title: String
    public var url: URL
    /// Plain text (provider markup removed), a sentence or two.
    public var snippet: String
    /// How old the page is, as the provider put it ("3 days ago") or the publication date ("2026-10-12").
    public var age: String?
    /// Further passages from the page, when the provider sends them.
    public var extraSnippets: [String]

    public init(title: String, url: URL, snippet: String, age: String? = nil, extraSnippets: [String] = []) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.age = age
        self.extraSnippets = extraSnippets
    }

    /// The site's host without `www.`, for "Sources" credits.
    public var site: String { LookupText.displayHost(url) }
}

public protocol WebSearchProvider: Sendable {
    /// Short id used in config and errors ("brave", "exa", "tavily").
    var providerID: String { get }
    func search(_ query: WebSearchQuery) async throws -> [WebSearchResult]
}

// MARK: - Image search

public struct ImageSearchQuery: Sendable, Hashable {
    public enum Mode: String, Sendable, Hashable, Codable {
        /// A photo of the named thing itself (a landmark, an animal, a product). Free-licence sources first.
        case subject
        /// Whatever the web shows for the words (news photos, screenshots, products).
        case web
    }

    public var text: String
    public var count: Int
    public var mode: Mode
    /// Skip photos that show people (faces or bodies), for drawings that must not picture anyone.
    public var excludePeople: Bool

    public init(_ text: String, count: Int = 4, mode: Mode = .subject, excludePeople: Bool = false) {
        self.text = text
        self.count = count
        self.mode = mode
        self.excludePeople = excludePeople
    }

    var clampedCount: Int { min(max(count, 1), 50) }
}

public struct ImageResult: Sendable, Hashable, Codable {
    /// The full-size (or largest offered) image.
    public var imageURL: URL
    /// A smaller rendition for quick display, when the provider has one.
    public var thumbnailURL: URL?
    /// The page the image appears on, for credits and "open source" buttons.
    public var sourcePageURL: URL?
    public var title: String?
    public var width: Int?
    public var height: Int?
    /// Which provider found it ("brave", "wikimedia-commons", "page-preview", "favicon").
    public var provider: String
    /// Licence short name, when known (Commons always has one).
    public var license: String?
    /// Author or credit line, plain text.
    public var credit: String?
    /// True when metadata or a detector says the image shows people; nil when nobody checked.
    public var mayShowPeople: Bool?
    /// Words the people heuristic reads (Commons categories, descriptions). Not shown to users.
    public var keywords: [String]

    public init(imageURL: URL, thumbnailURL: URL? = nil, sourcePageURL: URL? = nil, title: String? = nil, width: Int? = nil,
                height: Int? = nil, provider: String, license: String? = nil, credit: String? = nil,
                mayShowPeople: Bool? = nil, keywords: [String] = []) {
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
        self.sourcePageURL = sourcePageURL
        self.title = title
        self.width = width
        self.height = height
        self.provider = provider
        self.license = license
        self.credit = credit
        self.mayShowPeople = mayShowPeople
        self.keywords = keywords
    }
}

public protocol ImageSearchProvider: Sendable {
    var providerID: String { get }
    /// Modes this provider is good for. Commons only serves `.subject`; a web index serves both.
    var modes: Set<ImageSearchQuery.Mode> { get }
    func searchImages(_ query: ImageSearchQuery) async throws -> [ImageResult]
}

// MARK: - Places

public struct PlaceCoordinate: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool { (-90...90).contains(latitude) && (-180...180).contains(longitude) && latitude.isFinite && longitude.isFinite }
}

public struct PlaceQuery: Sendable, Hashable {
    public var text: String
    public var limit: Int
    /// Search around here. Nil lets the provider decide (MapKit then searches broadly).
    public var near: PlaceCoordinate?
    /// Radius around `near`, in metres.
    public var radiusMeters: Double

    public init(_ text: String, limit: Int = 5, near: PlaceCoordinate? = nil, radiusMeters: Double = 10_000) {
        self.text = text
        self.limit = limit
        self.near = near
        self.radiusMeters = radiusMeters
    }

    var clampedLimit: Int { min(max(limit, 1), 25) }
}

public struct Place: Sendable, Hashable, Codable {
    /// Stable id when the provider has one, else a name+coordinate key.
    public var id: String
    public var name: String
    public var coordinate: PlaceCoordinate
    /// One-line postal address.
    public var address: String?
    public var phone: String?
    /// The place's own website.
    public var website: URL?
    /// Human words ("Cafe", "Amusement Park").
    public var category: String?
    /// A maps link that opens the place (Apple Maps for MapKit).
    public var mapsURL: URL?
    /// IANA time zone id, when known.
    public var timeZone: String?
    /// Star rating and count; MapKit has none, a keyed places API may.
    public var rating: Double?
    public var ratingCount: Int?

    public init(id: String, name: String, coordinate: PlaceCoordinate, address: String? = nil, phone: String? = nil,
                website: URL? = nil, category: String? = nil, mapsURL: URL? = nil, timeZone: String? = nil,
                rating: Double? = nil, ratingCount: Int? = nil) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.address = address
        self.phone = phone
        self.website = website
        self.category = category
        self.mapsURL = mapsURL
        self.timeZone = timeZone
        self.rating = rating
        self.ratingCount = ratingCount
    }
}

public protocol PlaceSearchProvider: Sendable {
    var providerID: String { get }
    func searchPlaces(_ query: PlaceQuery) async throws -> [Place]
}

// MARK: - Market data

/// The span the sparkline covers.
public enum QuoteRange: String, Codable, Sendable, CaseIterable {
    case day = "1d"
    case week = "5d"
    case month = "1m"
    case quarter = "3m"
    case year = "1y"
}

public struct MarketQuote: Sendable, Hashable, Codable {
    public var symbol: String
    public var name: String?
    public var exchange: String?
    public var currency: String?
    public var price: Double
    /// Against the previous close.
    public var change: Double?
    public var changePercent: Double?
    public var open: Double?
    public var dayHigh: Double?
    public var dayLow: Double?
    public var previousClose: Double?
    public var asOf: Date?
    public var isMarketOpen: Bool?
    public var range: QuoteRange
    /// Closing prices across `range`, oldest first, for the sparkline.
    public var recentCloses: [Double]
    /// The sparkline's baseline: the previous close for a one-day range, else the first close.
    public var startPrice: Double?

    public init(symbol: String, name: String? = nil, exchange: String? = nil, currency: String? = nil, price: Double,
                change: Double? = nil, changePercent: Double? = nil, open: Double? = nil, dayHigh: Double? = nil,
                dayLow: Double? = nil, previousClose: Double? = nil, asOf: Date? = nil, isMarketOpen: Bool? = nil,
                range: QuoteRange = .day, recentCloses: [Double] = [], startPrice: Double? = nil) {
        self.symbol = symbol
        self.name = name
        self.exchange = exchange
        self.currency = currency
        self.price = price
        self.change = change
        self.changePercent = changePercent
        self.open = open
        self.dayHigh = dayHigh
        self.dayLow = dayLow
        self.previousClose = previousClose
        self.asOf = asOf
        self.isMarketOpen = isMarketOpen
        self.range = range
        self.recentCloses = recentCloses
        self.startPrice = startPrice
    }
}

public protocol MarketQuoteProvider: Sendable {
    var providerID: String { get }
    func quote(symbol: String, range: QuoteRange) async throws -> MarketQuote
}

// MARK: - Errors

public enum LookupError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The service has no usable provider (no key stored, nothing chosen). The text says how to fix it.
    case unavailable(service: String, reason: String)
    /// The request itself is unusable (blank query, bad ticker).
    case invalidQuery(String)
    /// The provider answered but nothing matched.
    case notFound(String)
    /// services.json could not be read.
    case invalidConfig(String)

    public var description: String {
        switch self {
        case .unavailable(let service, let reason): "\(service) is not set up: \(reason)"
        case .invalidQuery(let message): message
        case .notFound(let message): message
        case .invalidConfig(let message): message
        }
    }
}
