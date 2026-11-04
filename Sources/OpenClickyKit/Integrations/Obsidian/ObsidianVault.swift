// Direct access to a local Obsidian vault: a folder of Markdown notes. No Obsidian app, plugin or account is
// involved; OpenClicky reads and writes the `.md` files itself.
//
// Safety rules (the same ones agents are told to follow):
// - Every path is relative to the vault root and must stay inside it, symlinks included.
// - The `.obsidian` settings folder, `.trash` and other hidden folders are never read or written.
// - Writes create or append; replacing an existing note needs `overwrite: true`. Nothing is ever deleted,
//   moved or renamed through this type.

import Foundation

/// One note in the vault.
public struct ObsidianNote: Sendable, Hashable {
    /// Path inside the vault with `/` separators, e.g. "Projects/OpenClicky.md".
    public var path: String
    public var modified: Date
    public var size: Int

    /// The file name without `.md`: what `[[wiki links]]` use.
    public var title: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

/// A note that matched a search, with the lines that matched.
public struct ObsidianSearchHit: Sendable, Hashable {
    public var note: ObsidianNote
    public var score: Int
    /// Up to a few matching lines, trimmed.
    public var excerpts: [String]
}

public enum ObsidianError: Error, Sendable, Equatable, CustomStringConvertible {
    case notAFolder(String)
    case invalidPath(String)
    case outsideVault(String)
    case protectedPath(String)
    case notFound(String)
    case alreadyExists(String)
    case tooLarge(String)

    public var description: String {
        switch self {
        case .notAFolder(let path): "\(path) isn't a folder. Choose the folder that holds your Obsidian notes."
        case .invalidPath(let path): "\"\(path)\" isn't a usable note path. Use a path inside the vault, like Folder/Note.md."
        case .outsideVault(let path): "\"\(path)\" is outside the vault."
        case .protectedPath(let path): "\"\(path)\" is in a hidden or settings folder, which OpenClicky leaves alone."
        case .notFound(let path): "There's no note at \"\(path)\"."
        case .alreadyExists(let path): "A note already exists at \"\(path)\"."
        case .tooLarge(let path): "\"\(path)\" is too large to read here."
        }
    }
}

public struct ObsidianVault: Sendable, Hashable {
    /// Reserved connector id, so a user connector can't take the name.
    public static let connectorID = "obsidian"
    /// Notes larger than this are skipped by search and refused by `read`.
    public static let maximumNoteBytes = 2 * 1024 * 1024

    public let root: URL

    /// Opens a vault folder. The folder must exist; a `.obsidian` folder is not required (any Markdown folder works).
    public init(root: URL) throws {
        let expanded = URL(fileURLWithPath: (root.path as NSString).expandingTildeInPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ObsidianError.notAFolder(root.path)
        }
        self.root = expanded.resolvingSymlinksInPath().standardizedFileURL
    }

    public init(path: String) throws { try self.init(root: URL(fileURLWithPath: path, isDirectory: true)) }

    /// True when the folder has Obsidian's `.obsidian` settings folder.
    public static func looksLikeVault(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(".obsidian").path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Where Obsidian keeps vaults synced with iCloud, the first place the folder picker opens.
    public static func iCloudVaultsFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents", isDirectory: true)
    }

    /// Vaults found in the usual places (iCloud Obsidian folder, ~/Documents), for suggestions in Settings.
    public static func discoverVaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let parents = [iCloudVaultsFolder(home: home), home.appendingPathComponent("Documents", isDirectory: true),
                       home.appendingPathComponent("Obsidian", isDirectory: true)]
        var found: [URL] = []
        for parent in parents {
            if looksLikeVault(parent) { found.append(parent) }
            let children = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil,
                                                                        options: [.skipsHiddenFiles])) ?? []
            found += children.filter(looksLikeVault).sorted { $0.path < $1.path }
        }
        return found
    }

    // MARK: Reading

    /// Every Markdown note, sorted by path. Hidden folders (`.obsidian`, `.trash`, `.git`) are skipped.
    public func notes() throws -> [ObsidianNote] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var notes: [ObsidianNote] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let relative = relativePath(of: url) else { continue }
            notes.append(ObsidianNote(path: relative, modified: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0))
        }
        return notes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The most recently edited notes, newest first.
    public func recentNotes(limit: Int = 10) throws -> [ObsidianNote] {
        Array(try notes().sorted { $0.modified > $1.modified }.prefix(max(0, limit)))
    }

    /// The text of a note. `path` may omit `.md`.
    public func read(_ path: String) throws -> String {
        let url = try resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ObsidianError.notFound(path) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maximumNoteBytes else { throw ObsidianError.tooLarge(path) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Notes whose title or text contains the query's words. Title matches rank above text matches; every word
    /// must appear somewhere in the note.
    /// Notes containing every word of `query` (a plural or "-y" word also matches its other form: "grocery" finds
    /// "Groceries"). When no note has them all, the notes with the most of them, so a wordy request still finds
    /// something.
    public func search(_ query: String, limit: Int = 10) throws -> [ObsidianSearchHit] {
        let terms = Self.searchTerms(query).map(Self.searchRoot)
        guard !terms.isEmpty else { return [] }
        var all: [ObsidianSearchHit] = []
        var some: [(hit: ObsidianSearchHit, matched: Int)] = []
        for note in try notes() where note.size <= Self.maximumNoteBytes {
            guard let text = try? String(contentsOf: root.appendingPathComponent(note.path), encoding: .utf8) else { continue }
            let title = note.path.lowercased()
            let lowered = text.lowercased()
            let found = terms.filter { title.contains($0) || lowered.contains($0) }
            guard !found.isEmpty else { continue }
            var score = 0
            for term in found {
                if note.title.lowercased().contains(term) { score += 10 } else if title.contains(term) { score += 4 }
                score += min(lowered.components(separatedBy: term).count - 1, 5)
            }
            let excerpts = text.split(separator: "\n", omittingEmptySubsequences: true)
                .filter { line in found.contains { line.lowercased().contains($0) } }
                .prefix(3)
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) }
            let hit = ObsidianSearchHit(note: note, score: score, excerpts: Array(excerpts))
            if found.count == terms.count { all.append(hit) } else { some.append((hit, found.count)) }
        }
        let order: (ObsidianSearchHit, ObsidianSearchHit) -> Bool = { $0.score != $1.score ? $0.score > $1.score : $0.note.modified > $1.note.modified }
        if !all.isEmpty || terms.count == 1 { return Array(all.sorted(by: order).prefix(max(0, limit))) }
        let best = some.map(\.matched).max() ?? 0
        return Array(some.filter { $0.matched == best }.map(\.hit).sorted(by: order).prefix(max(0, limit)))
    }

    /// A search word without a plural or "-y" ending ("groceries", "grocery" → "grocer"), so either form matches.
    static func searchRoot(_ term: String) -> String {
        guard term.count > 4, !term.allSatisfy(\.isNumber) else { return term }
        if term.hasSuffix("ies") { return String(term.dropLast(3)) }
        if term.hasSuffix("es"), ["ches", "shes", "sses", "xes"].contains(where: term.hasSuffix) { return String(term.dropLast(2)) }
        if term.hasSuffix("y") { return String(term.dropLast()) }
        if term.hasSuffix("s"), !term.hasSuffix("ss"), !term.hasSuffix("us"), !term.hasSuffix("is") { return String(term.dropLast()) }
        return term
    }

    /// Notes that link to `title` with `[[title]]`, `[[title|alias]]`, `[[title#heading]]` or `[[folder/title]]`.
    public func backlinks(to title: String, limit: Int = 20) throws -> [ObsidianSearchHit] {
        let target = ((title as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        guard !target.isEmpty else { return [] }
        var hits: [ObsidianSearchHit] = []
        for note in try notes() where note.size <= Self.maximumNoteBytes && note.title.lowercased() != target {
            guard let text = try? String(contentsOf: root.appendingPathComponent(note.path), encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").filter { line in
                Self.wikiLinks(in: String(line)).contains { (($0 as NSString).lastPathComponent).lowercased() == target }
            }
            guard !lines.isEmpty else { continue }
            hits.append(ObsidianSearchHit(note: note, score: lines.count,
                                          excerpts: lines.prefix(3).map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) }))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(max(0, limit)))
    }

    /// Targets of the `[[wiki links]]` in a line, without alias or heading.
    static func wikiLinks(in text: String) -> [String] {
        var links: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
            var target = rest[open.upperBound..<close.lowerBound]
            if let bar = target.firstIndex(of: "|") { target = target[..<bar] }
            if let hash = target.firstIndex(of: "#") { target = target[..<hash] }
            let trimmed = target.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { links.append((trimmed as NSString).deletingPathExtension) }
            rest = rest[close.upperBound...]
        }
        return links
    }

    static func searchTerms(_ query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
            .filter { $0.count >= 2 && !Self.stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = ["the", "and", "for", "about", "with", "my", "me", "of", "in", "on", "to",
                                                 "a", "an", "is", "are", "what", "notes", "note", "find", "show", "any"]

    // MARK: Writing

    /// Creates a note (and its folders). Replaces an existing note only when `overwrite` is true.
    @discardableResult
    public func write(_ path: String, content: String, overwrite: Bool = false) throws -> ObsidianNote {
        let url = try resolve(path)
        if FileManager.default.fileExists(atPath: url.path), !overwrite { throw ObsidianError.alreadyExists(path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
        return try note(at: url)
    }

    /// Adds text to the end of a note, on a new line, creating the note if needed.
    @discardableResult
    public func append(_ path: String, text: String) throws -> ObsidianNote {
        let url = try resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return try write(path, content: text) }
        let existing = try String(contentsOf: url, encoding: .utf8)
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try Data((existing + separator + text).utf8).write(to: url, options: .atomic)
        return try note(at: url)
    }

    // MARK: Paths

    /// The file for a vault-relative note path, checked to stay inside the vault and out of hidden folders.
    /// `.md` is added when the path has no extension; other extensions are refused.
    public func resolve(_ path: String) throws -> URL {
        var relative = path.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("~"), !relative.contains("\0") else {
            throw ObsidianError.invalidPath(path)
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains("..") else { throw ObsidianError.outsideVault(path) }
        guard !components.contains(where: { $0.hasPrefix(".") }) else { throw ObsidianError.protectedPath(path) }
        let ext = (components.last! as NSString).pathExtension.lowercased()
        if !ext.isEmpty, ext != "md" { throw ObsidianError.invalidPath(path) }
        if ext.isEmpty { relative = components.joined(separator: "/") + ".md" } else { relative = components.joined(separator: "/") }

        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        // Resolve symlinks on the deepest existing ancestor so a link inside the vault can't point outside it.
        var existing = candidate
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != root.path, existing.pathComponents.count > 1 {
            existing.deleteLastPathComponent()
        }
        let resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else { throw ObsidianError.outsideVault(path) }
        return candidate
    }

    private func relativePath(of url: URL) -> String? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root.path + "/") else { return nil }
        return String(path.dropFirst(root.path.count + 1))
    }

    private func note(at url: URL) throws -> ObsidianNote {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return ObsidianNote(path: relativePath(of: url) ?? url.lastPathComponent, modified: values.contentModificationDate ?? Date(),
                            size: values.fileSize ?? 0)
    }
}
