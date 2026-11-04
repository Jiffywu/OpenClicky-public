import Foundation

/// Public favicon services. Drawings put a small grey site icon next to a source credit; HeyClicky fetches these
/// from a public icon service too (parity §6.1 lists `icons.duckduckgo.com/ip3/`). No key, no cookies.
public enum FaviconService: String, Codable, Sendable, CaseIterable {
    /// `https://icons.duckduckgo.com/ip3/<host>.ico`
    case duckDuckGo = "duckduckgo"
    /// `https://www.google.com/s2/favicons?domain=<host>&sz=<px>`
    case google
}

public struct FaviconLookup: Sendable, Hashable {
    public var service: FaviconService

    public init(service: FaviconService = .duckDuckGo) { self.service = service }

    /// The bare, lower-cased host for a domain, host or URL string ("https://www.NYTimes.com/x" → "www.nytimes.com"),
    /// or nil when it is not a public internet host.
    public static func host(from text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let parsed = URL(string: trimmed), var host = parsed.host, !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        guard let check = URL(string: "https://\(host)"), PublicURL.isPublic(check) else { return nil }
        // Icon services want a name, not an address.
        if host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) || host.contains(":") { return nil }
        return host
    }

    /// The icon URL for a site, or nil for hosts that are not public.
    public func url(for site: String, size: Int = 64) -> URL? {
        guard let host = Self.host(from: site) else { return nil }
        switch service {
        case .duckDuckGo:
            return URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
        case .google:
            var components = URLComponents(string: "https://www.google.com/s2/favicons")!
            components.queryItems = [URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: String(min(max(size, 16), 256)))]
            return components.url
        }
    }

    /// The icon as an image result, so `favicon:` photo queries flow through the same path as photos.
    public func result(for site: String, size: Int = 64) -> ImageResult? {
        guard let host = Self.host(from: site), let icon = url(for: host, size: size) else { return nil }
        return ImageResult(imageURL: icon, thumbnailURL: icon, sourcePageURL: URL(string: "https://\(host)/"), title: host,
                           width: size, height: size, provider: "favicon", mayShowPeople: false)
    }
}

/// Finds the preview picture a page declares for link cards (`og:image`, `twitter:image`, `link rel=image_src`).
/// Drawings use it for "the article's own photo". Reads at most `maxBytes` of HTML, public https pages only.
public struct PagePreviewImageLookup: Sendable {
    let http: any HTTPTransport
    let userAgent: String
    let maxBytes: Int

    public init(http: any HTTPTransport = URLSessionTransport.publicWebOnly, userAgent: String = LookupEndpoint.defaultUserAgent,
                maxBytes: Int = 768 * 1024) {
        self.http = http
        self.userAgent = userAgent
        self.maxBytes = maxBytes
    }

    /// The page's preview image, or nil when the page has none (or is not HTML).
    public func previewImage(for page: URL, title: String? = nil) async throws -> ImageResult? {
        guard PublicURL.isPublic(page) else {
            throw LookupError.invalidQuery("Only public https pages can be read for a preview image.")
        }
        var request = URLRequest(url: page)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await http.stream(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError(provider: "page-preview", status: response.statusCode, message: "the page could not be read")
        }
        let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "text/html").lowercased()
        guard type.contains("html") else { return nil }
        // Redirects end where URLSession says; resolve relative image paths against the final page.
        let finalPage = response.url.flatMap { PublicURL.isPublic($0) ? $0 : nil } ?? page
        var html = Data()
        for try await chunk in stream {
            let newBytes = html.count
            html.append(chunk)
            // Only the new bytes (and a tag split across chunks) are searched, so many small chunks stay linear.
            if html.count >= maxBytes || Self.headEnds(in: html, searchingFrom: newBytes) { break }
        }
        guard let image = Self.previewImageURL(in: String(decoding: html.prefix(maxBytes), as: UTF8.self), page: finalPage) else { return nil }
        return ImageResult(imageURL: image, thumbnailURL: image, sourcePageURL: finalPage, title: title, provider: "page-preview",
                           keywords: title.map { [$0] } ?? [])
    }

    /// Whether `</head>` (any case) occurs in `data`, looking only at bytes from `offset` on plus the few before it that
    /// could start a tag split across chunks.
    static func headEnds(in data: Data, searchingFrom offset: Int) -> Bool {
        let needle = Array("</head>".utf8)
        let first = data.startIndex + max(0, offset - (needle.count - 1))
        let last = data.endIndex - needle.count
        guard first <= last else { return false }
        for start in first...last {
            var matched = true
            for (index, expected) in needle.enumerated() {
                var byte = data[start + index]
                if (0x41...0x5A).contains(byte) { byte += 0x20 }
                if byte != expected { matched = false; break }
            }
            if matched { return true }
        }
        return false
    }

    /// The best preview image declared in `html`, resolved against `page` and limited to public https URLs.
    static func previewImageURL(in html: String, page: URL) -> URL? {
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
        let priority = ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"]
        var found: [String: String] = [:]
        var linked: String?
        for tag in HTMLTags.tags(named: ["meta", "link"], in: head) {
            let attributes = tag.attributes
            if tag.name == "meta" {
                let key = (attributes["property"] ?? attributes["name"] ?? "").lowercased()
                if priority.contains(key), found[key] == nil, let content = attributes["content"] { found[key] = content }
            } else if (attributes["rel"] ?? "").lowercased().split(separator: " ").contains("image_src"), linked == nil {
                linked = attributes["href"]
            }
        }
        let candidates = priority.compactMap { found[$0] } + [linked].compactMap { $0 }
        for candidate in candidates {
            let text = LookupText.decodeEntities(candidate.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !text.isEmpty, let url = URL(string: text, relativeTo: page)?.absoluteURL ?? URL(string: text) else { continue }
            if PublicURL.isPublic(url) { return url }
        }
        return nil
    }
}

/// A tiny tag scanner for `<meta>` and `<link>` in a page head. Not an HTML parser: it reads start tags and
/// their attributes, which is all a preview-image lookup needs.
enum HTMLTags {
    struct Tag {
        var name: String
        var attributes: [String: String]
    }

    static func tags(named names: Set<String>, in html: String) -> [Tag] {
        var tags: [Tag] = []
        var index = html.startIndex
        while let open = html[index...].firstIndex(of: "<") {
            guard let close = html[open...].firstIndex(of: ">") else { break }
            let inner = html[html.index(after: open)..<close]
            index = html.index(after: close)
            let name = inner.prefix { $0.isLetter }.lowercased()
            guard names.contains(name) else { continue }
            tags.append(Tag(name: name, attributes: attributes(String(inner.dropFirst(name.count)))))
        }
        return tags
    }

    /// `property="og:image" content='x' data-x=y` → lower-cased names to raw values.
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var rest = Substring(text)
        func skipSpace() { rest = rest.drop { $0.isWhitespace || $0 == "/" } }
        while true {
            skipSpace()
            let name = rest.prefix { !$0.isWhitespace && $0 != "=" && $0 != "/" && $0 != ">" }
            guard !name.isEmpty else { break }
            rest = rest.dropFirst(name.count)
            rest = rest.drop { $0.isWhitespace }
            var value = ""
            if rest.first == "=" {
                rest = rest.dropFirst().drop { $0.isWhitespace }
                if let quote = rest.first, quote == "\"" || quote == "'" {
                    rest = rest.dropFirst()
                    value = String(rest.prefix { $0 != quote })
                    rest = rest.dropFirst(value.count)
                    rest = rest.dropFirst()
                } else {
                    value = String(rest.prefix { !$0.isWhitespace })
                    rest = rest.dropFirst(value.count)
                }
            }
            let key = name.lowercased()
            if result[key] == nil { result[key] = value }
        }
        return result
    }
}
