import CoreGraphics
import Foundation
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers

/// Renders a layer tree offscreen at a chosen moment, animations included, for tests and evidence images.
///
/// `CALayer.render(in:)` ignores animations, masks and shadows, so this uses `CARenderer` into a Metal texture:
/// the same compositor the screen uses, evaluated at an explicit media time.
@MainActor
public enum DrawingSnapshot {
    public enum SnapshotError: Error, CustomStringConvertible {
        case noMetalDevice
        case textureUnavailable
        case imageUnavailable
        case writeFailed(URL)

        public var description: String {
            switch self {
            case .noMetalDevice: "no Metal device is available for offscreen rendering"
            case .textureUnavailable: "could not create an offscreen texture"
            case .imageUnavailable: "could not read the rendered image"
            case .writeFailed(let url): "could not write \(url.path)"
            }
        }
    }

    private static var keeper: CARenderer?

    /// Make sure this process has a Core Animation render context before layers get animations.
    ///
    /// In a process with no window and no renderer yet (a command-line tool or a test run), committing a transaction
    /// drops the pending animations of layers that aren't on screen, so the first drawing would appear already
    /// finished. A small offscreen renderer kept for the life of the process prevents that. Cheap. `adopt(_:)` calls
    /// it and also keeps a painter's layer inside that renderer's context, which is what offscreen painters need.
    public static func prepare() {
        guard keeper == nil, let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        let renderer = CARenderer(mtlTexture: texture, options: nil)
        renderer.layer = CALayer()
        keeper = renderer
    }

    /// Keep an offscreen layer inside a render context, the way a window keeps the overlay's.
    ///
    /// Core Animation strips the animations from layers that belong to no render context whenever a transaction is
    /// flushed (any `CATransaction.flush()` on the main thread, including the one in `render`), so a painter's layer
    /// that is built and inspected offscreen must live under a context between snapshots. `render` borrows the layer
    /// and puts it back here afterwards.
    public static func adopt(_ layer: CALayer) {
        prepare()
        guard let root = keeper?.layer, layer.superlayer !== root else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.addSublayer(layer)
        CATransaction.commit()
    }

    /// Render `content` (sized in points) at media time `time` over an optional background.
    /// `backdrop` is drawn under the content (for example a synthetic screen).
    public static func render(_ content: CALayer, size: CGSize, at time: CFTimeInterval, background: CGColor? = nil,
                              backdrop: CGImage? = nil) throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw SnapshotError.noMetalDevice }
        let width = max(1, Int(size.width.rounded())), height = max(1, Int(size.height.rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw SnapshotError.textureUnavailable }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: colorSpace, kCARendererMetalCommandQueue: queue])

        let root = CALayer()
        // The renderer only sees what is committed after it owns the root, so attach first, then build.
        renderer.layer = root
        renderer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let previousParent = content.superlayer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.anchorPoint = .zero
        root.bounds = renderer.bounds
        root.position = .zero
        // Unflipped, like a window's root layer: the painter's own layer flips its content to y-down.
        root.backgroundColor = background
        if let backdrop {
            let image = CALayer()
            image.anchorPoint = .zero
            image.frame = root.bounds
            image.contents = backdrop
            image.contentsGravity = .resize
            root.addSublayer(image)
        }
        content.removeFromSuperlayer()
        root.addSublayer(content)
        CATransaction.commit()
        CATransaction.flush()

        renderer.beginFrame(atTime: time, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        if let buffer = queue.makeCommandBuffer() {
            buffer.commit()
            buffer.waitUntilCompleted()
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.removeFromSuperlayer()
        previousParent?.addSublayer(content)
        CATransaction.commit()

        // The texture comes back bottom row first.
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(&pixels, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var flipped = [UInt8](repeating: 0, count: pixels.count)
        for row in 0..<height {
            let source = (height - 1 - row) * rowBytes
            flipped.replaceSubrange(row * rowBytes..<(row + 1) * rowBytes, with: pixels[source..<source + rowBytes])
        }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: Data(flipped) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { throw SnapshotError.imageUnavailable }
        return image
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotError.writeFailed(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SnapshotError.writeFailed(url) }
    }

    /// RGBA (0…255) of one pixel, top-left origin. For tests.
    public static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0, 0) }
        context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
    }
}
