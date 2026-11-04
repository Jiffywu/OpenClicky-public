import Foundation
import Testing
@testable import OpenClickyKit

// The organizer: proposal parsing, the scripted brain-fast call, idempotent apply (kept agents made once, job folders
// linked, never moved) and the run-once flag.

enum OrganizerFixtures {
    /// A finished one-off job with one run and a report.
    @discardableResult
    static func job(_ store: AgentJobStore, _ title: String, ask: String, said: String = "Done.", routine: String? = nil,
                    status: AgentJobStatus = .done, at: Date = Date()) throws -> AgentJobRecord {
        var record = try store.createJob(task: ask, title: title, harness: .claudeCode, model: "claude-haiku-5-5", provider: "anthropic", now: at)
        var run = AgentRun(ask: ask, startedAt: at, routineID: routine)
        run.finishedAt = at.addingTimeInterval(60)
        run.outcome = .completed
        run.spoken = said
        record.runs = [run]
        record.status = status
        record.report = AgentFinalReport(markdown: said, spoken: said)
        try store.save(record)
        return record
    }

    /// Three trip jobs, one recipe job, plus jobs the organizer must ignore.
    static func history(_ store: AgentJobStore) throws -> (trip: [AgentJobRecord], recipe: AgentJobRecord) {
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        let trip = [
            try job(store, "Lisbon Flights", ask: "Find flights to Lisbon in May", said: "Three flights under 300 euros.", at: base),
            try job(store, "Lisbon Hotels", ask: "Hotels in Alfama for May", said: "Four hotels near the river.", at: base.addingTimeInterval(100)),
            try job(store, "Lisbon Day Trips", ask: "Day trips from Lisbon", said: "Sintra and Cascais.", at: base.addingTimeInterval(200)),
        ]
        let recipe = try job(store, "Sourdough Recipe", ask: "A beginner sourdough recipe", at: base.addingTimeInterval(300))
        try job(store, "Morning Brief", ask: "Summarize my inbox", routine: "routine-1", at: base.addingTimeInterval(400))
        try job(store, "Still Running", ask: "Long research", status: .running, at: base.addingTimeInterval(500))
        _ = try store.keptAgent(named: "Scribe", role: "newsletter writer", harness: .codex, model: nil, provider: "harness-login")
        return (trip, recipe)
    }

    static func answer(_ trip: [AgentJobRecord]) -> String {
        let ids = trip.map { "\"\($0.id)\"" }.joined(separator: ", ")
        return """
        Here you go:
        ```json
        {"groups": [{"existing_slug": null, "name": "Trip Planner", "role": "plans the Lisbon trip", "description": "Flights, hotels and outings for Lisbon.", "job_ids": [\(ids)], "notes": "Trip is in May; prefers Alfama."}], "leftover_job_ids": []}
        ```
        """
    }
}

@Test func organizerProposalsKeepOnlyWhatCanBeApplied() throws {
    let ids: Set<String> = ["a", "b", "c", "d"]
    let text = """
    {"groups": [
      {"name": "Trip Planner", "role": "trips", "job_ids": ["a", "b", "zzz", "a"]},
      {"name": "Lonely", "role": "one job", "job_ids": ["c"]},
      {"existing_slug": "scribe", "name": "", "role": "", "job_ids": ["c", "b"]},
      {"existing_slug": "ghost", "name": "Ghost", "role": "", "job_ids": ["d"]},
      {"name": "\(String(repeating: "x", count: 50))", "role": "", "job_ids": ["d", "c"]}
    ], "leftover_job_ids": ["d"]}
    """
    let proposal = try #require(AgentOrganizer.parse(text, jobIDs: ids, keptSlugs: ["scribe"]))
    #expect(proposal.groups.count == 2)
    #expect(proposal.groups[0].name == "Trip Planner" && proposal.groups[0].jobIDs == ["a", "b"])
    // Joining an existing kept agent needs only one job (b is already taken).
    #expect(proposal.groups[1].existingSlug == "scribe" && proposal.groups[1].jobIDs == ["c"] && proposal.groups[1].name == "scribe")
    #expect(proposal.leftover == ["d"])
    #expect(AgentOrganizer.parse("Sorry, I can't.", jobIDs: ids, keptSlugs: []) == nil)
    #expect(AgentOrganizer.parse(#"{"clickys": [{"name": "Pair", "role": "r", "threadIDs": ["a", "b"]}]}"#, jobIDs: ids, keptSlugs: [])?.groups.first?.jobIDs == ["a", "b"])
}

@Test func organizerAsksAboutFinishedOneOffJobsOnly() async throws {
    let temp = AgentTempDir()
    let store = AgentJobStore(paths: temp.paths)
    let (trip, recipe) = try OrganizerFixtures.history(store)
    let model = ScriptedLanguageModel(reply: OrganizerFixtures.answer(trip))
    let organizer = AgentOrganizer(store: store, client: model, model: "fast-test", reasoningEffort: "low")
    let candidates = organizer.candidates().map(\.id)
    #expect(Set(candidates) == Set(trip.map(\.id) + [recipe.id]))

    let proposal = try await organizer.propose()
    #expect(proposal.groups.count == 1)
    #expect(proposal.groups[0].name == "Trip Planner" && Set(proposal.groups[0].jobIDs) == Set(trip.map(\.id)))
    #expect(proposal.leftover == [recipe.id])
    let request = try #require(model.requests.first)
    #expect(request.model == "fast-test" && request.reasoningEffort == "low")
    let sent = request.messages.last?.text ?? ""
    #expect(sent.contains("\"job_id\":\"\(trip[0].id)\"") && sent.contains("Find flights to Lisbon in May"))
    #expect(sent.contains("\"slug\":\"scribe\""))
    #expect(!sent.contains("Morning Brief") && !sent.contains("Still Running"))

    let tooFew = AgentOrganizer(store: store, client: model, model: "fast-test")
    await #expect(throws: AgentOrganizerError.tooFewJobs(1)) { try await tooFew.propose(jobs: [recipe]) }
}

@Test func applyingTwiceFilesEachJobOnceAndNeverMovesItsFolder() async throws {
    let temp = AgentTempDir()
    let store = AgentJobStore(paths: temp.paths)
    let (trip, recipe) = try OrganizerFixtures.history(store)
    let manager = AgentManager(store: store) { _ in throw AgentManagerError.emptyTask }
    let organizer = AgentOrganizer(store: store, client: ScriptedLanguageModel(reply: OrganizerFixtures.answer(trip)), model: "m", manager: manager)
    let proposal = try await organizer.propose()

    let first = try await organizer.apply(proposal)
    #expect(first.created == ["trip-planner"])
    #expect(first.filed.count == 3 && first.filed.values.allSatisfy { $0 == "trip-planner" })
    let kept = try #require(store.load(id: "trip-planner"))
    #expect(kept.isKept && kept.agentName == "Trip Planner" && kept.agentRole == "plans the Lisbon trip")
    #expect(kept.harness == .claudeCode && kept.model == "claude-haiku-5-5" && kept.provider == "anthropic")
    for job in trip {
        let reloaded = try #require(store.load(id: job.id))
        #expect(reloaded.filedUnder == "trip-planner")
        #expect(reloaded.folderPath == job.folderPath, "the job folder stays where it was")
        let link = kept.folder.appendingPathComponent("jobs/\(job.id)")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../../../jobs/\(job.id)")
        #expect(FileManager.default.fileExists(atPath: link.appendingPathComponent("job.json").path), "the link resolves")
        #expect(await manager.job(job.id)?.filedUnder == "trip-planner")
    }
    #expect(store.load(id: recipe.id)?.filedUnder == nil)
    let memory = try String(contentsOf: kept.folder.appendingPathComponent("AGENTS.md"), encoding: .utf8)
    #expect(memory.contains("Trip is in May; prefers Alfama."))
    #expect(memory.contains("Lisbon Hotels (jobs/\(trip[1].id))"))

    let second = try await organizer.apply(proposal)
    #expect(second.created.isEmpty && second.filed.isEmpty)
    #expect(Set(second.alreadyFiled) == Set(trip.map(\.id)))
    #expect(try String(contentsOf: kept.folder.appendingPathComponent("AGENTS.md"), encoding: .utf8) == memory)
    let links = try FileManager.default.contentsOfDirectory(atPath: kept.folder.appendingPathComponent("jobs").path)
    #expect(links.count == 3)
    #expect(store.all().filter(\.isKept).count == 2, "Scribe and Trip Planner, nothing doubled")
    // Filed jobs drop out of the next round's candidates; kept agents' memory lists them.
    #expect(organizer.candidates().map(\.id) == [recipe.id])
    let clickyMemory = AgentClickyMemory.make(record: kept, store: store, running: false)
    #expect(clickyMemory["filed_jobs"]?.arrayValue?.count == 3)
    // Kept agents' artifacts don't list the linked job folders.
    #expect(AgentArtifacts.list(kept).allSatisfy { !$0.path.hasPrefix("jobs/") })
}

@Test func theOrganizerRunsOnceUnlessForced() async throws {
    let temp = AgentTempDir()
    let store = AgentJobStore(paths: temp.paths)
    let (trip, _) = try OrganizerFixtures.history(store)
    let model = ScriptedLanguageModel(reply: OrganizerFixtures.answer(trip))
    let clock = Date(timeIntervalSince1970: 1_793_500_000)
    let organizer = AgentOrganizer(store: store, client: model, model: "m", now: { clock })
    #expect(organizer.state.completedAt == nil)

    let (_, result) = try await organizer.runOnce()
    #expect(result.filed.count == 3)
    let state = AgentOrganizerState.load(temp.paths)
    #expect(state.completedAt == clock && state.groups == 1 && state.filedJobs == 3)

    await #expect(throws: AgentOrganizerError.alreadyDone(clock)) { try await organizer.runOnce() }
    #expect(model.requests.count == 1, "the flag stops it before any model call")

    // A new organizer (a relaunch) sees the flag too; forcing runs it again, and nothing is filed twice.
    let again = AgentOrganizer(store: AgentJobStore(paths: temp.paths), client: model, model: "m")
    await #expect(throws: AgentOrganizerError.alreadyDone(clock)) { try await again.runOnce() }
    await #expect(throws: AgentOrganizerError.tooFewJobs(1)) { try await again.runOnce(force: true) }
    // A dry run (propose only) never sets anything.
    let fresh = AgentTempDir()
    let freshStore = AgentJobStore(paths: fresh.paths)
    let (freshTrip, _) = try OrganizerFixtures.history(freshStore)
    let dry = AgentOrganizer(store: freshStore, client: ScriptedLanguageModel(reply: OrganizerFixtures.answer(freshTrip)), model: "m")
    _ = try await dry.propose()
    #expect(dry.state.completedAt == nil)
    #expect(freshStore.load(id: "trip-planner") == nil)
}

@Test func groupsNamedInOtherScriptsBecomeSeparateKeptAgents() async throws {
    // Names with no Latin letters used to slug to "job", so the second group was filed under the first kept agent.
    #expect(AgentJobStore.slug("旅行プランナー") != "job" && AgentJobStore.slug("家計ヘルパー") != "job")
    #expect(AgentJobStore.slug("旅行プランナー") != AgentJobStore.slug("家計ヘルパー"))
    #expect(AgentJobStore.slug("Путешествия") != "job" && AgentJobStore.slug("🧳") == "job")
    let temp = AgentTempDir()
    let store = AgentJobStore(paths: temp.paths)
    let base = Date(timeIntervalSince1970: 1_793_000_000)
    let jobs = try (0..<6).map { try OrganizerFixtures.job(store, "仕事 \($0)", ask: "仕事 \($0)", at: base.addingTimeInterval(Double($0))) }
    let proposal = AgentOrganizerProposal(groups: [
        .init(name: "旅行プランナー", role: "旅行", jobIDs: [jobs[0].id, jobs[1].id], notes: "五月の旅行"),
        .init(name: "家計ヘルパー", role: "家計", jobIDs: [jobs[2].id, jobs[3].id], notes: "毎月の予算"),
        // Names that still give no slug (only symbols) get numbered folders instead of sharing one.
        .init(name: "🧳", role: "bags", jobIDs: [jobs[4].id, jobs[5].id]),
    ], leftover: [])
    let organizer = AgentOrganizer(store: store, client: ScriptedLanguageModel(reply: ""), model: "m")
    let result = try await organizer.apply(proposal)
    #expect(result.created.count == 3 && Set(result.created).count == 3)
    let travel = try #require(store.all().first { $0.isKept && $0.agentName == "旅行プランナー" })
    let budget = try #require(store.all().first { $0.isKept && $0.agentName == "家計ヘルパー" })
    #expect(travel.id != budget.id)
    #expect(result.filed[jobs[0].id] == travel.id && result.filed[jobs[1].id] == travel.id)
    #expect(result.filed[jobs[2].id] == budget.id && result.filed[jobs[3].id] == budget.id)
    #expect(try String(contentsOf: budget.folder.appendingPathComponent("AGENTS.md"), encoding: .utf8).contains("毎月の予算"))

    // A second symbol-only name doesn't land on the first one's folder.
    let more = try (6..<8).map { try OrganizerFixtures.job(store, "仕事 \($0)", ask: "仕事 \($0)", at: base.addingTimeInterval(Double($0))) }
    let second = try await organizer.apply(AgentOrganizerProposal(groups: [.init(name: "💰", role: "money", jobIDs: more.map(\.id))], leftover: []))
    let money = try #require(second.created.first)
    #expect(money != result.filed[jobs[4].id])
    #expect(store.load(id: money)?.agentName == "💰")
    // The same name again joins the agent it already has.
    let third = try await organizer.apply(AgentOrganizerProposal(groups: [
        .init(name: "家計ヘルパー", role: "家計", jobIDs: [try OrganizerFixtures.job(store, "仕事 9", ask: "仕事 9").id]),
    ], leftover: []))
    #expect(third.created.isEmpty && third.filed.values.allSatisfy { $0 == budget.id } && third.filed.count == 1)
}

@Test func aSecondRunOverJobsAlreadyFiledMakesNoEmptyKeptAgent() async throws {
    // Two organizer runs at once (the launch run and the Settings button) propose over the same jobs.
    let temp = AgentTempDir()
    let store = AgentJobStore(paths: temp.paths)
    let (trip, _) = try OrganizerFixtures.history(store)
    let organizer = AgentOrganizer(store: store, client: ScriptedLanguageModel(reply: OrganizerFixtures.answer(trip)), model: "m")
    _ = try await organizer.apply(try await organizer.propose())
    let other = AgentOrganizerProposal(groups: [
        .init(name: "Travel Helper", role: "travel", jobIDs: trip.map(\.id), notes: "Lisbon in May"),
    ], leftover: [])
    let second = try await organizer.apply(other)
    #expect(second.created.isEmpty && second.filed.isEmpty)
    #expect(Set(second.alreadyFiled) == Set(trip.map(\.id)))
    #expect(store.load(id: "travel-helper") == nil)
    #expect(!FileManager.default.fileExists(atPath: temp.paths.agents.appendingPathComponent("travel-helper").path))
    #expect(store.all().filter(\.isKept).map(\.id).sorted() == ["scribe", "trip-planner"])
}
