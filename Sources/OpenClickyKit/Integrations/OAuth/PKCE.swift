// Proof Key for Code Exchange (RFC 7636), S256 only, as OAuth 2.1 and the MCP authorization spec require.

import CryptoKit
import Foundation
import Security

public struct PKCE: Sendable, Hashable {
    /// 43–128 characters from the unreserved set (RFC 7636 §4.1). Secret: never logged or put in a URL.
    public let verifier: String
    /// BASE64URL(SHA256(ASCII(verifier))) without padding (RFC 7636 §4.2).
    public let challenge: String
    public let method = "S256"

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// A fresh verifier from 32 random bytes (43 characters once encoded, the RFC's recommendation).
    public static func generate() -> PKCE { PKCE(verifier: randomURLSafeString(byteCount: 32)) }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    /// True when the verifier only uses `[A-Za-z0-9-._~]` and is 43–128 characters long.
    public static func isValidVerifier(_ verifier: String) -> Bool {
        (43...128).contains(verifier.count)
            && verifier.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-._~".unicodeScalars.contains($0)) }
    }

    /// Random bytes, base64url-encoded. Also used for OAuth `state`.
    public static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes).base64URLEncodedString()
    }
}

extension PKCE: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PKCE(S256, challenge: \(challenge), verifier: <redacted>)" }
    public var debugDescription: String { description }
}

extension Data {
    /// Base64url without padding (RFC 4648 §5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
