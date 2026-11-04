import Foundation
import Security

/// Where API keys live. Config files only ever hold a credential's *name*; the secret stays in the Keychain
/// (or an environment variable for development) and is handed to providers and harnesses at call time.
public protocol CredentialStore: Sendable {
    func secret(named name: String) throws -> String?
    func setSecret(_ secret: String, named name: String) throws
    func removeSecret(named name: String) throws
}

public enum CredentialError: Error, Equatable, CustomStringConvertible {
    case keychain(OSStatus)
    case missing(String)

    public var description: String {
        switch self {
        case .keychain(let status): "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        case .missing(let name): "No credential named \"\(name)\". Add it with: occtl key set \(name)"
        }
    }
}

/// Generic-password items in the login Keychain, service `com.openclicky.credentials`, account = credential name.
/// `OPENCLICKY_KEY_<NAME>` (uppercased, `-` → `_`) overrides the Keychain, for development and CI.
public struct KeychainCredentialStore: CredentialStore {
    public static let service = "com.openclicky.credentials"
    private let environment: [String: String]
    /// The Keychain service the items live under (`service`; tests use their own and delete it afterwards).
    public let serviceName: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, serviceName: String = KeychainCredentialStore.service) {
        self.environment = environment
        self.serviceName = serviceName
    }

    public static func environmentVariable(for name: String) -> String {
        "OPENCLICKY_KEY_" + name.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    public func secret(named name: String) throws -> String? {
        if let fromEnv = environment[Self.environmentVariable(for: name)], !fromEnv.isEmpty { return fromEnv }
        var query = baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw CredentialError.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ secret: String, named name: String) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(baseQuery(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw CredentialError.keychain(update) }
        var add = baseQuery(name)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    public func removeSecret(named name: String) throws {
        let status = SecItemDelete(baseQuery(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }

    private func baseQuery(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: serviceName,
         kSecAttrAccount as String: name]
    }
}

/// In-memory store for tests and previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var secrets: [String: String]
    private let lock = NSLock()

    public init(_ secrets: [String: String] = [:]) { self.secrets = secrets }

    public func secret(named name: String) throws -> String? { lock.withLock { secrets[name] } }
    public func setSecret(_ secret: String, named name: String) throws { lock.withLock { secrets[name] = secret } }
    public func removeSecret(named name: String) throws { _ = lock.withLock { secrets.removeValue(forKey: name) } }
    /// The names held (`CredentialListing`).
    public func storedNames() throws -> [String] { lock.withLock { secrets.keys.sorted() } }
}
