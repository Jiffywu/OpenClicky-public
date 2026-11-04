import AppKit
import CoreText
import ImageIO
import OpenClickyKit
import SwiftUI
import UniformTypeIdentifiers

/// `OpenClicky --render-preview-snapshots <folder>`: the preview pane for each kind of file (Markdown report and file,
/// CSV grid with a selection, PDF, animated GIF and APNG, Quick Look) and the result card's native Markdown, in light
/// and dark, from fixture files made in a temporary folder. Nothing is opened in another app.
@MainActor
enum PreviewSnapshots {
    static func run(into folder: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-previews-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let files = try Fixtures.write(into: root)
            try renderAll(files: files, into: folder)
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }

    static func renderAll(files: Fixtures.Files, into folder: URL) throws {
        func out(_ name: String) -> URL { folder.appendingPathComponent(name + ".png") }
        let card = Fixtures.card(files: files)
        let size = NSSize(width: 880, height: 600)
        let kinds: [(String, String)] = [
            ("report", "report"), ("markdown", files.markdown.path), ("csv", files.csv.path), ("pdf", files.pdf.path),
            ("gif", files.gif.path), ("apng", files.apng.path), ("quicklook", files.quickLook.path),
        ]
        for (name, id) in kinds {
            for dark in [false, true] {
                let model = FilePreviewModel(card: card)
                model.selectedID = id
                model.staticPDFPages = true
                if name == "csv" {
                    // Amount column, rows 2–5: the bar shows count, sum and average; the header stays out of it.
                    model.gridSelections[id] = GridSelection(anchor: GridCell(row: 1, column: 3), focus: GridCell(row: 4, column: 3))
                }
                try EvidenceSnapshots.render(FilePreviewPane(model: model), size: size, dark: dark,
                                             to: out("preview-\(name)\(dark ? "-dark" : "")"), settle: name == "pdf" || name == "quicklook" ? 1.5 : 0.5)
            }
        }
        // The result card with the report's blocks rendered natively.
        for dark in [false, true] {
            let model = AgentResultCardModel()
            model.show(card.report)
            try EvidenceSnapshots.render(AgentResultCardView(model: model).padding(20), size: NSSize(width: 420, height: 560), dark: dark,
                                         to: out("result-card-markdown\(dark ? "-dark" : "")"))
        }
    }

    enum Fixtures {
        struct Files {
            var markdown: URL
            var csv: URL
            var pdf: URL
            var gif: URL
            var apng: URL
            var quickLook: URL
        }

        static let report = """
            # Lisbon long weekend

            Three nights in **Alfama**, close to the tram and the river. Total so far: `€1,240`.

            ## Plan
            1. Friday: arrive, [Time Out Market](https://www.timeoutmarket.com) for dinner
            2. Saturday: Belém in the morning
               - Pastéis before 10 to skip the queue
               - Tower and monastery, one ticket
            3. Sunday: Sintra day trip

            ## Bookings
            | Item | Status | Cost |
            | :--- | :----: | ---: |
            | Flights | booked | €420 |
            | Hotel (3 nights) | booked | €690 |
            | Sintra train | to do | €13 |

            - [x] Passports checked
            - [ ] Reserve Sintra tickets

            > Tip: the 28 tram fills up by 10; walk the hill instead.

            ```text
            Check-in after 15:00, code at the door
            ```
            """

        static let csv = """
            Date,Merchant,Category,Amount
            2026-10-01,Pingo Doce,Groceries,42.18
            2026-10-02,"Uber, Lisbon",Transport,12.40
            2026-10-03,Time Out Market,Eating out,38.00
            2026-10-04,\"Livraria \"\"Bertrand\"\"\",Books,24.90
            2026-10-05,Netflix,Subscriptions,13.99
            2026-10-06,CP Sintra train,Transport,"2,600.00"
            2026-10-07,Farmácia,Health,9.75
            """

        static func write(into root: URL) throws -> Files {
            let output = root.appendingPathComponent("output", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let markdown = output.appendingPathComponent("trip-plan.md")
            try report.write(to: markdown, atomically: true, encoding: .utf8)
            let csvURL = output.appendingPathComponent("october-spending.csv")
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)
            let pdf = output.appendingPathComponent("itinerary.pdf")
            try writePDF(to: pdf)
            let gif = output.appendingPathComponent("route.gif")
            try writeAnimation(to: gif, type: .gif)
            let apng = output.appendingPathComponent("route-apng.png")
            try writeAnimation(to: apng, type: .png)
            let notes = output.appendingPathComponent("packing-list.txt")
            try "Packing list\n\n- Passport\n- Charger\n- Walking shoes\n- Light jacket for Sintra\n".write(to: notes, atomically: true, encoding: .utf8)
            return Files(markdown: markdown, csv: csvURL, pdf: pdf, gif: gif, apng: apng, quickLook: notes)
        }

        static func card(files: Files) -> AgentResultCard {
            let finished = Date(timeIntervalSince1970: 1_793_700_000)
            var report = AgentJobReport(jobID: "lisbon-weekend-0a1b2c3d", run: 1, title: "Lisbon weekend plan", agentName: "Trip Buddy",
                                        outcome: .done, spoken: "Your Lisbon weekend plan is ready, with bookings and a spending sheet.",
                                        markdown: Self.report,
                                        files: [files.markdown.path, files.csv.path, files.pdf.path, files.gif.path, files.apng.path, files.quickLook.path],
                                        nextSteps: ["Book the Sintra tickets", "Add a rainy-day plan"],
                                        startedAt: finished.addingTimeInterval(-340), finishedAt: finished)
            report.kind = .document
            return AgentResultCard(report: report)
        }

        /// A two-page PDF with a title and lines of text, drawn with Core Graphics.
        static func writePDF(to url: URL) throws {
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
            for page in 1...2 {
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(red: 0.13, green: 0.39, blue: 0.86, alpha: 1))
                context.fill(CGRect(x: 0, y: 712, width: 612, height: 80))
                draw("Lisbon itinerary · page \(page)", at: CGPoint(x: 48, y: 740), size: 26, color: .white, in: context)
                let lines = page == 1
                    ? ["Friday 7 Nov — arrive 14:05, TAP 1351", "Hotel Alfama Patio, check-in after 15:00", "Dinner: Time Out Market"]
                    : ["Saturday — Belém: pastéis, tower, monastery", "Sunday — Sintra: Pena Palace 10:30 slot", "Monday — fly home 11:40"]
                for (index, line) in lines.enumerated() {
                    draw(line, at: CGPoint(x: 48, y: 640 - CGFloat(index) * 34), size: 16, color: CGColor(gray: 0.15, alpha: 1), in: context)
                }
                context.endPDFPage()
            }
            context.closePDF()
        }

        static func draw(_ text: String, at point: CGPoint, size: CGFloat, color: CGColor, in context: CGContext) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = point
            CTLineDraw(line, context)
        }

        /// Eight frames of a dot moving along a route.
        static func writeAnimation(to url: URL, type: UTType) throws {
            let frames = 8
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let loop: [CFString: Any] = type == .gif ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
            CGImageDestinationSetProperties(destination, loop as CFDictionary)
            let space = CGColorSpaceCreateDeviceRGB()
            for frame in 0..<frames {
                guard let context = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.setFillColor(CGColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
                context.setStrokeColor(CGColor(red: 0.2, green: 0.45, blue: 0.85, alpha: 1))
                context.setLineWidth(4)
                context.move(to: CGPoint(x: 30, y: 40))
                context.addCurve(to: CGPoint(x: 290, y: 160), control1: CGPoint(x: 120, y: 190), control2: CGPoint(x: 200, y: 10))
                context.strokePath()
                let t = CGFloat(frame) / CGFloat(frames - 1)
                let x = 30 + 260 * t
                let y = 40 + 120 * t + 60 * sin(t * .pi)
                context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
                context.fillEllipse(in: CGRect(x: x - 10, y: y - 10, width: 20, height: 20))
                guard let image = context.makeImage() else { continue }
                let properties: [CFString: Any] = type == .gif ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.12]]
                    : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.12]]
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            }
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
