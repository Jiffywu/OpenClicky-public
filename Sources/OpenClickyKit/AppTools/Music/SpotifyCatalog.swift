// Optional Spotify catalog search: turns "play Hey Jude" into a track URI so playback can start directly.
// Off by default. It needs the user's own Spotify developer app (client id and secret in the Keychain as
// `spotify-client-id` and `spotify-client-secret`). Without it, play_on_spotify falls back to Spotify's search URI.
//
// Wire protocol, checked against Spotify's docs on 2026-10-30:
// - Token: https://developer.spotify.com/documentation/web-api/tutorials/client-credentials-flow
//   `POST https://accounts.spotify.com/api/token`, `Authorization: Basic base64(client_id:client_secret)`,
//   `Content-Type: application/x-www-form-urlencoded`, body `grant_type=client_credentials`. Response
//   `{access_token, token_type, expires_in}`. This flow reaches only endpoints without user data (search is one).
// - Search: https://developer.spotify.com/documentation/web-api/reference/search
//   `GET https://api.spotify.com/v1/search?q=…&type=track|album|playlist|artist&limit=…&market=…`.
//   `limit` is 0–10 (default 5). Without a market (or a user token's country) content counts as unavailable, so a
//   market is always sent. Results come under `tracks`/`albums`/`playlists`/`artists` → `items`; playlist items
//   may be null. Track items carry `uri`, `name`, `artists[{name}]`, `album{uri}`.

import Foundation
import os

/// What to look up in Spotify's catalog.
public struct SpotifySearchQuery: Sendable, Hashable {
    public var text: String
    public var artist: String?
    public var kind: MusicLibraryKind

    public init(text: String, artist: String? = nil, kind: MusicLibraryKind = .track) {
        self.text = text
        self.artist = artist
        self.kind = kind
    }
}

/// The best catalog match.
public struct SpotifyCatalogItem: Sendable, Hashable {
    public var uri: SpotifyURI
    public var name: String
    public var artists: [String]
    /// For a track, its album, so playback continues through the album.
    public var context: SpotifyURI?

    public init(uri: SpotifyURI, name: String, artists: [String] = [], context: SpotifyURI? = nil) {
        self.uri = uri
        self.name = name
        self.artists = artists
        self.context = context
    }
}

public protocol SpotifyCatalogSearching: Sendable {
    /// The best match, or nil when the catalog has nothing.
    func search(_ query: SpotifySearchQuery) async throws -> SpotifyCatalogItem?
}

/// Spotify Web API search with the client-credentials flow. The access token is cached until shortly before it
/// expires. Secrets never appear in errors or descriptions.
public final class SpotifyWebAPICatalog: SpotifyCatalogSearching, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public static let clientIDCredential = "spotify-client-id"
    public static let clientSecretCredential = "spotify-client-secret"
    public static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    public static let searchURL = URL(string: "https://api.spotify.com/v1/search")!

    private let clientID: String
    private let clientSecret: String
    private let http: any HTTPTransport
    private let market: String
    private let now: @Sendable () -> Date
    private let token = OSAllocatedUnfairLock<(value: String, expires: Date)?>(initialState: nil)

    /// - Parameter market: an ISO 3166-1 alpha-2 country code. Anything else (no region, or a UN M.49 area such as
    ///   "419" or "001", which `Locale.region` can return) becomes "US", because Spotify rejects the request otherwise.
    public init(clientID: String, clientSecret: String, http: any HTTPTransport = URLSessionTransport(),
                market: String? = Locale.current.region?.identifier, now: @escaping @Sendable () -> Date = { Date() }) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.http = http
        self.market = Self.marketCode(market)
        self.now = now
    }

    /// The country code to send as `market`: two ASCII letters, upper-cased; "US" otherwise.
    static func marketCode(_ region: String?) -> String {
        guard let region, region.count == 2,
              region.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) else { return "US" }
        return region.uppercased()
    }

    /// Builds the catalog from Keychain credentials; nil when either is missing.
    public static func fromCredentials(_ store: any CredentialStore, http: any HTTPTransport = URLSessionTransport()) -> SpotifyWebAPICatalog? {
        guard let id = try? store.secret(named: clientIDCredential), !id.isEmpty,
              let secret = try? store.secret(named: clientSecretCredential), !secret.isEmpty else { return nil }
        return SpotifyWebAPICatalog(clientID: id, clientSecret: secret, http: http)
    }

    // The client id, secret and access token are stored properties, and Swift's default description and mirror
    // print every stored property; these three keep them out of logs, `print`, `dump` and debugger output.
    public var description: String { "SpotifyWebAPICatalog(market: \(market), clientID: <redacted>, clientSecret: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["market": market, "clientID": "<redacted>", "clientSecret": "<redacted>",
                                "token": token.withLock { $0 == nil ? "none" : "<redacted>" }], displayStyle: .class)
    }

    public func search(_ query: SpotifySearchQuery) async throws -> SpotifyCatalogItem? {
        let current = try await accessToken()
        do {
            return try await searchOnce(query, token: current)
        } catch let error as ProviderError where error.status == 401 {
            // The cached token was revoked or expired early: fetch a new one once.
            token.withLock { $0 = nil }
            return try await searchOnce(query, token: try await accessToken())
        }
    }

    func searchRequest(_ query: SpotifySearchQuery, token: String) -> URLRequest {
        var components = URLComponents(url: Self.searchURL, resolvingAgainstBaseURL: false)!
        var q = query.text
        if let artist = query.artist, query.kind != .artist { q += " artist:\(artist)" }
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "type", value: query.kind.rawValue),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "market", value: market),
        ]
        // URLComponents leaves "+" alone, which servers read as a space; encode it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    private func searchOnce(_ query: SpotifySearchQuery, token: String) async throws -> SpotifyCatalogItem? {
        let data = try await http.checkedData(for: searchRequest(query, token: token), provider: "spotify")
        let body = try JSONDecoder().decode(JSONValue.self, from: data)
        return Self.firstItem(in: body, kind: query.kind)
    }

    static func firstItem(in body: JSONValue, kind: MusicLibraryKind) -> SpotifyCatalogItem? {
        let items = body["\(kind.rawValue)s"]?["items"]?.arrayValue ?? []
        for item in items where item != .null {
            guard let uriText = item["uri"]?.stringValue, let uri = SpotifyURI(uriText) else { continue }
            let artists = (item["artists"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            let owner = item["owner"]?["display_name"]?.stringValue
            let context = item["album"]?["uri"]?.stringValue.flatMap(SpotifyURI.init)
            return SpotifyCatalogItem(uri: uri, name: item["name"]?.stringValue ?? "", artists: artists.isEmpty ? (owner.map { [$0] } ?? []) : artists,
                                      context: kind == .track ? context : nil)
        }
        return nil
    }

    func tokenRequest() -> URLRequest {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        request.timeoutInterval = 15
        return request
    }

    private func accessToken() async throws -> String {
        let current = now()
        if let cached = token.withLock({ $0 }), cached.expires > current { return cached.value }
        let data: Data
        do {
            data = try await http.checkedData(for: tokenRequest(), provider: "spotify")
        } catch let error as ProviderError {
            // Keep the status, drop the body: token endpoint errors are about the credentials.
            throw ProviderError(provider: "spotify", status: error.status, message: "Spotify did not accept the client id and secret.")
        }
        let body = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let value = body["access_token"]?.stringValue, !value.isEmpty else {
            throw ProviderError(provider: "spotify", message: "The token response had no access_token.")
        }
        let lifetime = body["expires_in"]?.doubleValue ?? 3_600
        token.withLock { $0 = (value, current.addingTimeInterval(max(0, lifetime - 60))) }
        return value
    }
}
