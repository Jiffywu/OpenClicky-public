import Foundation
import OpenClickyKit

/// One `occtl` subcommand. Features add theirs as a new file in Commands/ and one line in `Occtl.commands`.
struct OcctlCommand: Sendable {
    let name: String
    let usage: String
    let run: @Sendable ([String]) async throws -> Void
}

enum Occtl {
    /// Every subcommand. Keep one entry per line so parallel branches merge cleanly.
    static let commands: [OcctlCommand] = [
        CoreCommands.initConfig,
        CoreCommands.validate,
        CoreCommands.models,
        CoreCommands.key,
        BrowserCommands.browser,
        EngineCommands.engines,
        EngineCommands.say,
        ChatCommands.chat,
        LookupCommands.lookup,
        AudioCommands.audio,
        DictationCommands.dictation,
        ScreenCommands.screen,
        ToolsCommands.tools,
        MemoryCommand.memory,
        TranscribeCommands.transcribe,
        AgentCommands.agent,
        AgentReportCommands.command,
        AppsCommands.command,
        FigureCommands.figure,
        DrawCommands.draw,
        GuidedCommands.guided,
        GuidedCommands.highlight,
        GroundCommands.command,
        SkillsCommands.skills,
        HistoryCommands.history,
        VoicesCommands.voices,
        OnboardingCommands.onboarding,
        TakeoverCommands.command,
        BrainCommands.brain,
        RealtimeCommands.realtime,
        TurnCommands.turn,
        OverlayCommands.overlay,
        LatencyCommands.latency,
        NotchCommands.command,
        RoutinesCommands.routines,
        URLCommands.url,
        SoundcheckCommands.command,
        QuietCommands.command,
        InfraCommands.usage,
        InfraCommands.probe,
        InfraCommands.diagnostics,
        InfraCommands.flags,
    ]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let name = arguments.first, let command = Occtl.commands.first(where: { $0.name == name }) else {
    let usage = Occtl.commands.map { "  occtl \($0.usage)" }.joined(separator: "\n")
    fail("Usage:\n\(usage)")
}
// Retries, plain provider explanations and the usage ledger for every engine occtl builds (docs/infra.md).
ProviderResilience.install(.standard(client: "occtl"))
do {
    try await UsageContext.$current.withValue(UsageContext(surface: .occtl)) {
        try await command.run(Array(arguments.dropFirst()))
    }
} catch {
    fail("Error: \(error)")
}
