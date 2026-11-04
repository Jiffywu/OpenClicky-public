import Foundation

/// The kept-agent tools: `clicky_memory`, `clicky_artifacts`, `clicky_archive`, and (when the app can show them)
/// `open_artifact` and `open_agent_dashboard`.
extension AgentTools {
    public static let clickyToolNames: Set<String> = ["clicky_memory", "clicky_artifacts", "clicky_archive", "open_artifact",
                                                      "open_agent_dashboard"]

    var clickySpecs: [ToolSpec] {
        var specs = [Self.clickyMemorySpec, Self.clickyArtifactsSpec, Self.clickyArchiveSpec]
        if openFile != nil { specs.append(Self.openArtifactSpec) }
        if openLink != nil { specs.append(Self.dashboardSpec) }
        return specs
    }

    static let agentReference: JSONValue = ["type": "string", "description": "A kept agent's name or slug (or a job_id)."]

    public static let clickyMemorySpec = ToolSpec(
        name: "clicky_memory",
        description: """
        What a kept agent remembers and has been doing: its memory file (identity, standing preferences, notes), the \
        state OpenClicky keeps for it, its recent tasks and what it said, and whether it is working or archived. Read \
        it before answering questions about a kept agent rather than guessing.
        """,
        parameters: ["type": "object", "properties": ["agent": agentReference], "required": ["agent"], "additionalProperties": false])

    public static let clickyArtifactsSpec = ToolSpec(
        name: "clicky_artifacts",
        description: "List the files in a kept agent's (or a job's) folder, newest first; pass file to read one of them in full.",
        parameters: [
            "type": "object",
            "properties": [
                "agent": agentReference,
                "file": ["type": "string", "description": "A path from the listing (output/notes.md) or a file name, to read it."],
            ],
            "required": ["agent"],
            "additionalProperties": false,
        ])

    public static let clickyArchiveSpec = ToolSpec(
        name: "clicky_archive",
        description: """
        Archive a kept agent the user no longer needs (its folder and memory stay; it leaves the [Your Clickys] list), \
        or bring an archived one back. Giving an archived agent work with sessions_spawn brings it back too.
        """,
        parameters: [
            "type": "object",
            "properties": ["agent": agentReference, "action": ["type": "string", "enum": ["archive", "unarchive"]]],
            "required": ["agent", "action"],
            "additionalProperties": false,
        ])

    public static let openArtifactSpec = ToolSpec(
        name: "open_artifact",
        description: "Open a file a kept agent or job made, in its usual app, for the user to look at. Held until you finish speaking.",
        parameters: [
            "type": "object",
            "properties": [
                "agent": agentReference,
                "file": ["type": "string", "description": "A path from clicky_artifacts or read_job (output/report.pdf), or a file name. Default: the newest output."],
            ],
            "required": ["agent"],
            "additionalProperties": false,
        ])

    public static let dashboardSpec = ToolSpec(
        name: "open_agent_dashboard",
        description: "Show the user the agents dashboard (Home → Agents), optionally on one job or kept agent, or close it. Held until you finish speaking.",
        parameters: [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["open", "close"], "description": "open (default) or close."],
                "job_id": jobReference,
            ],
            "additionalProperties": false,
        ])

    /// Adds the "it was archived and is back" note to a spawn or send result.
    static func noteRevived(_ record: AgentJobRecord, in out: inout [String: JSONValue]) {
        out["revived"] = true
        let back = "\(record.agentName ?? record.title) was archived and is back in the list now; mention that to the user."
        out["message"] = .string([back, out["message"]?.stringValue].compactMap { $0 }.joined(separator: " "))
    }

    func callClickyTool(_ name: String, _ args: JSONValue) async throws -> JSONValue {
        switch name {
        case "clicky_memory":
            let record = try await record(args)
            return .object(AgentClickyMemory.make(record: record, store: manager.store, running: await manager.isRunning(record.id)))
        case "clicky_artifacts":
            let record = try await record(args)
            guard let file = args["file"]?.stringValue?.nilIfEmpty else { return .object(AgentArtifacts.json(record)) }
            guard let url = AgentArtifacts.resolve(file, in: record) else { return Self.noFile(file, record) }
            return .object(AgentArtifacts.read(url, record: record))
        case "clicky_archive":
            let reference = try value(args, "agent")
            switch try value(args, "action") {
            case "archive":
                let record = try await manager.archive(reference)
                return ["status": "archived", "job_id": .string(record.id), "agent": .string(record.agentName ?? record.title)]
            case "unarchive":
                let record = try await manager.unarchive(reference)
                return ["status": "unarchived", "job_id": .string(record.id), "agent": .string(record.agentName ?? record.title)]
            case let other:
                throw AgentToolError.invalid("action must be archive or unarchive (got \(other)).")
            }
        case "open_artifact":
            guard let openFile else { return ["status": "not_implemented", "message": "Opening files isn't available here."] }
            let record = try await record(args)
            let url: URL
            if let file = args["file"]?.stringValue?.nilIfEmpty {
                guard let found = AgentArtifacts.resolve(file, in: record) else { return Self.noFile(file, record) }
                url = found
            } else {
                let files = AgentArtifacts.list(record)
                guard let newest = files.first(where: { $0.path.hasPrefix("output/") }) ?? files.first,
                      let found = AgentArtifacts.resolve(newest.path, in: record) else {
                    return ["status": "not_found", "message": .string("\(record.agentName ?? record.title) hasn't made any files yet.")]
                }
                url = found
            }
            guard await openFile(url) else { return ["status": "failed", "message": "The file couldn't be opened."] }
            return ["status": "opened", "job_id": .string(record.id), "file": .string(url.lastPathComponent)]
        case "open_agent_dashboard":
            guard let openLink else { return ["status": "not_implemented", "message": "The dashboard isn't available here."] }
            if args["action"]?.stringValue == "close" {
                return await openLink(nil) ? ["status": "closed"] : ["status": "failed", "message": "The dashboard couldn't be closed."]
            }
            var link = "openclicky://home/agents"
            if let reference = args["job_id"]?.stringValue?.nilIfEmpty {
                guard let record = await manager.job(reference) else { throw AgentManagerError.unknownJob(reference) }
                link = "openclicky://job/\(record.id)"
            }
            guard await openLink(link) else { return ["status": "failed", "message": "The dashboard couldn't be opened."] }
            return ["status": "opened", "link": .string(link)]
        default:
            return ["status": "not_implemented", "message": .string("No tool named \(name).")]
        }
    }

    private func value(_ args: JSONValue, _ key: String) throws -> String {
        guard let value = args[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw AgentToolError.missing(key)
        }
        return value
    }

    private func record(_ args: JSONValue) async throws -> AgentJobRecord {
        let reference = try value(args, "agent")
        guard let record = await manager.job(reference) else { throw AgentManagerError.unknownJob(reference) }
        return record
    }

    private static func noFile(_ file: String, _ record: AgentJobRecord) -> JSONValue {
        ["status": "not_found", "message": .string("No file \(file) in \(record.agentName ?? record.title)'s folder.")]
    }
}
