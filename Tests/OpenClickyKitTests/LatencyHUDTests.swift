import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

/// Request body size in the turn timings and the floating latency stats content (#32).
@Suite struct LatencyHUDTests {
    @Test func turnTimingsCarryTheRequestBodySize() throws {
        var timings = TurnTimings(kind: .voice)
        timings.requestBodyBytes = 412_345
        #expect(timings.json["request_body_bytes"] == .number(412_345))
        #expect(timings.report().contains("request body: about 412 KB"))
        timings.requestBodyBytes = 2_400_000
        #expect(timings.report().contains("request body: about 2.4 MB"))
        timings.requestBodyBytes = nil
        #expect(timings.json["request_body_bytes"] == nil)
    }

    @Test func theBodySizeCountsTextToolsAndImagesAsBase64() {
        let image = Data(count: 3_000)
        let request = ChatRequest(model: "m", messages: [.system("abc"), .user(.text("hello"), .image(data: image, mimeType: "image/jpeg"))],
                                  tools: [ToolSpec(name: "t", description: "d", parameters: ["type": "object"])])
        let expected = 1 + 3 + 5 + 4_000 + 1 + 1 + JSONValue.object(["type": "object"]).jsonString().utf8.count
        #expect(request.approximateBodyBytes == expected)
    }

    @Test func theBrainReportsItsFirstRequestSizeAndTheTimingsKeepIt() async throws {
        let model = BrainScriptModel([[.text(BrainFixtures.program("say(\"Hi.\")")), .finish(.stop)]])
        let runtime = BrainFixtures.runtime(model)
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("hello"))
        let summary = try #require(BrainFixtures.summary(events))
        let first = try #require(model.requests.first)
        #expect(summary.requestBytes == first.approximateBodyBytes)
        #expect((summary.requestBytes ?? 0) > 1_000)  // the system prompt alone is bigger than that
    }

    @Test func theHUDWithoutATurnOrSession() {
        let empty = LatencyHUDContent.make(timings: nil, stats: nil)
        #expect(empty.title == "Latency" && empty.footer == nil)
        var typed = TurnTimings(kind: .typed)
        let start = Date()
        typed.sentAt = start
        typed.firstLineHeardAt = start.addingTimeInterval(0.9)
        typed.usage = TokenUsage(inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 10)
        let content = LatencyHUDContent.make(timings: typed, stats: nil)
        #expect(content.rows.contains(LatencyHUDContent.Row("sent → first line heard", "900 ms", emphasized: true)))
        #expect(content.rows.contains { $0.label == "cache" && $0.value.hasPrefix("miss") })
        #expect(FeatureFlag.all.contains(.latencyHUD))
        #expect(FeatureFlag.latencyHUD.group == .developer && !FeatureFlag.latencyHUD.defaultValue)
    }
}
