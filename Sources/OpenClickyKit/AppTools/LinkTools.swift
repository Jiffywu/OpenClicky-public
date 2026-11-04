import Foundation

/// Which links `open_url` will open: http and https only, with a host and no embedded credentials.
public enum WebLinkPolicy {
    public static let maxLength = 8_192

    /// The URL to open, or the reason it is refused. A bare domain ("example.com/page") is opened over https, a bare
    /// "localhost:3000" over http.
    public static func normalize(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolArgumentError("Missing \"url\".") }
        guard text.count <= maxLength else { throw ToolArgumentError("The link is too long.") }
        // Whitespace or control characters inside a link are a sign of a smuggled scheme ("java\nscript:").
        guard !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { throw ToolArgumentError.refused("The link contains spaces or control characters.") }

        let candidate: String
        if let scheme = explicitScheme(of: text) {
            let lower = scheme.lowercased()
            guard lower == "http" || lower == "https" else {
                throw ToolArgumentError.refused("Only http and https links can be opened, not \(lower): links.")
            }
            candidate = text
        } else {
            let host = text.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? text
            let hostOnly = host.split(separator: ":").first.map(String.init) ?? host
            let isLoopback = ["localhost", "127.0.0.1"].contains(hostOnly.lowercased())
            guard hostOnly.contains(".") || isLoopback else {
                throw ToolArgumentError("\"\(text)\" is not a web address. Give a full http or https link.")
            }
            // Local development servers rarely speak TLS.
            candidate = (isLoopback ? "http://" : "https://") + text
        }

        guard let components = URLComponents(string: candidate) else { throw ToolArgumentError("That link is malformed.") }
        guard let host = components.host, !host.isEmpty else { throw ToolArgumentError("The link has no website in it.") }
        guard components.user == nil, components.password == nil else {
            throw ToolArgumentError.refused("Links with a user name or password in them are not opened.")
        }
        guard let url = components.url else { throw ToolArgumentError("That link is malformed.") }
        return url
    }

    /// The scheme the text names, if it names one. "localhost:8080/x" and "example.com:443" are a host and port,
    /// not a scheme; "javascript:…", "file:…", "mailto:…" and "https://…" are schemes.
    static func explicitScheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let prefix = text[..<colon]
        guard let first = prefix.unicodeScalars.first, CharacterSet.letters.contains(first),
              prefix.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0) })
        else { return nil }
        let rest = text[text.index(after: colon)...]
        if rest.hasPrefix("//") { return String(prefix) }
        let port = rest.prefix(while: \.isNumber)
        if !port.isEmpty, port.count <= 5 {
            let after = rest.dropFirst(port.count)
            if after.isEmpty || after.first == "/" || after.first == "?" || after.first == "#" { return nil }
        }
        return String(prefix)
    }
}

/// Which paths `reveal_in_finder` will show: existing items inside the user's home folder.
public enum HomePathPolicy {
    /// Resolves `~`, `..` and symbolic links, then checks the result is the home folder or inside it.
    public static func resolve(_ raw: String, home: URL) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolArgumentError("Missing \"path\".") }
        guard !text.contains("\0") else { throw ToolArgumentError("That path is malformed.") }

        var path = text
        if path.lowercased().hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL else { throw ToolArgumentError("That file link is malformed.") }
            path = url.path
        }
        if path == "~" {
            path = home.path
        } else if path.hasPrefix("~/") {
            path = home.path + "/" + path.dropFirst(2)
        } else if path.hasPrefix("~") {
            throw ToolArgumentError.refused("Only paths inside your own home folder can be shown.")
        }
        guard path.hasPrefix("/") else {
            throw ToolArgumentError("Give a full path (starting with / or ~/), not a relative one.")
        }

        let resolvedHome = canonical(home)
        let resolved = canonical(URL(fileURLWithPath: path))
        let homeParts = resolvedHome.pathComponents
        let parts = resolved.pathComponents
        guard parts.count >= homeParts.count, Array(parts.prefix(homeParts.count)) == homeParts else {
            throw ToolArgumentError.refused("Only files and folders inside your home folder can be shown in Finder.")
        }
        return resolved
    }

    /// `url` with `.` and `..` removed and symbolic links resolved. A path that does not exist yet is resolved up to
    /// its deepest existing folder, so it compares the same way as an existing one (`resolvingSymlinksInPath`
    /// alone treats the two differently, e.g. `/var` vs `/private/var`).
    static func canonical(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing { resolved.appendPathComponent(component) }
        return resolved
    }
}

enum LinkTools {
    static func openURL(workspace: any AppToolWorkspace) -> AppTool {
        AppTool.make(
            spec: ToolSpec(
                name: AppToolName.openURL,
                description: """
                Open a web page in the user's default browser. Only http and https links; a bare domain such as \
                example.com is opened over https. The page opens once you finish speaking, so say what you are \
                opening first. Result status: opened, refused (not a web link), or invalid_request.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "The web address to open."],
                    ],
                    "required": ["url"],
                    "additionalProperties": false,
                ]),
            needsFollowUpRound: false, defersUntilNarrationEnds: true, isReadOnly: false,
            statusLabel: "Opening the page…", queuedStatus: .opened,
            parse: { try WebLinkPolicy.normalize(try $0.requiredString("url", maxLength: WebLinkPolicy.maxLength)) },
            perform: { url in
                guard await workspace.openInDefaultBrowser(url) else {
                    return AppToolResult(.failed, "The browser did not open the page.", details: ["url": .string(url.absoluteString)])
                }
                return AppToolResult(.opened, nil, details: ["url": .string(url.absoluteString)])
            })
    }

    static let maxClipboardCharacters = 200_000

    static func copyToClipboard(pasteboard: any AppToolPasteboard) -> AppTool {
        AppTool.make(
            spec: ToolSpec(
                name: AppToolName.copyToClipboard,
                description: """
                Put text on the user's clipboard so they can paste it. Copies the text exactly as given. Result \
                status: copied, or invalid_request.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "The exact text to copy."],
                    ],
                    "required": ["text"],
                    "additionalProperties": false,
                ]),
            needsFollowUpRound: false, defersUntilNarrationEnds: false, isReadOnly: false,
            statusLabel: "Copying…",
            parse: { arguments in
                guard let text = try arguments.rawString("text", maxLength: maxClipboardCharacters) else {
                    throw ToolArgumentError("Missing \"text\" to copy.")
                }
                return text
            },
            perform: { text in
                guard await pasteboard.copy(text) else { return AppToolResult(.failed, "The clipboard did not take the text.") }
                return AppToolResult(.copied, nil, details: ["characters": .number(Double(text.count))])
            })
    }

    static func revealInFinder(workspace: any AppToolWorkspace, home: URL) -> AppTool {
        AppTool.make(
            spec: ToolSpec(
                name: AppToolName.revealInFinder,
                description: """
                Show a file or folder selected in a Finder window. Only items inside the user's home folder. \
                Happens once you finish speaking. Result status: revealed, not_found, refused (outside the home \
                folder), or invalid_request.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Full path, or a path starting with ~/ for the home folder."],
                    ],
                    "required": ["path"],
                    "additionalProperties": false,
                ]),
            needsFollowUpRound: false, defersUntilNarrationEnds: true, isReadOnly: false,
            statusLabel: "Showing it in Finder…", queuedStatus: .revealed,
            parse: { arguments in
                let url = try HomePathPolicy.resolve(try arguments.requiredString("path", maxLength: 4_096), home: home)
                // Checked here too, so a missing item is answered at once instead of being queued as "revealed".
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ToolArgumentError("Nothing exists at \(url.path).", status: .notFound)
                }
                return url
            },
            perform: { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return AppToolResult(.notFound, "Nothing exists at that path.", details: ["path": .string(url.path)])
                }
                guard await workspace.revealInFinder(url) else {
                    return AppToolResult(.failed, "Finder did not show it.", details: ["path": .string(url.path)])
                }
                return AppToolResult(.revealed, nil, details: ["path": .string(url.path)])
            })
    }
}
