import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Windows to leave out of OpenClicky's own screenshots: its pointer, captions and overlay panels, so the model never
/// sees (and talks about) OpenClicky itself.
public struct CaptureExclusion: Sendable, Hashable {
    /// `NSWindow.windowNumber` / `CGWindowID` values.
    public var windowNumbers: Set<Int>
    /// Every window owned by these apps.
    public var bundleIdentifiers: Set<String>

    public init(windowNumbers: Set<Int> = [], bundleIdentifiers: Set<String> = []) {
        self.windowNumbers = windowNumbers
        self.bundleIdentifiers = bundleIdentifiers
    }

    public static let none = CaptureExclusion()

    public func excludes(windowNumber: Int, bundleIdentifier: String?) -> Bool {
        if windowNumbers.contains(windowNumber) { return true }
        if let bundleIdentifier, bundleIdentifiers.contains(bundleIdentifier) { return true }
        return false
    }
}

public struct ScreenCaptureOptions: Sendable {
    public enum Displays: Sendable, Hashable {
        /// Every display (the pointer's display is flagged).
        case all
        /// Only the display under the pointer.
        case cursorOnly
    }

    public var displays: Displays
    public var longEdge: Int
    public var jpegQuality: Double
    /// Draw the system pointer into the picture, so the model sees where the user is pointing.
    public var showsCursor: Bool
    public var exclusion: CaptureExclusion
    /// Wait for the screen to stop changing first; nil captures immediately.
    public var settle: ScreenSettleSampler?

    public init(displays: Displays = .all, longEdge: Int = CaptureSizing.modelLongEdge, jpegQuality: Double = ImageCoding.defaultJPEGQuality,
                showsCursor: Bool = true, exclusion: CaptureExclusion = .none, settle: ScreenSettleSampler? = .quick) {
        self.displays = displays
        self.longEdge = longEdge
        self.jpegQuality = jpegQuality
        self.showsCursor = showsCursor
        self.exclusion = exclusion
        self.settle = settle
    }
}

public enum ScreenCaptureError: Error, CustomStringConvertible, Equatable {
    case permissionDenied
    case noDisplays
    case regionOffScreen
    case nothingCaptured(String)

    public var description: String {
        switch self {
        case .permissionDenied:
            "Screen Recording permission is missing. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .noDisplays: "No display is available to capture."
        case .regionOffScreen: "That region is not on any display."
        case .nothingCaptured(let reason): "No display could be captured: \(reason)"
        }
    }
}

/// Takes screenshots. Production uses ScreenCaptureKit; tests use fakes.
public protocol ScreenCapturing: Sendable {
    func capture(_ options: ScreenCaptureOptions) async throws -> [ScreenCapture]
}

/// Screen Recording permission, checked without ever showing the system prompt.
public enum ScreenRecordingAccess {
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }
}

/// Which displays a turn captures, in what order, how they are numbered and how big each image is. Pure, so the
/// numbering and sizing rules are testable without a screen.
public struct ScreenCapturePlan: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var display: DisplayGeometry
        public var screenNumber: Int
        public var screenCount: Int
        public var isCursorScreen: Bool
        public var pixelWidth: Int
        public var pixelHeight: Int
    }

    public var entries: [Entry]

    public init(layout: DesktopLayout, cursor: CGPoint, displays: ScreenCaptureOptions.Displays, longEdge: Int,
                capturable: Set<UInt32>? = nil) {
        let candidates = layout.readingOrder.filter { capturable?.contains($0.id) ?? true }
        let cursorID = DesktopLayout(displays: candidates).display(nearest: cursor)?.id
        let chosen = displays == .cursorOnly ? candidates.filter { $0.id == cursorID } : candidates
        entries = chosen.enumerated().map { index, display in
            let size = CaptureSizing.pixelSize(pointSize: display.frame.size, scale: display.scale, longEdge: longEdge)
            return Entry(display: display, screenNumber: index + 1, screenCount: chosen.count, isCursorScreen: display.id == cursorID,
                         pixelWidth: size.width, pixelHeight: size.height)
        }
    }

    public var cursorEntry: Entry? { entries.first(where: \.isCursorScreen) }
}

/// ScreenCaptureKit one-shot screenshots (`SCScreenshotManager`, macOS 14+). Needs Screen Recording permission for the
/// process (or, for `occtl`, for the terminal app that runs it).
public struct ScreenCaptureKitCapturer: ScreenCapturing {
    public var layout: @Sendable () -> DesktopLayout
    public var cursor: @Sendable (DesktopLayout) -> CGPoint

    public init(layout: @escaping @Sendable () -> DesktopLayout = { DesktopLayout.current() },
                cursor: @escaping @Sendable (DesktopLayout) -> CGPoint = { DesktopLayout.currentCursorLocation(in: $0) }) {
        self.layout = layout
        self.cursor = cursor
    }

    public func capture(_ options: ScreenCaptureOptions) async throws -> [ScreenCapture] {
        guard ScreenRecordingAccess.isGranted else { throw ScreenCaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let scDisplays = Dictionary(content.displays.map { ($0.displayID, $0) }, uniquingKeysWith: { a, _ in a })
        guard !scDisplays.isEmpty else { throw ScreenCaptureError.noDisplays }
        let excluded = content.windows.filter {
            options.exclusion.excludes(windowNumber: Int($0.windowID), bundleIdentifier: $0.owningApplication?.bundleIdentifier)
        }

        let layout = layout()
        let plan = ScreenCapturePlan(layout: layout, cursor: cursor(layout), displays: options.displays, longEdge: options.longEdge,
                                     capturable: Set(scDisplays.keys))
        guard !plan.entries.isEmpty else { throw ScreenCaptureError.noDisplays }

        if let settle = options.settle, let entry = plan.cursorEntry, let display = scDisplays[entry.display.id] {
            let sampler = SettleSampleSource(display: display, excluded: excluded, aspect: entry.display.frame.size)
            _ = await settle.waitForSettle(sample: { try await sampler.sample() })
        }

        var captures: [ScreenCapture] = []
        var failures: [String] = []
        for entry in plan.entries {
            guard let display = scDisplays[entry.display.id] else { continue }
            do {
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let configuration = SCStreamConfiguration()
                configuration.width = entry.pixelWidth
                configuration.height = entry.pixelHeight
                configuration.showsCursor = options.showsCursor
                configuration.scalesToFit = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                // ScreenCaptureKit may round the size; record what the image really is.
                let data = try ImageCoding.jpegData(image, quality: options.jpegQuality)
                captures.append(ScreenCapture(imageData: data, screenNumber: entry.screenNumber, screenCount: entry.screenCount,
                                              isCursorScreen: entry.isCursorScreen, display: entry.display,
                                              pixelWidth: image.width, pixelHeight: image.height))
            } catch {
                failures.append("display \(entry.display.id): \(error.localizedDescription)")
            }
        }
        guard !captures.isEmpty else { throw ScreenCaptureError.nothingCaptured(failures.joined(separator: "; ")) }
        return captures
    }

    /// A region of the screen at full Retina resolution, as PNG (for "capture this area" gestures).
    /// `rect` is in AppKit global points and must lie on one display.
    public func captureRegion(_ rect: CGRect, exclusion: CaptureExclusion = .none) async throws -> (png: Data, width: Int, height: Int) {
        guard ScreenRecordingAccess.isGranted else { throw ScreenCaptureError.permissionDenied }
        let layout = layout()
        guard let geometry = layout.display(containing: CGPoint(x: rect.midX, y: rect.midY)) else { throw ScreenCaptureError.regionOffScreen }
        let local = layout.localRect(fromAppKit: rect, in: geometry).intersection(CGRect(origin: .zero, size: geometry.frame.size))
        guard !local.isNull, local.width >= 1, local.height >= 1 else { throw ScreenCaptureError.regionOffScreen }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == geometry.id }) else { throw ScreenCaptureError.noDisplays }
        let excluded = content.windows.filter {
            exclusion.excludes(windowNumber: Int($0.windowID), bundleIdentifier: $0.owningApplication?.bundleIdentifier)
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = local
        configuration.width = max(1, Int((local.width * geometry.scale).rounded()))
        configuration.height = max(1, Int((local.height * geometry.scale).rounded()))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: excluded),
                                                               configuration: configuration)
        return (try ImageCoding.pngData(image), image.width, image.height)
    }
}

/// Takes the small, pointer-free grayscale samples the settle check compares.
private final class SettleSampleSource: @unchecked Sendable {
    // ScreenCaptureKit objects are not Sendable; this source is used by one task at a time.
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration

    init(display: SCDisplay, excluded: [SCWindow], aspect: CGSize) {
        filter = SCContentFilter(display: display, excludingWindows: excluded)
        let width = CaptureSizing.settleSampleWidth
        configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = max(1, Int((Double(width) * aspect.height / max(aspect.width, 1)).rounded()))
        configuration.showsCursor = false
    }

    func sample() async throws -> GrayThumbnail {
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let thumbnail = GrayThumbnail(image: image) else { throw ImageCoding.Failure.resizeFailed }
        return thumbnail
    }
}
