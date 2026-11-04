import CoreGraphics
import Foundation

/// Finds the element a spoken or written label refers to ("the Save button", "Share", "search field").
public enum ElementLabelMatcher {
    public struct Match: Sendable, Hashable {
        public var element: ElementSnapshot
        public var score: Double
        /// The element text that matched.
        public var matchedText: String
    }

    /// Lowercase, accent- and width-folded, punctuation turned into spaces, spaces collapsed. "Save…" → "save".
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        var result = ""
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return result
    }

    static let fillerWords: Set<String> = ["the", "a", "an", "this", "that", "click", "press", "tap", "on", "here", "named", "called", "labeled", "labelled"]

    /// Splits a query into the label words and any kind words ("button", "link"…) that hint at the role.
    static func parse(_ query: String) -> (core: [String], kindHints: Set<String>) {
        var tokens = normalize(query).split(separator: " ").map(String.init)
        while let first = tokens.first, fillerWords.contains(first), tokens.count > 1 { tokens.removeFirst() }
        var hints: Set<String> = []
        // Kind words at the end ("Save button") or start ("button Save") are hints, as long as some label is left.
        while let last = tokens.last, let roles = ElementRoles.kindWords[last], tokens.count > 1 {
            hints.formUnion(roles)
            tokens.removeLast()
        }
        while let first = tokens.first, let roles = ElementRoles.kindWords[first], tokens.count > 1 {
            hints.formUnion(roles)
            tokens.removeFirst()
        }
        return (tokens, hints)
    }

    /// Matches best first. Elements without a frame or that are big containers never match.
    public static func matches(for query: String, in elements: [ElementSnapshot], minimumScore: Double = 0.45) -> [Match] {
        let (core, hints) = parse(query)
        guard !core.isEmpty else { return [] }
        let coreText = core.joined(separator: " ")
        var results: [(match: Match, order: Int)] = []
        for (order, element) in elements.enumerated() {
            guard element.frame.width > 0, element.frame.height > 0, !ElementRoles.containers.contains(element.role) else { continue }
            var best: (score: Double, text: String)?
            for (candidate, weight) in candidates(of: element) {
                let score = textScore(query: core, queryText: coreText, candidate: candidate) * weight
                if score > (best?.score ?? 0) { best = (score, candidate) }
            }
            guard let best, best.score > 0 else { continue }
            var score = best.score
            let text = best.text
            if element.isActionable { score += 0.04 }
            if !hints.isEmpty { score += hints.contains(element.role) ? 0.08 : -0.05 }
            if !element.isEnabled { score -= 0.05 }
            guard score >= minimumScore else { continue }
            results.append((Match(element: element, score: min(score, 1.2), matchedText: text), order))
        }
        results.sort { a, b in
            if abs(a.match.score - b.match.score) > 0.0001 { return a.match.score > b.match.score }
            if a.match.element.isActionable != b.match.element.isActionable { return a.match.element.isActionable }
            let areaA = a.match.element.frame.width * a.match.element.frame.height
            let areaB = b.match.element.frame.width * b.match.element.frame.height
            if areaA != areaB { return areaA < areaB }
            return a.order < b.order
        }
        return results.map(\.match)
    }

    public static func bestMatch(for query: String, in elements: [ElementSnapshot]) -> Match? {
        matches(for: query, in: elements).first
    }

    /// The texts an element can be called by, with how much a match on each counts.
    static func candidates(of element: ElementSnapshot) -> [(String, Double)] {
        var list: [(String?, Double)] = [(element.label, 1.0), (element.title, 1.0), (element.detail, 1.0), (element.placeholder, 0.9), (element.help, 0.7)]
        if element.role != "AXTextArea" { list.append((element.value, 0.9)) }
        if let identifier = element.identifier {
            // camelCase and snake_case identifiers become words: "saveButton" → "save button".
            list.append((identifier.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression), 0.6))
        }
        var seen: Set<String> = []
        return list.compactMap { text, weight in
            guard let text else { return nil }
            let normalized = normalize(String(text.prefix(300)))
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return (normalized, weight)
        }
    }

    static func textScore(query: [String], queryText: String, candidate: String) -> Double {
        if candidate == queryText { return 1 }
        let words = candidate.split(separator: " ").map(String.init)
        if words.starts(with: query) { return 0.85 }
        if containsRun(words, query) { return 0.75 }
        if candidate.count >= 3, containsRun(query, words) { return 0.65 }
        let a = Set(query), b = Set(words)
        let overlap = Double(a.intersection(b).count) / Double(a.union(b).count)
        if overlap >= 0.5 { return 0.6 * overlap + 0.2 }
        if query.count == 1, let word = query.first, word.count >= 3, words.contains(where: { $0.hasPrefix(word) }) { return 0.5 }
        return 0
    }

    /// True when `needle` appears in `haystack` as consecutive words.
    static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}

/// Snaps a point (from a model's pixel answer) to the real control under or near it, so rings outline the actual
/// button instead of a guessed circle.
public enum ElementSnapper {
    /// The smallest actionable element containing `point` (AppKit global), else the nearest within `radius` points.
    public static func snap(_ point: CGPoint, in elements: [ElementSnapshot], radius: CGFloat = 28) -> ElementSnapshot? {
        let candidates = elements.filter {
            $0.isActionable && $0.frame.width > 0 && $0.frame.height > 0 && $0.frame.width < 1_000 && $0.frame.height < 700
        }
        func area(_ e: ElementSnapshot) -> CGFloat { e.frame.width * e.frame.height }
        if let hit = candidates.filter({ $0.frame.insetBy(dx: -2, dy: -2).contains(point) }).min(by: { area($0) < area($1) }) {
            return hit
        }
        let near = candidates.map { ($0, DesktopLayout.distance(from: point, to: $0.frame)) }.filter { $0.1 <= radius }
        return near.min { a, b in a.1 != b.1 ? a.1 < b.1 : area(a.0) < area(b.0) }?.0
    }
}

/// Where to point, in whatever space the request came in.
public enum PointingDestination: Sendable, Hashable {
    /// AppKit global points.
    case point(CGPoint)
    /// An element's frame, AppKit global points.
    case rect(CGRect)
    /// A pixel in a screenshot (top-left origin), as a model answers.
    case pixel(CGPoint, CaptureGeometry)
    /// A box in a screenshot's pixels.
    case pixelRect(CGRect, CaptureGeometry)

    /// The point to fly to and the frame to outline, both in AppKit global points.
    public var resolved: ResolvedPointingTarget {
        switch self {
        case .point(let point): return ResolvedPointingTarget(point: point, frame: nil)
        case .rect(let rect): return ResolvedPointingTarget(point: Self.aimPoint(for: rect), frame: rect)
        case .pixel(let pixel, let geometry): return ResolvedPointingTarget(point: geometry.appKitPoint(fromPixel: pixel), frame: nil)
        case .pixelRect(let rect, let geometry):
            let frame = geometry.appKitRect(fromPixelRect: rect)
            return ResolvedPointingTarget(point: Self.aimPoint(for: frame), frame: frame)
        }
    }

    /// Where the tip lands on an element (AppKit global, y up). On small controls it touches the lower edge just right
    /// of center, so the body hangs below and the control's text stays readable; on big areas it goes to the center.
    public static func aimPoint(for rect: CGRect) -> CGPoint {
        guard rect.height <= 60, rect.width <= 600 else { return CGPoint(x: rect.midX, y: rect.midY) }
        return CGPoint(x: rect.midX + min(rect.width * 0.12, 10), y: rect.minY + min(rect.height * 0.2, 4))
    }
}

public struct ResolvedPointingTarget: Sendable, Hashable {
    /// AppKit global points.
    public var point: CGPoint
    /// The element's frame when pointing at one (AppKit global points).
    public var frame: CGRect?

    public init(point: CGPoint, frame: CGRect?) {
        self.point = point
        self.frame = frame
    }
}

extension WindowElementSnapshot {
    /// The element a label names and where to point at it.
    public func resolve(label: String) -> (element: ElementSnapshot, target: ResolvedPointingTarget)? {
        guard let match = ElementLabelMatcher.bestMatch(for: label, in: elements) else { return nil }
        return (match.element, PointingDestination.rect(match.element.frame).resolved)
    }

    /// The element with an id from `promptLines` ("e12").
    public func resolve(elementID: String) -> (element: ElementSnapshot, target: ResolvedPointingTarget)? {
        guard let element = element(id: elementID) else { return nil }
        return (element, PointingDestination.rect(element.frame).resolved)
    }
}
