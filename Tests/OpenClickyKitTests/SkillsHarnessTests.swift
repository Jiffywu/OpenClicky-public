import Foundation
import Testing
@testable import OpenClickyKit

private let openAI = ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai")
private let anthropic = ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic")

private func environment(_ temp: AgentTempDir, log: URL, scenario: String = "quick") -> [String: String] {
    ["PATH": "/usr/bin:/bin", "HOME": temp.url.path, "FAKE_SCENARIO": scenario, "FAKE_LOG": log.path]
}

private func skillLaunch(_ temp: AgentTempDir, executable: URL, auth: HarnessAuth, log: URL, skills: [AgentSkillSource]?) throws -> HarnessLaunch {
    let folder = temp.paths.jobs.appendingPathComponent("job-1", isDirectory: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("output"), withIntermediateDirectories: true)
    var launch = HarnessLaunch(folder: folder, instructions: "Test instructions.", model: "m", auth: auth, executable: executable,
                               paths: temp.paths, baseEnvironment: environment(temp, log: log))
    launch.skills = skills
    return launch
}

@Test func codexOnItsOwnHomeInstallsSkillsAndEnablesThemInConfig() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("codex.log")
    let fake = try temp.script("codex", FakeHarnessScripts.codex)
    let skills = BundledAgentSkills.all()
    let launch = try skillLaunch(temp, executable: fake, auth: .provider(openAI, apiKey: "k"), log: log, skills: skills)

    let plan = try CodexHarness().plan(for: launch)
    let toml = try #require(plan.configTOML)
    let browserFile = temp.paths.codexSkills.appendingPathComponent("openclicky-browser/SKILL.md").path
    #expect(toml.contains("[skills]\nconfig = [{ enabled = true, path = \"\(browserFile)\" }, { enabled = true, path = "))
    #expect(toml.contains("vercel-deploy/SKILL.md"))
    #expect(plan.extraSkillRoots.isEmpty, "Codex finds CODEX_HOME/skills itself")

    let session = try await CodexHarness().start(launch, message: "Go", images: [])
    _ = await collect(session.events, until: \.isTurnFinished)
    await session.close()
    #expect(FileManager.default.fileExists(atPath: browserFile))
    #expect(FileManager.default.fileExists(atPath: temp.paths.codexSkills.appendingPathComponent("openclicky-browser/references/safety.md").path))
    #expect(FileManager.default.isExecutableFile(atPath: temp.paths.codexSkills.appendingPathComponent("vercel-deploy/scripts/deploy.sh").path))
    let written = try String(contentsOf: temp.paths.codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
    #expect(written.contains("[skills]"))
    #expect(!(try String(contentsOf: log, encoding: .utf8)).contains("skills/extraRoots/set"))
}

@Test func codexOnTheUsersHomeAddsOpenClickysSkillsAsAnExtraRoot() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("codex.log")
    let fake = try temp.script("codex", FakeHarnessScripts.codex)
    let launch = try skillLaunch(temp, executable: fake, auth: .harnessLogin, log: log, skills: BundledAgentSkills.all())
    let harness = CodexHarness(hasLogin: { _ in false }, listUserMCPServers: { _, _ in [] })

    let plan = try harness.plan(for: launch)
    #expect(plan.configTOML == nil)
    #expect(!plan.arguments.contains { $0.hasPrefix("skills.") }, "a -c skills.config would replace the user's own list")
    #expect(plan.extraSkillRoots == [temp.paths.codexSkills])

    let session = try await harness.start(launch, message: "Go", images: [])
    _ = await collect(session.events, until: \.isTurnFinished)
    await session.close()
    let sent = try String(contentsOf: log, encoding: .utf8)
    let roots = try #require(sent.range(of: #""method":"skills/extraRoots/set""#))
    #expect(sent.contains(#""extraRoots":[""# + temp.paths.codexSkills.path.replacingOccurrences(of: "/", with: "\\/")) || sent.contains(#""extraRoots":[""# + temp.paths.codexSkills.path))
    #expect(roots.lowerBound < sent.range(of: #""method":"thread/start""#)!.lowerBound, "before the thread starts")
    #expect(FileManager.default.fileExists(atPath: temp.paths.codexSkills.appendingPathComponent("openclicky-browser/SKILL.md").path))
}

@Test func harnessesLeaveSkillFoldersAloneWithoutSkills() throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("h.log")
    let codex = try temp.script("codex", FakeHarnessScripts.codex)
    let claude = try temp.script("claude", FakeHarnessScripts.claude)
    let codexPlan = try CodexHarness().plan(for: try skillLaunch(temp, executable: codex, auth: .provider(openAI, apiKey: "k"), log: log, skills: nil))
    #expect(codexPlan.skillsFolder == nil)
    #expect(codexPlan.configTOML?.contains("[skills]") == false)
    let claudePlan = try ClaudeCodeHarness().plan(for: try skillLaunch(temp, executable: claude, auth: .provider(anthropic, apiKey: "k"), log: log, skills: []))
    #expect(!claudePlan.arguments.contains("--plugin-dir"))
}

@Test func claudeCodeLoadsTheSkillsPluginForLoginAndKeyRuns() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("claude.log")
    let fake = try temp.script("claude", FakeHarnessScripts.claude)
    for auth in [HarnessAuth.harnessLogin, .provider(anthropic, apiKey: "k")] {
        let plan = try ClaudeCodeHarness().plan(for: try skillLaunch(temp, executable: fake, auth: auth, log: log, skills: BundledAgentSkills.all()))
        let index = try #require(plan.arguments.firstIndex(of: "--plugin-dir"))
        #expect(plan.arguments[index + 1] == temp.paths.claudeSkillsPlugin.path)
        #expect(plan.arguments.contains("project,local"), "the user's own settings still stay out")
    }
    let session = try await ClaudeCodeHarness().start(
        try skillLaunch(temp, executable: fake, auth: .harnessLogin, log: log, skills: BundledAgentSkills.all()), message: "Go", images: [])
    _ = await collect(session.events, until: \.isTurnFinished)
    await session.close()
    #expect(FileManager.default.fileExists(atPath: temp.paths.claudeSkillsPlugin.appendingPathComponent(".claude-plugin/plugin.json").path))
    #expect(FileManager.default.fileExists(atPath: temp.paths.claudeSkillsPlugin.appendingPathComponent("skills/openclicky-browser/SKILL.md").path))
}

/// A manager on the fake harnesses with a skill source provider, as the app and occtl set it up.
private func manager(_ temp: AgentTempDir, log: URL, harness: HarnessKind, claude: URL? = nil) throws -> AgentManager {
    let codex = try temp.script("codex", FakeHarnessScripts.codex)
    let claudeScript = try claude ?? temp.script("claude", FakeHarnessScripts.claude)
    let env = environment(temp, log: log)
    return AgentManager(store: AgentJobStore(paths: temp.paths)) { _ in
        let provider = harness == .codex ? openAI : anthropic
        return AgentLaunchSettings(harness: harness, model: "m", providerID: provider.id, auth: .provider(provider, apiKey: "k"),
                                   executable: harness == .codex ? codex : claudeScript, baseEnvironment: env)
    }
}

@Test func everyLaunchInstallsTheCurrentSkillsAndNamesThemInTheInstructions() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("codex.log")
    let manager = try manager(temp, log: log, harness: .codex)
    let library = SkillsLibrary(directory: temp.url.appendingPathComponent("Skills"), stateURL: temp.url.appendingPathComponent("skills.json"))
    try library.create(SkillMetadata(name: "Pitch decks", description: "Slides with one idea each.", builtFor: "Keynote"), body: "x", enable: true)
    let registryURL = temp.url.appendingPathComponent("connectors.json")
    var registry = ConnectorRegistry()
    registry.connectors = [ConnectorPreset.named("linear")!.connector]
    try registry.save(to: registryURL)
    await manager.setSkillSources { AgentSkillSources.current(library: library, registry: try? ConnectorRegistry.load(from: registryURL)) }

    let updates = await manager.subscribe()
    let first = try await manager.spawn(AgentSpawnRequest(task: "Plan the sprint"), waitForStart: true)
    _ = await nextJobReport(updates, for: first.record.id)
    let sent = try String(contentsOf: log, encoding: .utf8)
    #expect(sent.contains("# Skills"))
    #expect(sent.contains("`openclicky-browser`: before your first call to the browser tool"))
    #expect(sent.contains("`linear` for Linear"))
    #expect(sent.contains("`pitch-decks` (Pitch decks)"))
    for name in ["openclicky-browser", "vercel-deploy", "linear", "pitch-decks"] {
        #expect(FileManager.default.fileExists(atPath: temp.paths.codexSkills.appendingPathComponent("\(name)/SKILL.md").path), "\(name) installed")
    }
    let installed = SkillFile.parse(try String(contentsOf: temp.paths.codexSkills.appendingPathComponent("pitch-decks/SKILL.md"), encoding: .utf8))
    #expect(installed.name == "pitch-decks")

    // Disconnect Linear and switch the skill off: the next launch removes both and keeps the bundled ones.
    try ConnectorRegistry().save(to: registryURL)
    try library.disableAll()
    let second = try await manager.spawn(AgentSpawnRequest(task: "Something else entirely"), waitForStart: true)
    _ = await nextJobReport(updates, for: second.record.id)
    #expect(!FileManager.default.fileExists(atPath: temp.paths.codexSkills.appendingPathComponent("linear").path))
    #expect(!FileManager.default.fileExists(atPath: temp.paths.codexSkills.appendingPathComponent("pitch-decks").path))
    #expect(FileManager.default.fileExists(atPath: temp.paths.codexSkills.appendingPathComponent("openclicky-browser/SKILL.md").path))
}

private func nextJobReport(_ updates: AsyncStream<AgentManagerUpdate>, for jobID: String, timeout: Double = 15) async -> AgentJobReport? {
    await withTaskGroup(of: AgentJobReport?.self) { group in
        group.addTask {
            for await update in updates {
                if case .report(let report) = update, report.jobID == jobID { return report }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

// MARK: - Creating a skill from a brain dump

/// Behaves like Claude Code writing a skill: on the first message it saves output/SKILL.md and a reference, then
/// reports. `FAKE_SCENARIO=nothing` reports without writing anything.
private let skillWriter = #"""
#!/bin/sh
LOG="${FAKE_LOG:-/dev/null}"
S='"session_id":"sess-skill"'
while IFS= read -r line; do
  printf 'in: %s\n' "$line" >> "$LOG"
  case "$line" in
    *'"type":"user"'*)
      printf '%s\n' '{"type":"system","subtype":"init","cwd":"/tmp/job",'"$S"',"tools":["Write"],"model":"fake"}'
      if [ "$FAKE_SCENARIO" != nothing ]; then
        mkdir -p output/references
        printf -- '---\nname: Weekly status email\ndescription: "Use when the user asks for their Friday status email: wins, risks, next week."\none_liner: Friday status emails in my format.\ncategory: Writing\ntags: [email, status, weekly]\n---\n\n# Weekly status email\n\nThree sections: wins, risks, next week.\n' > output/SKILL.md
        printf 'Example email.\n' > output/references/example.md
        printf 'notes\n' > output/stray.txt
      fi
      printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"Done.\n\n<report>\nsay: Your skill is written.\ntitle: Weekly status email\nfiles:\n- output/SKILL.md\n</report>",'"$S"'}'
      ;;
  esac
done
"""#

@Test func aBrainDumpBecomesALibrarySkillThroughAnAgentJob() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("claude.log")
    let writer = try temp.script("claude-skill", skillWriter)
    let manager = try manager(temp, log: log, harness: .claudeCode, claude: writer)
    let library = SkillsLibrary(directory: temp.url.appendingPathComponent("Skills"), stateURL: temp.url.appendingPathComponent("skills.json"))
    try library.create(name: "Weekly status email", description: "Taken already.", body: "x")
    let creator = SkillCreator(library: library)

    await #expect(throws: SkillCreationError.emptyBrainDump) { try await creator.start(brainDump: "  \n", manager: manager) }
    let updates = await manager.subscribe()
    let record = try await creator.start(brainDump: "every friday I send my boss wins / risks / next week, short bullets", manager: manager,
                                         waitForStart: true)
    #expect(record.status == .creating)
    #expect(creator.store.all().map(\.id) == [record.id])
    _ = await nextJobReport(updates, for: record.jobID)

    let sent = try String(contentsOf: log, encoding: .utf8)
    #expect(sent.contains("Save it as output/SKILL.md"))
    #expect(sent.contains("every friday I send my boss wins"))

    #expect(await agentEventually { await !manager.isRunning(record.jobID) })
    let changed = await creator.collect(manager: manager)
    let done = try #require(changed.first)
    #expect(done.status == .ready)
    #expect(done.skillID == "weekly-status-email-2", "a name already in use gets a number")
    let skill = try #require(library.skill("weekly-status-email-2"))
    #expect(skill.name == "Weekly status email" && skill.category == "Writing" && skill.tags == ["email", "status", "weekly"])
    #expect(!skill.isEnabled, "new skills start off until the user reviews them")
    #expect(FileManager.default.fileExists(atPath: skill.folder.appendingPathComponent("references/example.md").path))
    #expect(!FileManager.default.fileExists(atPath: skill.folder.appendingPathComponent("stray.txt").path))
    #expect(await creator.collect(manager: manager).isEmpty, "collected once")
    #expect(creator.store.record(record.id)?.status == .ready)
}

@Test func aSkillJobThatWritesNothingIsMarkedFailed() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("claude.log")
    let writer = try temp.script("claude-skill", skillWriter)
    let manager = AgentManager(store: AgentJobStore(paths: temp.paths)) { _ in
        AgentLaunchSettings(harness: .claudeCode, model: "m", providerID: "anthropic", auth: .provider(anthropic, apiKey: "k"),
                            executable: writer, baseEnvironment: environment(temp, log: log, scenario: "nothing"))
    }
    let library = SkillsLibrary(directory: temp.url.appendingPathComponent("Skills"), stateURL: temp.url.appendingPathComponent("skills.json"))
    let creator = SkillCreator(library: library)
    let updates = await manager.subscribe()
    let record = try await creator.start(brainDump: "a skill about nothing", manager: manager, waitForStart: true)
    _ = await nextJobReport(updates, for: record.jobID)
    #expect(await agentEventually { await !manager.isRunning(record.jobID) })
    let failed = try #require(await creator.collect(manager: manager).first)
    #expect(failed.status == .failed)
    #expect(failed.message?.contains("didn't write a SKILL.md") == true)
    #expect(failed.message?.contains("Your skill is written.") == true)
    #expect(library.skills.isEmpty)
}
