import Foundation

/// Everything an adapter needs to talk to one configured provider. The engine factory resolves the credential
/// from the Keychain when it builds the adapter, so adapters never touch the credential store.
///
/// Printing, interpolating, `dump`ing or debug-describing a context never shows the API key, the values of the
/// provider's extra headers (a gateway header can be a credential too) or the user, password and query of its base
/// URL (where some proxies take a key); only whether a key is set, the header names and the rest of the URL.
public struct ProviderContext: Sendable {
    public var provider: ProviderConfig
    public var apiKey: String?
    public var http: any HTTPTransport
    public var webSocket: any WebSocketConnector

    public init(provider: ProviderConfig, apiKey: String?, http: any HTTPTransport = URLSessionTransport(),
                webSocket: any WebSocketConnector = URLSessionWebSocketConnector()) {
        self.provider = provider
        self.apiKey = apiKey
        self.http = http
        self.webSocket = webSocket
    }

    /// `baseURL` + path, tolerating a trailing slash on either side.
    public func url(_ path: String, default fallback: String) -> URL {
        let base = (provider.baseURL?.absoluteString ?? fallback)
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: trimmedPath.isEmpty ? trimmedBase : "\(trimmedBase)/\(trimmedPath)")!
    }

    /// A JSON POST with the provider's extra headers applied.
    ///
    /// Header names compare case-insensitively, as HTTP defines them. When the provider's configured headers and the
    /// adapter's `headers` name the same field in any spelling, the adapter's value is sent and the provider's is
    /// dropped, so a gateway header can never replace the credential or protocol headers an adapter sets.
    public func jsonRequest(_ url: URL, body: JSONValue, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in Self.mergedHeaders(provider: provider.headers ?? [:], adapter: headers) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = Data(body.jsonString().utf8)
        request.timeoutInterval = 600
        return request
    }

    /// The provider's headers plus the adapter's, with the adapter's winning over any provider header of the same
    /// name in any case. Provider headers come first, each group sorted by name (case-insensitively, then exactly,
    /// so two spellings of one name always come in the same order and the same one wins).
    public static func mergedHeaders(provider: [String: String], adapter: [String: String]) -> [(String, String)] {
        let adapterNames = Set(adapter.keys.map { $0.lowercased() })
        let fromProvider = provider.filter { !adapterNames.contains($0.key.lowercased()) }.sorted(by: byName)
        let fromAdapter = adapter.sorted(by: byName)
        return (fromProvider + fromAdapter).map { ($0.key, $0.value) }
    }

    private static func byName(_ a: (key: String, value: String), _ b: (key: String, value: String)) -> Bool {
        (a.key.lowercased(), a.key) < (b.key.lowercased(), b.key)
    }
}

extension ProviderContext: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        var parts = ["provider: \(provider.id)", "dialect: \(provider.dialect.rawValue)"]
        if let baseURL = provider.baseURL { parts.append("baseURL: \(Self.redacted(baseURL))") }
        if let credential = provider.credential { parts.append("credential: \(credential)") }
        parts.append("apiKey: \(keyState)")
        if !headerNames.isEmpty { parts.append("headers: [\(headerNames.map { "\($0): <redacted>" }.joined(separator: ", "))]") }
        return "ProviderContext(\(parts.joined(separator: ", ")))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "provider": provider.id,
            "dialect": provider.dialect.rawValue,
            "baseURL": provider.baseURL.map(Self.redacted) as Any,
            "credential": provider.credential as Any,
            "apiKey": keyState,
            "headerNames": headerNames,
        ], displayStyle: .struct)
    }

    private var keyState: String { apiKey?.isEmpty == false ? "<redacted>" : "none" }

    /// `url` with its user, password and query replaced by `<redacted>` and its fragment dropped.
    static func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<redacted>" }
        let hadUser = components.percentEncodedUser != nil || components.percentEncodedPassword != nil
        let hadQuery = components.percentEncodedQuery != nil
        components.percentEncodedUser = nil
        components.percentEncodedPassword = nil
        components.percentEncodedQuery = nil
        components.percentEncodedFragment = nil
        var text = components.string ?? "<redacted>"
        if hadUser, let schemeEnd = text.range(of: "://") { text.insert(contentsOf: "<redacted>@", at: schemeEnd.upperBound) }
        if hadQuery { text += "?<redacted>" }
        return text
    }
    private var headerNames: [String] { (provider.headers ?? [:]).keys.sorted() }
}
