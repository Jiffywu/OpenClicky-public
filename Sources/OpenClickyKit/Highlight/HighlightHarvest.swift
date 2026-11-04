import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// A line of words found under a mark.
public struct HighlightTextLine: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        case accessibility
        case ocr
    }

    public var text: String
    /// AppKit global points.
    public var frame: CGRect
    public var source: Source

    public init(text: String, frame: CGRect, source: Source) {
        self.text = text
        self.frame = frame
        self.source = source
    }
}

/// A control found under a mark.
public struct HighlightControl: Sendable, Hashable {
    /// Friendly kind: "button", "link", "text field", …
    public var kind: String
    public var label: String?
    public var value: String?
    /// Where a link goes.
    public var url: String?
    /// AppKit global points.
    public var frame: CGRect

    public init(kind: String, label: String?, value: String? = nil, url: String? = nil, frame: CGRect) {
        self.kind = kind
        self.label = label
        self.value = value
        self.url = url
        self.frame = frame
    }
}

/// What lies under one mark.
public struct HighlightHarvest: Sendable, Hashable {
    public var lines: [HighlightTextLine]
    public var controls: [HighlightControl]

    public init(lines: [HighlightTextLine] = [], controls: [HighlightControl] = []) {
        self.lines = lines
        self.controls = controls
    }

    public var isEmpty: Bool { lines.isEmpty && controls.isEmpty }
}

// MARK: - Accessibility

/// What Accessibility reports at one point. Frames are Quartz global points (top-left origin), as AX gives them.
public struct HighlightAXProbe: Sendable, Hashable {
    public var role: String
    public var subrole: String?
    public var label: String?
    public var value: String?
    public var url: String?
    public var frame: CGRect?
    /// The line of text at the point, when the element exposes its text layout.
    public var line: String?
    public var lineFrame: CGRect?

    public init(role: String, subrole: String? = nil, label: String? = nil, value: String? = nil, url: String? = nil, frame: CGRect? = nil,
                line: String? = nil, lineFrame: CGRect? = nil) {
        self.role = role
        self.subrole = subrole
        self.label = label
        self.value = value
        self.url = url
        self.frame = frame
        self.line = line
        self.lineFrame = lineFrame
    }
}

/// The Accessibility seam: what is at a Quartz global point. Live apps answer through `LiveHighlightAccessibility`;
/// tests and the simulator pass fakes.
public protocol HighlightAccessibilitySource: Sendable {
    var isAvailable: Bool { get }
    func probe(atQuartz point: CGPoint) -> HighlightAXProbe?
}

/// Reads the element under a point with `AXUIElementCopyElementAtPosition`, and the exact line of text there through
/// the text-layout parameterized attributes (range for position → line for index → range for line → string and
/// bounds for range). Secure fields report nothing. Needs Accessibility permission.
public struct LiveHighlightAccessibility: HighlightAccessibilitySource {
    public init(messagingTimeout: Float = 0.25) {
        AccessibilityAccess.setMessagingTimeout(seconds: messagingTimeout)
    }

    public var isAvailable: Bool { AccessibilityAccess.isTrusted }

    private static let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                                     kAXURLAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute]

    public func probe(atQuartz point: CGPoint) -> HighlightAXProbe? {
        guard isAvailable, var node = AXNode.systemWide.element(atQuartz: point) else { return nil }
        // Climb out of anonymous wrappers to something with a role worth naming.
        var values = node.values(Self.attributes)
        var hops = 0
        while hops < 3, let role = AXNode.string(from: values[kAXRoleAttribute]), ["AXGroup", "AXUnknown"].contains(role),
              let parent = AXNode.node(from: values[kAXParentAttribute]) {
            node = parent
            values = node.values(Self.attributes)
            hops += 1
        }
        guard let role = AXNode.string(from: values[kAXRoleAttribute]) else { return nil }
        let subrole = AXNode.string(from: values[kAXSubroleAttribute])
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        var probe = HighlightAXProbe(role: role, subrole: subrole,
                                     label: AXNode.string(from: values[kAXTitleAttribute]) ?? AXNode.string(from: values[kAXDescriptionAttribute]),
                                     value: secure ? nil : AXNode.string(from: values[kAXValueAttribute]).map { String($0.prefix(600)) },
                                     url: AXNode.string(from: values[kAXURLAttribute]))
        if let origin = AXNode.point(from: values[kAXPositionAttribute]), let size = AXNode.size(from: values[kAXSizeAttribute]) {
            probe.frame = CGRect(origin: origin, size: size)
        }
        if !secure, let line = Self.line(in: node, atQuartz: point) {
            probe.line = line.text
            probe.lineFrame = line.frame
        }
        return probe
    }

    static func line(in node: AXNode, atQuartz point: CGPoint) -> (text: String, frame: CGRect?)? {
        var p = point
        guard let at = AXValueCreate(.cgPoint, &p),
              let indexRange = AXNode.range(from: node.parameterized(kAXRangeForPositionParameterizedAttribute, at)),
              let lineNumber = node.parameterized(kAXLineForIndexParameterizedAttribute, NSNumber(value: indexRange.location)) as? NSNumber
        else { return nil }
        guard let rangeValue = node.parameterized(kAXRangeForLineParameterizedAttribute, lineNumber),
              let text = AXNode.string(from: node.parameterized(kAXStringForRangeParameterizedAttribute, rangeValue))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        var frame: CGRect?
        if let bounds = node.parameterized(kAXBoundsForRangeParameterizedAttribute, rangeValue), CFGetTypeID(bounds) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(bounds as! AXValue, .cgRect, &rect) { frame = rect }
        }
        return (String(text.prefix(300)), frame)
    }
}

// MARK: - On-device OCR

/// Reads text in part of a screenshot with Vision (`VNRecognizeTextRequest`, on device, no permission needed).
public struct HighlightTextRecognizer: Sendable {
    public var languageCorrection: Bool
    public var minimumConfidence: Float
    /// A turn never waits longer than this for the words; past it the mark is described without them.
    public var timeout: TimeInterval

    public init(languageCorrection: Bool = true, minimumConfidence: Float = 0.3, timeout: TimeInterval = 3) {
        self.languageCorrection = languageCorrection
        self.minimumConfidence = minimumConfidence
        self.timeout = timeout
    }

    /// The first recognition in a process loads Vision's text model, which can take many seconds on a fresh build.
    /// Call this once at launch so the first draw-to-ask turn doesn't pay for it.
    public static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            let context = CGContext(data: nil, width: 64, height: 24, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard let context else { return }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 24))
            guard let image = context.makeImage() else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }

    /// Lines of text in and around `pixelRect` (top-left origin) of `image`, with their boxes in the image's pixels,
    /// top to bottom. The crop reaches `padding` past the rect so words cut by the mark's edge are read whole.
    /// Runs Vision on a GCD queue.
    public func lines(in image: DrawingMediaImage, pixelRect: CGRect, padding: CGSize = CGSize(width: 120, height: 10)) async -> [(text: String, box: CGRect)] {
        let full = CGRect(x: 0, y: 0, width: image.image.width, height: image.image.height)
        let crop = pixelRect.insetBy(dx: -padding.width, dy: -padding.height).integral.intersection(full)
        guard !crop.isNull, crop.width >= 4, crop.height >= 4, let cropped = image.image.cropping(to: crop) else { return [] }
        let correction = languageCorrection, minimum = minimumConfidence, timeout = self.timeout
        let box = DrawingMediaImage(cropped)
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { once.resume([]) }
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = correction
                let handler = VNImageRequestHandler(cgImage: box.image, options: [:])
                var found: [(String, CGRect)] = []
                if (try? handler.perform([request])) != nil {
                    for observation in request.results ?? [] {
                        guard let best = observation.topCandidates(1).first, best.confidence >= minimum else { continue }
                        let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        let b = observation.boundingBox  // normalized, bottom-left origin, relative to the crop
                        let rect = CGRect(x: crop.minX + b.minX * crop.width, y: crop.minY + (1 - b.maxY) * crop.height,
                                          width: b.width * crop.width, height: b.height * crop.height)
                        found.append((text, rect))
                    }
                }
                found.sort { abs($0.1.midY - $1.1.midY) > min($0.1.height, $1.1.height) * 0.5 ? $0.1.midY < $1.1.midY : $0.1.minX < $1.1.minX }
                once.resume(found)
            }
        }
    }
}

/// Resumes a continuation with whichever answer comes first (the result or the timeout).
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func resume(_ value: Value) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

// MARK: - Harvester

/// Reads what is under a mark: Accessibility first (exact strings, control names, link targets), then OCR on the
/// turn's screenshot when Accessibility gave no text (no permission, canvas apps, images of text).
public struct HighlightHarvester: Sendable {
    public var accessibility: (any HighlightAccessibilitySource)?
    public var recognizer: HighlightTextRecognizer?
    public var maximumLines = 20
    public var maximumControls = 12
    /// How long the Accessibility probes of one turn may take together. Each probe can wait up to the messaging
    /// timeout on a busy app, and a turn may have 8 marks of 31 probes each.
    public var accessibilityBudget: TimeInterval = 1.5

    public init(accessibility: (any HighlightAccessibilitySource)? = nil, recognizer: HighlightTextRecognizer? = HighlightTextRecognizer()) {
        self.accessibility = accessibility
        self.recognizer = recognizer
    }

    /// The live harvester: Accessibility (when permitted) and on-device OCR.
    public static var live: HighlightHarvester { HighlightHarvester(accessibility: LiveHighlightAccessibility()) }

    /// When a turn's reading must be done (`ProcessInfo.systemUptime`): one deadline for the Accessibility probes and
    /// one for everything, shared by all the marks of a turn.
    public struct Deadlines: Sendable, Hashable {
        public var accessibility: TimeInterval
        public var overall: TimeInterval

        public init(accessibility: TimeInterval, overall: TimeInterval) {
            self.accessibility = accessibility
            self.overall = overall
        }
    }

    /// Deadlines for a turn starting now: `accessibilityBudget` of probing, then up to the recognizer's timeout of OCR.
    public func deadlines(from now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Deadlines {
        let accessibility = now + max(0, accessibilityBudget)
        return Deadlines(accessibility: accessibility, overall: accessibility + max(0, recognizer?.timeout ?? 0))
    }

    /// `region` is AppKit global. `screenshot` and `geometry` describe the display the mark is on (for OCR). With
    /// `deadlines`, probing stops at the Accessibility deadline and OCR gets only the time left before the overall one.
    public func harvest(region: CGRect, layout: DesktopLayout, screenshot: DrawingMediaImage? = nil, geometry: CaptureGeometry? = nil,
                        deadlines: Deadlines? = nil) async -> HighlightHarvest {
        var harvest = HighlightHarvest()
        if let accessibility, accessibility.isAvailable {
            harvest = Self.probeGrid(region: region, layout: layout, source: accessibility, maximumLines: maximumLines, maximumControls: maximumControls,
                                     until: deadlines?.accessibility)
        }
        var recognizer = self.recognizer
        if var limited = recognizer, let deadlines {
            let left = deadlines.overall - ProcessInfo.processInfo.systemUptime
            limited.timeout = min(limited.timeout, left)
            recognizer = left > 0.05 ? limited : nil
        }
        if harvest.lines.isEmpty, let recognizer, let screenshot, let geometry {
            let pixels = geometry.pixelRect(fromAppKitRect: region)
            let found = await recognizer.lines(in: screenshot, pixelRect: pixels)
            for (text, box) in found.prefix(maximumLines) {
                // Lines mostly outside the mark (picked up by the crop's margin) don't count.
                let inside = box.intersection(pixels)
                guard !inside.isNull, inside.width * inside.height >= 0.4 * box.width * box.height else { continue }
                harvest.lines.append(HighlightTextLine(text: text, frame: geometry.appKitRect(fromPixelRect: box), source: .ocr))
            }
        }
        return harvest
    }

    /// Accessibility at a grid of points over the region (up to 6×5 plus the centre), deduplicated. Stops early once
    /// `until` (`ProcessInfo.systemUptime`) has passed.
    static func probeGrid(region: CGRect, layout: DesktopLayout, source: any HighlightAccessibilitySource, maximumLines: Int, maximumControls: Int,
                          until: TimeInterval? = nil) -> HighlightHarvest {
        let columns = min(6, max(2, Int(region.width / 40))), rows = min(5, max(1, Int(region.height / 24)))
        var points = [CGPoint(x: region.midX, y: region.midY)]
        for row in 0..<rows {
            for column in 0..<columns {
                points.append(CGPoint(x: region.minX + region.width * (CGFloat(column) + 0.5) / CGFloat(columns),
                                      y: region.minY + region.height * (CGFloat(row) + 0.5) / CGFloat(rows)))
            }
        }
        var harvest = HighlightHarvest()
        var seenLines = Set<String>(), seenControls = Set<String>()
        let grown = region.insetBy(dx: -6, dy: -6)
        for point in points {
            if let until, ProcessInfo.processInfo.systemUptime >= until { break }
            guard let probe = source.probe(atQuartz: layout.quartzPoint(fromAppKit: point)) else { continue }
            let frame = probe.frame.map { layout.appKitRect(fromQuartz: $0) }
            if let text = probe.line, let key = Optional(ElementLabelMatcher.normalize(text)), !key.isEmpty,
               harvest.lines.count < maximumLines, seenLines.insert(key).inserted {
                let lineFrame = probe.lineFrame.map { layout.appKitRect(fromQuartz: $0) } ?? frame ?? CGRect(origin: point, size: .zero)
                harvest.lines.append(HighlightTextLine(text: text, frame: lineFrame, source: .accessibility))
            }
            let role = probe.role
            if ElementRoles.actionable.contains(role) || role == "AXHeading" || role == "AXImage" {
                guard let frame, !ElementRoles.containers.contains(role), frame.width < 900, frame.height < 600,
                      grown.contains(CGPoint(x: frame.midX, y: frame.midY)) || frame.contains(CGPoint(x: region.midX, y: region.midY)) else { continue }
                let kind = ElementRoles.friendlyName(role: role, subrole: probe.subrole)
                let label = probe.label.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
                let value = role == "AXLink" || role == "AXButton" ? nil : probe.value.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
                let key = "\(kind)|\(label ?? value ?? "")|\(Int(frame.minX)),\(Int(frame.minY))"
                guard harvest.controls.count < maximumControls, seenControls.insert(key).inserted, label != nil || value != nil || probe.url != nil else { continue }
                harvest.controls.append(HighlightControl(kind: kind, label: label ?? (role == "AXLink" ? probe.value : nil), value: value,
                                                         url: probe.url, frame: frame))
            } else if probe.line == nil, role == "AXStaticText", let text = probe.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, harvest.lines.count < maximumLines, seenLines.insert(ElementLabelMatcher.normalize(text)).inserted {
                harvest.lines.append(HighlightTextLine(text: String(text.prefix(300)), frame: frame ?? CGRect(origin: point, size: .zero), source: .accessibility))
            }
        }
        // Reading order: top to bottom (AppKit y is up), then left to right.
        harvest.lines.sort { abs($0.frame.midY - $1.frame.midY) > 4 ? $0.frame.midY > $1.frame.midY : $0.frame.minX < $1.frame.minX }
        return harvest
    }
}

extension DrawingMediaImage {
    /// A screenshot's JPEG or PNG bytes, decoded.
    public init?(encoded data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(image)
    }
}
