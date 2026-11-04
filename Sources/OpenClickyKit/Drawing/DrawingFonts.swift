import CoreGraphics
import CoreText
import Foundation

/// The text faces a drawing uses (`style` on a text mark).
public enum DrawingTextStyle: String, Sendable, CaseIterable {
    /// Handwriting.
    case hand
    /// Bold handwriting for headings.
    case title
    /// The system font, for labels that must be crisp.
    case ui
    /// The system font, semibold (pills, badges, buttons, dates).
    case bold
    /// A monospaced face.
    case mono
    /// A clean sans serif (Barlow) for card-like words.
    case sans

    public init(name: String?) { self = DrawingTextStyle(rawValue: name ?? "") ?? .ui }
}

/// Core Text fonts, measurement and glyph outlines for drawn words. The engine measures through `width(of:size:style:)`
/// and the painter sets the same words with `glyphPath`, so layout decided in JavaScript matches what is painted.
public enum DrawingFonts {
    /// Handwriting faces that ship with macOS, used when the bundled one can't be loaded, in order of preference.
    static let handFaces = ["Noteworthy-Light", "ChalkboardSE-Regular", "MarkerFelt-Thin"]
    static let titleFaces = ["Noteworthy-Bold", "ChalkboardSE-Bold", "MarkerFelt-Wide"]

    /// Fonts bundled in `Resources/fonts` (SIL Open Font License; the licences sit next to them): Patrick Hand for
    /// handwriting, Barlow for card titles and `sans` words. Loaded from their files, not installed system-wide.
    public enum Bundled: String, CaseIterable, Sendable {
        case patrickHand = "PatrickHand-Regular"
        case barlow = "Barlow-Regular"
        case barlowMedium = "Barlow-Medium"
        case barlowSemiBold = "Barlow-SemiBold"
    }

    private final class Faces: @unchecked Sendable {
        let lock = NSLock()
        var loaded: [Bundled: CGFont] = [:]
        var missing: Set<Bundled> = []
    }
    private static let faces = Faces()

    /// The bundled face, or nil when its file is missing or unreadable.
    public static func bundled(_ face: Bundled) -> CGFont? {
        faces.lock.lock()
        defer { faces.lock.unlock() }
        if let font = faces.loaded[face] { return font }
        if faces.missing.contains(face) { return nil }
        guard let url = KitResources.url(face.rawValue, "ttf", in: "fonts"), let provider = CGDataProvider(url: url as CFURL),
              let font = CGFont(provider) else {
            faces.missing.insert(face)
            return nil
        }
        faces.loaded[face] = font
        return font
    }

    /// Handwriting at a heading's weight has no bold face of its own: it is drawn with a thin outline of its own ink.
    public static func syntheticBoldWidth(_ style: DrawingTextStyle, size: CGFloat) -> CGFloat {
        style == .title && bundled(.patrickHand) != nil ? max(0.4, size * 0.035) : 0
    }

    private static func make(_ face: Bundled, size: CGFloat) -> CTFont? {
        bundled(face).map { CTFontCreateWithGraphicsFont($0, size, nil, nil) }
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var fonts: [String: CTFont] = [:]
    }
    private static let cache = Cache()

    public static func font(_ style: DrawingTextStyle, size: CGFloat) -> CTFont {
        let size = max(1, size)
        let key = "\(style.rawValue)@\(size)"
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let font = cache.fonts[key] { return font }
        let font: CTFont
        switch style {
        case .hand: font = make(.patrickHand, size: size) ?? named(handFaces, size: size) ?? CTFontCreateUIFontForLanguage(.system, size, nil)!
        case .title: font = make(.patrickHand, size: size) ?? named(titleFaces, size: size) ?? CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)!
        case .ui: font = CTFontCreateUIFontForLanguage(.system, size, nil)!
        case .bold: font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)!
        case .mono: font = named(["Menlo-Regular", "Courier"], size: size) ?? CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)!
        case .sans: font = make(.barlowMedium, size: size) ?? CTFontCreateUIFontForLanguage(.system, size, nil)!
        }
        if cache.fonts.count > 512 { cache.fonts.removeAll() }
        cache.fonts[key] = font
        return font
    }

    /// The first face that is actually installed (Core Text silently substitutes a fallback for missing names).
    private static func named(_ names: [String], size: CGFloat) -> CTFont? {
        for name in names {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            if (CTFontCopyPostScriptName(font) as String) == name { return font }
        }
        return nil
    }

    static func line(_ text: String, font: CTFont) -> CTLine {
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: font]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// Advance width of one line of text, in the same units as `size`.
    public static func width(of text: String, size: Double, style: DrawingTextStyle) -> Double {
        guard !text.isEmpty, size > 0 else { return 0 }
        let line = line(text, font: font(style, size: CGFloat(size)))
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil)) + Double(syntheticBoldWidth(style, size: CGFloat(size)))
    }

    /// A card's title-bar words: Barlow SemiBold when bundled, else the system's semibold face.
    public static func titleBarFont(size: CGFloat) -> CTFont {
        make(.barlowSemiBold, size: size) ?? font(.bold, size: size)
    }

    public static func ascent(_ style: DrawingTextStyle, size: CGFloat) -> CGFloat { CTFontGetAscent(font(style, size: size)) }
    public static func descent(_ style: DrawingTextStyle, size: CGFloat) -> CGFloat { CTFontGetDescent(font(style, size: size)) }

    /// The outlines of a line of text, with its baseline starting at `origin` in a y-down coordinate space.
    /// Glyphs Core Text substitutes from fallback fonts are included. Colour bitmap glyphs (emoji) have no outline.
    public static func glyphPath(_ text: String, style: DrawingTextStyle, size: CGFloat, origin: CGPoint) -> (path: CGPath, width: CGFloat) {
        glyphPath(text, font: font(style, size: size), origin: origin)
    }

    /// The outlines of a line of text set in `font`, baseline at `origin`, y down.
    public static func glyphPath(_ text: String, font: CTFont, origin: CGPoint) -> (path: CGPath, width: CGFloat) {
        let path = CGMutablePath()
        let line = line(text, font: font)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont // swiftlint:disable:this force_cast
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for index in 0..<count {
                var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origin.x + positions[index].x, ty: origin.y - positions[index].y)
                if let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], &transform) { path.addPath(glyph) }
            }
        }
        return (path, width)
    }
}
