import Foundation
import Testing
@testable import OpenClickyKit

/// A toolbox on fakes only: nothing opens, plays, copies or touches the real calendar.
struct AppToolRig {
    let workspace: RecordingWorkspace
    let pasteboard = RecordingPasteboard()
    let scripts: ScriptedAppleScriptRunner
    let calendar: InMemoryCalendarStore
    let home: URL
    let toolbox: AppToolbox

    init(workspace: RecordingWorkspace = RecordingWorkspace(), scripts: ScriptedAppleScriptRunner = ScriptedAppleScriptRunner(),
         calendar: InMemoryCalendarStore = InMemoryCalendarStore(), home: URL = URL(fileURLWithPath: "/Users/tester"),
         clock: CalendarClock = CalendarClock()) {
        self.workspace = workspace
        self.scripts = scripts
        self.calendar = calendar
        self.home = home
        toolbox = AppToolbox.standard(AppToolEnvironment(
            workspace: workspace, pasteboard: pasteboard, appleScript: scripts, calendar: calendar, homeDirectory: home,
            clock: clock, sleep: { _ in }))
    }
}

@Suite("App toolbox")
struct AppToolboxTests {
    @Test func exposesEveryToolButInsertText() {
        let names = AppToolRig().toolbox.specs.map(\.name)
        #expect(names == ["open_url", "copy_to_clipboard", "reveal_in_finder", "play_on_spotify", "calendar_find_events",
                          "calendar_create_event"])
        #expect(!names.contains("insert_text"))
    }

    @Test func deferralFlagsMarkTheActionsThatWaitForNarration() {
        let toolbox = AppToolRig().toolbox
        #expect(toolbox.deferredToolNames == ["open_url", "reveal_in_finder", "play_on_spotify"])
        #expect(toolbox["copy_to_clipboard"]?.defersUntilNarrationEnds == false)
        #expect(toolbox["calendar_find_events"]?.defersUntilNarrationEnds == false)
        #expect(toolbox["calendar_create_event"]?.defersUntilNarrationEnds == false)
    }

    @Test func readsAndDraftsNeedAnotherRoundButActionsDoNot() {
        let toolbox = AppToolRig().toolbox
        #expect(toolbox["calendar_find_events"]?.needsFollowUpRound == true)
        #expect(toolbox["calendar_find_events"]?.isReadOnly == true)
        #expect(toolbox["calendar_create_event"]?.needsFollowUpRound == true)
        #expect(toolbox["calendar_create_event"]?.isReadOnly == false)
        for name in ["open_url", "copy_to_clipboard", "reveal_in_finder", "play_on_spotify"] {
            #expect(toolbox[name]?.needsFollowUpRound == false, "\(name)")
            #expect(toolbox[name]?.isReadOnly == false, "\(name)")
        }
    }

    @Test func everySpecIsAnObjectSchemaWithoutExtraProperties() {
        for spec in AppToolRig().toolbox.specs {
            #expect(spec.parameters["type"] == "object", "\(spec.name)")
            #expect(spec.parameters["additionalProperties"] == false, "\(spec.name)")
            #expect(spec.parameters["properties"]?.objectValue?.isEmpty == false, "\(spec.name)")
            #expect(!spec.description.isEmpty)
        }
    }

    @Test func deferredActionIsQueuedWithItsStatusWordAndNothingRunsYet() async {
        let rig = AppToolRig()
        let dispatch = rig.toolbox.prepare(ToolCall(id: "c1", name: "open_url", arguments: #"{"url":"https://example.com/a"}"#))
        guard case .deferUntilNarrationEnds(let action, let queued) = dispatch else {
            Issue.record("expected a deferred action, got \(dispatch)")
            return
        }
        #expect(action == DeferredAction(callID: "c1", name: "open_url", arguments: ["url": "https://example.com/a"]))
        #expect(queued.status == .opened)
        #expect(queued.details["deferred"] == true)
        #expect(rig.workspace.events.isEmpty)

        let result = await rig.toolbox.run(action)
        #expect(result.status == .opened)
        #expect(rig.workspace.events == [.openInBrowser(URL(string: "https://example.com/a")!)])
    }

    @Test func queuedStatusWordsMatchWhatEachActionReportsWhenItWorks() {
        let toolbox = AppToolRig().toolbox
        #expect(toolbox["open_url"]?.queuedStatus == .opened)
        #expect(toolbox["reveal_in_finder"]?.queuedStatus == .revealed)
        #expect(toolbox["play_on_spotify"]?.queuedStatus == .completed)
    }

    @Test func badArgumentsAreAnsweredAtOnceEvenForDeferredTools() {
        let toolbox = AppToolRig().toolbox
        guard case .finished(let refused) = toolbox.prepare(ToolCall(id: "c", name: "open_url", arguments: #"{"url":"javascript:alert(1)"}"#))
        else { Issue.record("javascript: link was not answered at once"); return }
        #expect(refused.status == .refused)

        guard case .finished(let missing) = toolbox.prepare(ToolCall(id: "c", name: "play_on_spotify", arguments: "{}"))
        else { Issue.record("empty play request was not answered at once"); return }
        #expect(missing.status == .invalidRequest)
    }

    @Test func immediateToolsRunNow() {
        let toolbox = AppToolRig().toolbox
        guard case .runNow(let tool) = toolbox.prepare(ToolCall(id: "c", name: "copy_to_clipboard", arguments: #"{"text":"hi"}"#))
        else { Issue.record("copy should run now"); return }
        #expect(tool.name == "copy_to_clipboard")
    }

    @Test func unknownToolsAndMalformedJSONNeverRun() async {
        let toolbox = AppToolRig().toolbox
        guard case .finished(let unknown) = toolbox.prepare(ToolCall(id: "c", name: "insert_text", arguments: "{}")) else {
            Issue.record("unknown tool dispatched"); return
        }
        #expect(unknown.status == .notImplemented)
        #expect(await toolbox.call(name: "nope", arguments: "{}").status == .notImplemented)

        for text in ["{", "[1,2]", "\"url\"", "42"] {
            guard case .finished(let bad) = toolbox.prepare(ToolCall(id: "c", name: "open_url", arguments: text)) else {
                Issue.record("\(text) dispatched"); continue
            }
            #expect(bad.status == .invalidRequest, "\(text)")
        }
    }

    @Test func resultJSONLeadsWithTheStatusWord() throws {
        let result = AppToolResult(.opened, "Done.", details: ["url": "https://example.com"])
        let parsed = try JSONValue.parse(result.jsonString)
        #expect(parsed["status"] == "opened")
        #expect(parsed["message"] == "Done.")
        #expect(parsed["url"] == "https://example.com")

        let message = AppToolResult(.refused, "No.").toolMessage(callID: "x")
        #expect(message.role == .tool)
        #expect(message.toolCallID == "x")
        #expect(message.isError)
        #expect(!AppToolResult(.copied).toolMessage(callID: "y").isError)
    }

    @Test func failedDeferredActionsBecomeAppNotes() {
        #expect(AppToolResult(.opened).appNote(toolName: "open_url") == nil)
        #expect(AppToolResult(.needsConfirmation).appNote(toolName: "calendar_create_event") == nil)
        let note = AppToolResult(.failed, "The browser did not open the page.").appNote(toolName: "open_url")
        #expect(note == "[App] open_url did not work (failed). The browser did not open the page.")
    }

    @Test func statusSuccessSplit() {
        let successes: Set<AppToolStatus> = [.ok, .opened, .copied, .revealed, .completed, .created, .needsConfirmation]
        for status in AppToolStatus.allCases { #expect(status.isSuccess == successes.contains(status), "\(status)") }
    }
}

@Suite("Tool arguments")
struct ToolArgumentsTests {
    @Test func emptyTextAndNullMeanNoArguments() throws {
        #expect(try ToolArguments.parse("").values.isEmpty)
        #expect(try ToolArguments.parse("  ").values.isEmpty)
        #expect(try ToolArguments.parse("null").values.isEmpty)
    }

    @Test func stringsAreTrimmedAndEmptyCountsAsAbsent() throws {
        let args = try ToolArguments.parse(#"{"a":"  hi  ","b":"   ","c":null}"#)
        #expect(try args.string("a") == "hi")
        #expect(try args.string("b") == nil)
        #expect(try args.string("c") == nil)
        #expect(throws: ToolArgumentError.self) { try args.requiredString("b") }
    }

    @Test func firstPresentKeySpellingWins() throws {
        let args = try ToolArguments.parse(#"{"spotifyUri":"x","searchQuery":"y"}"#)
        #expect(try args.string("uri", "spotify_uri", "spotifyUri") == "x")
        #expect(try args.string("query", "searchQuery") == "y")
    }

    @Test func wrongTypesAndLimitsAreInvalidRequests() throws {
        let args = try ToolArguments.parse(#"{"s":5,"b":"maybe","n":2.5,"m":"99","long":"abcdef"}"#)
        #expect(throws: ToolArgumentError("\"s\" must be a string.")) { try args.string("s") }
        #expect(throws: ToolArgumentError("\"b\" must be true or false.")) { try args.bool("b") }
        #expect(throws: ToolArgumentError("\"n\" must be a whole number.")) { try args.int("n", in: 1...10) }
        #expect(throws: ToolArgumentError("\"m\" must be between 1 and 50.")) { try args.int("m", in: 1...50) }
        #expect(throws: ToolArgumentError("\"long\" is too long (over 3 characters).")) { try args.string("long", maxLength: 3) }
    }

    @Test func lenientBooleansAndNumbers() throws {
        let args = try ToolArguments.parse(#"{"t":"TRUE","f":"false","n":"7"}"#)
        #expect(try args.bool("t") == true)
        #expect(try args.bool("f") == false)
        #expect(try args.int("n", in: 1...10) == 7)
    }

    @Test func choicesNormalizeSpacesAndDashes() throws {
        let args = try ToolArguments.parse(#"{"app":"Apple Music","range":"next-week","bad":"weekly"}"#)
        #expect(try args.choice("app", as: MusicAppChoice.self) == .appleMusic)
        #expect(try args.choice("range", as: CalendarRangeName.self) == .nextWeek)
        #expect(throws: ToolArgumentError.self) { try args.choice("bad", as: CalendarRangeName.self) }
    }

    @Test func rawStringsKeepWhitespace() throws {
        let args = try ToolArguments.parse(#"{"text":"  line 1\n  line 2\n"}"#)
        #expect(try args.rawString("text", maxLength: 100) == "  line 1\n  line 2\n")
    }
}
