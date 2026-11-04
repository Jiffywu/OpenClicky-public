import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import OpenClickyKit
@testable import OpenClicky

/// The preview pane reads only the start of a long file, and says so, instead of loading all of it on the main thread.
@Suite @MainActor struct FilePreviewModelTests {
    func file(_ name: String, _ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func aLongMarkdownFileShowsItsStartAndANote() throws {
        let url = try file("notes.md", (1...200).map { "Paragraph \($0)\n" }.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = FilePreviewModel.Item(id: url.path, title: "notes.md", location: url.path, kind: .markdown)
        let model = FilePreviewModel(title: "Job", items: [item])
        model.markdownMaxBytes = 40
        guard case .markdown(let blocks, _) = model.content(for: item) else {
            Issue.record("expected Markdown")
            return
        }
        #expect(blocks == [.paragraph("Paragraph 1"), .paragraph("Paragraph 2"), .paragraph("Paragraph 3"), .rule,
                           .paragraph(FilePreviewModel.markdownCutNote)])

        let whole = FilePreviewModel(title: "Job", items: [item])
        guard case .markdown(let all, _) = whole.content(for: item) else {
            Issue.record("expected Markdown")
            return
        }
        #expect(all.count == 200, "a file under the default limit is read whole, with no note")
    }

    @Test func aLongSpreadsheetIsCutAtTheByteLimit() throws {
        let url = try file("data.csv", "a,b\n" + (1...500).map { "\($0),\($0 * 2)\n" }.joined())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = FilePreviewModel.Item(id: url.path, title: "data.csv", location: url.path, kind: .spreadsheet)
        let model = FilePreviewModel(title: "Job", items: [item])
        model.spreadsheetMaxBytes = 18
        guard case .spreadsheet(let table) = model.content(for: item) else {
            Issue.record("expected a spreadsheet")
            return
        }
        #expect(table.truncated)
        #expect(table.rows == [["a", "b"], ["1", "2"], ["2", "4"], ["3", "6"]])
    }

    @Test func anAnimationKeepsOnlyTheFrameOnScreenDecoded() throws {
        let frames = 6
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        for frame in 0..<frames {
            let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: Double(frame) / Double(frames - 1), green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.25]] as CFDictionary
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties)
        }
        #expect(CGImageDestinationFinalize(destination))

        let animation = try #require(AnimatedFrames(url: url))
        #expect(animation.count == frames)
        var reds: [Double] = []
        for index in 0..<frames {
            let image = animation.image(atIndex: index)
            let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
            reds.append(Double(try #require(pixels.colorAt(x: 8, y: 8)).redComponent))
            // Every frame used to be decoded up front and kept: 600 frames of a 1280x720 GIF held about 2 GB.
            #expect(animation.decodedFrameCount == 1)
        }
        #expect(reds == reds.sorted() && reds.first! < 0.1 && reds.last! > 0.9, "each index is its own frame: \(reds)")
        // Timing: 0.25 s per frame, looping.
        #expect(animation.index(at: animation.start) == 0)
        #expect(animation.index(at: animation.start.addingTimeInterval(0.6)) == 2)
        #expect(animation.index(at: animation.start.addingTimeInterval(1.5 + 0.3)) == 1, "the loop starts again after 1.5 s")
    }
}
