import Foundation
@testable import OpenClickyKit

/// A language model that replies with scripted text (or fails, or stalls) and records each request.
final class RecordingLanguageModel: LanguageModelClient, @unchecked Sendable {
    enum Behavior: Sendable {
        case reply(String)
        case fail
        case stall
    }

    private let lock = NSLock()
    private var recorded: [ChatRequest] = []
    let behavior: Behavior

    init(_ behavior: Behavior) { self.behavior = behavior }

    var requests: [ChatRequest] { lock.withLock { recorded } }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.withLock { recorded.append(request) }
        let behavior = self.behavior
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch behavior {
                case .reply(let text):
                    // Arrives in pieces, like a real stream.
                    for piece in text.chunked(5) { continuation.yield(.textDelta(piece)) }
                    continuation.yield(.finished(.stop))
                    continuation.finish()
                case .fail:
                    continuation.finish(throwing: ProviderError(provider: "test", status: 500, message: "boom"))
                case .stall:
                    try? await Task.sleep(for: .seconds(30))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension String {
    func chunked(_ size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for character in self {
            current.append(character)
            if current.count == size {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// The operating system as the inserter sees it, scripted. Element values live in `values`, keyed by the element's
/// string id; Accessibility writes and pastes edit them the way a cooperative app would.
final class FakeInsertionSystem: TextInsertionSystem, @unchecked Sendable {
    enum AXWriteBehavior { case works, refused, ignored }

    let lock = NSLock()
    let fakePasteboard = InMemoryPasteboard()
    var pasteboard: any PasteboardAccess { fakePasteboard }
    var trusted = true
    var secureInput = false
    var focus: CapturedFocus?
    var frontmost: Int32?
    var electron = false
    var axSelectedTextBehavior: AXWriteBehavior = .works
    var axValueBehavior: AXWriteBehavior = .works
    var pasteWorks = true
    var typingWorks = true
    /// Field contents, by element id.
    var values: [String: String] = [:]
    /// Selection per element id (UTF-16), used for AX selected-text writes and pastes.
    var selections: [String: UTF16Range] = [:]
    private(set) var pastes: [(pid: Int32, clipboard: String?)] = []
    private(set) var typed: [String] = []
    private(set) var typedWithShiftNewlines: [Bool] = []
    private(set) var pauses: [Double] = []
    /// Runs during the pause after Command-V, e.g. to simulate the user copying something.
    var duringPastePause: (() -> Void)?

    func isAccessibilityTrusted() -> Bool { trusted }
    func isSecureEventInputEnabled() -> Bool { secureInput }
    func currentFocus() -> CapturedFocus? { focus }
    func frontmostProcessID() -> Int32? { frontmost ?? focus?.context.processID }
    func isElectron(processID: Int32) -> Bool { electron }

    func id(_ element: FocusElement) -> String { (element.raw as? String) ?? "" }

    func value(of element: FocusElement) -> String? { lock.withLock { values[id(element)] } }

    func setSelectedText(_ text: String, on element: FocusElement) -> Bool {
        switch axSelectedTextBehavior {
        case .refused: return false
        case .ignored: return true
        case .works:
            replaceSelection(of: id(element), with: text)
            return true
        }
    }

    func setValue(_ value: String, caret: Int, on element: FocusElement) -> Bool {
        switch axValueBehavior {
        case .refused: return false
        case .ignored: return true
        case .works:
            lock.withLock {
                values[id(element)] = value
                selections[id(element)] = UTF16Range(location: caret, length: 0)
            }
            return true
        }
    }

    func postPaste(to processID: Int32) -> Bool {
        let clip = fakePasteboard.string
        lock.withLock { pastes.append((processID, clip)) }
        guard pasteWorks else { return false }
        if let element = focus?.element, let clip { replaceSelection(of: id(element), with: clip) }
        return true
    }

    func type(_ text: String, to processID: Int32, shiftNewlines: Bool) -> Bool {
        lock.withLock {
            typed.append(text)
            typedWithShiftNewlines.append(shiftNewlines)
        }
        return typingWorks
    }

    func pause(seconds: Double) async {
        lock.withLock { pauses.append(seconds) }
        duringPastePause?()
    }

    private func replaceSelection(of key: String, with text: String) {
        lock.withLock {
            let value = values[key] ?? ""
            let units = Array(value.utf16)
            let selection = selections[key] ?? UTF16Range(location: units.count, length: 0)
            let start = min(selection.location, units.count)
            let end = min(selection.end, units.count)
            values[key] = UTF16Text.slice(units, 0, start) + text + UTF16Text.slice(units, end, units.count)
            selections[key] = UTF16Range(location: start + text.utf16.count, length: 0)
        }
    }
}

/// A focused field for tests: a value, a caret and an app.
func makeFocus(_ value: String = "", caret: Int? = nil, element: String = "field-1", bundleID: String? = "com.apple.TextEdit",
               appName: String? = "TextEdit", pid: Int32 = 42, role: String = "AXTextArea", subrole: String? = nil,
               site: String? = nil) -> CapturedFocus {
    let units = value.utf16.count
    let snapshot = FocusSnapshot(appName: appName, bundleID: bundleID, processID: pid, role: role, subrole: subrole,
                                 value: subrole == "AXSecureTextField" ? nil : value,
                                 selection: UTF16Range(location: caret ?? units, length: 0), characterCount: units,
                                 isValueSettable: true, isSelectedTextSettable: true,
                                 url: site.flatMap { URL(string: "https://\($0)/") })
    return CapturedFocus(context: FocusContext(snapshot: snapshot), element: FocusElement(element as NSString))
}

struct FixedFocusReader: FocusReading {
    var focus: CapturedFocus?
    func captureFocus() -> Result<CapturedFocus, FocusReadError> {
        focus.map { .success($0) } ?? .failure(.noFocusedApplication)
    }
}

/// Speech-to-text that replays a script once audio stops, and records what it was given.
final class ScriptedSpeechToText: SpeechToTextClient, @unchecked Sendable {
    let script: [TranscriptEvent]
    let lock = NSLock()
    private(set) var sessions: [ScriptedSTTSession] = []
    private(set) var keywords: [[String]] = []
    private(set) var languages: [String?] = []

    init(_ script: [TranscriptEvent]) { self.script = script }

    var inputFormat: PCMFormat { .speech16k }

    func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        let session = ScriptedSTTSession(script: script)
        lock.withLock {
            sessions.append(session)
            self.keywords.append(keywords)
            languages.append(language)
        }
        return session
    }
}

final class ScriptedSTTSession: SpeechToTextSession, @unchecked Sendable {
    let events: AsyncThrowingStream<TranscriptEvent, Error>
    private let continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    private let script: [TranscriptEvent]
    private let lock = NSLock()
    private(set) var audio = Data()
    private(set) var finished = false
    private(set) var cancelled = false

    init(script: [TranscriptEvent]) {
        self.script = script
        (events, continuation) = AsyncThrowingStream.makeStream()
        // Interim text arrives while the user speaks.
        for event in script { if case .interim = event { continuation.yield(event) } }
    }

    func send(_ pcm: Data) async { lock.withLock { audio.append(pcm) } }

    func finish() async {
        lock.withLock { finished = true }
        for event in script { if case .final = event { continuation.yield(event) } }
        continuation.finish()
    }

    func cancel() async {
        lock.withLock { cancelled = true }
        continuation.finish()
    }
}

/// A microphone that emits a few chunks and then waits for stop().
final class FakeMicrophone: DictationAudioInput, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var starts = 0
    private(set) var stops = 0
    let chunkCount: Int
    let chunkSize: Int

    init(chunks: Int = 2, chunkSize: Int = 320) {
        chunkCount = chunks
        self.chunkSize = chunkSize
    }

    func start(format: PCMFormat) async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        for index in 0..<chunkCount { continuation.yield(Data(repeating: UInt8(index % 250 + 1), count: chunkSize)) }
        lock.withLock {
            starts += 1
            self.continuation = continuation
        }
        return stream
    }

    func stop() async {
        let continuation = lock.withLock {
            stops += 1
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }
}

func temporaryDirectory(_ name: String = UUID().uuidString) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-tests-\(name)", isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    return url
}

/// Speech-to-text whose session delivers some words and then drops, or that can't connect at all.
final class FailingSpeechToText: SpeechToTextClient, @unchecked Sendable {
    let heardBeforeFailure: String?
    init(heardBeforeFailure: String?) { self.heardBeforeFailure = heardBeforeFailure }
    var inputFormat: PCMFormat { .speech16k }

    func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        guard let heard = heardBeforeFailure else { throw ProviderError(provider: "stt", message: "could not connect") }
        return DroppingSession(heard: heard)
    }

    final class DroppingSession: SpeechToTextSession, @unchecked Sendable {
        let events: AsyncThrowingStream<TranscriptEvent, Error>
        init(heard: String) {
            let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
            continuation.yield(.final(heard))
            continuation.finish(throwing: ProviderError(provider: "stt", message: "connection lost"))
            events = stream
        }
        func send(_ pcm: Data) async {}
        func finish() async {}
        func cancel() async {}
    }
}

/// The first value `stream` yields, or nil if it ends first.
func firstValue<T>(_ stream: AsyncStream<T>) async -> T? {
    for await value in stream { return value }
    return nil
}

/// Yields each time `controller` sees its streaming speech session fail or end on its own while the key is held.
/// Tests wait on it instead of sleeping and hoping the session has dropped by the time they let go.
@MainActor
func speechSessionLosses(_ controller: DictationController) -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    controller.onSpeechSessionLost = { _ in continuation.yield() }
    return stream
}

/// Yields every status `controller` shows from now on.
@MainActor
func statusChanges(_ controller: DictationController) -> AsyncStream<DictationStatus> {
    let (stream, continuation) = AsyncStream<DictationStatus>.makeStream()
    controller.onStatusChange = { continuation.yield($0) }
    return stream
}
