// Tavily search API.
//
// Checked against https://docs.tavily.com/documentation/api-reference/endpoint/search on 2026-10-30:
// - `POST https://api.tavily.com/search`, auth `Authorization: Bearer tvly-…`.
// - Body: `query` (required), `search_depth` advanced | basic (default) | fast | ultra-fast, `topic` general | news |
//   finance, `max_results` 0...20 (default 10), `time_range` day | week | month | year (or d/w/m/y), `start_date` /
//   `end_date`, `include_answer`, `include_images`, `include_favicon`, `include_raw_content`,
//   `include_published_date` (adds `published_date` to each result; null when undetectable).
// - Response: `query`, `answer?`, `images[]`, `results[]` with `title`, `url`, `content`, `score`, `raw_content?`,
//   `published_date?`, `favicon?`; plus `response_time`, `usage{credits}`, `request_id`.
// - Errors (400, 401, 429, …): `{"detail": {"error": "…"}}`.

import Foundation

public struct TavilyWebSearch: WebSearchProvider {
    public static let defaultBaseURL = URL(string: "https://api.tavily.com")!
    public let providerID = "tavily"
    let endpoint: LookupEndpoint

    public init(endpoint: LookupEndpoint) { self.endpoint = endpoint }

    public func search(_ query: WebSearchQuery) async throws -> [WebSearchResult] {
        let text = try LookupQueryText.require(query.text, limit: 400)
        let key = try endpoint.requireKey(provider: "Tavily", service: "Web search")
        var body: [String: JSONValue] = [
            "query": .string(text),
            "search_depth": "basic",
            "max_results": .number(Double(query.clampedCount)),
            "include_published_date": true,
        ]
        if query.freshness != .any { body["time_range"] = .string(query.freshness.rawValue) }
        let request = endpoint.post(endpoint.url("search"), body: .object(body), headers: ["Authorization": "Bearer \(key)"])
        let json = try await endpoint.fetchJSON(request, provider: providerID)
        return Self.results(from: json).prefix(query.clampedCount).map { $0 }
    }

    static func results(from json: JSONValue) -> [WebSearchResult] {
        (json["results"]?.arrayValue ?? []).compactMap { item in
            guard let url = LookupWebURL.parse(item["url"]?.stringValue) else { return nil }
            let title = LookupText.nonEmpty(item["title"]?.stringValue).map(LookupText.collapseWhitespace) ?? LookupText.displayHost(url)
            let snippet = LookupText.truncate(LookupText.collapseWhitespace(item["content"]?.stringValue ?? ""), to: 600)
            return WebSearchResult(title: title, url: url, snippet: snippet, age: LookupDates.age(from: item["published_date"]?.stringValue))
        }
    }
}

extension TavilyWebSearch: CustomStringConvertible, CustomReflectable {
    public var description: String { "TavilyWebSearch(base: \(endpoint.redactedBase))" }
    public var customMirror: Mirror { Mirror(self, children: ["base": endpoint.redactedBase], displayStyle: .struct) }
}
