import Foundation
import OpenClickyKit

// Chrome native-messaging host for the OpenClicky browser extension.
// Chrome starts it with the caller's origin (chrome-extension://<id>/) as the first argument and exchanges
// length-prefixed JSON over stdin/stdout. The relay logic lives in OpenClickyKit (NativeHostRelay) so it is tested
// without a browser; this file only wires the process up.

signal(SIGPIPE, SIG_IGN)

let paths = BrowserBridgePaths.standard
let origin = CommandLine.arguments.dropFirst().first { $0.hasPrefix("chrome-extension://") } ?? ""

func log(_ message: String) {
    FileHandle.standardError.write(Data("OpenClickyBrowserHost: \(message)\n".utf8))
}

/// Opens OpenClicky: the app bundle this host sits in, else by bundle ID, else via its URL scheme.
func openApp() {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    var arguments: [String]
    if let range = executable.range(of: ".app/Contents/") {
        arguments = ["-a", String(executable[..<range.lowerBound]) + ".app", "openclicky://settings/browser"]
    } else {
        arguments = ["-b", "com.openclicky.app"]
    }
    for attempt in [arguments, ["openclicky://settings/browser"]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = attempt
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return }
        } catch {
            continue
        }
    }
}

let relay = NativeHostRelay(configuration: .init(
    origin: origin,
    allowedExtensionIDs: ChromeExtensionIdentity.allowedIDs(paths: paths),
    paths: paths,
    browserBundleID: CallerBrowser.bundleID(),
    openApp: openApp,
    log: log
))
exit(relay.run().rawValue)
