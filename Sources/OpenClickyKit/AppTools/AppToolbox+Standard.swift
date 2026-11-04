import Foundation

/// The tool names the brain's prompt refers to.
public enum AppToolName {
    public static let openURL = "open_url"
    public static let copyToClipboard = "copy_to_clipboard"
    public static let revealInFinder = "reveal_in_finder"
    public static let playOnSpotify = "play_on_spotify"
    public static let calendarFindEvents = "calendar_find_events"
    public static let calendarCreateEvent = "calendar_create_event"
}

/// Everything the app tools touch on this Mac. `live()` for the app and occtl; fakes for tests.
public struct AppToolEnvironment: Sendable {
    public var workspace: any AppToolWorkspace
    public var pasteboard: any AppToolPasteboard
    public var appleScript: any AppleScriptRunning
    public var calendar: any CalendarStore
    /// Spotify catalog search with the user's own developer credentials. Nil (the default) turns it off; playback
    /// then resolves only given URIs and otherwise opens Spotify's search.
    public var spotifyCatalog: (any SpotifyCatalogSearching)?
    /// reveal_in_finder only shows items under this folder.
    public var homeDirectory: URL
    public var clock: CalendarClock
    public var musicTiming: MusicPlayer.Timing
    public var sleep: @Sendable (Duration) async -> Void

    public init(workspace: any AppToolWorkspace, pasteboard: any AppToolPasteboard, appleScript: any AppleScriptRunning,
                calendar: any CalendarStore, spotifyCatalog: (any SpotifyCatalogSearching)? = nil,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, clock: CalendarClock = CalendarClock(),
                musicTiming: MusicPlayer.Timing = MusicPlayer.Timing(),
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.appleScript = appleScript
        self.calendar = calendar
        self.spotifyCatalog = spotifyCatalog
        self.homeDirectory = homeDirectory
        self.clock = clock
        self.musicTiming = musicTiming
        self.sleep = sleep
    }

    /// The real Mac: NSWorkspace, the general pasteboard, osascript (stopped when the task is cancelled), EventKit.
    public static func live(spotifyCatalog: (any SpotifyCatalogSearching)? = nil) -> AppToolEnvironment {
        AppToolEnvironment(workspace: MacWorkspace(), pasteboard: MacPasteboard(), appleScript: CancellableOsascriptRunner(),
                           calendar: EventKitCalendarStore(), spotifyCatalog: spotifyCatalog)
    }
}

extension AppToolbox {
    /// OpenClicky's local app tools. `insert_text` is not here: the dictation part owns it.
    public static func standard(_ environment: AppToolEnvironment) -> AppToolbox {
        let calendar = CalendarService(store: environment.calendar, clock: environment.clock)
        let player = MusicPlayer(workspace: environment.workspace, scripts: environment.appleScript,
                                 catalog: environment.spotifyCatalog, timing: environment.musicTiming, sleep: environment.sleep)
        return AppToolbox([
            LinkTools.openURL(workspace: environment.workspace),
            LinkTools.copyToClipboard(pasteboard: environment.pasteboard),
            LinkTools.revealInFinder(workspace: environment.workspace, home: environment.homeDirectory),
            MusicTools.playOnSpotify(player: player),
            CalendarTools.findEvents(service: calendar),
            CalendarTools.createEvent(service: calendar),
        ])
    }
}
