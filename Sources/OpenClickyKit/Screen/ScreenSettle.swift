import CoreGraphics
import Foundation

/// A tiny 8-bit grayscale copy of the screen, used only to compare successive samples.
public struct GrayThumbnail: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must equal width × height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Draws `image` into a `width`-pixel-wide grayscale bitmap (height keeps the aspect ratio).
    public init?(image: CGImage, width: Int = CaptureSizing.settleSampleWidth) {
        let height = max(1, Int((Double(width) * Double(image.height) / Double(max(image.width, 1))).rounded()))
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: buffer)
    }

    /// The share of pixels (0…1) whose brightness moved by more than `tolerance` levels. Differently sized samples
    /// (the display changed resolution mid-way) count as entirely changed.
    public func changedFraction(comparedTo other: GrayThumbnail, tolerance: UInt8 = 12) -> Double {
        guard width == other.width, height == other.height, !pixels.isEmpty else { return 1 }
        var changed = 0
        for index in pixels.indices {
            let a = pixels[index], b = other.pixels[index]
            if (a > b ? a - b : b - a) > tolerance { changed += 1 }
        }
        return Double(changed) / Double(pixels.count)
    }
}

/// Waits briefly for the screen to stop changing before the real capture, so a window that is still animating open, a
/// page mid-scroll or a menu mid-fade isn't what the model sees.
///
/// It keeps taking tiny grayscale samples of the pointer's display; once two successive samples differ in less than
/// `threshold` of their pixels the screen counts as settled. After `maximumWait` it gives up and captures anyway.
public struct ScreenSettleSampler: Sendable {
    public struct Outcome: Sendable, Hashable {
        public var settled: Bool
        public var samples: Int
        /// The last measured change between samples (0…1).
        public var lastChange: Double
        public var elapsed: Duration
    }

    public var maximumWait: Duration
    public var interval: Duration
    public var threshold: Double
    public var tolerance: UInt8

    /// For an ordinary turn: the screen is usually still, so this costs one interval.
    public static let quick = ScreenSettleSampler(maximumWait: .milliseconds(600), interval: .milliseconds(50))
    /// After the user clicked a guided target: pages load and panels slide, so wait longer.
    public static let afterAction = ScreenSettleSampler(maximumWait: .milliseconds(1500), interval: .milliseconds(80))

    public init(maximumWait: Duration = .milliseconds(600), interval: Duration = .milliseconds(50), threshold: Double = 0.005,
                tolerance: UInt8 = 12) {
        self.maximumWait = maximumWait
        self.interval = interval
        self.threshold = threshold
        self.tolerance = tolerance
    }

    /// Samples until settled or out of time. `sample` takes one thumbnail; `now`/`sleep` are injectable for tests.
    /// A failed sample ends the wait (the real capture will report the problem).
    public func waitForSettle(
        sample: @Sendable () async throws -> GrayThumbnail,
        now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Outcome {
        let start = now()
        var previous: GrayThumbnail?
        var samples = 0
        var lastChange = 1.0
        while true {
            guard let current = try? await sample() else {
                return Outcome(settled: false, samples: samples, lastChange: lastChange, elapsed: now() - start)
            }
            samples += 1
            if let previous {
                lastChange = current.changedFraction(comparedTo: previous, tolerance: tolerance)
                if lastChange < threshold {
                    return Outcome(settled: true, samples: samples, lastChange: lastChange, elapsed: now() - start)
                }
            }
            previous = current
            if Task.isCancelled || now() - start + interval > maximumWait {
                return Outcome(settled: false, samples: samples, lastChange: lastChange, elapsed: now() - start)
            }
            await sleep(interval)
        }
    }
}
