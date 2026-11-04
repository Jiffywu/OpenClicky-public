import Foundation
import Testing
import OpenClickyKit
@testable import OpenClicky

@Suite @MainActor struct ComposioConnectRefreshTests {
    /// Coming back to Settings (onAppear) or pressing Refresh while the browser sign-in is open must not cancel the
    /// connection: it finishes, says so, and lists the new account.
    @Test func refreshingWhileConnectingLeavesTheConnectionRunning() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-composio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = ConnectedAppsModel(credentials: InMemoryCredentialStore(), registryURL: folder.appendingPathComponent("connectors.json"))
        model.saveComposio(userID: "u1", toolkits: "gmail", key: "test-placeholder")
        let composio = GatedComposio()
        model.composioHTTP = composio
        var opened: [URL] = []
        model.openInBrowser = { opened.append($0) }

        model.connectComposio(toolkit: "gmail")
        #expect(await Self.eventually { !opened.isEmpty })
        #expect(model.composioFlow == .waiting(toolkit: "gmail"))
        model.refreshComposioAccounts()
        #expect(model.composioFlow == .waiting(toolkit: "gmail"), "the connection is still being waited for")
        #expect(model.isConnectingComposio)

        composio.signIn()
        #expect(await Self.eventually { model.composioFlow == .idle && !model.composioAccounts.isEmpty })
        #expect(model.message == "Connected gmail in Composio.")
        #expect(model.composioAccounts.map(\.id) == ["ca_9"])
        #expect(!composio.listedDuringSignIn, "nothing listed the accounts before sign-in finished")
    }

    static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

/// Composio's connect flow, with the account's sign-in held until `signIn()`.
private final class GatedComposio: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var signedIn = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var listedEarly = false

    var listedDuringSignIn: Bool { lock.withLock { listedEarly } }

    func signIn() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            signedIn = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in resumed { waiter.resume() }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let body: String
        if path.hasSuffix("/auth_configs") {
            body = #"{"items":[{"id":"ac_gmail","is_disabled":false}]}"#
        } else if path.hasSuffix("/connected_accounts/link") {
            body = #"{"redirect_url":"https://connect.composio.dev/link/lt_1","connected_account_id":"ca_9"}"#
        } else if path.hasSuffix("/connected_accounts/ca_9") {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock { () -> Bool in
                    if signedIn { return true }
                    waiters.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
            body = Self.account
        } else {
            lock.withLock { if !signedIn { listedEarly = true } }
            body = #"{"items":[\#(Self.account)],"next_cursor":null}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }

    static let account = #"{"id":"ca_9","toolkit":{"slug":"gmail"},"status":"ACTIVE","alias":null,"user_id":"u1","auth_config":{"id":"ac_gmail"}}"#
}
