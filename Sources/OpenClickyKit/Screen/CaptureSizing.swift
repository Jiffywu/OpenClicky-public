import CoreGraphics
import Foundation

/// How big a screenshot should be. Models see detail best around a 1280-pixel long edge; much larger images cost
/// tokens without helping, and smaller ones lose small text.
public enum CaptureSizing {
    /// The default long edge for screenshots sent to the brain.
    public static let modelLongEdge = 1280
    /// Long edges used when a realtime voice model gets the picture: smaller, since it rides along every turn.
    public static let voiceLongEdgeSingle = 768
    public static let voiceLongEdgeMultiple = 640
    /// Width of the tiny grayscale samples used to tell whether the screen has stopped changing.
    public static let settleSampleWidth = 192

    /// The pixel size of a capture of a display `pointSize` points big with `scale` pixels per point, scaled so its
    /// long edge is `longEdge`. Keeps the aspect ratio, never returns a zero side, and never upscales past the
    /// panel's native pixels unless `allowUpscale` is set.
    public static func pixelSize(pointSize: CGSize, scale: Double = 1, longEdge: Int = modelLongEdge,
                                 allowUpscale: Bool = false) -> (width: Int, height: Int) {
        let width = max(Double(pointSize.width), 1)
        let height = max(Double(pointSize.height), 1)
        let nativeLong = max(width, height) * max(scale, 0.01)
        var target = Double(max(longEdge, 1))
        if !allowUpscale { target = min(target, nativeLong.rounded()) }
        if width >= height {
            return (Int(target), max(1, Int((target * height / width).rounded())))
        } else {
            return (max(1, Int((target * width / height).rounded())), Int(target))
        }
    }

    /// The size an existing image should be scaled to for a long edge, without upscaling.
    public static func downscaledSize(width: Int, height: Int, longEdge: Int) -> (width: Int, height: Int) {
        let long = max(width, height)
        guard long > longEdge, long > 0 else { return (width, height) }
        let factor = Double(longEdge) / Double(long)
        if width >= height {
            return (longEdge, max(1, Int((Double(height) * factor).rounded())))
        } else {
            return (max(1, Int((Double(width) * factor).rounded())), longEdge)
        }
    }

    /// Long edge for realtime voice images: one display gets a little more room than several.
    public static func voiceLongEdge(displayCount: Int) -> Int {
        displayCount > 1 ? voiceLongEdgeMultiple : voiceLongEdgeSingle
    }
}
