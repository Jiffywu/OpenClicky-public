import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Size limits for document text, so a huge log or a 900-page PDF can't stall a turn or flood the model.
public struct DocumentLimits: Sendable, Hashable {
    /// Characters of text kept (after cleaning).
    public var maxCharacters: Int
    /// Bytes read from the start of a plain-text file.
    public var maxTextBytes: Int
    /// Rich documents (RTF, Word, OpenDocument) larger than this are not parsed.
    public var maxRichDocumentBytes: Int
    /// PDF pages read.
    public var maxPDFPages: Int

    public init(maxCharacters: Int = 120_000, maxTextBytes: Int = 4 * 1024 * 1024, maxRichDocumentBytes: Int = 25 * 1024 * 1024,
                maxPDFPages: Int = 300) {
        self.maxCharacters = maxCharacters
        self.maxTextBytes = maxTextBytes
        self.maxRichDocumentBytes = maxRichDocumentBytes
        self.maxPDFPages = maxPDFPages
    }

    public static let standard = DocumentLimits()
}

public enum DocumentReadError: Error, Sendable, Equatable, CustomStringConvertible {
    /// macOS refused (Files & Folders or Full Disk Access denied).
    case accessDenied
    case notFound
    case unreadable(String)

    public var description: String {
        switch self {
        case .accessDenied: "macOS denied access to the file."
        case .notFound: "The file no longer exists."
        case .unreadable(let reason): "The file couldn't be read: \(reason)"
        }
    }
}

/// Text read from a file on disk.
public struct FileDocumentText: Sendable, Hashable {
    public var kind: ActiveDocument.Kind
    public var text: String?
    public var isTruncated: Bool
    public var pageCount: Int?
    public var byteCount: Int?
}

/// Reads the text of the file a document app has open: PDFs through PDFKit, rich documents through AppKit's
/// importers, HTML roughly, and anything that looks like text with a bounded read from the start.
public enum DocumentFileReader {
    public static func read(_ url: URL, limits: DocumentLimits = .standard) throws -> FileDocumentText {
        // The path comes from another app's AXDocument. Follow links, then read only regular files and packages: a
        // named pipe would block the open forever and a device would stream.
        let resolved = url.resolvingSymlinksInPath()
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        } catch {
            throw classify(error)
        }
        let byteCount = (attributes[.size] as? NSNumber)?.intValue
        let fileType = attributes[.type] as? FileAttributeType
        if fileType == .typeDirectory {
            // Packages (.rtfd, .pages, bundles) are directories.
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .rtfd) == true {
                return try readRich(resolved, type: .rtfd, byteCount: byteCount, limits: limits)
            }
            return FileDocumentText(kind: .file, text: nil, isTruncated: false, pageCount: nil, byteCount: byteCount)
        }
        guard fileType == .typeRegular else {
            return FileDocumentText(kind: .file, text: nil, isTruncated: false, pageCount: nil, byteCount: nil)
        }
        let url = resolved

        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true { return try readPDF(url, byteCount: byteCount, limits: limits) }
        if let type, let documentType = richDocumentType(for: type) {
            return try readRich(url, type: documentType, byteCount: byteCount, limits: limits)
        }
        if type?.conforms(to: .html) == true {
            var result = try readPlainText(url, byteCount: byteCount, limits: limits, requireTextLooking: false)
            if let text = result.text {
                let cut = ReadableText.truncate(ReadableText.textFromHTML(text), maxCharacters: limits.maxCharacters)
                result.text = cut.text
                result.isTruncated = result.isTruncated || cut.truncated
            }
            return result
        }
        let isDeclaredText = type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true
        if isDeclaredText || type == nil || !(type?.conforms(to: .image) == true || type?.conforms(to: .audiovisualContent) == true
            || type?.conforms(to: .archive) == true || type?.conforms(to: .executable) == true) {
            return try readPlainText(url, byteCount: byteCount, limits: limits, requireTextLooking: !isDeclaredText)
        }
        return FileDocumentText(kind: .file, text: nil, isTruncated: false, pageCount: nil, byteCount: byteCount)
    }

    static func richDocumentType(for type: UTType) -> NSAttributedString.DocumentType? {
        if type.conforms(to: .rtfd) { return .rtfd }
        if type.conforms(to: .rtf) { return .rtf }
        switch type.identifier {
        case "org.openxmlformats.wordprocessingml.document": return .officeOpenXML
        case "com.microsoft.word.doc": return .docFormat
        case "org.oasis-open.opendocument.text": return .openDocument
        case "com.microsoft.word.wordml": return .wordML
        default: return nil
        }
    }

    private static func readPlainText(_ url: URL, byteCount: Int?, limits: DocumentLimits, requireTextLooking: Bool) throws -> FileDocumentText {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw classify(error)
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: limits.maxTextBytes + 1) ?? Data()
        } catch {
            throw classify(error)
        }
        if requireTextLooking, !ReadableText.looksLikeText(data.prefix(8192)) {
            return FileDocumentText(kind: .file, text: nil, isTruncated: false, pageCount: nil, byteCount: byteCount)
        }
        let cutByBytes = data.count > limits.maxTextBytes
        let decoded = ReadableText.decodeTextPrefix(cutByBytes ? data.prefix(limits.maxTextBytes) : data, isComplete: !cutByBytes)
        let cut = ReadableText.truncate(decoded.replacingOccurrences(of: "\r\n", with: "\n"), maxCharacters: limits.maxCharacters)
        return FileDocumentText(kind: .textFile, text: cut.text, isTruncated: cutByBytes || cut.truncated, pageCount: nil, byteCount: byteCount ?? data.count)
    }

    private static func readPDF(_ url: URL, byteCount: Int?, limits: DocumentLimits) throws -> FileDocumentText {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw DocumentReadError.accessDenied }
        guard let document = PDFDocument(url: url) else { throw DocumentReadError.unreadable("not a readable PDF") }
        if document.isLocked { return FileDocumentText(kind: .pdf, text: nil, isTruncated: false, pageCount: document.pageCount, byteCount: byteCount) }
        var text = ""
        var truncated = false
        let pages = document.pageCount
        for index in 0..<pages {
            if index >= limits.maxPDFPages || text.count > limits.maxCharacters { truncated = true; break }
            guard let page = document.page(at: index), let pageText = page.string else { continue }
            if !text.isEmpty { text += "\n\n" }
            text += pageText
        }
        let cut = ReadableText.truncate(ReadableText.clean(text), maxCharacters: limits.maxCharacters)
        return FileDocumentText(kind: .pdf, text: cut.text, isTruncated: truncated || cut.truncated, pageCount: pages, byteCount: byteCount)
    }

    private static func readRich(_ url: URL, type: NSAttributedString.DocumentType, byteCount: Int?, limits: DocumentLimits) throws -> FileDocumentText {
        if let byteCount, byteCount > limits.maxRichDocumentBytes {
            return FileDocumentText(kind: .richText, text: nil, isTruncated: true, pageCount: nil, byteCount: byteCount)
        }
        let string: String
        do {
            string = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
        } catch {
            throw classify(error)
        }
        let cut = ReadableText.truncate(ReadableText.clean(string), maxCharacters: limits.maxCharacters)
        return FileDocumentText(kind: .richText, text: cut.text, isTruncated: cut.truncated, pageCount: nil, byteCount: byteCount)
    }

    /// Maps file-system errors to what the user needs to hear.
    static func classify(_ error: Error) -> DocumentReadError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError: return .accessDenied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound
            default: break
            }
        }
        if let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError) ?? (nsError.domain == NSPOSIXErrorDomain ? nsError : nil),
           posix.domain == NSPOSIXErrorDomain {
            if posix.code == Int(EPERM) || posix.code == Int(EACCES) { return .accessDenied }
            if posix.code == Int(ENOENT) { return .notFound }
        }
        return .unreadable(error.localizedDescription)
    }
}
