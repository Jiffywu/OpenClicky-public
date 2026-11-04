import Foundation

/// The small local catalog of starter skills that ships with OpenClicky (`Resources/skills/catalog`), browsable by
/// category and search and copied into the library on request. Nothing is fetched from a server.
public struct SkillCatalog: Sendable {
    public var folder: URL?

    public init(folder: URL? = SkillResources.catalogFolder) {
        self.folder = folder
    }

    /// Every catalog skill, sorted by name.
    public func entries() -> [Skill] {
        SkillResources.skillFolders(in: folder).compactMap { try? SkillFile.load(folder: $0) }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    public func search(_ query: String, category: String? = nil) -> [Skill] {
        SkillSearch.filter(entries(), query: query, category: category)
    }

    public func categories() -> [SkillCategory] { SkillSearch.categories(in: entries()) }

    public func entry(_ reference: String) -> Skill? { SkillsLibrary.resolve(reference, in: entries()) }

    /// Whether the library already holds this catalog skill (a folder of the same name).
    public func isInLibrary(_ entry: Skill, library: SkillsLibrary) -> Bool {
        FileManager.default.fileExists(atPath: library.directory.appendingPathComponent(entry.id).appendingPathComponent(SkillFile.fileName).path)
    }

    /// Copies a catalog skill into the library, switched off.
    @discardableResult
    public func add(_ reference: String, to library: SkillsLibrary, enable: Bool = false) throws -> Skill {
        guard let entry = entry(reference) else { throw SkillsLibraryError.unknownSkill(reference) }
        let target = library.directory.appendingPathComponent(entry.id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw SkillsLibraryError.alreadyExists(entry.id) }
        try FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        try SkillFolder.copy(entry.folder, to: target)
        return enable ? try library.enable(entry.id) : try SkillFile.load(folder: target)
    }
}
