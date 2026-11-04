// Discovery of the authorization server for an MCP server.
//
// Checked against https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization and its
// authorization-server-discovery and client-registration pages on 2026-10-30:
// - Protected Resource Metadata (RFC 9728): use `resource_metadata` from the 401 challenge when present,
//   otherwise try `/.well-known/oauth-protected-resource/<mcp path>` and then `/.well-known/oauth-protected-resource`.
//   It lists `authorization_servers` (at least one) and optionally `scopes_supported` and `resource`.
// - Authorization Server Metadata: for an issuer with a path, try
//   `/.well-known/oauth-authorization-server/<path>`, `/.well-known/openid-configuration/<path>`, then
//   `<path>/.well-known/openid-configuration`; without a path, `/.well-known/oauth-authorization-server` then
//   `/.well-known/openid-configuration`. The document's `issuer` must equal the issuer used to build the URL.
// - PKCE: OAuth 2.1 requires S256; OpenClicky refuses servers whose metadata does not list it in
//   `code_challenge_methods_supported`.
// - Servers on the 2025-03-26 revision predate protected-resource metadata; for them the MCP server's origin is
//   the authorization server, so OpenClicky tries that origin's metadata as a last resort.

import Foundation

/// RFC 9728 protected-resource metadata.
public struct ProtectedResourceMetadata: Sendable, Hashable {
    public var resource: String?
    /// Issuer identifiers exactly as published.
    public var authorizationServers: [String]
    public var scopesSupported: [String]?

    init?(json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        let servers = (object["authorization_servers"]?.arrayValue ?? []).compactMap(\.stringValue).filter { URL(string: $0)?.host != nil }
        guard !servers.isEmpty else { return nil }
        resource = object["resource"]?.stringValue
        authorizationServers = servers
        scopesSupported = object["scopes_supported"]?.arrayValue?.compactMap(\.stringValue)
    }
}

/// RFC 8414 / OpenID Connect provider metadata: the fields OpenClicky uses.
public struct AuthorizationServerMetadata: Sendable, Hashable, Codable {
    public var issuer: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    public var scopesSupported: [String]?
    public var codeChallengeMethodsSupported: [String]?
    public var tokenEndpointAuthMethodsSupported: [String]?
    public var clientIDMetadataDocumentSupported: Bool
    /// RFC 9207: the server puts `iss` in authorization responses.
    public var authorizationResponseIssParameterSupported: Bool

    init?(json: JSONValue) {
        guard let object = json.objectValue,
              let issuer = object["issuer"]?.stringValue,
              let authorization = object["authorization_endpoint"]?.stringValue.flatMap(URL.init(string:)),
              let token = object["token_endpoint"]?.stringValue.flatMap(URL.init(string:)) else { return nil }
        self.issuer = issuer
        authorizationEndpoint = authorization
        tokenEndpoint = token
        registrationEndpoint = object["registration_endpoint"]?.stringValue.flatMap(URL.init(string:))
        scopesSupported = object["scopes_supported"]?.arrayValue?.compactMap(\.stringValue)
        codeChallengeMethodsSupported = object["code_challenge_methods_supported"]?.arrayValue?.compactMap(\.stringValue)
        tokenEndpointAuthMethodsSupported = object["token_endpoint_auth_methods_supported"]?.arrayValue?.compactMap(\.stringValue)
        clientIDMetadataDocumentSupported = object["client_id_metadata_document_supported"]?.boolValue ?? false
        authorizationResponseIssParameterSupported = object["authorization_response_iss_parameter_supported"]?.boolValue ?? false
    }
}

/// What discovery found for one MCP server.
public struct MCPAuthorizationTarget: Sendable, Hashable {
    /// The `resource` parameter (RFC 8707) to send: the metadata's `resource`, or the server's canonical URL.
    public var resource: String
    public var metadata: AuthorizationServerMetadata
    /// Scopes to ask for: the challenge's `scope`, else the resource's `scopes_supported`, else none.
    public var scopes: [String]
}

public enum MCPOAuthError: Error, Sendable, Hashable, CustomStringConvertible {
    case serverDoesNotRequireOAuth
    case discoveryFailed(String)
    case pkceUnsupported
    case clientRegistrationUnavailable
    case clientRegistrationFailed(String)
    case callbackPortUnavailable
    case authorizationDenied(String)
    case stateMismatch
    case issuerMismatch
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    /// No usable token: the user has to sign in (again).
    case needsSignIn
    case timedOut

    public var description: String {
        switch self {
        case .serverDoesNotRequireOAuth: "No browser sign-in needed: the server answered without asking for credentials."
        case .discoveryFailed(let detail): "Couldn't find where to sign in: \(detail)"
        case .pkceUnsupported: "The sign-in server doesn't support PKCE (S256), so OpenClicky won't use it."
        case .clientRegistrationUnavailable:
            "The sign-in server doesn't let apps register themselves. Enter a client ID for it, or use an API key instead."
        case .clientRegistrationFailed(let detail): "Couldn't register OpenClicky with the sign-in server: \(detail)"
        case .callbackPortUnavailable: "Couldn't open a local port for the sign-in to return to."
        case .authorizationDenied(let detail): "Sign-in wasn't completed: \(detail)"
        case .stateMismatch: "The sign-in response didn't match the request (state mismatch). Try again."
        case .issuerMismatch: "The sign-in response came from an unexpected server (issuer mismatch)."
        case .tokenExchangeFailed(let detail): "Couldn't finish signing in: \(detail)"
        case .refreshFailed(let detail): "Couldn't renew the sign-in: \(detail)"
        case .needsSignIn: "Sign in again to use this app."
        case .timedOut: "Sign-in timed out. Try again."
        }
    }
}

public struct MCPOAuthDiscovery: Sendable {
    let http: any HTTPTransport

    public init(http: any HTTPTransport) { self.http = http }

    /// Finds the authorization server and the scopes and resource to request for `serverURL`.
    public func discover(serverURL: URL, challenge: WWWAuthenticateChallenge?) async throws -> MCPAuthorizationTarget {
        let resourceMetadata = try await protectedResourceMetadata(serverURL: serverURL, challenge: challenge)
        let issuers = resourceMetadata?.authorizationServers ?? [Self.origin(of: serverURL)?.absoluteString].compactMap { $0 }
        var lastProblem = "no authorization server metadata found"
        for issuer in issuers {
            do {
                let metadata = try await authorizationServerMetadata(issuer: issuer)
                guard metadata.codeChallengeMethodsSupported?.contains("S256") == true else { throw MCPOAuthError.pkceUnsupported }
                let scopes = challenge?.scope.map { $0.split(separator: " ").map(String.init) } ?? resourceMetadata?.scopesSupported ?? []
                return MCPAuthorizationTarget(resource: resourceMetadata?.resource ?? Self.canonicalResource(serverURL),
                                              metadata: metadata, scopes: scopes)
            } catch MCPOAuthError.pkceUnsupported {
                throw MCPOAuthError.pkceUnsupported
            } catch {
                lastProblem = "\(error)"
            }
        }
        throw MCPOAuthError.discoveryFailed(lastProblem)
    }

    /// RFC 9728 metadata, or nil when the server publishes none (2025-03-26 servers).
    public func protectedResourceMetadata(serverURL: URL, challenge: WWWAuthenticateChallenge?) async throws -> ProtectedResourceMetadata? {
        var candidates: [URL] = []
        if let advertised = challenge?.resourceMetadata { candidates.append(advertised) }
        candidates += Self.protectedResourceMetadataURLs(for: serverURL)
        for url in candidates {
            guard let json = try? await getJSON(url), let metadata = ProtectedResourceMetadata(json: json) else { continue }
            // RFC 9728 §3.3: the metadata must describe this server. Same origin is required; a different
            // resource on the same origin is tolerated because many servers publish their origin as the resource.
            if let resource = metadata.resource, let resourceURL = URL(string: resource),
               Self.origin(of: resourceURL) != Self.origin(of: serverURL) {
                throw MCPOAuthError.discoveryFailed("the server's metadata names a different resource (\(resource))")
            }
            return metadata
        }
        return nil
    }

    /// Metadata for `issuer` (an identifier as published), checked to really belong to that issuer.
    public func authorizationServerMetadata(issuer: String) async throws -> AuthorizationServerMetadata {
        guard let issuerURL = URL(string: issuer) else { throw MCPOAuthError.discoveryFailed("invalid issuer \(issuer)") }
        for url in Self.authorizationServerMetadataURLs(for: issuerURL) {
            guard let json = try? await getJSON(url), let metadata = AuthorizationServerMetadata(json: json) else { continue }
            // The document's issuer must be the one we asked for (mix-up defence). Only a trailing slash may differ.
            guard Self.sameIssuer(metadata.issuer, issuer) else {
                throw MCPOAuthError.discoveryFailed("metadata at \(url.absoluteString) is for a different issuer")
            }
            return metadata
        }
        throw MCPOAuthError.discoveryFailed("no authorization server metadata for \(issuer)")
    }

    static func sameIssuer(_ a: String, _ b: String) -> Bool {
        func trimmed(_ text: String) -> String { text.hasSuffix("/") ? String(text.dropLast()) : text }
        return a == b || trimmed(a) == trimmed(b)
    }

    private func getJSON(_ url: URL) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else { throw MCPClientError.http(status: response.statusCode, body: "") }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: URL rules

    static func origin(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.url
    }

    /// The canonical server URI (RFC 8707): lower-case scheme and host, no fragment, no trailing slash.
    public static func canonicalResource(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        var text = components.string ?? url.absoluteString
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func protectedResourceMetadataURLs(for serverURL: URL) -> [URL] {
        guard let origin = origin(of: serverURL) else { return [] }
        let path = serverURL.path
        var urls: [URL] = []
        if !path.isEmpty, path != "/" {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            urls.append(URL(string: origin.absoluteString + "/.well-known/oauth-protected-resource" + trimmed)!)
        }
        urls.append(URL(string: origin.absoluteString + "/.well-known/oauth-protected-resource")!)
        return urls
    }

    static func authorizationServerMetadataURLs(for issuer: URL) -> [URL] {
        guard let origin = origin(of: issuer) else { return [] }
        var path = issuer.path
        if path.hasSuffix("/") { path.removeLast() }
        let base = origin.absoluteString
        if path.isEmpty {
            return [URL(string: base + "/.well-known/oauth-authorization-server")!,
                    URL(string: base + "/.well-known/openid-configuration")!]
        }
        return [URL(string: base + "/.well-known/oauth-authorization-server" + path)!,
                URL(string: base + "/.well-known/openid-configuration" + path)!,
                URL(string: base + path + "/.well-known/openid-configuration")!]
    }
}
