import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders a figure from its marks to an image, offscreen and synchronously: builds every part's mesh, settles the
/// growth animations, runs ticks once, renders with Metal and draws labels and readouts on top.
public enum FigureSnapshot {
    public struct Options {
        /// Use this look instead of the one the program chose.
        public var look: FigureLook?
        /// Turntable yaw in degrees (0 = front); nil uses the figure's own starting `turn`.
        public var angle: Float?
        /// Seconds of motion after everything has been drawn (spins, ticks).
        public var time: Double = 0
        /// Pixels per point.
        public var scale: CGFloat = 2
        /// Size of the image in points; nil uses the figure's rectangle.
        public var size: CGSize?
        /// sRGB background with alpha; nil leaves it transparent.
        public var background: SIMD4<Float>? = Options.paper
        public var figureID: String?
        public var drawsLabels = true

        public static let paper: SIMD4<Float> = [0.968, 0.957, 0.929, 1]

        public init() {}
    }

    public struct Result {
        public var image: CGImage
        public var scene: FigureScene
        public var frame: FigureFrame
        /// Parts whose mesh failed to build, with the reason.
        public var failures: [String: String]
    }

    /// - Parameter tick: runs the figure's ticks (figure id, [(tick id, seconds)], dt) and returns packed poses.
    public static func render(marks: [DrawingMark], options: Options = Options(), kernel: FigureKernel = .shared,
                              renderer: FigureRenderer? = nil,
                              tick: ((String, [(String, Double)], Double) -> [Float])? = nil,
                              readouts: (() -> [String: [String: String]])? = nil) throws -> Result {
        guard let figureMark = marks.first(where: { $0.kind == "figure" && (options.figureID == nil || $0.id == options.figureID) }) else {
            throw FigureRendererError.resources("no figure() in the program")
        }
        let scene = FigureScene(mark: figureMark, at: 0)
        if let look = options.look { scene.setLook(look) }
        var failures: [String: String] = [:]
        var settle = 0.0
        for mark in marks where mark.isFigureMark && mark.kind != "figure" && mark.json["figure"]?.stringValue == scene.id {
            // Offscreen, everything starts at once; motions then run for `time` seconds after the build settles.
            if let node = scene.apply(mark, at: 0), let recipe = node.recipe {
                do { node.mesh = try kernel.meshNow(kind: node.kind, recipe: recipe) } catch {
                    failures[node.id] = "\(error)"
                    node.meshError = "\(error)"
                }
            }
            settle = max(settle, mark.duration)
        }
        let time = settle + 0.05 + max(0, options.time)
        if let tick, !scene.ticks.isEmpty {
            let poses = tick(scene.id, scene.ticks.map { ($0.id, time - $0.start) }, 1.0 / 60)
            scene.applyTickPoses(poses)
            if let values = readouts?()[scene.id] { scene.applyReadouts(values) }
        }
        let size = options.size ?? scene.rect.size
        let frame = scene.frame(at: time, viewport: size, yawOverride: options.angle ?? scene.camera(at: time).turn)
        let renderer = try renderer ?? FigureRenderer()
        let figure = try renderer.renderImage(frame, scale: options.scale)
        let image = try compose(figure, frame: frame, scene: scene, time: time, options: options)
        return Result(image: image, scene: scene, frame: frame, failures: failures)
    }

    /// Background, figure and labels in one image.
    static func compose(_ figure: CGImage, frame: FigureFrame, scene: FigureScene, time: Double, options: Options) throws -> CGImage {
        let width = figure.width, height = figure.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FigureRendererError.resources("bitmap context")
        }
        if let background = options.background {
            context.setFillColor(CGColor(srgbRed: CGFloat(background.x), green: CGFloat(background.y), blue: CGFloat(background.z), alpha: CGFloat(background.w)))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.draw(figure, in: CGRect(x: 0, y: 0, width: width, height: height))
        if options.drawsLabels {
            // Labels are laid out in points with a top-left origin.
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(height))
            // The scale the figure was really drawn at (very large figures are drawn at a lower one).
            let scale = FigureRenderer.effectiveScale(for: frame.viewport, scale: options.scale)
            context.scaleBy(x: scale, y: -scale)
            let ink = CGColor(srgbRed: CGFloat(frame.ink.x), green: CGFloat(frame.ink.y), blue: CGFloat(frame.ink.z), alpha: 1)
            let halo: CGColor? = options.background == nil ? CGColor(gray: 1, alpha: 0.85) : nil
            let placements = FigureLabelLayout.layout(scene.labels, frame: frame, time: time + 10)
            FigureLabelLayout.draw(placements, readouts: scene.readouts, ink: ink, halo: halo ?? CGColor(gray: 1, alpha: 0.7), in: context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw FigureRendererError.resources("compose") }
        return image
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
