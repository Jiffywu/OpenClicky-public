import AppKit
import OpenClickyKit
import SwiftUI

/// Markdown rendered natively, block by block (`MarkdownBlockParser`): headings, paragraphs with inline styling,
/// nested and task lists, code blocks with a copy button, tables, quotes, rules and images. Text is selectable.
/// `compact` is the result card's size: smaller headings and no copy buttons.
struct MarkdownDocumentView: View {
    let blocks: [MarkdownBlock]
    var compact = false
    /// Where relative image paths are resolved (the report's job folder or the file's folder).
    var baseURL: URL?
    /// Makes views only for the blocks scrolled into sight (the pane's long documents, inside a ScrollView).
    var lazy = false

    var body: some View {
        Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: compact ? 6 : 12) { blockViews }
            } else {
                VStack(alignment: .leading, spacing: compact ? 6 : 12) { blockViews }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var blockViews: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            MarkdownBlockView(block: block, compact: compact, baseURL: baseURL)
        }
    }

    /// Inline Markdown (bold, italics, code spans, links) as styled text; plain text when it doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let compact: Bool
    let baseURL: URL?

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownDocumentView.inline(text))
                .font(headingFont(level))
                .padding(.top, compact || level > 2 ? 0 : 4)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(MarkdownDocumentView.inline(text))
                .font(compact ? .callout : .body)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let list):
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        marker(item, ordered: list.ordered)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(MarkdownDocumentView.inline(item.text))
                            .strikethrough(item.checked == true, color: .secondary)
                            .foregroundStyle(item.checked == true ? Color.secondary : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
            .font(compact ? .callout : .body)
        case .code(let language, let text):
            CodeBlockView(language: language, text: text, compact: compact)
        case .table(let table):
            MarkdownTableView(table: table, compact: compact)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                MarkdownDocumentView(blocks: inner, compact: compact, baseURL: baseURL)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 4)
        case .image(let alt, let source):
            MarkdownImageView(alt: alt, source: source, baseURL: baseURL, compact: compact)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        if compact { return level <= 2 ? .callout.weight(.bold) : .callout.weight(.semibold) }
        switch level {
        case 1: return .title.weight(.bold)
        case 2: return .title2.weight(.semibold)
        case 3: return .title3.weight(.semibold)
        default: return .headline
        }
    }

    @ViewBuilder
    private func marker(_ item: MarkdownList.Item, ordered: Bool) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
        } else if ordered, let ordinal = item.ordinal {
            Text("\(ordinal).").monospacedDigit().foregroundStyle(.secondary)
        } else {
            Text(["•", "◦", "▪︎"][min(item.depth, 2)]).foregroundStyle(.secondary)
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let text: String
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact {
                HStack {
                    Text(language ?? "code").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy the code")
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(compact ? .caption : .callout, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.1)))
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let compact: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, text in
                        cell(text, column: column).font((compact ? Font.caption : .callout).weight(.semibold))
                            .background(Color.secondary.opacity(0.12))
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                            cell(text, column: column).font(compact ? .caption : .callout)
                                .background(index % 2 == 1 ? Color.secondary.opacity(0.05) : Color.clear)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment: Alignment = switch table.alignments.indices.contains(column) ? table.alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(MarkdownDocumentView.inline(text))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minWidth: 60, maxWidth: 280, alignment: alignment)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1) }
    }
}

private struct MarkdownImageView: View {
    let alt: String
    let source: String
    let baseURL: URL?
    let compact: Bool

    var body: some View {
        if let url = resolved, FileManager.default.fileExists(atPath: url.path) {
            if FilePreviewKind.classify(url.path) == .animatedImage {
                AnimatedImageView(url: url).frame(maxHeight: compact ? 120 : 360)
            } else if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: compact ? 120 : 360)
                    .accessibilityLabel(alt)
            } else {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Label(alt.isEmpty ? source : alt, systemImage: "photo").font(.callout).foregroundStyle(.secondary)
    }

    private var resolved: URL? {
        if source.hasPrefix("/") { return URL(fileURLWithPath: source) }
        if source.hasPrefix("file://") { return URL(string: source) }
        guard !source.contains("://"), let baseURL else { return nil }
        return baseURL.appendingPathComponent(source)
    }
}
