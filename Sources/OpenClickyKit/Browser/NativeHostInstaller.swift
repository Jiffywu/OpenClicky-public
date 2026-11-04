import Foundation

/// A Chromium browser that reads native-messaging host manifests from its Application Support folder.
public struct ChromiumBrowser: Sendable, Hashable {
    public var id: String
    public var displayName: String
    public var bundleID: String
    /// Folder under `~/Library/Application Support/` holding the browser's profiles.
    public var supportPath: String

    public init(id: String, displayName: String, bundleID: String, supportPath: String) {
        self.id = id
        self.displayName = displayName
        self.bundleID = bundleID
        self.supportPath = supportPath
    }
}

/// Writes (and removes) OpenClicky's native-messaging host manifest, `com.openclicky.browser.json`, in each
/// Chromium browser's `NativeMessagingHosts` folder. It only ever touches files with that exact name; other apps'
/// manifests (HeyClicky's `com.heyclicky.browser.json` included) are left alone.
public enum NativeHostInstaller {
    public static let manifestFileName = ChromeExtensionIdentity.hostName + ".json"
    public static let hostExecutableName = "OpenClickyBrowserHost"

    public static let browsers: [ChromiumBrowser] = [
        ChromiumBrowser(id: "chrome", displayName: "Chrome", bundleID: "com.google.Chrome", supportPath: "Google/Chrome"),
        ChromiumBrowser(id: "chromium", displayName: "Chromium", bundleID: "org.chromium.Chromium", supportPath: "Chromium"),
        ChromiumBrowser(id: "brave", displayName: "Brave", bundleID: "com.brave.Browser", supportPath: "BraveSoftware/Brave-Browser"),
        ChromiumBrowser(id: "edge", displayName: "Edge", bundleID: "com.microsoft.edgemac", supportPath: "Microsoft Edge"),
        ChromiumBrowser(id: "arc", displayName: "Arc", bundleID: "company.thebrowser.Browser", supportPath: "Arc/User Data"),
        ChromiumBrowser(id: "vivaldi", displayName: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", supportPath: "Vivaldi"),
        ChromiumBrowser(id: "chrome-beta", displayName: "Chrome Beta", bundleID: "com.google.Chrome.beta", supportPath: "Google/Chrome Beta"),
        ChromiumBrowser(id: "chrome-dev", displayName: "Chrome Dev", bundleID: "com.google.Chrome.dev", supportPath: "Google/Chrome Dev"),
        ChromiumBrowser(id: "chrome-canary", displayName: "Chrome Canary", bundleID: "com.google.Chrome.canary", supportPath: "Google/Chrome Canary"),
        ChromiumBrowser(id: "chrome-for-testing", displayName: "Chrome for Testing", bundleID: "com.google.chrome.for.testing", supportPath: "Google/Chrome for Testing"),
    ]

    public static var defaultApplicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// The manifest Chrome reads: the host's absolute path and the extension origins allowed to start it.
    public static func manifest(hostPath: String, extensionIDs: [String]) -> JSONValue {
        [
            "name": .string(ChromeExtensionIdentity.hostName),
            "description": "OpenClicky browser bridge",
            "path": .string(hostPath),
            "type": "stdio",
            "allowed_origins": .array(extensionIDs.map { .string(ChromeExtensionIdentity.origin(for: $0)) }),
        ]
    }

    public static func manifestData(hostPath: String, extensionIDs: [String]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(manifest(hostPath: hostPath, extensionIDs: extensionIDs))) ?? Data()) + Data("\n".utf8)
    }

    public static func hostsFolder(for browser: ChromiumBrowser, applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(browser.supportPath, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
    }

    public static func manifestURL(for browser: ChromiumBrowser, applicationSupport: URL) -> URL {
        hostsFolder(for: browser, applicationSupport: applicationSupport).appendingPathComponent(manifestFileName)
    }

    public struct Outcome: Sendable, Hashable {
        public enum Action: Sendable, Hashable {
            case written, unchanged, removed, absent
            /// The browser's support folder doesn't exist (not installed or never run).
            case browserNotFound
            case failed(String)
        }

        public var browser: ChromiumBrowser
        public var manifest: URL
        public var action: Action
    }

    /// Writes the manifest for every browser whose support folder exists (or all of them with `includeMissing`).
    public static func install(hostPath: URL, extensionIDs: [String] = [ChromeExtensionIdentity.extensionID],
                               applicationSupport: URL = defaultApplicationSupport, browsers: [ChromiumBrowser] = browsers,
                               includeMissing: Bool = false) -> [Outcome] {
        let data = manifestData(hostPath: hostPath.standardizedFileURL.path, extensionIDs: extensionIDs)
        return browsers.map { browser in
            let target = manifestURL(for: browser, applicationSupport: applicationSupport)
            precondition(target.lastPathComponent == manifestFileName)
            let support = applicationSupport.appendingPathComponent(browser.supportPath, isDirectory: true)
            guard includeMissing || FileManager.default.fileExists(atPath: support.path) else {
                return Outcome(browser: browser, manifest: target, action: .browserNotFound)
            }
            if (try? Data(contentsOf: target)) == data { return Outcome(browser: browser, manifest: target, action: .unchanged) }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
                return Outcome(browser: browser, manifest: target, action: .written)
            } catch {
                let hint = "OpenClicky couldn't write to \(target.deletingLastPathComponent().path); check that you own that folder."
                return Outcome(browser: browser, manifest: target, action: .failed("\(hint) (\(error.localizedDescription))"))
            }
        }
    }

    /// Removes OpenClicky's manifest (only that file) from every browser.
    public static func uninstall(applicationSupport: URL = defaultApplicationSupport, browsers: [ChromiumBrowser] = browsers) -> [Outcome] {
        browsers.map { browser in
            let target = manifestURL(for: browser, applicationSupport: applicationSupport)
            precondition(target.lastPathComponent == manifestFileName)
            guard FileManager.default.fileExists(atPath: target.path) else { return Outcome(browser: browser, manifest: target, action: .absent) }
            do {
                try FileManager.default.removeItem(at: target)
                return Outcome(browser: browser, manifest: target, action: .removed)
            } catch {
                return Outcome(browser: browser, manifest: target, action: .failed(error.localizedDescription))
            }
        }
    }

    public struct Inspection: Sendable, Hashable {
        public var browser: ChromiumBrowser
        public var browserFound: Bool
        public var manifest: URL
        public var manifestPresent: Bool
        /// The host path the manifest points at, and whether an executable is there.
        public var hostPath: String?
        public var hostExecutable: Bool
        public var allowsOpenClickyExtension: Bool
    }

    public static func inspect(applicationSupport: URL = defaultApplicationSupport, browsers: [ChromiumBrowser] = browsers) -> [Inspection] {
        browsers.map { browser in
            let target = manifestURL(for: browser, applicationSupport: applicationSupport)
            let found = FileManager.default.fileExists(atPath: applicationSupport.appendingPathComponent(browser.supportPath).path)
            let json = (try? Data(contentsOf: target)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            let path = json?["path"]?.stringValue
            let origins = json?["allowed_origins"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return Inspection(browser: browser, browserFound: found, manifest: target, manifestPresent: json != nil, hostPath: path,
                              hostExecutable: path.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false,
                              allowsOpenClickyExtension: origins.contains(ChromeExtensionIdentity.origin(for: ChromeExtensionIdentity.extensionID)))
        }
    }

    /// Finds the host executable for a running tool: next to it (SwiftPM build folder, `Contents/MacOS`) or in the app
    /// bundle's `Contents/Helpers`.
    public static func locateHost(nextTo executable: URL) -> URL? {
        let folder = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            folder.appendingPathComponent(hostExecutableName),
            folder.deletingLastPathComponent().appendingPathComponent("Helpers").appendingPathComponent(hostExecutableName),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
