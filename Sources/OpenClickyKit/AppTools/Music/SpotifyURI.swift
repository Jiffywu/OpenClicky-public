import Foundation

/// A validated Spotify item reference, e.g. `spotify:track:4uLU6hMCjMI75M1A2tKUQC`.
///
/// Only strict forms are accepted, so a URI can be spliced into AppleScript or a URL without escaping surprises:
/// a known kind and a 22-character base-62 id, or the older `spotify:user:<name>:playlist:<id>`.
public struct SpotifyURI: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case track, album, playlist, artist, episode, show
    }

    public let kind: Kind
    public let id: String
    /// The canonical `spotify:` text.
    public let rawValue: String

    public var description: String { rawValue }
    public var url: URL { URL(string: rawValue)! }

    public init(kind: Kind, id: String) throws {
        guard Self.isValidID(id) else { throw ToolArgumentError("\"\(id)\" is not a Spotify id.") }
        self.kind = kind
        self.id = id
        self.rawValue = "spotify:\(kind.rawValue):\(id)"
    }

    /// Accepts `spotify:` URIs and `https://open.spotify.com/...` links (with or without a locale segment or query).
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("spotify:") {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3, let kind = Kind(rawValue: parts[1].lowercased()), Self.isValidID(parts[2]) {
                self.kind = kind
                self.id = parts[2]
                self.rawValue = "spotify:\(kind.rawValue):\(parts[2])"
                return
            }
            if parts.count == 5, parts[1].lowercased() == "user", Self.isValidUser(parts[2]),
               parts[3].lowercased() == "playlist", Self.isValidID(parts[4]) {
                self.kind = .playlist
                self.id = parts[4]
                self.rawValue = "spotify:user:\(parts[2]):playlist:\(parts[4])"
                return
            }
            return nil
        }
        guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "open.spotify.com" else { return nil }
        var path = components.path.split(separator: "/").map(String.init)
        if let first = path.first, first.lowercased().hasPrefix("intl-") || first.lowercased() == "embed" { path.removeFirst() }
        guard path.count == 2, let kind = Kind(rawValue: path[0].lowercased()), Self.isValidID(path[1]) else { return nil }
        self.kind = kind
        self.id = path[1]
        self.rawValue = "spotify:\(kind.rawValue):\(path[1])"
    }

    static func isValidID(_ id: String) -> Bool {
        id.count == 22 && id.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    static func isValidUser(_ user: String) -> Bool {
        (1...64).contains(user.count)
            && user.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// `spotify:search:<words>`: opens Spotify's search for the words (it shows results; it does not play).
    public static func searchURL(_ query: String) -> URL? {
        let words = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = words.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "spotify:search:\(encoded)")
    }
}
