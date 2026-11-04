// Brave Search API: web results and image results with one subscription key.
//
// Checked against Brave's docs on 2026-10-30:
// - Web: https://api-dashboard.search.brave.com/documentation/services/web-search and the API reference
//   (/api-reference/web/search/get). `GET {base}/web/search`, header `X-Subscription-Token`. Query `q` (the reference allows
//   600 characters / 75 words; at most 400 are sent), `count` 1...20 (default 20), `offset` 0...9, `freshness` pd | pw | pm | py | YYYY-MM-DDtoYYYY-MM-DD,
//   `safesearch` off | moderate | strict, `extra_snippets=true` for up to five more excerpts. Results are
//   `web.results[]` with `title`, `url`, `description` (may hold <strong> markup), optional `age` ("2 days ago"),
//   `page_age` (ISO date), `extra_snippets`, `meta_url`, `thumbnail`.
// - Images: https://api-dashboard.search.brave.com/documentation/services/image-search and
//   /api-reference/images/image_search. `GET {base}/images/search`, same header, `q`, `count` up to 200 (default 50),
//   `safesearch` strict (default) | off, `spellcheck`. Results are `results[]` with `title`, `url` (the page),
//   `source`, `page_fetched`, `thumbnail{src,width,height}` (Brave's proxy, 500 px wide),
//   `properties{url (original image), placeholder, width, height}`, `meta_url{hostname, favicon, …}`, `confidence`.
// - Errors: a JSON body whose `error` object carries `code`, `detail` and `status` (parsed generically).

import Foundation

public struct BraveWebSearch: WebSearchProvider {
    public static let defaultBaseURL = URL(string: "https://api.search.brave.com/res/v1")!
    public let providerID = "brave"
    let endpoint: LookupEndpoint

    public init(endpoint: LookupEndpoint) { self.endpoint = endpoint }

    public func search(_ query: WebSearchQuery) async throws -> [WebSearchResult] {
        let text = try LookupQueryText.require(query.text, limit: 400)
        let key = try endpoint.requireKey(provider: "Brave Search", service: "Web search")
        var items = [URLQueryItem(name: "q", value: text),
                     URLQueryItem(name: "count", value: String(query.clampedCount)),
                     URLQueryItem(name: "extra_snippets", value: "true")]
        if let freshness = Self.freshnessCode(query.freshness) { items.append(URLQueryItem(name: "freshness", value: freshness)) }
        let request = endpoint.get(endpoint.url("web/search", query: items), headers: ["X-Subscription-Token": key])
        let json = try await endpoint.fetchJSON(request, provider: providerID)
        return Self.results(from: json).prefix(query.clampedCount).map { $0 }
    }

    static func freshnessCode(_ freshness: SearchFreshness) -> String? {
        switch freshness {
        case .any: nil
        case .day: "pd"
        case .week: "pw"
        case .month: "pm"
        case .year: "py"
        }
    }

    static func results(from json: JSONValue) -> [WebSearchResult] {
        (json["web"]?["results"]?.arrayValue ?? []).compactMap { item in
            guard let url = LookupWebURL.parse(item["url"]?.stringValue) else { return nil }
            let title = LookupText.plain(item["title"]?.stringValue ?? "")
            let snippet = LookupText.plain(item["description"]?.stringValue ?? "")
            let extras = (item["extra_snippets"]?.arrayValue ?? []).compactMap { $0.stringValue.map(LookupText.plain) }.filter { !$0.isEmpty }
            let age = LookupText.nonEmpty(item["age"]?.stringValue) ?? LookupDates.age(from: item["page_age"]?.stringValue)
            return WebSearchResult(title: title.isEmpty ? LookupText.displayHost(url) : title, url: url, snippet: snippet,
                                   age: age, extraSnippets: extras)
        }
    }
}

public struct BraveImageSearch: ImageSearchProvider {
    public let providerID = "brave"
    public let modes: Set<ImageSearchQuery.Mode> = [.subject, .web]
    let endpoint: LookupEndpoint

    public init(endpoint: LookupEndpoint) { self.endpoint = endpoint }

    public func searchImages(_ query: ImageSearchQuery) async throws -> [ImageResult] {
        let text = try LookupQueryText.require(query.text, limit: 400)
        let key = try endpoint.requireKey(provider: "Brave Search", service: "Image search")
        let items = [URLQueryItem(name: "q", value: text),
                     URLQueryItem(name: "count", value: String(query.clampedCount)),
                     URLQueryItem(name: "safesearch", value: "strict")]
        let request = endpoint.get(endpoint.url("images/search", query: items), headers: ["X-Subscription-Token": key])
        let json = try await endpoint.fetchJSON(request, provider: providerID)
        return Self.results(from: json).prefix(query.clampedCount).map { $0 }
    }

    static func results(from json: JSONValue) -> [ImageResult] {
        (json["results"]?.arrayValue ?? []).compactMap { item in
            let original = PublicURL.parse(item["properties"]?["url"]?.stringValue)
            let thumbnail = PublicURL.parse(item["thumbnail"]?["src"]?.stringValue)
            guard let image = original ?? thumbnail else { return nil }
            let title = LookupText.nonEmpty(item["title"]?.stringValue).map(LookupText.plain)
            return ImageResult(imageURL: image, thumbnailURL: thumbnail, sourcePageURL: LookupWebURL.parse(item["url"]?.stringValue),
                               title: title,
                               width: item["properties"]?["width"]?.looseInt ?? (original == nil ? item["thumbnail"]?["width"]?.looseInt : nil),
                               height: item["properties"]?["height"]?.looseInt ?? (original == nil ? item["thumbnail"]?["height"]?.looseInt : nil),
                               provider: "brave",
                               credit: LookupText.nonEmpty(item["source"]?.stringValue) ?? LookupText.nonEmpty(item["meta_url"]?["hostname"]?.stringValue),
                               keywords: title.map { [$0] } ?? [])
        }
    }
}

/// Web result links: http or https only (a search result may be plain http; photos may not).
enum LookupWebURL {
    static func parse(_ string: String?) -> URL? {
        guard let text = LookupText.nonEmpty(string), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// Query checks shared by the adapters.
enum LookupQueryText {
    /// The trimmed query, cut to `limit` characters, or `LookupError.invalidQuery` when blank.
    static func require(_ text: String, limit: Int) throws -> String {
        let trimmed = LookupText.collapseWhitespace(text)
        guard !trimmed.isEmpty else { throw LookupError.invalidQuery("The search words are empty.") }
        return String(trimmed.prefix(limit))
    }
}

extension BraveWebSearch: CustomStringConvertible, CustomReflectable {
    public var description: String { "BraveWebSearch(base: \(endpoint.redactedBase))" }
    public var customMirror: Mirror { Mirror(self, children: ["base": endpoint.redactedBase], displayStyle: .struct) }
}

extension BraveImageSearch: CustomStringConvertible, CustomReflectable {
    public var description: String { "BraveImageSearch(base: \(endpoint.redactedBase))" }
    public var customMirror: Mirror { Mirror(self, children: ["base": endpoint.redactedBase], displayStyle: .struct) }
}
