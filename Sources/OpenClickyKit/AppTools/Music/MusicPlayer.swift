import Foundation

/// Which app the user wants the music in.
public enum MusicAppChoice: String, Sendable, Hashable, CaseIterable {
    case spotify
    case appleMusic = "apple_music"
}

/// A parsed `play_on_spotify` call.
public struct MusicPlayRequest: Sendable, Hashable {
    public var uri: SpotifyURI?
    public var query: String?
    public var artist: String?
    public var kind: MusicLibraryKind
    /// Nil: Spotify, or Music when Spotify is not installed.
    public var app: MusicAppChoice?

    public init(uri: SpotifyURI? = nil, query: String? = nil, artist: String? = nil, kind: MusicLibraryKind = .track,
                app: MusicAppChoice? = nil) {
        self.uri = uri
        self.query = query
        self.artist = artist
        self.kind = kind
        self.app = app
    }

    /// What to search for: the query plus the artist.
    var searchWords: String { [query, artist].compactMap { $0 }.joined(separator: " ") }
    var spokenName: String { query ?? artist ?? uri?.rawValue ?? "it" }
}

/// Plays music by query or Spotify URI and checks the player afterwards.
///
/// Spotify: resolve a URI (given, or from the optional catalog search). If Spotify is running, tell it over
/// AppleScript to play and read the player state back after a short settle. Otherwise, or when AppleScript is
/// refused, open the `spotify:` URI (which launches Spotify), wait for the cold start, check, and nudge it to
/// play once more if it is open but idle. With no URI, open Spotify's search for the words. Apple Music: search
/// the user's library over AppleScript and play the first match (artist preferred when given).
public struct MusicPlayer: Sendable {
    public struct Timing: Sendable, Hashable {
        /// After an AppleScript play command, before reading the player back.
        public var settle: Duration
        /// After opening a URI that may have launched Spotify.
        public var coldLaunch: Duration
        /// The most one AppleScript may take (a first-time Automation prompt waits on the user until then).
        public var script: Duration

        public init(settle: Duration = .milliseconds(400), coldLaunch: Duration = .seconds(3), script: Duration = .seconds(15)) {
            self.settle = settle
            self.coldLaunch = coldLaunch
            self.script = script
        }
    }

    public static let automationSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

    let workspace: any AppToolWorkspace
    let scripts: any AppleScriptRunning
    let catalog: (any SpotifyCatalogSearching)?
    let sleep: @Sendable (Duration) async -> Void
    let timing: Timing

    public init(workspace: any AppToolWorkspace, scripts: any AppleScriptRunning, catalog: (any SpotifyCatalogSearching)? = nil,
                timing: Timing = Timing(), sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.workspace = workspace
        self.scripts = scripts
        self.catalog = catalog
        self.timing = timing
        self.sleep = sleep
    }

    public func play(_ request: MusicPlayRequest) async -> AppToolResult {
        let spotifyInstalled = await workspace.isInstalled(bundleID: AppBundleID.spotify)
        if request.app == .appleMusic || (!spotifyInstalled && request.app == nil) {
            guard await workspace.isInstalled(bundleID: AppBundleID.music) else {
                return AppToolResult(.unavailable, "Neither Spotify nor Music is installed on this Mac.")
            }
            return await playOnAppleMusic(request)
        }
        guard spotifyInstalled else { return AppToolResult(.unavailable, "Spotify isn't installed on this Mac.") }
        return await playOnSpotify(request)
    }

    // MARK: Spotify

    func playOnSpotify(_ request: MusicPlayRequest) async -> AppToolResult {
        var notes: [String: JSONValue] = [:]
        var target: SpotifyCatalogItem?
        if let uri = request.uri {
            target = SpotifyCatalogItem(uri: uri, name: request.query ?? "")
        } else if let catalog, let query = request.query ?? request.artist {
            do {
                target = try await catalog.search(SpotifySearchQuery(text: query, artist: request.query == nil ? nil : request.artist,
                                                                    kind: request.kind))
                if target == nil { notes["catalog"] = "no_match" }
            } catch {
                notes["catalog"] = .string("error")
            }
        }

        guard let target else { return await openSpotifySearch(request, notes: notes) }
        notes["uri"] = .string(target.uri.rawValue)
        let playScript = SpotifyScript.play(target.uri, inContext: target.context)

        var automationDenied = false
        let wasRunning = await workspace.isRunning(bundleID: AppBundleID.spotify)
        // What was playing before, so a later check can tell our track from music that was already on.
        let before = wasRunning ? try? await snapshot(SpotifyScript.playerState) : nil
        if wasRunning {
            do {
                _ = try await scripts.run(playScript, timeout: timing.script)
                await sleep(timing.settle)
                if let after = try? await snapshot(SpotifyScript.playerState), isPlaying(target, after: after, before: before) {
                    return playing(after, target: target, method: "applescript", notes: notes)
                }
            } catch let error as AppleScriptError where error.isNotPermitted {
                automationDenied = true
            } catch {
                notes["applescript_error"] = .string(String(describing: error))
            }
        }

        // A newer turn cancelled this while Spotify was being asked: start nothing more.
        if Task.isCancelled { return Self.cancelled(notes) }
        // Cold start, or AppleScript did not take: hand the URI to Spotify itself.
        guard await workspace.open(target.uri.url) else {
            return AppToolResult(.failed, "Spotify did not open.", details: notes)
        }
        await sleep(timing.coldLaunch)
        if !automationDenied {
            do {
                var after = try await snapshot(SpotifyScript.playerState)
                if isPlaying(target, after: after, before: before) {
                    return playing(after, target: target, method: "url_scheme", notes: notes)
                }
                if after.state != "not_running", !Task.isCancelled {
                    // Open on the item's page but idle: ask it to play now that it is running.
                    _ = try await scripts.run(playScript, timeout: timing.script)
                    await sleep(timing.settle)
                    after = try await snapshot(SpotifyScript.playerState)
                    if isPlaying(target, after: after, before: before) {
                        return playing(after, target: target, method: "url_scheme", notes: notes)
                    }
                }
            } catch let error as AppleScriptError where error.isNotPermitted {
                automationDenied = true
            } catch {
                notes["applescript_error"] = .string(String(describing: error))
            }
        }
        if Task.isCancelled { return Self.cancelled(notes) }
        if automationDenied {
            notes["automation"] = "denied"
            notes["settings_url"] = .string(Self.automationSettingsURL)
            return AppToolResult(.unconfirmed, """
                Opened it in Spotify, but OpenClicky isn't allowed to control Spotify, so it couldn't start or check \
                playback. The user can allow it in System Settings > Privacy & Security > Automation.
                """, details: notes)
        }
        return AppToolResult(.unconfirmed, "Opened it in Spotify, but couldn't confirm it is playing.", details: notes)
    }

    func openSpotifySearch(_ request: MusicPlayRequest, notes: [String: JSONValue]) async -> AppToolResult {
        var details = notes
        guard let url = SpotifyURI.searchURL(request.searchWords) else {
            return AppToolResult(.invalidRequest, "Nothing to search for.", details: details)
        }
        if Task.isCancelled { return Self.cancelled(details) }
        details["opened"] = "search"
        guard await workspace.open(url) else { return AppToolResult(.failed, "Spotify did not open.", details: details) }
        return AppToolResult(.unconfirmed, """
            Opened Spotify's search for "\(request.searchWords)". Nothing plays by itself from search; the user \
            picks a result.
            """, details: details)
    }

    func isPlaying(_ target: SpotifyCatalogItem, after: PlayerSnapshot, before: PlayerSnapshot?) -> Bool {
        guard after.isPlaying else { return false }
        if after.trackID == target.uri.rawValue { return true }
        // Albums, playlists and artists start on some track of theirs; relinked tracks report another id. Accept a
        // change of track, or playback that was not running before.
        guard let before else { return true }
        return !before.isPlaying || before.trackID != after.trackID
    }

    func playing(_ after: PlayerSnapshot, target: SpotifyCatalogItem, method: String, notes: [String: JSONValue]) -> AppToolResult {
        var details = notes
        details["app"] = "spotify"
        details["method"] = .string(method)
        details["now_playing"] = nowPlaying(after)
        let name = after.name ?? (target.name.isEmpty ? nil : target.name)
        let artist = after.artist ?? target.artists.first
        let message = switch (name, artist) {
        case let (name?, artist?): "Now playing \"\(name)\" by \(artist) on Spotify."
        case let (name?, nil): "Now playing \"\(name)\" on Spotify."
        default: "Spotify is playing."
        }
        return AppToolResult(.completed, message, details: details)
    }

    // MARK: Apple Music

    func playOnAppleMusic(_ request: MusicPlayRequest) async -> AppToolResult {
        guard let query = request.query ?? request.artist else {
            return AppToolResult(.invalidRequest, "Music can't play a Spotify link. Give the song, album, playlist or artist name.")
        }
        let kind: MusicLibraryKind = request.query == nil ? .artist : request.kind
        let script = AppleMusicScript.play(query: query, artist: request.query == nil ? nil : request.artist, kind: kind)
        let output: String
        do {
            output = try await scripts.run(script, timeout: timing.script)
        } catch is CancellationError {
            return Self.cancelled(["app": "apple_music"])
        } catch let error as AppleScriptError where error.isNotPermitted {
            return AppToolResult(.permissionDenied, """
                OpenClicky isn't allowed to control Music. The user can allow it in System Settings > Privacy & \
                Security > Automation.
                """, details: ["app": "apple_music", "settings_url": .string(Self.automationSettingsURL)])
        } catch {
            return AppToolResult(.failed, "Music didn't take the request: \(error)", details: ["app": "apple_music"])
        }
        let played = PlayerSnapshot.fields(output)
        guard played.first == AppleMusicScript.playedMarker else {
            return AppToolResult(.notFound, "Couldn't find \"\(query)\" in the Music library.", details: ["app": "apple_music"])
        }
        await sleep(timing.settle)
        var details: [String: JSONValue] = ["app": "apple_music", "method": "applescript"]
        guard let after = try? await snapshot(AppleMusicScript.playerState), after.isPlaying else {
            return AppToolResult(.unconfirmed, "Asked Music to play it, but couldn't confirm it is playing.", details: details)
        }
        details["now_playing"] = nowPlaying(after)
        let name = after.name ?? (played.count > 1 && !played[1].isEmpty ? played[1] : query)
        let artist = after.artist ?? (played.count > 2 && !played[2].isEmpty ? played[2] : nil)
        return AppToolResult(.completed, artist.map { "Now playing \"\(name)\" by \($0) in Music." } ?? "Now playing \"\(name)\" in Music.",
                             details: details)
    }

    // MARK: Helpers

    static func cancelled(_ details: [String: JSONValue]) -> AppToolResult {
        var result = AppToolResult.cancelledByNewerTurn
        result.details = details
        return result
    }

    func snapshot(_ script: String) async throws -> PlayerSnapshot {
        PlayerSnapshot.parse(try await scripts.run(script, timeout: timing.script))
    }

    func nowPlaying(_ snapshot: PlayerSnapshot) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let name = snapshot.name { object["name"] = .string(name) }
        if let artist = snapshot.artist { object["artist"] = .string(artist) }
        if let id = snapshot.trackID { object["id"] = .string(id) }
        return .object(object)
    }
}

enum MusicTools {
    static func playOnSpotify(player: MusicPlayer) -> AppTool {
        AppTool.make(
            spec: ToolSpec(
                name: AppToolName.playOnSpotify,
                description: """
                Play music for the user: a song, album, playlist or artist, by name or by Spotify link. Plays in \
                Spotify; uses the Music app instead when Spotify isn't installed or the user asks for Apple Music. \
                Starts once you finish speaking, so say what you're putting on first. Result status: completed \
                (playing), unconfirmed (opened but not confirmed playing), not_found, unavailable, \
                permission_denied, or invalid_request.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Song, album, playlist or artist name."],
                        "artist": ["type": "string", "description": "The artist, to narrow a song or album."],
                        "kind": ["type": "string", "enum": .array(MusicLibraryKind.allCases.map { .string($0.rawValue) }),
                                 "description": "What query names (default track)."],
                        "uri": ["type": "string", "description": "A spotify: URI or open.spotify.com link, when known."],
                        "app": ["type": "string", "enum": .array(MusicAppChoice.allCases.map { .string($0.rawValue) }),
                                "description": "Only when the user names the app."],
                    ],
                    "additionalProperties": false,
                ]),
            needsFollowUpRound: false, defersUntilNarrationEnds: true, isReadOnly: false,
            statusLabel: "Starting the music…", queuedStatus: .completed,
            parse: parse,
            perform: { await player.play($0) })
    }

    static func parse(_ arguments: ToolArguments) throws -> MusicPlayRequest {
        let uriText = try arguments.string("uri", "spotify_uri", "spotifyURI", "spotifyUri", maxLength: 300)
        var uri: SpotifyURI?
        if let uriText {
            guard let parsed = SpotifyURI(uriText) else {
                throw ToolArgumentError("\"uri\" must be a spotify: URI or an open.spotify.com link.")
            }
            uri = parsed
        }
        let query = try arguments.string("query", "search_query", "searchQuery", "song", "name", maxLength: 200)
        let artist = try arguments.string("artist", maxLength: 200)
        var kind = try arguments.choice("kind", "type", as: MusicLibraryKind.self) ?? .track
        if query == nil, artist != nil, uri == nil { kind = .artist }
        let app = try arguments.choice("app", as: MusicAppChoice.self)
        guard uri != nil || query != nil || artist != nil else {
            throw ToolArgumentError("Say what to play: a song, album, playlist or artist name, or a Spotify link.")
        }
        if app == .appleMusic, query == nil, artist == nil {
            throw ToolArgumentError("Music can't play a Spotify link. Give the name of what to play.")
        }
        return MusicPlayRequest(uri: uri, query: query, artist: artist, kind: kind, app: app)
    }
}
