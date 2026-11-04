import AppKit
import OpenClickyKit
import SwiftUI

/// Evidence renders for Settings → Agents' kept-agent and developer-preview sections and the file-diff viewer, from
/// fixture jobs whose diffs are made by the real recorder in a temporary folder.
@MainActor
enum AgentsUXSnapshots {
    static func render<V: View>(services: HomeServices, root: URL, settings: () -> V, size: NSSize, out: (String) -> URL) throws {
        let agents = services.agentSettings
        let before = agents.preferences
        var preview = before
        preview.developerFileDiffs = true
        agents.show(preview)
        // The page's new sections on their own (the full page scrolls past them).
        let sections = Form { AgentsUXSettingsSections() }.formStyle(.grouped).environment(services).environment(services.model)
        try EvidenceSnapshots.render(sections, size: NSSize(width: 640, height: 420), to: out("settings-agents-preview"))
        try EvidenceSnapshots.render(sections, size: NSSize(width: 640, height: 420), dark: true, to: out("settings-agents-preview-dark"))
        agents.show(before)

        let store = AgentJobStore(paths: AgentPaths(root: root.appendingPathComponent("diff-fixture", isDirectory: true)))
        let jobs = try fixtureJobs(store)
        let model = AgentFileDiffsModel()
        model.show(jobs)
        let viewer = NSSize(width: 900, height: 560)
        try EvidenceSnapshots.render(AgentFileDiffsView(model: model), size: viewer, to: out("agent-file-diffs"))
        try EvidenceSnapshots.render(AgentFileDiffsView(model: model), size: viewer, dark: true, to: out("agent-file-diffs-dark"))
        model.selectedID = model.entries.first { $0.item.kind == .created }?.id
        try EvidenceSnapshots.render(AgentFileDiffsView(model: model), size: viewer, to: out("agent-file-diffs-created"))
        model.selectedID = model.entries.first { $0.item.skipped == .binary }?.id
        try EvidenceSnapshots.render(AgentFileDiffsView(model: model), size: viewer, to: out("agent-file-diffs-binary"))
    }

    /// Two jobs: one changed a script and made a README, one deleted a draft and touched an image.
    static func fixtureJobs(_ store: AgentJobStore) throws -> [AgentJobRecord] {
        let now = Date()
        func job(_ title: String, _ edits: (URL, inout AgentFileDiffRecorder) throws -> Void) throws -> AgentJobRecord {
            var record = try store.createJob(task: title, title: title, harness: .claudeCode, model: "claude-haiku-5-5", provider: "anthropic", now: now)
            var run = AgentRun(ask: title, startedAt: now)
            run.finishedAt = now
            run.outcome = .completed
            record.runs = [run]
            record.status = .done
            var recorder = AgentFileDiffRecorder()
            try edits(record.outputFolder, &recorder)
            record.fileDiffs = recorder.finish(run: 1, folder: record.folder, at: now)
            try store.save(record)
            return record
        }
        let scripts = try job("Rename Photos Script") { output, recorder in
            let script = output.appendingPathComponent("rename.sh")
            try "#!/bin/sh\n# Rename photos by date\nfor f in *.jpg; do\n  mv \"$f\" \"photo-$f\"\ndone\n".write(to: script, atomically: true, encoding: .utf8)
            recorder.willChange(script.path)
            try "#!/bin/sh\n# Rename photos by the date they were taken\nset -e\nfor f in *.jpg; do\n  day=$(stat -f %Sm -t %Y-%m-%d \"$f\")\n  mv \"$f\" \"$day-$f\"\ndone\n"
                .write(to: script, atomically: true, encoding: .utf8)
            let readme = output.appendingPathComponent("README.md")
            try "# Rename photos\n\nRun `sh rename.sh` in the folder with the photos.\n".write(to: readme, atomically: true, encoding: .utf8)
            recorder.changed(readme.path, change: "created")
        }
        let tidy = try job("Tidy Newsletter Drafts") { output, recorder in
            let draft = output.appendingPathComponent("draft-old.md"), logo = output.appendingPathComponent("logo.png")
            try "# Old draft\n\nNothing here anymore.\n".write(to: draft, atomically: true, encoding: .utf8)
            try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: logo)
            recorder.willChange(draft.path)
            recorder.willChange(logo.path)
            try FileManager.default.removeItem(at: draft)
            try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x02, 0x03]).write(to: logo)
        }
        return [scripts, tidy]
    }
}
