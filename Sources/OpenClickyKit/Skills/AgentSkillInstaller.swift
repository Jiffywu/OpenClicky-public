import CryptoKit
import Foundation

/// A skill folder OpenClicky installed for its agents.
public struct InstalledAgentSkill: Sendable, Hashable {
    public var name: String
    public var origin: AgentSkillOrigin
    public var folder: URL
    public var file: URL { folder.appendingPathComponent(SkillFile.fileName) }
}

/// What one sync did.
public struct AgentSkillSyncResult: Sendable, Hashable {
    public var installed: [InstalledAgentSkill] = []
    /// Names written or rewritten this time (the rest were already current).
    public var updated: [String] = []
    /// OpenClicky-installed folders removed because their skill is no longer wanted (an app disconnected, a skill
    /// switched off).
    public var removed: [String] = []
    /// Names skipped because a folder OpenClicky didn't install is already there.
    public var conflicts: [String] = []
    /// Skills that couldn't be installed, with the reason.
    public var failures: [String: String] = [:]
}

extension AgentPaths {
    /// Codex finds skills here by itself (`$CODEX_HOME/skills`). On the user's own Codex home it is added as an extra
    /// skills root for the job instead.
    public var codexSkills: URL { codexHome.appendingPathComponent("skills", isDirectory: true) }
    /// A Claude Code plugin holding the skills, loaded with `--plugin-dir` (Claude Code reads the config folder's own
    /// `skills/` only with the `user` setting source, which jobs leave off so the user's settings stay out).
    public var claudeSkillsPlugin: URL { claudeConfig.appendingPathComponent("openclicky-plugin", isDirectory: true) }
}

/// Copies agent skills into the harness folders. Each installed folder carries a marker naming its origin and a
/// fingerprint of its files, so unchanged skills aren't rewritten and only OpenClicky's own folders are ever
/// replaced or removed (Codex keeps its system skills in the same place, and the user may add their own).
public enum AgentSkillInstaller {
    public static let markerName = ".openclicky-skill.json"
    /// The plugin's name; Claude Code lists its skills as `openclicky:<name>`.
    public static let claudePluginName = "openclicky"

    /// The app and occtl share these folders, so a sync also holds an `flock` on this file in the skills folder.
    static let lockFileName = ".openclicky-sync.lock"

    private static let lock = NSLock()

    struct Marker: Codable, Equatable {
        var installedBy = "OpenClicky"
        var origin: AgentSkillOrigin
        var fingerprint: String
    }

    /// Makes `root` hold exactly OpenClicky's `sources` (plus whatever OpenClicky didn't install).
    @discardableResult
    public static func sync(_ sources: [AgentSkillSource], into root: URL) throws -> AgentSkillSyncResult {
        try lock.withLock { try withProcessLock(in: root) { try syncLocked(sources, into: root) } }
    }

    /// The Claude Code plugin: a manifest and a `skills/` folder synced like Codex's.
    @discardableResult
    public static func syncClaudePlugin(_ sources: [AgentSkillSource], at plugin: URL, version: String = "1.0.0") throws -> AgentSkillSyncResult {
        let skills = plugin.appendingPathComponent("skills", isDirectory: true)
        return try lock.withLock { try withProcessLock(in: skills) {
            let manifestFolder = plugin.appendingPathComponent(".claude-plugin", isDirectory: true)
            try FileManager.default.createDirectory(at: manifestFolder, withIntermediateDirectories: true)
            let manifest: JSONValue = [
                "name": .string(claudePluginName),
                "version": .string(version),
                "description": "Skills OpenClicky installs for its background jobs: its browser skill, deploys, connected apps and the skills the user switched on.",
            ]
            let file = manifestFolder.appendingPathComponent("plugin.json")
            let text = manifest.jsonString()
            if (try? String(contentsOf: file, encoding: .utf8)) != text { try text.write(to: file, atomically: true, encoding: .utf8) }
            return try syncLocked(sources, into: skills)
        } }
    }

    /// Runs `body` while holding an exclusive `flock` on the lock file in `folder`. Without it, a sync in occtl and
    /// one in the app could interleave, and one's leftover pass would delete the other's staging folder mid-install.
    private static func withProcessLock<T>(in folder: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.appendingPathComponent(lockFileName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }  // closing releases the lock
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try body()
    }

    private static func syncLocked(_ sources: [AgentSkillSource], into root: URL) throws -> AgentSkillSyncResult {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var result = AgentSkillSyncResult()
        var wanted = Set<String>()
        for source in sources {
            let name = AgentSkillSource.installName(source.name)
            guard wanted.insert(name).inserted else { continue }
            let target = root.appendingPathComponent(name, isDirectory: true)
            if manager.fileExists(atPath: target.path), marker(in: target) == nil {
                result.conflicts.append(name)
                continue
            }
            let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: staging) }
            do {
                try SkillFolder.copy(source.folder, to: staging)
                if let markdown = source.markdown {
                    try markdown.write(to: staging.appendingPathComponent(SkillFile.fileName), atomically: true, encoding: .utf8)
                }
                guard manager.fileExists(atPath: staging.appendingPathComponent(SkillFile.fileName).path) else {
                    throw SkillFileError.missing(source.folder.path)
                }
                for script in SkillFolder.files(in: staging).map(\.path) where script.hasPrefix("scripts/") {
                    try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.appendingPathComponent(script).path)
                }
                let fresh = Marker(origin: source.origin, fingerprint: fingerprint(of: staging))
                if marker(in: target) == fresh {
                    result.installed.append(InstalledAgentSkill(name: name, origin: source.origin, folder: target))
                    continue
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(fresh).write(to: staging.appendingPathComponent(markerName))
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.moveItem(at: staging, to: target)
                result.installed.append(InstalledAgentSkill(name: name, origin: source.origin, folder: target))
                result.updated.append(name)
            } catch {
                result.failures[name] = "\(error)"
            }
        }
        // Leftovers: our folders that are no longer wanted, and staging folders from an interrupted sync.
        for entry in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let name = entry.lastPathComponent
            if name.hasPrefix(".staging-") {
                try? manager.removeItem(at: entry)
            } else if !wanted.contains(name), marker(in: entry) != nil {
                try? manager.removeItem(at: entry)
                result.removed.append(name)
            }
        }
        result.removed.sort()
        return result
    }

    static func marker(in folder: URL) -> Marker? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(markerName)) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// SHA-256 over each file's relative path and bytes, in path order.
    static func fingerprint(of folder: URL) -> String {
        var hasher = SHA256()
        for file in SkillFolder.files(in: folder) where file.path != markerName {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: file.data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
