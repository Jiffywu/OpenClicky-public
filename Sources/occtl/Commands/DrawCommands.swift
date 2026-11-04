import CoreGraphics
import Foundation
import ImageIO
import OpenClickyKit

enum DrawCommands {
    static let usageText = """
        draw <program.js> <out.png> [--size WxH] [--at seconds] [--ink #RRGGBB] [--bg none|light|dark|split|mock|mock-dark|#RRGGBB|image.png]
             [--media live|fixture|off] [--media-delay seconds] [--services services.json] [--fixture-quotes] [--sound out.wav]
          --sound out.wav   also write the drawing's sounds (pen textures and accents), mixed, to a WAV file
          --media live      photos, places and icons from the lookup services (services.json; keys via occtl key or OPENCLICKY_KEY_*)
          --media fixture   made-up answers, no network
          --fixture-quotes  with --media live: answer stock() with a made-up quote (no market-data key needed)
        """

    static let draw = OcctlCommand(name: "draw", usage: "draw <program.js> <out.png> [--size WxH] [--at s]  render a drawing program to PNG") { args in
        var positional: [String] = []
        var size = (width: 1280.0, height: 832.0)
        var at: Double?
        var ink = "#3380FF"
        var background = "light"
        var mediaMode = "live"
        var mediaDelay = 0.0
        var servicesURL: URL?
        var fixtureQuotes = false
        var soundURL: URL?
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--size":
                guard let value = iterator.next(), let parsed = parseSize(value) else { fail("--size wants WxH, like 1280x832") }
                size = parsed
            case "--at":
                guard let value = iterator.next(), let seconds = Double(value), seconds >= 0 else { fail("--at wants seconds, like 2.5") }
                at = seconds
            case "--ink":
                guard let value = iterator.next(), DrawingColor(hex: value) != nil else { fail("--ink wants a colour like #3380FF") }
                ink = value
            case "--bg":
                guard let value = iterator.next() else { fail("--bg wants none, light, dark, split, mock, mock-dark, a colour or a PNG") }
                background = value
            case "--media":
                guard let value = iterator.next(), ["live", "fixture", "off"].contains(value) else { fail("--media wants live, fixture or off") }
                mediaMode = value
            case "--media-delay":
                guard let value = iterator.next(), let seconds = Double(value), seconds >= 0 else { fail("--media-delay wants seconds, like 1.2") }
                mediaDelay = seconds
            case "--services":
                guard let value = iterator.next() else { fail("--services wants a services.json path") }
                servicesURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--fixture-quotes":
                fixtureQuotes = true
            case "--sound":
                guard let value = iterator.next() else { fail("--sound wants a .wav path") }
                soundURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            default:
                if arg.hasPrefix("--") { fail("Unknown option \(arg)\nUsage: occtl \(usageText)") }
                positional.append(arg)
            }
        }
        guard positional.count == 2 else { fail("Usage: occtl \(usageText)") }
        let program = try String(contentsOf: URL(fileURLWithPath: positional[0]), encoding: .utf8)
        let output = URL(fileURLWithPath: positional[1])
        let shownPath = positional[1]
        let chosenSize = size, chosenAt = at, chosenInk = ink, chosenBackground = background

        // Media pieces ask for photos, places and quotes; find those requests and answer them before the rehearsal.
        var media: DrawingRehearsalMedia?
        var mediaLines: [String] = []
        let asked = try DrawingMediaPrefetch.requests(in: program, width: size.width, height: size.height)
        if !asked.isEmpty, mediaMode != "off" {
            let lookups: any DrawingMediaLookups
            if mediaMode == "fixture" {
                lookups = FixtureMediaLookups()
            } else {
                let config = try ServicesConfig.load(from: servicesURL ?? ServicesConfig.defaultURL)
                let services = LookupServices.make(config: config, credentials: CoreCommands.store)
                let live = LiveDrawingMediaLookups(services: services)
                lookups = fixtureQuotes ? MixedMediaLookups(live: live, quotes: FixtureMediaLookups()) : live
            }
            let started = Date()
            let (answered, results) = await DrawingRehearsalMedia.resolve(asked, with: lookups, delay: mediaDelay)
            media = answered
            mediaLines.append(String(format: "%d media request(s) answered (%@) in %.2f s:", asked.count, mediaMode, Date().timeIntervalSince(started)))
            for (request, resolution) in results {
                let what = request.query ?? request.symbol ?? request.host ?? ""
                let fields = resolution.fields
                var detail = fields["state"]?.stringValue ?? "?"
                if let reason = fields["reason"]?.stringValue { detail += ": \(reason)" }
                for key in ["title", "company", "address", "provider", "source", "price", "changePercent"] {
                    if let value = fields[key] { detail += ", \(key)=\(String((value.stringValue ?? value.jsonString()).prefix(70)))" }
                }
                mediaLines.append("  \(request.kind.rawValue) \"\(what)\" → \(detail)")
            }
        }
        let chosenMedia = media
        let chosenSound = soundURL

        let summary = try await MainActor.run { () throws -> String in
            var options = DrawingRehearsal.Options()
            options.width = chosenSize.width
            options.height = chosenSize.height
            options.at = chosenAt
            options.ink = chosenInk
            options.backdrop = try backdrop(chosenBackground)
            options.media = chosenMedia
            let result = try DrawingRehearsal.run(program: program, options: options)
            try DrawingSnapshot.writePNG(result.image, to: output)
            var lines = ["Wrote \(shownPath) (\(result.image.width)x\(result.image.height)) at t=\(String(format: "%.2f", result.time)) s."]
            lines.append("\(result.lines.count) spoken line(s), \(result.markCount) mark(s) painted" +
                         (result.finishedAt.map { String(format: ", finished drawing at %.2f s", $0) } ?? ", still drawing"))
            for (index, line) in result.lines.enumerated() { lines.append("  say \(index): \(line.text)") }
            for note in result.notes { lines.append("  note \(note.kind): \(note.text)") }
            for action in result.actions {
                let what = action.url?.absoluteString ?? action.text ?? ""
                lines.append("  action \(action.role.rawValue): \(what.prefix(80))")
            }
            if let chosenSound {
                try result.soundtrackWAV().write(to: chosenSound)
                lines.append("  sound: \(result.sounds.count) recipe(s) mixed into \(chosenSound.path)")
            }
            for warning in result.warnings { lines.append("  warning: \(warning)") }
            for error in result.errors { lines.append("  error: \(error)") }
            return lines.joined(separator: "\n")
        }
        for line in mediaLines { print(line) }
        print(summary)
    }

    static func parseSize(_ text: String) -> (width: Double, height: Double)? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w >= 16, h >= 16, w <= 8192, h <= 8192 else { return nil }
        return (w, h)
    }

    @MainActor
    static func backdrop(_ value: String) throws -> DrawingRehearsal.Backdrop {
        switch value {
        case "none", "transparent": return .none
        case "light": return .color("#F3F4F6")
        case "dark": return .color("#1D1F25")
        case "split": return .split
        case "mock": return .mockScreen(dark: false)
        case "mock-dark": return .mockScreen(dark: true)
        default:
            if DrawingColor(hex: value) != nil { return .color(value) }
            let url = URL(fileURLWithPath: value)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                fail("--bg: \(value) is not a known backdrop, a colour, or a readable image")
            }
            return .image(image)
        }
    }
}

/// Live lookups for photos, places and icons, with made-up quotes (for renders without a market-data key).
struct MixedMediaLookups: DrawingMediaLookups {
    let live: LiveDrawingMediaLookups
    let quotes: FixtureMediaLookups

    func photo(_ query: PhotoQuery) async throws -> DrawingPhoto { try await live.photo(query) }
    func place(_ query: PlaceQuery) async throws -> Place { try await live.place(query) }
    func map(around coordinate: PlaceCoordinate, size: CGSize) async -> DrawingMediaImage? { await live.map(around: coordinate, size: size) }
    func quote(symbol: String, range: QuoteRange) async throws -> MarketQuote { try await quotes.quote(symbol: symbol, range: range) }
    func favicon(host: String) async throws -> DrawingMediaImage { try await live.favicon(host: host) }
    func image(at url: URL) async throws -> DrawingMediaImage { try await live.image(at: url) }
}

/// Made-up answers for every media piece: flat-colour pictures, a fixed place and a gently rising quote. No network.
struct FixtureMediaLookups: DrawingMediaLookups {
    func photo(_ query: PhotoQuery) async throws -> DrawingPhoto {
        let url = URL(string: "https://fixture.invalid/photo.png")!
        return DrawingPhoto(image: Self.swatch("#7FA7D9", "#F2C46D"), result: ImageResult(imageURL: url, title: "Fixture photo", provider: "fixture"))
    }

    func place(_ query: PlaceQuery) async throws -> Place {
        Place(id: "fixture", name: query.text, coordinate: PlaceCoordinate(latitude: 37.7955, longitude: -122.3937),
              address: "Made-up address (fixture)", category: "Place")
    }

    func map(around coordinate: PlaceCoordinate, size: CGSize) async -> DrawingMediaImage? { Self.swatch("#DDE8D5", "#C9D9EC") }

    func quote(symbol: String, range: QuoteRange) async throws -> MarketQuote {
        let closes = (0..<48).map { i in 100 + Double(i) * 0.35 + sin(Double(i) / 3) * 1.6 }
        return MarketQuote(symbol: symbol, name: "\(symbol) (fixture quote)", currency: "USD", price: closes.last!,
                           change: closes.last! - closes.first!, changePercent: (closes.last! / closes.first! - 1) * 100,
                           previousClose: closes.first!, range: range, recentCloses: closes, startPrice: closes.first!)
    }

    func favicon(host: String) async throws -> DrawingMediaImage { Self.swatch("#3380FF", "#3380FF") }
    func image(at url: URL) async throws -> DrawingMediaImage { Self.swatch("#E7A86B", "#6B9E7F") }

    static func swatch(_ top: String, _ bottom: String) -> DrawingMediaImage {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(DrawingColor(hex: bottom)!.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 24))
        context.setFillColor(DrawingColor(hex: top)!.cgColor)
        context.fill(CGRect(x: 0, y: 24, width: 64, height: 24))
        return DrawingMediaImage(context.makeImage()!)
    }
}
