import Foundation

/// The exact operation awaiting a user decision. Arguments are already validated and the tab is pinned.
public struct BrowserChangeRequest: Sendable {
    public let jobID: String?
    public let operation: String
    public let arguments: JSONValue
    public let target: JSONValue?

    public var summary: String { "Allow browser \(operation)?" }

    /// Plain JSON keeps page text and typed values from being interpreted as formatting or instructions.
    public var details: String {
        var value: [String: JSONValue] = ["operation": .string(operation), "arguments": arguments]
        if let target {
            value["page"] = ["title": target["title"] ?? .null, "url": target["url"] ?? .null, "tab": target["id"] ?? .null]
        }
        return JSONValue.object(value).jsonString()
    }
}
