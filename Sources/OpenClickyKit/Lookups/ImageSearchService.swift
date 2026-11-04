import Foundation

/// The photo query a drawing writes for `photo()`, `image` and `source` marks (04 §13.9), parsed:
///
///     [nopeople:] <name>                      a photo of the thing itself
///     [nopeople:] web: <words>                whatever a web image search shows
///     [nopeople:] page: <url> :: <name>       the page's own preview picture, else a photo of <name>
///     favicon: <host>                         the site's icon
public struct PhotoQuery: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        case subject(String)
        case web(String)
        case page(URL, name: String)
        case favicon(String)
    }

    public var target: Target
    public var excludePeople: Bool

    public init(_ target: Target, excludePeople: Bool = false) {
        self.target = target
        self.excludePeople = excludePeople
    }

    public static func parse(_ text: String) -> PhotoQuery? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var excludePeople = false
        if let stripped = strip("nopeople:", from: rest) {
            excludePeople = true
            rest = stripped
        }
        if let host = strip("favicon:", from: rest) {
            let site = host.trimmingCharacters(in: .whitespaces)
            return site.isEmpty ? nil : PhotoQuery(.favicon(site), excludePeople: excludePeople)
        }
        if let words = strip("web:", from: rest) {
            let query = LookupText.collapseWhitespace(String(words))
            return query.isEmpty ? nil : PhotoQuery(.web(query), excludePeople: excludePeople)
        }
        if let page = strip("page:", from: rest) {
            let parts = page.components(separatedBy: "::")
            let address = parts[0].trimmingCharacters(in: .whitespaces)
            let name = LookupText.collapseWhitespace(parts.dropFirst().joined(separator: "::"))
            if let url = URL(string: address), PublicURL.isPublic(url) {
                return PhotoQuery(.page(url, name: name), excludePeople: excludePeople)
            }
            return name.isEmpty ? nil : PhotoQuery(.subject(name), excludePeople: excludePeople)
        }
        let name = LookupText.collapseWhitespace(String(rest))
        return name.isEmpty ? nil : PhotoQuery(.subject(name), excludePeople: excludePeople)
    }

    private static func strip(_ prefix: String, from text: Substring) -> Substring? {
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        return text.dropFirst(prefix.count).drop { $0.isWhitespace }
    }
}

/// The image-search slot as the brain tools and the drawing see it: providers in preference order, the people
/// filter, page previews and favicons. Every URL it returns is public https.
public struct ImageSearchService: Sendable {
    /// Tried in order; the first that returns usable photos answers.
    public var providers: [any ImageSearchProvider]
    public var favicons: FaviconLookup
    public var pagePreview: PagePreviewImageLookup?
    public var peopleFilter: PeopleFilter

    public init(providers: [any ImageSearchProvider], favicons: FaviconLookup = FaviconLookup(),
                pagePreview: PagePreviewImageLookup? = PagePreviewImageLookup(), peopleFilter: PeopleFilter = PeopleFilter()) {
        self.providers = providers
        self.favicons = favicons
        self.pagePreview = pagePreview
        self.peopleFilter = peopleFilter
    }

    public var providerIDs: [String] { providers.map(\.providerID) }

    public func search(_ query: ImageSearchQuery) async throws -> [ImageResult] {
        var chosen = providers.filter { $0.modes.contains(query.mode) }
        // No web image index configured: a subject search is the closest thing.
        if chosen.isEmpty { chosen = providers }
        guard !chosen.isEmpty else {
            throw LookupError.unavailable(service: "Image search", reason: "no image search provider is configured")
        }
        let wanted = query.clampedCount
        var request = query
        // Over-fetch when some hits will be filtered out.
        if query.excludePeople { request.count = min(wanted * 3, 30) }
        var firstError: Error?
        for provider in chosen {
            do {
                let found = Self.unique(try await provider.searchImages(request))
                let kept = query.excludePeople
                    ? await peopleFilter.withoutPeople(found, limit: wanted)
                    : Array(PeopleFilter.annotate(found).prefix(wanted))
                // A cancelled people check drops every photo; say "cancelled", not "nothing found".
                try Task.checkCancellation()
                if !kept.isEmpty { return kept }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return []
    }

    /// Resolves a drawing's photo query to candidates, best first.
    public func find(_ photo: PhotoQuery, count: Int = 3) async throws -> [ImageResult] {
        switch photo.target {
        case .favicon(let site):
            guard let icon = favicons.result(for: site) else { throw LookupError.invalidQuery("\"\(site)\" is not a public site.") }
            return [icon]
        case .subject(let name):
            return try await search(ImageSearchQuery(name, count: count, mode: .subject, excludePeople: photo.excludePeople))
        case .web(let words):
            return try await search(ImageSearchQuery(words, count: count, mode: .web, excludePeople: photo.excludePeople))
        case .page(let url, let name):
            var preview: [ImageResult] = []
            if let pagePreview, let image = try? await pagePreview.previewImage(for: url, title: name.isEmpty ? nil : name) {
                preview = photo.excludePeople ? await peopleFilter.withoutPeople([image], limit: 1) : PeopleFilter.annotate([image])
            }
            try Task.checkCancellation()
            guard !name.isEmpty else { return preview }
            let more: [ImageResult]
            do {
                more = try await search(ImageSearchQuery(name, count: count, mode: .subject, excludePeople: photo.excludePeople))
            } catch let error where preview.isEmpty || error is CancellationError {
                // With no page picture to show, the search error (missing key, outage) is the answer.
                throw error
            } catch {
                more = []
            }
            return Array(Self.unique(preview + more).prefix(max(count, 1)))
        }
    }

    static func unique(_ results: [ImageResult]) -> [ImageResult] {
        var seen = Set<URL>()
        return results.filter { seen.insert($0.imageURL).inserted }
    }
}
