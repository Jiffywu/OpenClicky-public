import AppKit
import ImageIO
import OpenClickyKit
import PDFKit
import Quartz
import SwiftUI

// MARK: - Spreadsheet grid

/// A CSV/TSV grid: column letters and the header row stay frozen at the top while the rows scroll; row numbers on the
/// left. Click a cell to select it, shift-click to extend, click a column letter for the whole column; the bar at the
/// bottom shows Count, Sum and Average of the selection.
struct SpreadsheetGridView: View {
    let table: DelimitedTable
    @Binding var selection: GridSelection?

    private static let rowNumberWidth: CGFloat = 44
    private static let rowHeight: CGFloat = 24

    var body: some View {
        let widths = Self.columnWidths(table)
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(0..<table.bodyCount, id: \.self) { row in
                            HStack(spacing: 0) {
                                Text("\(row + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: Self.rowNumberWidth, height: Self.rowHeight)
                                    .background(Color.secondary.opacity(0.08))
                                ForEach(0..<table.columnCount, id: \.self) { column in
                                    bodyCell(GridCell(row: row, column: column), width: widths[column])
                                }
                            }
                        }
                    } header: {
                        frozenHeader(widths)
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text("\(table.bodyCount) row\(table.bodyCount == 1 ? "" : "s") · \(table.columnCount) column\(table.columnCount == 1 ? "" : "s")"
                     + (table.truncated ? " (first \(table.rows.count - 1) shown)" : ""))
                    .foregroundStyle(.secondary)
                Spacer()
                if let selection {
                    Text(GridSelectionSummary(table: table, selection: selection).text)
                        .monospacedDigit()
                } else {
                    Text("Select cells to see their sum").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// Column letters over the header row, pinned while the body scrolls.
    private func frozenHeader(_ widths: [CGFloat]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.rowNumberWidth, height: 18)
                ForEach(0..<table.columnCount, id: \.self) { column in
                    Text(DelimitedTable.columnName(column))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(selection?.columns.contains(column) == true ? Color.accentColor : Color.secondary)
                        .frame(width: widths[column], height: 18)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = .column(column, in: table) }
                }
            }
            HStack(spacing: 0) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.rowNumberWidth, height: Self.rowHeight)
                ForEach(0..<table.columnCount, id: \.self) { column in
                    Text(table.header[column])
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(width: widths[column], height: Self.rowHeight, alignment: .leading)
                        .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1) }
                }
            }
            .background(Color.secondary.opacity(0.14))
            Rectangle().fill(Color.secondary.opacity(0.45)).frame(height: 1)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func bodyCell(_ cell: GridCell, width: CGFloat) -> some View {
        let text = table.cell(cell)
        let selected = selection?.contains(cell) == true
        let numeric = GridSelectionSummary.number(text) != nil
        return Text(text.replacingOccurrences(of: "\n", with: " "))
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: width, height: Self.rowHeight, alignment: numeric ? .trailing : .leading)
            .background(selected ? Color.accentColor.opacity(0.22) : Color.clear)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1) }
            .contentShape(Rectangle())
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.shift), let current = selection {
                    selection = current.extended(to: cell)
                } else {
                    selection = GridSelection(cell)
                }
            }
            .help(text)
    }

    /// Widths from the longest text in each column's first rows, within reason.
    static func columnWidths(_ table: DelimitedTable) -> [CGFloat] {
        (0..<table.columnCount).map { column in
            let longest = table.rows.prefix(200).map { $0[column].count }.max() ?? 0
            return min(260, max(64, CGFloat(longest) * 7.5 + 16))
        }
    }
}

// MARK: - PDF

/// PDFKit's view: continuous pages, scaled to fit the width, with text selection and the system's find.
struct PDFPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

/// The same document's pages drawn by PDFKit into images, one under another. Offscreen renders use it: PDFView draws
/// its pages in tiles that never reach `cacheDisplay`.
struct PDFPageStackView: View {
    let url: URL

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if let document = PDFDocument(url: url) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        if let page = document.page(at: index) {
                            let bounds = page.bounds(for: .mediaBox)
                            let width: CGFloat = 560
                            let size = NSSize(width: width, height: width * bounds.height / max(bounds.width, 1))
                            Image(nsImage: page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .mediaBox))
                                .resizable()
                                .frame(width: size.width, height: size.height)
                                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: - Quick Look

/// Quick Look for everything without a native viewer: images, Office documents (XLSX included), Keynote, text, code,
/// audio and video.
struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem?.previewItemURL) != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

// MARK: - Animated images

/// Plays a GIF or APNG with each frame's own delay, looping. `frame` pins one frame (renders, tests).
struct AnimatedImageView: View {
    let url: URL
    var frame: Int?
    @ViewState private var frames: AnimatedFrames?

    var body: some View {
        Group {
            if let frames {
                if let frame {
                    Image(nsImage: frames.image(atIndex: min(frame, frames.count - 1))).resizable().scaledToFit()
                } else {
                    TimelineView(.animation(minimumInterval: frames.shortestDelay)) { context in
                        Image(nsImage: frames.image(at: context.date)).resizable().scaledToFit()
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear { if frames == nil { frames = AnimatedFrames(url: url) } }
    }
}

/// An animation's frame timing, with each frame decoded when it comes up (at most 600 frames play). Only the frame on
/// screen stays decoded: a long screen-recording GIF would otherwise hold gigabytes of pixels.
final class AnimatedFrames {
    let count: Int
    let delays: [Double]
    let total: Double
    let start = Date()
    private let source: CGImageSource
    private var current: (index: Int, image: NSImage)?

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let info = AnimatedImageReader.frames(url) else { return nil }
        let count = min(info.count, info.delays.count, 600)
        guard count > 0 else { return nil }
        self.source = source
        self.count = count
        delays = Array(info.delays.prefix(count))
        total = max(0.01, delays.reduce(0, +))
        guard decode(0) != nil else { return nil }
    }

    var shortestDelay: Double { max(0.02, delays.min() ?? 0.1) }

    /// How many frames are held decoded (one at most).
    var decodedFrameCount: Int { current == nil ? 0 : 1 }

    func image(at date: Date) -> NSImage { image(atIndex: index(at: date)) }

    /// The frame showing `date` seconds into the loop that began at `start`.
    func index(at date: Date) -> Int {
        var elapsed = max(0, date.timeIntervalSince(start)).truncatingRemainder(dividingBy: total)
        for (index, delay) in delays.enumerated() {
            if elapsed < delay { return index }
            elapsed -= delay
        }
        return count - 1
    }

    /// A frame, decoded now unless it is the one already showing; the last good frame when it can't be decoded.
    func image(atIndex index: Int) -> NSImage {
        if let current, current.index == index { return current.image }
        return decode(index) ?? current?.image ?? NSImage()
    }

    private func decode(_ index: Int) -> NSImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        let decoded = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        current = (index, decoded)
        return decoded
    }
}
