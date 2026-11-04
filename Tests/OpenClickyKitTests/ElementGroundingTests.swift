import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

// One-shot element grounding (docs/guided.md, "Grounding"): resolution choice, mapping back through the capture
// geometry on Retina and secondary displays, the computer tool reply, "no specific element", and the guided fallback.

/// A grounding model that answers from a script and records what it was shown.
private final class FakeGroundingModel: GroundingModel, @unchecked Sendable {
    let answer: GroundingAnswer
    private let lock = NSLock()
    private var seen: [(width: Int, height: Int, question: String)] = []

    init(_ answer: GroundingAnswer) { self.answer = answer }

    var calls: [(width: Int, height: Int, question: String)] { lock.withLock { seen } }

    func locate(image: DriveImage, question: String) async throws -> GroundingAnswer {
        let size = ImageCoding.pixelSize(of: image.data)
        lock.withLock { seen.append((size?.width ?? -1, size?.height ?? -1, question)) }
        return answer
    }
}

private func blankJPEG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try ImageCoding.jpegData(try #require(context.makeImage()))
}

@Suite struct ElementGroundingTests {
    @Test func theNearestComputerUseResolutionFollowsTheScreenshotsShape() {
        // MacBook panels are 16:10; external 16:9 displays; old 4:3 projectors.
        #expect(GroundingResolution.nearest(toWidth: 1512, height: 982) == .wxga)
        #expect(GroundingResolution.nearest(toWidth: 1280, height: 800) == .wxga)
        #expect(GroundingResolution.nearest(toWidth: 2560, height: 1440) == .fwxga)
        #expect(GroundingResolution.nearest(toWidth: 1920, height: 1080) == .fwxga)
        #expect(GroundingResolution.nearest(toWidth: 1024, height: 768) == .xga)
        #expect(GroundingResolution.nearest(toWidth: 1600, height: 1200) == .xga)
        // A portrait display is nearest the squarest one.
        #expect(GroundingResolution.nearest(toWidth: 1080, height: 1920) == .xga)
        #expect(GroundingResolution.nearest(toWidth: 0, height: 0) == .wxga)
    }

    @Test func aPointMapsBackOnARetinaPrimaryDisplay() {
        // A 1512 × 982 pt Retina panel captured at 1280 × 831 px (the model's long edge), primary display at the origin.
        let geometry = CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), pixelWidth: 1280, pixelHeight: 831)
        let mapping = GroundingMapping(geometry: geometry)
        #expect(mapping.resolution == .wxga)
        // The model's centre is the screenshot's centre and the display's centre.
        let center = mapping.appKitPoint(fromModel: CGPoint(x: 640, y: 400))
        #expect(abs(center.x - 756) < 0.01 && abs(center.y - 491) < 0.01)
        // Top-left of the model image → top-left of the display (AppKit y is up).
        let topLeft = mapping.appKitPoint(fromModel: .zero)
        #expect(topLeft == CGPoint(x: 0, y: 982))
        // A point in the model's pixels: (1280, 800) → (1280, 831) px → (1512, 0) pt.
        #expect(mapping.screenshotPixel(fromModel: CGPoint(x: 1280, y: 800)) == CGPoint(x: 1280, y: 831))
        #expect(mapping.appKitPoint(fromModel: CGPoint(x: 1280, y: 800)) == CGPoint(x: 1512, y: 0))
        // Past the edge is clamped to the image.
        #expect(mapping.appKitPoint(fromModel: CGPoint(x: 5000, y: -40)) == CGPoint(x: 1512, y: 982))
    }

    @Test func aPointMapsBackOnASecondaryDisplay() {
        // A 1920 × 1080 pt display to the left of the primary and raised 200 pt, captured at 1280 × 720.
        let geometry = CaptureGeometry(displayFrame: CGRect(x: -1920, y: 200, width: 1920, height: 1080), pixelWidth: 1280, pixelHeight: 720)
        let mapping = GroundingMapping(geometry: geometry)
        #expect(mapping.resolution == .fwxga)
        // (683, 384) is the middle of 1366 × 768: the display's middle.
        let middle = mapping.appKitPoint(fromModel: CGPoint(x: 683, y: 384))
        #expect(abs(middle.x - -960) < 0.01 && abs(middle.y - 740) < 0.01)
        // A control 100 px from the screenshot's left and 72 px down: model (106.7, 76.8).
        let pixel = mapping.screenshotPixel(fromModel: CGPoint(x: 106.71875, y: 76.8))
        #expect(abs(pixel.x - 100) < 0.01 && abs(pixel.y - 72) < 0.01)
        let point = mapping.appKitPoint(fromModel: CGPoint(x: 106.71875, y: 76.8))
        #expect(abs(point.x - (-1920 + 150)) < 0.01 && abs(point.y - (200 + 1080 - 108)) < 0.01)
    }

    @Test func theGrounderSendsTheResolutionAndMapsTheAnswer() async throws {
        let model = FakeGroundingModel(.point(CGPoint(x: 640, y: 400)))
        let grounder = ElementGrounder(model: model)
        let geometry = CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), pixelWidth: 1280, pixelHeight: 831)
        let result = try await grounder.locate("Click Export", screenshot: try blankJPEG(width: 1280, height: 831), geometry: geometry)
        #expect(model.calls.count == 1)
        #expect(model.calls.first?.width == 1280 && model.calls.first?.height == 800)
        #expect(model.calls.first?.question == "Click Export")
        let point = try #require(result.point)
        #expect(abs(point.x - 756) < 0.01 && abs(point.y - 491) < 0.01)
    }

    @Test func aModelWithNoElementSaysSo() async throws {
        let grounder = ElementGrounder(model: FakeGroundingModel(.noElement("no specific element")))
        let geometry = CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 800), pixelWidth: 1280, pixelHeight: 800)
        let result = try await grounder.locate("What is a gyroscope?", screenshot: try blankJPEG(width: 1280, height: 800), geometry: geometry)
        #expect(result == .noElement("no specific element"))
        #expect(result.point == nil)
    }

    @Test func anAnthropicReplyIsReadForBothToolVersions() {
        let toolset = AnthropicComputerUseReply(content: [
            ["type": "tool_use", "id": "t1", "name": "left_click", "toolset_name": "computer", "input": ["coordinate": [512, 300]]],
        ], stopReason: "tool_use", usage: nil)
        #expect(AnthropicGroundingModel.answer(from: toolset, version: .toolset) == .point(CGPoint(x: 512, y: 300)))
        let beta = AnthropicComputerUseReply(content: [
            ["type": "text", "text": "Clicking Export."],
            ["type": "tool_use", "id": "t1", "name": "computer", "input": ["action": "left_click", "coordinate": [90, 40]]],
        ], stopReason: "tool_use", usage: nil)
        #expect(AnthropicGroundingModel.answer(from: beta, version: .beta20250124) == .point(CGPoint(x: 90, y: 40)))
        // A screenshot request is not a click; plain words mean no element.
        let none = AnthropicComputerUseReply(content: [
            ["type": "tool_use", "id": "t1", "name": "screenshot", "toolset_name": "computer", "input": [:]],
            ["type": "text", "text": "no specific element"],
        ], stopReason: "end_turn", usage: nil)
        #expect(AnthropicGroundingModel.answer(from: none, version: .toolset) == .noElement("no specific element"))
    }

    @Test func theRequestCarriesTheImageQuestionAndASmallBudget() throws {
        let client = AnthropicMessagesClient(context: ProviderContext(provider: ProviderConfig(id: "anthropic", dialect: .anthropicMessages,
                                                                                               baseURL: URL(string: "https://api.anthropic.com")),
                                                                      apiKey: nil))
        let model = AnthropicGroundingModel(client: client, model: "claude-haiku-4-5")
        #expect(model.version == .beta20250124)
        let request = model.request(image: DriveImage(data: Data([1, 2, 3]), pixelWidth: 1366, pixelHeight: 768), question: "Click Save")
        #expect(request.maxTokens == 256)
        #expect(request.displayWidth == 1366 && request.displayHeight == 768)
        let body = client.computerUseBody(request)
        #expect(body["tools"]?.arrayValue?.first?["display_width_px"]?.doubleValue == 1366)
        let content = body["messages"]?.arrayValue?.first?["content"]?.arrayValue ?? []
        #expect(content.first?["type"]?.stringValue == "image")
        #expect(content.last?["text"]?.stringValue?.contains("Click Save") == true)
        #expect(body["system"]?.stringValue?.contains(AnthropicGroundingModel.noElementPhrase) == true)
    }

    @Test func theConfigChoosesTheGroundingModel() throws {
        var config = OpenClickyConfig(providers: [ProviderConfig(id: "anthropic", dialect: .anthropicMessages,
                                                                 baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic")],
                                      slots: [:])
        let store = InMemoryCredentialStore(["anthropic": "test-key"])
        let catalog = try ModelCatalog.builtIn()
        #expect(try EngineFactory(config: config, catalog: catalog, credentials: store, resilience: nil).elementGrounder() == nil)
        config.grounding = SlotSelection(provider: "anthropic", model: "claude-haiku-5-5")
        let grounder = try #require(try EngineFactory(config: config, catalog: catalog, credentials: store, resilience: nil).elementGrounder())
        #expect((grounder.model as? AnthropicGroundingModel)?.model == "claude-haiku-5-5")
        // Round-trips through the config file.
        let decoded = try JSONDecoder().decode(OpenClickyConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.grounding == config.grounding)
    }
}

/// The walkthrough's fallback: a target the brain named by an id that isn't on screen, or a box with no control at
/// it, is placed where grounding says.
@MainActor
@Suite struct GuidedGroundingTests {
    private struct Grounding: GuidedTargetGrounding {
        let result: GroundingResult?
        func locate(_ question: String, on screen: GuidedScreen) async -> GroundingResult? { result }
    }

    private func screen() -> GuidedScreen {
        let geometry = CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 800), pixelWidth: 1280, pixelHeight: 800)
        return GuidedScreen(geometry: geometry, elements: [
            ElementSnapshot(id: "e1", role: "AXButton", title: "Export", frame: geometry.appKitRect(fromPixelRect: CGRect(x: 200, y: 100, width: 120, height: 40))),
        ], screenshot: Data([0xFF]))
    }

    @Test func anUnknownElementIsGroundedAndArmed() async throws {
        var now: TimeInterval = 0
        let controller = GuidedWalkthroughController(clock: { now })
        controller.screen = screen()
        let point = CGPoint(x: 900, y: 500)
        controller.grounding = Grounding(result: .element(point: point, pixel: .zero, modelPoint: .zero, resolution: .wxga))
        controller.apply(.target(GuidedTargetRequest(.element("e99"), label: "Share")))
        #expect(controller.target == nil)
        #expect(controller.isGrounding)
        // The answer ends before grounding does: the walkthrough waits instead of calling the task done.
        controller.answerFinished()
        #expect(!controller.walkthrough.isActive || controller.walkthrough.phase != .ended(.completed))
        await controller.groundingSettled()
        let target = try #require(controller.target)
        #expect(target.contains(point))
        #expect(target.snap == .grounded)
        #expect(controller.walkthrough.phase == .armed)
        now += 1
    }

    @Test func noSpecificElementArmsNothingAndTheAnswerFinishes() async throws {
        let controller = GuidedWalkthroughController(clock: { 0 })
        controller.screen = screen()
        controller.grounding = Grounding(result: .noElement("no specific element"))
        controller.apply(.task("Share the file"))
        // Step 1 is clicked; the follow-up answer names an element that isn't there, and grounding finds none.
        controller.apply(.target(GuidedTargetRequest(.element("e1"), label: "Export")))
        let e1 = try #require(controller.target)
        controller.handle(.mouseDown(e1.center))
        #expect(controller.walkthrough.phase == .followingUp)
        controller.apply(.target(GuidedTargetRequest(.element("e99"), label: "Share")))
        controller.answerFinished()
        #expect(controller.walkthrough.phase == .followingUp)
        await controller.groundingSettled()
        #expect(controller.target == nil)
        #expect(controller.walkthrough.phase == .ended(.completed))
    }

    @Test func anUnsnappedBoxMovesOnlyWhenGroundingDisagrees() async throws {
        let controller = GuidedWalkthroughController(clock: { 0 })
        controller.screen = screen()
        let far = CGPoint(x: 1100, y: 200)
        controller.grounding = Grounding(result: .element(point: far, pixel: .zero, modelPoint: .zero, resolution: .wxga))
        // A box in empty space, nowhere near e1: armed at the brain's box first, then moved.
        controller.apply(.target(GuidedTargetRequest(.pixelRect(CGRect(x: 600, y: 600, width: 40, height: 20)), label: "Share")))
        let first = try #require(controller.target)
        #expect(first.snap == .none)
        await controller.groundingSettled()
        let moved = try #require(controller.target)
        #expect(moved.id != first.id)
        #expect(moved.contains(far))

        let agreeing = GuidedWalkthroughController(clock: { 0 })
        agreeing.screen = screen()
        let inside = agreeing.screen!.geometry.appKitPoint(fromPixel: CGPoint(x: 620, y: 610))
        agreeing.grounding = Grounding(result: .element(point: inside, pixel: .zero, modelPoint: .zero, resolution: .wxga))
        agreeing.apply(.target(GuidedTargetRequest(.pixelRect(CGRect(x: 600, y: 600, width: 40, height: 20)), label: "Share")))
        let kept = try #require(agreeing.target)
        await agreeing.groundingSettled()
        #expect(agreeing.target?.id == kept.id)
    }

    @Test func aSnappedTargetIsNotGroundedAndAUserTurnDropsGrounding() async throws {
        let controller = GuidedWalkthroughController(clock: { 0 })
        controller.screen = screen()
        controller.grounding = Grounding(result: .element(point: CGPoint(x: 5, y: 5), pixel: .zero, modelPoint: .zero, resolution: .wxga))
        controller.apply(.target(GuidedTargetRequest(.element("e1"), label: "Export")))
        #expect(!controller.isGrounding)

        let dropped = GuidedWalkthroughController(clock: { 0 })
        dropped.screen = screen()
        dropped.grounding = Grounding(result: .element(point: CGPoint(x: 900, y: 500), pixel: .zero, modelPoint: .zero, resolution: .wxga))
        dropped.apply(.target(GuidedTargetRequest(.element("e99"), label: "Share")))
        dropped.userTurnStarted()
        await dropped.groundingSettled()
        #expect(dropped.target == nil)
    }

    @Test func aLaterWalkthroughCanStartFromAGroundedTarget() async throws {
        let controller = GuidedWalkthroughController(clock: { 0 })
        controller.screen = screen()
        let point = CGPoint(x: 900, y: 500)
        controller.grounding = Grounding(result: .element(point: point, pixel: .zero, modelPoint: .zero, resolution: .wxga))
        // A first walkthrough runs and is stopped.
        controller.apply(.target(GuidedTargetRequest(.element("e1"), label: "Export")))
        controller.stop()
        #expect(controller.walkthrough.phase == .ended(.stopped))
        // The next answer opens with a target only grounding can place: it starts a new walkthrough.
        controller.apply(.target(GuidedTargetRequest(.element("e99"), label: "Share")))
        await controller.groundingSettled()
        let target = try #require(controller.target)
        #expect(target.contains(point))
        #expect(controller.walkthrough.phase == .armed)
    }

    @Test func aWalkthroughThatEndsWhileGroundingIsOutDropsTheAnswer() async throws {
        let gate = GroundingGate(result: .element(point: CGPoint(x: 900, y: 500), pixel: .zero, modelPoint: .zero, resolution: .wxga))
        var now: TimeInterval = 0
        let controller = GuidedWalkthroughController(settings: .init(), clock: { now })
        controller.screen = screen()
        controller.grounding = gate
        controller.apply(.task("Share the file"))
        controller.apply(.target(GuidedTargetRequest(.element("e1"), label: "Export")))
        let e1 = try #require(controller.target)
        controller.handle(.mouseDown(e1.center))
        controller.apply(.target(GuidedTargetRequest(.element("e99"), label: "Share")))
        await gate.waitUntilAsked()
        // The follow-up runs out while the model is still looking.
        now += 600
        controller.tick()
        #expect(!controller.walkthrough.isActive)
        gate.release()
        await controller.groundingAnswersHandled(1)
        #expect(controller.target == nil)
        #expect(!controller.walkthrough.isActive)
    }

    @Test func escapeBeforeTheFirstGroundedTargetKeepsTheBuddyAway() async throws {
        let gate = GroundingGate(result: .element(point: CGPoint(x: 900, y: 500), pixel: .zero, modelPoint: .zero, resolution: .wxga))
        let controller = GuidedWalkthroughController(clock: { 0 })
        let guide = TurnPointingGuide(guided: controller, clock: { 0 })
        let pointer = RecordingBuddyPointer()
        guide.buddy.pointer = pointer
        controller.screen = screen()
        controller.grounding = gate
        controller.apply(.target(GuidedTargetRequest(.element("e99"), label: "Share")))
        #expect(controller.isGrounding)
        #expect(!controller.walkthrough.isActive)
        await gate.waitUntilAsked()
        // Escape arrives before the model answers: nothing is active yet, but the grounding is dropped.
        #expect(guide.stopWalkthrough() == false)
        #expect(!controller.isGrounding)
        gate.release()
        await controller.groundingAnswersHandled(1)
        #expect(controller.target == nil)
        #expect(pointer.flights.isEmpty)
    }

    @Test func aTargetPastTheRoundLimitIsNotGroundedBackToLife() async throws {
        var settings = GuidedWalkthrough.Settings()
        settings.maxRounds = 1
        let controller = GuidedWalkthroughController(settings: settings, clock: { 0 })
        controller.screen = screen()
        controller.grounding = Grounding(result: .element(point: CGPoint(x: 900, y: 500), pixel: .zero, modelPoint: .zero, resolution: .wxga))
        controller.apply(.task("Share the file"))
        controller.apply(.target(GuidedTargetRequest(.element("e1"), label: "Export")))
        let e1 = try #require(controller.target)
        controller.handle(.mouseDown(e1.center))
        #expect(controller.walkthrough.remainingRounds == 0)
        // The last round's answer arms an unsnapped box: the walkthrough ends there, and nothing is grounded.
        controller.apply(.target(GuidedTargetRequest(.pixelRect(CGRect(x: 600, y: 600, width: 40, height: 20)), label: "Share")))
        #expect(controller.walkthrough.phase == .ended(.maxRounds))
        #expect(!controller.isGrounding)
        await controller.groundingSettled()
        #expect(controller.target == nil)
        #expect(controller.walkthrough.phase == .ended(.maxRounds))
    }

    @Test func aBrushedTalkKeyWhileTheNextStepIsGroundedAsksAgain() async throws {
        let controller = GuidedWalkthroughController(clock: { 0 })
        controller.screen = screen()
        let point = CGPoint(x: 900, y: 500)
        controller.grounding = Grounding(result: .element(point: point, pixel: .zero, modelPoint: .zero, resolution: .wxga))
        controller.apply(.task("Share the file"))
        controller.apply(.target(GuidedTargetRequest(.element("e1"), label: "Export")))
        let e1 = try #require(controller.target)
        controller.handle(.mouseDown(e1.center))
        // Step 2's answer names an element the list doesn't have and finishes while grounding is out.
        controller.apply(.target(GuidedTargetRequest(.element("e99"), label: "Share")))
        controller.answerFinished()
        // The talk key is only brushed: the press comes to nothing.
        controller.userTurnStarted()
        #expect(!controller.isGrounding)
        controller.userTurnCancelled()
        #expect(controller.isGrounding)
        await controller.groundingSettled()
        let target = try #require(controller.target)
        #expect(target.contains(point))
        #expect(controller.walkthrough.phase == .armed)
    }

    @Test func aBrushedTalkKeyStillFinishesAnAnswerWithNoPlaceableStep() async throws {
        let controller = GuidedWalkthroughController(clock: { 0 })
        controller.screen = screen()
        controller.grounding = Grounding(result: .noElement("no specific element"))
        controller.apply(.task("Share the file"))
        controller.apply(.target(GuidedTargetRequest(.element("e1"), label: "Export")))
        let e1 = try #require(controller.target)
        controller.handle(.mouseDown(e1.center))
        controller.apply(.target(GuidedTargetRequest(.element("e99"), label: "Share")))
        controller.answerFinished()
        controller.userTurnStarted()
        controller.userTurnCancelled()
        await controller.groundingSettled()
        // Grounding found nothing the second time too: the held answer finishes the walkthrough at once.
        #expect(controller.target == nil)
        #expect(controller.walkthrough.phase == .ended(.completed))
    }
}

/// A grounding model that answers only when the test lets it.
@MainActor
private final class GroundingGate: GuidedTargetGrounding {
    let result: GroundingResult?
    private var asked: CheckedContinuation<Void, Never>?
    private var wasAsked = false
    private var answer: CheckedContinuation<Void, Never>?
    private var released = false

    init(result: GroundingResult?) { self.result = result }

    nonisolated func locate(_ question: String, on screen: GuidedScreen) async -> GroundingResult? {
        await waitForRelease()
    }

    private func waitForRelease() async -> GroundingResult? {
        wasAsked = true
        asked?.resume()
        asked = nil
        if !released { await withCheckedContinuation { answer = $0 } }
        return result
    }

    func waitUntilAsked() async {
        if wasAsked { return }
        await withCheckedContinuation { asked = $0 }
    }

    func release() {
        released = true
        answer?.resume()
        answer = nil
    }
}
