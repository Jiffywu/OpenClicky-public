import CoreGraphics
import Foundation

/// `onScreen(n)` at the start of a drawing program: which of the turn's screenshots (numbered from 1, as the brain saw
/// them) the drawing goes on. The host must know before the drawing begins, since the canvas, its size and the display
/// overlay all follow from the screenshot, so it reads the directive from the streamed program text itself.
///
/// The directive counts only as the program's first statement (comments and blank lines may come before it). While
/// the text so far could still turn into one, the answer is `.undecided` and the host holds the text back.
public enum DrawingScreenDirective {
    public enum Scan: Sendable, Hashable {
        /// More text is needed to tell.
        case undecided
        /// The program doesn't start with `onScreen(n)`: draw on the default canvas.
        case none
        /// `onScreen(n)`, n ≥ 1.
        case screen(Int)
    }

    /// Reads the start of `program`. With `complete` (the brain has finished) an unfinished directive counts as none.
    public static func scan(_ program: String, complete: Bool = false) -> Scan {
        let chars = Array(program.unicodeScalars)
        var i = 0
        // Whitespace, semicolons and comments before the first statement.
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == ";" { i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                guard let end = chars[i...].firstIndex(of: "\n") else { return complete ? .none : .undecided }
                i = end + 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                guard j + 1 < chars.count else { return complete ? .none : .undecided }
                i = j + 2
                continue
            }
            if c == "/", i + 1 == chars.count { return complete ? .none : .undecided }
            break
        }
        let rest = String(String.UnicodeScalarView(chars[min(i, chars.count)...]))
        if rest.isEmpty { return complete ? .none : .undecided }
        let keyword = "onScreen"
        if rest.count < keyword.count { return keyword.hasPrefix(rest) && !complete ? .undecided : .none }
        guard rest.hasPrefix(keyword) else { return .none }
        // onScreen ( spaces digits spaces )
        var tail = Substring(rest.dropFirst(keyword.count))
        tail = tail.drop { $0 == " " || $0 == "\t" }
        guard let open = tail.first else { return complete ? .none : .undecided }
        guard open == "(" else { return .none }
        tail = tail.dropFirst().drop { $0 == " " || $0 == "\t" }
        let digits = tail.prefix { $0.isASCII && $0.isNumber }
        tail = tail.dropFirst(digits.count).drop { $0 == " " || $0 == "\t" }
        guard let close = tail.first else { return complete ? .none : .undecided }
        guard close == ")", let n = Int(digits), n >= 1 else { return .none }
        return .screen(n)
    }

    /// The screenshot a program asks for, if it is one of `screenshots` (1-based).
    public static func screenshot(_ number: Int, in screenshots: [TurnScreenshot]) -> TurnScreenshot? {
        screenshots.indices.contains(number - 1) ? screenshots[number - 1] : nil
    }

    /// A canvas point (screenshot pixels of `screenshot`) in global screen points (Quartz, y down): where a mark drawn
    /// there appears on the desktop.
    public static func globalPoint(_ point: CGPoint, on screenshot: TurnScreenshot) -> CGPoint {
        let frame = screenshot.displayFrame
        let sx = screenshot.pixelSize.width > 0 ? frame.width / screenshot.pixelSize.width : 1
        let sy = screenshot.pixelSize.height > 0 ? frame.height / screenshot.pixelSize.height : 1
        return CGPoint(x: frame.minX + point.x * sx, y: frame.minY + point.y * sy)
    }
}
