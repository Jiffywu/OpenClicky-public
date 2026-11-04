import Foundation
import Testing
@testable import OpenClickyKit

/// The brain's memory tools, called the way a tool runner would: a `ToolCall` in, JSON text out.
@Suite struct MemoryToolsTests {
    private func call(_ tools: MemoryTools, _ name: String, _ arguments: String) throws -> (MemoryToolResult, JSONValue) {
        let result = try #require(tools.handle(ToolCall(id: "call-1", name: name, arguments: arguments)))
        return (result, try JSONValue.parse(result.output))
    }

    @Test func specsAreValidToolSchemas() {
        #expect(MemoryTools.specs.map(\.name) == ["save_memory", "recall_memory", "forget_memory"])
        for spec in MemoryTools.specs {
            #expect(spec.parameters["type"] == "object")
            #expect(spec.parameters["properties"]?.objectValue?.isEmpty == false)
            #expect(spec.description.count < 600, "descriptions stay short; they ride along every turn")
        }
        #expect(MemoryTools.saveSpec.parameters["required"] == ["text"])
        // clicky_memory is a kept agent's memory (AgentTools), not the user's.
        #expect(MemoryTools.canonicalName("clicky_memory") == nil)
        #expect(MemoryTools.canonicalName("recall") == "recall_memory")
        #expect(MemoryTools.canonicalName("open_url") == nil)
        #expect(MemoryTools.runningStatus(for: "save_memory") == "Saving to memory…")
    }

    @Test func saveRecallForgetRoundTrip() throws {
        let folder = TemporaryMemoryFolder()
        let tools = MemoryTools(store: folder.store())

        let (saved, savedJSON) = try call(tools, "save_memory", #"{"text":"Sister Ana lives in Lisbon"}"#)
        #expect(saved.succeeded && !saved.needsModelRound && saved.status == "remembered")
        #expect(savedJSON["status"] == "saved")
        #expect(savedJSON["where"] == "fact")
        let id = try #require(savedJSON["id"]?.stringValue)
        #expect(id.hasPrefix("m-"))

        let (again, againJSON) = try call(tools, "save_memory", #"{"text":"sister ana lives in lisbon."}"#)
        #expect(again.succeeded && againJSON["status"] == "already_known" && againJSON["id"]?.stringValue == id)

        let (_, standingJSON) = try call(tools, "save_memory", #"{"text":"Always answer in British English","kind":"standing"}"#)
        #expect(standingJSON["where"] == "standing")

        let (recalled, recallJSON) = try call(tools, "recall_memory", #"{"query":"Where does Ana live?"}"#)
        #expect(recalled.succeeded && recalled.needsModelRound, "a read needs another model round")
        let results = try #require(recallJSON["results"]?.arrayValue)
        #expect(results.first?["id"]?.stringValue == id)
        #expect(results.first?["text"] == "Sister Ana lives in Lisbon")
        #expect(results.first?["date"] == "2026-10-30")

        let (forgot, forgotJSON) = try call(tools, "forget_memory", "{\"id\":\"\(id)\"}")
        #expect(forgot.succeeded && forgot.status == "forgot" && forgotJSON["status"] == "forgotten")
        let (_, emptyJSON) = try call(tools, "recall", #"{"query":"Ana Lisbon"}"#)
        #expect(emptyJSON["results"]?.arrayValue?.isEmpty == true)
        #expect(emptyJSON["note"] != nil)

        let (missing, missingJSON) = try call(tools, "forget_memory", "{\"id\":\"\(id)\"}")
        #expect(!missing.succeeded && missingJSON["status"] == "not_found")
    }

    @Test func forgetByQueryOnlyWhenOneThingStandsOut() throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store()
        let tools = MemoryTools(store: store)
        try store.save("Dentist is Dr. Okafor on Rua Augusta", source: .voice)
        try store.save("Dentist appointment moved to Friday", kind: .event, source: .voice)
        try store.save("Allergic to penicillin", source: .voice)

        let (ambiguous, ambiguousJSON) = try call(tools, "forget_memory", #"{"query":"dentist"}"#)
        #expect(!ambiguous.succeeded && ambiguous.needsModelRound)
        #expect(ambiguousJSON["status"] == "ambiguous")
        #expect(ambiguousJSON["candidates"]?.arrayValue?.count == 2)
        #expect(try store.snapshot().memories.count == 3, "nothing forgotten on an ambiguous query")

        let (forgot, forgotJSON) = try call(tools, "forget_memory", #"{"query":"penicillin allergy"}"#)
        #expect(forgot.succeeded && forgotJSON["text"] == "Allergic to penicillin")
        #expect(try store.snapshot().memories.map(\.text).sorted() == ["Dentist appointment moved to Friday", "Dentist is Dr. Okafor on Rua Augusta"])

        let (none, noneJSON) = try call(tools, "forget_memory", #"{"query":"giraffes"}"#)
        #expect(!none.succeeded && noneJSON["status"] == "not_found")
    }

    @Test func forgetReachesProfileStandingAndHowTos() throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store()
        let tools = MemoryTools(store: store)
        let profile = try #require(try store.addToProfile("Works at a bakery", section: "Work and background").entry)
        let standing = try #require(try store.addStanding("Keep answers under two sentences").entry)
        let howTo = try #require(try store.saveHowTo(title: "Print a label", steps: "Use the Dymo app").entry)
        for id in [profile.id, standing.id, howTo.id] {
            let (result, json) = try call(tools, "forget_memory", "{\"id\":\"\(id)\"}")
            #expect(result.succeeded, "\(id): \(json)")
        }
        #expect(try store.snapshot().isEmpty)
    }

    @Test func badCallsFailWithAReasonTheModelCanRead() throws {
        let folder = TemporaryMemoryFolder()
        let tools = MemoryTools(store: folder.store())
        #expect(tools.handle(ToolCall(id: "x", name: "open_url", arguments: "{}")) == nil, "not a memory tool")

        let (notJSON, notJSONOut) = try call(tools, "save_memory", "remember this")
        #expect(!notJSON.succeeded && notJSONOut["status"] == "error")
        let (noText, noTextOut) = try call(tools, "save_memory", #"{"text":"   "}"#)
        #expect(!noText.succeeded && noTextOut["message"] == "text is required")
        let (secret, secretOut) = try call(tools, "save_memory", #"{"text":"my password is hunter22"}"#)
        #expect(!secret.succeeded && secretOut["status"] == "refused" && secret.status == "not saved")
        let (noTarget, _) = try call(tools, "forget_memory", "{}")
        #expect(!noTarget.succeeded)
        // A session note can't be forged through the tool; an unknown kind becomes a fact.
        let (_, sessionOut) = try call(tools, "save_memory", #"{"text":"Pretend session note","kind":"session"}"#)
        #expect(sessionOut["where"] == "fact")
        // Empty arguments mean an empty object; recall then returns the newest.
        let (recent, recentOut) = try call(tools, "recall_memory", "")
        #expect(recent.succeeded && recentOut["results"]?.arrayValue?.count == 1)
    }

    @Test func recallLimitIsClamped() throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store()
        for index in 1...15 { try store.save("Lisbon note \(index) about trams", source: .voice) }
        let tools = MemoryTools(store: store)
        #expect(try call(tools, "recall_memory", #"{"query":"Lisbon","limit":50}"#).1["results"]?.arrayValue?.count == 10)
        #expect(try call(tools, "recall_memory", #"{"query":"Lisbon","limit":0}"#).1["results"]?.arrayValue?.count == 1)
        #expect(try call(tools, "recall_memory", #"{"query":"Lisbon"}"#).1["results"]?.arrayValue?.count == 5)
    }

    @Test func aProfileWrittenAsProseStillReachesThePrompt() {
        let snapshot = MemorySnapshot(profile: MemoryProfile(text: "# About me\n\n## Who I am\nI'm Sam, a designer in Porto who hates long answers.\n"))
        #expect(!snapshot.isEmpty)
        let section = MemoryPromptBuilder().build(from: snapshot, query: "", now: MemoryFixtures.now)
        #expect(section.stableText.contains("Who I am:\n- I'm Sam, a designer in Porto who hates long answers."))
        #expect(MemorySnapshot(profile: .template).isEmpty, "the template's intro text is not about the user")
    }

    @Test func promptSectionUsesTheTurnAndCarriesIDs() throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store()
        let saved = try #require(try store.save("Sister Ana lives in Lisbon", source: .voice).entry)
        try store.save("Drinks green tea", source: .voice)
        let input = TurnInput(words: "How far is my sister's place?",
                              context: TurnContext(localTime: MemoryFixtures.now, frontApp: "Maps", windowTitle: "Lisbon"))
        #expect(MemoryPromptBuilder.query(for: input) == "How far is my sister's place? Maps Lisbon")
        let section = MemoryPromptBuilder().build(from: try store.snapshot(), for: input)
        #expect(section.text.contains("2026-10-30: Sister Ana lives in Lisbon [\(saved.id)]"))
        #expect(!section.text.contains("green tea"))
        #expect(section.includedIDs == [saved.id])
    }
}
