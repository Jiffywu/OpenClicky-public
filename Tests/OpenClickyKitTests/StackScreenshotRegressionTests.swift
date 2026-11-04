import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import OpenClickyKit

@MainActor
@Test func aContinuedDrawingUsesTheNewScreenshotForHighlightsAndInk() async throws {
    let size = CGSize(width: 800, height: 600)
    func image(_ gray: CGFloat) throws -> CGImage {
        try #require(DrawingRehearsal.paint(size: size) { context, rect in
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(rect)
        })
    }
    let light = try image(1), dark = try image(0)
    let clock = VirtualClock(CACurrentMediaTime() + 100_000)
    let canvas = DrawingDisplayCanvas(stage: FigureStage(drivesItself: false))
    canvas.clock = { clock.now }
    canvas.fixedScale = 1
    canvas.offscreen = true
    let shot = TurnScreenshot(jpeg: Data(), label: "main", isCursorScreen: true, pixelSize: size,
                              displayFrame: CGRect(origin: .zero, size: size))
    let first = try #require(canvas.drawing(for: shot, image: light, continuing: false)?.session)
    first.begin(DrawingBeginOptions(width: 800, height: 600, pace: .now))
    first.append("const card = paper(400, 300, 300, 200)\n")
    first.end()
    await first.settle()
    clock.now += 10
    await first.settle()
    #expect(await canvas.screenChanged() == 1)

    let continued = try #require(canvas.drawing(for: shot, image: dark, continuing: true))
    #expect(continued.keep && continued.session === first)
    #expect(first.painter.screen === dark)
    var options = DrawingBeginOptions(width: 800, height: 600, ink: "#121317", pace: .now)
    options.keep = true
    first.begin(options)
    first.append("text(100, 100, \"Words on the new dark page\")\nhighlight(80, 150, 240, 30)\n")
    first.end()
    await first.settle()
    let text = try #require(first.painter.entries.values.first { $0.mark.kind == "text" })
    let ink = try #require(DrawingColor(hex: try #require(text.mark.json["tone"]?.stringValue)))
    #expect(ink.luminance >= 0.225)
    #expect(first.painter.entries.values.contains { $0.mark.kind == "paper" })

    _ = canvas.drawing(for: shot, image: nil, continuing: true)
    #expect(first.painter.screen == nil)
}

@Test func homeChatJobsUseTheirOwnTurnAssetsAfterAVoiceTurn() async throws {
    let rig = ScriptedRig { session in await session.finish("Done.") }
    let box = AgentTurnAssetsBox()
    let previous = Data([1, 2, 3]), current = Data([4, 5, 6])
    box.record(AgentTurnAssets(screenshots: [previous]))
    let tools = AgentTools(manager: rig.manager, turnAssets: { box.current() })
    let model = BrainScriptModel([
        [.call("voice-job", "sessions_spawn", #"{"task":"Analyze this screen"}"#), .finish(.toolCalls)],
        [.call("home-job", "sessions_spawn", #"{"task":"Research an unrelated Home question"}"#), .finish(.toolCalls)],
    ])
    let runtime = BrainFixtures.runtime(model, tools: ToolRegistry.agentTools(tools))
    let screen = TurnScreenshot(jpeg: current, label: "main", isCursorScreen: true,
                                pixelSize: CGSize(width: 800, height: 600), displayFrame: CGRect(x: 0, y: 0, width: 800, height: 600))
    _ = try await BrainFixtures.events(runtime, TurnInput(words: "Analyze this screen", screenshots: [screen]))
    #expect(await agentEventually { rig.harness.launches.count == 1 })
    let voiceImage = try #require(rig.harness.launches.first?.images.first)
    #expect(try Data(contentsOf: voiceImage) == current)

    let chat = TypedChatController(brain: BrainRelay(runtime), history: nil)
    let result = await chat.send("Research an unrelated Home question", appNotes: [TypedChatController.homeWindowNote])
    #expect(result.outcome == .completed)
    #expect(await agentEventually { rig.harness.launches.count == 2 })
    let homeLaunch = try #require(rig.harness.launches.last)
    #expect(homeLaunch.images.isEmpty)
    #expect(!homeLaunch.message.contains("a screenshot of the user's screen"))
}
