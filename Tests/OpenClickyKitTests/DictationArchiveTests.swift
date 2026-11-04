import Foundation
import Testing
@testable import OpenClickyKit

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

@Test func archiveWritesOneJSONLinePerDictationInADailyFile() async throws {
    let directory = temporaryDirectory()
    let archive = DictationTranscriptArchive(directory: directory, calendar: calendar("America/Los_Angeles"))
    // 2026-10-30 23:30 in Los Angeles is already the 31st in UTC; the file follows the local day.
    let late = Date(timeIntervalSince1970: 1_793_428_200)
    try await archive.append(.init(at: late, app: "Notes", bundleID: "com.apple.Notes", text: "Buy milk.", raw: "um buy milk", outcome: "typed"))
    try await archive.append(.init(at: late.addingTimeInterval(60), app: "Slack", text: "On my way", outcome: "clipboard"))

    let url = archive.fileURL(for: late)
    #expect(url.lastPathComponent == "2026-10-30.jsonl")
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 3 && lines[2].isEmpty) // newline-terminated
    #expect(lines[0] == #"{"app":"Notes","at":"2026-10-31T06:30:00Z","bundle_id":"com.apple.Notes","outcome":"typed","raw":"um buy milk","text":"Buy milk."}"#)
    #expect(lines[1] == #"{"app":"Slack","at":"2026-10-31T06:31:00Z","outcome":"clipboard","text":"On my way"}"#)

    let entries = try await archive.entries(on: late)
    #expect(entries.map(\.text) == ["Buy milk.", "On my way"])
    #expect(entries[0].bundleID == "com.apple.Notes")

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func archivePrunesOldDays() async throws {
    let directory = temporaryDirectory()
    let utc = calendar("UTC")
    let archive = DictationTranscriptArchive(directory: directory, calendar: utc)
    let now = Date(timeIntervalSince1970: 1_793_400_000) // 2026-10-30
    for daysAgo in [0, 5, 31, 40] {
        try await archive.append(.init(at: now.addingTimeInterval(Double(-daysAgo) * 86_400), text: "day \(daysAgo)"))
    }
    #expect(try await archive.prune(keepingDays: 30, now: now) == 2)
    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(left == ["2026-10-25.jsonl", "2026-10-30.jsonl"])
}
