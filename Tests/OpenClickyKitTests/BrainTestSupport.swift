import CoreGraphics
import Foundation
@testable import OpenClickyKit

/// A one-shot latch a test opens to let a scripted model continue.
final class BrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var openedByTest = false

    func open() {
        lock.lock()
        isOpen = true
        openedByTest = true
        let ready = waiters
        waiters = []
        lock.unlock()
        for waiter in ready { waiter.resume() }
    }

    private func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
        let ready: Bool = lock.withLock {
            if isOpen { return true }
            waiters.append(continuation)
            return false
        }
        if ready { continuation.resume() }
    }

    private func releaseAll() -> [CheckedContinuation<Void, Never>] {
        lock.withLock {
            let stuck = waiters
            waiters = []
            return stuck
        }
    }

    /// Waits until opened; gives up after `timeout` so a failing test never hangs.
    func wait(timeout: Duration = .seconds(5)) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in self.enqueue(continuation) }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
            for waiter in self.releaseAll() { waiter.resume() }
        }
    }
}

/// A brain-slot model that plays one script per request and records every request.
final class BrainScriptModel: LanguageModelClient, @unchecked Sendable {
    enum Step: @unchecked Sendable {
        case text(String)
        case call(String, String, String) // id, name, arguments
        case usage(input: Int, cached: Int, output: Int)
        case wait(BrainGate)
        case sleep(Duration)
        /// Never finishes until cancelled.
        case hang
        case fail(Error)
        case finish(FinishReason)
    }

    private let lock = NSLock()
    private var scripts: [[Step]]
    private var recorded: [ChatRequest] = []
    private var terminations = 0

    init(_ scripts: [[Step]]) { self.scripts = scripts }

    var requests: [ChatRequest] { lock.withLock { recorded } }
    /// Streams that ended because their consumer went away (cancelled).
    var cancelledStreams: Int { lock.withLock { terminations } }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let steps: [Step] = lock.withLock {
            recorded.append(request)
            return scripts.isEmpty ? [.text("```js\nsay(\"Done.\")\n```"), .finish(.stop)] : scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var finished = false
                for step in steps {
                    if Task.isCancelled { break }
                    switch step {
                    case .text(let text):
                        continuation.yield(.textDelta(text))
                    case .call(let id, let name, let arguments):
                        continuation.yield(.toolCall(ToolCall(id: id, name: name, arguments: arguments)))
                    case .usage(let input, let cached, let output):
                        continuation.yield(.usage(TokenUsage(inputTokens: input, cachedInputTokens: cached, outputTokens: output)))
                    case .wait(let gate):
                        await gate.wait()
                    case .sleep(let duration):
                        try? await Task.sleep(for: duration)
                    case .hang:
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                    case .fail(let error):
                        continuation.finish(throwing: error)
                        return
                    case .finish(let reason):
                        continuation.yield(.finished(reason))
                        finished = true
                    }
                    await Task.yield()
                }
                if !finished && !Task.isCancelled { continuation.yield(.finished(.stop)) }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.lock.withLock { self?.terminations += 1 } }
                task.cancel()
            }
        }
    }
}

/// A tool for tests that counts its runs and can be slow or stuck.
final class BrainProbeTool: BrainTool, @unchecked Sendable {
    let spec: ToolSpec
    let kind: BrainToolKind
    let runningStatus: String?
    private let lock = NSLock()
    private var calls: [JSONValue] = []
    private let delay: Duration?
    private let ignoresCancellation: Bool
    private let result: JSONValue

    init(_ name: String, kind: BrainToolKind, delay: Duration? = nil, ignoresCancellation: Bool = false,
         result: JSONValue = ["status": "ok"], status: String? = nil) {
        self.spec = ToolSpec(name: name, description: "Test tool \(name).", parameters: ["type": "object", "properties": [:]])
        self.kind = kind
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
        self.result = result
        self.runningStatus = status
    }

    var runs: [JSONValue] { lock.withLock { calls } }

    func run(_ arguments: JSONValue, context: BrainToolContext) async -> JSONValue {
        lock.withLock { calls.append(arguments) }
        if let delay {
            if ignoresCancellation {
                let deadline = ContinuousClock.now + delay
                while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            } else {
                do { try await Task.sleep(for: delay) } catch { return BrainToolResults.cancelled }
            }
        }
        return result
    }
}

enum BrainFixtures {
    static let assembler = BrainPromptAssembler(drawing2D: "## Drawing\n(2D language here)", drawing3D: "(3D language here)")

    static func screenshot(width: Int = 1280, height: Int = 832, label: String = "main display", cursor: Bool = true,
                           origin: CGPoint = .zero) -> TurnScreenshot {
        TurnScreenshot(jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, UInt8(width % 251), UInt8(height % 251)]), label: label, isCursorScreen: cursor,
                       pixelSize: CGSize(width: width, height: height),
                       displayFrame: CGRect(x: origin.x, y: origin.y, width: CGFloat(width) / 2, height: CGFloat(height) / 2))
    }

    static func input(_ words: String, app: String = "Safari", screenshot: Bool = true, at date: Date = Date(timeIntervalSince1970: 1_793_361_600)) -> TurnInput {
        TurnInput(words: words, screenshots: screenshot ? [Self.screenshot()] : [],
                  context: TurnContext(localTime: date, timeZone: TimeZone(identifier: "America/Los_Angeles")!, frontApp: app,
                                       windowTitle: "Window of \(app)"))
    }

    static func runtime(_ model: BrainScriptModel, tools: [any BrainTool] = [],
                        store: BrainSessionStore? = nil, memory: BrainMemory? = nil, compactor: BrainCompactor? = nil,
                        clock: BrainClock? = nil, resume: Bool = true,
                        configure: (inout BrainRuntimeConfiguration) -> Void = { _ in }) -> BrainRuntime {
        var configuration = BrainRuntimeConfiguration(model: "test-brain", dialect: .anthropicMessages)
        configure(&configuration)
        var now: @Sendable () -> Date = { Date() }
        if let clock { now = clock.function }
        let sleep: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
        return BrainRuntime(client: model, configuration: configuration, tools: ToolRegistry(tools), assembler: assembler,
                            store: store, memory: memory, compactor: compactor, resume: resume, now: now, sleep: sleep)
    }

    /// Runs one turn and collects its events.
    static func events(_ runtime: BrainRuntime, _ input: TurnInput) async throws -> [TurnEvent] {
        var events: [TurnEvent] = []
        for try await event in runtime.run(input) { events.append(event) }
        return events
    }

    static func program(_ lines: String...) -> String { "```js\n" + lines.joined(separator: "\n") + "\n```" }

    static func summary(_ events: [TurnEvent]) -> TurnSummary? {
        for event in events { if case .finished(let summary) = event { return summary } }
        return nil
    }
}

/// A folder for session files, removed afterwards.
final class BrainTemporaryFolder: @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-brain-tests-\(UUID().uuidString)", isDirectory: true)
    deinit { try? FileManager.default.removeItem(at: url) }
    var store: BrainSessionStore { BrainSessionStore(root: url) }
}

/// A clock tests move by hand.
final class BrainClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_793_361_600)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    var function: @Sendable () -> Date { { [self] in self.now } }
}
