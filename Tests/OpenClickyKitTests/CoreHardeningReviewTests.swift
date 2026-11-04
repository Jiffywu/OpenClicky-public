import Foundation
import Testing
@testable import OpenClickyKit

/// Problems found reviewing the core-hardening branch. Each test fails on the code before its fix.
@Suite struct CoreHardeningReviewTests {
    // MARK: - ProviderContext

    @Test func providerContextHidesCredentialsInTheBaseURL() {
        let context = ProviderContext(
            provider: ProviderConfig(id: "proxy", dialect: .openAIChat,
                                     baseURL: URL(string: "https://me:SECRET-pass@proxy.example.com:8443/v1?key=SECRET-query#frag")),
            apiKey: nil)
        var dumped = ""
        dump(context, to: &dumped)
        for text in [String(describing: context), String(reflecting: context), dumped] {
            #expect(!text.contains("SECRET"), "leaked in: \(text)")
            #expect(text.contains("https://<redacted>@proxy.example.com:8443/v1?<redacted>"), "in: \(text)")
        }
        // A plain base URL is shown as it is.
        let plain = ProviderContext(provider: ProviderConfig(id: "local", dialect: .openAIChat, baseURL: URL(string: "http://[::1]:11434/v1")),
                                    apiKey: nil)
        #expect(String(describing: plain).contains("baseURL: http://[::1]:11434/v1"))
    }

    @Test func chatAdaptersHideCredentialsInTheirEndpoint() {
        let provider = ProviderConfig(id: "proxy", dialect: .openAIChat, baseURL: URL(string: "https://me:SECRET-pass@proxy.example.com/v1"))
        let context = ProviderContext(provider: provider, apiKey: nil)
        let clients: [Any] = [OpenAIChatClient(context: context), OpenAIResponsesClient(context: context)]
        for client in clients {
            var dumped = ""
            dump(client, to: &dumped)
            for text in [String(describing: client), String(reflecting: client), dumped] {
                #expect(!text.contains("SECRET"), "leaked in: \(text)")
                #expect(text.contains("https://<redacted>@proxy.example.com/v1/"), "in: \(text)")
            }
        }
    }

    @Test func providerHeadersThatDifferOnlyInCaseMergeTheSameWayEveryTime() {
        // Dictionary order depends on capacity and the process seed; ties on the lowercased name used to follow it.
        var orders: Set<[String]> = []
        for capacity in 0..<64 {
            var provider = [String: String](minimumCapacity: capacity)
            provider["x-route"] = "lower"
            provider["X-Route"] = "upper"
            provider["X-Title"] = "OpenClicky"
            orders.insert(ProviderContext.mergedHeaders(provider: provider, adapter: [:]).map(\.0))
        }
        #expect(orders == [["X-Route", "x-route", "X-Title"]])
    }

    // MARK: - URLSession WebSocket

    @Test func refusedUpgradeSurfacesTheStatusFromSendToo() async throws {
        // The Realtime adapter sends session.update before it reads anything, so send must carry the status as well.
        let server = try await LoopbackServer { connection in
            _ = try await connection.readRequestHead()
            try await connection.write(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        }
        defer { server.stop() }
        let socket = try await URLSessionWebSocketConnector().connect(URLRequest(url: server.url("/realtime", scheme: "ws")))
        let error = await #expect(throws: ProviderError.self) {
            try await withTimeout(.seconds(10)) { try await socket.send(.text("{}")) }
        }
        #expect(error?.status == 403)
        await socket.close()
    }

    // MARK: - FakeWebSocket

    @Test func fakeWebSocketSendAfterServerCloseThrowsTheCloseError() async {
        // A real connection whose upgrade was refused throws the same ProviderError from send as from receive.
        let socket = FakeWebSocket()
        socket.serverClose(with: ProviderError(provider: "api.openai.com", status: 401, message: "refused"))
        let error = await #expect(throws: ProviderError.self) { try await socket.send(.text("hi")) }
        #expect(error?.status == 401)
        // Closing on our side still reports a lost connection.
        let closed = FakeWebSocket()
        await closed.close()
        await #expect(throws: URLError.self) { try await closed.send(.text("hi")) }
    }

    @Test func realtimeSpeechReportsTheStatusOfARefusedUpgrade() async throws {
        let socket = FakeWebSocket()
        socket.serverClose(with: ProviderError(provider: "api.openai.com", status: 401, message: "The server refused the WebSocket connection (HTTP 401 unauthorized)."))
        let client = OpenAIRealtimeSpeechClient(
            context: ProviderContext(provider: ProviderConfig(id: "openai", dialect: .openAIRealtime, credential: "openai"), apiKey: "k",
                                     webSocket: socket),
            timeout: .seconds(5))
        let error = await #expect(throws: (any Error).self) { for try await _ in client.speak("Hello.", voice: nil, instructions: nil) {} }
        #expect(String(describing: error.map { $0 as Any } ?? "").contains("401"), "got \(String(describing: error))")
    }

    @Test func fakeWebSocketHandlerCanBeSwappedWhileSending() async throws {
        // onSend is set by tests while an adapter may be sending; both sides go through the lock.
        let socket = FakeWebSocket()
        let counter = SendCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask { try await socket.send(.text("\(index)")) }
                group.addTask { socket.onSend = { _, _ in counter.increment() } }
            }
            try await group.waitForAll()
        }
        #expect(socket.sent.count == 200)
    }
}

private final class SendCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
