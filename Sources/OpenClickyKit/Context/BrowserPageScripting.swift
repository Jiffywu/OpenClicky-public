import CoreServices
import Foundation

/// Browsers whose scripting dictionaries expose the current tab's address, title and (one way or another) text.
public enum ScriptableBrowser: String, Sendable, CaseIterable {
    case safari, safariTechnologyPreview, chrome, chromeBeta, chromeCanary, chromium, arc, edge, edgeBeta, brave, braveBeta, vivaldi

    public enum Family: Sendable { case safari, chromium }

    public var bundleIdentifier: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .safariTechnologyPreview: "com.apple.SafariTechnologyPreview"
        case .chrome: "com.google.Chrome"
        case .chromeBeta: "com.google.Chrome.beta"
        case .chromeCanary: "com.google.Chrome.canary"
        case .chromium: "org.chromium.Chromium"
        case .arc: "company.thebrowser.Browser"
        case .edge: "com.microsoft.edgemac"
        case .edgeBeta: "com.microsoft.edgemac.Beta"
        case .brave: "com.brave.Browser"
        case .braveBeta: "com.brave.Browser.beta"
        case .vivaldi: "com.vivaldi.Vivaldi"
        }
    }

    public init?(bundleIdentifier: String?) {
        guard let bundleIdentifier, let match = Self.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return nil }
        self = match
    }

    public var family: Family {
        switch self {
        case .safari, .safariTechnologyPreview: .safari
        default: .chromium
        }
    }
}

/// Recognizes web browsers, scriptable or not (the rest are read through Accessibility only).
public enum BrowserCatalog {
    static let otherBrowsers: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX", "company.thebrowser.dia", "com.kagi.kagimacOS",
        "com.duckduckgo.macos.browser", "com.openai.atlas", "ai.perplexity.comet", "org.torproject.torbrowser",
    ]

    public static func isBrowser(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return ScriptableBrowser(bundleIdentifier: bundleIdentifier) != nil || otherBrowsers.contains(bundleIdentifier)
    }
}

/// What a browser's scripting dictionary told us about its current tab.
public struct BrowserPageInfo: Sendable, Hashable {
    public var url: String
    public var title: String?
    public var text: String?
    /// The page had more text than the limit; `text` holds the start.
    public var textTruncated: Bool = false
    /// Why the page text couldn't be read by script (typically: "Allow JavaScript from Apple Events" is off).
    public var textError: String?
}

/// Builds the AppleScript that asks a browser about its front tab, and parses the answer.
///
/// The script returns one string: URL, title, text and text error separated by ASCII record separators (30), so
/// titles and page text can contain anything. Safari exposes a tab's text directly; Chromium browsers need
/// `execute javascript`, which works only after the user turns on "Allow JavaScript from Apple Events".
public enum BrowserPageScript {
    public static let separator: Character = "\u{1E}"

    /// JavaScript run in Chromium tabs: the rendered text of the page, capped in the page so a huge document isn't
    /// shipped across Apple Events whole.
    static func pageTextJavaScript(maxCharacters: Int) -> String {
        "(function(){var b=document.body;var t=b?(b.innerText||b.textContent||''):'';return t.length>\(maxCharacters)?t.slice(0,\(maxCharacters)):t;})()"
    }

    public static func source(for browser: ScriptableBrowser, includeText: Bool, maxCharacters: Int) -> String {
        let app = "application id \(literal(browser.bundleIdentifier))"
        let textBlock: String
        switch browser.family {
        case .safari:
            textBlock = includeText ? """
                    try
                        set pageText to (text of theTab) as text
                    on error errText
                        set textError to errText
                    end try
            """ : ""
            return wrap(app: app, tabExpression: "current tab of front window", urlProperty: "URL", titleProperty: "name", textBlock: textBlock)
        case .chromium:
            textBlock = includeText ? """
                    try
                        tell theTab to set pageText to (execute javascript \(literal(pageTextJavaScript(maxCharacters: maxCharacters + 1)))) as text
                    on error errText
                        set textError to errText
                    end try
            """ : ""
            return wrap(app: app, tabExpression: "active tab of front window", urlProperty: "URL", titleProperty: "title", textBlock: textBlock)
        }
    }

    private static func wrap(app: String, tabExpression: String, urlProperty: String, titleProperty: String, textBlock: String) -> String {
        """
        set sep to (character id 30)
        set pageURL to ""
        set pageTitle to ""
        set pageText to ""
        set textError to ""
        tell \(app)
            if (count of windows) is 0 then return ""
            set theTab to \(tabExpression)
            try
                set pageURL to (\(urlProperty) of theTab) as text
            end try
            try
                set pageTitle to (\(titleProperty) of theTab) as text
            end try
        \(textBlock)
        end tell
        return pageURL & sep & pageTitle & sep & pageText & sep & textError
        """
    }

    /// An AppleScript string literal.
    public static func literal(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// Parses the script's output. Nil when the browser had no window or no address.
    public static func parse(_ output: String, maxCharacters: Int) -> BrowserPageInfo? {
        var trimmed = output
        if trimmed.hasSuffix("\n") { trimmed.removeLast() }
        let fields = trimmed.split(separator: separator, maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard let rawURL = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty, rawURL != "missing value" else { return nil }
        func field(_ index: Int) -> String? {
            guard fields.count > index else { return nil }
            let value = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value == "missing value" ? nil : value
        }
        var info = BrowserPageInfo(url: rawURL, title: field(1), text: nil, textError: field(3))
        if let raw = field(2) {
            // The page-side cap returns one extra character, so a cut page can be told from one that fit exactly.
            let cut = ReadableText.truncate(ReadableText.clean(raw), maxCharacters: maxCharacters)
            info.text = cut.text
            info.textTruncated = cut.truncated
        }
        return info
    }
}

/// Runs AppleScript source and returns what it printed.
public protocol AppleScriptRunning: Sendable {
    func run(_ source: String, timeout: Duration) async throws -> String
}

public struct AppleScriptError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The Apple Event error number when the message carried one, e.g. -1743 (not permitted).
    public var code: Int?
    public var message: String

    public init(code: Int?, message: String) {
        self.code = code
        self.message = message
    }

    /// Reads the trailing "(-1743)" style code osascript appends to execution errors.
    public init(osascriptStderr: String) {
        let text = osascriptStderr.trimmingCharacters(in: .whitespacesAndNewlines)
        var code: Int?
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            code = Int(text[text.index(after: open)..<text.index(before: text.endIndex)])
        }
        self.init(code: code, message: text)
    }

    public var isPermissionDenied: Bool { code == -1743 }
    public static let timedOut = AppleScriptError(code: nil, message: "The browser didn't answer in time.")

    public var description: String { message }
}

/// Runs scripts with `/usr/bin/osascript` in a child process, so a hung browser can be abandoned at the timeout.
/// The child inherits this process's Automation permissions (macOS attributes them to the responsible app).
public struct OsascriptRunner: AppleScriptRunning {
    public init() {}

    public func run(_ source: String, timeout: Duration) async throws -> String {
        // One -e per line: nothing is written to the child's stdin, so it can't die on a broken pipe.
        let arguments = source.split(separator: "\n").flatMap { ["-e", String($0)] }
        let result = try await ChildProcess.run("/usr/bin/osascript", arguments: arguments, timeout: timeout)
        guard !result.timedOut else { throw AppleScriptError.timedOut }
        guard result.status == 0 else { throw AppleScriptError(osascriptStderr: String(decoding: result.stderr, as: UTF8.self)) }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

/// Reads a browser's front tab through its scripting dictionary.
public struct BrowserPageScripter: Sendable {
    public var runner: any AppleScriptRunning
    public var permission: @Sendable (String, Bool) -> AutomationPermission

    public init(runner: any AppleScriptRunning = OsascriptRunner(),
                permission: @escaping @Sendable (String, Bool) -> AutomationPermission = { AutomationPermission.status(forBundleIdentifier: $0, askIfNeeded: $1) }) {
        self.runner = runner
        self.permission = permission
    }

    public enum Outcome: Sendable, Equatable {
        case page(BrowserPageInfo)
        /// No window, or the tab has no address.
        case noPage
        case permission(AutomationPermission)
        /// The Automation prompt is up and the user hasn't answered within `promptTimeout`. The turn goes on without
        /// the page; the answer still counts for the next turn.
        case awaitingPrompt
        case failed(String)
    }

    /// `timeout` bounds the script; `promptTimeout` bounds how long the turn waits on a first-time Automation prompt
    /// (asking blocks until the user answers, so it runs on its own thread and is abandoned, not cancelled).
    public func read(_ browser: ScriptableBrowser, includeText: Bool, maxCharacters: Int, allowPrompt: Bool,
                     timeout: Duration = .seconds(3), promptTimeout: Duration = .seconds(3)) async -> Outcome {
        var access = permission(browser.bundleIdentifier, false)
        if access == .notDetermined, allowPrompt {
            let permission = self.permission, bundleIdentifier = browser.bundleIdentifier
            let ask = Task.detached(priority: .userInitiated) { permission(bundleIdentifier, true) }
            guard let answer = await ActiveDocumentReader.value(of: ask, timeout: promptTimeout) else { return .awaitingPrompt }
            access = answer
        }
        guard access == .granted else { return .permission(access) }
        do {
            let output = try await runner.run(BrowserPageScript.source(for: browser, includeText: includeText, maxCharacters: maxCharacters),
                                              timeout: timeout)
            guard let info = BrowserPageScript.parse(output, maxCharacters: maxCharacters) else { return .noPage }
            return .page(info)
        } catch let error as AppleScriptError where error.isPermissionDenied {
            return .permission(.denied)
        } catch {
            return .failed(String(describing: error))
        }
    }
}

// MARK: - Child processes

enum ChildProcess {
    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    /// Runs an executable with no input, collecting both outputs; kills it after `timeout`.
    static func run(_ executable: String, arguments: [String], timeout: Duration) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let box = ProcessBox(process)
        return try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()
            let collected = OutputCollector()
            group.enter()
            process.terminationHandler = { _ in group.leave() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            for (pipe, isError) in [(stdout, false), (stderr, true)] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    // Reading to the end on a separate thread keeps a big answer from filling the pipe and deadlocking.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    collected.set(data, isError: isError)
                    group.leave()
                }
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if box.process.isRunning {
                    collected.markTimedOut()
                    box.process.terminate()
                }
            }
            group.notify(queue: .global()) {
                let outputs = collected.snapshot()
                continuation.resume(returning: Result(status: box.process.terminationStatus, stdout: outputs.stdout, stderr: outputs.stderr,
                                                      timedOut: outputs.timedOut))
            }
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var timedOut = false

        func set(_ data: Data, isError: Bool) { lock.withLock { if isError { stderr = data } else { stdout = data } } }
        func markTimedOut() { lock.withLock { timedOut = true } }
        func snapshot() -> (stdout: Data, stderr: Data, timedOut: Bool) { lock.withLock { (stdout, stderr, timedOut) } }
    }
}
