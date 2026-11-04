import Foundation

// The extra headers and environment variables a connector form takes as lines ("X-Api-Key: …", "API_TOKEN=…").
// Values are secrets: they go to the credential store under `ConnectorSecretNames`, and connectors.json keeps only
// the header or variable name and the credential's name (the same path `occtl apps header` and `occtl apps env` use).

public enum ConnectorSecretLines {
    public enum Kind: Sendable, Hashable {
        /// `Header-Name: value`, for remote servers.
        case header
        /// `VARIABLE=value`, for commands on this Mac.
        case environment
    }

    public struct Line: Sendable, Hashable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case malformed(line: Int, kind: Kind)
        case badName(String, kind: Kind)
        case authorizationHeader
        case emptyValue(String)

        public var description: String {
            switch self {
            case .malformed(let line, .header): "Line \(line) needs the form Header-Name: value."
            case .malformed(let line, .environment): "Line \(line) needs the form NAME=value."
            case .badName(let name, .header): "\"\(name)\" isn't a usable header name (letters, digits and - only)."
            case .badName(let name, .environment): "\"\(name)\" isn't a usable variable name (A–Z, 0–9 and _ only)."
            case .authorizationHeader: "Put an Authorization token in the token field instead of a header line."
            case .emptyValue(let name): "\(name) has no value."
            }
        }
    }

    /// The lines of `text`, skipping blank ones and `#` comments. Throws on the first line that can't be used.
    public static func parse(_ text: String, kind: Kind) throws -> [Line] {
        var lines: [Line] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let separator: Character = kind == .header ? ":" : "="
            guard let split = line.firstIndex(of: separator) else { throw Problem.malformed(line: index + 1, kind: kind) }
            let name = line[..<split].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            guard isValidName(name, kind: kind) else { throw Problem.badName(name, kind: kind) }
            if kind == .header, name.lowercased() == "authorization" { throw Problem.authorizationHeader }
            guard !value.isEmpty else { throw Problem.emptyValue(name) }
            // A later line for the same name wins (header names ignore case).
            lines.removeAll { kind == .header ? $0.name.caseInsensitiveCompare(name) == .orderedSame : $0.name == name }
            lines.append(Line(name: name, value: value))
        }
        return lines
    }

    public static func isValidName(_ name: String, kind: Kind) -> Bool {
        guard !name.isEmpty else { return false }
        switch kind {
        case .header: return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        case .environment: return name.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") } && !(name.first?.isNumber ?? true)
        }
    }

    /// Stores each value in `credentials` and returns `connector` naming them (values never appear in it).
    public static func apply(_ lines: [Line], kind: Kind, to connector: ConnectorConfig,
                             credentials: any CredentialStore) throws -> ConnectorConfig {
        var connector = connector
        for line in lines {
            switch kind {
            case .header:
                let credential = ConnectorSecretNames.header(connector.id, line.name)
                try credentials.setSecret(line.value, named: credential)
                var headers = connector.secretHeaders ?? [:]
                // One entry per header, whatever its case.
                for key in headers.keys where key.caseInsensitiveCompare(line.name) == .orderedSame { headers[key] = nil }
                headers[line.name] = credential
                connector.secretHeaders = headers
            case .environment:
                let credential = ConnectorSecretNames.environment(connector.id, line.name)
                try credentials.setSecret(line.value, named: credential)
                connector.environment = (connector.environment ?? [:]).merging([line.name: credential]) { _, new in new }
            }
        }
        return connector
    }

    /// Forgets one header or variable: its credential and its entry.
    public static func remove(_ name: String, kind: Kind, from connector: ConnectorConfig, credentials: any CredentialStore) -> ConnectorConfig {
        var connector = connector
        switch kind {
        case .header:
            if let credential = connector.secretHeaders?[name] { try? credentials.removeSecret(named: credential) }
            connector.secretHeaders?[name] = nil
            if connector.secretHeaders?.isEmpty == true { connector.secretHeaders = nil }
        case .environment:
            if let credential = connector.environment?[name] { try? credentials.removeSecret(named: credential) }
            connector.environment?[name] = nil
            if connector.environment?.isEmpty == true { connector.environment = nil }
        }
        return connector
    }
}

/// What the "add a connector" form collects, saved in one step: the connector into the registry, the token, header
/// values and environment values into the credential store.
public struct ConnectorDraft: Sendable {
    public var name: String
    public var transport: ConnectorTransport
    public var auth: ConnectorAuth
    public var token: String
    public var accountLabel: String
    /// `Header-Name: value` lines (remote servers).
    public var headerLines: String
    /// `NAME=value` lines (commands).
    public var environmentLines: String

    public init(name: String, transport: ConnectorTransport, auth: ConnectorAuth = .none, token: String = "", accountLabel: String = "",
                headerLines: String = "", environmentLines: String = "") {
        self.name = name
        self.transport = transport
        self.auth = auth
        self.token = token
        self.accountLabel = accountLabel
        self.headerLines = headerLines
        self.environmentLines = environmentLines
    }

    /// Adds the connector to `registry` and stores its secrets. Nothing is stored when a line is malformed.
    @discardableResult
    public func save(into registry: inout ConnectorRegistry, credentials: any CredentialStore) throws -> ConnectorConfig {
        let isRemote = transport.remoteURL != nil
        let headers = isRemote ? try ConnectorSecretLines.parse(headerLines, kind: .header) : []
        let variables = isRemote ? [] : try ConnectorSecretLines.parse(environmentLines, kind: .environment)
        let label = accountLabel.trimmingCharacters(in: .whitespaces)
        var updated = registry
        var added = try updated.add(ConnectorConfig(id: "", name: name.trimmingCharacters(in: .whitespaces), transport: transport, auth: auth,
                                                    accountLabel: label.isEmpty ? nil : label))
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if auth == .bearer, !trimmedToken.isEmpty { try credentials.setSecret(trimmedToken, named: ConnectorSecretNames.bearer(added.id)) }
        added = try ConnectorSecretLines.apply(headers, kind: .header, to: added, credentials: credentials)
        added = try ConnectorSecretLines.apply(variables, kind: .environment, to: added, credentials: credentials)
        updated.update(added)
        registry = updated
        return added
    }
}
