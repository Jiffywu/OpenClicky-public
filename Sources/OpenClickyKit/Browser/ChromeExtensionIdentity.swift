import CryptoKit
import Foundation

/// The OpenClicky Chrome extension's identity. Chrome derives an extension's ID from its public key, so the fixed
/// `key` in `Extension/chrome/manifest.json` gives the unpacked extension the same ID on every Mac. Only the public
/// key is in the repository.
public enum ChromeExtensionIdentity {
    /// Native-messaging host name the extension connects to. HeyClicky's is different and is never touched.
    public static let hostName = "com.openclicky.browser"

    /// SubjectPublicKeyInfo (DER, base64) of the extension's RSA key; identical to manifest.json's `key`.
    public static let publicKeyBase64 =
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3GIegyHao22v7c1oHiTSb89kYGQ3Iu3Vt/uc6KtBRLkXmv0oES5v6x6nGme8uUB8"
        + "RJxaXqSnD8CXC/DtpNGW0BGSLmFzAQgZZsC3RbDw+yuEEFzO6QeuhF3HuC4AFDW+jjfRriyjLiyg16eCBOIB9G8U4OCYvuluL37Q9PYAHW/G"
        + "U6qr1No/eKDo09M3t2VnpyEJ9atuuATGrgXya7Cc4vwRAP6ESjloiCHKladuGSZ0Dr3/Wa/U+51WA3+D68A1hYviy7uNDi6fCQp0UWcfUmqH"
        + "PUR+HSxY+Wyb9xi2xIXR44dcsmPjonGP/PxU6Edm6Hy616wRGh5pxvPPEUISDQIDAQAB"

    /// The extension ID Chrome assigns to OpenClicky's extension.
    public static var extensionID: String { id(forPublicKeyBase64: publicKeyBase64)! }

    /// `chrome-extension://<id>/`, the form Chrome passes to the host and expects in `allowed_origins`.
    public static func origin(for id: String) -> String { "chrome-extension://\(id)/" }

    /// Chrome's rule: SHA-256 of the DER public key, first 16 bytes as hex, each hex digit 0–f mapped to a–p.
    public static func id(forPublicKeyDER der: Data) -> String {
        let digest = SHA256.hash(data: der)
        let letters = Array("abcdefghijklmnop")
        return digest.prefix(16).map { "\(letters[Int($0 >> 4)])\(letters[Int($0 & 0x0F)])" }.joined()
    }

    public static func id(forPublicKeyBase64 base64: String) -> String? {
        Data(base64Encoded: base64).map(id(forPublicKeyDER:))
    }

    /// 32 characters, each a–p.
    public static func isValidID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }

    /// IDs the host accepts as callers: OpenClicky's own plus any listed in the bridge's extra-IDs file.
    public static func allowedIDs(paths: BrowserBridgePaths = .standard) -> [String] {
        var ids = [extensionID]
        for extra in paths.readExtraExtensionIDs() where !ids.contains(extra) { ids.append(extra) }
        return ids
    }
}
