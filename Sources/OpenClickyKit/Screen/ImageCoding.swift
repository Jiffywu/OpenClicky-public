import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encoding, decoding and resizing of screenshots. Uses ImageIO and Core Graphics only, so it works in tests and
/// command-line tools.
public enum ImageCoding {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case encodeFailed(String)
        case decodeFailed
        case resizeFailed

        public var description: String {
            switch self {
            case .encodeFailed(let type): "Couldn't encode the image as \(type)."
            case .decodeFailed: "Couldn't decode the image."
            case .resizeFailed: "Couldn't resize the image."
            }
        }
    }

    public static let defaultJPEGQuality = 0.8
    public static let voiceJPEGQuality = 0.6

    /// JPEG bytes at `quality` (0…1). Alpha is dropped; screenshots are opaque.
    public static func jpegData(_ image: CGImage, quality: Double = defaultJPEGQuality) throws -> Data {
        try encode(image, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)])
    }

    public static func pngData(_ image: CGImage) throws -> Data {
        try encode(image, type: .png, properties: [:])
    }

    public static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.decodeFailed }
        return image
    }

    /// Pixel dimensions of encoded image data without decoding all of it.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Redraws `image` at exactly `width` × `height` pixels with high-quality interpolation, in sRGB.
    public static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        if image.width == width && image.height == height { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.resizeFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw Failure.resizeFailed }
        return result
    }

    /// Shrinks an image so its long edge is at most `longEdge` (never enlarges).
    public static func downscaled(_ image: CGImage, longEdge: Int) throws -> CGImage {
        let size = CaptureSizing.downscaledSize(width: image.width, height: image.height, longEdge: longEdge)
        return try resized(image, width: size.width, height: size.height)
    }

    /// Re-encodes a screenshot smaller, e.g. for a realtime voice model (768 or 640 px, quality 0.6).
    public static func rescaledJPEG(_ data: Data, longEdge: Int, quality: Double = voiceJPEGQuality) throws -> (data: Data, width: Int, height: Int) {
        let image = try downscaled(decode(data), longEdge: longEdge)
        return (try jpegData(image, quality: quality), image.width, image.height)
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw Failure.encodeFailed(type.preferredFilenameExtension ?? type.identifier)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodeFailed(type.preferredFilenameExtension ?? type.identifier) }
        return data as Data
    }
}
