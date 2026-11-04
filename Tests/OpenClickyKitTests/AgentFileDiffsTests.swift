import Foundation
import Testing
@testable import OpenClickyKit

// Before-and-after file diffs: the unified diff itself, snapshots taken from fake harness events (create, change,
// delete, binary, too large), persistence across a relaunch, the off switch, and the normalizers' "about to change"
// events.

@Test func unifiedDiffOfAChangeHasContextAndLineNumbers() {
    let old = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
    var lines = (1...12).map { "line \($0)" }
    lines[5] = "line six, rewritten"
    lines.insert("a new line", at: 10)
    let new = lines.joined(separator: "\n") + "\n"
    let diff = AgentUnifiedDiff.make(old: old, new: new, path: "/tmp/notes.txt")
    #expect(diff.added == 2 && diff.removed == 1)
    #expect(diff.text == """
        --- a/tmp/notes.txt
        +++ b/tmp/notes.txt
        @@ -3,10 +3,11 @@
         line 3
         line 4
         line 5
        -line 6
        +line six, rewritten
         line 7
         line 8
         line 9
         line 10
        +a new line
         line 11
         line 12

        """)
}

@Test func unifiedDiffOfFarApartChangesHasTwoHunks() {
    let old = (1...20).map { "l\($0)" }.joined(separator: "\n") + "\n"
    var lines = (1...20).map { "l\($0)" }
    lines[1] = "L2"
    lines[18] = "L19"
    let diff = AgentUnifiedDiff.make(old: old, new: lines.joined(separator: "\n") + "\n", path: "f")
    #expect(diff.text.components(separatedBy: "\n@@ ").count == 3)
    #expect(diff.text.contains("@@ -1,5 +1,5 @@\n l1\n-l2\n+L2\n"))
    #expect(diff.text.contains("@@ -16,5 +16,5 @@\n l16\n l17\n l18\n-l19\n+L19\n l20\n"))
}

@Test func unifiedDiffOfCreateDeleteAndAMissingFinalNewline() {
    let created = AgentUnifiedDiff.make(old: nil, new: "one\ntwo\n", path: "/x/new.md")
    #expect(created.text == "--- /dev/null\n+++ b/x/new.md\n@@ -0,0 +1,2 @@\n+one\n+two\n")
    let deleted = AgentUnifiedDiff.make(old: "gone\n", new: nil, path: "/x/old.md")
    #expect(deleted.text == "--- a/x/old.md\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone\n")
    let noNewline = AgentUnifiedDiff.make(old: "a\nb", new: "a\nb\n", path: "f")
    #expect(noNewline.text.hasSuffix("@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+b\n"))
    #expect(AgentUnifiedDiff.make(old: "same\n", new: "same\n", path: "f").added == 0)
}

@Test(.timeLimit(.minutes(1))) func aFileRewrittenThroughoutIsDiffedAsOneBlockNotLineByLine() {
    // CRLF to LF changes every line. Myers over 20,000 changed lines on each side needs memory in the square of that
    // (gigabytes) on the manager actor; the diff shows one removed block and one added block instead.
    let old = (1...20_000).map { "\($0)\r\n" }.joined(), new = (1...20_000).map { "\($0)\n" }.joined()
    let diff = AgentUnifiedDiff.make(old: old, new: new, path: "data.csv")
    #expect(diff.added == 20_000 && diff.removed == 20_000)
    #expect(diff.text.hasPrefix("--- a/data.csv\n+++ b/data.csv\n@@ -1,20000 +1,20000 @@\n-1\r\n"))

    // Over the cap the changed middle isn't matched line by line (every other line changed: 1,197 lines between the
    // shared first and last ones on each side); under it, it is, and shared start and end lines stay context.
    let many = (0..<1_200).map { "a\($0)" }
    let edited = many.enumerated().map { $0.offset % 2 == 1 && $0.offset < 1_199 ? "b\($0.offset)" : $0.element }
    let block = AgentUnifiedDiff.make(old: many.joined(separator: "\n") + "\n", new: edited.joined(separator: "\n") + "\n", path: "f")
    #expect(block.removed == 1_197 && block.added == 1_197)
    let small = AgentUnifiedDiff.make(old: many.prefix(400).joined(separator: "\n") + "\n",
                                      new: edited.prefix(400).joined(separator: "\n") + "\n", path: "f")
    #expect(small.removed == 200 && small.added == 200)
    let longFile = (0..<50_000).map { "line \($0)" }
    var oneChange = longFile
    oneChange[25_000] = "changed"
    let one = AgentUnifiedDiff.make(old: longFile.joined(separator: "\n"), new: oneChange.joined(separator: "\n"), path: "f")
    #expect(one.added == 1 && one.removed == 1)
    #expect(one.text.contains("@@ -24998,7 +24998,7 @@\n line 24997\n line 24998\n line 24999\n-line 25000\n+changed\n line 25001\n"))
}

@Test func oneFileUnderTwoSpellingsIsOneDiff() throws {
    // Claude Code has reported the same file as /private/tmp/… before an edit and /tmp/… after it.
    let folder = URL(fileURLWithPath: "/tmp/openclicky-diff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("output"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("output/nuts.md").path
    var recorder = AgentFileDiffRecorder()
    recorder.willChange("/private" + file)
    try "# Nuts\n".write(toFile: file, atomically: true, encoding: .utf8)
    recorder.changed(file, change: "created")
    let items = recorder.finish(run: 1, folder: folder, at: Date())
    #expect(items.count == 1)
    #expect(items.first?.kind == .created)
    let record = AgentJobRecord(id: "j", kind: .job, title: "j", task: "", harness: .codex, model: nil, provider: "p", status: .done,
                                createdAt: Date(), updatedAt: Date(), folderPath: folder.path)
    #expect(AgentFileDiffs.text(of: try #require(items.first), in: record)?.hasPrefix("--- /dev/null\n+++ b/output/nuts.md\n") == true)
}

@Test func snapshotsSkipBinariesAndFilesOverTheCap() throws {
    let temp = AgentTempDir()
    let text = temp.url.appendingPathComponent("a.txt"), binary = temp.url.appendingPathComponent("b.bin")
    let big = temp.url.appendingPathComponent("big.txt")
    try "hello\n".write(to: text, atomically: true, encoding: .utf8)
    try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: binary)
    try String(repeating: "x", count: 600).write(to: big, atomically: true, encoding: .utf8)
    #expect(AgentFileSnapshot.read(text.path, cap: 512) == .text("hello\n", bytes: 6))
    #expect(AgentFileSnapshot.read(binary.path, cap: 512) == .binary(bytes: 6))
    #expect(AgentFileSnapshot.read(big.path, cap: 512) == .tooLarge(bytes: 600))
    #expect(AgentFileSnapshot.read(temp.url.appendingPathComponent("none").path) == .missing)
    #expect(AgentFileSnapshot.read(temp.url.path) == .missing, "a folder isn't a file")
}

/// The manager a fake harness script can wait on.
final class ManagerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _manager: AgentManager?
    var manager: AgentManager? {
        get { lock.withLock { _manager } }
        set { lock.withLock { _manager = newValue } }
    }
}

/// Emits `fileWillChange` and waits until the manager has kept the "before", as a real edit would follow it.
func willChange(_ path: String, _ session: ScriptedSession, _ box: ManagerBox, jobID: @escaping @Sendable () -> String?, count: Int) async {
    await session.emit(.fileWillChange(path: path))
    _ = await agentEventually {
        guard let manager = box.manager, let id = jobID() else { return false }
        return await manager.fileSnapshotCount(id) >= count
    }
}

@Test func fakeHarnessEventsProduceDiffsForCreateChangeAndDeleteThatSurviveARelaunch() async throws {
    let box = ManagerBox()
    let files = AgentTempDir()
    let notes = files.url.appendingPathComponent("notes.md"), doomed = files.url.appendingPathComponent("old.txt")
    let created = files.url.appendingPathComponent("new.txt"), picture = files.url.appendingPathComponent("logo.png")
    let huge = files.url.appendingPathComponent("huge.log")
    try "# Notes\n\n- milk\n- eggs\n".write(to: notes, atomically: true, encoding: .utf8)
    try "remove me\n".write(to: doomed, atomically: true, encoding: .utf8)
    try Data([0x89, 0x50, 0x4E, 0x47, 0x00]).write(to: picture)
    try "small\n".write(to: huge, atomically: true, encoding: .utf8)
    let ids = IDBox()
    let rig = ScriptedRig { session in
        let id = { @Sendable in ids.value }
        await willChange(notes.path, session, box, jobID: id, count: 1)
        try? "# Notes\n\n- milk\n- bread\n- eggs\n".write(to: notes, atomically: true, encoding: .utf8)
        await session.emit(.fileChanged(path: notes.path, change: "changed"))
        // Created with no "before" event (Claude Code reports a Write after it ran): it didn't exist before.
        try? "brand new\n".write(to: created, atomically: true, encoding: .utf8)
        await session.emit(.fileChanged(path: created.path, change: "created"))
        await willChange(doomed.path, session, box, jobID: id, count: 3)
        try? FileManager.default.removeItem(at: doomed)
        await session.emit(.fileChanged(path: doomed.path, change: "deleted"))
        await willChange(picture.path, session, box, jobID: id, count: 4)
        try? Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x02]).write(to: picture)
        await willChange(huge.path, session, box, jobID: id, count: 5)
        try? String(repeating: "y", count: AgentFileDiffs.maxSnapshotBytes + 10).write(to: huge, atomically: true, encoding: .utf8)
        await session.emit(.fileChanged(path: huge.path, change: "changed"))
        // Asked about, then left alone: no diff.
        await willChange(files.url.appendingPathComponent("untouched.txt").path, session, box, jobID: id, count: 6)
        await session.finish("Done.")
    }
    box.manager = rig.manager
    await rig.manager.setFileDiffs { true }
    let updates = await rig.manager.subscribe()
    let started = try await rig.manager.spawn(AgentSpawnRequest(task: "Tidy my files"))
    ids.value = started.record.id
    _ = await nextAgentReport(updates, for: started.record.id)

    let record = try #require(await rig.manager.job(started.record.id))
    let diffs = try #require(record.fileDiffs)
    #expect(diffs.map(\.kind) == [.changed, .created, .deleted, .changed, .changed])
    #expect(diffs.map(\.fileName) == ["notes.md", "new.txt", "old.txt", "logo.png", "huge.log"])
    #expect(diffs.allSatisfy { $0.run == 1 })
    #expect(diffs[0].added == 1 && diffs[0].removed == 0 && diffs[0].skipped == nil)
    #expect(diffs[1].added == 1 && diffs[1].sizeBefore == nil)
    #expect(diffs[2].removed == 1 && diffs[2].sizeAfter == nil)
    #expect(diffs[3].skipped == .binary && diffs[3].diffFile == nil)
    #expect(diffs[4].skipped == .tooLarge && diffs[4].diffFile == nil)
    let changeText = try #require(AgentFileDiffs.text(of: diffs[0], in: record))
    #expect(changeText.contains("@@ -1,4 +1,5 @@\n # Notes\n \n - milk\n+- bread\n - eggs\n"))
    #expect(AgentFileDiffs.text(of: diffs[1], in: record)?.contains("--- /dev/null") == true)
    #expect(AgentFileDiffs.text(of: diffs[2], in: record)?.contains("+++ /dev/null\n@@ -1 +0,0 @@\n-remove me\n") == true)
    #expect(diffs[0].diffFile?.hasPrefix("diffs/run-1/") == true)

    // A relaunch: the record and the diff files are still there.
    let relaunched = AgentManager(store: AgentJobStore(paths: rig.temp.paths)) { _ in throw AgentManagerError.emptyTask }
    let again = try #require(await relaunched.job(started.record.id))
    // Times are kept to the second in job.json.
    func undated(_ items: [AgentFileDiffItem]?) -> [AgentFileDiffItem]? { items?.map { var item = $0; item.at = .distantPast; return item } }
    #expect(undated(again.fileDiffs) == undated(diffs))
    #expect(abs((again.fileDiffs?.first?.at ?? .distantPast).timeIntervalSince(diffs[0].at)) < 1)
    #expect(AgentFileDiffs.text(of: try #require(again.fileDiffs?.first), in: again) == changeText)
}

final class IDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Test func aSecondRunKeepsItsOwnDiffsAndAMissedBeforeIsSaidSo() async throws {
    let box = ManagerBox(), ids = IDBox(), runs = IDBox()
    let files = AgentTempDir()
    let file = files.url.appendingPathComponent("plan.txt")
    try "v1\n".write(to: file, atomically: true, encoding: .utf8)
    let rig = ScriptedRig { session in
        let id = { @Sendable in ids.value }
        let first = runs.value == nil
        runs.value = "started"
        if first {
            await willChange(file.path, session, box, jobID: id, count: 1)
            try? "v2\n".write(to: file, atomically: true, encoding: .utf8)
            await session.emit(.fileChanged(path: file.path, change: "changed"))
        } else {
            // The change landed before any "about to change" event.
            try? "v3\n".write(to: file, atomically: true, encoding: .utf8)
            await session.emit(.fileChanged(path: file.path, change: "changed"))
        }
        await session.finish("Done.")
    }
    box.manager = rig.manager
    await rig.manager.setFileDiffs { true }
    let updates = await rig.manager.subscribe()
    let started = try await rig.manager.spawn(AgentSpawnRequest(task: "Update the plan"))
    ids.value = started.record.id
    _ = await nextAgentReport(updates, for: started.record.id)
    _ = try await rig.manager.send(to: started.record.id, message: "Again please")
    _ = await nextAgentReport(updates, for: started.record.id)

    let diffs = try #require(await rig.manager.job(started.record.id)?.fileDiffs)
    #expect(diffs.count == 2)
    #expect(diffs[0].run == 1 && diffs[0].added == 1 && diffs[0].removed == 1)
    #expect(diffs[1].run == 2 && diffs[1].skipped == .beforeMissed && diffs[1].kind == .changed)
    #expect(diffs[0].id != diffs[1].id)
}

@Test func withDiffsOffNothingIsKept() async throws {
    let files = AgentTempDir()
    let file = files.url.appendingPathComponent("a.txt")
    try "a\n".write(to: file, atomically: true, encoding: .utf8)
    let rig = ScriptedRig { session in
        await session.emit(.fileWillChange(path: file.path))
        try? "b\n".write(to: file, atomically: true, encoding: .utf8)
        await session.emit(.fileChanged(path: file.path, change: "changed"))
        await session.finish("Done.")
    }
    let updates = await rig.manager.subscribe()
    let started = try await rig.manager.spawn(AgentSpawnRequest(task: "Change a"))
    _ = await nextAgentReport(updates, for: started.record.id)
    let record = try #require(await rig.manager.job(started.record.id))
    #expect(record.fileDiffs == nil)
    #expect(!FileManager.default.fileExists(atPath: record.folder.appendingPathComponent("diffs").path))
    #expect(record.ledger?.files[file.path] == "changed", "the ledger still records the path")
}

@Test func normalizersSayWhenAFileIsAboutToChange() {
    let folder = URL(fileURLWithPath: "/tmp/job", isDirectory: true)
    var codex = CodexEventNormalizer(folder: folder)
    let started = codex.notification(method: "item/started", params: [
        "item": ["type": "fileChange", "id": "f1", "changes": [["path": "notes.md", "kind": ["type": "update"]], ["path": "/abs/x.txt", "kind": ["type": "add"]]]],
    ])
    #expect(started == [.progress("Editing notes.md, x.txt"), .fileWillChange(path: "/tmp/job/notes.md"), .fileWillChange(path: "/abs/x.txt")])

    var claude = ClaudeEventNormalizer(folder: folder)
    let events = claude.message([
        "type": "assistant",
        "message": ["content": [["type": "tool_use", "id": "t1", "name": "Edit", "input": ["file_path": "/tmp/job/output/a.md", "old_string": "a", "new_string": "b"]]]],
    ])
    #expect(events.contains(.fileWillChange(path: "/tmp/job/output/a.md")))
    let read = claude.message([
        "type": "assistant",
        "message": ["content": [["type": "tool_use", "id": "t2", "name": "Read", "input": ["file_path": "/tmp/job/output/a.md"]]]],
    ])
    #expect(!read.contains { if case .fileWillChange = $0 { true } else { false } })

    // Logged and read back.
    let entry = AgentLogEntry(.fileWillChange(path: "/tmp/job/a.md"), at: Date())
    #expect(entry.kind == "file_will_change" && entry.event == .fileWillChange(path: "/tmp/job/a.md"))
}

@Test func anEditThatLandsBeforeTheSnapshotIsListedAsBeforeMissed() async throws {
    // Claude Code in acceptEdits mode and Codex don't wait for OpenClicky: the edit can land before the manager reads
    // the "before". It used to be compared with itself and dropped from the list.
    let files = AgentTempDir()
    let edited = files.url.appendingPathComponent("plan.md"), created = files.url.appendingPathComponent("new.md")
    try "v1\n".write(to: edited, atomically: true, encoding: .utf8)
    let rig = ScriptedRig { session in
        try? "v2\n".write(to: edited, atomically: true, encoding: .utf8)
        await session.emit(.fileWillChange(path: edited.path))
        await session.emit(.fileChanged(path: edited.path, change: "changed"))
        try? "fresh\n".write(to: created, atomically: true, encoding: .utf8)
        await session.emit(.fileWillChange(path: created.path))
        await session.emit(.fileChanged(path: created.path, change: "created"))
        await session.finish("Done.")
    }
    await rig.manager.setFileDiffs { true }
    let updates = await rig.manager.subscribe()
    let started = try await rig.manager.spawn(AgentSpawnRequest(task: "Edit the plan"))
    _ = await nextAgentReport(updates, for: started.record.id)
    let record = try #require(await rig.manager.job(started.record.id))
    let diffs = try #require(record.fileDiffs)
    #expect(diffs.map(\.fileName) == ["plan.md", "new.md"])
    #expect(diffs[0].kind == .changed && diffs[0].skipped == .beforeMissed && diffs[0].sizeAfter == 3)
    // A file the harness reports as created had nothing before it, however late its snapshot came.
    #expect(diffs[1].kind == .created && diffs[1].skipped == nil && diffs[1].added == 1)
    #expect(AgentFileDiffs.text(of: diffs[1], in: record)?.contains("--- /dev/null") == true)
}

@Test(.timeLimit(.minutes(1))) func snapshotsFollowLinksForTheSizeAndNeverReadPipes() throws {
    let temp = AgentTempDir()
    let big = temp.url.appendingPathComponent("big.csv"), small = temp.url.appendingPathComponent("small.txt")
    try String(repeating: "1,2\n", count: 200).write(to: big, atomically: true, encoding: .utf8)
    try "hi\n".write(to: small, atomically: true, encoding: .utf8)
    let bigLink = temp.url.appendingPathComponent("export.csv"), smallLink = temp.url.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: bigLink, withDestinationURL: big)
    try FileManager.default.createSymbolicLink(at: smallLink, withDestinationURL: small)
    #expect(AgentFileSnapshot.read(bigLink.path, cap: 512) == .tooLarge(bytes: 800), "the target's size, not the link's")
    #expect(AgentFileSnapshot.read(smallLink.path, cap: 512) == .text("hi\n", bytes: 3))
    // A named pipe with no writer would block the read forever.
    let pipe = temp.url.appendingPathComponent("pipe")
    #expect(mkfifo(pipe.path, 0o600) == 0)
    #expect(AgentFileSnapshot.read(pipe.path) == .missing)
}

@Test func aFileCreatedInANewFolderUnderTmpIsOneDiff() throws {
    // /tmp is a link to /private/tmp; the new folder doesn't exist when the "before" is taken.
    let root = "/tmp/openclicky-diff-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let file = root + "/report/out.md"
    #expect(AgentFileDiffs.canonical(file) == "/private" + file)
    var recorder = AgentFileDiffRecorder()
    recorder.willChange(file)
    try FileManager.default.createDirectory(atPath: root + "/report", withIntermediateDirectories: true)
    try "# Out\n".write(toFile: file, atomically: true, encoding: .utf8)
    recorder.changed(file, change: "created")
    let items = recorder.finish(run: 1, folder: URL(fileURLWithPath: root), at: Date())
    #expect(items.count == 1 && items.first?.kind == .created)
    #expect(items.first?.diffFile == "diffs/run-1/1-out.md.diff")
}

@Test func trimmedItemsTakeTheirDiffFilesWithThem() throws {
    let temp = AgentTempDir()
    func item(_ index: Int) throws -> AgentFileDiffItem {
        let file = "diffs/run-\(index)/1-env.diff"
        let url = temp.url.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "-SECRET=1\n+SECRET=2\n".write(to: url, atomically: true, encoding: .utf8)
        return AgentFileDiffItem(id: "run-\(index)/1", run: index, path: "/x/.env", kind: .changed, added: 1, removed: 1, diffFile: file, at: Date())
    }
    let existing = try (1...AgentFileDiffs.maxItemsPerJob).map(item)
    let merged = AgentFileDiffs.merged(existing, [try item(AgentFileDiffs.maxItemsPerJob + 1)], folder: temp.url)
    #expect(merged.count == AgentFileDiffs.maxItemsPerJob && merged.first?.run == 2)
    #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("diffs/run-1/1-env.diff").path))
    #expect(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("diffs/run-2/1-env.diff").path))
}
