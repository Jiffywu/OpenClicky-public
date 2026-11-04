import AppKit
import OpenClickyKit
import SwiftUI

/// `OpenClicky --render-voice-snapshots <folder> [--backdrop image]`: renders the voice loop's surfaces offscreen from
/// fixed turn states (the notch pill in each phase, the listening bubble, captions, notices, a walkthrough's step pill,
/// always-on voice's pill and caption, the typed-question panel)
/// and the Voice and Talk keys settings pages with the voice loop's sections. Reads no key, asks for no permission and
/// installs no key tap.
@MainActor
enum VoiceOverlaySnapshots {
    static func run(into folder: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try renderAll(into: folder)
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }

    static func renderAll(into folder: URL) throws {
        func out(_ name: String) -> URL { folder.appendingPathComponent(name + ".png") }
        let backdrop = backdropImage()

        // The overlay over a screen: pill, bubble and caption in each phase.
        var listening = TurnDisplay()
        listening.phase = .listening
        listening.kind = .voice
        listening.liveTranscript = "what does the say hello button"
        try EvidenceSnapshots.render(screen(listening, backdrop: backdrop, mouse: CGPoint(x: 120, y: 260), level: 0.22),
                                     size: screenSize, to: out("overlay-listening"))

        var thinking = TurnDisplay()
        thinking.phase = .requesting
        thinking.kind = .voice
        thinking.words = "what does the say hello button do"
        thinking.status = "Searching the web…"
        try EvidenceSnapshots.render(screen(thinking, backdrop: backdrop), size: screenSize, to: out("overlay-thinking"))

        var speaking = TurnDisplay()
        speaking.phase = .speaking
        speaking.kind = .voice
        speaking.words = "what does the say hello button do"
        speaking.caption = "The Say hello button reads your name and favorite color from the form."
        speaking.captionIndex = 0
        speaking.lines = [speaking.caption!]
        try EvidenceSnapshots.render(screen(speaking, backdrop: backdrop), size: screenSize, to: out("overlay-speaking"))
        // Word by word, 1.6 s into the line (the words not yet heard wait faintly), with the drawing's beat chips.
        let words = CaptionWords(speaking.caption!)
        let heard = words.revealed(elapsed: 1.6, duration: 4.2)
        let beats = DrawingBeats(json: ["line": 0, "of": 2, "text": .string(speaking.caption!), "elapsed": 1.6, "length": 4.2,
                                        "chips": [["label": "callout \"Reads name and color\"", "state": "done"],
                                                  ["label": "region \"Greeting\"", "state": "drawing"],
                                                  ["label": "button \"Try it\"", "state": "waiting", "late": true]]])
        try EvidenceSnapshots.render(screen(speaking, backdrop: backdrop, revealed: heard, beats: beats), size: screenSize,
                                     to: out("overlay-caption-word-by-word"))
        speaking.usingFallbackVoice = true
        try EvidenceSnapshots.render(screen(speaking, backdrop: backdrop), size: screenSize, to: out("overlay-speaking-mac-voice"))

        var nothing = TurnDisplay()
        nothing.notice = .nothingHeard
        try EvidenceSnapshots.render(screen(nothing, backdrop: backdrop), size: screenSize, to: out("overlay-nothing-heard"))
        var dropped = TurnDisplay()
        dropped.notice = .connectionDropped()
        try EvidenceSnapshots.render(screen(dropped, backdrop: backdrop), size: screenSize, to: out("overlay-connection-dropped"))

        var timings = TurnTimings(kind: .voice)
        let start = Date()
        timings.releasedAt = start
        timings.firstLineHeardAt = start.addingTimeInterval(2.53)
        // (the numbers of the first live `occtl turn` run)
        timings.finishedAt = start.addingTimeInterval(11.04)
        try EvidenceSnapshots.render(screen(TurnDisplay(), backdrop: backdrop, timings: timings), size: screenSize, to: out("overlay-idle-timings"))

        // A walkthrough's step pill under the notch pill while the next step is prepared (the user clicked the target).
        var walkthrough = GuidedWalkthrough()
        walkthrough.setTask("Open the second page")
        let link = GuidedTarget(id: 1, label: "Go to the second page", requestedFrame: CGRect(x: 32, y: 332, width: 165, height: 20))
        _ = walkthrough.arm(link, at: 0)
        _ = walkthrough.handle(.mouseDown(link.center), at: 2)
        var following = TurnDisplay()
        following.phase = .requesting
        following.kind = .guided
        try EvidenceSnapshots.render(screen(following, backdrop: backdrop, walkthrough: walkthrough.status), size: screenSize,
                                     to: out("overlay-walkthrough-step"))

        // Always-on voice: listening, a tool at work, and the reply being spoken with its caption.
        var alwaysOn = AlwaysOnDisplay(state: .on)
        alwaysOn.voice = .listening
        let hint = TalkKeyTrigger.doubleTap(.control).tripleTapPhrase
        try EvidenceSnapshots.render(screen(TurnDisplay(), backdrop: backdrop, level: 0.12, alwaysOn: alwaysOn, alwaysOnHint: hint),
                                     size: screenSize, to: out("overlay-always-on-listening"))
        alwaysOn.voice = .thinking
        alwaysOn.userCaption = "Can you look at my screen and tell me when my appointment is?"
        alwaysOn.status = "Looking at your screen…"
        try EvidenceSnapshots.render(screen(TurnDisplay(), backdrop: backdrop, alwaysOn: alwaysOn, alwaysOnHint: hint),
                                     size: screenSize, to: out("overlay-always-on-tool"))
        alwaysOn.voice = .speaking
        alwaysOn.status = nil
        alwaysOn.assistantCaption = "Your reminder says your dentist appointment is on Thursday at 4:15 PM."
        try EvidenceSnapshots.render(screen(TurnDisplay(), backdrop: backdrop, alwaysOn: alwaysOn, alwaysOnHint: hint),
                                     size: screenSize, to: out("overlay-always-on-speaking"))

        // The typed-question panel with an answer coming in.
        let fixture = try EvidenceSnapshots.Fixture()
        let model = fixture.model
        var typed = TurnDisplay()
        typed.kind = .typed
        typed.phase = .drawing
        typed.words = "how do I change my favorite color?"
        typed.lines = ["Open the Favorite color menu next to your name.", "Pick a color, then press Say hello to update the greeting."]
        model.turn = typed
        let draft = TypedDraft()
        try EvidenceSnapshots.render(TypedTurnView(draft: draft, submit: { _ in }, close: {}).environment(model),
                                     size: NSSize(width: TypedTurnPanel.size.width, height: TypedTurnPanel.size.height), to: out("typed-panel-answer"))
        model.turn = TurnDisplay()
        draft.text = "how do I change my favorite color?"
        try EvidenceSnapshots.render(TypedTurnView(draft: draft, submit: { _ in }, close: {}).environment(model),
                                     size: NSSize(width: TypedTurnPanel.size.width, height: TypedTurnPanel.size.height), dark: true,
                                     to: out("typed-panel-dark"))

        // Settings pages with the voice loop's sections.
        let loop = VoiceLoopController(model: model, home: fixture.services, settingsURL: nil)
        model.voiceLoop = loop
        let settingsSize = NSSize(width: 860, height: 620)
        // A fixed voice list, so nothing asks a provider for one.
        fixture.services.voice.showVoices([VoiceOption(id: "EXAVITQu4vr4xnSDxMaL", name: "Sarah", detail: "Fixture voice")], note: nil)
        fixture.services.settingsPage = .voice
        try EvidenceSnapshots.render(SettingsView().environment(model).environment(fixture.services), size: settingsSize, to: out("settings-voice"))
        fixture.services.settingsPage = .talkKeys
        try EvidenceSnapshots.render(SettingsView().environment(model).environment(fixture.services), size: settingsSize, to: out("settings-talk-keys"))
        try? FileManager.default.removeItem(at: fixture.root)
    }

    static let screenSize = NSSize(width: 1200, height: 661)

    private static func screen(_ turn: TurnDisplay, backdrop: NSImage?, mouse: CGPoint? = nil, level: Float = 0,
                               timings: TurnTimings? = nil, walkthrough: GuidedStatus? = nil,
                               alwaysOn: AlwaysOnDisplay = AlwaysOnDisplay(), alwaysOnHint: String? = nil,
                               revealed: Int? = nil, beats: DrawingBeats? = nil) -> some View {
        ZStack(alignment: .topLeading) {
            if let backdrop {
                Image(nsImage: backdrop).resizable().frame(width: screenSize.width, height: screenSize.height)
            } else {
                LinearGradient(colors: [.gray.opacity(0.2), .gray.opacity(0.4)], startPoint: .top, endPoint: .bottom)
            }
            if let mouse, turn.phase == .listening {
                ListeningBubble(turn: turn, level: { level }).position(x: mouse.x + 28, y: mouse.y + 28)
            }
            if let caption = turn.caption ?? (alwaysOn.voice == .speaking ? alwaysOn.replyTail() : nil) {
                CaptionPlate(text: caption, revealed: revealed, beats: beats).position(x: screenSize.width / 2, y: screenSize.height - 96)
            }
            VStack {
                NotchPill(turn: turn, timings: timings, showsTimings: timings != nil, micLevel: { level }, notchWidth: 0,
                          alwaysOn: alwaysOn, alwaysOnKeyPhrase: alwaysOnHint)
                Spacer()
            }
            .frame(width: screenSize.width, height: screenSize.height, alignment: .top)
            if let walkthrough {
                // Where OverlayRootView puts it on a display without a notch.
                WalkthroughStep(status: walkthrough).position(x: screenSize.width / 2, y: 84)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }

    private static func backdropImage() -> NSImage? {
        guard let index = CommandLine.arguments.firstIndex(of: "--backdrop"), index + 1 < CommandLine.arguments.count else { return nil }
        return NSImage(contentsOfFile: CommandLine.arguments[index + 1])
    }
}
