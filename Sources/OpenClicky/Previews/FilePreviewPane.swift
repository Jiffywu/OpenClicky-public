import AppKit
import Observation
import OpenClickyKit
import SwiftUI

/// What the preview pane holds for one job: its report and the files it listed, one selected at a time.
@MainActor
@Observable
final class FilePreviewModel {
    struct Item: Identifiable, Hashable {
        var id: String
        var title: String
        /// An absolute path or a web link; nil for the report.
        var location: String?
        var kind: FilePreviewKind
        /// The report's Markdown, for the report item.
        var markdown: String?
    }

    enum Content {
        case markdown([MarkdownBlock], base: URL?)
        case spreadsheet(DelimitedTable)
        case pdf(URL)
        case animatedImage(URL)
        case quickLook(URL)
        case link(URL)
        case missing(String)
    }

    var title: String
    private(set) var items: [Item]
    var selectedID: String?
    /// The spreadsheet selection, per item.
    var gridSelections: [String: GridSelection] = [:]
    /// Draw PDF pages as images instead of PDFView (offscreen renders, where PDFView's tiles never draw).
    @ObservationIgnored var staticPDFPages = false
    /// How much of a Markdown file or a spreadsheet is read; the rest is left for the app that opens it.
    @ObservationIgnored var markdownMaxBytes = PreviewText.markdownMaxBytes
    @ObservationIgnored var spreadsheetMaxBytes = PreviewText.spreadsheetMaxBytes
    @ObservationIgnored private var cache: [String: Content] = [:]

    init(title: String, items: [Item], selectedID: String? = nil) {
        self.title = title
        self.items = items
        self.selectedID = selectedID ?? items.first?.id
    }

    /// A job's report (when it has one) and its files, in the card's order.
    convenience init(card: AgentResultCard, selecting location: String? = nil) {
        var items: [Item] = []
        if !card.body.isEmpty {
            items.append(Item(id: "report", title: "Report", location: nil, kind: .markdown, markdown: card.body))
        }
        for location in card.report.files {
            let isLink = location.hasPrefix("http://") || location.hasPrefix("https://")
            let name = isLink ? (URL(string: location)?.host ?? location) : URL(fileURLWithPath: location).lastPathComponent
            items.append(Item(id: location, title: name, location: location, kind: FilePreviewKind.classify(location)))
        }
        self.init(title: card.title, items: items, selectedID: location ?? items.first(where: { $0.location != nil })?.id ?? items.first?.id)
    }

    var selected: Item? { items.first { $0.id == selectedID } }

    func content(for item: Item) -> Content {
        if let cached = cache[item.id] { return cached }
        let content = load(item)
        cache[item.id] = content
        return content
    }

    private func load(_ item: Item) -> Content {
        if let markdown = item.markdown { return .markdown(MarkdownBlockParser.parse(markdown), base: nil) }
        guard let location = item.location else { return .missing("Nothing to show.") }
        if item.kind == .link { return URL(string: location).map(Content.link) ?? .missing("That link can't be opened.") }
        let url = URL(fileURLWithPath: location)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing("\(url.lastPathComponent) isn't there any more.") }
        switch item.kind {
        case .markdown:
            guard let loaded = try? PreviewText.read(url, maxBytes: markdownMaxBytes) else { return .quickLook(url) }
            var blocks = MarkdownBlockParser.parse(loaded.text)
            if loaded.truncated { blocks += [.rule, .paragraph(Self.markdownCutNote)] }
            return .markdown(blocks, base: url.deletingLastPathComponent())
        case .spreadsheet:
            guard let table = try? DelimitedText.read(url, maxBytes: spreadsheetMaxBytes), table.columnCount > 0 else { return .quickLook(url) }
            return .spreadsheet(table)
        case .pdf: return .pdf(url)
        case .animatedImage: return .animatedImage(url)
        case .quickLook, .link: return .quickLook(url)
        }
    }

    static let markdownCutNote = "*The file is longer than this. Open it to see the rest.*"

    func open(_ item: Item) {
        guard let location = item.location else { return }
        if item.kind == .link, let url = URL(string: location) { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.open(URL(fileURLWithPath: location)) }
    }

    func reveal(_ item: Item) {
        guard let location = item.location, item.kind != .link else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location)])
    }

    /// The app that opens a file, for the button ("Open in Numbers").
    func openTitle(_ item: Item) -> String {
        guard let location = item.location else { return "Open" }
        if item.kind == .link { return "Open in Browser" }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: location)) else { return "Open" }
        return "Open in \(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))"
    }
}

/// The preview pane: the job's report and files on the left, the selected one on the right with Open and Show in
/// Finder above it.
struct FilePreviewPane: View {
    let model: FilePreviewModel

    var body: some View {
        HStack(spacing: 0) {
            if model.items.count > 1 {
                List(selection: Binding(get: { model.selectedID }, set: { model.selectedID = $0 })) {
                    ForEach(model.items) { item in
                        Label(item.title, systemImage: Self.symbol(item.kind, report: item.markdown != nil))
                            .lineLimit(1)
                            .tag(item.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 200)
                Divider()
            }
            if let item = model.selected {
                VStack(spacing: 0) {
                    header(item)
                    Divider()
                    content(item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .id(item.id)
            } else {
                Text("Nothing to preview.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func header(_ item: FilePreviewModel.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(item.kind, report: item.markdown != nil)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(item.markdown != nil ? "\(model.title) · report" : item.kind.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.location != nil {
                Button(model.openTitle(item)) { model.open(item) }
                if item.kind != .link {
                    Button { model.reveal(item) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func content(_ item: FilePreviewModel.Item) -> some View {
        switch model.content(for: item) {
        case .markdown(let blocks, let base):
            ScrollView {
                MarkdownDocumentView(blocks: blocks, baseURL: base, lazy: true)
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .spreadsheet(let table):
            SpreadsheetGridView(table: table, selection: Binding(get: { model.gridSelections[item.id] },
                                                                 set: { model.gridSelections[item.id] = $0 }))
        case .pdf(let url):
            if model.staticPDFPages { PDFPageStackView(url: url) } else { PDFPreviewView(url: url) }
        case .animatedImage(let url):
            AnimatedImageView(url: url).padding(20)
        case .quickLook(let url):
            QuickLookPreviewView(url: url)
        case .link(let url):
            VStack(spacing: 10) {
                Image(systemName: "globe").font(.system(size: 34)).foregroundStyle(.secondary)
                Text(url.absoluteString).font(.callout).textSelection(.enabled).multilineTextAlignment(.center)
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
            }
            .padding(30)
        case .missing(let why):
            Label(why, systemImage: "questionmark.folder").foregroundStyle(.secondary)
        }
    }

    static func symbol(_ kind: FilePreviewKind, report: Bool) -> String {
        if report { return "doc.richtext" }
        return switch kind {
        case .markdown: "doc.text"
        case .spreadsheet: "tablecells"
        case .pdf: "doc.richtext.fill"
        case .animatedImage: "photo.stack"
        case .quickLook: "eye"
        case .link: "link"
        }
    }
}

/// A normal, resizable window holding the preview pane for one job at a time.
@MainActor
final class FilePreviewWindow {
    static let shared = FilePreviewWindow()
    private var window: NSWindow?

    func show(_ model: FilePreviewModel) {
        let window = self.window ?? make()
        self.window = window
        window.title = model.title
        window.contentView = NSHostingView(rootView: FilePreviewPane(model: model).frame(minWidth: 520, minHeight: 360))
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("OpenClicky.FilePreview")
        return window
    }
}
