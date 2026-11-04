import Foundation

/// Why a call's arguments were turned away. `status` is `invalid_request` for missing or malformed arguments and
/// `refused` for well-formed ones the tool will not act on.
public struct ToolArgumentError: Error, Sendable, Hashable, CustomStringConvertible {
    public var status: AppToolStatus
    public var message: String

    public init(_ message: String, status: AppToolStatus = .invalidRequest) {
        self.status = status
        self.message = message
    }

    public static func refused(_ message: String) -> ToolArgumentError { ToolArgumentError(message, status: .refused) }

    public var description: String { "\(status.rawValue): \(message)" }
}

/// The arguments object of one tool call, with typed, validating accessors.
///
/// Each accessor takes a list of key spellings so a tool can accept the variants models tend to produce
/// (`spotify_uri`, `spotifyUri`, …). The first key present wins.
public struct ToolArguments: Sendable, Hashable {
    public var values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) { self.values = values }

    /// From the JSON text a model produced. Empty text means no arguments.
    public static func parse(_ text: String) throws -> ToolArguments {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ToolArguments() }
        let value: JSONValue
        do {
            value = try JSONValue.parse(trimmed)
        } catch {
            throw ToolArgumentError("The arguments are not valid JSON.")
        }
        return try ToolArguments(json: value)
    }

    public init(json: JSONValue) throws {
        switch json {
        case .object(let object): self.values = object
        case .null: self.values = [:]
        default: throw ToolArgumentError("The arguments must be a JSON object.")
        }
    }

    /// The key holds a value: present, not null, and not a blank string (the accessors treat those as absent too).
    public func has(_ key: String) -> Bool {
        guard let value = values[key], value != .null else { return false }
        if case .string(let text) = value { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }

    private func first(_ keys: [String]) -> (key: String, value: JSONValue)? {
        for key in keys {
            if let value = values[key], value != .null { return (key, value) }
        }
        return nil
    }

    /// A string, trimmed. Empty strings count as absent.
    public func string(_ keys: String..., maxLength: Int = 2_000) throws -> String? {
        try string(keys, maxLength: maxLength, trim: true)
    }

    /// A string kept exactly as given (for text to copy). Whitespace-only strings count as absent.
    public func rawString(_ keys: String..., maxLength: Int) throws -> String? {
        try string(keys, maxLength: maxLength, trim: false)
    }

    public func requiredString(_ keys: String..., maxLength: Int = 2_000) throws -> String {
        guard let value = try string(keys, maxLength: maxLength, trim: true) else {
            throw ToolArgumentError("Missing \"\(keys[0])\".")
        }
        return value
    }

    private func string(_ keys: [String], maxLength: Int, trim: Bool) throws -> String? {
        guard let (key, value) = first(keys) else { return nil }
        guard case .string(let text) = value else { throw ToolArgumentError("\"\(key)\" must be a string.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let result = trim ? trimmed : text
        guard result.count <= maxLength else {
            throw ToolArgumentError("\"\(key)\" is too long (over \(maxLength) characters).")
        }
        return result
    }

    /// A boolean. Also accepts the strings "true" and "false", which some models send.
    public func bool(_ keys: String...) throws -> Bool? {
        guard let (key, value) = first(keys) else { return nil }
        switch value {
        case .bool(let flag): return flag
        case .string(let text) where text.lowercased() == "true": return true
        case .string(let text) where text.lowercased() == "false": return false
        default: throw ToolArgumentError("\"\(key)\" must be true or false.")
        }
    }

    /// A whole number within `range`. Also accepts a numeric string.
    public func int(_ keys: String..., in range: ClosedRange<Int>) throws -> Int? {
        guard let (key, value) = first(keys) else { return nil }
        let number: Double?
        switch value {
        case .number(let n): number = n
        case .string(let text): number = Double(text.trimmingCharacters(in: .whitespaces))
        default: number = nil
        }
        guard let number, number.isFinite, number.rounded() == number else {
            throw ToolArgumentError("\"\(key)\" must be a whole number.")
        }
        guard number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
            throw ToolArgumentError("\"\(key)\" must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return Int(number)
    }

    /// One of a fixed set of lowercase words.
    public func choice<Choice: RawRepresentable & CaseIterable>(_ keys: String..., as type: Choice.Type) throws -> Choice?
    where Choice.RawValue == String {
        guard let text = try string(keys, maxLength: 64, trim: true) else { return nil }
        let normalized = text.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        guard let choice = Choice(rawValue: normalized) else {
            let allowed = Choice.allCases.map(\.rawValue).joined(separator: ", ")
            throw ToolArgumentError("\"\(keys[0])\" must be one of: \(allowed).")
        }
        return choice
    }
}
