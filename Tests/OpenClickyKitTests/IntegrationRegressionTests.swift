import Foundation
import Testing
@testable import OpenClickyKit

@Suite struct IntegrationRegressionTests {
    @Test func anExternalAppendThenOurAppendCountsBothInCachedTotals() throws {
        let directory = InfraUsageTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = UsageLedger(directory: directory), cli = UsageLedger(directory: directory)
        try app.setLimits(UsageLimits(dailyUSD: 3, monthlyUSD: 3, stopAtLimit: true))
        app.record(InfraUsageTests.record("brain", surface: "app", cost: 1, at: Date()))
        #expect(app.spending().today == 1)
        cli.record(InfraUsageTests.record("brain", surface: "cli", cost: 1, at: Date()))
        app.record(InfraUsageTests.record("brain", surface: "app", cost: 1, at: Date()))
        #expect(app.spending().today == 3)
        #expect(app.spending().month == 3)
        #expect(app.limitStatus().blocksCalls)
        #expect(cli.limitStatus().blocksCalls)
    }

    @Test func trashFailureLeavesFilesAndEnabledStateIntact() throws {
        let directory = InfraUsageTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SkillsLibrary(directory: directory.appendingPathComponent("Skills"), stateURL: directory.appendingPathComponent("skills.json"),
                                    trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        let skill = try library.create(name: "Fixture", description: "Fixture only", body: "Keep these bytes.")
        try library.setEnabled(skill.id, true)
        let bytes = try Data(contentsOf: skill.file)
        let state = try Data(contentsOf: library.stateURL)
        #expect(throws: (any Error).self) { try library.remove(skill.id) }
        #expect(try Data(contentsOf: skill.file) == bytes)
        #expect(try Data(contentsOf: library.stateURL) == state)
        #expect(library.skill(skill.id)?.isEnabled == true)
    }

    @Test func concurrentProcessesCreateAndAppendCompleteCountedRecords() async throws {
        let root = InfraUsageTests.temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var folder = Bundle(for: LedgerBundleAnchor.self).bundleURL.deletingLastPathComponent()
        var executable: URL?
        for _ in 0..<8 {
            let candidate = folder.appendingPathComponent("UsageLedgerProbe")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { executable = candidate; break }
            folder.deleteLastPathComponent()
        }
        let probe = try #require(executable)
        let directory = root.appendingPathComponent("Usage")
        let barrier = root.appendingPathComponent("go")
        let now = Date()
        let processes = try (0..<6).map { writer in
            let process = Process()
            process.executableURL = probe
            process.arguments = [directory.path, String(writer), "120", barrier.path, String(now.timeIntervalSince1970)]
            // Nothing is read from the probes, so they get no pipes: an inherited or unread pipe can fill and block a
            // writer forever.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        let ready = await waitUntil { (0..<6).allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready-\($0)").path) } }
        #expect(ready)
        try Data().write(to: barrier)
        // `waitUntilExit()` blocks a cooperative thread (and spins its run loop) with no time limit; under parallel
        // test load that could hang the whole run. Poll instead, and stop the probes if they overrun.
        let exited = await Self.waitForExit(processes, timeout: 60)
        #expect(exited, "the ledger probes didn't finish within 60 s")
        guard exited else { return }
        for process in processes { #expect(process.terminationStatus == 0) }
        let ledger = UsageLedger(directory: directory, now: { now })
        let records = ledger.records(from: .distantPast)
        #expect(records.count == 720)
        #expect(Set(records.compactMap(\.turn)).count == 720)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" {
            let lines = try Data(contentsOf: file).split(separator: 10)
            #expect(lines.count == 720)
            for line in lines { _ = try JSONSerialization.jsonObject(with: line) }
        }
        #expect(ledger.spending().today == 720)
        #expect(ledger.spending().month == 720)
    }
}

private final class LedgerBundleAnchor: NSObject {}

extension IntegrationRegressionTests {
    /// Waits for every process to exit without blocking a thread, for at most `timeout` seconds; on timeout the ones
    /// still running are terminated and false comes back.
    static func waitForExit(_ processes: [Process], timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while processes.contains(where: \.isRunning) {
            guard Date() < deadline else {
                for process in processes where process.isRunning { process.terminate() }
                return false
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func theProcessWaitIsBounded() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        sleeper.standardOutput = FileHandle.nullDevice
        sleeper.standardError = FileHandle.nullDevice
        try sleeper.run()
        let started = Date()
        #expect(await Self.waitForExit([sleeper], timeout: 0.3) == false)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(await Self.waitForExit([sleeper], timeout: 5))
    }
}

extension IntegrationRegressionTests {
    @Test func aLimitsReplacementWithTheSameTimestampIsReadFresh() throws {
        let directory = InfraUsageTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = UsageLedger(directory: directory), cli = UsageLedger(directory: directory)
        try app.setLimits(UsageLimits(dailyUSD: 5, stopAtLimit: true))
        _ = app.limitStatus()
        let oldDate = try FileManager.default.attributesOfItem(atPath: app.limitsURL.path)[.modificationDate]
        try cli.setLimits(UsageLimits(dailyUSD: 1, stopAtLimit: true))
        if let oldDate { try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: app.limitsURL.path) }
        #expect(app.limits().dailyUSD == 1)
    }

    @Test func meteringPreservesWarmConnectionsAndSessionReadiness() async throws {
        let collector = UsageCollector()
        let resilience = ProviderResilience(recorder: collector)
        let factory = EngineFactory(config: InfraFixtures.config, catalog: try ModelCatalog.builtIn(),
                                    credentials: InMemoryCredentialStore(), resilience: resilience)
        let identity = try #require(factory.identity(for: .stt, resilience: resilience))
        let base = VoiceEarsTests.WarmingSTT()
        let metered = MeteredSpeechToTextClient(base: base, identity: identity, resilience: resilience)
        let warming = MeteredWarmingSpeechToTextClient(client: metered, warming: base)
        await warming.warmUp(language: "en", keywords: [])
        #expect(await warming.waitUntilWarm(language: "en", keywords: []))
        await warming.discardWarmSocket()
        #expect(base.warmUps == 1 && base.discards == 1)
        let session = try await metered.startSession(language: nil, keywords: [])
        let readiness = try #require(session as? any SpeechToTextSessionReadiness)
        #expect(await readiness.waitUntilReady())
        await session.send(Data(count: 32_000))
        await session.finish()
        #expect(collector.records.count == 1)
    }
}
