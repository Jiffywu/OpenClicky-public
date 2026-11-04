import Foundation
import Network
import Testing
@testable import OpenClickyKit

/// The binary stream must stop its URLSession task whenever the caller is done with the body, however it is done:
/// cancelling, breaking out of the loop, or dropping the stream unread. Otherwise the download keeps running (and
/// buffering into a stream nobody reads) until the server finishes, which for streamed speech is the whole line.
/// Each test uses its own session, so "no task left" is about this test's request only.
@Suite struct BinaryStreamCancellationTests {
    /// Sends the head, then a 32 KB body chunk every 50 ms for up to 8 s: a long line of speech.
    static func endlessAudioServer() async throws -> LoopbackServer {
        try await LoopbackServer { connection in
            _ = try await connection.readRequestHead()
            try await connection.write(Data("HTTP/1.1 200 OK\r\nContent-Type: audio/pcm\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
            let start = ContinuousClock.now
            while ContinuousClock.now - start < .seconds(8) {
                try await connection.write(URLSessionTransportTests.chunk(Data(repeating: 7, count: 32_000)))
                try await Task.sleep(for: .milliseconds(50))
            }
            try await connection.write(Data("0\r\n\r\n".utf8))
        }
    }

    /// Waits until `session` has no task left, failing after `limit`. The limit is a hang guard, kept well short of the
    /// 8 s an uncancelled download of `endlessAudioServer` would run for.
    static func expectNoTaskLeft(in session: URLSession, within limit: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + limit
        var live: [URLSessionTask] = []
        repeat {
            live = await session.allTasks.filter { $0.state == .running || $0.state == .suspended }
            if live.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        Issue.record("\(live.count) task(s) still running, \(live.map(\.countOfBytesReceived)) bytes received")
    }

    static func session() -> URLSession { URLSession(configuration: .ephemeral) }

    @Test(arguments: [HTTPStreamMode.lines, .binary])
    func droppingTheUnreadBodyCancelsTheTask(_ mode: HTTPStreamMode) async throws {
        let server = try await Self.endlessAudioServer()
        defer { server.stop() }
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await URLSessionTransport(session: session).stream(for: URLRequest(url: server.url("/speech")), mode: mode)
            #expect(response.statusCode == 200)
        }
        await Self.expectNoTaskLeft(in: session)
    }

    @Test(arguments: [HTTPStreamMode.lines, .binary])
    func breakingOutOfTheBodyCancelsTheTask(_ mode: HTTPStreamMode) async throws {
        let server = try await Self.endlessAudioServer()
        defer { server.stop() }
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        do {
            let (body, _) = try await URLSessionTransport(session: session).stream(for: URLRequest(url: server.url("/speech")), mode: mode)
            for try await chunk in body where !chunk.isEmpty { break }
        }
        await Self.expectNoTaskLeft(in: session)
    }

    @Test(arguments: [HTTPStreamMode.lines, .binary])
    func cancellingTheReaderCancelsTheTask(_ mode: HTTPStreamMode) async throws {
        let server = try await Self.endlessAudioServer()
        defer { server.stop() }
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let firstChunk = Gate()
        let reader = Task {
            let (body, _) = try await URLSessionTransport(session: session).stream(for: URLRequest(url: server.url("/speech")), mode: mode)
            for try await _ in body { await firstChunk.open() }
        }
        try await withTimeout(.seconds(10)) { await firstChunk.wait() }
        reader.cancel()
        _ = await reader.result
        await Self.expectNoTaskLeft(in: session)
    }

    @Test(arguments: [HTTPStreamMode.lines, .binary])
    func cancellingWhileWaitingForTheHeadThrowsAndCancelsTheTask(_ mode: HTTPStreamMode) async throws {
        let requested = Gate()
        let server = try await LoopbackServer { connection in
            _ = try await connection.readRequestHead()
            await requested.open()
            // Never answers.
            try? await Task.sleep(for: .seconds(8))
        }
        defer { server.stop() }
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let caller = Task {
            _ = try await URLSessionTransport(session: session).stream(for: URLRequest(url: server.url("/slow")), mode: mode)
        }
        try await withTimeout(.seconds(10)) { await requested.wait() }
        caller.cancel()
        let result = try await withTimeout(.seconds(5)) { await caller.result }
        #expect(throws: (any Error).self) { try result.get() }
        await Self.expectNoTaskLeft(in: session)
    }

    @Test func alreadyCancelledStartDoesNotHang() async throws {
        // Bypasses the transport's up-front cancellation check, so the cancellation handler runs before the task is
        // resumed: the start must still end instead of waiting forever for a head.
        let server = try await LoopbackServer { connection in
            _ = try await connection.readRequestHead()
            try await connection.write(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))
        }
        defer { server.stop() }
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let url = server.url("/x")
        let result = try await withTimeout(.seconds(10)) {
            await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await BinaryResponseStream.start(URLRequest(url: url), session: session)
            }.result
        }
        #expect(throws: (any Error).self) { _ = try result.get() }
        await Self.expectNoTaskLeft(in: session)
    }
}
