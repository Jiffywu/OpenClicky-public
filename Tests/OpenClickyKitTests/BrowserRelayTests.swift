import Foundation
import Testing
@testable import OpenClickyKit

private let origin = ChromeExtensionIdentity.origin(for: ChromeExtensionIdentity.extensionID)

private func startBridge(_ paths: BrowserBridgePaths) throws -> BrowserBridgeServer {
    let server = BrowserBridgeServer(paths: paths, token: try paths.loadOrCreateToken(), allowedOrigins: [origin], pingInterval: 0.5)
    try server.start()
    return server
}

@Test func relayCarriesACommandFromTheAppToTheExtensionAndBack() async throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let server = try startBridge(paths)
    defer { server.stop() }

    let fake = FakeExtension(paths: paths)
    fake.onCommand = FakeExtension.standardReply
    try fake.sendHello()
    #expect(eventually { fake.appReachable == true })
    #expect(eventually { server.peers.count == 1 })
    let peer = try #require(server.peers.first)
    #expect(peer.profileId == "8a6e0c55-3f1b-4f7a-9d44-0b1c2d3e4f50")
    #expect(peer.origin == origin)
    #expect(peer.browser == "com.google.Chrome")
    #expect(peer.browserName == "Chrome")
    #expect(peer.extensionVersion == "0.1.0")

    let page = try await server.send("read", arguments: ["tabId": 7], timeout: 5)
    #expect(page["title"] == "Test page")
    let command = try #require(fake.messages.first { $0["type"] == "command" })
    #expect(command["operation"] == "read")
    #expect(command["args"]?["tabId"] == 7)

    // Extension-side failures come back as errors with the extension's message.
    await #expect(throws: BrowserBridgeError(.failed, "Ref e9 is unknown.")) {
        _ = try await server.send("fail", timeout: 5)
    }

    // The bridge pings; the fake extension's pongs keep the connection alive past three ping intervals.
    try await Task.sleep(for: .seconds(2))
    #expect(fake.messages.contains { $0["type"] == "ping" })
    #expect(server.peers.count == 1)

    fake.disconnect()
    #expect(eventually { fake.exit == .normal })
    #expect(eventually { server.peers.isEmpty })
}

@Test func relayWaitsForTheAppAndConnectsWhenItStarts() async throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    _ = try paths.loadOrCreateToken()

    let fake = FakeExtension(paths: paths)
    fake.onCommand = FakeExtension.standardReply
    try fake.sendHello()
    #expect(eventually { fake.appReachable == false })

    let server = try startBridge(paths)
    defer { server.stop() }
    #expect(eventually { fake.appReachable == true })
    let tabs = try await server.send("tabs", timeout: 5)
    #expect(tabs["tabs"]?.arrayValue?.count == 1)

    // The app quits: the extension hears about it, and the relay reconnects when it comes back.
    server.stop()
    #expect(eventually { fake.appReachable == false })
    let again = try startBridge(paths)
    defer { again.stop() }
    #expect(eventually { fake.appReachable == true })
    #expect(try await again.send("tabs", timeout: 5)["tabs"] != nil)
    fake.disconnect()
}

@Test func relayRefusesCallersThatAreNotTheOpenClickyExtension() throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let fake = FakeExtension(paths: paths, origin: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/")
    #expect(eventually { fake.exit == .refused })
}

@Test func relayRequiresHelloFirst() throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let fake = FakeExtension(paths: paths)
    try fake.send(["type": "result", "id": "x", "ok": true])
    #expect(eventually { fake.exit == .refused })

    let badProfile = FakeExtension(paths: paths)
    try badProfile.send(["type": "hello", "protocol": 1, "profileId": "not-a-uuid"])
    #expect(eventually { badProfile.exit == .refused })
}

@Test func bridgeRejectsAWrongToken() async throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let server = try startBridge(paths)
    defer { server.stop() }
    // The host reads whatever token is on disk; replace it so it no longer matches the running bridge.
    try BrowserBridgeSecrets.writePrivate(Data("0000\n".utf8), to: paths.token)

    let fake = FakeExtension(paths: paths)
    try fake.sendHello()
    #expect(eventually { fake.appReachable == false })
    try await Task.sleep(for: .milliseconds(300))
    #expect(server.peers.isEmpty)
    await #expect(throws: BrowserBridgeError.self) { _ = try await server.send("tabs", timeout: 1) }
    fake.disconnect()
}

@Test func bridgeRejectsExtensionsOutsideItsAllowList() async throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let other = "abcdefghijklmnopabcdefghijklmnop"
    let server = try startBridge(paths)
    defer { server.stop() }
    // The host accepts this extension (as if listed in extra-extension-ids.txt) but the app does not.
    let fake = FakeExtension(paths: paths, origin: ChromeExtensionIdentity.origin(for: other), allowedIDs: [other])
    try fake.sendHello()
    #expect(eventually { fake.appReachable == false })
    #expect(server.peers.isEmpty)
    fake.disconnect()
}

@Test func commandsFailWhenNothingIsConnectedOrTheBrowserGoesAway() async throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let server = try startBridge(paths)
    defer { server.stop() }

    do {
        _ = try await server.send("tabs", timeout: 1)
        Issue.record("expected notConnected")
    } catch let error as BrowserBridgeError {
        #expect(error.kind == .notConnected)
    }

    let silent = FakeExtension(paths: paths)  // never answers commands
    try silent.sendHello()
    #expect(eventually { server.peers.count == 1 })
    do {
        _ = try await server.send("click", arguments: ["ref": "e1"], timeout: 0.5)
        Issue.record("expected timeout")
    } catch let error as BrowserBridgeError {
        #expect(error.kind == .timeout)
    }

    async let pending = server.send("click", arguments: ["ref": "e1"], timeout: 10)
    #expect(eventually { silent.messages.filter { $0["type"] == "command" }.count == 2 })
    try silent.send(["type": "stop"])
    do {
        _ = try await pending
        Issue.record("expected stopped")
    } catch let error as BrowserBridgeError {
        #expect(error.kind == .stopped)
    }

    async let orphaned = server.send("click", arguments: ["ref": "e1"], timeout: 10)
    #expect(eventually { silent.messages.filter { $0["type"] == "command" }.count == 3 })
    silent.disconnect()
    do {
        _ = try await orphaned
        Issue.record("expected disconnected")
    } catch let error as BrowserBridgeError {
        #expect(error.kind == .disconnected)
    }
}

@Test func statusProbeListsConnectedBrowsers() async throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let server = try startBridge(paths)
    defer { server.stop() }
    #expect(try BrowserBridgeProbe.status(paths: paths).peers.isEmpty)

    let fake = FakeExtension(paths: paths, browser: "company.thebrowser.Browser")
    try fake.sendHello()
    #expect(eventually { server.peers.count == 1 })
    let status = try BrowserBridgeProbe.status(paths: paths)
    #expect(status.peers.map(\.browserName) == ["Arc"])
    fake.disconnect()
}

@Test func secondBridgeOnTheSameSocketIsRefusedButAStaleSocketIsReplaced() throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let first = try startBridge(paths)
    #expect(throws: BridgeSocket.Error.self) { _ = try startBridge(paths) }
    first.stop()

    // A socket file nobody listens on (left by a crash) is replaced.
    let stale = try BridgeSocket.listenUnix(path: paths.socket.path)
    Darwin.close(stale)
    #expect(FileManager.default.fileExists(atPath: paths.socket.path))
    let second = try startBridge(paths)
    second.stop()
}

@Test func tokenAndFolderArePrivate() throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let token = try paths.loadOrCreateToken()
    #expect(token.count == 64)
    #expect(token.allSatisfy { $0.isHexDigit })
    #expect(try paths.loadOrCreateToken() == token)
    let tokenMode = try FileManager.default.attributesOfItem(atPath: paths.token.path)[.posixPermissions] as? Int
    let folderMode = try FileManager.default.attributesOfItem(atPath: paths.directory.path)[.posixPermissions] as? Int
    #expect(tokenMode == 0o600)
    #expect(folderMode == 0o700)
    #expect(BrowserBridgeSecrets.constantTimeEquals(token, token))
    #expect(!BrowserBridgeSecrets.constantTimeEquals(token, String(token.dropLast())))
    #expect(!BrowserBridgeSecrets.constantTimeEquals("", token))

    let server = try startBridge(paths)
    defer { server.stop() }
    let socketMode = try FileManager.default.attributesOfItem(atPath: paths.socket.path)[.posixPermissions] as? Int
    #expect(socketMode == 0o600)
}
