import Foundation
import Testing
@testable import OpenClickyKit

// Newline framing, and a real child process: a /bin/sh script that plays an initialize-based MCP server.

@Test func framerSplitsChunksAtNewlinesAndToleratesCRLFAndBlankLines() {
    var framer = NewlineJSONFramer()
    let text = "{\"a\":1}\r\n\n  \n{\"b\":\"x y\"}\n{\"c\":"
    var lines: [String] = []
    for byte in Data(text.utf8) { lines += framer.feed(Data([byte])).map { String(decoding: $0, as: UTF8.self) } }
    #expect(lines == ["{\"a\":1}", "{\"b\":\"x y\"}"])
    lines += framer.feed(Data("3}".utf8)).map { String(decoding: $0, as: UTF8.self) }
    #expect(lines.count == 2)
    #expect(framer.finish().map { String(decoding: $0, as: UTF8.self) } == "{\"c\":3}")
    #expect(framer.finish() == nil)
}

@Test func framerKeepsMultibyteCharactersSplitAcrossChunks() throws {
    var framer = NewlineJSONFramer()
    let data = Data("{\"t\":\"héllo 世界\"}\n".utf8)
    var lines: [Data] = []
    for index in data.indices { lines += framer.feed(data.subdata(in: index..<(index + 1))) }
    #expect(lines.count == 1)
    #expect(try JSONValue.parse(String(decoding: lines[0], as: UTF8.self))["t"]?.stringValue == "héllo 世界")
}

@Test func framedMessagesAreOneLineEvenWithNewlinesInStrings() throws {
    let message = MCPOutgoingMessage(id: .number(7), method: "tools/call", params: ["name": "echo", "arguments": ["text": "two\nlines"]])
    let framed = NewlineJSONFramer.frame(message)
    #expect(framed.last == 0x0A)
    #expect(framed.filter { $0 == 0x0A }.count == 1)
    let parsed = try JSONValue.parse(String(decoding: framed.dropLast(), as: UTF8.self))
    #expect(parsed["params"]?["arguments"]?["text"]?.stringValue == "two\nlines")
    #expect(parsed["id"]?.intValue == 7)
}

@Test func commandResolverWidensPathAndFindsExecutables() {
    let home = URL(fileURLWithPath: "/Users/someone")
    let path = MCPCommandResolver.searchPath(base: "/usr/bin:/bin:/usr/bin", home: home)
    let parts = path.split(separator: ":").map(String.init)
    #expect(parts.prefix(2) == ["/usr/bin", "/bin"])
    #expect(parts.filter { $0 == "/usr/bin" }.count == 1)
    #expect(parts.contains("/opt/homebrew/bin"))
    #expect(parts.contains("/Users/someone/.cargo/bin"))
    #expect(MCPCommandResolver.resolve("sh", searchPath: "/nonexistent:/bin")?.path == "/bin/sh")
    #expect(MCPCommandResolver.resolve("/bin/sh", searchPath: "")?.path == "/bin/sh")
    #expect(MCPCommandResolver.resolve("definitely-not-a-command-xyz", searchPath: "/bin:/usr/bin") == nil)
    let environment = MCPCommandResolver.environment(base: ["PATH": "/bin", "HOME": "/h"], adding: ["API_TOKEN": "t"])
    #expect(environment["API_TOKEN"] == "t")
    #expect(environment["HOME"] == "/h")
    #expect(environment["PATH"]?.hasPrefix("/bin:") == true)
}

/// A fake MCP server in POSIX sh. It logs every line it receives, prints a non-JSON banner, answers
/// `server/discover` with "method not found" (or not at all when SILENT_DISCOVER=1), uses CRLF for one reply,
/// asks the client for `roots/list`, and exits on the "crash" tool.
private let fakeServerScript = #"""
log="$1"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$log"
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"server/discover"'*)
      if [ "$SILENT_DISCOVER" != 1 ]; then
        echo "fake server starting (not JSON)"
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id"
      fi ;;
    *'"method":"initialize"'*)
      echo "initializing" >&2
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"sh-fake","version":"0.1"}}}\r\n' "$id" ;;
    *'"method":"tools/list"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":"srv-1","method":"roots/list"}'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"listing"}}'
      printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"get_time","description":"Current time","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
    *'"method":"tools/call"'*)
      case "$line" in
        *'"crash"'*) echo "fatal: crashed on purpose" >&2; exit 3 ;;
        *'"slow"'*) : ;;
        *) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"12:00"}]}}\n' "$id" ;;
      esac ;;
  esac
done
"""#

private struct ShellServer {
    let directory: URL
    let log: URL

    init(_ name: String = #function) throws {
        directory = try scratchFolder(name)
        log = directory.appendingPathComponent("received.log")
        try fakeServerScript.write(to: directory.appendingPathComponent("server.sh"), atomically: true, encoding: .utf8)
    }

    func transport(environment extra: [String: String] = [:], notifications: ProgressBox? = nil) -> MCPStdioTransport {
        let launch = MCPStdioLaunch(executable: URL(fileURLWithPath: "/bin/sh"),
                                    arguments: [directory.appendingPathComponent("server.sh").path, log.path],
                                    environment: MCPCommandResolver.environment(adding: extra))
        return MCPStdioTransport(launch: launch) { method, _ in notifications?.add(method) }
    }

    func received() -> [JSONValue] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
    }

    func receivedLineCount() -> Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
    }
}

@Suite(.serialized) struct MCPStdioProcessTests {
    @Test func childProcessHandshakeListAndCall() async throws {
        let server = try ShellServer()
        let notifications = ProgressBox()
        let transport = server.transport(notifications: notifications)
        let client = MCPClient(transport: transport, options: .init(probeTimeout: .seconds(5), requestTimeout: .seconds(10)))

        let description = try await client.connect()
        #expect(description.era == .legacy)
        #expect(description.serverInfo?.name == "sh-fake")
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["get_time"])
        let result = try await client.callTool("get_time")
        #expect(result.text == "12:00")
        #expect(notifications.methods.contains("notifications/message"))
        #expect(transport.recentStandardError.contains("initializing"))
        await client.close()
        #expect(!transport.isRunning)

        // Every line the child received was exactly one JSON-RPC message.
        let lines = server.received()
        #expect(lines.count == server.receivedLineCount())
        let methods = lines.compactMap { $0["method"]?.stringValue }
        #expect(methods == ["server/discover", "initialize", "notifications/initialized", "tools/list", "tools/call"])
        #expect(lines.allSatisfy { $0["jsonrpc"]?.stringValue == "2.0" })
        // The server's roots/list request got a "method not found" reply, since OpenClicky offers no roots.
        let reply = try #require(lines.first { $0["id"]?.stringValue == "srv-1" })
        #expect(reply["error"]?["code"]?.intValue == JSONRPCError.methodNotFound)
        let initialize = try #require(lines.first { $0["method"]?.stringValue == "initialize" })
        #expect(initialize["params"]?["protocolVersion"]?.stringValue == MCPProtocolVersion.preferredLegacy)
    }

    @Test func silentProbeTimesOutAndFallsBackToInitialize() async throws {
        let server = try ShellServer()
        let client = MCPClient(transport: server.transport(environment: ["SILENT_DISCOVER": "1"]),
                               options: .init(probeTimeout: .milliseconds(400), requestTimeout: .seconds(10)))
        let description = try await client.connect()
        #expect(description.era == .legacy)
        #expect(try await client.listTools().count == 1)
        await client.close()
    }

    @Test func crashedServerReportsItsExitStatusAndStderr() async throws {
        let server = try ShellServer()
        let client = MCPClient(transport: server.transport(), options: .init(probeTimeout: .seconds(5), requestTimeout: .seconds(10)))
        _ = try await client.connect()
        do {
            _ = try await client.callTool("crash")
            Issue.record("expected the process to exit")
        } catch MCPClientError.processExited(let status, let stderr) {
            #expect(status == 3)
            #expect(stderr.contains("crashed on purpose"))
        }
        // Later requests fail fast instead of hanging.
        await #expect(throws: MCPClientError.self) { _ = try await client.callTool("get_time") }
    }

    @Test func cancellingACallSendsCancelledToTheServer() async throws {
        let server = try ShellServer()
        let client = MCPClient(transport: server.transport(), options: .init(probeTimeout: .seconds(5), requestTimeout: .seconds(30)))
        _ = try await client.connect()
        let call = Task { try await client.callTool("slow") }
        try await Task.sleep(for: .milliseconds(300))
        call.cancel()
        await #expect(throws: CancellationError.self) { _ = try await call.value }
        var cancelled: JSONValue?
        for _ in 0..<50 where cancelled == nil {
            cancelled = server.received().first { $0["method"]?.stringValue == "notifications/cancelled" }
            if cancelled == nil { try await Task.sleep(for: .milliseconds(40)) }
        }
        let slowID = server.received().first { $0["params"]?["name"]?.stringValue == "slow" }?["id"]
        #expect(cancelled?["params"]?["requestId"] == slowID)
        await client.close()
    }

    @Test func concurrentLargeRequestsReachTheServerAsWholeLines() async throws {
        // Messages bigger than the pipe buffer are written in several write(2) calls. Two tasks writing at once
        // must not interleave their bytes, or the server sees broken JSON and both requests hang.
        let server = try ShellServer()
        let client = MCPClient(transport: server.transport(), options: .init(probeTimeout: .seconds(5), requestTimeout: .seconds(10)))
        _ = try await client.connect()
        let padding = String(repeating: "x", count: 80_000)
        let texts = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask { try await client.callTool("get_time", arguments: ["pad": .string(padding), "n": .number(Double(index))]).text }
            }
            var all: [String] = []
            for try await text in group { all.append(text) }
            return all
        }
        #expect(texts == Array(repeating: "12:00", count: 8))
        let calls = server.received().filter { $0["method"]?.stringValue == "tools/call" }
        #expect(calls.count == 8)
        #expect(server.receivedLineCount() == server.received().count)
        await client.close()
    }

    @Test func childEnvironmentOnlyInheritsBasicsAndTheConnectorsOwnValues() {
        let base = ["PATH": "/bin", "HOME": "/h", "USER": "me", "LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8", "TMPDIR": "/t",
                    "OPENAI_API_KEY": "sk-secret", "OPENCLICKY_KEY_OPENAI": "sk-dev", "GITHUB_TOKEN": "ghp_x", "AWS_SECRET_ACCESS_KEY": "a"]
        let environment = MCPCommandResolver.environment(base: base, adding: ["API_TOKEN": "t", "GITHUB_TOKEN": "mine"])
        #expect(environment["HOME"] == "/h")
        #expect(environment["USER"] == "me")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["LC_CTYPE"] == "UTF-8")
        #expect(environment["TMPDIR"] == "/t")
        #expect(environment["PATH"]?.hasPrefix("/bin:") == true)
        // The connector's own values are passed; everything else from OpenClicky's environment is not.
        #expect(environment["API_TOKEN"] == "t")
        #expect(environment["GITHUB_TOKEN"] == "mine")
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["OPENCLICKY_KEY_OPENAI"] == nil)
        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
    }

    @Test func missingExecutableIsALaunchError() async throws {
        let transport = MCPStdioTransport(launch: MCPStdioLaunch(executable: URL(fileURLWithPath: "/nonexistent/server"), environment: [:]))
        await #expect(throws: MCPClientError.self) { _ = try await MCPClient(transport: transport).connect() }
    }
}
