// `WWW-Authenticate` parsing (RFC 9110 §11.6.1 grammar, RFC 6750 §3 Bearer parameters, RFC 9728 §5.1
// `resource_metadata`). MCP servers answer 401 and 403 with a Bearer challenge that says where the
// protected-resource metadata lives and which scopes the request needs.

import Foundation

public struct WWWAuthenticateChallenge: Sendable, Hashable {
    /// Auth scheme as sent ("Bearer").
    public var scheme: String
    /// Parameters with lower-cased names and unquoted values.
    public var parameters: [String: String]

    public init(scheme: String, parameters: [String: String] = [:]) {
        self.scheme = scheme
        self.parameters = parameters
    }

    public var resourceMetadata: URL? { parameters["resource_metadata"].flatMap(URL.init(string:)) }
    /// Space-separated scopes the server says this request needs.
    public var scope: String? { parameters["scope"] }
    public var error: String? { parameters["error"] }
    public var errorDescription: String? { parameters["error_description"] }

    /// Every challenge in a header value. Several challenges may share one header, separated by commas.
    public static func parse(_ header: String) -> [WWWAuthenticateChallenge] {
        var scanner = ChallengeScanner(Array(header.unicodeScalars))
        var challenges: [WWWAuthenticateChallenge] = []
        while true {
            scanner.skip { $0 == " " || $0 == "\t" || $0 == "," }
            guard let scheme = scanner.token(), !scheme.isEmpty else { break }
            var challenge = WWWAuthenticateChallenge(scheme: scheme)
            while true {
                scanner.skip { $0 == " " || $0 == "\t" }
                let mark = scanner.position
                guard let name = scanner.token(), !name.isEmpty else { break }
                scanner.skip { $0 == " " || $0 == "\t" }
                guard scanner.consume("=") else {
                    // A bare token: the start of the next challenge (or token68, which MCP does not use).
                    scanner.position = mark
                    break
                }
                scanner.skip { $0 == " " || $0 == "\t" }
                let value = scanner.peek() == "\"" ? scanner.quoted() : (scanner.token() ?? "")
                challenge.parameters[name.lowercased()] = value
                scanner.skip { $0 == " " || $0 == "\t" }
                if !scanner.consume(",") { break }
            }
            challenges.append(challenge)
        }
        return challenges
    }

    /// The Bearer challenge in a header value, if any.
    public static func bearer(from header: String?) -> WWWAuthenticateChallenge? {
        guard let header else { return nil }
        return parse(header).first { $0.scheme.caseInsensitiveCompare("Bearer") == .orderedSame }
    }
}

private struct ChallengeScanner {
    let scalars: [Unicode.Scalar]
    var position = 0

    init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

    func peek() -> Unicode.Scalar? { position < scalars.count ? scalars[position] : nil }

    mutating func skip(while predicate: (Unicode.Scalar) -> Bool) {
        while let scalar = peek(), predicate(scalar) { position += 1 }
    }

    mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        guard peek() == scalar else { return false }
        position += 1
        return true
    }

    /// An RFC 9110 token. Unquoted values that are not strict tokens (seen in the wild, e.g. bare URLs with `/`
    /// and `:`) are read up to the next comma, whitespace or `=`.
    mutating func token() -> String? {
        let start = position
        while let scalar = peek(), scalar != ",", scalar != " ", scalar != "\t", scalar != "=" { position += 1 }
        return position > start ? String(String.UnicodeScalarView(scalars[start..<position])) : nil
    }

    mutating func quoted() -> String {
        guard consume("\"") else { return "" }
        var value = String.UnicodeScalarView()
        while let scalar = peek() {
            position += 1
            if scalar == "\\", let escaped = peek() {
                value.append(escaped)
                position += 1
            } else if scalar == "\"" {
                break
            } else {
                value.append(scalar)
            }
        }
        return String(value)
    }
}
