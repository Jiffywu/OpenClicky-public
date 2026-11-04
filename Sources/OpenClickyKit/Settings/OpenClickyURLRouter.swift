import Foundation

/// The Settings pages a link can open. The app's sidebar uses the same raw values.
public enum SettingsPageID: String, Sendable, CaseIterable, Hashable {
    case general, models, voice, microphone, dictation, talkKeys, providers, permissions, agents, routines
    case memory, connectedApps, browser, services, skills, usage, developer

    /// Names accepted in links besides the raw value (kebab case, and HeyClicky's section names).
    static let aliases: [String: SettingsPageID] = [
        "talk-keys": .talkKeys, "shortcuts": .talkKeys, "keys": .providers, "providers-and-keys": .providers,
        "connected-apps": .connectedApps, "integrations": .connectedApps, "chrome": .browser, "mic": .microphone,
        "lookups": .services, "limits": .usage, "spending": .usage, "costs": .usage, "dev": .developer,
        "flags": .developer, "diagnostics": .developer,
    ]

    public init?(linkName: String) {
        let name = linkName.lowercased()
        if let alias = Self.aliases[name] { self = alias; return }
        guard let page = Self.allCases.first(where: { $0.rawValue.lowercased() == name }) else { return nil }
        self = page
    }
}

/// Where an `openclicky://` link (from the browser host, another app or `open`) or an in-app `openclicky:` link (in an
/// agent's Markdown or a card) goes.
public enum OpenClickyRoute: Sendable, Equatable {
    /// Settings, on a page (nil keeps the current one).
    case settings(SettingsPageID?)
    /// Home, on a section ("chat", "agents", "drawings", "skills"; nil keeps the current one).
    case home(String?)
    /// A background job or kept agent, by id or slug.
    case job(String)
    /// Settings → Routines with one routine selected.
    case routine(String)
    /// The welcome tour.
    case onboarding
    /// Show a file an agent made in Finder. The app only does so inside the agent folders.
    case revealFile(String)
}

public enum OpenClickyURLError: Error, Sendable, Equatable, CustomStringConvertible {
    case wrongScheme(String)
    case tooLong(Int)
    case hasCredentialsOrPort
    case unknownRoute(String)
    case unknownSettingsPage(String)
    case unknownHomeSection(String)
    case badIdentifier(String)
    case badPath(String)
    case unexpectedQuery(String)

    public var description: String {
        switch self {
        case .wrongScheme(let scheme): "not an openclicky link (scheme \"\(scheme)\")"
        case .tooLong(let length): "link is too long (\(length) characters)"
        case .hasCredentialsOrPort: "link carries a user, password or port"
        case .unknownRoute(let route): "unknown route \"\(route)\""
        case .unknownSettingsPage(let page): "unknown Settings page \"\(page)\""
        case .unknownHomeSection(let section): "unknown Home section \"\(section)\""
        case .badIdentifier(let id): "\"\(id)\" isn't a valid id"
        case .badPath(let reason): "file link refused: \(reason)"
        case .unexpectedQuery(let route): "\(route) links take no query"
        }
    }
}

/// One parse, ready to log: what was asked for (with query values left out) and where it goes or why it was refused.
public struct OpenClickyURLParse: Sendable, Equatable {
    public var result: Result<OpenClickyRoute, OpenClickyURLError>
    public var logLine: String

    public var route: OpenClickyRoute? { try? result.get() }
}

/// Parses `openclicky://` and in-app `openclicky:` links. Everything not on the list is refused: the scheme must be
/// `openclicky`, links can't carry credentials or a port, pages and sections come from fixed lists, ids are short
/// and plain, and only the file route takes a query (an absolute path, with no `..`).
///
///     openclicky://settings/browser        openclicky:settings/browser
///     openclicky://home/agents             openclicky:job/pricing-articles-3f2a91c0de
///     openclicky://routine/1a2b3c4d        openclicky://file?path=/Users/me/…/output/report.md
public enum OpenClickyURLRouter {
    public static let scheme = "openclicky"
    public static let maxLength = 2048
    public static let homeSections: Set<String> = ["chat", "agents", "drawings", "skills"]

    public static func parse(_ url: URL) -> OpenClickyURLParse {
        let result = route(for: url)
        let shown = redacted(url)
        let line: String = switch result {
        case .success(let route): "openclicky link \(shown) → \(describe(route))"
        case .failure(let error): "openclicky link \(shown) refused: \(error)"
        }
        return OpenClickyURLParse(result: result, logLine: line)
    }

    public static func parse(_ text: String) -> OpenClickyURLParse {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return OpenClickyURLParse(result: .failure(.unknownRoute(String(text.prefix(60)))), logLine: "openclicky link refused: not a URL")
        }
        return parse(url)
    }

    static func route(for url: URL) -> Result<OpenClickyRoute, OpenClickyURLError> {
        let text = url.absoluteString
        guard text.count <= maxLength else { return .failure(.tooLong(text.count)) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.unknownRoute(text)) }
        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == Self.scheme else { return .failure(.wrongScheme(scheme)) }
        guard components.user == nil, components.password == nil, components.port == nil else { return .failure(.hasCredentialsOrPort) }

        // `openclicky://settings/browser` puts "settings" in the host; `openclicky:settings/browser` puts it in the path.
        var parts: [String] = []
        if let host = components.host, !host.isEmpty { parts.append(host) }
        parts += components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first?.lowercased() else { return .failure(.unknownRoute("")) }
        let rest = Array(parts.dropFirst())
        let query = components.queryItems ?? []

        if head != "file", !query.isEmpty { return .failure(.unexpectedQuery(head)) }
        switch head {
        case "settings", "preferences":
            guard rest.count <= 1 else { return .failure(.unknownRoute(parts.joined(separator: "/"))) }
            guard let name = rest.first else { return .success(.settings(nil)) }
            guard let page = SettingsPageID(linkName: name) else { return .failure(.unknownSettingsPage(String(name.prefix(40)))) }
            return .success(.settings(page))
        case "home":
            guard rest.count <= 1 else { return .failure(.unknownRoute(parts.joined(separator: "/"))) }
            guard let section = rest.first?.lowercased() else { return .success(.home(nil)) }
            guard homeSections.contains(section) else { return .failure(.unknownHomeSection(String(section.prefix(40)))) }
            return .success(.home(section))
        case "job", "jobs", "agent":
            guard rest.count == 1 else { return .failure(.unknownRoute(parts.joined(separator: "/"))) }
            return identifier(rest[0]).map(OpenClickyRoute.job)
        case "routine", "routines":
            if rest.isEmpty { return .success(.settings(.routines)) }
            guard rest.count == 1 else { return .failure(.unknownRoute(parts.joined(separator: "/"))) }
            return identifier(rest[0]).map(OpenClickyRoute.routine)
        case "onboarding", "welcome":
            guard rest.isEmpty else { return .failure(.unknownRoute(parts.joined(separator: "/"))) }
            return .success(.onboarding)
        case "file":
            guard rest.isEmpty else { return .failure(.unknownRoute(parts.joined(separator: "/"))) }
            guard query.count == 1, query[0].name == "path", let path = query[0].value else {
                return .failure(.badPath("needs exactly one path= item"))
            }
            return filePath(path).map(OpenClickyRoute.revealFile)
        default:
            return .failure(.unknownRoute(String(head.prefix(40))))
        }
    }

    static func identifier(_ text: String) -> Result<String, OpenClickyURLError> {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard (1...128).contains(text.count), text.unicodeScalars.allSatisfy(allowed.contains), text != ".", text != "..",
              text.unicodeScalars.allSatisfy(\.isASCII) else {
            return .failure(.badIdentifier(String(text.prefix(40))))
        }
        return .success(text)
    }

    static func filePath(_ path: String) -> Result<String, OpenClickyURLError> {
        guard path.hasPrefix("/") else { return .failure(.badPath("not an absolute path")) }
        guard path.count <= 1024 else { return .failure(.badPath("path too long")) }
        guard !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return .failure(.badPath("path has . or ..")) }
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(.badPath("path has control characters"))
        }
        return .success(path)
    }

    /// Whether `path` is inside one of `roots` (after resolving symlinks), for the file route.
    public static func isInside(_ path: String, roots: [URL]) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { root in
            let base = root.resolvingSymlinksInPath().standardizedFileURL.path
            return resolved == base || resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    /// The link with query values hidden, for logs.
    static func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "(unreadable)" }
        components.user = nil
        components.password = nil
        if let items = components.queryItems, !items.isEmpty {
            components.percentEncodedQuery = items.map { "\($0.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "_")=(hidden)" }
                .joined(separator: "&")
        }
        let text = components.string ?? "(unreadable)"
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }

    public static func describe(_ route: OpenClickyRoute) -> String {
        switch route {
        case .settings(let page): "Settings" + (page.map { " › \($0.rawValue)" } ?? "")
        case .home(let section): "Home" + (section.map { " › \($0)" } ?? "")
        case .job(let id): "job \(id)"
        case .routine(let id): "routine \(id)"
        case .onboarding: "welcome tour"
        case .revealFile: "reveal a file in Finder"
        }
    }

    /// The link for a route (what agents and cards should write).
    public static func link(for route: OpenClickyRoute, inApp: Bool = false) -> URL? {
        let prefix = inApp ? "openclicky:" : "openclicky://"
        let tail: String
        switch route {
        case .settings(let page): tail = "settings" + (page.map { "/\($0.rawValue)" } ?? "")
        case .home(let section): tail = "home" + (section.map { "/\($0)" } ?? "")
        case .job(let id): tail = "job/\(id)"
        case .routine(let id): tail = "routine/\(id)"
        case .onboarding: tail = "onboarding"
        case .revealFile(let path):
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            tail = "file" + (components.string ?? "")
        }
        return URL(string: prefix + tail)
    }
}
