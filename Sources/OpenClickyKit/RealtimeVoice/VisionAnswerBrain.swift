import Foundation

/// A minimal brain behind `send_to_higher_model` until the brain runtime is on main: one call on the brain slot's model
/// with the question and the screenshots, no thread, tools or drawing. Each finished sentence comes out as a say line,
/// so the realtime model can read the answer back. Any `BrainTurnRunning` (the full brain runtime) can replace it.
public final class VisionAnswerBrain: BrainTurnRunning, @unchecked Sendable {
    public let client: any LanguageModelClient
    public let model: String
    public let maxOutputTokens: Int

    public init(client: any LanguageModelClient, model: String, maxOutputTokens: Int = 500) {
        self.client = client
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    /// The brain slot's model from a config.
    public static func forBrainSlot(_ factory: EngineFactory) throws -> VisionAnswerBrain {
        VisionAnswerBrain(client: try factory.languageModel(for: .brain), model: try factory.resolve(.brain).selection.model)
    }

    static let systemPrompt = """
        OpenClicky's voice assistant forwards you the requests it can't handle well by itself, usually with an image \
        of the user's display. Study it, reason it out, and write exactly what the voice should say: two to four plain \
        sentences for listening, without markdown, bullets, URLs or code. Drawing and pointing aren't available here, \
        so if they wanted something marked on screen, describe it in words. If the image doesn't contain what they \
        asked about, say that in a sentence.
        """

    public func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream()
        let task = Task { [self] in
            let started = Date()
            var firstToken: Double?
            var splitter = SentenceSplitter()
            var lines: [String] = []
            var usage: TokenUsage?
            func emit(_ sentences: [String]) {
                for sentence in sentences {
                    continuation.yield(.sayLine(index: lines.count, text: sentence))
                    lines.append(sentence)
                }
            }
            do {
                let request = ChatRequest(model: model, messages: messages(for: input), maxOutputTokens: maxOutputTokens)
                for try await event in client.stream(request) {
                    switch event {
                    case .textDelta(let text):
                        if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                        emit(splitter.feed(text))
                    case .usage(let reported):
                        usage = reported
                    default:
                        break
                    }
                }
                emit(splitter.finish())
                continuation.yield(.roundFinished(1))
                continuation.yield(.finished(TurnSummary(program: "", spokenLines: lines, rounds: 1, usage: usage, model: model,
                                                         firstTokenSeconds: firstToken, totalSeconds: Date().timeIntervalSince(started))))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.yield(.failed(spoken: "I couldn't reach the main model just now.", detail: "\(error)"))
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func messages(for input: TurnInput) -> [ChatMessage] {
        var parts: [ContentPart] = []
        for shot in input.screenshots {
            parts.append(.text("Screenshot of the \(shot.label) (\(Int(shot.pixelSize.width))×\(Int(shot.pixelSize.height)) px):"))
            parts.append(.image(data: shot.jpeg, mimeType: "image/jpeg"))
        }
        parts += input.attachedImages
        let notes = input.appNotes.joined(separator: "\n")
        parts.append(.text((notes.isEmpty ? "" : notes + "\n\n") + input.words))
        return [.system(Self.systemPrompt), ChatMessage(role: .user, content: parts)]
    }

    public func prewarm() async {}
    public func recordOutcome(_ note: String) async {}
    public func endSession() async {}
}
