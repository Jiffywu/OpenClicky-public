import CoreGraphics
import Foundation
import QuartzCore
import OpenClickyKit

/// `occtl turn`: one whole voice turn through the real `TurnOrchestrator`, headlessly. A text transcript stands in for
/// the microphone and an image for screen capture; the brain and the voice are real (the voice is written to a WAV file,
/// never played), and the real drawing session renders a PNG frame at the start of every spoken line.
enum TurnCommands {
    static let help = """
    Usage:
      occtl turn [options] --out-dir <dir> [--text] <words…>
      occtl turn [options] --out-dir <dir> --in question.wav

    Runs one turn the way the talk keys would: key down, the words "heard" while the keys are held, key up, then the
    screenshot, the brain, the spoken lines and the drawing. Writes to <dir>:
      frame-line-N.png   the drawing as line N starts (over the screenshot); frame-final.png when it is done
      voice.wav          what the user would have heard (rendered offline in real time; nothing is played)
      timing.txt/.json   release → transcript → request → first token → first line → first audio → heard
      events.txt         every step with its time; program.js the brain's drawing program
      history/           the turn and its saved lesson (lessons/<turn>/: lesson.json, screenshot.jpg, poster.png)

    Options:
      --config c.json    the slots to use (default: your config)
      --in audio-file    speak this recording instead: the configured stt slot hears it through the voice loop's ears
                         (warm connection, fallbacks, per-press timings), played in real time as if from the mic
      --cold-ears        with --in: don't open the stt connection ahead of key-down
      --thinking summarized|hidden|off   override how the brain thinks (default: hidden on Anthropic)
      --image f.png|jpg  the screenshot of the screen under the pointer (default: a blank 1280×800 canvas)
      --points-per-pixel n   display points per screenshot pixel (0.5 for a Retina screenshot; default 1)
      --app name / --window title   the front app and window the context reports
      --typed            a typed question instead of a spoken one (--speak reads the answer aloud)
      --hold seconds     how long the keys are held (default: about as long as saying the words)
      --no-voice         answer with captions only
      --wav path         where to write the audio (default <dir>/voice.wav)
      --state dir        brain sessions (default <dir>/brain, a fresh session each run)
      --tools none|lookups|memory|apps|skills|all   tools for the brain, as occtl brain ask (default lookups,memory)
      --no-figures       tell the brain 3D figures are unavailable
      --elements f.json  the front window's controls: [{"id","role","label","frame":[x,y,w,h]}] in screenshot pixels
                         (the brain can point at them by id; guided targets snap to them)
      --highlight SHAPE  draw-to-ask: a mark drawn while the keys are held (repeatable; the same SHAPEs as
                         `occtl highlight`: circle:cx,cy,r[,ry] underline:x,y,w line:x1,y1,x2,y2 scribble:x,y,w,h, in
                         screenshot pixels). Described with on-device OCR (warmed first) and attached to the turn.
      --dwell seconds    rest at the end of each highlight mark
      --media live|off   look up the drawing's photo, place, quote and site-icon cards (default off: they stay loading)
      --click-target     if the answer armed a walkthrough target, click it afterwards: the next turn starts by itself
                         (trigger clicked_target) on the same screenshot; its files are prefixed followup-
    """

    static let turn = OcctlCommand(name: "turn", usage: "turn [--config c] [--image f] [--text words] --out-dir d  run one whole voice turn headlessly (--help)") { args in
        if args.isEmpty || args.contains("--help") || args.contains("-h") { print(help); return }
        var options = Options()
        options.parse(args)
        try await simulate(options)
    }

    struct Options {
        var config: String?
        var image: String?
        var pointsPerPixel = 1.0
        var app: String?
        var window: String?
        var typed = false
        var speak = false
        var hold: Double?
        var voice = true
        var wav: String?
        var state: String?
        var tools = "lookups,memory"
        var figures = true
        var outDir: String?
        var words: [String] = []
        var elements: String?
        var highlights: [HighlightSimulator.Shape] = []
        var dwell = 0.0
        var media = "off"
        var clickTarget = false
        var input: String?
        var coldEars = false
        var thinking: ThinkingMode?

        mutating func parse(_ args: [String]) {
            var index = 0
            func value(_ flag: String) -> String {
                index += 1
                guard index < args.count else { fail("\(flag) needs a value") }
                return args[index]
            }
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--config": config = value(arg)
                case "--image": image = value(arg)
                case "--points-per-pixel":
                    guard let parsed = Double(value(arg)), parsed > 0 else { fail("--points-per-pixel wants a number like 0.5") }
                    pointsPerPixel = parsed
                case "--app": app = value(arg)
                case "--window": window = value(arg)
                case "--typed": typed = true
                case "--speak": speak = true
                case "--hold":
                    guard let parsed = Double(value(arg)), parsed > 0 else { fail("--hold wants seconds") }
                    hold = parsed
                case "--no-voice": voice = false
                case "--wav": wav = value(arg)
                case "--state": state = value(arg)
                case "--tools": tools = value(arg)
                case "--no-figures": figures = false
                case "--out-dir": outDir = value(arg)
                case "--text": words.append(value(arg))
                case "--elements": elements = value(arg)
                case "--highlight":
                    guard let shape = HighlightSimulator.Shape(value(arg)) else { fail("--highlight wants a shape like circle:400,300,80\n\(help)") }
                    highlights.append(shape)
                case "--dwell":
                    guard let parsed = Double(value(arg)), parsed >= 0 else { fail("--dwell wants seconds") }
                    dwell = parsed
                case "--media":
                    media = value(arg)
                    guard media == "live" || media == "off" else { fail("--media is live or off") }
                case "--click-target": clickTarget = true
                case "--in": input = value(arg)
                case "--cold-ears": coldEars = true
                case "--thinking":
                    guard let mode = ThinkingMode(rawValue: value(arg)) else { fail("--thinking is summarized, hidden or off") }
                    thinking = mode
                default:
                    if arg.hasPrefix("--") { fail("Unknown option \(arg)\n\(help)") }
                    words.append(arg)
                }
                index += 1
            }
        }
    }

    @MainActor
    static func simulate(_ options: Options) async throws {
        let words = options.words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty || options.input != nil, let outPath = options.outDir else { fail(help) }
        if options.input != nil, options.typed { fail("--in is a spoken question; leave out --typed") }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Engines from the config.
        let config = try EngineCommands.loadConfig(options.config, fallback: .heyClickyLike)
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models), credentials: CoreCommands.store)
        let stateRoot = options.state.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? out.appendingPathComponent("brain", isDirectory: true)
        let runtime = try makeBrain(factory: factory, stateRoot: stateRoot, tools: options.tools, figures: options.figures,
                                    fresh: options.state == nil, thinking: options.thinking)
        let brainResolution = try factory.resolve(.brain)

        let wavURL = options.wav.map { URL(fileURLWithPath: $0) } ?? out.appendingPathComponent("voice.wav")
        let speakers = try OfflineSpeakers(url: wavURL)
        var narrator: LineNarrator?
        var voiceLabel = "none (captions only)"
        if options.voice {
            let fallback = AppleSpeechSynthesisClient(context: ProviderContext(provider: ProviderConfig(id: "apple-voices", dialect: .appleSpeechSynthesis), apiKey: nil))
            do {
                let primary = try factory.speechOutput()
                let resolution = try factory.resolve(.voice)
                voiceLabel = "\(resolution.selection.provider) / \(resolution.selection.model) via \(resolution.adapter ?? "?")"
                narrator = LineNarrator(voice: primary, fallback: fallback, player: speakers.player)
            } catch {
                voiceLabel = "Apple voice (the voice slot can't start: \(error))"
                narrator = LineNarrator(voice: fallback, fallback: nil, player: speakers.player)
            }
        }

        let imageData: Data
        if let path = options.image {
            imageData = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            imageData = StillImageScreen.blankCanvas()
        }
        var context = TurnContext(frontApp: options.app, windowTitle: options.window)
        if let path = options.elements { context.elements = try elements(path, pointsPerPixel: options.pointsPerPixel) }
        let screen = StillImageScreen(imageData: imageData, pointsPerPixel: options.pointsPerPixel, context: context)
        guard let shot = screen.screenshot, let layout = screen.layout else { fail("\(options.image ?? "the canvas") is not a readable image") }
        let geometry = CaptureGeometry(turnScreenshot: shot, layout: layout)
        let surfaces = OffscreenDrawingSurfaces()
        if options.media == "live" {
            let lookups = LookupServices.make(config: (try? ServicesConfig.load(from: ServicesConfig.defaultURL)) ?? .defaults,
                                              credentials: CoreCommands.store)
            surfaces.media = DrawingMediaResolver(lookups: LiveDrawingMediaLookups(services: lookups))
        }
        // The ears: a scripted transcript, or with --in the configured stt slot hearing a recording.
        var microphone: any TurnMicrophone = SilentMicrophone()
        var speech: any SpeechToTextClient = SimulatedSpeechToText(text: words, chunksPerWord: 8)
        var earsLabel = "simulated (the words given)"
        var recordingSeconds: Double?
        let settings = TurnOrchestrator.Settings(speaksTypedAnswers: options.speak)
        if let input = options.input {
            let ears = try VoiceEars.make(factory: factory, language: settings.language, keywords: settings.keywords)
            let pcm = try TranscribeCommands.decode(URL(fileURLWithPath: input), to: ears.inputFormat)
            let file = AudioFileMicrophone(pcm: pcm, format: ears.inputFormat)
            recordingSeconds = file.duration
            microphone = file
            speech = ears
            earsLabel = "\(ears.primary.name) via VoiceEars (\(String(format: "%.2f", file.duration)) s from \(URL(fileURLWithPath: input).lastPathComponent))"
            if !options.coldEars {
                let warm = Date()
                let ready = await ears.warmUpNow(waitUntilReady: true)
                print(String(format: "→ ears: %@ in %.2f s", ready ? "connection ready ahead of key-down" : "nothing to open ahead of key-down",
                             Date().timeIntervalSince(warm)))
            }
        }
        // Draw-to-ask and the guided walkthrough, as the app's overlay model runs them (no Accessibility here: text under
        // a mark is read with on-device OCR).
        let guide = TurnPointingGuide(drawToAsk: DrawToAskSession(harvester: HighlightHarvester(accessibility: nil)))
        if !options.highlights.isEmpty {
            guard let gesture = HighlightSimulator.gesture(options.highlights, geometry: geometry, dwellAtEnd: options.dwell) else {
                fail("No ink was drawn: --highlight strokes must move at least 8 points, slower than a quick flick.")
            }
            guide.scriptedGesture = gesture
            // The app warms the OCR model at launch; the first recognition in a fresh binary takes about half a minute.
            let warm = Date()
            if let image = TurnImages.image(from: shot.jpeg) {
                _ = await HighlightTextRecognizer(timeout: 90).lines(in: DrawingMediaImage(image), pixelRect: CGRect(x: 0, y: 0, width: 64, height: 32))
            }
            print(String(format: "→ draw-to-ask: %d mark(s); OCR warmed in %.1f s", options.highlights.count, Date().timeIntervalSince(warm)))
        }
        let services = TurnOrchestrator.Services(microphone: microphone, speechToText: { [speech] in speech }, screen: screen, brain: runtime,
                                                 narrator: narrator, drawings: surfaces, guidance: guide)
        let orchestrator = TurnOrchestrator(services: services, settings: settings)

        // Everything that happens, with its time from the start.
        let started = Date()
        var events: [String] = []
        func note(_ text: String, at date: Date = Date()) {
            let line = String(format: "%7.3fs  ", date.timeIntervalSince(started)) + text
            events.append(line)
            print(line)
        }
        var lastDisplay = TurnDisplay()
        orchestrator.onDisplayChange = { display in
            if display.phase != lastDisplay.phase { note("phase: \(display.phase.rawValue)") }
            if display.liveTranscript != lastDisplay.liveTranscript, display.phase == .listening, !display.liveTranscript.isEmpty {
                note("hearing: \(display.liveTranscript)")
            }
            if let status = display.status, status != lastDisplay.status { note("status: \(status)") }
            if let notice = display.notice, notice != lastDisplay.notice { note("notice: \(notice.title) \(notice.detail ?? "")") }
            if display.lines.count > lastDisplay.lines.count {
                for (index, line) in display.lines.enumerated().dropFirst(lastDisplay.lines.count) { note("brain line \(index): \(line)") }
            }
            lastDisplay = display
        }
        orchestrator.onLog = { note($0) }
        surfaces.onEvent = { event in
            switch event {
            case .warning(let message): note("drawing warning: \(message)")
            case .error(let message, _): note("drawing error: \(message)")
            case .request(let ref, _, let json): note("drawing asks for a \(json["kind"]?.stringValue ?? "card") (\(ref))")
            case .action(let action): note("drawing action \(action.role.rawValue): \((action.url?.absoluteString ?? action.text ?? "").prefix(80)) (not performed by occtl)")
            case .note(let kind, let text): note("drawing note \(kind): \(text)")
            case .done: note("drawing done")
            default: break
            }
        }
        var frames: [String] = []
        surfaces.media?.onResolved = { request, resolution in
            note("media \(request.kind.rawValue) \"\(request.query ?? request.symbol ?? request.host ?? "")\": \(resolution.fields["state"]?.stringValue ?? "?")")
        }
        var targetsShown = 0
        let backdrop = TurnImages.image(from: shot.jpeg)
        guide.onEffect = { effect in
            switch effect {
            case .showTarget(let target):
                let box = geometry.pixelRect(fromAppKitRect: target.frame)
                let how = target.element.map { "snapped to \($0.id) \"\($0.label ?? "")\" (\(target.snap.rawValue))" } ?? "ring at the brain's box"
                note("guided: target \"\(target.name ?? "?")\" armed at pixels [\(Int(box.minX)), \(Int(box.minY)), \(Int(box.width)), \(Int(box.height))], \(how)")
                // The ring the overlay shows, over the screenshot (far in the media future so its animations stay put).
                targetsShown += 1
                let base = CACurrentMediaTime() + 100_000
                let display = geometry.displayFrame
                let name = "target-\(targetsShown).png"
                do {
                    let image = try DrawingSnapshot.render(GuidedTargetLayer.make(for: target, display: display, begin: base), size: display.size,
                                                           at: base + 0.7, backdrop: backdrop)
                    try DrawingSnapshot.writePNG(image, to: out.appendingPathComponent(name))
                    frames.append(name)
                } catch {
                    note("\(name) failed: \(error)")
                }
            case .clearTarget: note("guided: target cleared")
            case .startTurn(let request):
                note("guided: next turn starts by itself (trigger \(request.trigger.rawValue), step \(request.step), \(request.remainingRounds) automatic step(s) left)")
                for line in request.notes { note("    note: " + line.replacingOccurrences(of: "\n", with: " / ")) }
            case .refreshCapture: note("guided: capture again (the user kept going)")
            case .ended(let reason): note("guided: walkthrough ended (\(reason.rawValue))")
            }
        }
        var heardAt: [Int: Date] = [:]
        var prefix = ""
        func render(_ name: String) {
            do {
                guard let image = try surfaces.snapshot() else { return }
                let url = out.appendingPathComponent(prefix + name)
                try DrawingSnapshot.writePNG(image, to: url)
                frames.append(prefix + name)
            } catch {
                note("frame \(prefix + name) failed: \(error)")
            }
        }
        orchestrator.onVoiceEvent = { event, at in
            switch event {
            case .lineStarted(let index, let expected):
                heardAt[index] = at
                note("heard line \(index) start" + (expected.map { String(format: " (%.2f s)", $0) } ?? ""), at: at)
                render("frame-line-\(index).png")
            case .lineFinished(let index): note("heard line \(index) end", at: at)
            case .firstAudio(let index, let delay): note(String(format: "voice: first audio of line %d, %.2f s after the line", index, delay), at: at)
            case .reopened, .fellBack, .lineFailed: break // the orchestrator's log already says these
            case .lineCut(let index, let played): note(String(format: "line %d cut after %.2f s", index, played), at: at)
            case .drained: note("voice drained", at: at)
            }
        }
        var records: [TurnRecord] = []
        orchestrator.onTurnFinished = { records.append($0) }

        print("→ brain: \(brainResolution.selection.provider) / \(brainResolution.selection.model) (thinking \(runtime.configuration.thinking?.rawValue ?? "default")); voice: \(voiceLabel)")
        print("→ ears: \(earsLabel)")
        print("→ screen: \(Int(shot.pixelSize.width))×\(Int(shot.pixelSize.height)) px\(options.image.map { " from \($0)" } ?? " blank canvas")")
        speakers.start()
        if options.typed {
            note("typed: \(words)")
            orchestrator.submitTyped(words)
        } else {
            // A recording is held for its length plus a short pause before letting go.
            let hold = options.hold ?? recordingSeconds.map { $0 + 0.4 } ?? max(1.0, Double(words.split(separator: " ").count) / 2.5 + 0.4)
            note("key down")
            orchestrator.pressBegan()
            try await Task.sleep(for: .seconds(hold))
            note("key up")
            orchestrator.pressEnded()
        }
        /// Waits for the next finished turn and lets its drawing finish what it was paced to draw.
        func awaitTurn(_ count: Int) async throws -> TurnRecord {
            let deadline = Date().addingTimeInterval(180)
            while records.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            guard records.count >= count else { fail("the turn didn't finish within 3 minutes") }
            let drawDeadline = Date().addingTimeInterval(12)
            while surfaces.session?.isDrawing == true, Date() < drawDeadline { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(700))
            await surfaces.media?.settle()
            render("frame-final.png")
            return records[count - 1]
        }
        let brainLabel = "\(brainResolution.selection.provider) / \(brainResolution.selection.model)"
        func writeReports(_ record: TurnRecord) throws -> String {
            let program = record.history?.program ?? ""
            try program.write(to: out.appendingPathComponent(prefix + "program.js"), atomically: true, encoding: .utf8)
            if let input = runtimeInput(record) { try input.write(to: out.appendingPathComponent(prefix + "context.txt"), atomically: true, encoding: .utf8) }
            let report = timingReport(record: record, heardAt: heardAt, speakers: speakers, wavURL: wavURL, frames: frames.filter { $0.hasPrefix(prefix) },
                                      voice: voiceLabel, brain: brainLabel, ears: earsLabel)
            try report.text.write(to: out.appendingPathComponent(prefix + "timing.txt"), atomically: true, encoding: .utf8)
            try (report.json.jsonString() + "\n").write(to: out.appendingPathComponent(prefix + "timing.json"), atomically: true, encoding: .utf8)
            return report.text
        }
        /// The turn's trigger and highlight, as the brain got them (screenshots and keys left out).
        func runtimeInput(_ record: TurnRecord) -> String? {
            var lines: [String] = []
            if let highlight = guide.lastHighlight, record.kind != .guided { lines.append("highlightDescription:\n" + highlight.text) }
            if record.kind == .guided { lines.append("trigger: clicked_target (a turn the walkthrough started)") }
            return lines.isEmpty ? nil : lines.joined(separator: "\n\n") + "\n"
        }

        let record = try await awaitTurn(1)
        if let highlight = guide.lastHighlight { note("draw-to-ask: attached \"\(highlight.text.prefix(160))…\"") }
        let firstReport = try writeReports(record)
        // The lesson the app keeps with "Save drawings as lessons" on, in <dir>/history/lessons/<turn>.
        if let draft = record.lesson, let history = record.history {
            let historyDir = out.appendingPathComponent("history", isDirectory: true)
            try HistoryStore(directory: historyDir).append(history)
            if let folder = try DrawingLessonRecorder.record(draft, turn: history, store: DrawingLessonStore(historyDirectory: historyDir)) {
                note("lesson saved: \(folder.path)")
            }
        }
        // What the notch would do with this reply on this Mac now: with the sound off it copies the reply and says so.
        try NotchCommands.mutedReplyReport(record, speaksTypedAnswers: options.speak)
            .write(to: out.appendingPathComponent("notch-muted-reply.txt"), atomically: true, encoding: .utf8)
        var followReport: String?
        if options.clickTarget {
            if let target = guide.guided.target {
                // The answer's walkthrough step: the user clicks the ringed control and the next turn starts by itself.
                try await Task.sleep(for: .milliseconds(700))
                prefix = "followup-"
                heardAt = [:]
                note("click on the target \"\(target.name ?? "?")\"")
                guide.guided.handle(.mouseDown(target.center))
                let follow = try await awaitTurn(2)
                followReport = try writeReports(follow)
                try await Task.sleep(for: .milliseconds(300))
            } else {
                note("--click-target: the answer armed no target")
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        try speakers.finish()
        await runtime.waitForBackgroundWork()
        try (events.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("events.txt"), atomically: true, encoding: .utf8)
        print("")
        print(firstReport)
        if let followReport {
            print("follow-up turn:")
            print(followReport)
        }
        print("wrote \(frames.count) frame(s), timing.txt/json, events.txt and program.js to \(out.path)")
    }

    /// An element list in screenshot pixels, as global points for a display of `pointsPerPixel`.
    static func elements(_ path: String, pointsPerPixel: Double) throws -> [TurnElement] {
        let json = try JSONValue.parse(String(contentsOfFile: path, encoding: .utf8))
        return (json.arrayValue ?? []).compactMap { item in
            guard let id = item["id"]?.stringValue, let frame = item["frame"]?.arrayValue?.compactMap(\.doubleValue), frame.count == 4 else { return nil }
            let scale = CGFloat(pointsPerPixel)
            return TurnElement(id: id, role: item["role"]?.stringValue ?? "element", label: item["label"]?.stringValue ?? "",
                               frame: CGRect(x: frame[0] * scale, y: frame[1] * scale, width: frame[2] * scale, height: frame[3] * scale))
        }
    }

    /// The brain as `occtl brain ask` builds it (`BrainCommands.wiring`: memory, lookups, connected apps, skills),
    /// sessions under `stateRoot`.
    static func makeBrain(factory: EngineFactory, stateRoot: URL, tools: String, figures: Bool, fresh: Bool, thinking: ThinkingMode? = nil) throws -> BrainRuntime {
        let store = BrainSessionStore(root: stateRoot)
        let wiring = BrainCommands.wiring(tools: tools, factory: factory, dialect: try factory.resolve(.brain).provider?.dialect,
                                          memoryDirectory: stateRoot.appendingPathComponent("memory", isDirectory: true),
                                          services: nil, hostedSearch: false, connectors: nil)
        return try BrainCommands.runtime(factory: factory, wiring: wiring, store: store, resume: !fresh, figures: figures, thinking: thinking)
    }

    static func timingReport(record: TurnRecord, heardAt: [Int: Date], speakers: OfflineSpeakers, wavURL: URL, frames: [String],
                             voice: String, brain: String, ears: String = "simulated") -> (text: String, json: JSONValue) {
        var lines = ["occtl turn: \(record.kind.rawValue) turn, outcome \(record.outcome.label)",
                     "brain: \(brain)", "voice: \(voice)", "ears: \(ears)", "heard: \(record.words)", "", record.timings.report(), ""]
        let narration = record.narration ?? NarrationReport()
        let spoken = record.history?.spokenLines ?? []
        lines.append("lines (\(spoken.count)):")
        var lineJSON: [JSONValue] = []
        let origin = record.timings.origin
        for (index, text) in spoken.enumerated() {
            var parts = ["  \(index): \"\(text)\""]
            var object: [String: JSONValue] = ["index": .number(Double(index)), "text": .string(text)]
            if let delay = narration.firstAudioDelays[index] {
                parts.append(String(format: "first audio %.2f s after the line", delay))
                object["first_audio_after_line_s"] = .number((delay * 100).rounded() / 100)
            }
            if let seconds = narration.audioSeconds[index] {
                parts.append(String(format: "%.2f s of audio", seconds))
                object["audio_s"] = .number((seconds * 100).rounded() / 100)
            }
            if let at = heardAt[index], let origin {
                parts.append(String(format: "heard at +%.2f s", at.timeIntervalSince(origin)))
                object["heard_at_s"] = .number((at.timeIntervalSince(origin) * 100).rounded() / 100)
            }
            if narration.fallbackLines.contains(index) {
                parts.append("Apple voice")
                object["fallback_voice"] = true
            }
            lines.append(parts.joined(separator: " · "))
            lineJSON.append(.object(object))
        }
        if !narration.resentLines.isEmpty { lines.append("resent on a reopened voice: \(narration.resentLines)") }
        if !narration.failedLines.isEmpty { lines.append("not spoken: \(narration.failedLines)") }
        if !record.deferred.isEmpty {
            lines.append("deferred actions: " + record.deferred.map { "\($0.action.name) \($0.succeeded.map { $0 ? "ran" : "failed" } ?? "dropped")" }.joined(separator: ", "))
        }
        if let failure = record.failure { lines.append("brain failure: \(failure.spoken) (\(failure.detail))") }
        if let notice = record.notice { lines.append("notice: \(notice.title)") }
        let wavSeconds = speakers.seconds
        lines.append("")
        lines.append(String(format: "voice WAV: %@, %.2f s at %d Hz, peak %.1f dBFS (%.2f s of speech audio)", wavURL.lastPathComponent, wavSeconds,
                            speakers.sampleRate, Double(AudioLevel.decibels(speakers.peakLevel)),
                            narration.audioSeconds.values.reduce(0, +)))
        if let problem = speakers.renderError { lines.append("audio render problem: \(problem)") }
        lines.append("frames: " + (frames.isEmpty ? "none" : frames.joined(separator: ", ")))
        var json: [String: JSONValue] = [
            "kind": .string(record.kind.rawValue), "outcome": .string(record.outcome.label), "words": .string(record.words),
            "brain": .string(brain), "voice": .string(voice), "ears": .string(ears), "timings": record.timings.json, "lines": .array(lineJSON),
            "wav_seconds": .number((wavSeconds * 100).rounded() / 100), "wav_sample_rate": .number(Double(speakers.sampleRate)),
            "speech_audio_seconds": .number((narration.audioSeconds.values.reduce(0, +) * 100).rounded() / 100),
            "frames": .array(frames.map { .string($0) }),
        ]
        if let usage = record.history?.usage {
            json["usage"] = ["input": .number(Double(usage.input)), "cached": .number(Double(usage.cached)), "output": .number(Double(usage.output))]
            lines.append("tokens: in \(usage.input) (cached \(usage.cached)), out \(usage.output)")
        }
        return (lines.joined(separator: "\n") + "\n", .object(json))
    }
}
