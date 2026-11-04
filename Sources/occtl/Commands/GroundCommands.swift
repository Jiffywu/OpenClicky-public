import CoreGraphics
import Foundation
import OpenClickyKit

/// `occtl ground`: one-shot element grounding on a screenshot file (docs/guided.md, "Grounding").
enum GroundCommands {
    static let usage = """
        Usage: occtl ground [--config c.json] [--provider id --model m] --image shot.png [--display x,y,w,h] [--mark out.png] <question>
          Resizes the screenshot to the nearest computer-use resolution (1024x768, 1280x800 or 1366x768), asks the grounding
          model (the config's "grounding" choice, else --provider/--model, else the brain slot's) for one click point, and
          prints it in the model's pixels, the screenshot's pixels and AppKit points. --display is the display the
          screenshot shows, in AppKit points (default: one point per pixel at the origin). --mark writes the screenshot
          with the point marked.
        """

    static let command = OcctlCommand(name: "ground", usage: "ground --image shot.png <question>   locate one element with a computer-use model") { args in
        var configPath: String?
        var provider: String?
        var model: String?
        var imagePath: String?
        var display: CGRect?
        var mark: URL?
        var words: [String] = []
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            func value() -> String {
                guard let next = iterator.next() else { fail(usage) }
                return next
            }
            switch arg {
            case "--config": configPath = value()
            case "--provider": provider = value()
            case "--model": model = value()
            case "--image": imagePath = value()
            case "--mark": mark = URL(fileURLWithPath: value())
            case "--display":
                let numbers = value().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { fail("--display wants x,y,w,h in points") }
                display = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            default: words.append(arg)
            }
        }
        let question = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let imagePath, !question.isEmpty else { fail(usage) }
        let screenshot = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        guard let size = ImageCoding.pixelSize(of: screenshot) else { fail("Can't read \(imagePath) as an image.") }

        var config = try EngineCommands.loadConfig(configPath, fallback: .heyClickyLike)
        if let provider, let model {
            config.grounding = SlotSelection(provider: provider, model: model)
        } else if config.grounding == nil {
            config.grounding = config.slots[.brain]
        }
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models), credentials: CoreCommands.store)
        guard let grounder = try factory.elementGrounder(), let chosen = config.grounding else { fail("No grounding model is chosen.") }

        let frame = display ?? CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let geometry = CaptureGeometry(displayFrame: frame, pixelWidth: size.width, pixelHeight: size.height)
        let mapping = GroundingMapping(geometry: geometry)
        let (w, h) = mapping.resolution.size
        print("screenshot \(size.width)x\(size.height) px on a display at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) pt")
        print("computer-use resolution: \(w)x\(h); model \(chosen.provider) / \(chosen.model)")
        print("question: \(question)")
        let started = Date()
        let result = try await grounder.locate(question, screenshot: screenshot, geometry: geometry)
        let seconds = Date().timeIntervalSince(started)
        switch result {
        case .noElement(let text):
            print(String(format: "no element (%.2f s): %@", seconds, text))
        case .element(let point, let pixel, let modelPoint, _):
            print(String(format: "model point (%.0f, %.0f) of %dx%d → screenshot pixel (%.1f, %.1f) → AppKit (%.1f, %.1f)  [%.2f s]",
                         modelPoint.x, modelPoint.y, w, h, pixel.x, pixel.y, point.x, point.y, seconds))
            if let mark {
                try writeMarked(screenshot, at: pixel, to: mark)
                print("wrote \(mark.relativePath)")
            }
        }
    }

    /// The screenshot with a red ring and cross at `pixel`.
    static func writeMarked(_ screenshot: Data, at pixel: CGPoint, to url: URL) throws {
        let image = try ImageCoding.decode(screenshot)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let y = CGFloat(image.height) - pixel.y
        context.setStrokeColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.setLineWidth(3)
        context.strokeEllipse(in: CGRect(x: pixel.x - 14, y: y - 14, width: 28, height: 28))
        context.move(to: CGPoint(x: pixel.x - 22, y: y)); context.addLine(to: CGPoint(x: pixel.x + 22, y: y))
        context.move(to: CGPoint(x: pixel.x, y: y - 22)); context.addLine(to: CGPoint(x: pixel.x, y: y + 22))
        context.strokePath()
        guard let marked = context.makeImage() else { return }
        try ImageCoding.pngData(marked).write(to: url)
    }
}
