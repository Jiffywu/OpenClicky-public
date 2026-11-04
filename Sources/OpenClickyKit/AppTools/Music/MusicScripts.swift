import Foundation

// AppleScript source for the music tools. Built as plain text so tests can check exactly what would run; nothing
// here executes anything.

public enum AppleScriptText {
    /// A double-quoted AppleScript string literal holding `text`.
    ///
    /// Backslashes and straight double quotes are escaped. Line breaks, tabs and other control or format characters
    /// become spaces, so the text can neither end the literal nor start a new statement. (Curly quotes do not end
    /// an AppleScript string, so they pass through.)
    public static func literal(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\u{2028}", "\u{2029}": out += " "
            default:
                if CharacterSet.controlCharacters.contains(scalar) { out += " " } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// What a music app's player reported.
public struct PlayerSnapshot: Sendable, Hashable {
    /// "playing", "paused", "stopped", or "not_running".
    public var state: String
    /// Spotify: the `spotify:track:` URI. Music: the persistent id.
    public var trackID: String?
    public var name: String?
    public var artist: String?

    public init(state: String, trackID: String? = nil, name: String? = nil, artist: String? = nil) {
        self.state = state
        self.trackID = trackID
        self.name = name
        self.artist = artist
    }

    public var isPlaying: Bool { state == "playing" }

    /// Field separator the scripts put between values (ASCII unit separator, never in track names).
    static let separator: Character = "\u{1F}"

    /// The separator-delimited fields of a script's output.
    public static func fields(_ output: String) -> [String] {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    }

    /// Parses `state<US>id<US>name<US>artist` (the last three optional).
    public static func parse(_ output: String) -> PlayerSnapshot {
        let fields = fields(output)
        func field(_ index: Int) -> String? { index < fields.count && !fields[index].isEmpty ? fields[index] : nil }
        return PlayerSnapshot(state: field(0)?.lowercased() ?? "unknown", trackID: field(1), name: field(2), artist: field(3))
    }
}

/// Spotify's AppleScript dictionary: `play track <uri> [in context <uri>]`, `player state`, `current track`.
public enum SpotifyScript {
    public static func play(_ uri: SpotifyURI, inContext context: SpotifyURI? = nil) -> String {
        let contextClause = context.map { " in context \(AppleScriptText.literal($0.rawValue))" } ?? ""
        return """
        tell application "Spotify"
        \tplay track \(AppleScriptText.literal(uri.rawValue))\(contextClause)
        end tell
        """
    }

    /// Reports the player without launching Spotify: "not_running" when it is closed.
    public static let playerState = """
    if application "Spotify" is running then
    \ttell application "Spotify"
    \t\tset sep to character id 31
    \t\tset report to (player state as text)
    \t\ttry
    \t\t\tset t to current track
    \t\t\tset report to report & sep & (id of t) & sep & (name of t) & sep & (artist of t)
    \t\tend try
    \t\treturn report
    \tend tell
    end if
    return "not_running"
    """
}

/// What to look for in the Music library.
public enum MusicLibraryKind: String, Sendable, Hashable, CaseIterable {
    case track, album, playlist, artist
}

/// The Music app's AppleScript dictionary: `search library playlist 1 for … only names|albums|artists`, `play`,
/// user playlists by name. Searches the user's own library (Apple Music catalog search is not scriptable).
public enum AppleMusicScript {
    public static let notFoundMarker = "none"
    public static let playedMarker = "ok"

    public static func play(query: String, artist: String?, kind: MusicLibraryKind) -> String {
        let q = AppleScriptText.literal(query)
        if kind == .playlist {
            return """
            tell application "Music"
            \tset sep to character id 31
            \tset lists to (every user playlist whose name contains \(q))
            \tif (count of lists) is 0 then return "\(notFoundMarker)"
            \tset picked to item 1 of lists
            \tplay picked
            \treturn "\(playedMarker)" & sep & (name of picked) & sep & ""
            end tell
            """
        }
        let area = switch kind {
        case .album: "albums"
        case .artist: "artists"
        default: "names"
        }
        let preferArtist = artist.map { name in
            """

            \trepeat with candidate in hits
            \t\tif (artist of candidate) contains \(AppleScriptText.literal(name)) then
            \t\t\tset picked to contents of candidate
            \t\t\texit repeat
            \t\tend if
            \tend repeat
            """
        } ?? ""
        return """
        tell application "Music"
        \tset sep to character id 31
        \tset hits to (search library playlist 1 for \(q) only \(area))
        \tset picked to missing value\(preferArtist)
        \tif picked is missing value then
        \t\tif (count of hits) is 0 then return "\(notFoundMarker)"
        \t\tset picked to item 1 of hits
        \tend if
        \tplay picked
        \treturn "\(playedMarker)" & sep & (name of picked) & sep & (artist of picked)
        end tell
        """
    }

    public static let playerState = """
    if application "Music" is running then
    \ttell application "Music"
    \t\tset sep to character id 31
    \t\tset report to (player state as text)
    \t\ttry
    \t\t\tset t to current track
    \t\t\tset report to report & sep & (persistent ID of t) & sep & (name of t) & sep & (artist of t)
    \t\tend try
    \t\treturn report
    \tend tell
    end if
    return "not_running"
    """
}
