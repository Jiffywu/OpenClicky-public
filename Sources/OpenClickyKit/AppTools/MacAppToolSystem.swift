import AppKit
import Foundation

/// NSWorkspace-backed opening and app lookup. AppKit calls run on the main actor.
public struct MacWorkspace: AppToolWorkspace {
    public init() {}

    public func openInDefaultBrowser(_ url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        // Ask for the app that handles plain web links, so a page goes to the browser even when another app
        // (a meeting client, a music app) has claimed links to its own site.
        let browser: URL? = await MainActor.run {
            NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        }
        guard let browser else { return await open(url) }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }
    }

    public func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }

    public func revealInFinder(_ fileURL: URL) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return true
        }
    }

    public func isInstalled(bundleID: String) async -> Bool {
        await MainActor.run { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    }

    public func isRunning(bundleID: String) async -> Bool {
        await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    }
}

/// The general pasteboard.
public struct MacPasteboard: AppToolPasteboard {
    public init() {}

    public func copy(_ text: String) async -> Bool {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
    }
}

/// Runs AppleScript with `/usr/bin/osascript`, passing the source as one `-e` argument (argv, never a shell, so no
/// quoting issues; and no stdin pipe that could raise SIGPIPE if osascript is stopped before reading it).
///
/// Unlike the Kit's `OsascriptRunner`, it stops osascript as soon as the calling task is cancelled (a newer turn), so
/// a cancelled music request neither waits out the time limit nor keeps going. A child process keeps AppleScript off
/// the main thread and lets a stuck script be killed. macOS attributes the Automation permission to the responsible
/// app (OpenClicky), so the consent prompt names OpenClicky.
public struct CancellableOsascriptRunner: AppleScriptRunning {
    public var executable: URL

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/osascript")) {
        self.executable = executable
    }

    public func run(_ source: String, timeout: Duration) async throws -> String {
        let box = ProcessBox()
        let executable = executable
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try box.run(executable: executable, source: source, timeout: timeout) })
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// Owns one osascript process so cancellation and the timeout can stop it from another thread.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func terminate() {
        lock.withLock {
            cancelled = true
            if process?.isRunning == true { process?.terminate() }
        }
    }

    func run(executable: URL, source: String, timeout: Duration) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-e", source]
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors

        try lock.withLock {
            if cancelled { throw CancellationError() }
            self.process = process
            try process.run()
        }

        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if process.isRunning {
                    self.timedOut = true
                    process.terminate()
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: watchdog)

        // Read stderr on its own thread so a chatty script cannot fill one pipe while we wait on the other.
        let errorData = LockedData()
        let errorReader = DispatchGroup()
        errorReader.enter()
        DispatchQueue.global().async {
            errorData.set(errors.fileHandleForReading.readDataToEndOfFile())
            errorReader.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errorReader.wait()
        watchdog.cancel()

        let (wasCancelled, didTimeOut) = lock.withLock { (cancelled, timedOut) }
        if wasCancelled { throw CancellationError() }
        if didTimeOut { throw AppleScriptError.scriptTimedOut }
        guard process.terminationStatus == 0 else {
            throw AppleScriptError(osascriptStderr: String(decoding: errorData.get(), as: UTF8.self))
        }
        var text = String(decoding: outputData, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}
