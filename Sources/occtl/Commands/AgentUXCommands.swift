import Foundation
import OpenClickyKit

/// `occtl agent organize|clickys|archive|unarchive|diffs`: kept agents and job file diffs.
enum AgentUXCommands {
    static let help = """
      occtl agent organize [--dry-run] [--force]          group finished one-off jobs into kept agents (brain-fast);
                                                          --dry-run prints the proposal only; --force runs again
      occtl agent clickys                                 the [Your Clickys] note the brain gets
      occtl agent archive <agent> | unarchive <agent>     archive a kept agent, or bring it back
      occtl agent diffs <job-id|agent> [N]                file diffs a job kept (developer preview); N prints one
    """

    static func run(_ sub: String, _ args: [String]) async throws {
        switch sub {
        case "organize": try await organize(args)
        case "clickys": await clickys()
        case "archive", "unarchive": try await archive(sub, args)
        case "diffs": diffs(args)
        default: fail(AgentCommands.help)
        }
    }

    /// A manager for bookkeeping only: anything that would launch a harness fails.
    static func bookkeepingManager() -> AgentManager {
        AgentManager(store: AgentJobStore()) { _ in throw AgentManagerError.configuration("occtl agent bookkeeping doesn't start jobs.") }
    }

    static func organize(_ args: [String]) async throws {
        let dryRun = args.contains("--dry-run"), force = args.contains("--force")
        let config = AgentCommands.loadConfig()
        let catalog = ((try? ModelCatalog.builtIn()) ?? ModelCatalog(models: [])).merging(config.models)
        let store = AgentJobStore()
        let organizer: AgentOrganizer
        do {
            organizer = try AgentOrganizer(store: store, factory: EngineFactory(config: config, catalog: catalog, credentials: KeychainCredentialStore()),
                                           manager: bookkeepingManager())
        } catch {
            fail("No organizer model: \(error)")
        }
        let state = organizer.state
        if let done = state.completedAt, !force, !dryRun {
            fail(AgentOrganizerError.alreadyDone(done).description + " (--force)")
        }
        let candidates = organizer.candidates()
        print("model: \(organizer.model)\(organizer.reasoningEffort.map { " (effort \($0))" } ?? "")")
        print("finished one-off jobs: \(candidates.count)")
        let started = Date()
        let proposal: AgentOrganizerProposal
        do { proposal = try await organizer.propose(jobs: candidates) } catch { fail("\(error)") }
        print(String(format: "answer in %.1f s", Date().timeIntervalSince(started)))
        let titles = Dictionary(candidates.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for group in proposal.groups {
            print("\n\(group.name)\(group.existingSlug.map { " (existing \($0))" } ?? "") — \(group.role)")
            if let description = group.description { print("  \(description)") }
            for id in group.jobIDs { print("  - \(id): \(titles[id] ?? "")") }
            if let notes = group.notes { print("  notes: \(notes)") }
        }
        print("\nleft alone: \(proposal.leftover.count)")
        guard !dryRun else {
            print("(dry run: nothing changed)")
            return
        }
        let result = try await organizer.apply(proposal)
        print("created: \(result.created.joined(separator: ", ").nilIfEmptyText)")
        print("filed: \(result.filed.count) job(s)\(result.alreadyFiled.isEmpty ? "" : "; already filed: \(result.alreadyFiled.count)")")
    }

    static func clickys() async {
        let manager = bookkeepingManager()
        let jobs = await manager.jobs()
        print(AgentBrainContext.clickysNote(jobs: jobs, running: []) ?? "No kept agents.")
    }

    static func archive(_ sub: String, _ args: [String]) async throws {
        guard let reference = args.first else { fail("Usage: occtl agent \(sub) <agent>") }
        let manager = bookkeepingManager()
        do {
            let record = sub == "archive" ? try await manager.archive(reference) : try await manager.unarchive(reference)
            print("\(record.agentName ?? record.title) (\(record.id)): \(record.isArchived ? "archived" : "active")")
        } catch {
            fail("\(error)")
        }
    }

    static func diffs(_ args: [String]) {
        guard let reference = args.first else { fail("Usage: occtl agent diffs <job-id|agent> [N]") }
        let store = AgentJobStore()
        guard let record = store.load(id: reference) ?? store.load(id: AgentJobStore.slug(reference)) else {
            fail(AgentManagerError.unknownJob(reference).description)
        }
        let items = record.fileDiffs ?? []
        guard !items.isEmpty else {
            print("No file diffs for \(record.id). Turn them on in Settings → Agents (developer preview).")
            return
        }
        if args.count > 1, let index = Int(args[1]), (1...items.count).contains(index) {
            let item = items[index - 1]
            print(AgentFileDiffs.text(of: item, in: record) ?? "(no diff text: \(item.summary))")
            return
        }
        for (index, item) in items.enumerated() {
            print("\(index + 1). run \(item.run) \(item.kind.rawValue) \(item.path)  \(item.summary)\(item.diffFile.map { "  [\($0)]" } ?? "")")
        }
    }
}

private extension String {
    var nilIfEmptyText: String { isEmpty ? "none" : self }
}
