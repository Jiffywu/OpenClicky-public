import Foundation
import Testing
import OpenClickyKit
@testable import OpenClicky

// The app's own path for the brain's turn notes (VoiceLoopController reads AgentServices.brainNotes), not only the
// kit's BrainWiring.jobNotes: the kept agents reach the voice brain through it, archived ones apart.
@Suite @MainActor struct AgentServicesNotesTests {
    @Test func theAppsTurnNotesCarryTheClickysNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-notes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(root: root)
        let store = AgentJobStore(paths: paths)
        _ = try store.keptAgent(named: "Scribe", role: "newsletter writer", harness: .codex, model: nil, provider: "p")
        var old = try store.keptAgent(named: "Old Helper", role: "retired", harness: .codex, model: nil, provider: "p")
        old.archivedAt = Date()
        try store.save(old)
        let services = AgentServices(config: { .heyClickyLike }, credentials: InMemoryCredentialStore(), paths: paths,
                                     connectorRegistry: root.appendingPathComponent("connectors.json"))
        let notes = await services.brainNotes()
        let clickys = try #require(notes.first { $0.hasPrefix("[Your Clickys]") })
        #expect(clickys.contains("- Scribe (scribe), newsletter writer"))
        #expect(clickys.contains("Archived (") && clickys.contains("Old Helper"))
        #expect(notes.filter { $0.hasPrefix("[Your Clickys]") }.count == 1)
        await services.stop()
    }
}
