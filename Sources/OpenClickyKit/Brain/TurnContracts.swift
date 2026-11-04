import Foundation

// The contract between the turn orchestrator (talk keys, mic, capture, voice, drawing) and the brain runtime
// (prompt, thread, tools, model). See docs/turn-contract.md.

/// One screenshot sent with a turn.
public struct TurnScreenshot: Sendable, Hashable {
    public var jpeg: Data
    /// "main display", "display 2 (left)", …: how the prompt refers to it.
    public var label: String
    /// The display the cursor is on; drawings and pointing default to it.
    public var isCursorScreen: Bool
    public var pixelSize: CGSize
    /// The display's frame in global screen points (origin top-left of the main display, y down).
    public var displayFrame: CGRect

    public init(jpeg: Data, label: String, isCursorScreen: Bool, pixelSize: CGSize, displayFrame: CGRect) {
        self.jpeg = jpeg
        self.label = label
        self.isCursorScreen = isCursorScreen
        self.pixelSize = pixelSize
        self.displayFrame = displayFrame
    }
}

/// An on-screen element the brain can point at by id instead of by pixel.
public struct TurnElement: Sendable, Hashable {
    public var id: String
    public var role: String
    public var label: String
    /// Global screen points.
    public var frame: CGRect

    public init(id: String, role: String, label: String, frame: CGRect) {
        self.id = id
        self.role = role
        self.label = label
        self.frame = frame
    }
}

/// What the user is looking at besides pixels.
public struct TurnContext: Sendable, Hashable {
    public var localTime: Date
    public var timeZone: TimeZone
    public var frontApp: String?
    public var frontAppBundleID: String?
    public var windowTitle: String?
    /// The browser page or open document, possibly truncated.
    public var documentTitle: String?
    public var documentURL: String?
    public var documentText: String?
    public var documentTruncated: Bool
    /// Text the user has selected in the front app.
    public var selectedText: String?
    /// A region the user circled or highlighted before asking, and the text under it.
    public var highlightDescription: String?
    /// Elements of the front window, for pointing.
    public var elements: [TurnElement]
    /// What OpenClicky's own drawing currently shows (so follow-ups can edit it).
    public var drawingOnScreen: String?
    /// Why this turn started when the user didn't speak: "did_step", "clicked_target", "job_report", "tour", …
    public var trigger: String?

    public init(localTime: Date = Date(), timeZone: TimeZone = .current, frontApp: String? = nil, frontAppBundleID: String? = nil,
                windowTitle: String? = nil, documentTitle: String? = nil, documentURL: String? = nil, documentText: String? = nil,
                documentTruncated: Bool = false, selectedText: String? = nil, highlightDescription: String? = nil,
                elements: [TurnElement] = [], drawingOnScreen: String? = nil, trigger: String? = nil) {
        self.localTime = localTime
        self.timeZone = timeZone
        self.frontApp = frontApp
        self.frontAppBundleID = frontAppBundleID
        self.windowTitle = windowTitle
        self.documentTitle = documentTitle
        self.documentURL = documentURL
        self.documentText = documentText
        self.documentTruncated = documentTruncated
        self.selectedText = selectedText
        self.highlightDescription = highlightDescription
        self.elements = elements
        self.drawingOnScreen = drawingOnScreen
        self.trigger = trigger
    }
}

/// Everything the brain gets for one user turn.
public struct TurnInput: Sendable {
    /// What the user said or typed. Empty for app-initiated turns (see `context.trigger`).
    public var words: String
    public var isTyped: Bool
    public var screenshots: [TurnScreenshot]
    public var attachedImages: [ContentPart]
    public var context: TurnContext
    /// "[App] …" notes about what happened since the last turn (a drawing was cut off, an action failed, a job
    /// finished). The brain sees them before the user's words.
    public var appNotes: [String]
    /// Which screenshot is the canvas when it isn't the one under the pointer: a follow-up continues the drawing on the
    /// display it is on (index into `screenshots`). Nil: the pointer's screenshot.
    public var canvasIndex: Int?

    public init(words: String, isTyped: Bool = false, screenshots: [TurnScreenshot] = [], attachedImages: [ContentPart] = [],
                context: TurnContext = TurnContext(), appNotes: [String] = []) {
        self.words = words
        self.isTyped = isTyped
        self.screenshots = screenshots
        self.attachedImages = attachedImages
        self.context = context
        self.appNotes = appNotes
    }
}

/// An action the brain asked for that must wait until the narration has been spoken (open a link, show a result…).
public struct DeferredAction: Sendable, Hashable {
    public var callID: String
    public var name: String
    public var arguments: JSONValue

    public init(callID: String, name: String, arguments: JSONValue) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

public struct TurnSummary: Sendable, Hashable {
    /// The whole drawing program, fences stripped.
    public var program: String
    public var spokenLines: [String]
    public var rounds: Int
    public var usage: TokenUsage?
    public var model: String
    public var firstTokenSeconds: Double?
    public var totalSeconds: Double
    /// About how many bytes the first request's body was (text, tool definitions and base64 images), for timings.
    public var requestBytes: Int?

    public init(program: String, spokenLines: [String], rounds: Int, usage: TokenUsage?, model: String,
                firstTokenSeconds: Double?, totalSeconds: Double, requestBytes: Int? = nil) {
        self.requestBytes = requestBytes
        self.program = program
        self.spokenLines = spokenLines
        self.rounds = rounds
        self.usage = usage
        self.model = model
        self.firstTokenSeconds = firstTokenSeconds
        self.totalSeconds = totalSeconds
    }
}

/// What the orchestrator receives while a turn runs, in order.
public enum TurnEvent: Sendable, Hashable {
    /// A short status for the notch/cursor while tools run ("Searching the web…").
    case status(String)
    /// More drawing-program text (code fences stripped). Feed it to the drawing engine as it arrives.
    case programDelta(String)
    /// A complete say() line, ready for the voice. Same numbering the drawing engine uses.
    case sayLine(index: Int, text: String)
    case toolStarted(name: String, callID: String)
    case toolFinished(name: String, callID: String, succeeded: Bool)
    /// Run after the narration finishes (or drop if a new turn starts first).
    case deferredAction(DeferredAction)
    /// One model round finished; another follows when tools need their results read.
    case roundFinished(Int)
    case finished(TurnSummary)
    /// The turn failed; `spoken` is a short sentence the voice can say to the user.
    case failed(spoken: String, detail: String)
}

/// The brain runtime as the orchestrator sees it.
public protocol BrainTurnRunning: AnyObject, Sendable {
    /// Run one turn. Cancelling the consuming task cancels the model call and any running tools.
    func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error>
    /// Warm the provider's prompt cache at key-down so the reply starts faster at key-up (no-op if unsupported).
    func prewarm() async
    /// Report what happened to the last turn's narration/drawing, for the next turn's app notes.
    func recordOutcome(_ note: String) async
    /// End the session: write memory notes and start a fresh thread.
    func endSession() async
}
