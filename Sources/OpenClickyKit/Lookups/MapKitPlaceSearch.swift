import Foundation
import MapKit

// Places through MapKit's local search: no key, no account, and no location permission (the search runs on Apple's
// servers; a region only biases it). Replaces HeyClicky's `place-search` route (parity §2.5 `other:places`).
//
// API notes (macOS SDK headers, checked 2026-10-30): `MKLocalSearch.Request` takes `naturalLanguageQuery`, `region`
// and `resultTypes`; `start` reports `MKLocalSearch.Response.mapItems`. On macOS 26 `MKMapItem.placemark` is
// deprecated in favour of `location`, `address` and `addressRepresentations`; both paths are handled. MapKit has no
// ratings or opening hours, so those stay empty. "Nothing found" arrives as `MKError.placemarkNotFound`.

/// What the adapter asks MapKit for, as plain values.
public struct MapKitSearchRequest: Sendable, Hashable {
    public var query: String
    public var center: PlaceCoordinate?
    public var radiusMeters: Double
    public var includeAddresses: Bool

    public init(query: String, center: PlaceCoordinate? = nil, radiusMeters: Double = 10_000, includeAddresses: Bool = true) {
        self.query = query
        self.center = center
        self.radiusMeters = radiusMeters
        self.includeAddresses = includeAddresses
    }
}

/// One MapKit hit copied out of `MKMapItem`, so it can cross actors and tests can make them by hand.
public struct MapKitItem: Sendable, Hashable {
    public var identifier: String?
    public var name: String?
    public var coordinate: PlaceCoordinate
    public var address: String?
    public var phone: String?
    public var url: URL?
    /// `MKPointOfInterestCategory.rawValue`, e.g. "MKPOICategoryCafe".
    public var category: String?
    public var timeZone: String?

    public init(identifier: String? = nil, name: String?, coordinate: PlaceCoordinate, address: String? = nil,
                phone: String? = nil, url: URL? = nil, category: String? = nil, timeZone: String? = nil) {
        self.identifier = identifier
        self.name = name
        self.coordinate = coordinate
        self.address = address
        self.phone = phone
        self.url = url
        self.category = category
        self.timeZone = timeZone
    }
}

/// The seam in front of `MKLocalSearch`. Production uses `SystemMapKitLocalSearch`; tests pass a fake.
public protocol MapKitLocalSearching: Sendable {
    func search(_ request: MapKitSearchRequest) async throws -> [MapKitItem]
}

public struct SystemMapKitLocalSearch: MapKitLocalSearching {
    public init() {}

    public func search(_ request: MapKitSearchRequest) async throws -> [MapKitItem] {
        try await Self.run(request)
    }

    @MainActor
    static func run(_ request: MapKitSearchRequest) async throws -> [MapKitItem] {
        let mkRequest = MKLocalSearch.Request()
        mkRequest.naturalLanguageQuery = request.query
        mkRequest.resultTypes = request.includeAddresses ? [.pointOfInterest, .address] : [.pointOfInterest]
        if let center = request.center {
            mkRequest.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
                                                  latitudinalMeters: request.radiusMeters * 2, longitudinalMeters: request.radiusMeters * 2)
        }
        let search = SearchBox(MKLocalSearch(request: mkRequest))
        do {
            let response = try await withTaskCancellationHandler {
                try await search.value.start()
            } onCancel: {
                Task { @MainActor in search.value.cancel() }
            }
            return response.mapItems.map(item(from:))
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        }
    }

    /// Copies what OpenClicky uses out of a map item.
    static func item(from mapItem: MKMapItem) -> MapKitItem {
        let coordinate: CLLocationCoordinate2D
        var address: String?
        if #available(macOS 26, *) {
            coordinate = mapItem.location.coordinate
            address = mapItem.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true)
                ?? mapItem.address?.fullAddress
        } else {
            coordinate = mapItem.placemark.coordinate
            address = mapItem.placemark.title
        }
        var identifier: String?
        if #available(macOS 15, *) { identifier = mapItem.identifier?.rawValue }
        return MapKitItem(identifier: identifier, name: mapItem.name,
                          coordinate: PlaceCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
                          address: address.map(oneLine), phone: mapItem.phoneNumber, url: mapItem.url,
                          category: mapItem.pointOfInterestCategory?.rawValue, timeZone: mapItem.timeZone?.identifier)
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { LookupText.collapseWhitespace(String($0)) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// `MKLocalSearch` is not Sendable; the cancel handler only hops back to the main actor with it.
    private final class SearchBox: @unchecked Sendable {
        let value: MKLocalSearch
        init(_ value: MKLocalSearch) { self.value = value }
    }
}

public struct MapKitPlaceSearch: PlaceSearchProvider {
    public let providerID = "mapkit"
    let backend: any MapKitLocalSearching

    public init(backend: any MapKitLocalSearching = SystemMapKitLocalSearch()) { self.backend = backend }

    public func searchPlaces(_ query: PlaceQuery) async throws -> [Place] {
        let text = try LookupQueryText.require(query.text, limit: 200)
        if let near = query.near, !near.isValid {
            throw LookupError.invalidQuery("The search centre is not a valid latitude and longitude.")
        }
        let radius = min(max(query.radiusMeters.isFinite ? query.radiusMeters : 10_000, 100), 200_000)
        let items = try await backend.search(MapKitSearchRequest(query: text, center: query.near, radiusMeters: radius))
        var seen = Set<String>()
        return Array(items.compactMap(Self.place(from:)).filter { seen.insert($0.id).inserted }.prefix(query.clampedLimit))
    }

    static func place(from item: MapKitItem) -> Place? {
        guard let name = LookupText.nonEmpty(item.name), item.coordinate.isValid else { return nil }
        let rounded = String(format: "%.5f,%.5f", item.coordinate.latitude, item.coordinate.longitude)
        return Place(id: LookupText.nonEmpty(item.identifier) ?? "\(name)@\(rounded)", name: name, coordinate: item.coordinate,
                     address: LookupText.nonEmpty(item.address), phone: LookupText.nonEmpty(item.phone),
                     website: item.url.flatMap { LookupWebURL.parse($0.absoluteString) }, category: categoryName(item.category),
                     mapsURL: appleMapsURL(name: name, coordinate: item.coordinate), timeZone: item.timeZone)
    }

    /// "MKPOICategoryAmusementPark" → "Amusement Park", "MKPOICategoryEVCharger" → "EV Charger".
    static func categoryName(_ raw: String?) -> String? {
        guard var text = LookupText.nonEmpty(raw) else { return nil }
        if text.hasPrefix("MKPOICategory") { text.removeFirst("MKPOICategory".count) }
        let characters = Array(text)
        var words = ""
        for (index, character) in characters.enumerated() {
            if index > 0, character.isUppercase {
                let previous = characters[index - 1]
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || (previous.isUppercase && nextIsLower) { words.append(" ") }
            }
            words.append(character)
        }
        return LookupText.nonEmpty(words)
    }

    static func appleMapsURL(name: String, coordinate: PlaceCoordinate) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: name),
                                 URLQueryItem(name: "ll", value: String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude))]
        return components.url
    }
}
