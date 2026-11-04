import Foundation
import Testing
@testable import OpenClickyKit

// The blocks agents may add to their final message next to <report>: ANSWER, ROUTINE, WAIT_FOR and LEARNED. Each is
// parsed on its own (valid, malformed, mixed with the report block) and reaches the job record, the report and the card.

private let fixed = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct AgentFinalBlocksTests {
    @Test func anAnswerWithNumbersSitsBesideTheReport() {
        let text = """
        Prices are down this week.

        <report>
        say: The cheapest flight dropped to 129 dollars.
        title: Flight Prices
        </report>
        <answer>{"outcome": "Cheapest SFO to DEN is $129", "numbers": [{"value": "$129", "label": "United 7:05", "was": "$154", "better": "lower"}, {"value": 3, "label": "nonstops"}], "note": "Checked at 10:40"}</answer>
        """
        let report = AgentFinalReport.parse(text, now: fixed)
        #expect(report.spoken == "The cheapest flight dropped to 129 dollars.")
        #expect(report.title == "Flight Prices")
        #expect(report.markdown == "Prices are down this week.")
        let answer = try! #require(report.answer)
        #expect(answer.outcome == "Cheapest SFO to DEN is $129")
        #expect(answer.numbers == [AgentAnswer.Number(value: "$129", label: "United 7:05", was: "$154", better: .lower),
                                   AgentAnswer.Number(value: "3", label: "nonstops")])
        #expect(answer.numbersLook == .changes)
        #expect(answer.blocks == [.numbers])
        #expect(answer.note == "Checked at 10:40")
        #expect(report.blockProblems == nil)
    }

    @Test func everyAnswerKindParsesAndAtMostTwoBlocksShow() throws {
        let list = try AgentAnswer.parse(#"{"outcome":"Top picks","list":[{"text":"Lisbon","detail":"€420"},{"text":"Porto","detail":"€390"},"Madrid"],"ranked":true}"#)
        #expect(list.list?.map(\.text) == ["Lisbon", "Porto", "Madrid"])
        #expect(list.ranked == true && list.blocks == [.list])

        let done = try AgentAnswer.parse(#"{"outcome":"Invites sent","done":[{"did":"Sent","what":"the invite to Sam","link":"https://calendar.example/e/1"},{"did":"Booked","what":"room 4B"}]}"#)
        #expect(done.done?.count == 2 && done.done?[0].link == "https://calendar.example/e/1")

        let draft = try AgentAnswer.parse(#"{"outcome":"Reply drafted","draft":{"text":"Hi Sam, Thursday works.","to":"Sam"}}"#)
        #expect(draft.draft == AgentAnswer.Draft(text: "Hi Sam, Thursday works.", to: "Sam"))

        let ask = try AgentAnswer.parse(#"{"outcome":"Which venue?","ask":[{"answer":"The Loft","detail":"seats 40"},{"answer":"Pier 7"},{"file":"/tmp/plan.pdf"}]}"#)
        #expect(ask.ask?.map(\.reply) == ["The Loft", "Pier 7", "Use /tmp/plan.pdf"])

        let progress = try AgentAnswer.parse(#"{"numbers":[{"value":"12","label":"tasks done","of":"20"}]}"#)
        #expect(progress.numbersLook == .progress && progress.outcome == nil)
        let hero = try AgentAnswer.parse(#"{"numbers":[{"value":"42","label":"open tickets"}]}"#)
        #expect(hero.numbersLook == .hero)

        let many = try AgentAnswer.parse(#"{"outcome":"x","done":[{"did":"Sent","what":"a"}],"ask":["Yes","No"],"numbers":[{"value":"1","label":"n"}],"list":["a","b"]}"#)
        #expect(many.blocks == [.done, .ask])

        let quiet = try AgentAnswer.parse(#"{"quiet": true}"#)
        #expect(quiet.quiet == true && quiet.blocks.isEmpty)
    }

    @Test func longAnswerValuesAreShortenedAndExtrasDropped() throws {
        let answer = try AgentAnswer.parse("""
        {"outcome": "\(String(repeating: "a", count: 200))", "numbers": [{"value": "1234567890123", "label": "big"}, {"value": "1", "label": "b"}, {"value": "2", "label": "c"}, {"value": "3", "label": "d"}], "note": "\(String(repeating: "n", count: 100))"}
        """)
        #expect(answer.outcome?.count == 90)
        #expect(answer.numbers?.count == 3)
        #expect(answer.numbers?[0].value.count == 9)
        #expect(answer.note?.count == 70)
    }

    @Test func malformedBlocksAreDroppedWithANoteAndTheReportSurvives() {
        let text = """
        Done.
        <ANSWER>{"outcome": "half a json"</ANSWER>
        <routine>{"action": "create", "title": "Inbox"}</routine>
        <wait_for>{"page": "https://example.com"}</wait_for>
        <learned>no topic here</learned>
        <report>
        say: Finished the summary.
        </report>
        """
        let report = AgentFinalReport.parse(text, now: fixed)
        #expect(report.spoken == "Finished the summary.")
        #expect(report.markdown == "Done.")
        #expect(report.answer == nil && report.routineRequests == nil && report.waitFor == nil && report.learned == nil)
        let problems = report.blockProblems ?? []
        #expect(problems.count == 4)
        #expect(problems.contains("ANSWER: no JSON object") || problems.contains("ANSWER: not valid JSON"))
        #expect(problems.contains("ROUTINE: create needs a task"))
        #expect(problems.contains("WAIT_FOR: needs a step"))
        #expect(problems.contains { $0.hasPrefix("LEARNED:") })
    }

    @Test func tagsMatchInAnyCaseWithSpacesAndAnUnclosedBlockStopsAtTheReport() {
        let text = """
        Body text.
        < Wait_For >{"step": "Approve the sign-in on your phone", "page": "https://accounts.example.com", "done_when_url_contains": "/welcome"}
        <report>
        say: I need you to approve the sign-in.
        </report>
        """
        let report = AgentFinalReport.parse(text, now: fixed)
        #expect(report.waitFor == AgentUserStep(step: "Approve the sign-in on your phone", page: "https://accounts.example.com",
                                                doneWhenURLContains: "/welcome", askedAt: fixed))
        #expect(report.spoken == "I need you to approve the sign-in.")
        #expect(report.markdown == "Body text.")
    }

    @Test func tagsMentionedInProseOrQuotedInCodeStayText() {
        let text = """
        No <wait_for> step is needed; you're already signed in. I left the <learned> block out too.
        Files: report.md
        Here is the format I used:
        ```
        <learned>Mail: always archive first</learned>
        <wait_for>{"step": "Quoted step"}</wait_for>
        ```
        <report>
        say: All set.
        </report>
        """
        let report = AgentFinalReport.parse(text, now: fixed)
        #expect(report.waitFor == nil)
        #expect(report.learned == nil)
        #expect(report.blockProblems == nil)
        #expect(report.spoken == "All set.")
        #expect(report.markdown.contains("No <wait_for> step is needed; you're already signed in."))
        #expect(report.markdown.contains("Files: report.md"))
        #expect(report.markdown.contains("<learned>Mail: always archive first</learned>"))

        // A closed plain-sentence step, and an unclosed one in JSON, are still steps.
        #expect(AgentFinalReport.parse("<wait_for>Approve the sign-in</wait_for>\n<report>\nsay: Waiting.\n</report>", now: fixed).waitFor?.step
                == "Approve the sign-in")
        #expect(AgentFinalReport.parse("<wait_for>{\"step\": \"Approve it\"}\n<report>\nsay: Waiting.\n</report>", now: fixed).waitFor?.step
                == "Approve it")
    }

    @Test func routineBlocksParseSchedulesAndActions() throws {
        let create = try AgentRoutineRequest.parse(#"{"action":"create","title":"Inbox digest","task":"Summarize unread mail","at":"8:30","days":"weekdays"}"#)
        #expect(create.schedule == .daily(TimeOfDay(hour: 8, minute: 30), weekdays: [1, 2, 3, 4, 5]))
        #expect(create.summary == "Create the routine \"Inbox digest\", weekdays at 08:30")
        let every = try AgentRoutineRequest.parse("```json\n{\"title\":\"Price check\",\"task\":\"Check the price\",\"every_minutes\":\"120\"}\n```")
        #expect(every.action == .create && every.schedule == .every(minutes: 120))
        let pause = try AgentRoutineRequest.parse(#"{"action":"pause","title":"Price check"}"#)
        #expect(pause.action == .pause && pause.schedule == nil)
        let days = try AgentRoutineRequest.parse(#"{"action":"update","title":"Gym","at":"07:00","days":["mon","Wed",5],"new_title":"Gym days"}"#)
        #expect(days.schedule == .daily(TimeOfDay(hour: 7, minute: 0), weekdays: [1, 3, 5]) && days.newTitle == "Gym days")
        #expect(throws: AgentBlockError.self) { try AgentRoutineRequest.parse(#"{"action":"explode","title":"x"}"#) }
        #expect(throws: AgentBlockError.self) { try AgentRoutineRequest.parse(#"{"title":"x","task":"y","at":"25:00"}"#) }
        #expect(throws: AgentBlockError.self) { try AgentRoutineRequest.parse(#"{"title":"x","task":"y","at":"09:00","days":["someday"]}"#) }
        #expect(throws: AgentBlockError.self) { try AgentRoutineRequest.parse(#"{"title":"x","task":"y","every_minutes":0}"#) }
    }

    @Test func learnedLinesBecomeHowTosUpToThree() {
        let report = AgentFinalReport.parse("""
        <report>
        say: Exported.
        </report>
        <LEARNED>
        - Expense export: use Reports → Export CSV, not the print view
        - Calendar: the work calendar is called "Team"
        3. Printer: the office printer needs the PS driver
        - VPN: connect before opening the wiki
        </LEARNED>
        """, now: fixed)
        #expect(report.learned?.map(\.topic) == ["Expense export", "Calendar", "Printer"])
        #expect(report.learned?.first?.detail == "use Reports → Export CSV, not the print view")
        #expect(report.blockProblems?.first?.hasPrefix("LEARNED:") == true)
    }

    @Test func aPlainWaitForSentenceIsTheStepAndBlocksWithoutAReportStillSpeak() {
        let report = AgentFinalReport.parse("""
        I filled in the form but it needs your signature.
        <wait_for>Sign the form in the DocuSign tab</wait_for>
        <answer>{"outcome": "Form filled; needs your signature"}</answer>
        """, now: fixed)
        #expect(report.waitFor?.step == "Sign the form in the DocuSign tab")
        #expect(report.spoken == "Form filled; needs your signature")
        #expect(report.markdown == "I filled in the form but it needs your signature.")
    }

    @Test func blocksSurviveTheJobRecordAndReachTheReportAndCard() throws {
        let report = AgentFinalReport.parse("""
        Body.
        <report>
        say: Ready.
        </report>
        <answer>{"outcome":"Two options","ask":["Monday","Tuesday"]}</answer>
        """, now: fixed)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentFinalReport.self, from: try encoder.encode(report))
        #expect(decoded == report)
        // A record written before the blocks existed still decodes.
        let old = try decoder.decode(AgentFinalReport.self, from: Data(#"{"markdown":"m","spoken":"s","files":[],"nextSteps":[]}"#.utf8))
        #expect(old.answer == nil && old.spoken == "s")

        var record = AgentJobRecord(id: "j", kind: .job, title: "T", task: "t", harness: .codex, model: nil, provider: "p", status: .done,
                                    createdAt: fixed, updatedAt: fixed, runs: [AgentRun(ask: "t", startedAt: fixed)], folderPath: "/tmp/j")
        record.report = report
        let made = AgentJobReport.make(record: record, outputs: [], finishedAt: fixed)
        #expect(made.answer?.ask?.count == 2)
        #expect(made.json["answer"] == "Two options")
        let card = AgentResultCard(report: made)
        #expect(card.answer?.blocks == [.ask])
    }
}
