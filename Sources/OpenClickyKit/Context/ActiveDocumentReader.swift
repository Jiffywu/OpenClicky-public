import Foundation

public struct ActiveDocumentOptions: Sendable {
    public enum FolderPolicy: Sendable, Hashable {
        /// Read even the first time from a guarded folder; macOS shows its prompt and the read waits (up to
        /// `fileReadTimeout`, then the turn goes on without the text and the read finishes in the background).
        case readAndRecord
        /// Never trigger the prompt: skip files in guarded folders this process hasn't read from before.
        case skipFirstReads
    }

    public var includeText: Bool
    public var limits: DocumentLimits
    public var folderPolicy: FolderPolicy
    /// Allow the one-time Automation prompt for a browser ("OpenClicky wants to control Safari").
    public var allowAutomationPrompt: Bool
    public var fileReadTimeout: Duration
    public var webTextDeadline: Duration
    public var scriptTimeout: Duration
    /// How long a turn waits on the user to answer a first-time Automation prompt before going on without the page.
    public var automationPromptTimeout: Duration

    public init(includeText: Bool = true, limits: DocumentLimits = .standard, folderPolicy: FolderPolicy = .readAndRecord,
                allowAutomationPrompt: Bool = true, fileReadTimeout: Duration = .seconds(2), webTextDeadline: Duration = .milliseconds(1500),
                scriptTimeout: Duration = .seconds(3), automationPromptTimeout: Duration = .seconds(3)) {
        self.includeText = includeText
        self.limits = limits
        self.folderPolicy = folderPolicy
        self.allowAutomationPrompt = allowAutomationPrompt
        self.fileReadTimeout = fileReadTimeout
        self.webTextDeadline = webTextDeadline
        self.scriptTimeout = scriptTimeout
        self.automationPromptTimeout = automationPromptTimeout
    }

    /// For tools and tests: never shows a system prompt.
    public static let noPrompts = ActiveDocumentOptions(folderPolicy: .skipFirstReads, allowAutomationPrompt: false)
}

/// Reads files for the active-document reader. A seam so tests can avoid the disk.
public protocol DocumentFileSource: Sendable {
    func read(_ url: URL, limits: DocumentLimits) throws -> FileDocumentText
}

public struct DiskDocumentFileSource: DocumentFileSource {
    public init() {}
    public func read(_ url: URL, limits: DocumentLimits) throws -> FileDocumentText { try DocumentFileReader.read(url, limits: limits) }
}

/// Finds and reads the document in front of the user: the browser's current page (address, title, text) or the file a
/// document app has open (`AXDocument`).
public struct ActiveDocumentReader: Sendable {
    public var accessibility: any AccessibilityContextSource
    public var scripter: BrowserPageScripter
    public var files: any DocumentFileSource
    public var ledger: GuardedFolderLedger

    public init(accessibility: any AccessibilityContextSource, scripter: BrowserPageScripter = BrowserPageScripter(),
                files: any DocumentFileSource = DiskDocumentFileSource(), ledger: GuardedFolderLedger = GuardedFolderLedger()) {
        self.accessibility = accessibility
        self.scripter = scripter
        self.files = files
        self.ledger = ledger
    }

    /// The document, plus notes about anything skipped. `window` is the already-read focused window, if any.
    public func read(app: FrontAppInfo, window: FocusedWindowInfo?, options: ActiveDocumentOptions) async -> (document: ActiveDocument?, notes: [String]) {
        if BrowserCatalog.isBrowser(app.bundleIdentifier) {
            return await readWebPage(app: app, window: window, options: options)
        }
        if let url = window?.documentURL, url.isFileURL {
            return await readFile(url, options: options)
        }
        if let url = window?.documentURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return (ActiveDocument(kind: .webPage, reference: url.absoluteString, title: window?.title, source: .accessibility), [])
        }
        return (nil, [])
    }

    // MARK: Web pages

    func readWebPage(app: FrontAppInfo, window: FocusedWindowInfo?, options: ActiveDocumentOptions) async -> (document: ActiveDocument?, notes: [String]) {
        var notes: [String] = []
        let maxCharacters = options.limits.maxCharacters
        if let browser = ScriptableBrowser(bundleIdentifier: app.bundleIdentifier) {
            let outcome = await scripter.read(browser, includeText: options.includeText, maxCharacters: maxCharacters,
                                              allowPrompt: options.allowAutomationPrompt, timeout: options.scriptTimeout,
                                              promptTimeout: options.automationPromptTimeout)
            switch outcome {
            case .page(let info):
                var document = ActiveDocument(kind: .webPage, reference: info.url, title: info.title ?? window?.title, text: info.text,
                                              isTruncated: info.textTruncated, source: .scripting)
                if options.includeText, info.text?.isEmpty ?? true {
                    if let error = info.textError {
                        notes.append("\(app.name ?? "The browser") wouldn't hand over the page text by script (\(Self.shortened(error))). "
                                     + "For Chromium browsers, turn on View → Developer → Allow JavaScript from Apple Events.")
                    }
                    if let ax = accessibility.webPageText(pid: app.processIdentifier, deadline: options.webTextDeadline, maxCharacters: maxCharacters) {
                        document.text = ax.text
                        document.isTruncated = ax.truncated
                        notes.append("Page text came from the Accessibility tree.")
                    }
                }
                return (document, notes)
            case .noPage:
                return (nil, ["\(app.name ?? "The browser") has no page open."])
            case .permission(let status):
                notes.append(Self.automationNote(app: app, status: status))
            case .awaitingPrompt:
                notes.append("The Automation prompt for \(app.name ?? "the browser") hasn't been answered yet; reading the page without it this turn.")
            case .failed(let message):
                notes.append("Asking \(app.name ?? "the browser") for its page failed: \(Self.shortened(message))")
            }
        }
        // Accessibility fallback: the address bar and the web area's text.
        guard let address = accessibility.browserAddress(pid: app.processIdentifier) else {
            if !accessibility.isTrusted { notes.append("Accessibility permission is needed to read the browser's address bar.") }
            return (nil, notes)
        }
        var document = ActiveDocument(kind: .webPage, reference: address, title: window?.title, source: .accessibility)
        if options.includeText,
           let ax = accessibility.webPageText(pid: app.processIdentifier, deadline: options.webTextDeadline, maxCharacters: maxCharacters) {
            document.text = ax.text
            document.isTruncated = ax.truncated
        }
        return (document, notes)
    }

    static func automationNote(app: FrontAppInfo, status: AutomationPermission) -> String {
        let name = app.name ?? "the browser"
        switch status {
        case .denied: return "Automation permission for \(name) is off (System Settings → Privacy & Security → Automation)."
        case .notDetermined: return "Automation permission for \(name) hasn't been asked for yet; not prompting now."
        case .targetNotRunning: return "\(name) isn't running."
        case .granted: return ""
        case .unknown(let code): return "Couldn't check Automation permission for \(name) (\(code))."
        }
    }

    static func shortened(_ text: String) -> String {
        text.count > 160 ? String(text.prefix(157)) + "…" : text
    }

    // MARK: Files

    func readFile(_ url: URL, options: ActiveDocumentOptions) async -> (document: ActiveDocument?, notes: [String]) {
        var document = ActiveDocument(kind: Self.kindGuess(for: url), reference: url.path, title: url.lastPathComponent, source: .file)
        guard options.includeText else { return (document, []) }
        if let folder = ledger.firstReadFolder(for: url), options.folderPolicy == .skipFirstReads {
            document.awaitingFolderAccess = folder
            return (document, ["Not reading the file yet: the first read from \(folder.displayName) shows a macOS permission prompt."])
        }
        let files = self.files, ledger = self.ledger, limits = options.limits
        let read = Task.detached(priority: .userInitiated) { () -> Result<FileDocumentText, DocumentReadError> in
            do {
                let text = try files.read(url, limits: limits)
                ledger.recordSuccessfulRead(of: url)
                return .success(text)
            } catch let error as DocumentReadError {
                return .failure(error)
            } catch {
                return .failure(.unreadable(error.localizedDescription))
            }
        }
        guard let result = await Self.value(of: read, timeout: options.fileReadTimeout) else {
            let folder = ledger.classifier.folder(for: url)
            return (document, ["Reading the file took too long\(folder.map { " (probably waiting on the \($0.displayName) permission prompt)" } ?? ""); going on without its text."])
        }
        switch result {
        case .success(let text):
            document.kind = text.kind
            document.text = text.text
            document.isTruncated = text.isTruncated
            document.pageCount = text.pageCount
            document.byteCount = text.byteCount
            return (document, [])
        case .failure(.accessDenied):
            document.accessDenied = true
            if let folder = ledger.classifier.folder(for: url) { ledger.forget(folder) }
            return (document, ["macOS denied reading the file; allow it in System Settings → Privacy & Security → Files & Folders."])
        case .failure(let error):
            return (document, [error.description])
        }
    }

    static func kindGuess(for url: URL) -> ActiveDocument.Kind {
        switch url.pathExtension.lowercased() {
        case "pdf": .pdf
        case "rtf", "rtfd", "doc", "docx", "odt": .richText
        default: .file
        }
    }

    /// The task's value if it finishes within `timeout`, else nil (the task keeps running).
    static func value<T: Sendable>(of task: Task<T, Never>, timeout: Duration) async -> T? {
        let gate = FirstResultGate<T?>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task { gate.resolve(await task.value) }
            Task {
                try? await Task.sleep(for: timeout)
                gate.resolve(nil)
            }
        }
    }
}

/// Resumes a continuation with whichever result arrives first.
final class FirstResultGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var pending: T?
    private var done = false

    func install(_ continuation: CheckedContinuation<T, Never>) {
        let early: T? = lock.withLock {
            if done, let pending { self.pending = nil; return pending }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func resolve(_ value: T) {
        let target: CheckedContinuation<T, Never>? = lock.withLock {
            guard !done else { return nil }
            done = true
            if let continuation { self.continuation = nil; return continuation }
            pending = value
            return nil
        }
        target?.resume(returning: value)
    }
}
