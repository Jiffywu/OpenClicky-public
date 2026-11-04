import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-renders saved drawing programs as small images for Home's "Recent drawings", with the real drawing engine
/// (`DrawingRehearsal`: engine, painter and offscreen compositor), and keeps the results as PNGs on disk so each
/// program renders once.
@MainActor
public final class DrawingThumbnailer {
    public enum Style: String, Sendable, CaseIterable {
        /// The drawing over a plain light card.
        case light
        /// The drawing over a plain dark card.
        case dark
    }

    public nonisolated static var defaultCacheDirectory: URL {
        HistoryStore.defaultDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    }

    public let cacheDirectory: URL?
    /// Width of the finished thumbnail in pixels; the height follows the canvas.
    public var pixelWidth: Int
    public var ink: String
    private var memory: [String: CGImage] = [:]

    public init(cacheDirectory: URL? = DrawingThumbnailer.defaultCacheDirectory, pixelWidth: Int = 480, ink: String = "#3380FF") {
        self.cacheDirectory = cacheDirectory
        self.pixelWidth = pixelWidth
        self.ink = ink
    }

    /// The canvas a program is laid out on when the turn didn't record one (a 13-inch laptop screen).
    public nonisolated static let defaultCanvas = HistoryCanvas(width: 1280, height: 832)

    /// The thumbnail for `program`, from memory, the disk cache, or a fresh render.
    public func thumbnail(for program: String, canvas: HistoryCanvas? = nil, style: Style = .light) throws -> CGImage {
        let canvas = Self.clamped(canvas ?? Self.defaultCanvas)
        let key = cacheKey(program: program, canvas: canvas, style: style)
        if let image = memory[key] { return image }
        if let url = cacheURL(key), let image = Self.readPNG(url) {
            memory[key] = image
            return image
        }
        var options = DrawingRehearsal.Options()
        options.width = canvas.width
        options.height = canvas.height
        options.ink = ink
        options.backdrop = .color(style == .dark ? "#1C1D21" : "#F3F4F6")
        let result = try DrawingRehearsal.run(program: program, options: options)
        let image = Self.scaled(result.image, toWidth: pixelWidth) ?? result.image
        memory[key] = image
        if let url = cacheURL(key) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? DrawingSnapshot.writePNG(image, to: url)
        }
        return image
    }

    /// The thumbnail for a saved drawing: over the screenshot it was drawn on when its lesson kept one, else over a
    /// plain card like `thumbnail(for:canvas:style:)`.
    public func thumbnail(for drawing: HistoryDrawing, style: Style = .light) throws -> CGImage {
        // <history>/lessons/<turn>: the store of the history the folder is in.
        let store = drawing.lessonFolder.map { DrawingLessonStore(historyDirectory: $0.deletingLastPathComponent().deletingLastPathComponent()) }
        guard let folder = drawing.lessonFolder, let store, let lesson = store.load(folder: folder),
              let screen = store.screenshot(folder: folder) else {
            return try thumbnail(for: drawing.program, canvas: drawing.canvas, style: style)
        }
        let canvas = Self.clamped(lesson.canvas)
        let key = cacheKey(program: lesson.program, canvas: canvas, style: style) + "-lesson-" + HistoryStore.safeName(lesson.turnID)
        if let image = memory[key] { return image }
        if let url = cacheURL(key), let image = Self.readPNG(url) {
            memory[key] = image
            return image
        }
        var options = DrawingRehearsal.Options()
        options.width = lesson.canvas.width
        options.height = lesson.canvas.height
        options.ink = ink
        options.backdrop = .image(screen)
        let result = try DrawingRehearsal.run(program: lesson.program, options: options)
        let image = Self.scaled(result.image, toWidth: pixelWidth) ?? result.image
        memory[key] = image
        if let url = cacheURL(key) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? DrawingSnapshot.writePNG(image, to: url)
        }
        return image
    }

    /// PNG bytes of the thumbnail, for views that take data.
    public func pngData(for program: String, canvas: HistoryCanvas? = nil, style: Style = .light) throws -> Data {
        try Self.png(thumbnail(for: program, canvas: canvas, style: style))
    }

    /// Drops the cached images (memory and disk).
    public func clearCache() {
        memory.removeAll()
        if let cacheDirectory { try? FileManager.default.removeItem(at: cacheDirectory) }
    }

    func cacheKey(program: String, canvas: HistoryCanvas, style: Style) -> String {
        let material = "v1|\(program)|\(Int(canvas.width))x\(Int(canvas.height))|\(style.rawValue)|\(ink)|\(pixelWidth)"
        return SHA256.hash(data: Data(material.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func cacheURL(_ key: String) -> URL? { cacheDirectory?.appendingPathComponent(key + ".png") }

    /// Keeps absurd recorded canvases (a 6K display, a zero-height window) to sizes the renderer handles quickly.
    static func clamped(_ canvas: HistoryCanvas) -> HistoryCanvas {
        guard canvas.width > 10, canvas.height > 10 else { return defaultCanvas }
        let scale = min(1, 1920 / max(canvas.width, canvas.height))
        return HistoryCanvas(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
    }

    static func scaled(_ image: CGImage, toWidth width: Int) -> CGImage? {
        guard width > 0, image.width > width else { return image }
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func readPNG(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw DrawingSnapshot.SnapshotError.imageUnavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DrawingSnapshot.SnapshotError.imageUnavailable }
        return data as Data
    }
}
