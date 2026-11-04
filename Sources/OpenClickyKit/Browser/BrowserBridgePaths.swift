import Foundation
import Security

/// Where the browser bridge keeps its socket, its per-install token and the agent MCP endpoint file.
///
/// Default: `~/Library/Application Support/OpenClicky/BrowserBridge/` (mode 0700). `OPENCLICKY_BRIDGE_DIR` overrides
/// it for tests; Chrome passes its environment to the native host, so a test browser launched with the variable set
/// talks to a test bridge.
public struct BrowserBridgePaths: Sendable, Hashable {
    public static let environmentOverride = "OPENCLICKY_BRIDGE_DIR"

    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var standard: BrowserBridgePaths {
        if let override = ProcessInfo.processInfo.environment[environmentOverride], !override.isEmpty {
            return BrowserBridgePaths(directory: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BrowserBridgePaths(directory: support.appendingPathComponent("OpenClicky/BrowserBridge", isDirectory: true))
    }

    /// Unix-domain socket the app listens on and the native host connects to.
    public var socket: URL { directory.appendingPathComponent("bridge.sock") }
    /// Per-install secret the host presents on the socket (64 hex characters, mode 0600).
    public var token: URL { directory.appendingPathComponent("token") }
    /// Written while the agent MCP server runs; see `BrowserMCPEndpoint` and docs/browser-bridge.md.
    public var mcpEndpoint: URL { directory.appendingPathComponent("mcp.json") }
    /// Optional extra extension IDs (one per line) the host accepts, for differently keyed development copies.
    public var extraExtensionIDs: URL { directory.appendingPathComponent("extra-extension-ids.txt") }

    /// Creates the directory with mode 0700 (and tightens it if it already exists).
    public func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Reads the per-install token, creating it on first use.
    public func loadOrCreateToken() throws -> String {
        if let existing = try? readToken() { return existing }
        try prepareDirectory()
        let token = try BrowserBridgeSecrets.randomHex(bytes: 32)
        try BrowserBridgeSecrets.writePrivate(Data((token + "\n").utf8), to: self.token)
        return token
    }

    /// The per-install token, or nil if it was never created.
    public func readToken() throws -> String? {
        guard FileManager.default.fileExists(atPath: token.path) else { return nil }
        let text = try String(contentsOf: token, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Extension IDs listed in `extra-extension-ids.txt`.
    public func readExtraExtensionIDs() -> [String] {
        guard let text = try? String(contentsOf: extraExtensionIDs, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { ChromeExtensionIdentity.isValidID($0) }
    }
}

public enum BrowserBridgeSecrets {
    /// `bytes` random bytes from the system CSPRNG as lowercase hex.
    public static func randomHex(bytes: Int) throws -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        guard status == errSecSuccess else { throw POSIXError(.EIO) }
        return buffer.map { String(format: "%02x", $0) }.joined()
    }

    /// Compares two secrets in time that depends only on their lengths.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = UInt8(x.count == y.count ? 0 : 1)
        for index in 0..<max(x.count, y.count) {
            difference |= (index < x.count ? x[index] : 0) ^ (index < y.count ? y[index] : 0)
        }
        return difference == 0
    }

    /// Writes a file only the user can read: a 0600 temp file renamed over the target.
    public static func writePrivate(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temp.path])
        }
        if rename(temp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

/// How agent harnesses reach the browser MCP server. The bridge writes this to `BrowserBridge/mcp.json` (mode 0600)
/// while the server runs and deletes it when it stops. The URL's port and the token change on every launch.
public struct BrowserMCPEndpoint: Codable, Sendable, Hashable {
    /// MCP server name harnesses should register (`[mcp_servers.openclicky_browser]` for Codex).
    public static let serverName = "openclicky_browser"
    /// Environment variable harnesses should carry the token in (never write the token into their config files).
    public static let tokenEnvironmentVariable = "OPENCLICKY_BROWSER_MCP_TOKEN"

    /// `http://127.0.0.1:<port>/mcp`
    public var url: URL
    /// Bearer token for `Authorization: Bearer <token>`.
    public var token: String
    public var serverName: String
    public var tokenEnvironmentVariable: String
    public var transport: String
    /// The process serving the endpoint; a dead pid means the file is stale.
    public var pid: Int32
    public var startedAt: Date

    public init(url: URL, token: String, pid: Int32 = getpid(), startedAt: Date = Date()) {
        self.url = url
        self.token = token
        self.serverName = Self.serverName
        self.tokenEnvironmentVariable = Self.tokenEnvironmentVariable
        self.transport = "streamable-http"
        self.pid = pid
        self.startedAt = startedAt
    }

    public static func load(from paths: BrowserBridgePaths = .standard) throws -> BrowserMCPEndpoint {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BrowserMCPEndpoint.self, from: Data(contentsOf: paths.mcpEndpoint))
    }

    /// The endpoint if the file exists and its process is still alive.
    public static func loadIfRunning(from paths: BrowserBridgePaths = .standard) -> BrowserMCPEndpoint? {
        guard let endpoint = try? load(from: paths), endpoint.isProcessAlive else { return nil }
        return endpoint
    }

    public var isProcessAlive: Bool { kill(pid, 0) == 0 || errno == EPERM }

    public func write(to paths: BrowserBridgePaths) throws {
        try paths.prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try BrowserBridgeSecrets.writePrivate(try encoder.encode(self), to: paths.mcpEndpoint)
    }

    /// A Codex `config.toml` block. The token stays in the environment variable.
    public var codexConfigTOML: String {
        """
        [mcp_servers.\(serverName)]
        url = "\(url.absoluteString)"
        bearer_token_env_var = "\(tokenEnvironmentVariable)"
        startup_timeout_sec = 20.0
        tool_timeout_sec = 900.0
        """
    }

    /// A Claude Code `--mcp-config` document. Claude Code expands `${VAR}` in headers, so the token stays in the
    /// environment variable here too.
    public var claudeMCPConfig: JSONValue {
        ["mcpServers": .object([serverName: [
            "type": "http",
            "url": .string(url.absoluteString),
            "headers": ["Authorization": .string("Bearer ${\(tokenEnvironmentVariable)}")],
        ]])]
    }
}
