import Foundation
@testable import OpenClickyKit

/// A short temporary bridge folder (Unix socket paths must stay under 104 bytes, so not under $TMPDIR).
func makeBridgePaths() throws -> BrowserBridgePaths {
    let directory = URL(fileURLWithPath: "/tmp/ocb-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
    let paths = BrowserBridgePaths(directory: directory)
    try paths.prepareDirectory()
    return paths
}

func removeBridgePaths(_ paths: BrowserBridgePaths) {
    try? FileManager.default.removeItem(at: paths.directory)
}

/// Polls `condition` until it is true or `timeout` passes. The timeout only guards against a hang; a busy machine can
/// take far longer than an idle one.
func eventually(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

/// Plays the Chrome extension: talks to a real `NativeHostRelay` over pipes standing in for the host's stdin/stdout,
/// records everything the host sends, answers pings, and optionally answers commands.
final class FakeExtension: @unchecked Sendable {
    let relay: NativeHostRelay
    private let toHost: FramedChannel
    private let fromHost: FramedChannel
    private let hostStdinRead: Int32
    private let hostStdoutWrite: Int32
    private let lock = NSLock()
    private var received: [JSONValue] = []
    private var exitCode: NativeHostRelay.Exit?
    /// Answers `command` messages; return nil to stay silent.
    var onCommand: (@Sendable (JSONValue) -> JSONValue?)?

    init(paths: BrowserBridgePaths, origin: String = ChromeExtensionIdentity.origin(for: ChromeExtensionIdentity.extensionID),
         allowedIDs: [String] = [ChromeExtensionIdentity.extensionID], browser: String = "com.google.Chrome") {
        signal(SIGPIPE, SIG_IGN)
        var stdinPipe: [Int32] = [0, 0]
        var stdoutPipe: [Int32] = [0, 0]
        pipe(&stdinPipe)
        pipe(&stdoutPipe)
        hostStdinRead = stdinPipe[0]
        hostStdoutWrite = stdoutPipe[1]
        toHost = FramedChannel(readFD: stdinPipe[1], writeFD: stdinPipe[1], ownsDescriptors: true)
        fromHost = FramedChannel(readFD: stdoutPipe[0], writeFD: stdoutPipe[0], ownsDescriptors: true)
        relay = NativeHostRelay(configuration: .init(origin: origin, allowedExtensionIDs: allowedIDs, paths: paths,
                                                     browserBundleID: browser, retryDelay: 0.1),
                                input: hostStdinRead, output: hostStdoutWrite)
        Thread.detachNewThread { [self] in
            let code = relay.run()
            lock.withLock { exitCode = code }
            // Give the relay's app thread a moment to notice the stop before its descriptors go away.
            Thread.sleep(forTimeInterval: 0.5)
            Darwin.close(hostStdoutWrite)
            Darwin.close(hostStdinRead)
        }
        Thread.detachNewThread { [self] in readLoop() }
    }

    private func readLoop() {
        while let message = try? fromHost.read() {
            lock.withLock { received.append(message) }
            switch message["type"]?.stringValue {
            case "ping":
                try? toHost.write(["type": "pong"])
            case "command":
                if let reply = lock.withLock({ onCommand })?(message) { try? toHost.write(reply) }
            default:
                break
            }
        }
    }

    func send(_ message: JSONValue) throws { try toHost.write(message) }

    func sendHello(profile: String = "8a6e0c55-3f1b-4f7a-9d44-0b1c2d3e4f50") throws {
        try send(["type": "hello", "protocol": 1, "profileId": .string(profile), "version": "0.1.0"])
    }

    var messages: [JSONValue] { lock.withLock { received } }
    var exit: NativeHostRelay.Exit? { lock.withLock { exitCode } }

    /// The most recent `ready.app` value, if any.
    var appReachable: Bool? { messages.last { $0["type"]?.stringValue == "ready" }?["app"]?.boolValue }

    /// Closes the host's stdin, as Chrome does when the extension disconnects.
    func disconnect() { toHost.close() }

    /// A canned answer for each operation, shaped like the real extension's results.
    static func standardReply(_ command: JSONValue) -> JSONValue {
        let id = command["id"] ?? .null
        let args = command["args"] ?? .object([:])
        let result: JSONValue
        switch command["operation"]?.stringValue {
        case "tabs":
            result = ["tabs": [["id": 7, "windowId": 1, "title": "Test page", "url": "http://127.0.0.1/test", "active": true, "focused": true]]]
        case "read":
            result = [
                "tabId": 7, "title": "Test page", "url": "http://127.0.0.1/test", "text": "Hello from the test page.",
                "textTruncated": false, "elementsOmitted": 0,
                "elements": [
                    ["ref": "e1", "role": "textbox", "name": "Your name"],
                    ["ref": "e2", "role": "button", "name": "Say hello"],
                ],
            ]
        case "click":
            result = ["tabId": 7, "note": .string("Clicked [\(args["ref"]?.stringValue ?? "?")] button \"Say hello\"."),
                      "navigated": false, "title": "Test page", "url": "http://127.0.0.1/test"]
        case "screenshot":
            result = ["tabId": 7, "mimeType": "image/jpeg", "data": .string(Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()),
                      "title": "Test page", "url": "http://127.0.0.1/test"]
        case "fail":
            return ["type": "result", "id": id, "ok": false, "error": "Ref e9 is unknown."]
        default:
            result = ["tabId": 7, "note": "done"]
        }
        return ["type": "result", "id": id, "ok": true, "result": result]
    }
}
