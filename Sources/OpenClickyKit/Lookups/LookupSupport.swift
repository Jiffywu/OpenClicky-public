import Foundation

/// How a lookup adapter reaches its API: base URL, the user's key (if the API needs one) and the network.
/// The services factory reads the key from the credential store, so adapters never touch the Keychain.
public struct LookupEndpoint: Sendable {
    public var baseURL: URL
    public var apiKey: String?
    public var http: any HTTPTransport
    /// Sent on every request. Wikimedia asks API clients to identify themselves this way.
    public var userAgent: String
    /// Per-request timeout. Lookups sit in the middle of a spoken answer, so they fail fast.
    public var timeout: TimeInterval

    public static let defaultUserAgent = "OpenClicky/1.0 (macOS assistant; https://github.com/Jiffywu/OpenClicky-public)"

    public init(baseURL: URL, apiKey: String? = nil, http: any HTTPTransport = URLSessionTransport(),
                userAgent: String = LookupEndpoint.defaultUserAgent, timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.http = http
        self.userAgent = userAgent
        self.timeout = timeout
    }

    /// `baseURL` + `path`, tolerating slashes on either side, with query items appended.
    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let trimmed = path.drop { $0 == "/" }
        let joined = URL(string: trimmed.isEmpty ? base : "\(base)/\(trimmed)") ?? baseURL
        guard !query.isEmpty, var components = URLComponents(url: joined, resolvingAgainstBaseURL: false) else { return joined }
        components.queryItems = (components.queryItems ?? []) + query
        // URLComponents leaves "+" alone in queries, but most servers read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? joined
    }

    func get(_ url: URL, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    func post(_ url: URL, body: JSONValue, headers: [String: String] = [:]) -> URLRequest {
        var request = get(url, headers: headers)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.jsonString().utf8)
        return request
    }

    /// The key, or a `LookupError.unavailable` naming the provider.
    func requireKey(provider: String, service: String) throws -> String {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw LookupError.unavailable(service: service, reason: "no \(provider) API key is stored")
        }
        return key
    }

    /// Sends a request and decodes a JSON body. Non-2xx statuses become a `ProviderError` with the API's own error
    /// text; the key is scrubbed from that text in case a server echoes it back.
    func fetchJSON(_ request: URLRequest, provider: String) async throws -> JSONValue {
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError(provider: provider, status: response.statusCode,
                                message: redact(LookupErrorText.message(from: data, status: response.statusCode)))
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            let preview = String(decoding: data.prefix(200), as: UTF8.self)
            throw ProviderError(provider: provider, status: response.statusCode, message: redact("unreadable response: \(preview)"))
        }
    }

    func redact(_ text: String) -> String {
        guard let key = apiKey, key.count >= 4 else { return text }
        return text.replacingOccurrences(of: key, with: "[redacted]")
    }

    /// The base URL with any user, password or query hidden, for descriptions and logs.
    var redactedBase: String { ProviderContext.redacted(baseURL) }
}

// Printing, interpolating or dumping an endpoint shows its host, never its key.
extension LookupEndpoint: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "LookupEndpoint(base: \(redactedBase), apiKey: \(apiKey?.isEmpty == false ? "<redacted>" : "none"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["base": redactedBase, "apiKey": apiKey?.isEmpty == false ? "<redacted>" : "none",
                                "timeout": timeout], displayStyle: .struct)
    }
}

/// Pulls the human message out of the error bodies the lookup APIs document.
enum LookupErrorText {
    static func message(from body: Data, status: Int) -> String {
        if let json = try? JSONDecoder().decode(JSONValue.self, from: body), let message = message(in: json) {
            return message
        }
        let text = String(decoding: body.prefix(2_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text
    }

    static func message(in json: JSONValue) -> String? {
        // Brave: {"error": {"code", "detail", "status"}}; MediaWiki: {"error": {"code", "info"}};
        // Exa: {"error": "...", "tag"}; Tavily: {"detail": {"error": "..."}}; Twelve Data: {"code", "message", "status"};
        // Alpha-Vantage-style notes as a last resort.
        if let error = json["error"] {
            if let text = error.stringValue, !text.isEmpty { return text }
            for key in ["detail", "message", "info", "code"] {
                if let text = error[key]?.stringValue, !text.isEmpty { return text }
            }
        }
        if let detail = json["detail"] {
            if let text = detail.stringValue, !text.isEmpty { return text }
            // Tavily's 422: `{"detail": [{"loc", "msg", "type", "input"}]}`.
            if let first = detail.arrayValue?.first, let text = first["msg"]?.stringValue, !text.isEmpty {
                let field = (first["loc"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0.intValue.map(String.init) }.last
                return field.map { "\($0): \(text)" } ?? text
            }
            if let text = detail["error"]?.stringValue ?? detail["message"]?.stringValue, !text.isEmpty { return text }
        }
        for key in ["message", "Error Message", "Information", "Note"] {
            if let text = json[key]?.stringValue, !text.isEmpty { return text }
        }
        return nil
    }
}

/// Text clean-up shared by the adapters.
enum LookupText {
    /// Removes tags and decodes the entities search snippets commonly carry (`<strong>`, `&amp;`, `&#39;`).
    static func plain(_ html: String) -> String {
        var out = ""
        out.reserveCapacity(html.count)
        var inTag = false
        for character in html {
            if character == "<" { inTag = true; continue }
            if character == ">" && inTag { inTag = false; continue }
            if !inTag { out.append(character) }
        }
        return collapseWhitespace(decodeEntities(out))
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                let name = String(text[text.index(after: index)..<semicolon])
                if let decoded = entity(name) {
                    result.append(decoded)
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    private static func entity(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "hellip": return "…"
        case "mdash": return "—"
        case "ndash": return "–"
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Shortens to at most `limit` characters on a word boundary, with an ellipsis.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let boundary = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return boundary.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }

    static func displayHost(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Only https URLs on public hosts are handed to the drawing and widgets. Search indexes occasionally return
/// intranet, loopback or plain-http links; a photo loader must never be pointed at those.
///
/// IP literals are judged by the address the system resolver would connect to. It reads IPv4 shorthand, hex and octal
/// (`127.1`, `0x7f.0.0.1`, `0177.0.0.1`), so only a plain dotted quad counts as an address here and every other numeric
/// form is refused; IPv6 is parsed with `inet_pton` and must be global unicast.
public enum PublicURL {
    public static func isPublic(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if host.contains(":") || host.contains("%") { return ipv6Bytes(host).map(isPublicIPv6) ?? false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
            || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.contains(where: \.isEmpty) else { return false }
        // No top-level domain starts with a digit, so a host ending in one is an address.
        if labels.last?.first?.isNumber == true {
            guard let octets = dottedQuad(labels) else { return false }
            return isPublicIPv4(octets)
        }
        // A bare name with no dot is an intranet host.
        return labels.count >= 2
    }

    /// The four octets of a plain `a.b.c.d` address (decimal, no leading zeros), else nil.
    static func dottedQuad(_ labels: [Substring]) -> [Int]? {
        guard labels.count == 4 else { return nil }
        var octets: [Int] = []
        for label in labels {
            guard (1...3).contains(label.count), label.allSatisfy({ $0.isASCII && $0.isNumber }),
                  label == "0" || !label.hasPrefix("0"), let value = Int(label), value <= 255 else { return nil }
            octets.append(value)
        }
        return octets
    }

    static func isPublicIPv4(_ o: [Int]) -> Bool {
        switch (o[0], o[1], o[2]) {
        case (0, _, _), (10, _, _), (127, _, _), (169, 254, _), (192, 168, _): return false
        case (172, 16...31, _): return false
        case (100, 64...127, _): return false // carrier-grade NAT (and Tailscale)
        case (192, 0, 0), (192, 0, 2), (192, 88, 99), (198, 18...19, _), (198, 51, 100), (203, 0, 113): return false // special and documentation ranges
        case (224...255, _, _): return false // multicast, reserved, broadcast
        default: return true
        }
    }

    /// The 16 bytes of an IPv6 literal, or nil when `inet_pton` rejects it (zone ids included).
    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// Global unicast (2000::/3) only, without documentation, Teredo, and 6to4 wrapping a non-public IPv4 address.
    /// Loopback, unspecified, IPv4-mapped and -compatible, NAT64, link-local, site-local, unique-local and multicast all
    /// fall outside 2000::/3.
    static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16, b[0] & 0xE0 == 0x20 else { return false }
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0D, b[3] == 0xB8 { return false } // 2001:db8::/32
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x00, b[3] == 0x00 { return false } // 2001::/32 Teredo
        if b[0] == 0x20, b[1] == 0x02 { return isPublicIPv4(b[2...5].map(Int.init)) } // 2002::/16 6to4
        return true
    }

    /// Parses a string from an API as a public https URL. Protocol-relative `//host/path` becomes https.
    static func parse(_ string: String?) -> URL? {
        guard var text = LookupText.nonEmpty(string) else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        guard let url = URL(string: text), isPublic(url) else { return nil }
        return url
    }
}

/// Dates as the lookup APIs send them.
enum LookupDates {
    static func parse(_ text: String?) -> Date? {
        guard let text = LookupText.nonEmpty(text) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "EEE, dd MMM yyyy HH:mm:ss zzz"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// "2026-10-12" in UTC: short, unambiguous and stable for the model to read.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// A provider's date string shown as a day when it parses, else as given.
    static func age(from text: String?) -> String? {
        guard let text = LookupText.nonEmpty(text) else { return nil }
        return parse(text).map(day) ?? text
    }
}

extension JSONValue {
    /// A number sent either as a JSON number or as a numeric string (Twelve Data sends strings).
    var looseDouble: Double? {
        switch self {
        case .number(let value): return value.isFinite ? value : nil
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
            guard let value = Double(trimmed), value.isFinite else { return nil }
            return value
        default: return nil
        }
    }

    /// A whole number in Int's range; nil for anything bigger rather than a crash.
    var looseInt: Int? { looseDouble.flatMap { Int(exactly: $0.rounded(.towardZero)) } }

    var looseBool: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let text): return ["true", "1", "yes"].contains(text.lowercased()) ? true : (["false", "0", "no"].contains(text.lowercased()) ? false : nil)
        case .number(let value): return value != 0
        default: return nil
        }
    }
}

/// Refuses redirects that leave the public internet, so a public page or image URL cannot bounce a fetch to a LAN
/// address, a loopback service or a cloud metadata endpoint. Used for page previews and thumbnail checks, which fetch
/// URLs that came from search results. (Hostnames that resolve to private addresses are not caught here.)
final class PublicRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, PublicURL.isPublic(url) else { return nil }
        return request
    }
}

extension URLSessionTransport {
    /// For fetching third-party pages and images: no cookies or cache shared with the rest of the app, and redirects
    /// only to public https hosts (a refused redirect comes back as its 3xx response, which callers treat as a failure).
    public static let publicWebOnly: URLSessionTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        return URLSessionTransport(session: URLSession(configuration: configuration, delegate: PublicRedirectGuard(), delegateQueue: nil))
    }()
}
