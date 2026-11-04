import Foundation
import Security

/// Lists the names of the credentials a store holds (never their values).
public protocol CredentialListing: Sendable {
    func storedNames() throws -> [String]
}

extension InMemoryCredentialStore: CredentialListing {}

extension KeychainCredentialStore: CredentialListing {
    /// Account names of OpenClicky's items in the login Keychain (service `com.openclicky.credentials`). Reads
    /// attributes only, never the secrets, so it doesn't ask for Keychain access.
    public func storedNames() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        let list = (items as? [[String: Any]]) ?? []
        return list.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// Credential names supplied through `OPENCLICKY_KEY_<NAME>` for this process (they can't be deleted from Settings).
    public static func environmentNames(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        environment.keys.filter { $0.hasPrefix("OPENCLICKY_KEY_") && !(environment[$0] ?? "").isEmpty }
            .map { String($0.dropFirst("OPENCLICKY_KEY_".count)).lowercased().replacingOccurrences(of: "_", with: "-") }
            .sorted()
    }
}

/// A saved key as Settings → Providers & keys lists it.
public struct SavedKey: Sendable, Hashable, Identifiable {
    public var name: String
    /// Providers, services or connectors that name this credential.
    public var usedBy: [String]
    /// Set from the environment for this process; the Keychain copy (if any) is shadowed and nothing can be deleted here.
    public var fromEnvironment: Bool

    public var id: String { name }

    public init(name: String, usedBy: [String], fromEnvironment: Bool) {
        self.name = name
        self.usedBy = usedBy
        self.fromEnvironment = fromEnvironment
    }

    /// The stored names with what uses each: config providers, plus any extra uses (services, connectors).
    public static func inventory(stored: [String], config: OpenClickyConfig, extraUses: [String: [String]] = [:],
                                 environmentNames: [String] = []) -> [SavedKey] {
        var uses: [String: [String]] = extraUses
        for provider in config.providers {
            if let name = provider.credential { uses[name, default: []].append(provider.id) }
        }
        let names = Set(stored).union(environmentNames)
        return names.sorted().map { name in
            SavedKey(name: name, usedBy: Array(Set(uses[name] ?? [])).sorted(), fromEnvironment: environmentNames.contains(name))
        }
    }
}

/// "Reset local data": everything OpenClicky keeps on this Mac, gone, so the next launch starts like a new install.
/// That is the Application Support folder (config, history, memory, skills, routines, jobs, voice previews, dictation
/// files, preferences, the browser bridge's token) and every credential under OpenClicky's Keychain service. A custom
/// agent folder chosen in Settings → Agents is the user's own folder and is left alone.
public struct LocalDataResetPlan: Sendable, Equatable {
    public var supportFolder: URL
    /// Top-level entries in the support folder that will be deleted.
    public var items: [URL]
    public var credentialNames: [String]
    /// Folders outside the support folder that are deliberately kept (a custom agent folder).
    public var kept: [URL]

    public var isEmpty: Bool { items.isEmpty && credentialNames.isEmpty }

    /// "12 files and folders, 3 saved keys".
    public var summary: String {
        let files = items.count == 1 ? "1 file or folder" : "\(items.count) files and folders"
        let keys = credentialNames.count == 1 ? "1 saved key" : "\(credentialNames.count) saved keys"
        return "\(files) in \(supportFolder.path), \(keys)"
    }
}

public struct LocalDataResetReport: Sendable, Equatable {
    public var removedItems: [URL] = []
    public var removedCredentials: [String] = []
    public var failures: [String] = []

    public var succeeded: Bool { failures.isEmpty }
}

public enum LocalDataReset {
    /// What a reset would delete. Nothing is touched.
    public static func plan(supportFolder: URL = OpenClickyConfig.defaultURL.deletingLastPathComponent(),
                            credentials: any CredentialListing, keep: [URL] = [],
                            fileManager: FileManager = .default) -> LocalDataResetPlan {
        let entries = (try? fileManager.contentsOfDirectory(at: supportFolder, includingPropertiesForKeys: nil)) ?? []
        let kept = keep.map(\.standardizedFileURL)
        let items = entries.filter { entry in
            let path = entry.standardizedFileURL.path
            // A kept folder inside the support folder (unusual, but possible) survives with its parents.
            return !kept.contains { $0.path == path || $0.path.hasPrefix(path + "/") }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let names = (try? credentials.storedNames()) ?? []
        return LocalDataResetPlan(supportFolder: supportFolder, items: items, credentialNames: names, kept: kept)
    }

    /// Deletes what the plan lists. Keeps going past failures and reports them.
    public static func perform(_ plan: LocalDataResetPlan, credentials: any CredentialStore,
                               fileManager: FileManager = .default) -> LocalDataResetReport {
        var report = LocalDataResetReport()
        let support = plan.supportFolder.standardizedFileURL.path
        for item in plan.items {
            // Only ever delete entries directly inside the support folder.
            guard item.standardizedFileURL.deletingLastPathComponent().path == support else {
                report.failures.append("Skipped \(item.path): not inside \(support)")
                continue
            }
            do {
                try fileManager.removeItem(at: item)
                report.removedItems.append(item)
            } catch {
                report.failures.append("Couldn't delete \(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for name in plan.credentialNames {
            do {
                try credentials.removeSecret(named: name)
                report.removedCredentials.append(name)
            } catch {
                report.failures.append("Couldn't delete the key \"\(name)\": \(error)")
            }
        }
        return report
    }
}
