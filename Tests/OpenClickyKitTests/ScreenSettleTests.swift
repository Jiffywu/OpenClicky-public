import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

/// A fake clock that only moves when the sampler sleeps, plus a scripted list of thumbnails.
private final class ScriptedSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [GrayThumbnail?]
    private var offset: Duration = .zero
    private let base = ContinuousClock.now
    private(set) var taken = 0

    init(_ frames: [GrayThumbnail?]) { self.frames = frames }

    func next() throws -> GrayThumbnail {
        try lock.withLock {
            taken += 1
            let frame = frames.count > 1 ? frames.removeFirst() : frames.first ?? nil
            guard let frame else { throw ImageCoding.Failure.decodeFailed }
            return frame
        }
    }

    func now() -> ContinuousClock.Instant { lock.withLock { base + offset } }
    func sleep(_ duration: Duration) { lock.withLock { offset += duration } }
}

private func flat(_ value: UInt8, changed: Int = 0, size: Int = 100) -> GrayThumbnail {
    var pixels = [UInt8](repeating: value, count: size)
    for index in 0..<changed { pixels[index] = value &+ 100 }
    return GrayThumbnail(width: 10, height: size / 10, pixels: pixels)
}

@Suite("Screen settle")
struct ScreenSettleTests {
    @Test func changedFractionCountsPixelsPastTheTolerance() {
        let a = flat(50)
        #expect(a.changedFraction(comparedTo: a) == 0)
        #expect(a.changedFraction(comparedTo: flat(50, changed: 7)) == 0.07)
        // Small brightness drift (video noise, cursor blink anti-aliasing) doesn't count.
        #expect(a.changedFraction(comparedTo: flat(58)) == 0)
        #expect(a.changedFraction(comparedTo: flat(80)) == 1)
        // A different size (resolution change) counts as entirely changed.
        #expect(a.changedFraction(comparedTo: GrayThumbnail(width: 5, height: 1, pixels: [0, 0, 0, 0, 0])) == 1)
    }

    @Test func thumbnailsComeFromImages() throws {
        let image = makeTestImage(width: 1280, height: 800)
        let thumbnail = try #require(GrayThumbnail(image: image))
        #expect(thumbnail.width == 192 && thumbnail.height == 120)
        let other = try #require(GrayThumbnail(image: makeTestImage(width: 1280, height: 800, block: CGRect(x: 0, y: 0, width: 640, height: 800))))
        #expect(thumbnail.changedFraction(comparedTo: other) > 0.3)
    }

    @Test func settlesOnceTwoSamplesMatch() async {
        let script = ScriptedSamples([flat(10), flat(10, changed: 30), flat(10, changed: 30)])
        let sampler = ScreenSettleSampler(maximumWait: .milliseconds(600), interval: .milliseconds(50))
        let outcome = await sampler.waitForSettle(sample: { try script.next() }, now: { script.now() }, sleep: { script.sleep($0) })
        #expect(outcome.settled)
        #expect(outcome.samples == 3)
        #expect(outcome.lastChange == 0)
        #expect(outcome.elapsed == .milliseconds(100))
    }

    @Test func givesUpAtTheCapWhenTheScreenKeepsChanging() async {
        let frames = (0..<200).map { flat(UInt8($0 % 2 == 0 ? 10 : 200)) }
        let script = ScriptedSamples(frames)
        let sampler = ScreenSettleSampler(maximumWait: .milliseconds(1500), interval: .milliseconds(80))
        let outcome = await sampler.waitForSettle(sample: { try script.next() }, now: { script.now() }, sleep: { script.sleep($0) })
        #expect(!outcome.settled)
        #expect(outcome.elapsed <= .milliseconds(1500))
        #expect(outcome.samples == 19)
        #expect(outcome.lastChange == 1)
    }

    @Test func belowThresholdChangeCountsAsSettled() async {
        // 0.3% of pixels changed (a blinking caret): under the 0.5% threshold.
        let a = GrayThumbnail(width: 100, height: 10, pixels: [UInt8](repeating: 9, count: 1000))
        var pixels = a.pixels
        for index in 0..<3 { pixels[index] = 250 }
        let b = GrayThumbnail(width: 100, height: 10, pixels: pixels)
        let script = ScriptedSamples([a, b])
        let outcome = await ScreenSettleSampler.quick.waitForSettle(sample: { try script.next() }, now: { script.now() }, sleep: { script.sleep($0) })
        #expect(outcome.settled)
        #expect(outcome.samples == 2)
    }

    @Test func aFailedSampleEndsTheWait() async {
        let script = ScriptedSamples([flat(1), nil])
        let outcome = await ScreenSettleSampler.quick.waitForSettle(sample: { try script.next() }, now: { script.now() }, sleep: { script.sleep($0) })
        #expect(!outcome.settled)
        #expect(outcome.samples == 1)
    }
}
