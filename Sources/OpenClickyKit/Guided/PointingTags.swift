import CoreGraphics
import Foundation

/// The classic pointing grammar (03 §6.1): answers whose lines start with a tag in screenshot pixels, followed by the
/// sentence spoken while it shows. OpenClicky's brain draws programs instead (docs/dsl.md, docs/dsl-guided.md), but
/// providers and prompts that answer in tags can still point, highlight and arm guided targets through this parser.
///
///     [POINT:812,96:Share] This is the Share button.
///     [TARGET:640,410,18:Export] Click Export to continue.
///     [SHAPE:arrow:200,300;420,300:drag here] Drag the file across.
///     [TYPE:500,220:Name]<<<
///     Jeff
///     >>>
public enum PointingVisual: Sendable, Hashable {
    /// Fly the pointer to a pixel and name it. `screen` is 1-based, nil means the pointer's screen.
    case point(CGPoint, label: String?, screen: Int?)
    /// Nothing on screen to point at.
    case pointNone
    /// A rectangle `x, y, w, h`.
    case highlight(CGRect, label: String?, screen: Int?)
    /// Ring a control and wait for the user's click (or, with `hover`, for the pointer to rest on it).
    case target(center: CGPoint, radius: CGFloat?, label: String?, screen: Int?, hover: Bool)
    case shape(kind: PointingShapeKind, points: [CGPoint], label: String?, screen: Int?)
    /// Put text into the field at a pixel.
    case type(at: CGPoint, label: String?, screen: Int?, text: String)

    /// A guided target request for `target` visuals (pixels of the screenshot).
    public var guidedRequest: GuidedTargetRequest? {
        guard case .target(let center, let radius, let label, _, let hover) = self else { return nil }
        return GuidedTargetRequest(.pixelRing(center: center, radius: radius), label: label, isHover: hover)
    }

    public var screen: Int? {
        switch self {
        case .point(_, _, let s), .highlight(_, _, let s), .target(_, _, _, let s, _), .shape(_, _, _, let s), .type(_, _, let s, _): s
        case .pointNone: nil
        }
    }
}

public enum PointingShapeKind: String, Sendable, Hashable, CaseIterable {
    case line, arrow, circle, curve, polygon
}

/// One beat: what shows, and the words spoken while it does.
public struct PointingBeat: Sendable, Hashable {
    public var visual: PointingVisual?
    public var spoken: String

    public init(visual: PointingVisual?, spoken: String) {
        self.visual = visual
        self.spoken = spoken
    }
}

public enum PointingTagParser {
    static let tags = ["POINT", "HIGHLIGHT", "TARGET", "HOVER", "SHAPE", "TYPE"]
    private static let anyTag = try! NSRegularExpression(pattern: "\\[(?:POINT|HIGHLIGHT|SHAPE|TARGET|HOVER|TYPE):[^\\]\\n]*\\]")
    private static let screenSuffix = try! NSRegularExpression(pattern: ":\\s*screen\\s*(\\d+)\\s*$", options: [.caseInsensitive])

    /// The beats of an answer, in order. Lines without a tag continue the previous beat's words. Tags that can't be
    /// read are dropped (their words are kept), and the result never contains tag text.
    public static func parse(_ text: String) -> [PointingBeat] {
        var beats: [PointingBeat] = []
        var lines = text.components(separatedBy: .newlines)[...]
        while let raw = lines.popFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let (tag, body, rest) = leadingTag(line) else {
                let words = clean(line)
                guard !words.isEmpty else { continue }
                if beats.isEmpty { beats.append(PointingBeat(visual: nil, spoken: words)) } else { beats[beats.count - 1].spoken = join(beats[beats.count - 1].spoken, words) }
                continue
            }
            var spoken = rest
            var typed: String?
            if tag == "TYPE", let start = spoken.range(of: "<<<") {
                // The text to type follows `<<<` up to `>>>`, on the same line or the next ones.
                var block = String(spoken[start.upperBound...])
                spoken = String(spoken[..<start.lowerBound])
                var tail = ""
                while !block.contains(">>>"), let next = lines.popFirst() { block += "\n" + next }
                if let end = block.range(of: ">>>") {
                    tail = String(block[end.upperBound...])
                    block = String(block[..<end.lowerBound])
                }
                typed = block.trimmingCharacters(in: .newlines)
                spoken += " " + tail
            }
            let visual = parseTag(tag, body: body, typed: typed)
            beats.append(PointingBeat(visual: visual, spoken: clean(spoken)))
        }
        return beats
    }

    /// The answer's words with every tag removed (what a voice should say).
    public static func spokenText(_ text: String) -> String {
        parse(text).map(\.spoken).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Pieces

    /// `[TAG:body]rest` at the start of a line (after list markers).
    static func leadingTag(_ line: String) -> (tag: String, body: String, rest: String)? {
        var s = Substring(line)
        while let first = s.first, "-*•>".contains(first) || first.isWhitespace { s = s.dropFirst() }
        guard s.hasPrefix("["), let colon = s.firstIndex(of: ":"), let close = s.firstIndex(of: "]"), colon < close else { return nil }
        let tag = s[s.index(after: s.startIndex)..<colon].uppercased()
        guard tags.contains(tag) else { return nil }
        return (tag, String(s[s.index(after: colon)..<close]), String(s[s.index(after: close)...]))
    }

    static func parseTag(_ tag: String, body: String, typed: String?) -> PointingVisual? {
        var body = body.trimmingCharacters(in: .whitespaces)
        var screen: Int?
        let range = NSRange(body.startIndex..., in: body)
        if let match = screenSuffix.firstMatch(in: body, range: range), let digits = Range(match.range(at: 1), in: body),
           let whole = Range(match.range, in: body) {
            screen = Int(body[digits])
            body.removeSubrange(whole)
        }
        if tag == "POINT", body.lowercased() == "none" { return .pointNone }
        if tag == "SHAPE" {
            let parts = body.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let kind = PointingShapeKind(rawValue: parts[0].trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
            let points = parts[1].split(separator: ";").compactMap { pair -> CGPoint? in
                let n = numbers(String(pair))
                return n.count == 2 ? CGPoint(x: n[0], y: n[1]) : nil
            }
            guard points.count >= 2 else { return nil }
            return .shape(kind: kind, points: points, label: label(parts.count > 2 ? parts[2] : nil), screen: screen)
        }
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let n = numbers(parts[0])
        let name = label(parts.count > 1 ? parts[1] : nil)
        switch tag {
        case "POINT":
            guard n.count == 2 else { return nil }
            return .point(CGPoint(x: n[0], y: n[1]), label: name, screen: screen)
        case "HIGHLIGHT":
            guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
            return .highlight(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), label: name, screen: screen)
        case "TARGET", "HOVER":
            guard n.count == 2 || n.count == 3 else { return nil }
            return .target(center: CGPoint(x: n[0], y: n[1]), radius: n.count == 3 ? abs(n[2]) : nil, label: name, screen: screen, hover: tag == "HOVER")
        case "TYPE":
            guard n.count == 2, let typed, !typed.isEmpty else { return nil }
            return .type(at: CGPoint(x: n[0], y: n[1]), label: name, screen: screen, text: typed)
        default:
            return nil
        }
    }

    /// The comma-separated numbers of a coordinate list; any part that isn't a finite number empties the list.
    static func numbers(_ text: String) -> [CGFloat] {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let values = parts.map { part -> CGFloat? in
            guard part.range(of: "^-?\\d+(\\.\\d+)?$", options: .regularExpression) != nil, let v = Double(part), v.isFinite else { return nil }
            return CGFloat(v)
        }
        return values.contains(nil) ? [] : values.compactMap { $0 }
    }

    static func label(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return String(text.prefix(80))
    }

    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = anyTag.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : a + " " + b }
}
