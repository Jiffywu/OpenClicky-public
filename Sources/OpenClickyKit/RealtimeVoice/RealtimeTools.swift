import Foundation

// The tools OpenClicky offers the realtime model. The descriptions are OpenClicky's own; HeyClicky's are server-side.

/// Where `capture_screen` and `send_to_higher_model` get the picture of the screen the pointer is on.
public protocol RealtimeScreenSource: Sendable {
    func captureCursorScreen() async throws -> TurnScreenshot
    /// How many displays the Mac has: the voice model's picture is smaller with several (`CaptureSizing.voiceLongEdge`).
    var displayCount: Int { get }
}

extension RealtimeScreenSource {
    public var displayCount: Int { 1 }
}

/// What `send_to_higher_model` hands the brain besides the question: the screens (the pointer's first), the context a
/// push-to-talk turn gets (front app, window, element ids, document text, selection) and notes such as the recent
/// always-on conversation.
public struct RealtimeBrainLook: Sendable {
    public var screenshots: [TurnScreenshot]
    public var context: TurnContext
    public var appNotes: [String]

    public init(screenshots: [TurnScreenshot] = [], context: TurnContext = TurnContext(), appNotes: [String] = []) {
        self.screenshots = screenshots
        self.context = context
        self.appNotes = appNotes
    }
}

/// Gathers a `RealtimeBrainLook`. The app looks the way a push-to-talk turn does (`ScreenLookService`); tests and
/// `occtl realtime` use a still picture.
public protocol RealtimeBrainLooking: Sendable {
    /// `includeScreen` false: the context and notes only, no screenshots.
    func lookForBrain(includeScreen: Bool) async -> RealtimeBrainLook
}

/// A look from a screen source alone: the pointer's screen and no other context. `notes` adds notes (the recent
/// conversation) to every look.
public struct ScreenOnlyBrainLook: RealtimeBrainLooking {
    public var screen: (any RealtimeScreenSource)?
    public var notes: @Sendable () async -> [String]

    public init(screen: (any RealtimeScreenSource)?, notes: @escaping @Sendable () async -> [String] = { [] }) {
        self.screen = screen
        self.notes = notes
    }

    public func lookForBrain(includeScreen: Bool) async -> RealtimeBrainLook {
        var look = RealtimeBrainLook(appNotes: await notes())
        if includeScreen, let screen {
            do {
                look.screenshots = [try await screen.captureCursorScreen()]
            } catch {
                look.appNotes.append("[App] There is no image of the display this time: capturing it failed.")
            }
        }
        return look
    }
}

/// A fixed look: screenshots and a context given up front (`occtl realtime --runtime`, tests). `notes` is read at each
/// look (the recent conversation).
public struct StaticRealtimeBrainLook: RealtimeBrainLooking {
    public var screenshots: [TurnScreenshot]
    public var context: TurnContext
    public var notes: @Sendable () async -> [String]

    public init(screenshots: [TurnScreenshot] = [], context: TurnContext = TurnContext(),
                notes: @escaping @Sendable () async -> [String] = { [] }) {
        self.screenshots = screenshots
        self.context = context
        self.notes = notes
    }

    public func lookForBrain(includeScreen: Bool) async -> RealtimeBrainLook {
        var context = self.context
        context.localTime = Date()
        return RealtimeBrainLook(screenshots: includeScreen ? screenshots : [], context: context, appNotes: await notes())
    }
}

/// Pictures for the realtime voice model: smaller than the brain's (768 px on the long edge with one display, 640 with
/// several) at JPEG quality 0.6, since one rides along with the conversation.
public enum RealtimeVoiceImages {
    public static func voiceSized(_ shot: TurnScreenshot, displayCount: Int) -> (data: Data, width: Int, height: Int) {
        let longEdge = CaptureSizing.voiceLongEdge(displayCount: displayCount)
        if let scaled = try? ImageCoding.rescaledJPEG(shot.jpeg, longEdge: longEdge, quality: ImageCoding.voiceJPEGQuality) {
            return scaled
        }
        return (shot.jpeg, Int(shot.pixelSize.width), Int(shot.pixelSize.height))
    }
}

/// The real screen through ScreenCaptureKit. Needs Screen Recording permission.
public struct LiveRealtimeScreenSource: RealtimeScreenSource {
    public var capturer: any ScreenCapturing
    public var exclusion: CaptureExclusion
    public var layout: @Sendable () -> DesktopLayout

    public init(capturer: any ScreenCapturing = ScreenCaptureKitCapturer(), exclusion: CaptureExclusion = .none,
                layout: @escaping @Sendable () -> DesktopLayout = { DesktopLayout.current() }) {
        self.capturer = capturer
        self.exclusion = exclusion
        self.layout = layout
    }

    public func captureCursorScreen() async throws -> TurnScreenshot {
        let captures = try await capturer.capture(ScreenCaptureOptions(displays: .cursorOnly, exclusion: exclusion))
        guard let capture = captures.cursorCapture else { throw ScreenCaptureError.noDisplays }
        return capture.turnScreenshot(in: layout())
    }

    public var displayCount: Int { max(1, layout().displays.count) }
}

/// A fixed picture: `occtl realtime --screen shot.jpg`, the simulator and tests.
public struct StaticRealtimeScreenSource: RealtimeScreenSource {
    public var screenshot: TurnScreenshot

    public init(screenshot: TurnScreenshot) { self.screenshot = screenshot }

    /// A JPEG or PNG file as the main display, scaled down to the size live captures send the model.
    public init(imageFile url: URL, longEdge: Int = CaptureSizing.modelLongEdge) throws {
        let original = try Data(contentsOf: url)
        let scaled = try ImageCoding.rescaledJPEG(original, longEdge: longEdge, quality: ImageCoding.defaultJPEGQuality)
        screenshot = TurnScreenshot(jpeg: scaled.data, label: "main display", isCursorScreen: true,
                                    pixelSize: CGSize(width: scaled.width, height: scaled.height),
                                    displayFrame: CGRect(x: 0, y: 0, width: scaled.width, height: scaled.height))
    }

    public func captureCursorScreen() async throws -> TurnScreenshot { screenshot }
}

public enum RealtimeToolName {
    public static let captureScreen = "capture_screen"
    public static let sendToHigherModel = "send_to_higher_model"
    public static let skipInterview = "skip_onboarding_interview"
}

/// The last picture `capture_screen` gave the voice model, so `send_to_higher_model` can show the brain what the voice
/// was looking at (HeyClicky sends it as `previous_screenshots`).
public final class RealtimeCaptureMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var shot: TurnScreenshot?
    private var at: Date?
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    public func remember(_ screenshot: TurnScreenshot) {
        let time = now()
        lock.withLock {
            shot = screenshot
            at = time
        }
    }

    /// The last capture and how many seconds ago it was taken.
    public var latest: (screenshot: TurnScreenshot, age: TimeInterval)? {
        let time = now()
        return lock.withLock { () -> (TurnScreenshot, TimeInterval)? in
            guard let shot, let at else { return nil }
            return (shot, max(0, time.timeIntervalSince(at)))
        }
    }

    public func forget() { lock.withLock { shot = nil; at = nil } }
}

/// What `send_to_higher_model` tells the voice model happened besides the answer (docs/re/03-screen-pointing.md §6.7),
/// so it doesn't repeat or contradict what is already on screen, typed or copied.
public struct HigherModelOutcome: Sendable, Hashable {
    /// The pointer was shown pointing at something (a `point(…)` in the drawing).
    public var cursorAnimated = false
    /// A drawing with the answer is on the user's display.
    public var visualGuidanceShown = false
    /// Text will be typed where the user's cursor is once the reply has been spoken.
    public var textTyped = false
    /// Text is being put on the clipboard after the reply.
    public var copiedToClipboard = false
    /// A background job was started (or sent a follow-up) for the request.
    public var routedToAgent = false
    /// Typing was asked for, but the focused field refuses typed text (a password field, or secure input is on).
    public var deliveryRefused = false

    public init() {}

    /// The flags as the tool result carries them.
    public var details: [String: JSONValue] {
        ["cursor_animated": .bool(cursorAnimated), "visual_guidance_shown": .bool(visualGuidanceShown), "text_typed": .bool(textTyped),
         "copied_to_clipboard": .bool(copiedToClipboard), "routed_to_agent": .bool(routedToAgent), "delivery_refused": .bool(deliveryRefused)]
    }

    /// The flags from what the brain did: its drawing program, the actions it held for after the reply, and the tools it
    /// ran (with whether each worked). `typingRefused` is whether typing into the focused field would be refused now.
    public static func derive(drew: Bool, program: String, held: [DeferredAction], toolsRan: [String: Bool],
                              typingRefused: Bool) -> HigherModelOutcome {
        var outcome = HigherModelOutcome()
        outcome.visualGuidanceShown = drew
        outcome.cursorAnimated = drew && program.range(of: #"(^|[^A-Za-z0-9_.])point\s*\("#, options: .regularExpression) != nil
        let names = Set(held.map(\.name))
        outcome.copiedToClipboard = names.contains(AppToolName.copyToClipboard)
        let typing = names.contains(InsertTextTool.name)
        outcome.textTyped = typing && !typingRefused
        outcome.deliveryRefused = typing && typingRefused
        outcome.routedToAgent = ["sessions_spawn", "sessions_send"].contains { toolsRan[$0] == true }
        return outcome
    }
}

public enum RealtimeTools {
    // MARK: - capture_screen

    public static let captureScreenSpec = ToolSpec(
        name: RealtimeToolName.captureScreen,
        description: """
            Grab a current image of the display under the user's mouse pointer. Use it when they refer to something \
            on their display ("this", "over here", "what's that say") and you don't already have an up-to-date image. \
            The image comes back with this call's result.
            """,
        parameters: ["type": "object", "properties": [:]])

    /// `capture_screen`: attaches the pointer's screen as an image the model can look at. While a drawing is playing
    /// (`isDrawing`), no picture is attached (HeyClicky skips it then too): the answer says so in words. Each picture
    /// taken is kept in `memory` for the brain.
    public static func captureScreen(_ source: any RealtimeScreenSource, memory: RealtimeCaptureMemory? = nil,
                                     isDrawing: (@Sendable () async -> Bool)? = nil) -> RealtimeTool {
        RealtimeTool(spec: captureScreenSpec, statusLabel: "Looking at your screen…", cancelsWhenSuperseded: true,
                     timeout: .seconds(10)) { _ in
            if let isDrawing, await isDrawing() {
                return .status("skipped", "A drawing is playing on the user's display right now, so no new image was taken. "
                    + "Answer from what you already know, or look again once the drawing has finished.",
                    details: ["drawing_in_progress": .bool(true)], succeeded: true)
            }
            do {
                let shot = try await source.captureCursorScreen()
                memory?.remember(shot)
                // The voice model gets a smaller picture than the brain does.
                let image = RealtimeVoiceImages.voiceSized(shot, displayCount: source.displayCount)
                var outcome = RealtimeToolOutcome.status(
                    "ok", "Here is the image of the \(shot.label). Answer from what it shows.",
                    details: ["screen": .string(shot.label), "width": .number(Double(image.width)), "height": .number(Double(image.height))],
                    succeeded: true)
                outcome.images = [RealtimeImage(data: image.data, mimeType: "image/jpeg")]
                return outcome
            } catch let error as ScreenCaptureError where error == .permissionDenied {
                return .status("unavailable", "Screen Recording permission is off for OpenClicky, so no image. Reply without "
                    + "it; if the image matters, say they can turn the permission on in System Settings.", succeeded: false)
            } catch {
                return .status("failed", "Capturing the display failed this time. Reply without the image.", succeeded: false)
            }
        }
    }

    // MARK: - send_to_higher_model

    public static let sendToHigherModelSpec = ToolSpec(
        name: RealtimeToolName.sendToHigherModel,
        description: """
            Ask OpenClicky's main model, which gets a full-resolution view of the display, thinks things through and \
            can mark up or point at things on screen. Use it whenever a quick reply of your own won't do: detailed \
            reading or explanation of the display, step-by-step help, math, code, or any request to show, circle, \
            draw or point at something. Let the user know you're on it first ("One moment, let me check"), then call \
            it. You get back the reply to speak.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "question": ["type": "string",
                             "description": "The complete request, plus anything from earlier in the chat the main model will need."],
                "include_screen": ["type": "boolean",
                                   "description": "Attach an image of the user's display (default true)."],
            ],
            "required": ["question"],
        ])

    /// `send_to_higher_model`: runs one brain turn (the brain slot, through the brain runtime) with the question and the
    /// pointer's screen, forwards its events to `observe` (so the app can play a drawing program or show statuses), and
    /// returns the spoken lines for the realtime model to say. Actions the brain held for after its narration (open a
    /// link, show a result) run once the realtime voice has said the answer, through the brain when it can perform
    /// them (`BrainRuntime` does).
    ///
    /// `look` gathers what the brain sees: in the app, every display plus the front app, window, element ids and document
    /// text, like a push-to-talk turn, and the recent always-on conversation. Without it, `screen` gives the pointer's
    /// screen alone.
    ///
    /// `memory` holds the last `capture_screen` picture: it goes to the brain as well, marked as the earlier look the
    /// voice took. `typingRefused` says whether the focused field would refuse typed text right now (a held
    /// `insert_text` is then dropped and reported as `delivery_refused`).
    public static func sendToHigherModel(brain: any BrainTurnRunning, screen: (any RealtimeScreenSource)?,
                                         look: (any RealtimeBrainLooking)? = nil, timeout: Duration = .seconds(60),
                                         observe: (@Sendable (TurnEvent) -> Void)? = nil, memory: RealtimeCaptureMemory? = nil,
                                         typingRefused: (@Sendable () async -> Bool)? = nil) -> RealtimeTool {
        let looker: any RealtimeBrainLooking = look ?? ScreenOnlyBrainLook(screen: screen)
        return RealtimeTool(spec: sendToHigherModelSpec, statusLabel: "Thinking deeper…", cancelsWhenSuperseded: true, timeout: timeout) { call in
            guard let question = call.string("question") ?? realtimeTrimmed(call.userWords) else {
                return .status("invalid_request", "Pass the user's question in `question`.", succeeded: false)
            }
            let seen = await looker.lookForBrain(includeScreen: call.bool("include_screen") ?? true)
            var context = seen.context
            context.trigger = "realtime_voice"
            var notes = ["[App] This request came from the always-on voice, which will speak your lines for you. "
                + "Write them as a few short sentences meant for listening."] + seen.appNotes
            var screenshots = seen.screenshots
            if let earlier = memory?.latest, !screenshots.contains(where: { $0.jpeg == earlier.screenshot.jpeg }) {
                screenshots.append(Self.earlierLook(earlier.screenshot, age: earlier.age))
                notes.append(seen.screenshots.isEmpty
                    ? "[App] The only screenshot is the earlier look the voice took; the screen may have changed since. Use it to "
                        + "understand the question; don't draw on it."
                    : "[App] The last screenshot is the earlier look the voice took, for reference only.")
            }
            let input = TurnInput(words: question, screenshots: screenshots, context: context, appNotes: notes)
            var lines: [String] = []
            var program = ""
            var held: [DeferredAction] = []
            var toolsRan: [String: Bool] = [:]
            // `observe` always hears how the turn ended: a drawing it started waits for `.finished` or `.failed`, so a
            // call cancelled (superseded, timed out) or broken off before either would leave that drawing held.
            var ended = false
            defer {
                if !ended, !program.isEmpty {
                    observe?(.failed(spoken: "", detail: "send_to_higher_model ended before the brain finished"))
                }
            }
            do {
                for try await event in brain.run(input) {
                    observe?(event)
                    switch event {
                    case .sayLine(_, let text): lines.append(text)
                    case .programDelta(let delta): program += delta
                    case .deferredAction(let action): held.append(action)
                    case .toolFinished(let name, _, let succeeded): toolsRan[name] = (toolsRan[name] ?? false) || succeeded
                    case .finished(let summary):
                        ended = true
                        if lines.isEmpty { lines = summary.spokenLines }
                        if program.isEmpty { program = summary.program }
                    case .failed(let spoken, _):
                        ended = true
                        return .status("failed", "The main model hit a problem. Let the user know in a few words: \(spoken)", succeeded: false)
                    default:
                        break
                    }
                }
            } catch is CancellationError {
                return .status("cancelled", "This was called off before it was done.", succeeded: false)
            } catch {
                return .status("failed", "The main model is unreachable right now. Mention that in a few words and offer another try.",
                               succeeded: false)
            }
            let answer = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
            guard !answer.isEmpty else {
                return .status("failed", "The main model came back empty. Tell the user you couldn't figure it out this time.", succeeded: false)
            }
            let drew = observe != nil && Self.programDraws(program)
            let wantsTyping = held.contains { $0.name == InsertTextTool.name }
            let refused = wantsTyping ? await typingRefused?() ?? false : false
            let flags = HigherModelOutcome.derive(drew: drew, program: program, held: held, toolsRan: toolsRan, typingRefused: refused)
            // Typing a secure field would only be refused after the reply; drop it now and say so instead.
            if refused { held.removeAll { $0.name == InsertTextTool.name } }
            var details: [String: JSONValue] = ["answer": .string(answer), "drew_on_screen": .bool(drew),
                                                "lines": .array(lines.map(JSONValue.string))]
            details.merge(flags.details) { _, new in new }
            var outcome = RealtimeToolOutcome.status("answer", Self.answerMessage(flags), details: details, succeeded: true)
            if let performer = brain as? any DeferredActionPerforming, !held.isEmpty {
                outcome.deferred = heldActions(held, performer: performer, callID: call.callID)
            }
            return outcome
        }
    }

    /// The brain's held actions as one piece of work for after the reply: run in order; a note for the conversation
    /// names the ones that didn't work.
    static func heldActions(_ actions: [DeferredAction], performer: any DeferredActionPerforming,
                            callID: String) -> RealtimeDeferredWork {
        RealtimeDeferredWork(name: actions.map(\.name).joined(separator: ","), callID: callID) {
            var failed: [String] = []
            for action in actions where !BrainToolResults.succeeded(await performer.performDeferred(action)) {
                failed.append(action.name)
            }
            return failed.isEmpty ? nil
                : "[App] After that reply, \(failed.joined(separator: ", ")) didn't work. Mention it if the user asks."
        }
    }

    /// The earlier `capture_screen` picture as a reference screenshot for the brain (never the canvas it draws on).
    static func earlierLook(_ shot: TurnScreenshot, age: TimeInterval) -> TurnScreenshot {
        var earlier = shot
        earlier.isCursorScreen = false
        earlier.label = "earlier look the voice took (\(Int(age.rounded())) s ago, \(shot.label))"
        return earlier
    }

    /// What the voice model is told to do with the answer, given what else happened.
    static func answerMessage(_ flags: HigherModelOutcome) -> String {
        var message = "Speak this answer now, keeping its meaning and adding nothing."
        var extras: [String] = []
        if flags.visualGuidanceShown {
            extras.append(flags.cursorAnimated ? "a drawing pointing at the spot is appearing on the user's display"
                : "a drawing to go with this is appearing on the user's display")
        }
        if flags.textTyped { extras.append("the text will be typed where their cursor is right after you finish") }
        if flags.copiedToClipboard { extras.append("the text goes on their clipboard right after you finish") }
        if flags.routedToAgent { extras.append("a background job has started on it") }
        if flags.deliveryRefused { extras.append("typing was refused because a password field or secure input is active, so nothing will be typed") }
        if extras.isEmpty { return message + " No need to say where it came from." }
        message += " Also: " + extras.joined(separator: "; ") + ". Mention that where it fits; don't repeat it."
        return message
    }

    /// Whether a drawing program does more than speak: any call other than `say(…)` and `step(n)`.
    static func programDraws(_ program: String) -> Bool { HistoryTurn.programDraws(program) }

    // MARK: - Memory, lookups, app tools

    /// `save_memory`, `recall_memory` and `forget_memory` on the local memory store.
    public static func memory(_ memory: MemoryTools) -> [RealtimeTool] {
        MemoryTools.specs.map { spec in
            RealtimeTool(spec: spec, statusLabel: MemoryTools.runningStatus(for: spec.name), cancelsWhenSuperseded: false,
                         timeout: .seconds(10)) { call in
                let arguments = JSONValue.object(call.arguments).jsonString()
                guard let result = memory.handle(name: spec.name, arguments: arguments) else {
                    return .status("not_implemented", succeeded: false)
                }
                return .text(result.output, succeeded: result.succeeded)
            }
        }
    }

    /// The lookups that can answer right now (web, images, places, stocks).
    public static func lookups(_ lookups: LookupTools) -> [RealtimeTool] {
        lookups.specs.map { spec in
            RealtimeTool(spec: spec, statusLabel: LookupTools.runningStatus(for: spec.name), cancelsWhenSuperseded: true,
                         timeout: .seconds(20)) { call in
                let arguments = JSONValue.object(call.arguments).jsonString()
                guard let result = await lookups.handle(name: spec.name, arguments: arguments) else {
                    return .status("not_implemented", succeeded: false)
                }
                return .text(result.output, succeeded: result.succeeded)
            }
        }
    }

    /// Local app tools. Actions that change what's on screen or audible run once the reply about them has been spoken.
    public static func appTools(_ toolbox: AppToolbox) -> [RealtimeTool] {
        toolbox.tools.map { tool in
            RealtimeTool(spec: tool.spec, statusLabel: tool.statusLabel, cancelsWhenSuperseded: tool.isReadOnly,
                         timeout: .seconds(20)) { call in
                let toolCall = ToolCall(id: call.callID, name: call.name, arguments: JSONValue.object(call.arguments).jsonString())
                switch toolbox.prepare(toolCall) {
                case .runNow:
                    let result = await toolbox.run(toolCall)
                    return RealtimeToolOutcome(output: result.json, succeeded: result.succeeded)
                case .deferUntilNarrationEnds(let action, let queued):
                    let work = RealtimeDeferredWork(name: action.name, callID: action.callID) {
                        await toolbox.run(action).appNote(toolName: action.name)
                    }
                    return RealtimeToolOutcome(output: queued.json, succeeded: true, deferred: work)
                case .finished(let result):
                    return RealtimeToolOutcome(output: result.json, succeeded: result.succeeded)
                }
            }
        }
    }

    // MARK: - Background jobs and connected apps

    /// The background-job tools (`sessions_spawn`, `session_status`, `find_jobs`, `show_result`, …) on the app's job
    /// coordinator, as for the brain. `show_result` runs once the reply about it has been heard.
    public static func agents(_ agent: AgentTools) -> [RealtimeTool] {
        let statuses: [String: String] = [
            "sessions_spawn": "Starting a job…", "sessions_send": "Sending to the job…", "sessions_interrupt": "Stopping the job…",
            "session_status": "Checking your jobs…", "find_jobs": "Looking through your jobs…", "routines": "Updating routines…",
            "show_result": "Showing the result…", "sessions_answer_request": "Passing on your answer…",
            "clicky_memory": "Checking its notes…", "clicky_artifacts": "Looking at its files…", "clicky_archive": "Updating your agents…",
            "open_artifact": "Opening the file…", "open_agent_dashboard": "Opening your agents…",
        ]
        let reads: Set<String> = ["session_status", "find_jobs", "clicky_memory", "clicky_artifacts"]
        let shownAfterReply: Set<String> = ["show_result", "open_artifact", "open_agent_dashboard"]
        return agent.specs.map { spec in
            RealtimeTool(spec: spec, statusLabel: statuses[spec.name], cancelsWhenSuperseded: reads.contains(spec.name),
                         timeout: .seconds(30)) { call in
                let arguments = JSONValue.object(call.arguments).jsonString()
                if shownAfterReply.contains(spec.name) {
                    let work = RealtimeDeferredWork(name: spec.name, callID: call.callID) {
                        let result = await agent.callJSON(name: spec.name, arguments: arguments)
                        return BrainToolResults.succeeded(result) ? nil
                            : "[App] \(spec.name == "show_result" ? "Showing that job's result" : spec.name) didn't work (\(result["status"]?.stringValue ?? "error"))."
                    }
                    return RealtimeToolOutcome(output: BrainToolResults.queued, succeeded: true, deferred: work)
                }
                let result = await agent.callJSON(name: spec.name, arguments: arguments)
                return RealtimeToolOutcome(output: result.objectValue == nil ? ["status": "ok", "result": result] : result,
                                           succeeded: BrainToolResults.succeeded(result))
            }
        }
    }

    /// `read_connected_apps`: a quick, read-only look in the user's connected apps (and Obsidian vault).
    public static func connectedApps(_ reader: ReadConnectedApps, apps: [ConnectedAppSummary]) -> RealtimeTool {
        RealtimeTool(spec: ReadConnectedApps.toolSpec(apps: apps), statusLabel: "Reading your apps…", cancelsWhenSuperseded: true,
                     timeout: .seconds(45)) { call in
            let outcome = await reader.run(arguments: JSONValue.object(call.arguments).jsonString())
            return .status(outcome.didRead ? "ok" : "error", details: ["text": .string(outcome.text)], succeeded: outcome.didRead)
        }
    }

    // MARK: - Onboarding interview

    public static let skipInterviewSpec = ToolSpec(
        name: RealtimeToolName.skipInterview,
        description: """
            Finish the welcome chat right away. For use when the user wants to leave it, however they phrase it and \
            in any language; say one warm closing remark without a question before calling it.
            """,
        parameters: ["type": "object", "properties": [:]])

    /// `skip_onboarding_interview`. `skip` returns false when no interview is running.
    public static func skipInterview(_ skip: @escaping @Sendable () async -> Bool) -> RealtimeTool {
        RealtimeTool(spec: skipInterviewSpec, statusLabel: "Skipping the interview", cancelsWhenSuperseded: false,
                     timeout: .seconds(5)) { _ in
            await skip()
                ? .status("accepted", "The welcome chat has ended. Ask nothing further.", succeeded: true)
                : .status("not_in_interview", "No welcome chat is in progress right now.", succeeded: false)
        }
    }
}

/// The tool set for one realtime session.
public struct RealtimeToolbox: Sendable {
    public var tools: [RealtimeTool]

    public init(_ tools: [RealtimeTool]) { self.tools = tools }

    /// Always-on voice's tools: look at the screen, delegate to the brain, memory, lookups and app tools. Each part is
    /// left out when its service isn't there.
    /// Background jobs and connected-app reads are offered when given, as for push-to-talk.
    ///
    /// `isDrawing` keeps `capture_screen` from taking pictures while a drawing plays; `typingRefused` tells the brain's
    /// typing apart from typing a secure field would refuse. The last `capture_screen` picture reaches the brain.
    public static func standard(screen: (any RealtimeScreenSource)?, brain: (any BrainTurnRunning)?,
                                brainLook: (any RealtimeBrainLooking)? = nil,
                                brainObserver: (@Sendable (TurnEvent) -> Void)? = nil, memory: MemoryTools? = nil,
                                lookups: LookupTools? = nil, apps: AppToolbox? = nil, agents: AgentTools? = nil,
                                connectedApps: (reader: ReadConnectedApps, apps: [ConnectedAppSummary])? = nil,
                                isDrawing: (@Sendable () async -> Bool)? = nil,
                                typingRefused: (@Sendable () async -> Bool)? = nil) -> RealtimeToolbox {
        var tools: [RealtimeTool] = []
        let captures = RealtimeCaptureMemory()
        if let screen { tools.append(RealtimeTools.captureScreen(screen, memory: captures, isDrawing: isDrawing)) }
        if let brain {
            tools.append(RealtimeTools.sendToHigherModel(brain: brain, screen: screen, look: brainLook, observe: brainObserver,
                                                         memory: captures, typingRefused: typingRefused))
        }
        if let memory { tools += RealtimeTools.memory(memory) }
        if let lookups { tools += RealtimeTools.lookups(lookups) }
        if let apps { tools += RealtimeTools.appTools(apps) }
        if let agents { tools += RealtimeTools.agents(agents) }
        if let connectedApps, connectedApps.apps.contains(where: { $0.status == .ready }) {
            tools.append(RealtimeTools.connectedApps(connectedApps.reader, apps: connectedApps.apps))
        }
        return RealtimeToolbox(tools)
    }

    public var specs: [ToolSpec] { tools.map(\.spec) }

    public func dispatcher(maxCallsPerTurn: Int = 6) -> RealtimeToolDispatcher {
        RealtimeToolDispatcher(tools: tools, maxCallsPerTurn: maxCallsPerTurn)
    }
}
