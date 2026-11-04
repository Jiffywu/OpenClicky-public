import AppKit
import OpenClickyKit
import SwiftUI

/// `OpenClicky --render-agent-snapshots <folder>`: renders Home → Agents (job list and a transcript rebuilt from a
/// fixture job's files) and the result card for each kind of structured answer, a user step and a routine proposal,
/// offscreen in light and dark. Fixtures live in a temporary folder; nothing of the user's is read or written.
@MainActor
enum AgentSnapshots {
    static func run(into folder: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-agent-snapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try renderHome(into: folder, root: root)
            try renderCards(into: folder)
            try renderBrowserApproval(into: folder, root: root)
            try renderRoutineFromJob(into: folder, root: root)
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: Home → Agents

    static func renderBrowserApproval(into folder: URL, root: URL) throws {
        let now = Date()
        let store = AgentJobStore(paths: AgentPaths(root: root))
        var job = try store.createJob(task: "Draft a message for review", title: "Contact form", harness: .codex,
                                      model: "fixture-model", provider: "fixture", now: now)
        job.status = .needsYou
        let details: JSONValue = ["operation": "batch", "page": ["title": "Contact form", "url": "https://example.com/contact", "tab": 7],
                                  "arguments": ["tabId": 7, "steps": [["operation": "fill", "ref": "e1", "text": "Please send the information we discussed."],
                                                                       ["operation": "click", "ref": "e2"]]]]
        job.pendingRequest = AgentApprovalRequest(id: "fixture-browser-approval", kind: .browserAction,
                                                  summary: "Allow browser batch?", reason: details.jsonString())
        let model = AgentHUDModel(records: [job], now: now, store: store)
        for dark in [false, true] {
            try EvidenceSnapshots.render(AgentHUDView(model: model), size: NSSize(width: 400, height: 430), dark: dark,
                                         to: folder.appendingPathComponent(dark ? "browser-approval-dark.png" : "browser-approval.png"))
        }
    }

    static func renderHome(into folder: URL, root: URL) throws {
        let now = Date()
        let store = AgentJobStore(paths: AgentPaths(root: root))
        let records = try fixtureJobs(store: store, now: now)
        for (name, showArchived, dark) in [("home-agents-transcript", false, false), ("home-agents-transcript-dark", false, true),
                                           ("home-agents-archived", true, false)] {
            let model = AgentHUDModel(records: records, now: now, store: store)
            model.showArchived = showArchived
            model.selectedJobID = showArchived ? records.last?.id : records.first?.id
            let view = VStack(alignment: .leading, spacing: 12) {
                Text("Background jobs").font(.title2.weight(.semibold))
                AgentJobsBrowserView(model: model)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(20)
            try EvidenceSnapshots.render(view, size: NSSize(width: 980, height: 720), dark: dark, to: folder.appendingPathComponent("\(name).png"))
        }
    }

    /// Three jobs written the way the manager writes them: a two-run job with a full transcript (unseen), a job waiting
    /// on a user step, and an archived one.
    static func fixtureJobs(store: AgentJobStore, now: Date) throws -> [AgentJobRecord] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        var flights = try store.createJob(task: "Find nonstop flights from SFO to Denver next Tuesday under $200", title: "Denver flights",
                                          harness: .claudeCode, model: "claude-haiku-5-5", provider: "anthropic", now: at(42))
        let output = flights.outputFolder.appendingPathComponent("flights.md").path
        func log(_ event: AgentEvent, _ minutesAgo: Double) { store.append(event, to: flights, at: at(minutesAgo)) }
        var first = AgentRun(ask: flights.task, startedAt: at(42))
        store.appendRun(number: 1, ask: first.ask, to: flights, at: at(42))
        log(.sessionStarted(threadID: "fixture-session"), 42)
        log(.thinking("Planning the fare search"), 41.8)
        log(.commentary("I'll check Kayak and the airlines' own sites for Tuesday nonstops."), 41.6)
        log(.plan([AgentPlanStep(step: "Search Tuesday nonstops", status: .completed), AgentPlanStep(step: "Write the comparison", status: .completed)]), 41.5)
        log(.progress("Searching: SFO to DEN nonstop Tuesday"), 41.4)
        log(.progress("Fetching: kayak.com/flights/SFO-DEN"), 41)
        log(.fileChanged(path: output, change: "created"), 39)
        let firstReport = """
        Three nonstops are under $200; **United 7:05 AM** is cheapest at $129.

        <report>
        say: I found three nonstop flights under 200 dollars; United at 7:05 is the cheapest at 129.
        title: Denver Flight Options
        files:
        - output/flights.md
        next:
        - Book the United 7:05 AM flight
        - Find the return on Sunday
        </report>
        """
        log(.turnFinished(.completed, finalText: firstReport, error: nil), 38)
        first.finishedAt = at(38)
        first.outcome = .completed
        first.spoken = "I found three nonstop flights under 200 dollars; United at 7:05 is the cheapest at 129."
        var second = AgentRun(ask: "Find the return on Sunday", startedAt: at(12))
        store.appendRun(number: 2, ask: second.ask, to: flights, at: at(12))
        log(.thinking("Checking Sunday returns"), 11.8)
        log(.progress("Searching: DEN to SFO nonstop Sunday"), 11.5)
        log(.fileChanged(path: output, change: "changed"), 10)
        let secondReport = """
        Added Sunday's returns to the table.

        <report>
        say: Sunday's cheapest nonstop back is Southwest at 4:40 PM for 141 dollars.
        title: Denver Round Trip
        next:
        - Set a fare alert for both legs
        </report>
        <answer>{"outcome": "Round trip from $270", "numbers": [{"value": "$129", "label": "Tue out, United 7:05"}, {"value": "$141", "label": "Sun back, Southwest 4:40", "was": "$158", "better": "lower"}]}</answer>
        """
        log(.turnFinished(.completed, finalText: secondReport, error: nil), 9.5)
        second.finishedAt = at(9.5)
        second.outcome = .completed
        second.spoken = "Sunday's cheapest nonstop back is Southwest at 4:40 PM for 141 dollars."
        flights.runs = [first, second]
        flights.status = .done
        flights.report = AgentFinalReport.parse(secondReport, now: at(9.5))
        flights.isSeen = false
        flights.updatedAt = at(9.5)
        try store.save(flights)

        var expenses = try store.createJob(task: "File my October expenses in the company portal", title: "October expenses",
                                           harness: .codex, model: "gpt-5.4-mini", provider: "openai", now: at(80))
        let waitReport = """
        I collected 14 receipts into output/october.csv. The portal needs you to sign in before I can upload them.

        <report>
        say: The receipts are ready; I need you to sign in to the expenses portal.
        title: October Expenses
        </report>
        <wait_for>{"step": "Sign in to the expenses portal in Chrome", "page": "https://expenses.example.com"}</wait_for>
        """
        store.appendRun(number: 1, ask: expenses.task, to: expenses, at: at(80))
        store.append(.progress("Reading: ~/Downloads/receipts"), to: expenses, at: at(79))
        store.append(.fileChanged(path: expenses.outputFolder.appendingPathComponent("october.csv").path, change: "created"), to: expenses, at: at(75))
        store.append(.turnFinished(.completed, finalText: waitReport, error: nil), to: expenses, at: at(74))
        var run = AgentRun(ask: expenses.task, startedAt: at(80))
        run.finishedAt = at(74)
        run.outcome = .completed
        expenses.runs = [run]
        expenses.report = AgentFinalReport.parse(waitReport, now: at(74))
        expenses.waitingStep = expenses.report?.waitFor
        expenses.status = .needsYou
        expenses.isSeen = true
        expenses.updatedAt = at(74)
        try store.save(expenses)

        var old = try store.createJob(task: "Summarize the Q3 board deck", title: "Q3 deck summary", harness: .claudeCode,
                                      model: "claude-haiku-5-5", provider: "anthropic", now: at(3000))
        var oldRun = AgentRun(ask: old.task, startedAt: at(3000))
        oldRun.finishedAt = at(2990)
        oldRun.outcome = .completed
        oldRun.spoken = "The deck's three points: growth held at 12 percent, hiring slows, and the EU launch moves to March."
        old.runs = [oldRun]
        old.report = AgentFinalReport(markdown: "", spoken: oldRun.spoken ?? "", title: "Q3 Deck Summary")
        old.status = .done
        old.archivedAt = at(2990)
        old.updatedAt = at(2990)
        try store.save(old)
        return [flights, expenses, old]
    }

    // MARK: A routine a job set up

    /// A routine proposed by a job and approved goes through `AgentCoordinator.apply` (the path the `<routine>` block and
    /// `openclicky_routines` add both take after the user's yes) into a temporary routines.json; Settings → Routines is
    /// rendered from that file as read back from disk.
    static func renderRoutineFromJob(into folder: URL, root: URL) throws {
        let now = Date()
        let store = AgentJobStore(paths: AgentPaths(root: root))
        var job = try store.createJob(task: "Check SFO to DEN fares", title: "Denver fares", harness: .claudeCode, model: "claude-haiku-5-5",
                                      provider: "anthropic", now: now.addingTimeInterval(-600))
        var run = AgentRun(ask: job.task, startedAt: now.addingTimeInterval(-600))
        run.finishedAt = now.addingTimeInterval(-540)
        run.outcome = .completed
        run.spoken = "Fares are flat at 129 dollars."
        job.runs = [run]
        job.status = .done
        try store.save(job)
        let routinesFile = root.appendingPathComponent("routines.json")
        let scheduler = RoutineScheduler(store: RoutineStore(url: routinesFile)) { _, _ in "unused" }
        let request = AgentRoutineRequest(action: .create, title: "Fare watch", task: "Check SFO to DEN fares and say only what changed",
                                          schedule: .daily(TimeOfDay(hour: 8, minute: 0), weekdays: [1, 2, 3, 4, 5]))
        let made = job
        var outcome: Result<String, Error>?
        Task { @MainActor in
            do { outcome = .success(try await AgentCoordinator.apply(request, job: made, routines: scheduler)) } catch { outcome = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(10)
        while outcome == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print("apply: \(try outcome?.get() ?? "timed out")")
        let saved = RoutineStore(url: routinesFile).load()
        print("routines.json now holds: \(saved.map { "\($0.title) (job \($0.jobID ?? "-"), \($0.schedule.phrase))" }.joined(separator: "; "))")
        let fixture = try EvidenceSnapshots.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let summaries = RoutineSummary.make(routines: saved, jobs: [job])
        fixture.services.routines.show(summaries, selected: summaries.first?.id)
        fixture.services.settingsPage = .routines
        let view = SettingsView().environment(fixture.services).environment(fixture.model)
        try EvidenceSnapshots.render(view, size: NSSize(width: 860, height: 620), to: folder.appendingPathComponent("settings-routines-from-job.png"))
    }

    // MARK: Result cards

    static func renderCards(into folder: URL) throws {
        let start = Date(timeIntervalSince1970: 0)
        func report(_ title: String, outcome: AgentJobReport.Outcome = .done, spoken: String, answer: String? = nil,
                    markdown: String = "", seconds: Double = 95) -> AgentJobReport {
            var made = AgentJobReport(jobID: "fixture-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))", run: 1, title: title,
                                      outcome: outcome, spoken: spoken, markdown: markdown, startedAt: start, finishedAt: start.addingTimeInterval(seconds))
            made.answer = answer.flatMap { try? AgentAnswer.parse($0) }
            return made
        }
        var cards: [(String, AgentJobReport)] = [
            ("answer-numbers-hero", report("Open Support Tickets", spoken: "You have 42 open tickets, most of them about billing.",
                                           answer: #"{"outcome":"42 open tickets","numbers":[{"value":"42","label":"open tickets in Zendesk"}],"note":"Billing is 27 of them"}"#)),
            ("answer-numbers-tiles", report("Weekly Sales", spoken: "Sales were up this week across all three stores.",
                                            answer: #"{"outcome":"Sales up in all three stores","numbers":[{"value":"$18.2k","label":"Downtown"},{"value":"$11.9k","label":"Airport"},{"value":"$7.4k","label":"Mall"}]}"#)),
            ("answer-numbers-changes", report("Flight Prices", spoken: "The return got cheaper; the outbound went up a little.",
                                              answer: #"{"outcome":"Return dropped $17","numbers":[{"value":"$141","label":"Sun return","was":"$158","better":"lower"},{"value":"$134","label":"Tue outbound","was":"$129","better":"lower"}]}"#)),
            ("answer-numbers-progress", report("Course Progress", spoken: "You're more than halfway through both courses.",
                                               answer: #"{"outcome":"Over halfway in both","numbers":[{"value":"12","label":"Swift course lessons","of":"20"},{"value":"7","label":"Design course lessons","of":"10"}]}"#)),
            ("answer-list", report("Lisbon Hotels", spoken: "Three hotels fit; Memmo Alfama is the best value.",
                                   answer: #"{"outcome":"Memmo Alfama is the best value","list":[{"text":"Memmo Alfama","detail":"€210/night"},{"text":"The Lumiares","detail":"€245/night"},{"text":"Hotel Avenida","detail":"€190/night"}],"ranked":true}"#)),
            ("answer-done", report("Dinner Invites", spoken: "I sent the invites and booked the table.",
                                   answer: #"{"outcome":"Invites sent, table booked","done":[{"did":"Sent","what":"the invite to Sam, Alex and Priya","link":"https://calendar.example.com/e/1"},{"did":"Booked","what":"a table for 4 at 7:30 PM"}]}"#)),
            ("answer-draft", report("Reply to Sam", spoken: "I drafted a reply saying Thursday works.",
                                    answer: #"{"outcome":"Reply drafted","draft":{"text":"Hi Sam, Thursday at 2 works for me. I'll bring the Q4 numbers. See you then!","to":"Sam Lee"}}"#)),
            ("answer-ask", report("Venue Options", outcome: .needsYou, spoken: "Two venues are free that night. Which one should I book?",
                                  answer: #"{"outcome":"Two venues free on the 14th","ask":[{"answer":"The Loft","detail":"seats 40, $900"},{"answer":"Pier 7","detail":"seats 60, $1,400"}]}"#)),
            ("answer-quiet", report("Price Watch", spoken: "No change since this morning's check.", answer: #"{"quiet":true,"outcome":"No change since 8:00"}"#)),
        ]
        var step = report("October Expenses", outcome: .needsYou, spoken: "The receipts are ready; I need you to sign in to the expenses portal.")
        step.userStep = AgentUserStep(step: "Sign in to the expenses portal in Chrome", page: "https://expenses.example.com", askedAt: start)
        cards.append(("card-user-step", step))
        var routine = report("Fare Watch", outcome: .needsYou, spoken: "I can check these fares every weekday morning. Want me to set that up?")
        routine.routineProposals = [AgentRoutineRequest(action: .create, title: "Fare watch", task: "Check SFO to DEN fares and say what changed",
                                                        schedule: .daily(TimeOfDay(hour: 8, minute: 0), weekdays: [1, 2, 3, 4, 5]))]
        cards.append(("card-routine-proposal", routine))
        for (name, made) in cards {
            let model = AgentResultCardModel()
            model.show(made)
            for (suffix, dark) in [("light", false), ("dark", true)] {
                let view = AgentResultCardView(model: model).padding(24)
                let host = NSHostingView(rootView: view)
                let size = host.fittingSize
                try EvidenceSnapshots.render(view, size: NSSize(width: max(428, size.width), height: max(160, size.height)), dark: dark,
                                             to: folder.appendingPathComponent("\(name)-\(suffix).png"), settle: 0.2)
            }
        }
    }
}
