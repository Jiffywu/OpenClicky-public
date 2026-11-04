import CoreGraphics
import Foundation
import OpenClickyKit

enum FigureCommands {
    static let help = """
    Usage: occtl figure <program.js> <out.png> [options]
    Runs a figure() program (docs/dsl-3d.md) and renders its first figure offscreen with Metal.
      --look studio|illustrated   override the look the program chose
      --angle deg                 turntable angle (0 = front; default: the figure's own `turn`)
      --time s                    seconds of motion after everything is drawn (spins, ticks)
      --scale n                   pixels per point (default 2)
      --size WxH                  image size in points (default: the figure's rectangle)
      --background none|#RRGGBB   paper colour under the figure (default: warm paper)
      --figure id                 which figure, if the program draws several
      --no-labels                 leave out labels, leaders and readouts
    """

    static let figure = OcctlCommand(
        name: "figure",
        usage: "figure <program.js> <out.png> [--look studio|illustrated] [--angle deg]  render a 3D figure to PNG (--help for more)"
    ) { args in
        var positional: [String] = []
        var options = FigureSnapshot.Options()
        var index = 0
        func value(_ flag: String) -> String {
            index += 1
            guard index < args.count else { fail("\(flag) needs a value") }
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--look":
                guard let look = FigureLook(rawValue: value(arg)) else { fail("--look must be studio or illustrated") }
                options.look = look
            case "--angle":
                guard let angle = Float(value(arg)) else { fail("--angle needs degrees") }
                options.angle = angle
            case "--time":
                guard let time = Double(value(arg)) else { fail("--time needs seconds") }
                options.time = time
            case "--scale":
                guard let scale = Double(value(arg)), scale > 0, scale <= 4 else { fail("--scale must be in 0...4") }
                options.scale = scale
            case "--size":
                let parts = value(arg).split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2, parts.allSatisfy({ $0 >= 1 && $0.isFinite }) else { fail("--size needs WxH in points, each at least 1") }
                options.size = CGSize(width: parts[0], height: parts[1])
            case "--figure":
                options.figureID = value(arg)
            case "--background":
                let text = value(arg)
                if text == "none" { options.background = nil }
                else if let rgb = FigureColor.srgb(hex: text) { options.background = SIMD4(rgb, 1) }
                else { fail("--background must be none or #RRGGBB") }
            case "--no-labels":
                options.drawsLabels = false
            case "--help", "-h":
                print(Self.help)
                return
            default:
                if arg.hasPrefix("--") { fail("unknown option \(arg)") }
                positional.append(arg)
            }
            index += 1
        }
        guard positional.count == 2 else {
            fail("Usage: occtl figure <program.js> <out.png> [--look studio|illustrated] [--angle deg] [--time s] [--scale n] [--size WxH] [--background none|#RRGGBB] [--figure id] [--no-labels]")
        }
        let program = try String(contentsOf: URL(fileURLWithPath: positional[0]), encoding: .utf8)
        let started = Date()
        let harness = try FigureProgramHarness()
        let marks = harness.run(program)
        harness.warnings.forEach { print("warning: \($0)") }
        harness.errors.forEach { print("error: \($0)") }
        let bridge = harness.tickBridge
        let result = try FigureSnapshot.render(
            marks: marks, options: options,
            tick: { figure, ticks, dt in bridge.runTicks(figure: figure, ticks: ticks, dt: dt) },
            readouts: { bridge.takeReadouts() })
        guard let png = FigureSnapshot.pngData(result.image) else { fail("could not encode PNG") }
        try png.write(to: URL(fileURLWithPath: positional[1]))
        for (part, reason) in result.failures.sorted(by: { $0.key < $1.key }) { print("part \(part) failed: \(reason)") }
        let parts = result.scene.nodes.filter { !$0.isGroup }
        let vertices = parts.compactMap(\.mesh).reduce(0) { $0 + $1.vertexCount }
        print(String(format: "%@: %d parts, %d vertices, %@ look, %dx%d px in %.2f s -> %@",
                     result.scene.id, parts.count, vertices, result.frame.look.rawValue, result.image.width, result.image.height,
                     Date().timeIntervalSince(started), positional[1]))
    }
}
