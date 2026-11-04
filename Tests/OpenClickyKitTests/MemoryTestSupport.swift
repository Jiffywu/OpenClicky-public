import Foundation
@testable import OpenClickyKit

/// A memory folder in the temporary directory, removed when the test's scope ends.
final class TemporaryMemoryFolder: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-memory-tests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func store(budget: MemoryBudget = MemoryBudget(), now: @escaping @Sendable () -> Date = { MemoryFixtures.now }) -> MemoryStore {
        MemoryStore(directory: url, budget: budget, now: now)
    }
}

/// A clock tests can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = MemoryFixtures.now) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(days: Double) { lock.withLock { current = current.addingTimeInterval(days * 86_400) } }

    var function: @Sendable () -> Date { { [self] in self.now } }
}

enum MemoryFixtures {
    /// 2026-10-30T12:00:00Z.
    static let now = Date(timeIntervalSince1970: 1_793_361_600)

    static func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    static func memory(_ id: String, _ text: String, kind: MemoryKind = .fact, daysAgo days: Double) -> MemoryEntry {
        MemoryEntry(id: id, text: text, place: .memory(kind), date: daysAgo(days))
    }
}

/// A language model that answers every request with a scripted reply, streamed in small pieces, and records what
/// it was sent.
final class ScriptedLanguageModel: LanguageModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: String
    private var recorded: [ChatRequest] = []

    init(reply: String) { self.reply = reply }

    var requests: [ChatRequest] { lock.withLock { recorded } }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.withLock { recorded.append(request) }
        let reply = reply
        return AsyncThrowingStream { continuation in
            var rest = Substring(reply)
            while !rest.isEmpty {
                continuation.yield(.textDelta(String(rest.prefix(7))))
                rest = rest.dropFirst(7)
            }
            continuation.yield(.usage(TokenUsage(inputTokens: 100, outputTokens: 50)))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }
}
