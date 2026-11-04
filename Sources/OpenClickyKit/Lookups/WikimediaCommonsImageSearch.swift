// Wikimedia Commons image search. Free-licence photos with a description page, a licence and an author, and no key.
//
// Uses the MediaWiki Action API (https://www.mediawiki.org/wiki/API:Search, API:Imageinfo), checked on 2026-10-30
// with one keyless request:
//   GET https://commons.wikimedia.org/w/api.php?action=query&format=json&formatversion=2
//       &generator=search&gsrsearch=<words> filetype:bitmap&gsrnamespace=6&gsrlimit=N
//       &prop=imageinfo&iiprop=url|size|mime|extmetadata&iiurlwidth=640&iiextmetadatafilter=…
// With formatversion=2 the hits come back as `query.pages[]` (unordered; `index` is the search rank), each with
// `title` ("File:…") and `imageinfo[0]` holding `url` (original), `descriptionurl` (the file page), `thumburl`,
// `thumbwidth`, `thumbheight`, `width`, `height`, `size` (bytes), `mime`, and `extmetadata.<Name>.value` for
// ImageDescription, ObjectName, Artist (HTML), LicenseShortName and Categories ("A|B|C"). No hits: no `query` key.
// API errors arrive with HTTP 200 as `{"error": {"code", "info"}}`.
// Wikimedia's User-Agent policy asks every client to send an identifying User-Agent; `LookupEndpoint` does.

import Foundation

public struct WikimediaCommonsImageSearch: ImageSearchProvider {
    public static let defaultBaseURL = URL(string: "https://commons.wikimedia.org/w/api.php")!
    public let providerID = "wikimedia-commons"
    public let modes: Set<ImageSearchQuery.Mode> = [.subject]
    let endpoint: LookupEndpoint
    /// Originals above this size are swapped for a scaled rendition, so photo loaders are not handed 20 MB files.
    let maxOriginalBytes: Int

    static let displayableMIME: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif"]

    public init(endpoint: LookupEndpoint = LookupEndpoint(baseURL: WikimediaCommonsImageSearch.defaultBaseURL),
                maxOriginalBytes: Int = 4_000_000) {
        self.endpoint = endpoint
        self.maxOriginalBytes = maxOriginalBytes
    }

    public func searchImages(_ query: ImageSearchQuery) async throws -> [ImageResult] {
        let text = try LookupQueryText.require(query.text, limit: 250)
        let items = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "generator", value: "search"),
            // Bitmaps only: no SVG diagrams, PDFs or audio.
            URLQueryItem(name: "gsrsearch", value: "\(text) filetype:bitmap"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: String(query.clampedCount)),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|size|mime|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "640"),
            URLQueryItem(name: "iiextmetadatafilter", value: "ImageDescription|ObjectName|Artist|LicenseShortName|Categories"),
        ]
        let request = endpoint.get(endpoint.url("", query: items))
        let json = try await endpoint.fetchJSON(request, provider: providerID)
        if let error = json["error"] {
            throw ProviderError(provider: providerID, status: nil,
                                message: error["info"]?.stringValue ?? error["code"]?.stringValue ?? "the search failed")
        }
        return results(from: json).prefix(query.clampedCount).map { $0 }
    }

    func results(from json: JSONValue) -> [ImageResult] {
        let pages = (json["query"]?["pages"]?.arrayValue ?? [])
            .sorted { ($0["index"]?.looseInt ?? .max) < ($1["index"]?.looseInt ?? .max) }
        return pages.compactMap { page in
            guard let info = page["imageinfo"]?.arrayValue?.first else { return nil }
            let mime = info["mime"]?.stringValue?.lowercased() ?? ""
            guard mime.hasPrefix("image/") else { return nil }
            let original = Self.withoutTracking(PublicURL.parse(info["url"]?.stringValue))
            let thumbnail = Self.withoutTracking(PublicURL.parse(info["thumburl"]?.stringValue))
            // Compared as a Double: a byte count too big for Int is simply too big.
            let bytes = info["size"]?.looseDouble ?? 0
            let largeRendition = (info["responsiveUrls"]?.objectValue ?? [:])
                .sorted { (Double($0.key) ?? 0) > (Double($1.key) ?? 0) }
                .lazy.compactMap { Self.withoutTracking(PublicURL.parse($0.value.stringValue)) }.first
            let originalIsUsable = original != nil && Self.displayableMIME.contains(mime) && bytes <= Double(maxOriginalBytes)
            guard let image = originalIsUsable ? original : (largeRendition ?? thumbnail) else { return nil }

            let meta = info["extmetadata"]
            func field(_ name: String) -> String? { LookupText.nonEmpty(meta?[name]?["value"]?.stringValue).map(LookupText.plain) }
            let fileTitle = Self.fileTitle(page["title"]?.stringValue)
            let description = field("ImageDescription")
            let categories = (meta?["Categories"]?["value"]?.stringValue ?? "").split(separator: "|").map(String.init)
            return ImageResult(
                imageURL: image, thumbnailURL: thumbnail ?? image,
                sourcePageURL: Self.withoutTracking(PublicURL.parse(info["descriptionurl"]?.stringValue)),
                title: field("ObjectName") ?? fileTitle,
                width: originalIsUsable ? info["width"]?.looseInt : (largeRendition == nil ? info["thumbwidth"]?.looseInt : nil),
                height: originalIsUsable ? info["height"]?.looseInt : (largeRendition == nil ? info["thumbheight"]?.looseInt : nil),
                provider: providerID, license: field("LicenseShortName"), credit: field("Artist"),
                keywords: [fileTitle, description].compactMap { $0 } + categories)
        }
    }

    /// Commons appends `utm_*` tracking parameters to file URLs; the files load the same without them.
    static func withoutTracking(_ url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = components.queryItems else { return url }
        let kept = items.filter { !$0.name.lowercased().hasPrefix("utm_") }
        guard kept.count != items.count else { return url }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    /// "File:Golden Gate Bridge, 2018.jpg" → "Golden Gate Bridge, 2018".
    static func fileTitle(_ title: String?) -> String? {
        guard var text = LookupText.nonEmpty(title) else { return nil }
        if text.hasPrefix("File:") { text.removeFirst(5) }
        if let dot = text.lastIndex(of: "."), text.distance(from: dot, to: text.endIndex) <= 5 { text = String(text[..<dot]) }
        return LookupText.nonEmpty(text.replacingOccurrences(of: "_", with: " "))
    }
}
