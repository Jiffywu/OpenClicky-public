import Foundation

// Kept agents ("Clickys") as the voice brain sees them: the [Your Clickys] note, each one's memory (its AGENTS.md,
// state.md and recent runs) and the files in its folder.

extension AgentBrainContext {
    /// The `[Your Clickys]` note: every kept agent that isn't archived, with its role, what it is doing and the last
    /// thing it said, then the archived ones by name. Nil when there are none.
    public static func clickysNote(jobs: [AgentJobRecord], running: Set<String>, limit: Int = 12, now: Date = Date()) -> String? {
        let kept = jobs.filter(\.isKept)
        guard !kept.isEmpty else { return nil }
        let current = kept.filter { !$0.isArchived }
        let archived = kept.filter(\.isArchived)
        var lines = ["[Your Clickys] The user's kept agents, for your eyes only. Give one work with sessions_spawn agent=<name>, follow up with sessions_send, answer questions about one from clicky_memory and clicky_artifacts."]
        for record in current.prefix(limit) {
            var line = "- \(record.agentName ?? record.title) (\(record.id))"
            if let role = record.agentRole?.nilIfEmpty { line += ", \(AgentText.shorten(role, limit: 80))" }
            switch record.status {
            case .needsYou:
                line += ": WAITING ON THE USER"
                if let request = record.pendingRequest { line += " to approve: \(request.summary)" }
                else if let question = record.report?.question { line += ", asked: \(AgentText.shorten(question, limit: 140))" }
            case .queued, .running:
                line += ": WORKING NOW"
                if let progress = record.lastProgress { line += ", latest: \(AgentText.shorten(progress, limit: 100))" }
            default:
                if running.contains(record.id) {
                    line += ": WORKING NOW"
                } else if record.runs.isEmpty {
                    line += ": idle, no tasks yet"
                } else {
                    line += ": idle"
                }
            }
            if let said = lastSaid(record) { line += "; last said: \"\(AgentText.shorten(said, limit: 160))\"" }
            lines.append(line)
        }
        if current.count > limit { lines.append("- and \(current.count - limit) more (find_jobs lists them)") }
        if !archived.isEmpty {
            let names = archived.prefix(limit).map { "\($0.agentName ?? $0.title) (\($0.id))" }.joined(separator: ", ")
            lines.append("Archived (routing work to one brings it back; tell the user when that happens): \(names)")
        }
        return lines.joined(separator: "\n")
    }

    /// What the kept agent last said: its latest message along the way while it works, else its last report.
    static func lastSaid(_ record: AgentJobRecord) -> String? {
        if record.status.isActive, let said = record.lastSaid?.nilIfEmpty { return said }
        if let spoken = record.report?.spoken.nilIfEmpty { return spoken }
        return record.lastSaid?.nilIfEmpty
    }
}

/// `clicky_memory`: a kept agent's (or a job's) memory file, the state OpenClicky keeps for it and its recent runs.
public enum AgentClickyMemory {
    /// Characters of AGENTS.md returned before it is cut.
    public static let memoryLimit = 8_000

    public static func make(record: AgentJobRecord, store: AgentJobStore, running: Bool, recentRuns: Int = 6) -> [String: JSONValue] {
        var out: [String: JSONValue] = [
            "status": "ok", "job_id": .string(record.id), "name": .string(record.agentName ?? record.title),
            "is_kept": .bool(record.isKept), "is_archived": .bool(record.isArchived),
            "is_working_now": .bool(running || record.status == .running || record.status == .queued),
            "state": .string(record.status.rawValue), "folder": .string(record.folderPath),
        ]
        if let role = record.agentRole?.nilIfEmpty { out["role"] = .string(role) }
        let memoryURL = record.folder.appendingPathComponent("AGENTS.md")
        if let memory = try? String(contentsOf: memoryURL, encoding: .utf8) {
            if memory.count > memoryLimit {
                out["memory_markdown"] = .string(String(memory.prefix(memoryLimit)) + "\n(memory file truncated)")
            } else {
                out["memory_markdown"] = .string(memory)
            }
        } else {
            out["memory_markdown"] = "(no memory file yet)"
        }
        if let state = try? String(contentsOf: record.folder.appendingPathComponent("state.md"), encoding: .utf8), !state.isEmpty {
            out["state_markdown"] = .string(AgentText.shorten(state, limit: 3_000))
        }
        let formatter = ISO8601DateFormatter()
        out["recent_runs"] = .array(record.runs.suffix(recentRuns).reversed().map { run in
            var entry: [String: JSONValue] = ["asked": .string(AgentText.shorten(run.ask, limit: 300)),
                                              "started_at": .string(formatter.string(from: run.startedAt)),
                                              "outcome": .string(run.outcome?.rawValue ?? (run.finishedAt == nil ? "working" : "finished"))]
            if let spoken = run.spoken?.nilIfEmpty { entry["said"] = .string(spoken) }
            return .object(entry)
        })
        if let reply = record.report?.spoken.nilIfEmpty { out["latest_reply"] = .string(reply) }
        if let question = record.report?.question { out["question"] = .string(question) }
        if record.status.isActive || running, let progress = record.lastProgress { out["current_progress"] = .string(progress) }
        if let said = record.lastSaid?.nilIfEmpty, record.status.isActive || running { out["latest_message"] = .string(said) }
        if record.isKept {
            let filed = store.all().filter { $0.filedUnder == record.id }
            if !filed.isEmpty {
                out["filed_jobs"] = .array(filed.prefix(20).map { .string("\($0.id): \($0.title)") })
            }
        }
        return out
    }
}

/// `clicky_artifacts` and `open_artifact`: the files in a job's or kept agent's folder.
public enum AgentArtifacts {
    /// Characters of a file `clicky_artifacts` returns in full.
    public static let readLimit = 20_000

    /// OpenClicky's own bookkeeping, never listed.
    static let hidden: Set<String> = ["job.json", "events.jsonl", "AGENTS.md", "state.md"]

    /// Files in the folder, newest first, as paths relative to it: everything in `output/`, `report.md`, and other
    /// top-level files the agent wrote. Scratch (`tmp/`), diffs, OpenClicky's bookkeeping and linked job folders are
    /// left out.
    public static func list(_ record: AgentJobRecord, limit: Int = 60) -> [(path: String, modified: Date, bytes: Int)] {
        let base = record.folder.standardizedFileURL
        let manager = FileManager.default
        var found: [(String, Date, Int)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        func add(_ url: URL, relative: String) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true else { return }
            found.append((relative, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
        }
        for url in (try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [] {
            let name = url.lastPathComponent
            guard !hidden.contains(name) else { continue }
            add(url, relative: name)
        }
        let output = base.appendingPathComponent("output", isDirectory: true)
        if let walker = manager.enumerator(at: output, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                let relative = String(url.standardizedFileURL.path.dropFirst(base.path.count + 1))
                add(url, relative: relative)
            }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map { (path: $0.0, modified: $0.1, bytes: $0.2) }
    }

    /// The file `name` names in the folder: a relative path inside it, or a bare file name found in the listing. Nil
    /// for anything outside the folder, and for the file diffs in `diffs/` (they hold copies of files the job changed
    /// anywhere on the Mac, which the developer preview shows, not the brain).
    public static func resolve(_ name: String, in record: AgentJobRecord) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = record.folder.standardizedFileURL.resolvingSymlinksInPath()
        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else if trimmed.contains("/") {
            candidate = base.appendingPathComponent(trimmed)
        } else if let match = list(record, limit: 500).first(where: { URL(fileURLWithPath: $0.path).lastPathComponent == trimmed || $0.path == trimmed }) {
            candidate = base.appendingPathComponent(match.path)
        } else {
            return nil
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(base.path + "/"), FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        // The volume is usually case-insensitive, so "Diffs/…" is the same folder.
        guard !resolved.path.dropFirst(base.path.count + 1).lowercased().hasPrefix("diffs/") else { return nil }
        return resolved
    }

    /// The listing as tool output.
    public static func json(_ record: AgentJobRecord) -> [String: JSONValue] {
        let formatter = ISO8601DateFormatter()
        let files = list(record)
        return ["status": "ok", "job_id": .string(record.id), "name": .string(record.agentName ?? record.title),
                "folder": .string(record.folderPath),
                "files": .array(files.map { file in
                    .object(["path": .string(file.path), "modified": .string(formatter.string(from: file.modified)), "bytes": .number(Double(file.bytes))])
                })]
    }

    /// One file in full (text only, cut at `readLimit` characters).
    public static func read(_ url: URL, record: AgentJobRecord) -> [String: JSONValue] {
        let base = record.folder.standardizedFileURL.resolvingSymlinksInPath().path
        let relative = url.path.hasPrefix(base + "/") ? String(url.path.dropFirst(base.count + 1)) : url.lastPathComponent
        var out: [String: JSONValue] = ["status": "ok", "job_id": .string(record.id), "file": .string(relative), "path": .string(url.path)]
        switch AgentFileSnapshot.read(url.path, cap: 2 * 1024 * 1024) {
        case .text(let text, let bytes):
            out["bytes"] = .number(Double(bytes))
            if text.count > readLimit {
                out["content"] = .string(String(text.prefix(readLimit)))
                out["truncated"] = true
            } else {
                out["content"] = .string(text)
            }
        case .binary(let bytes), .tooLarge(let bytes):
            out["bytes"] = .number(Double(bytes))
            out["content"] = "(not a text file; open_artifact shows it to the user)"
        case .missing:
            return ["status": "not_found", "message": .string("No file \(relative) in \(record.agentName ?? record.title)'s folder.")]
        }
        return out
    }
}
