import Foundation
@testable import OpenClickyKit

/// An in-process harness whose sessions the test drives event by event: what each launch got (instructions, MCP
/// servers, environment, images) is recorded, and `script` decides what a new session does.
final class ScriptedHarness: AgentHarness, @unchecked Sendable {
    let kind: HarnessKind
    private let lock = NSLock()
    private var _launches: [(launch: HarnessLaunch, message: String, images: [URL])] = []
    private var _sessions: [ScriptedSession] = []
    /// Runs when a session starts (after `start` returns).
    var script: @Sendable (ScriptedSession) async -> Void

    init(kind: HarnessKind = .codex, script: @escaping @Sendable (ScriptedSession) async -> Void = { _ in }) {
        self.kind = kind
        self.script = script
    }

    var launches: [(launch: HarnessLaunch, message: String, images: [URL])] { lock.withLock { _launches } }
    var sessions: [ScriptedSession] { lock.withLock { _sessions } }

    func start(_ launch: HarnessLaunch, message: String, images: [URL]) async throws -> any AgentHarnessSession {
        let session = ScriptedSession(steerable: kind == .codex)
        lock.withLock {
            _launches.append((launch, message, images))
            _sessions.append(session)
        }
        let script = self.script
        Task {
            await session.emit(.sessionStarted(threadID: "scripted-thread"))
            await session.emit(.turnStarted)
            await script(session)
        }
        return session
    }
}

actor ScriptedSession: AgentHarnessSession {
    nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    let steerable: Bool
    private(set) var sent: [String] = []
    private(set) var responses: [(String, AgentApprovalDecision)] = []
    private(set) var interrupts = 0
    private var closed = false
    /// Runs inside the next `send` (once); a non-nil result replaces the disposition it returns.
    private var onSend: (@Sendable (ScriptedSession) async -> AgentSendDisposition?)?

    var isClosed: Bool { closed }

    func setOnSend(_ hook: @escaping @Sendable (ScriptedSession) async -> AgentSendDisposition?) { onSend = hook }

    init(steerable: Bool) {
        self.steerable = steerable
        (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .unbounded)
    }

    func emit(_ event: AgentEvent) {
        guard !closed else { return }
        continuation.yield(event)
    }

    func finish(_ text: String) {
        emit(.turnFinished(.completed, finalText: text, error: nil))
    }

    func send(_ message: String) async throws -> AgentSendDisposition {
        sent.append(message)
        if let hook = onSend {
            onSend = nil
            if let disposition = await hook(self) { return disposition }
        }
        return steerable ? .steered : .queued
    }

    func interrupt() async {
        interrupts += 1
        emit(.turnFinished(.interrupted, finalText: nil, error: nil))
    }

    func respond(to requestID: String, with decision: AgentApprovalDecision) async throws {
        responses.append((requestID, decision))
        emit(.approvalResolved(id: requestID))
    }

    func close() async {
        closed = true
        continuation.finish()
    }
}

/// A labeler that answers at once (or after `delay`).
struct FakeLabeler: AgentLaunchLabeling {
    var labels: AgentLaunchLabels?
    var delay: TimeInterval = 0

    func labels(for task: String) async -> AgentLaunchLabels? {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return labels
    }
}

/// A manager over a scripted harness in a scratch folder.
struct ScriptedRig {
    let temp = AgentTempDir()
    let harness: ScriptedHarness
    let manager: AgentManager

    init(kind: HarnessKind = .codex, limits: AgentLimits = AgentLimits(), now: @escaping @Sendable () -> Date = { Date() },
         script: @escaping @Sendable (ScriptedSession) async -> Void) {
        let harness = ScriptedHarness(kind: kind, script: script)
        self.harness = harness
        manager = AgentManager(store: AgentJobStore(paths: temp.paths), harnesses: [harness], now: now) { _ in
            AgentLaunchSettings(harness: kind, model: nil, providerID: AgentLaunchSettings.loginProviderID, auth: .harnessLogin,
                                baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"], limits: limits)
        }
    }
}

/// Waits for the next report (for `jobID` when given).
func nextAgentReport(_ updates: AsyncStream<AgentManagerUpdate>, for jobID: String? = nil, timeout: Double = 10) async -> AgentJobReport? {
    await withTaskGroup(of: AgentJobReport?.self) { group in
        group.addTask {
            for await update in updates {
                if case .report(let report) = update, jobID == nil || report.jobID == jobID { return report }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

let reportText = "Found three options.\n\n<report>\nsay: I found three flights.\ntitle: Denver Flights\nfiles:\n- output/flights.md\nnext:\n- Book the cheapest one\n</report>"
