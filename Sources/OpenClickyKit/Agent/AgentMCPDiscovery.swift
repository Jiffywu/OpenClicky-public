import Foundation

/// Finds the MCP servers OpenClicky offers its agents. Today that is the browser bridge's loopback server, which
/// advertises itself in `BrowserBridge/mcp.json` (mode 0600) while it runs (`BrowserMCPEndpoint`, see
/// docs/browser-bridge.md). The file is re-read for every launch because its port and token change each time the
/// bridge starts. The token is handed to the harness only through the environment variable the file names.
public enum AgentMCPDiscovery {
    /// Where the bridge writes the file: `BrowserBridgePaths.standard` (`~/Library/Application Support/OpenClicky/
    /// BrowserBridge/mcp.json`, or under `OPENCLICKY_BRIDGE_DIR`). `OPENCLICKY_SUPPORT_DIR` doesn't move it, because
    /// it doesn't move the bridge either.
    public static var browserEndpointFile: URL { BrowserBridgePaths.standard.mcpEndpoint }

    /// The fields of `mcp.json` the agent needs (a subset of `BrowserMCPEndpoint`, decoded leniently so a newer
    /// bridge that adds fields still works).
    struct BrowserEndpoint: Decodable {
        var url: URL
        var token: String
        var serverName: String?
        var tokenEnvironmentVariable: String?
        var pid: Int32?
    }

    /// The browser MCP server if its endpoint file exists, names a loopback URL and its process is alive.
    public static func browserServer(file: URL = browserEndpointFile, isAlive: (Int32) -> Bool = processIsAlive) -> AgentMCPServer? {
        guard let data = try? Data(contentsOf: file),
              let endpoint = try? JSONDecoder().decode(BrowserEndpoint.self, from: data) else { return nil }
        guard ["127.0.0.1", "localhost", "::1", "[::1]"].contains(endpoint.url.host ?? ""),
              ["http", "https"].contains(endpoint.url.scheme?.lowercased() ?? "") else { return nil }
        if let pid = endpoint.pid, !isAlive(pid) { return nil }
        let token = endpoint.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = endpoint.serverName.flatMap { isValidName($0) ? $0 : nil } ?? "openclicky_browser"
        let variable = endpoint.tokenEnvironmentVariable.flatMap { isValidVariable($0) ? $0 : nil }
        var server = AgentMCPServer(name: name, transport: .http(endpoint.url), bearerToken: token.isEmpty ? nil : token,
                                    tokenEnvironmentVariable: variable, startupTimeout: 20, toolTimeout: 900)
        // The app serves the job tools on the same server; they, and the browser tool (BrowserCallIdentity, which ties
        // each call to the job's turn), tell jobs apart by this header.
        server.jobHeaderName = AgentJobMCPTools.jobHeader
        server.trustedTools = AgentJobMCPTools.names
        return server
    }

    /// Every server to offer a job right now.
    public static func current(browserFile: URL = browserEndpointFile) -> [AgentMCPServer] {
        [browserServer(file: browserFile)].compactMap { $0 }
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// Server names end up as TOML keys and `mcp__<name>__tool` prefixes; keep them plain.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "_" || $0 == "-"
        }
    }

    static func isValidVariable(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !(first >= "0" && first <= "9") else { return false }
        return name.count <= 128 && name.unicodeScalars.allSatisfy {
            ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "_"
        }
    }
}
