import Foundation
import Security
import Testing
@testable import OpenClickyKit

// The real Keychain store, under a throwaway service name so nothing touches OpenClicky's own items. Every item is
// deleted again, also when an expectation fails. Skipped where the login Keychain can't be used (a locked or missing
// keychain in CI).

@Suite struct KeychainRoundTripTests {
    /// Whether this process can add and delete a generic password at all.
    static let keychainUsable: Bool = {
        let service = "app.openclicky.tests.probe.\(UUID().uuidString)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "probe"]
        var add = query
        add[kSecValueData as String] = Data("x".utf8)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        SecItemDelete(query as CFDictionary)
        return true
    }()

    @Test(.enabled(if: KeychainRoundTripTests.keychainUsable, "the login Keychain isn't available to this process"))
    func setReadListUpdateAndRemoveInTheRealKeychain() throws {
        let service = "app.openclicky.tests.\(UUID().uuidString)"
        // No OPENCLICKY_KEY_* environment, so every read goes to the Keychain.
        let store = KeychainCredentialStore(environment: [:], serviceName: service)
        defer {
            let all: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(all as CFDictionary)
        }
        #expect(try store.storedNames().isEmpty)
        #expect(try store.secret(named: "alpha") == nil)

        // Placeholder values only; never a real key.
        try store.setSecret("placeholder-one", named: "alpha")
        try store.setSecret("placeholder-two", named: "beta-key")
        #expect(try store.secret(named: "alpha") == "placeholder-one")
        #expect(try store.storedNames() == ["alpha", "beta-key"])

        // Setting again updates in place.
        try store.setSecret("placeholder-three", named: "alpha")
        #expect(try store.secret(named: "alpha") == "placeholder-three")
        #expect(try store.storedNames() == ["alpha", "beta-key"])

        try store.removeSecret(named: "alpha")
        try store.removeSecret(named: "alpha") // removing a missing item is fine
        #expect(try store.secret(named: "alpha") == nil)
        #expect(try store.storedNames() == ["beta-key"])
        try store.removeSecret(named: "beta-key")
        #expect(try store.storedNames().isEmpty)
    }

    @Test func theEnvironmentOverridesTheKeychainWithoutTouchingIt() throws {
        let service = "app.openclicky.tests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(environment: ["OPENCLICKY_KEY_SOME_PROVIDER": "from-env"], serviceName: service)
        #expect(try store.secret(named: "some-provider") == "from-env")
        #expect(KeychainCredentialStore.environmentNames(["OPENCLICKY_KEY_SOME_PROVIDER": "x"]) == ["some-provider"])
    }
}
