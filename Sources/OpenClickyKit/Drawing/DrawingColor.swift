import CoreGraphics
import Foundation

/// Colours as the drawing engine writes them: `#RGB`, `#RRGGBB` or `#RRGGBBAA`, plus a few CSS names.
public struct DrawingColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = DrawingColor(red: 0, green: 0, blue: 0)
    public static let white = DrawingColor(red: 1, green: 1, blue: 1)
    public static let defaultInk = DrawingColor(hex: "#3380FF")!

    public init?(hex text: String?) {
        guard var text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        switch text {
        case "white": self = .white; return
        case "black": self = .black; return
        case "transparent", "none": self.init(red: 0, green: 0, blue: 0, alpha: 0); return
        default: break
        }
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        if text.count == 8 {
            self.init(red: Double((value >> 24) & 0xFF) / 255, green: Double((value >> 16) & 0xFF) / 255,
                      blue: Double((value >> 8) & 0xFF) / 255, alpha: Double(value & 0xFF) / 255)
        } else {
            self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
    }

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    public func withAlpha(_ value: Double) -> DrawingColor { DrawingColor(red: red, green: green, blue: blue, alpha: value) }

    /// Linear blend toward another colour (`t` = 0 keeps this colour).
    public func mixed(with other: DrawingColor, _ t: Double) -> DrawingColor {
        DrawingColor(red: red + (other.red - red) * t, green: green + (other.green - green) * t,
                     blue: blue + (other.blue - blue) * t, alpha: alpha + (other.alpha - alpha) * t)
    }

    /// WCAG relative luminance (0 black … 1 white).
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// The soft gel a pill, badge or button is made of, derived from one base colour (usually Clicky's ink).
    public struct Gel: Sendable, Hashable {
        public var top: DrawingColor
        public var bottom: DrawingColor
        public var rim: DrawingColor
        public var gloss: DrawingColor
    }

    public var gel: Gel {
        Gel(top: mixed(with: .white, 0.88), bottom: mixed(with: .white, 0.58), rim: mixed(with: .black, 0.42), gloss: DrawingColor.white.withAlpha(0.55))
    }
}
