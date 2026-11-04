import AppKit
import OpenClickyKit
import SwiftUI

/// `OpenClicky --render-connected-apps-snapshots <folder>`: renders Settings → Connected apps in the states this page
/// gained: secret header and environment lines in the add forms, a connector's stored secret names, and the Composio
/// accounts list (connected accounts, waiting for the browser, a failed connection). Uses an in-memory credential
/// store, a scratch connectors file and no network: Composio's answers are fixtures.
@MainActor
enum ConnectedAppsSnapshots {
    static func run(into folder: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-apps-snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try renderAll(root: root, into: folder)
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }

    static let size = NSSize(width: 760, height: 2300)

    static func renderAll(root: URL, into folder: URL) throws {
        func out(_ name: String) -> URL { folder.appendingPathComponent("connected-apps-" + name + ".png") }
        let credentials = InMemoryCredentialStore([ComposioClient.credentialName: "ck_fixture_not_a_key"])
        let model = ConnectedAppsModel(credentials: credentials, registryURL: root.appendingPathComponent("connectors.json"))
        model.composioHTTP = FakeHTTPTransport([])
        model.openInBrowser = { _ in }
        model.addRemote(name: "Helpdesk", url: "https://helpdesk.example.com/mcp", auth: .none, token: "", label: "Work",
                        headerLines: "X-Api-Key: fixture-value\nX-Workspace: fixture-workspace")
        model.addCommand(name: "Files", commandLine: "npx -y @example/files-mcp", label: "",
                         environmentLines: "FILES_TOKEN=fixture-token")
        model.saveComposio(userID: "jeff@example.com", toolkits: "", key: "")
        model.message = nil
        let accounts = [
            ComposioConnectedAccount(id: "ca_gmail01", toolkit: "gmail", status: "ACTIVE", alias: "work"),
            ComposioConnectedAccount(id: "ca_gcal02", toolkit: "googlecalendar", status: "ACTIVE"),
            ComposioConnectedAccount(id: "ca_slack03", toolkit: "slack", status: "INITIATED"),
        ]
        func page() -> some View { ConnectedAppsSettings(model: model) }

        model.showComposioFixture(accounts: accounts, flow: .idle)
        try EvidenceSnapshots.render(page(), size: size, to: out("accounts"), settle: 0.8)
        model.showComposioFixture(accounts: accounts, flow: .waiting(toolkit: "notion"))
        try EvidenceSnapshots.render(page(), size: size, to: out("waiting-for-browser"), settle: 0.8)
        model.showComposioFixture(accounts: [ComposioConnectedAccount(id: "ca_slack03", toolkit: "slack", status: "FAILED")],
                                  flow: .failed("Composio says the slack connection failed."))
        try EvidenceSnapshots.render(page(), size: size, to: out("failed"), settle: 0.8)
        model.showComposioFixture(accounts: accounts, flow: .idle)
        try EvidenceSnapshots.render(page(), size: size, dark: true, to: out("accounts-dark"), settle: 0.8)

        // What the file holds: names only.
        let saved = try String(contentsOf: root.appendingPathComponent("connectors.json"), encoding: .utf8)
        let leaked = ["fixture-value", "fixture-workspace", "fixture-token", "ck_fixture"].filter { saved.contains($0) }
        try saved.write(to: folder.appendingPathComponent("connected-apps-connectors.json"), atomically: true, encoding: .utf8)
        print(leaked.isEmpty ? "connectors.json holds no secret values" : "LEAKED: \(leaked)")
    }
}
