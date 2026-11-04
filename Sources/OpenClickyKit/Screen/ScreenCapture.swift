import CoreGraphics
import Foundation

/// One display's screenshot, ready for a model, with everything needed to map the model's pixel answers back.
public struct ScreenCapture: Sendable, Hashable {
    /// Encoded image (JPEG unless `mimeType` says otherwise).
    public var imageData: Data
    public var mimeType: String
    /// 1-based number of this screen in the turn, in reading order (left to right). The model names screens by it.
    public var screenNumber: Int
    /// How many screens this turn captured.
    public var screenCount: Int
    /// True for the display the pointer is on: what the user is most likely asking about.
    public var isCursorScreen: Bool
    public var display: DisplayGeometry
    /// Size of the image in pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var capturedAt: Date

    public init(imageData: Data, mimeType: String = "image/jpeg", screenNumber: Int, screenCount: Int, isCursorScreen: Bool,
                display: DisplayGeometry, pixelWidth: Int, pixelHeight: Int, capturedAt: Date = Date()) {
        self.imageData = imageData
        self.mimeType = mimeType
        self.screenNumber = screenNumber
        self.screenCount = screenCount
        self.isCursorScreen = isCursorScreen
        self.display = display
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.capturedAt = capturedAt
    }

    /// The display frame in AppKit global points (bottom-left origin).
    public var displayFrame: CGRect { display.frame }
    public var pointWidth: Int { Int(display.frame.width.rounded()) }
    public var pointHeight: Int { Int(display.frame.height.rounded()) }

    /// Pixel ⇄ point ⇄ global mapping for this image.
    public var geometry: CaptureGeometry {
        CaptureGeometry(displayFrame: display.frame, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    /// A short caption that tells the model which screen this is and where the user's attention is.
    public var label: String {
        ScreenCapture.label(screenNumber: screenNumber, screenCount: screenCount, isCursorScreen: isCursorScreen,
                            pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    public static func label(screenNumber: Int, screenCount: Int, isCursorScreen: Bool, pixelWidth: Int, pixelHeight: Int) -> String {
        let size = "\(pixelWidth)×\(pixelHeight) px"
        if screenCount <= 1 { return "The user's screen, \(size). The pointer is on this screen." }
        let role = isCursorScreen ? "the pointer is here, so this is most likely what the user means" : "another display"
        return "Screen \(screenNumber) of \(screenCount), \(size): \(role)."
    }

    /// The image as a chat content part.
    public var contentPart: ContentPart { .image(data: imageData, mimeType: mimeType) }

    /// Metadata without the image bytes.
    public var jsonValue: JSONValue {
        [
            "screen": .number(Double(screenNumber)),
            "screenCount": .number(Double(screenCount)),
            "label": .string(label),
            "isCursorScreen": .bool(isCursorScreen),
            "mimeType": .string(mimeType),
            "bytes": .number(Double(imageData.count)),
            "pixelWidth": .number(Double(pixelWidth)),
            "pixelHeight": .number(Double(pixelHeight)),
            "pointWidth": .number(Double(pointWidth)),
            "pointHeight": .number(Double(pointHeight)),
            "displayFrame": display.frame.jsonValue,
            "display": display.jsonValue,
        ]
    }
}

extension Array where Element == ScreenCapture {
    /// The capture of the display under the pointer, else the first.
    public var cursorCapture: ScreenCapture? { first(where: \.isCursorScreen) ?? first }

    /// The capture a model's answer refers to: screen `number` (1-based) when given and valid, else the pointer's.
    public func capture(screen number: Int?) -> ScreenCapture? {
        if let number, let match = first(where: { $0.screenNumber == number }) { return match }
        return cursorCapture
    }

    /// Text and images for a user message: each image preceded by its label.
    public var contentParts: [ContentPart] {
        flatMap { [.text($0.label), $0.contentPart] }
    }
}
