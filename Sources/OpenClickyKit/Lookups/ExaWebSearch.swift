// Exa search API (the provider HeyClicky's agent search was hinted to use).
//
// Checked against https://docs.exa.ai/reference/search on 2026-10-30:
// - `POST https://api.exa.ai/search`, auth `x-api-key: <key>` (or `Authorization: Bearer`).
// - Body: `query` (required), `type` auto (default) | lite | deep-lite | deep, `numResults` 1...100 (default 10),
//   `startPublishedDate` / `endPublishedDate` (ISO 8601), `includeDomains`, `category`, and
//   `contents{text, highlights{query, maxCharacters}, summary}`. `highlights.numSentences` is deprecated.
// - Response: `requestId`, `results[]` with `title`, `url`, `publishedDate` (described as YYYY-MM-DD, typed date-time;
//   both are parsed), `author`, `id`, `image`, `favicon`, `text`, `highlights[]` (strings), `highlightScores[]`,
//   `summary`; plus `costDollars{total, …}` and `searchTime`.
// - Errors: `{"requestId", "error", "tag"}`.

import Foundation

public struct ExaWebSearch: WebSearchProvider {
    public static let defaultBaseURL = URL(string: "https://api.exa.ai")!
    public let providerID = "exa"
    let endpoint: LookupEndpoint
    /// Injected so freshness filters are testable.
    let now: @Sendable () -> Date

    public init(endpoint: LookupEndpoint, now: @escaping @Sendable () -> Date = Date.init) {
        self.endpoint = endpoint
        self.now = now
    }

    public func search(_ query: WebSearchQuery) async throws -> [WebSearchResult] {
        let text = try LookupQueryText.require(query.text, limit: 2_000)
        let key = try endpoint.requireKey(provider: "Exa", service: "Web search")
        var body: [String: JSONValue] = [
            "query": .string(text),
            "type": "auto",
            "numResults": .number(Double(query.clampedCount)),
            "contents": ["highlights": ["maxCharacters": 600]],
        ]
        if let start = query.freshness.startDate(now: now()) { body["startPublishedDate"] = .string(LookupDates.iso(start)) }
        let request = endpoint.post(endpoint.url("search"), body: .object(body), headers: ["x-api-key": key])
        let json = try await endpoint.fetchJSON(request, provider: providerID)
        return Self.results(from: json).prefix(query.clampedCount).map { $0 }
    }

    static func results(from json: JSONValue) -> [WebSearchResult] {
        (json["results"]?.arrayValue ?? []).compactMap { item in
            guard let url = LookupWebURL.parse(item["url"]?.stringValue) else { return nil }
            let highlights = (item["highlights"]?.arrayValue ?? []).compactMap { $0.stringValue.map(LookupText.collapseWhitespace) }
                .filter { !$0.isEmpty }
            let fallback = LookupText.nonEmpty(item["summary"]?.stringValue)
                ?? LookupText.nonEmpty(item["text"]?.stringValue).map { LookupText.truncate(LookupText.collapseWhitespace($0), to: 400) }
            let snippet = highlights.first ?? fallback ?? ""
            let title = LookupText.nonEmpty(item["title"]?.stringValue).map(LookupText.collapseWhitespace) ?? LookupText.displayHost(url)
            return WebSearchResult(title: title, url: url, snippet: snippet, age: LookupDates.age(from: item["publishedDate"]?.stringValue),
                                   extraSnippets: Array(highlights.dropFirst()))
        }
    }
}

extension ExaWebSearch: CustomStringConvertible, CustomReflectable {
    public var description: String { "ExaWebSearch(base: \(endpoint.redactedBase))" }
    public var customMirror: Mirror { Mirror(self, children: ["base": endpoint.redactedBase], displayStyle: .struct) }
}
