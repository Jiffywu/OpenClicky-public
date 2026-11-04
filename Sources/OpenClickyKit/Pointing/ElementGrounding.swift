import CoreGraphics
import Foundation

// One-shot element grounding (03 §6.8, parity row point-grounding): a screenshot resized to a computer-use resolution
// goes to a model with Anthropic's computer tool, which answers with one click point (or with no element at all for
// a general question); the point is mapped back to AppKit points. The app uses it as a fallback when a guided target
// names an element the turn's list doesn't have, or when neither the element list nor Accessibility finds a control
// at the brain's box (docs/guided.md, "Grounding").

/// The screen sizes computer-use models are trained on. A screenshot is resized to the one whose shape is closest.
public enum GroundingResolution: String, Sendable, CaseIterable {
    /// 4:3.
    case xga = "1024x768"
    /// 16:10, most Mac displays.
    case wxga = "1280x800"
    /// About 16:9.
    case fwxga = "1366x768"

    public var size: (width: Int, height: Int) {
        switch self {
        case .xga: (1024, 768)
        case .wxga: (1280, 800)
        case .fwxga: (1366, 768)
        }
    }

    public var aspect: Double { Double(size.width) / Double(size.height) }

    /// The resolution whose aspect ratio is nearest the screenshot's (compared as log ratios, so 4:3 and 16:9 are
    /// judged alike from either side). Ties go to the larger resolution.
    public static func nearest(toWidth width: Double, height: Double) -> GroundingResolution {
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return .wxga }
        let aspect = width / height
        return allCases.min { a, b in
            let da = abs(log(a.aspect / aspect)), db = abs(log(b.aspect / aspect))
            if abs(da - db) > 1e-9 { return da < db }
            return a.size.width > b.size.width
        } ?? .wxga
    }
}

/// Maps a click point the model gave in the computer-use image back to the screenshot and to AppKit points.
public struct GroundingMapping: Sendable, Hashable {
    public var resolution: GroundingResolution
    /// The screenshot that was resized (its pixels and its display).
    public var geometry: CaptureGeometry

    public init(resolution: GroundingResolution, geometry: CaptureGeometry) {
        self.resolution = resolution
        self.geometry = geometry
    }

    /// The mapping for a screenshot: the nearest resolution to its shape.
    public init(geometry: CaptureGeometry) {
        self.init(resolution: .nearest(toWidth: Double(geometry.pixelWidth), height: Double(geometry.pixelHeight)), geometry: geometry)
    }

    /// A point in the computer-use image → the screenshot's pixels (top-left origin). Clamped to the image.
    public func screenshotPixel(fromModel point: CGPoint) -> CGPoint {
        let (w, h) = resolution.size
        let x = min(max(point.x, 0), CGFloat(w)), y = min(max(point.y, 0), CGFloat(h))
        return CGPoint(x: x * CGFloat(geometry.pixelWidth) / CGFloat(w), y: y * CGFloat(geometry.pixelHeight) / CGFloat(h))
    }

    /// A point in the computer-use image → AppKit global points (bottom-left origin), through the screenshot's
    /// geometry (the display's frame and its points per screenshot pixel; Retina scale doesn't enter it).
    public func appKitPoint(fromModel point: CGPoint) -> CGPoint {
        geometry.appKitPoint(fromPixel: screenshotPixel(fromModel: point))
    }
}

/// What the grounding model said.
public enum GroundingAnswer: Sendable, Hashable {
    /// It would click here (pixels of the computer-use image).
    case point(CGPoint)
    /// The question isn't about one element ("no specific element"), or the model gave no point. The text it wrote.
    case noElement(String)
}

/// A model that answers "where would you click for this?" on one image.
public protocol GroundingModel: Sendable {
    /// `image` is exactly `width` × `height` pixels (a computer-use resolution).
    func locate(image: DriveImage, question: String) async throws -> GroundingAnswer
}

/// The result of grounding a question on a screenshot.
public enum GroundingResult: Sendable, Hashable {
    case element(point: CGPoint, pixel: CGPoint, modelPoint: CGPoint, resolution: GroundingResolution)
    case noElement(String)

    /// The AppKit point, when an element was found.
    public var point: CGPoint? {
        if case .element(let point, _, _, _) = self { point } else { nil }
    }
}

public struct GroundingError: Error, CustomStringConvertible, Sendable, Hashable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Grounds a question on a screenshot: resizes it to the nearest computer-use resolution, asks the model for one
/// click point, and maps the answer back.
public struct ElementGrounder: Sendable {
    public var model: any GroundingModel
    /// Seconds before giving up on the model (the walkthrough doesn't wait longer than this for a fallback).
    public var timeout: TimeInterval

    public init(model: any GroundingModel, timeout: TimeInterval = 15) {
        self.model = model
        self.timeout = timeout
    }

    /// The image the model sees: the screenshot stretched to the resolution (the aspect is already the closest).
    public static func modelImage(_ screenshot: Data, resolution: GroundingResolution) throws -> DriveImage {
        let (w, h) = resolution.size
        let image = try ImageCoding.resized(try ImageCoding.decode(screenshot), width: w, height: h)
        return DriveImage(data: try ImageCoding.jpegData(image), pixelWidth: w, pixelHeight: h)
    }

    public func locate(_ question: String, screenshot: Data, geometry: CaptureGeometry) async throws -> GroundingResult {
        let mapping = GroundingMapping(geometry: geometry)
        let image = try Self.modelImage(screenshot, resolution: mapping.resolution)
        let model = self.model
        let answer = try await withThrowingTaskGroup(of: GroundingAnswer.self) { group in
            group.addTask { try await model.locate(image: image, question: question) }
            let limit = timeout
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                throw GroundingError("grounding took longer than \(Int(limit)) s")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        switch answer {
        case .noElement(let text):
            return .noElement(text)
        case .point(let point):
            return .element(point: mapping.appKitPoint(fromModel: point), pixel: mapping.screenshotPixel(fromModel: point),
                            modelPoint: point, resolution: mapping.resolution)
        }
    }
}

/// Grounding through Anthropic's computer tool on the Messages API: one request with the image and the question,
/// `max_tokens` 256, and the first click (or pointer move) the reply asks for. A reply with no click, or one that says
/// there is no specific element, is `.noElement`.
public struct AnthropicGroundingModel: GroundingModel {
    public let client: AnthropicMessagesClient
    public let metered: MeteredLanguageModelClient?
    public let model: String
    public let version: AnthropicComputerToolVersion

    public init(client: AnthropicMessagesClient, model: String, version: AnthropicComputerToolVersion? = nil,
                metered: MeteredLanguageModelClient? = nil) {
        self.client = client
        self.model = model
        self.version = version ?? AnthropicComputerToolVersion.preferred(forModel: model)
        self.metered = metered
    }

    /// The phrase the model is asked to answer with when the question isn't about one control.
    public static let noElementPhrase = "no specific element"

    static let system = """
    You find things on a Mac screen. You get one screenshot and a question or instruction from someone looking at it. \
    If it is about one particular control, menu item, field, link or spot on the screen, click that spot once with the \
    computer tool and write nothing else. If it is a general question that no single spot on the screen answers, don't \
    click: reply with exactly "\(noElementPhrase)".
    """

    public func request(image: DriveImage, question: String) -> AnthropicComputerUseRequest {
        let text = "Screenshot of the screen (\(image.pixelWidth) × \(image.pixelHeight) pixels). Question: \(question)"
        let message: JSONValue = [
            "role": "user",
            "content": [
                ["type": "image", "source": ["type": "base64", "media_type": .string(image.mimeType), "data": .string(image.data.base64EncodedString())]],
                ["type": "text", "text": .string(text)],
            ],
        ]
        return AnthropicComputerUseRequest(model: model, system: Self.system, messages: [message], version: version,
                                           displayWidth: image.pixelWidth, displayHeight: image.pixelHeight, zoom: false, maxTokens: 256)
    }

    public func locate(image: DriveImage, question: String) async throws -> GroundingAnswer {
        let request = request(image: image, question: question)
        let reply: AnthropicComputerUseReply
        if let metered {
            reply = try await metered.computerUseStep(request, on: client, surface: "grounding")
        } else {
            reply = try await client.computerUseStep(request)
        }
        return Self.answer(from: reply, version: version)
    }

    /// The first click-like action's coordinate, else no element.
    public static func answer(from reply: AnthropicComputerUseReply, version: AnthropicComputerToolVersion) -> GroundingAnswer {
        let pointing: Set<String> = ["left_click", "click", "double_click", "right_click", "mouse_move", "middle_click", "triple_click"]
        for use in reply.toolUses where use.isComputerAction(version) {
            guard pointing.contains(use.actionName(version)), let coordinate = use.input["coordinate"]?.arrayValue, coordinate.count == 2,
                  let x = coordinate[0].doubleValue, let y = coordinate[1].doubleValue, x.isFinite, y.isFinite else { continue }
            return .point(CGPoint(x: x, y: y))
        }
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .noElement(text.isEmpty ? noElementPhrase : text)
    }
}

extension EngineFactory {
    /// The grounding model from the config's optional `grounding` selection (an Anthropic Messages provider and a
    /// model that takes the computer tool). Nil when nothing is chosen; throws when the choice can't be built.
    public func elementGrounder(timeout: TimeInterval = 15) throws -> ElementGrounder? {
        guard let selection = config.grounding else { return nil }
        // Built like a brain slot (credential, retries, metering), from a copy of the config with this selection there.
        var copy = self
        copy.config.slots = [.brain: selection]
        let client: any LanguageModelClient
        do {
            client = try copy.languageModel(for: .brain)
        } catch let error as EngineFactoryError {
            throw GroundingError("The grounding model can't start: " + error.description.replacingOccurrences(of: "brain slot", with: "grounding choice"))
        }
        guard let anthropic = EngineFactory.unwrapped(client) as? AnthropicMessagesClient else {
            throw GroundingError("Grounding needs an Anthropic Messages provider (the computer tool); \(selection.provider) isn't one.")
        }
        let model = AnthropicGroundingModel(client: anthropic, model: selection.model, metered: client as? MeteredLanguageModelClient)
        return ElementGrounder(model: model, timeout: timeout)
    }
}
