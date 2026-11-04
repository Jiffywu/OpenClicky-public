import Foundation
import ImageIO

/// How the preview pane shows a deliverable: Markdown and CSV/TSV natively, PDFs with PDFKit, animated GIF and APNG
/// with their own frame timing, and everything else (images, Office files including XLSX, text, code, media) through
/// QuickLook. Links open in the browser.
public enum FilePreviewKind: String, Sendable, Hashable, CaseIterable {
    case markdown
    case spreadsheet
    case pdf
    case animatedImage
    case quickLook
    case link

    public static func classify(_ location: String) -> FilePreviewKind {
        if location.hasPrefix("http://") || location.hasPrefix("https://") { return .link }
        let url = URL(fileURLWithPath: location)
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "csv", "tsv", "tab": return .spreadsheet
        case "pdf": return .pdf
        case "gif", "apng": return AnimatedImageReader.frameCount(url) > 1 ? .animatedImage : .quickLook
        case "png": return AnimatedImageReader.isAPNG(url) && AnimatedImageReader.frameCount(url) > 1 ? .animatedImage : .quickLook
        default: return .quickLook
        }
    }

    /// A short label for the pane's header.
    public var label: String {
        switch self {
        case .markdown: "Markdown"
        case .spreadsheet: "Spreadsheet"
        case .pdf: "PDF"
        case .animatedImage: "Animation"
        case .quickLook: "Quick Look"
        case .link: "Link"
        }
    }
}

/// Frames and timing of GIF and APNG files, read with ImageIO.
public enum AnimatedImageReader {
    public struct Frames: Sendable {
        public var count: Int
        /// Seconds each frame shows (clamped like browsers: under 20 ms counts as 100 ms).
        public var delays: [Double]
        /// 0 loops forever.
        public var loopCount: Int
        public var totalDuration: Double { delays.reduce(0, +) }
    }

    public static func frameCount(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    /// Whether a PNG file is animated (has an `acTL` chunk before its image data).
    public static func isAPNG(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return isAPNG(data: (try? handle.read(upToCount: 64 * 1024)) ?? Data())
    }

    public static func isAPNG(data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count > 8, Array(data.prefix(8)) == signature else { return false }
        var offset = 8
        let bytes = [UInt8](data)
        while offset + 8 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            if type == "acTL" { return true }
            if type == "IDAT" || type == "IEND" { return false }
            offset += 12 + length
        }
        return false
    }

    public static func frames(_ url: URL) -> Frames? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return frames(source)
    }

    public static func frames(data: Data) -> Frames? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return frames(source)
    }

    static func frames(_ source: CGImageSource) -> Frames? {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var delays: [Double] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            delays.append(delay(properties))
        }
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let gif = container[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = container[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let loops = (gif?[kCGImagePropertyGIFLoopCount] as? Int) ?? (png?[kCGImagePropertyAPNGLoopCount] as? Int) ?? 0
        return Frames(count: count, delays: delays, loopCount: loops)
    }

    static func delay(_ properties: [CFString: Any]) -> Double {
        var value: Double?
        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            value = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
        } else if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            value = (png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double) ?? (png[kCGImagePropertyAPNGDelayTime] as? Double)
        }
        guard let value, value >= 0.02 else { return 0.1 }
        return value
    }
}
