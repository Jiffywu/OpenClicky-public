import Foundation
import Testing
@testable import OpenClickyKit

@Test func sseParserKeepsEventBoundariesAcrossChunks() throws {
    let body = "event: a\ndata: {\"x\":1}\n\n: comment\ndata: line one\ndata: line two\n\ndata: tail"
    var parser = SSEParser()
    var events: [ServerSentEvent] = []
    for byte in Data(body.utf8) { events += parser.feed(Data([byte])) }
    events += parser.finish()
    #expect(events.map(\.data) == ["{\"x\":1}", "line one\nline two", "tail"])
    #expect(events.first?.event == "a")
    #expect(events[1].event == nil)
}

@Test func sseParserHandlesCRLF() {
    var parser = SSEParser()
    let events = parser.feed(Data("data: one\r\n\r\ndata: two\r\n\r\n".utf8))
    #expect(events.map(\.data) == ["one", "two"])
}

@Test func fakeTransportStreamsScriptedSSE() async throws {
    let fake = FakeHTTPTransport([.sse("data: 1\n\ndata: 2\n\ndata: [DONE]\n\n", chunkSize: 3)])
    let stream = try await fake.checkedStream(for: URLRequest(url: URL(string: "https://example.com")!), provider: "test")
    var seen: [String] = []
    for try await event in stream.serverSentEvents() { seen.append(event.data) }
    #expect(seen == ["1", "2", "[DONE]"])
}

@Test func checkedStreamSurfacesProviderErrors() async {
    let fake = FakeHTTPTransport([.body("{\"error\":{\"message\":\"bad key\"}}", status: 401)])
    await #expect(throws: ProviderError.self) {
        _ = try await fake.checkedStream(for: URLRequest(url: URL(string: "https://example.com")!), provider: "test")
    }
}

@Test func fakeWebSocketDeliversPushedMessagesInOrder() async throws {
    let socket = FakeWebSocket(inbound: [.text("first")])
    socket.onSend = { message, ws in
        if case .text(let t) = message { ws.push(.text("echo:\(t)")) }
    }
    try await socket.send(.text("hi"))
    #expect(try await socket.receive() == .text("first"))
    #expect(try await socket.receive() == .text("echo:hi"))
    await socket.close()
    await #expect(throws: URLError.self) { _ = try await socket.receive() }
}

@Test func jsonValueRoundTripsAndKeepsIntegers() throws {
    let value: JSONValue = ["n": 3, "f": 1.5, "s": "x", "a": [true, .null], "o": ["k": "v"]]
    let text = value.jsonString()
    #expect(text == "{\"a\":[true,null],\"f\":1.5,\"n\":3,\"o\":{\"k\":\"v\"},\"s\":\"x\"}")
    #expect(try JSONValue.parse(text) == value)
}

@Test func providerContextJoinsURLs() {
    let ctx = ProviderContext(provider: ProviderConfig(id: "p", dialect: .openAIChat, baseURL: URL(string: "https://openrouter.ai/api/v1/")), apiKey: nil)
    #expect(ctx.url("/chat/completions", default: "https://api.openai.com/v1").absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    let bare = ProviderContext(provider: ProviderConfig(id: "p", dialect: .openAIChat), apiKey: nil)
    #expect(bare.url("chat/completions", default: "https://api.openai.com/v1").absoluteString == "https://api.openai.com/v1/chat/completions")
}
