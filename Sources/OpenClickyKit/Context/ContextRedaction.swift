import Foundation

/// Hides the user's content in context JSON (titles, page and file text, URLs, paths, element labels, and names quoted
/// inside notes) while keeping its shape, the app's identity and OpenClicky's own wording, so tool output can be kept
/// as evidence.
public enum ContextRedaction {
    /// Keys whose string values describe apps, roles and sources, not the user's content.
    static let keptKeys: Set<String> = [
        "frontApp", "frontAppBundleID", "localTime", "bundleID", "role", "subrole", "roleDescription", "kind", "source",
        "awaitingFolderAccess", "gatheredAt", "name",
    ]

    /// Keys holding OpenClicky's own sentences, which can quote a file name, path or address.
    static let sentenceKeys: Set<String> = ["notes", "appNotes", "captureError", "error"]

    public static func redact(_ value: JSONValue, key: String? = nil) -> JSONValue {
        switch value {
        case .string(let text):
            if let key, keptKeys.contains(key) { return value }
            if let key, sentenceKeys.contains(key) { return .string(scrub(text)) }
            return .string("<\(text.count) chars>")
        case .object(let object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { ($0.key, redact($0.value, key: $0.key)) }))
        case .array(let array):
            return .array(array.map { redact($0, key: key) })
        default:
            return value
        }
    }

    private static let patterns: [(NSRegularExpression, String)] = [
        // Quoted names: “Report.docx”, "Report", ‘Report’.
        (try! NSRegularExpression(pattern: #"“[^”]*”"#), "“<name>”"),
        (try! NSRegularExpression(pattern: #""[^"]*""#), "\"<name>\""),
        (try! NSRegularExpression(pattern: #"‘[^’]*’"#), "‘<name>’"),
        // Addresses with a scheme.
        (try! NSRegularExpression(pattern: #"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s)]*"#), "<address>"),
        // Absolute and home-relative paths.
        (try! NSRegularExpression(pattern: #"(^|[\s(])~?/[^\s)]*"#), "$1<path>"),
    ]

    /// One of OpenClicky's sentences with quoted names, addresses and paths replaced.
    public static func scrub(_ sentence: String) -> String {
        patterns.reduce(sentence) { text, entry in
            entry.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: entry.1)
        }
    }
}
