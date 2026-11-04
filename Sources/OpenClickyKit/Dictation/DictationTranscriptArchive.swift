import Foundation

/// A local, private log of what was dictated: one JSON object per line, one file per day, in
/// `~/Library/Application Support/OpenClicky/DictationTranscripts/YYYY-MM-DD.jsonl`. Nothing leaves the Mac.
public actor DictationTranscriptArchive {
    public struct Entry: Codable, Sendable, Equatable {
        /// When the text was delivered.
        public var at: Date
        /// The app the text went to.
        public var app: String?
        public var bundleID: String?
        /// The text as typed (after cleanup).
        public var text: String
        /// The transcript before cleanup, when it differs.
        public var raw: String?
        /// How it was delivered: "typed", "clipboard", …
        public var outcome: String?

        public init(at: Date = Date(), app: String? = nil, bundleID: String? = nil, text: String, raw: String? = nil,
                    outcome: String? = nil) {
            self.at = at
            self.app = app
            self.bundleID = bundleID
            self.text = text
            self.raw = raw
            self.outcome = outcome
        }

        enum CodingKeys: String, CodingKey {
            case at, app, text, raw, outcome
            case bundleID = "bundle_id"
        }
    }

    public nonisolated let directory: URL
    private nonisolated let calendar: Calendar

    public init(directory: URL = DictationTranscriptArchive.defaultDirectory, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("DictationTranscripts", isDirectory: true)
    }

    /// The file for the local calendar day containing `date`.
    public nonisolated func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent(Self.dayName(date, calendar: calendar) + ".jsonl")
    }

    static func dayName(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// One entry as a JSON line (no trailing newline).
    public static func line(for entry: Entry) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(entry), as: UTF8.self)
    }

    public func append(_ entry: Entry) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let url = fileURL(for: entry.at)
        let data = Data((try Self.line(for: entry) + "\n").utf8)
        if manager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Entries for the day containing `date`, oldest first. Lines that don't parse are skipped.
    public func entries(on date: Date) throws -> [Entry] {
        let url = fileURL(for: date)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap {
            try? decoder.decode(Entry.self, from: Data($0.utf8))
        }
    }

    /// Deletes day files older than `days` days before `now`. Returns how many were removed.
    @discardableResult
    public func prune(keepingDays days: Int, now: Date = Date()) throws -> Int {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) else { return 0 }
        let cutoffName = Self.dayName(cutoff, calendar: calendar)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where name.hasSuffix(".jsonl") && name.count == 16 && String(name.prefix(10)) < cutoffName {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }
}
