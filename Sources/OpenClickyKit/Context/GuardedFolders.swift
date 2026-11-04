import Foundation

/// Folders macOS protects with a one-time "would like to access files in…" prompt (Files & Folders privacy). The first
/// read from one blocks until the user answers, so OpenClicky tracks which ones it has read from before.
public enum GuardedFolder: String, Sendable, Hashable, CaseIterable {
    case desktop
    case documents
    case downloads
    /// iCloud Drive (`~/Library/Mobile Documents`).
    case iCloudDrive = "icloud_drive"
    /// File-provider folders such as Dropbox, Google Drive and OneDrive (`~/Library/CloudStorage`).
    case cloudStorage = "cloud_storage"
    /// External, removable and network volumes (`/Volumes`).
    case volumes

    public var displayName: String {
        switch self {
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .downloads: "Downloads"
        case .iCloudDrive: "iCloud Drive"
        case .cloudStorage: "cloud storage"
        case .volumes: "external volume"
        }
    }

    /// The System Settings pane where the user can allow it afterwards.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
}

/// Decides which guarded folder, if any, a file lives in. Uses path text only, never the file system, so asking can't
/// itself trigger a prompt.
public struct GuardedFolderClassifier: Sendable, Hashable {
    public var homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func folder(for url: URL) -> GuardedFolder? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        let home = homeDirectory.path.hasSuffix("/") ? String(homeDirectory.path.dropLast()) : homeDirectory.path
        let checks: [(String, GuardedFolder)] = [
            (home + "/Desktop", .desktop),
            (home + "/Documents", .documents),
            (home + "/Downloads", .downloads),
            (home + "/Library/Mobile Documents", .iCloudDrive),
            (home + "/Library/CloudStorage", .cloudStorage),
            ("/Volumes", .volumes),
        ]
        for (prefix, folder) in checks where path == prefix || path.hasPrefix(prefix + "/") {
            return folder
        }
        return nil
    }
}

/// Where the ledger keeps the set of folders read before.
public protocol GuardedFolderLedgerStorage: Sendable {
    func load() -> Set<String>
    func save(_ folders: Set<String>)
}

/// Persists in the process's user defaults. Permissions are per app, so the app and `occtl` keep separate ledgers.
public struct UserDefaultsGuardedFolderStorage: GuardedFolderLedgerStorage {
    public var key: String

    public init(key: String = "openclicky.guardedFoldersReadBefore.v1") { self.key = key }

    public func load() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    public func save(_ folders: Set<String>) { UserDefaults.standard.set(folders.sorted(), forKey: key) }
}

public final class InMemoryGuardedFolderStorage: GuardedFolderLedgerStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var folders: Set<String>

    public init(_ folders: Set<String> = []) { self.folders = folders }

    public func load() -> Set<String> { lock.withLock { folders } }
    public func save(_ folders: Set<String>) { lock.withLock { self.folders = folders } }
}

/// Remembers which guarded folders this process has successfully read from, so the reader knows when a read may stop
/// on a system prompt.
public final class GuardedFolderLedger: @unchecked Sendable {
    public let classifier: GuardedFolderClassifier
    private let storage: any GuardedFolderLedgerStorage
    private let lock = NSLock()
    private var readBefore: Set<String>

    public init(classifier: GuardedFolderClassifier = GuardedFolderClassifier(), storage: any GuardedFolderLedgerStorage = UserDefaultsGuardedFolderStorage()) {
        self.classifier = classifier
        self.storage = storage
        self.readBefore = storage.load()
    }

    public func hasRead(from folder: GuardedFolder) -> Bool { lock.withLock { readBefore.contains(folder.rawValue) } }

    /// The guarded folder `url` is in, when this process has never read from it (so reading may prompt).
    public func firstReadFolder(for url: URL) -> GuardedFolder? {
        guard let folder = classifier.folder(for: url), !hasRead(from: folder) else { return nil }
        return folder
    }

    /// Call after a read from `url` succeeded: macOS has granted access, later reads won't prompt.
    public func recordSuccessfulRead(of url: URL) {
        guard let folder = classifier.folder(for: url) else { return }
        let snapshot: Set<String>? = lock.withLock {
            guard !readBefore.contains(folder.rawValue) else { return nil }
            readBefore.insert(folder.rawValue)
            return readBefore
        }
        if let snapshot { storage.save(snapshot) }
    }

    /// Forget a folder (e.g. after the user revoked access and macOS denied a read).
    public func forget(_ folder: GuardedFolder) {
        let snapshot: Set<String> = lock.withLock {
            readBefore.remove(folder.rawValue)
            return readBefore
        }
        storage.save(snapshot)
    }
}
