import Foundation

// Settings → Browser: the pieces the page and the app's launch use, kept free of AppKit so they are tested without a
// browser. Profile discovery from `Local State`, the saved profile choice, refreshing the native-host manifests from
// the app bundle (refused outside a real .app), staging the unpacked extension and the Load unpacked steps.

/// A profile listed in a Chromium browser's `Local State` file.
public struct ChromiumProfile: Sendable, Hashable, Identifiable {
    public var browser: ChromiumBrowser
    /// The profile's folder name ("Default", "Profile 1").
    public var directory: String
    /// The name the browser shows for it ("Work", "Person 1").
    public var name: String
    /// When the profile was last used, if the browser recorded it.
    public var lastActive: Date?

    public var id: String { browser.id + "/" + directory }

    public init(browser: ChromiumBrowser, directory: String, name: String, lastActive: Date?) {
        self.browser = browser
        self.directory = directory
        self.name = name
        self.lastActive = lastActive
    }
}

/// Reads `<browser support folder>/Local State` → `profile.info_cache`. Only folder names, display names and the last
/// active time are kept; account e-mail addresses in the same file are never read into OpenClicky.
public enum ChromiumProfileDiscovery {
    public static func localStateURL(for browser: ChromiumBrowser, applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(browser.supportPath, isDirectory: true).appendingPathComponent("Local State")
    }

    /// The browser's profiles, most recently active first (unknown times last, then by name).
    public static func profiles(for browser: ChromiumBrowser, applicationSupport: URL = NativeHostInstaller.defaultApplicationSupport) -> [ChromiumProfile] {
        guard let data = try? Data(contentsOf: localStateURL(for: browser, applicationSupport: applicationSupport)) else { return [] }
        return parse(localState: data, browser: browser)
    }

    public static func parse(localState data: Data, browser: ChromiumBrowser) -> [ChromiumProfile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        var found: [ChromiumProfile] = []
        for (directory, value) in cache {
            guard let entry = value as? [String: Any], isSafeDirectoryName(directory) else { continue }
            let name = (entry["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? directory
            var active: Date?
            if let seconds = entry["active_time"] as? Double, seconds > 0 { active = Date(timeIntervalSince1970: seconds) }
            else if let text = entry["active_time"] as? String, let seconds = Double(text), seconds > 0 { active = Date(timeIntervalSince1970: seconds) }
            found.append(ChromiumProfile(browser: browser, directory: directory, name: String(name.prefix(80)), lastActive: active))
        }
        return found.sorted { a, b in
            switch (a.lastActive, b.lastActive) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Installed browsers (their support folder exists) and their profiles, in `NativeHostInstaller.browsers` order.
    public static func installed(applicationSupport: URL = NativeHostInstaller.defaultApplicationSupport,
                                 browsers: [ChromiumBrowser] = NativeHostInstaller.browsers) -> [(browser: ChromiumBrowser, profiles: [ChromiumProfile])] {
        browsers.compactMap { browser in
            let support = applicationSupport.appendingPathComponent(browser.supportPath, isDirectory: true)
            guard FileManager.default.fileExists(atPath: support.path) else { return nil }
            return (browser, profiles(for: browser, applicationSupport: applicationSupport))
        }
    }

    /// The most recently active profile across every installed browser.
    public static func mostRecent(applicationSupport: URL = NativeHostInstaller.defaultApplicationSupport,
                                  browsers: [ChromiumBrowser] = NativeHostInstaller.browsers) -> ChromiumProfile? {
        installed(applicationSupport: applicationSupport, browsers: browsers).flatMap(\.profiles)
            .filter { $0.lastActive != nil }.max { ($0.lastActive ?? .distantPast) < ($1.lastActive ?? .distantPast) }
    }

    static func isSafeDirectoryName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.contains("/") && name != "." && name != ".."
    }
}

/// The browser page's saved choices, `BrowserBridge/preferences.json` (mode 0600 in the bridge's 0700 folder):
/// which connected profile agents work in, and the profiles seen before (so the page can name one that is offline).
public struct BrowserBridgePreferences: Codable, Sendable, Equatable {
    public struct KnownProfile: Codable, Sendable, Hashable, Identifiable {
        /// The extension's per-profile UUID (`BrowserPeer.profileId`).
        public var id: String
        public var browserName: String
        public var lastSeen: Date

        public init(id: String, browserName: String, lastSeen: Date) {
            self.id = id
            self.browserName = browserName
            self.lastSeen = lastSeen
        }
    }

    /// The profile commands go to when several are connected; nil = the most recently connected one.
    public var preferredProfileID: String?
    public var knownProfiles: [KnownProfile]
    /// Whether a browser has ever connected on this Mac, and when the first one did.
    public var hasEverConnected: Bool
    public var firstConnectedAt: Date?

    public init(preferredProfileID: String? = nil, knownProfiles: [KnownProfile] = [], hasEverConnected: Bool = false,
                firstConnectedAt: Date? = nil) {
        self.preferredProfileID = preferredProfileID
        self.knownProfiles = knownProfiles
        self.hasEverConnected = hasEverConnected
        self.firstConnectedAt = firstConnectedAt
    }

    private enum CodingKeys: String, CodingKey { case preferredProfileID, knownProfiles, hasEverConnected, firstConnectedAt }

    /// Files written before a key existed still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferredProfileID = try container.decodeIfPresent(String.self, forKey: .preferredProfileID)
        knownProfiles = try container.decodeIfPresent([KnownProfile].self, forKey: .knownProfiles) ?? []
        firstConnectedAt = try container.decodeIfPresent(Date.self, forKey: .firstConnectedAt)
        hasEverConnected = try container.decodeIfPresent(Bool.self, forKey: .hasEverConnected) ?? (firstConnectedAt != nil || !knownProfiles.isEmpty)
    }

    /// Records that browsers are connected. True the first time any browser connects on this Mac.
    public mutating func noteConnected(_ peers: [BrowserPeer], at now: Date = Date()) -> Bool {
        guard !peers.isEmpty else { return false }
        remember(peers, at: now)
        guard !hasEverConnected else { return false }
        hasEverConnected = true
        firstConnectedAt = now
        return true
    }

    /// The first-connection notice, for a while after the first browser connected.
    public func firstConnectionNotice(now: Date = Date(), showFor: TimeInterval = 30 * 60) -> String? {
        guard hasEverConnected, let first = firstConnectedAt, now.timeIntervalSince(first) < showFor, now >= first else { return nil }
        let browser = knownProfiles.last?.browserName ?? "your browser"
        return "OpenClicky connected to \(browser) for the first time. Jobs can now work in sites you're signed in to, in tabs of their own; press Stop in the extension's menu any time to take the browser back."
    }

    public static func url(in paths: BrowserBridgePaths) -> URL { paths.directory.appendingPathComponent("preferences.json") }

    public static func load(from paths: BrowserBridgePaths = .standard) -> BrowserBridgePreferences {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(in: paths)),
              var loaded = try? decoder.decode(BrowserBridgePreferences.self, from: data) else { return BrowserBridgePreferences() }
        // A hand-edited file can't steer commands to something that isn't a profile id.
        if let id = loaded.preferredProfileID, UUID(uuidString: id) == nil { loaded.preferredProfileID = nil }
        return loaded
    }

    public func save(to paths: BrowserBridgePaths = .standard) throws {
        try paths.prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try BrowserBridgeSecrets.writePrivate(try encoder.encode(self), to: Self.url(in: paths))
    }

    /// Remembers connected peers (newest sighting wins; at most 12 kept).
    public mutating func remember(_ peers: [BrowserPeer], at now: Date = Date()) {
        for peer in peers {
            let entry = KnownProfile(id: peer.profileId.lowercased(), browserName: peer.browserName, lastSeen: now)
            if let index = knownProfiles.firstIndex(where: { $0.id == entry.id }) { knownProfiles[index] = entry }
            else { knownProfiles.append(entry) }
        }
        knownProfiles.sort { $0.lastSeen > $1.lastSeen }
        if knownProfiles.count > 12 { knownProfiles.removeLast(knownProfiles.count - 12) }
    }

    /// Chooses the profile agents work in (nil: the most recently connected one). Ids are normalized to lowercase.
    public mutating func choose(_ profileID: String?) {
        preferredProfileID = profileID.flatMap { UUID(uuidString: $0) == nil ? nil : $0.lowercased() }
    }
}

/// What the browser page says about the connection.
public enum BrowserConnectionState: Sendable, Equatable {
    /// OpenClicky's side of the bridge isn't listening (the reason from the probe).
    case bridgeNotRunning(String)
    /// The bridge runs but no extension has connected.
    case waitingForExtension
    case connected([BrowserPeer])

    public static func from(probe: Result<BrowserBridgeProbe.Status, Error>) -> BrowserConnectionState {
        switch probe {
        case .success(let status): status.peers.isEmpty ? .waitingForExtension : .connected(status.peers)
        case .failure(let error): .bridgeNotRunning("\(error)")
        }
    }

    public var title: String {
        switch self {
        case .bridgeNotRunning: "Not connected"
        case .waitingForExtension: "Waiting for the extension"
        case .connected(let peers): peers.count == 1 ? "Connected" : "Connected in \(peers.count) profiles"
        }
    }

    public var detail: String {
        switch self {
        case .bridgeNotRunning(let reason):
            "OpenClicky's browser bridge isn't running (\(reason)). It runs while OpenClicky or `occtl browser mcp-serve` is open."
        case .waitingForExtension:
            "The bridge is listening, but no browser has connected yet. Load the extension (steps below), then click its toolbar button once."
        case .connected(let peers):
            peers.map { "\($0.browserName), profile \($0.profileId.prefix(8)), extension \($0.extensionVersion ?? "?")" }.joined(separator: "; ")
        }
    }

    public var isConnected: Bool { if case .connected = self { true } else { false } }
}

/// The badge at the top of Settings → Browser: Off, Waiting, Setup failed (with the reason) or Connected.
public enum BrowserSetupBadge: Sendable, Equatable {
    case off
    case waiting
    case setupFailed(String)
    case connected

    public var title: String {
        switch self {
        case .off: "Off"
        case .waiting: "Waiting"
        case .setupFailed: "Setup failed"
        case .connected: "Connected"
        }
    }

    public var reason: String? { if case .setupFailed(let reason) = self { reason } else { nil } }

    /// A failure counts until a browser connects after it. While connected, a problem the extension reported later is
    /// returned as `attention` beside the Connected badge instead.
    /// - Parameters:
    ///   - failure: from the bridge (`BrowserBridgeProbe.Status.failure`): a refused extension, an old copy
    ///   - setupError: OpenClicky's own setup step that failed here (writing the browser helpers)
    public static func make(state: BrowserConnectionState, failure: BrowserSetupFailure?, setupError: String? = nil)
        -> (badge: BrowserSetupBadge, attention: String?) {
        switch state {
        case .connected(let peers):
            let since = peers.map(\.connectedAt).max() ?? .distantPast
            let problem = failure.flatMap { $0.at >= since ? $0.reason : nil }
            return (.connected, problem ?? setupError)
        case .waitingForExtension:
            if let reason = failure?.reason ?? setupError { return (.setupFailed(reason), nil) }
            return (.waiting, nil)
        case .bridgeNotRunning:
            if let setupError { return (.setupFailed(setupError), nil) }
            return (.off, nil)
        }
    }
}

/// The `[Browser]` note the voice brain gets (as a turn note, so only when it changes): whether jobs can use the
/// user's browser, and what to do when they can't.
public enum BrowserBrainNote {
    public static func make(state: BrowserConnectionState, chromiumInstalled: Bool) -> String {
        switch state {
        case .connected(let peers):
            let names = Array(Set(peers.map(\.browserName))).sorted().joined(separator: ", ")
            let profiles = peers.count == 1 ? "1 profile" : "\(peers.count) profiles"
            return "[Browser] Connected: \(names) (\(profiles)). Background jobs can work in sites the user is signed in to, in tabs of their own."
        case .waitingForExtension, .bridgeNotRunning:
            guard chromiumInstalled else {
                return "[Browser] There is no Chromium browser on this Mac, so jobs can't use the user's signed-in sites; they use web search and fetch, and give numbered steps for the rest."
            }
            return "[Browser] Not connected. A job that needs a site the user is signed in to will ask (a chrome_setup request); approve it when the user agrees and walk them through the steps you get back. If the user asks to set it up now, \(BrowserSetupGuide.settingsURL) opens Settings → Browser."
        }
    }
}

/// Refreshing the native-host manifests from the running app. HeyClicky does this at launch and refuses when it isn't
/// running from a real .app bundle (a manifest pointing into a build folder breaks when the folder is cleaned).
public enum BundledHostInstall {
    public enum Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        case notAnAppBundle(String)
        /// A copy macOS translocated, or one on a disk image: it goes away when the app quits or the image is ejected.
        case temporaryCopy(String)
        case helperMissing(String)

        public var description: String {
            switch self {
            case .notAnAppBundle(let path):
                "OpenClicky isn't running from an app bundle (\(path)), so it didn't write browser host manifests. Use `occtl browser install-host` for development builds."
            case .temporaryCopy(let path):
                "OpenClicky is running from a temporary copy (\(path)), so it left the browser host manifests pointing at the installed app. Move OpenClicky to Applications and open it from there."
            case .helperMissing(let path):
                "The browser helper is missing from the app (\(path)). Rebuild the app with scripts/build-app.sh."
            }
        }
    }

    /// `<bundle>.app/Contents/Helpers/OpenClickyBrowserHost`, if the bundle is a real .app that carries it and stays
    /// where it is. A translocated or disk-image copy is refused: a manifest pointing there would replace the installed
    /// app's working one and break once that copy is gone.
    public static func helper(inBundle bundleURL: URL, fileManager: FileManager = .default) -> Result<URL, Refusal> {
        let bundle = bundleURL.standardizedFileURL
        guard bundle.pathExtension == "app" else { return .failure(.notAnAppBundle(bundle.path)) }
        switch InstallLocation.classify(bundleURL: bundle).kind {
        case .translocated, .diskImage: return .failure(.temporaryCopy(bundle.path))
        default: break
        }
        guard fileManager.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) else {
            return .failure(.notAnAppBundle(bundle.path))
        }
        let helper = bundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(NativeHostInstaller.hostExecutableName)
        guard fileManager.isExecutableFile(atPath: helper.path) else { return .failure(.helperMissing(helper.path)) }
        return .success(helper)
    }

    /// Writes or refreshes `com.openclicky.browser.json` for every installed Chromium browser, pointing at this
    /// bundle's helper. Unchanged manifests are left alone.
    public static func refresh(bundleURL: URL, extensionIDs: [String] = [ChromeExtensionIdentity.extensionID],
                               applicationSupport: URL = NativeHostInstaller.defaultApplicationSupport,
                               browsers: [ChromiumBrowser] = NativeHostInstaller.browsers) -> Result<[NativeHostInstaller.Outcome], Refusal> {
        helper(inBundle: bundleURL).map { host in
            NativeHostInstaller.install(hostPath: host, extensionIDs: extensionIDs, applicationSupport: applicationSupport, browsers: browsers)
        }
    }

    /// One line per browser for logs: "Chrome: written, Arc: unchanged".
    public static func summary(_ outcomes: [NativeHostInstaller.Outcome]) -> String {
        let parts = outcomes.compactMap { outcome -> String? in
            switch outcome.action {
            case .browserNotFound: return nil
            case .written: return "\(outcome.browser.displayName): written"
            case .unchanged: return "\(outcome.browser.displayName): unchanged"
            case .removed: return "\(outcome.browser.displayName): removed"
            case .absent: return "\(outcome.browser.displayName): absent"
            case .failed(let message): return "\(outcome.browser.displayName): failed (\(message))"
            }
        }
        return parts.isEmpty ? "no Chromium browser installed" : parts.joined(separator: ", ")
    }
}

/// The unpacked extension. `scripts/build-app.sh` copies `Extension/chrome` (without its tests) into the app as
/// `Contents/Resources/BrowserExtension`; setup copies it on to Application Support, a folder that stays put when the
/// app is replaced, so the browser keeps loading it.
public enum BrowserExtensionFolder {
    public static let bundledName = "BrowserExtension"

    public static func bundled(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true).appendingPathComponent(bundledName, isDirectory: true)
    }

    public static var defaultStaged: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent(bundledName, isDirectory: true)
    }

    public enum StageError: Error, Sendable, Equatable, CustomStringConvertible {
        case noManifest(String)

        public var description: String {
            switch self {
            case .noManifest(let path): "There's no extension at \(path) (manifest.json is missing). Rebuild the app with scripts/build-app.sh."
            }
        }
    }

    /// Copies the extension's files (skipping `tests` and hidden files) into `destination`, replacing what was there.
    /// Returns the destination.
    @discardableResult
    public static func stage(from source: URL, to destination: URL = defaultStaged, fileManager: FileManager = .default) throws -> URL {
        guard fileManager.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw StageError.noManifest(source.path)
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            for name in try fileManager.contentsOfDirectory(atPath: source.path) where !name.hasPrefix(".") && name != "tests" {
                try fileManager.copyItem(at: source.appendingPathComponent(name), to: temporary.appendingPathComponent(name))
            }
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        return destination
    }

    /// The extension version in a folder's manifest.json, if readable.
    public static func version(at folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }
}

/// Load unpacked, step by step, in OpenClicky's own words.
public enum BrowserSetupGuide {
    /// The Settings page the extension's "Open OpenClicky" button and a `chrome_setup` approval open.
    public static let settingsURL = "openclicky://settings/browser"

    /// The steps when no particular browser or folder is known yet.
    public static let genericSteps = [
        "In OpenClicky, open Settings → Browser and click Prepare the Extension Folder.",
        "In Chrome (or Arc, Brave, Edge), open the extensions page and turn on Developer mode.",
        "Click Load unpacked and choose the folder OpenClicky showed.",
        "Click the OpenClicky button in the browser toolbar once; Settings then says Connected.",
    ]

    /// The browser's extensions page (`chrome://extensions`, `arc://extensions`, …).
    public static func extensionsPage(for browser: ChromiumBrowser) -> String {
        switch browser.id {
        case "arc": "arc://extensions"
        case "brave": "brave://extensions"
        case "edge": "edge://extensions"
        case "vivaldi": "vivaldi://extensions"
        default: "chrome://extensions"
        }
    }

    public static func loadUnpackedSteps(browser: ChromiumBrowser, folder: URL) -> [String] {
        var steps = ["Open \(extensionsPage(for: browser)) in \(browser.displayName)."]
        if browser.id == "edge" { steps.append("Turn on \"Allow extensions from other stores\" if Edge asks.") }
        steps += [
            "Turn on Developer mode (top right).",
            "Click Load unpacked and choose the folder \(folder.path).",
            "Pin OpenClicky in the toolbar and click it once; this page then says Connected.",
        ]
        return steps
    }
}
