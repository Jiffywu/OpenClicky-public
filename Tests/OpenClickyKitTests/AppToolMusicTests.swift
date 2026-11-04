import Foundation
import Testing
@testable import OpenClickyKit

private let sep = "\u{1F}"
private let heyJude = "spotify:track:0aym2LBJBk9DAYuHHutrIl"
private let otherTrack = "spotify:track:4uLU6hMCjMI75M1A2tKUQC"

@Suite("AppleScript construction")
struct AppleScriptConstructionTests {
    @Test func literalsEscapeQuotesAndBackslashes() {
        #expect(AppleScriptText.literal("plain") == "\"plain\"")
        #expect(AppleScriptText.literal("say \"hi\"") == #""say \"hi\"""#)
        #expect(AppleScriptText.literal(#"a\b"#) == #""a\\b""#)
        #expect(AppleScriptText.literal("Beyoncé – “Halo”") == "\"Beyoncé – “Halo”\"")
    }

    @Test func literalsCannotEndTheStringOrStartAStatement() {
        let hostile = "x\" & (do shell script \"rm -rf ~\") & \"\nend tell\rtell app \"Finder\"\u{2028}"
        let literal = AppleScriptText.literal(hostile)
        // One string literal: the only unescaped quotes are the first and the last.
        let body = literal.dropFirst().dropLast()
        var escaped = false
        for character in body {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            #expect(character != "\"", "unescaped quote in \(literal)")
        }
        #expect(!literal.contains("\n"))
        #expect(!literal.contains("\r"))
        #expect(!literal.contains("\u{2028}"))
    }

    @Test func spotifyPlayUsesTheDictionarysPlayTrackCommand() throws {
        let uri = try #require(SpotifyURI(heyJude))
        #expect(SpotifyScript.play(uri) == """
        tell application "Spotify"
        \tplay track "\(heyJude)"
        end tell
        """)
        let album = try #require(SpotifyURI("spotify:album:0ETFjACtuP2ADo6LFhL6HN"))
        #expect(SpotifyScript.play(uri, inContext: album).contains(#"play track "\#(heyJude)" in context "spotify:album:0ETFjACtuP2ADo6LFhL6HN""#))
    }

    @Test func playerStateNeverLaunchesSpotify() {
        let script = SpotifyScript.playerState
        #expect(script.hasPrefix("if application \"Spotify\" is running then"))
        #expect(script.contains("player state as text"))
        #expect(script.hasSuffix("return \"not_running\""))
        #expect(AppleMusicScript.playerState.hasPrefix("if application \"Music\" is running then"))
    }

    @Test func appleMusicSearchesTheRightField() {
        #expect(AppleMusicScript.play(query: "Hey Jude", artist: nil, kind: .track).contains(#"search library playlist 1 for "Hey Jude" only names"#))
        #expect(AppleMusicScript.play(query: "Abbey Road", artist: nil, kind: .album).contains("only albums"))
        #expect(AppleMusicScript.play(query: "The Beatles", artist: nil, kind: .artist).contains("only artists"))
        let playlist = AppleMusicScript.play(query: "Focus", artist: nil, kind: .playlist)
        #expect(playlist.contains(#"every user playlist whose name contains "Focus""#))
        #expect(!playlist.contains("search library"))
    }

    @Test func appleMusicPrefersTheNamedArtist() {
        let script = AppleMusicScript.play(query: "Yesterday", artist: "The \"Fab\" Four", kind: .track)
        #expect(script.contains(#"if (artist of candidate) contains "The \"Fab\" Four" then"#))
        let without = AppleMusicScript.play(query: "Yesterday", artist: nil, kind: .track)
        #expect(!without.contains("candidate"))
    }

    @Test func appleMusicQueryIsEscaped() {
        let script = AppleMusicScript.play(query: "a\" & quit & \"", artist: nil, kind: .track)
        #expect(script.contains(#"for "a\" & quit & \"" only names"#))
    }

    @Test func playerSnapshotsParse() {
        let full = PlayerSnapshot.parse(["playing", heyJude, "Hey Jude", "The Beatles"].joined(separator: sep) + "\n")
        #expect(full == PlayerSnapshot(state: "playing", trackID: heyJude, name: "Hey Jude", artist: "The Beatles"))
        #expect(PlayerSnapshot.parse("not_running") == PlayerSnapshot(state: "not_running"))
        #expect(PlayerSnapshot.parse("Paused").state == "paused")
        #expect(PlayerSnapshot.parse("").state == "unknown")
    }
}

@Suite("Spotify URIs")
struct SpotifyURITests {
    @Test func acceptsURIsAndOpenLinks() {
        #expect(SpotifyURI(heyJude)?.kind == .track)
        #expect(SpotifyURI("https://open.spotify.com/album/0ETFjACtuP2ADo6LFhL6HN?si=abc")?.rawValue == "spotify:album:0ETFjACtuP2ADo6LFhL6HN")
        #expect(SpotifyURI("https://open.spotify.com/intl-de/track/0aym2LBJBk9DAYuHHutrIl")?.rawValue == heyJude)
        #expect(SpotifyURI("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")?.kind == .playlist)
        #expect(SpotifyURI("spotify:user:someone:playlist:37i9dQZF1DXcBWIGoYBM5M")?.rawValue == "spotify:user:someone:playlist:37i9dQZF1DXcBWIGoYBM5M")
        #expect(SpotifyURI("Spotify:Artist:3WrFJ7ztbogyGnTHbHJFl2")?.rawValue == "spotify:artist:3WrFJ7ztbogyGnTHbHJFl2")
    }

    @Test(arguments: [
        "spotify:track:short", "spotify:track:0aym2LBJBk9DAYuHHutrIl\"", "spotify:track:0aym2LBJBk9DAYuHHutrI!",
        "spotify:search:hey jude", "spotify:podcast:0aym2LBJBk9DAYuHHutrIl", "http://open.spotify.com/track/0aym2LBJBk9DAYuHHutrIl",
        "https://evil.com/track/0aym2LBJBk9DAYuHHutrIl", "https://open.spotify.com/track/0aym2LBJBk9DAYuHHutrIl/extra",
        "spotify:user:bad name:playlist:37i9dQZF1DXcBWIGoYBM5M", "",
    ])
    func rejectsAnythingElse(_ text: String) {
        #expect(SpotifyURI(text) == nil)
    }

    @Test func searchURLEncodesTheWords() {
        #expect(SpotifyURI.searchURL("Hey  Jude & more")?.absoluteString == "spotify:search:Hey%20Jude%20%26%20more")
        #expect(SpotifyURI.searchURL("   ") == nil)
    }
}

/// A Spotify that reports what it was last told to play, after the scripted number of state reads.
private final class FakeSpotify: @unchecked Sendable {
    let lock = NSLock()
    var playing: String?
    var deniesAutomation = false
    var ignoresPlay = false
    var startedFrom: String?

    func respond(_ source: String, workspace: RecordingWorkspace) throws -> String {
        try lock.withLock {
            if deniesAutomation, source.contains("tell application") {
                throw AppleScriptError(code: AppleScriptError.notPermittedCode, message: "Not authorized to send Apple events to Spotify. (-1743)")
            }
            if source.contains("play track") {
                if !ignoresPlay, let start = source.range(of: "play track \"") {
                    let rest = source[start.upperBound...]
                    playing = String(rest[..<rest.firstIndex(of: "\"")!])
                }
                return ""
            }
            guard workspace.isRunningNow(AppBundleID.spotify) else { return "not_running" }
            guard let playing else { return "paused" }
            return ["playing", playing, "Hey Jude", "The Beatles"].joined(separator: sep)
        }
    }
}

private struct MusicRig {
    let workspace: RecordingWorkspace
    let scripts: ScriptedAppleScriptRunner
    let player: MusicPlayer

    init(workspace: RecordingWorkspace = RecordingWorkspace(), catalog: (any SpotifyCatalogSearching)? = nil,
         respond: @escaping @Sendable (String, RecordingWorkspace) throws -> String) {
        self.workspace = workspace
        let ws = workspace
        scripts = ScriptedAppleScriptRunner { source, _ in try respond(source, ws) }
        player = MusicPlayer(workspace: workspace, scripts: scripts, catalog: catalog, sleep: { _ in })
    }
}

private struct StubCatalog: SpotifyCatalogSearching {
    var item: SpotifyCatalogItem?
    var fails = false
    let queries = QueryLog()

    final class QueryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SpotifySearchQuery] = []
        func add(_ query: SpotifySearchQuery) { lock.withLock { items.append(query) } }
        var all: [SpotifySearchQuery] { lock.withLock { items } }
    }

    func search(_ query: SpotifySearchQuery) async throws -> SpotifyCatalogItem? {
        queries.add(query)
        if fails { throw ProviderError(provider: "spotify", status: 500, message: "down") }
        return item
    }
}

@Suite("play_on_spotify")
struct MusicPlayerTests {
    @Test func parsesTheArgumentSpellingsModelsUse() throws {
        let request = try MusicTools.parse(ToolArguments(["spotifyUri": .string(heyJude), "searchQuery": "Hey Jude"]))
        #expect(request.uri?.rawValue == heyJude)
        #expect(request.query == "Hey Jude")
        #expect(request.kind == .track)

        let artistOnly = try MusicTools.parse(ToolArguments(["artist": "Radiohead"]))
        #expect(artistOnly.kind == .artist)

        let album = try MusicTools.parse(ToolArguments(["query": "OK Computer", "type": "album", "app": "apple music"]))
        #expect(album.kind == .album)
        #expect(album.app == .appleMusic)
    }

    @Test func rejectsEmptyAndMalformedRequests() {
        #expect(throws: ToolArgumentError("Say what to play: a song, album, playlist or artist name, or a Spotify link.")) {
            try MusicTools.parse(ToolArguments())
        }
        #expect(throws: ToolArgumentError("\"uri\" must be a spotify: URI or an open.spotify.com link.")) {
            try MusicTools.parse(ToolArguments(["uri": "https://evil.com/x"]))
        }
        #expect(throws: ToolArgumentError.self) { try MusicTools.parse(ToolArguments(["query": "x", "kind": "podcast"])) }
        #expect(throws: ToolArgumentError("Music can't play a Spotify link. Give the name of what to play.")) {
            try MusicTools.parse(ToolArguments(["uri": .string(heyJude), "app": "apple_music"]))
        }
    }

    @Test func runningSpotifyPlaysOverAppleScriptAndIsVerified() async throws {
        let spotify = FakeSpotify()
        let rig = MusicRig(workspace: RecordingWorkspace(running: [AppBundleID.spotify])) { try spotify.respond($0, workspace: $1) }
        let result = await rig.player.play(MusicPlayRequest(uri: SpotifyURI(heyJude), query: "Hey Jude"))
        #expect(result.status == .completed)
        #expect(result.details["method"] == "applescript")
        #expect(result.message == "Now playing \"Hey Jude\" by The Beatles on Spotify.")
        #expect(rig.workspace.events.isEmpty) // no URL fallback needed
        #expect(rig.scripts.scripts.count == 3) // state before, play, state after
        #expect(rig.scripts.scripts[1] == SpotifyScript.play(try #require(SpotifyURI(heyJude))))
    }

    @Test func closedSpotifyIsColdStartedThroughItsURIThenVerified() async {
        let spotify = FakeSpotify()
        let rig = MusicRig { try spotify.respond($0, workspace: $1) }
        // Opening the URI starts the track in the real app; the fake records it as playing.
        spotify.playing = heyJude
        let result = await rig.player.play(MusicPlayRequest(uri: SpotifyURI(heyJude)))
        #expect(result.status == .completed)
        #expect(result.details["method"] == "url_scheme")
        #expect(rig.workspace.events == [.open(URL(string: heyJude)!)])
        #expect(!rig.scripts.scripts.contains { $0.contains("play track") })
    }

    @Test func spotifyOpenButIdleAfterColdStartIsToldToPlayOnce() async {
        let spotify = FakeSpotify()
        let rig = MusicRig { try spotify.respond($0, workspace: $1) }
        let result = await rig.player.play(MusicPlayRequest(uri: SpotifyURI(heyJude)))
        #expect(result.status == .completed)
        #expect(rig.scripts.scripts.filter { $0.contains("play track") }.count == 1)
    }

    @Test func playbackThatNeverStartsIsUnconfirmed() async {
        let spotify = FakeSpotify()
        spotify.ignoresPlay = true
        let rig = MusicRig(workspace: RecordingWorkspace(running: [AppBundleID.spotify])) { try spotify.respond($0, workspace: $1) }
        let result = await rig.player.play(MusicPlayRequest(uri: SpotifyURI(heyJude)))
        #expect(result.status == .unconfirmed)
        #expect(rig.workspace.events == [.open(URL(string: heyJude)!)]) // fell back to the URI
    }

    @Test func deniedAutomationFallsBackToTheURIAndSaysWhy() async {
        let spotify = FakeSpotify()
        spotify.deniesAutomation = true
        let rig = MusicRig(workspace: RecordingWorkspace(running: [AppBundleID.spotify])) { try spotify.respond($0, workspace: $1) }
        let result = await rig.player.play(MusicPlayRequest(uri: SpotifyURI(heyJude)))
        #expect(result.status == .unconfirmed)
        #expect(result.details["automation"] == "denied")
        #expect(result.details["settings_url"] == .string(MusicPlayer.automationSettingsURL))
        #expect(rig.workspace.events == [.open(URL(string: heyJude)!)])
    }

    @Test func alreadyPlayingSomethingElseCountsOnlyWhenTheTrackChanges() async {
        let spotify = FakeSpotify()
        spotify.playing = otherTrack
        spotify.ignoresPlay = true
        let rig = MusicRig(workspace: RecordingWorkspace(running: [AppBundleID.spotify])) { try spotify.respond($0, workspace: $1) }
        let album = SpotifyURI("spotify:album:0ETFjACtuP2ADo6LFhL6HN")
        let result = await rig.player.play(MusicPlayRequest(uri: album, kind: .album))
        #expect(result.status == .unconfirmed) // still the old track: not our album
    }

    @Test func queryWithoutCatalogOpensSpotifySearchAndSaysNothingPlaysYet() async {
        let rig = MusicRig { _, _ in "" }
        let result = await rig.player.play(MusicPlayRequest(query: "Hey Jude", artist: "The Beatles"))
        #expect(result.status == .unconfirmed)
        #expect(result.details["opened"] == "search")
        #expect(rig.workspace.events == [.open(URL(string: "spotify:search:Hey%20Jude%20The%20Beatles")!)])
        #expect(rig.scripts.scripts.isEmpty)
    }

    @Test func catalogMatchIsPlayedInItsAlbumContext() async throws {
        let album = try #require(SpotifyURI("spotify:album:0ETFjACtuP2ADo6LFhL6HN"))
        let catalog = StubCatalog(item: SpotifyCatalogItem(uri: try #require(SpotifyURI(heyJude)), name: "Hey Jude", artists: ["The Beatles"], context: album))
        let spotify = FakeSpotify()
        let rig = MusicRig(workspace: RecordingWorkspace(running: [AppBundleID.spotify]), catalog: catalog) { try spotify.respond($0, workspace: $1) }
        let result = await rig.player.play(MusicPlayRequest(query: "Hey Jude", artist: "The Beatles"))
        #expect(result.status == .completed)
        #expect(result.details["uri"] == .string(heyJude))
        #expect(catalog.queries.all == [SpotifySearchQuery(text: "Hey Jude", artist: "The Beatles", kind: .track)])
        #expect(rig.scripts.scripts.contains(SpotifyScript.play(try #require(SpotifyURI(heyJude)), inContext: album)))
    }

    @Test func catalogFailureFallsBackToSearch() async {
        let rig = MusicRig(catalog: StubCatalog(fails: true)) { _, _ in "" }
        let result = await rig.player.play(MusicPlayRequest(query: "Hey Jude"))
        #expect(result.status == .unconfirmed)
        #expect(result.details["catalog"] == "error")
        #expect(result.details["opened"] == "search")
    }

    @Test func noSpotifyFallsBackToMusic() async {
        let rig = MusicRig(workspace: RecordingWorkspace(installed: [AppBundleID.music])) { source, _ in
            if source.contains("search library") { return ["ok", "Hey Jude", "The Beatles"].joined(separator: sep) }
            return ["playing", "ABC", "Hey Jude", "The Beatles"].joined(separator: sep)
        }
        let result = await rig.player.play(MusicPlayRequest(query: "Hey Jude"))
        #expect(result.status == .completed)
        #expect(result.details["app"] == "apple_music")
        #expect(result.message == "Now playing \"Hey Jude\" by The Beatles in Music.")
        #expect(rig.scripts.scripts.first == AppleMusicScript.play(query: "Hey Jude", artist: nil, kind: .track))
    }

    @Test func musicReportsNoMatchAndDeniedAutomation() async {
        let empty = MusicRig(workspace: RecordingWorkspace(installed: [AppBundleID.music])) { _, _ in AppleMusicScript.notFoundMarker }
        #expect(await empty.player.play(MusicPlayRequest(query: "Nothing")).status == .notFound)

        let denied = MusicRig(workspace: RecordingWorkspace(installed: [AppBundleID.music])) { _, _ in
            throw AppleScriptError(code: -1743, message: "Not authorized")
        }
        let result = await denied.player.play(MusicPlayRequest(query: "Hey Jude"))
        #expect(result.status == .permissionDenied)
    }

    @Test func spotifyLinkWithoutSpotifyCannotPlayInMusic() async {
        let rig = MusicRig(workspace: RecordingWorkspace(installed: [AppBundleID.music])) { _, _ in "" }
        #expect(await rig.player.play(MusicPlayRequest(uri: SpotifyURI(heyJude))).status == .invalidRequest)
    }

    @Test func noMusicAppsIsUnavailable() async {
        let rig = MusicRig(workspace: RecordingWorkspace(installed: [])) { _, _ in "" }
        #expect(await rig.player.play(MusicPlayRequest(query: "x")).status == .unavailable)
        #expect(await rig.player.play(MusicPlayRequest(query: "x", app: .spotify)).status == .unavailable)
        #expect(rig.scripts.scripts.isEmpty)
    }

    @Test func appleScriptErrorNumbersAreRead() {
        let denied = AppleScriptError(osascriptStderr: "execution error: Not authorized to send Apple events to Spotify. (-1743)\n")
        #expect(denied.code == -1743)
        #expect(denied.isNotPermitted)
        #expect(AppleScriptError(code: -1744, message: "consent").isNotPermitted)
        #expect(!AppleScriptError(code: -600, message: "not running").isNotPermitted)
        #expect(AppleScriptError(osascriptStderr: "boom").code == nil)
    }
}

@Suite("Spotify Web API catalog")
struct SpotifyWebAPICatalogTests {
    static let token = #"{"access_token":"tok-123","token_type":"Bearer","expires_in":3600}"#
    static let tracks = """
    {"tracks":{"items":[{"uri":"\(heyJude)","name":"Hey Jude","artists":[{"name":"The Beatles"}],
    "album":{"uri":"spotify:album:0ETFjACtuP2ADo6LFhL6HN"}}]}}
    """

    @Test func clientCredentialsTokenThenSearch() async throws {
        let http = FakeHTTPTransport([.body(Self.token), .body(Self.tracks)])
        let catalog = SpotifyWebAPICatalog(clientID: "my-id", clientSecret: "my-secret", http: http, market: "gb")
        let item = try await catalog.search(SpotifySearchQuery(text: "Hey Jude", artist: "The Beatles", kind: .track))
        #expect(item?.uri.rawValue == heyJude)
        #expect(item?.artists == ["The Beatles"])
        #expect(item?.context?.rawValue == "spotify:album:0ETFjACtuP2ADo6LFhL6HN")

        let tokenRequest = http.requests[0]
        #expect(tokenRequest.url == SpotifyWebAPICatalog.tokenURL)
        #expect(tokenRequest.httpMethod == "POST")
        #expect(tokenRequest.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("my-id:my-secret".utf8).base64EncodedString())
        #expect(tokenRequest.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(tokenRequest.httpBody == Data("grant_type=client_credentials".utf8))

        let search = try #require(http.requests[1].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(search.host == "api.spotify.com")
        #expect(search.path == "/v1/search")
        let items = Dictionary(uniqueKeysWithValues: (search.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == ["q": "Hey Jude artist:The Beatles", "type": "track", "limit": "5", "market": "GB"])
        #expect(http.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
    }

    @Test func plusSignsInTheQueryAreEncoded() throws {
        let catalog = SpotifyWebAPICatalog(clientID: "a", clientSecret: "b", http: FakeHTTPTransport([]))
        let request = catalog.searchRequest(SpotifySearchQuery(text: "C++ & you"), token: "t")
        let query = try #require(request.url?.query(percentEncoded: true))
        #expect(query.contains("C%2B%2B"))
        #expect(!query.contains("+"))
    }

    @Test func tokenIsCachedAndRefreshedOnceAfterA401() async throws {
        let http = FakeHTTPTransport([.body(Self.token), .body(Self.tracks), .body(#"{"error":"expired"}"#, status: 401),
                                      .body(Self.token), .body(Self.tracks)])
        let catalog = SpotifyWebAPICatalog(clientID: "a", clientSecret: "b", http: http)
        _ = try await catalog.search(SpotifySearchQuery(text: "x"))
        _ = try await catalog.search(SpotifySearchQuery(text: "y"))
        let paths = http.requests.map { $0.url!.path }
        #expect(paths == ["/api/token", "/v1/search", "/v1/search", "/api/token", "/v1/search"])
    }

    @Test func rejectedCredentialsDoNotRetryOrLeakTheBody() async {
        let http = FakeHTTPTransport([.body(#"{"error":"invalid_client","echo":"my-secret"}"#, status: 400)])
        let catalog = SpotifyWebAPICatalog(clientID: "a", clientSecret: "my-secret", http: http)
        do {
            _ = try await catalog.search(SpotifySearchQuery(text: "x"))
            Issue.record("expected an error")
        } catch {
            #expect(!"\(error)".contains("my-secret"))
        }
        #expect(http.requests.count == 1)
    }

    @Test func skipsNullAndMalformedItems() {
        let body: JSONValue = ["playlists": ["items": [.null, ["uri": "spotify:playlist:bad"],
                                                        ["uri": "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M", "name": "Focus",
                                                         "owner": ["display_name": "Spotify"]]]]]
        let item = SpotifyWebAPICatalog.firstItem(in: body, kind: .playlist)
        #expect(item?.name == "Focus")
        #expect(item?.artists == ["Spotify"])
        #expect(item?.context == nil)
        #expect(SpotifyWebAPICatalog.firstItem(in: ["tracks": ["items": []]], kind: .track) == nil)
    }

    @Test func secretsStayOutOfDescriptionsAndMirrors() async throws {
        let http = FakeHTTPTransport([.body(Self.token), .body(Self.tracks)])
        let catalog = SpotifyWebAPICatalog(clientID: "client-id-value", clientSecret: "client-secret-value", http: http)
        _ = try await catalog.search(SpotifySearchQuery(text: "x"))
        var dumped = ""
        dump(catalog, to: &dumped)
        for text in [catalog.description, catalog.debugDescription, String(reflecting: catalog), dumped] {
            #expect(!text.contains("client-id-value"))
            #expect(!text.contains("client-secret-value"))
            #expect(!text.contains("tok-123"))
        }
    }

    @Test func credentialsComeFromTheStoreOrTheFeatureStaysOff() throws {
        struct Store: CredentialStore {
            var values: [String: String]
            func secret(named name: String) throws -> String? { values[name] }
            func setSecret(_ secret: String, named name: String) throws {}
            func removeSecret(named name: String) throws {}
        }
        #expect(SpotifyWebAPICatalog.fromCredentials(Store(values: [:])) == nil)
        #expect(SpotifyWebAPICatalog.fromCredentials(Store(values: ["spotify-client-id": "a"])) == nil)
        #expect(SpotifyWebAPICatalog.fromCredentials(Store(values: ["spotify-client-id": "a", "spotify-client-secret": "b"])) != nil)
        // The standard toolbox has no catalog unless one is passed in.
        #expect(AppToolEnvironment.live().spotifyCatalog == nil)
    }
}

/// The real osascript runner, on scripts that send no Apple events to any app (so no permission prompt). Off by
/// default because the app-tool tests never execute AppleScript; run with OPENCLICKY_RUN_OSASCRIPT=1.
@Suite("osascript runner", .enabled(if: ProcessInfo.processInfo.environment["OPENCLICKY_RUN_OSASCRIPT"] == "1"))
struct CancellableOsascriptRunnerTests {
    @Test func returnsTheScriptsValue() async throws {
        let output = try await CancellableOsascriptRunner().run("set sep to character id 31\nreturn \"a\" & sep & \"b\"", timeout: .seconds(15))
        #expect(PlayerSnapshot.fields(output) == ["a", "b"])
    }

    @Test func reportsTheErrorNumber() async {
        do {
            _ = try await CancellableOsascriptRunner().run("error \"boom\" number 4242", timeout: .seconds(15))
            Issue.record("expected an error")
        } catch let error as AppleScriptError {
            #expect(error.code == 4242)
            #expect(error.message.contains("boom"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func stopsAScriptThatRunsTooLong() async {
        let started = Date()
        do {
            _ = try await CancellableOsascriptRunner().run("delay 10\nreturn \"late\"", timeout: .milliseconds(500))
            Issue.record("expected a timeout")
        } catch {
            #expect("\(error)".contains("took too long"))
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func cancellationStopsTheScript() async {
        let started = Date()
        let task = Task { try await CancellableOsascriptRunner().run("delay 10\nreturn \"late\"", timeout: .seconds(15)) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

/// Compiles (never runs) the generated scripts against the installed apps' scripting dictionaries with osacompile,
/// which checks syntax and every term (`search … only albums`, `player state`, `play track … in context`). Sends no
/// Apple events. Off by default; run with OPENCLICKY_COMPILE_APPLESCRIPT=1.
@Suite("Generated AppleScript compiles", .enabled(if: ProcessInfo.processInfo.environment["OPENCLICKY_COMPILE_APPLESCRIPT"] == "1"))
struct AppleScriptCompileTests {
    static func compile(_ source: String) throws -> (status: Int32, errors: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oc-osacompile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("script.applescript")
        try source.write(to: input, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", dir.appendingPathComponent("script.scpt").path, input.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    static func installed(_ bundleID: String) -> Bool {
        let path = bundleID == AppBundleID.music ? "/System/Applications/Music.app" : "/Applications/Spotify.app"
        return FileManager.default.fileExists(atPath: path)
    }

    @Test(.enabled(if: installed(AppBundleID.music)), arguments: MusicLibraryKind.allCases)
    func musicScriptsCompile(_ kind: MusicLibraryKind) throws {
        for artist in [nil, "The \"Fab\" Four"] as [String?] {
            let result = try Self.compile(AppleMusicScript.play(query: "Hey \"Jude\"\nend tell", artist: artist, kind: kind))
            #expect(result.status == 0, "\(kind) artist=\(artist ?? "-"): \(result.errors)")
        }
        let state = try Self.compile(AppleMusicScript.playerState)
        #expect(state.status == 0, "\(state.errors)")
    }

    @Test(.enabled(if: installed(AppBundleID.spotify)))
    func spotifyScriptsCompile() throws {
        let track = try #require(SpotifyURI("spotify:track:0aym2LBJBk9DAYuHHutrIl"))
        let album = try #require(SpotifyURI("spotify:album:0ETFjACtuP2ADo6LFhL6HN"))
        for source in [SpotifyScript.play(track), SpotifyScript.play(track, inContext: album), SpotifyScript.playerState] {
            let result = try Self.compile(source)
            #expect(result.status == 0, "\(result.errors)")
        }
    }
}
