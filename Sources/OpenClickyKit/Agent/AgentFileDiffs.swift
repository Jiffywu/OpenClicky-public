import Foundation

// Before-and-after file diffs for agent jobs (developer preview, Settings → Agents). The first time a run is about to
// change a file (`AgentEvent.fileWillChange`: the harness started an edit or asked to make one) its content is
// snapshotted; when the run's turn ends every file it touched is read again and compared. Each changed file becomes an
// `AgentFileDiffItem` in the job record, with its unified diff in `diffs/run-<n>/` in the job folder, so the diffs
// outlive the app. Only text is kept: binaries and files over the size cap are listed without content.

/// One file a job's run created, changed or deleted.
public struct AgentFileDiffItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case created, changed, deleted }

    /// Why an item has no diff text.
    public enum Skip: String, Codable, Sendable {
        /// Either side isn't UTF-8 text (or holds NUL bytes).
        case binary
        /// Either side is over `AgentFileDiffs.maxSnapshotBytes`.
        case tooLarge = "too_large"
        /// The change landed before OpenClicky could read the file, so there is no "before" to compare with.
        case beforeMissed = "before_missed"
    }

    /// `run-<n>/<index>`: unique within the job.
    public var id: String
    /// The run (1-based, as in `AgentJobRecord.runs`) that changed the file.
    public var run: Int
    /// Absolute path.
    public var path: String
    public var kind: Kind
    public var added: Int
    public var removed: Int
    /// The unified diff, relative to the job folder (`diffs/run-2/1-notes.md.diff`); nil when skipped.
    public var diffFile: String?
    public var skipped: Skip?
    /// File sizes in bytes before and after (nil when the file didn't exist).
    public var sizeBefore: Int?
    public var sizeAfter: Int?
    public var at: Date

    public init(id: String, run: Int, path: String, kind: Kind, added: Int = 0, removed: Int = 0, diffFile: String? = nil,
                skipped: Skip? = nil, sizeBefore: Int? = nil, sizeAfter: Int? = nil, at: Date) {
        self.id = id
        self.run = run
        self.path = path
        self.kind = kind
        self.added = added
        self.removed = removed
        self.diffFile = diffFile
        self.skipped = skipped
        self.sizeBefore = sizeBefore
        self.sizeAfter = sizeAfter
        self.at = at
    }

    public var fileName: String { URL(fileURLWithPath: path).lastPathComponent }

    /// "+12 −3", "binary", "too large to keep".
    public var summary: String {
        switch skipped {
        case .binary: "binary"
        case .tooLarge: "too large to keep"
        case .beforeMissed: "changed before it could be read"
        case nil: "+\(added) −\(removed)"
        }
    }
}

/// A file's content as read for a diff.
public enum AgentFileSnapshot: Sendable, Hashable {
    case missing
    case text(String, bytes: Int)
    case binary(bytes: Int)
    case tooLarge(bytes: Int)

    /// Reads `path`: absent (or a folder, or anything else that isn't a regular file, such as a pipe) is `missing`;
    /// over `cap` bytes is `tooLarge`; not UTF-8 or holding NUL bytes is `binary`. Symbolic links are followed, and
    /// the size checked is the target's, so a link to a huge file is never read whole.
    public static func read(_ path: String, cap: Int = AgentFileDiffs.maxSnapshotBytes) -> AgentFileSnapshot {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .missing }
        let size = Int(info.st_size)
        if size > cap { return .tooLarge(bytes: size) }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .missing }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: cap + 1)) ?? Data()
        if data.count > cap { return .tooLarge(bytes: max(size, data.count)) }
        if data.contains(0) { return .binary(bytes: data.count) }
        guard let text = String(data: data, encoding: .utf8) else { return .binary(bytes: data.count) }
        return .text(text, bytes: data.count)
    }

    public var exists: Bool { self != .missing }

    /// When the file (a link's target) was last modified; nil when there is none.
    static func modified(_ path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    public var bytes: Int? {
        switch self {
        case .missing: nil
        case .text(_, let bytes), .binary(let bytes), .tooLarge(let bytes): bytes
        }
    }
}

/// What one run of a job has touched so far: the "before" of each file, in the order first seen. The manager keeps one
/// per running job and turns it into diff items when the turn ends.
public struct AgentFileDiffRecorder: Sendable {
    public private(set) var order: [String] = []
    public private(set) var before: [String: AgentFileSnapshot] = [:]
    /// Paths reported changed with no snapshot taken first (and not reported as created).
    public private(set) var missed: Set<String> = []
    /// Paths whose snapshot came too late (in `missed`): the file had already been modified during the run.
    private var late: Set<String> = []
    public var cap: Int
    /// When the run started. Harnesses don't wait for OpenClicky before editing (Claude Code in acceptEdits mode,
    /// Codex applying a patch), so a file modified at or after this when it is snapshotted may already hold the edit;
    /// it is listed as "before missed" instead of being compared with itself (and silently dropped). Nil trusts
    /// every snapshot.
    public var since: Date?

    public init(cap: Int = AgentFileDiffs.maxSnapshotBytes, since: Date? = nil) {
        self.cap = cap
        self.since = since
    }

    public var isEmpty: Bool { order.isEmpty }

    /// The run is about to change `path`: snapshot it unless it already was this run.
    public mutating func willChange(_ path: String) {
        let path = AgentFileDiffs.canonical(path)
        guard before[path] == nil, !missed.contains(path), order.count < AgentFileDiffs.maxFilesPerRun else { return }
        let snapshot = AgentFileSnapshot.read(path, cap: cap)
        if let since, snapshot.exists, let modified = AgentFileSnapshot.modified(path), modified >= since {
            missed.insert(path)
            late.insert(path)
        } else {
            before[path] = snapshot
        }
        order.append(path)
    }

    /// The run changed `path`. A file reported `created` with no snapshot didn't exist before; any other change with
    /// no snapshot happened before OpenClicky could read the file.
    public mutating func changed(_ path: String, change: String) {
        let path = AgentFileDiffs.canonical(path)
        // Its snapshot came after the edit, but the harness says the file is new, so there was nothing before it.
        if change == "created", late.contains(path) {
            late.remove(path)
            missed.remove(path)
            before[path] = .missing
            return
        }
        guard before[path] == nil, !missed.contains(path), order.count < AgentFileDiffs.maxFilesPerRun else { return }
        if change == "created" {
            before[path] = .missing
        } else {
            missed.insert(path)
        }
        order.append(path)
    }

    /// Compares every touched file with what is on disk now and writes the diffs into `diffs/run-<run>/` under
    /// `folder`. Files that ended as they started are left out.
    public func finish(run: Int, folder: URL, at time: Date) -> [AgentFileDiffItem] {
        var items: [AgentFileDiffItem] = []
        let directory = folder.appendingPathComponent("diffs/run-\(run)", isDirectory: true)
        for path in order {
            let after = AgentFileSnapshot.read(path, cap: cap)
            let index = items.count + 1
            let id = "run-\(run)/\(index)"
            if missed.contains(path) {
                guard after.exists else {
                    items.append(AgentFileDiffItem(id: id, run: run, path: path, kind: .deleted, skipped: .beforeMissed, at: time))
                    continue
                }
                items.append(AgentFileDiffItem(id: id, run: run, path: path, kind: .changed, skipped: .beforeMissed,
                                               sizeAfter: after.bytes, at: time))
                continue
            }
            let start = before[path] ?? .missing
            guard start != after else { continue }
            let kind: AgentFileDiffItem.Kind
            switch (start.exists, after.exists) {
            case (false, false): continue
            case (false, true): kind = .created
            case (true, false): kind = .deleted
            case (true, true): kind = .changed
            }
            var item = AgentFileDiffItem(id: id, run: run, path: path, kind: kind, sizeBefore: start.bytes, sizeAfter: after.bytes, at: time)
            let old: String?, new: String?
            switch (start, after) {
            case (.binary, _), (_, .binary):
                item.skipped = .binary
                items.append(item)
                continue
            case (.tooLarge, _), (_, .tooLarge):
                item.skipped = .tooLarge
                items.append(item)
                continue
            default:
                old = start.text
                new = after.text
            }
            // Files in the job folder are named relative to it; others by their full path.
            let base = AgentFileDiffs.canonical(folder.path) + "/"
            let shown = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            let diff = AgentUnifiedDiff.make(old: old, new: new, path: shown)
            item.added = diff.added
            item.removed = diff.removed
            let name = "\(index)-\(AgentFileDiffs.safeName(item.fileName)).diff"
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try diff.text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
                item.diffFile = "diffs/run-\(run)/\(name)"
            } catch {
                item.diffFile = nil
            }
            items.append(item)
        }
        return items
    }
}

extension AgentFileSnapshot {
    var text: String? { if case .text(let text, _) = self { text } else { nil } }
}

/// Limits and helpers for job file diffs.
public enum AgentFileDiffs {
    /// Files bigger than this are listed but not snapshotted (256 KB).
    public static let maxSnapshotBytes = 256 * 1024
    /// Files followed per run.
    public static let maxFilesPerRun = 80
    /// Diff items kept per job (oldest dropped first).
    public static let maxItemsPerJob = 400

    /// One spelling per file, so `/tmp/x` and `/private/tmp/x` (harnesses report both) are the same file: the real
    /// path of the nearest folder that exists, plus the rest of the path (folders not made yet, and the name).
    public static func canonical(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var rest = [url.lastPathComponent]
        var folder = url.deletingLastPathComponent()
        while true {
            if let real = realpath(folder.path, nil) {
                defer { free(real) }
                let resolved = String(cString: real)
                return (resolved == "/" ? "" : resolved) + "/" + rest.joined(separator: "/")
            }
            guard folder.path != "/", !folder.path.isEmpty else { return url.path }
            rest.insert(folder.lastPathComponent, at: 0)
            folder = folder.deletingLastPathComponent()
        }
    }

    /// Merges a run's items into the job's list, keeping the newest `maxItemsPerJob`. With `folder` (the job's), the
    /// diff files of the items dropped are deleted too, so no copy of a file's content outlives its item.
    public static func merged(_ existing: [AgentFileDiffItem]?, _ new: [AgentFileDiffItem], folder: URL? = nil) -> [AgentFileDiffItem] {
        let all = (existing ?? []) + new
        let kept = Array(all.suffix(maxItemsPerJob))
        if let folder {
            for item in all.dropLast(kept.count) {
                guard let file = item.diffFile, file.hasPrefix("diffs/"), !file.contains("..") else { continue }
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
            }
        }
        return kept
    }

    /// The diff text of an item, read from the job folder.
    public static func text(of item: AgentFileDiffItem, in record: AgentJobRecord) -> String? {
        guard let file = item.diffFile else { return nil }
        return try? String(contentsOf: record.folder.appendingPathComponent(file), encoding: .utf8)
    }

    /// Letters, digits, dots, dashes and underscores; at most 60 characters.
    static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "_" })
        return String(cleaned.prefix(60))
    }
}

/// A unified diff (as `diff -u` writes it, with three lines of context) between two texts.
public struct AgentUnifiedDiff: Sendable, Hashable {
    public var text: String
    public var added: Int
    public var removed: Int

    struct Line: Hashable {
        var text: String
        /// False for a last line with no newline after it.
        var terminated: Bool
    }

    static func lines(_ text: String?) -> [Line] {
        guard let text, !text.isEmpty else { return [] }
        var parts = text.components(separatedBy: "\n")
        let terminated = parts.last == ""
        if terminated { parts.removeLast() }
        return parts.enumerated().map { index, part in Line(text: part, terminated: terminated || index < parts.count - 1) }
    }

    enum Op { case same(Line), removed(Line), added(Line) }

    /// The most changed lines (old plus new, after the shared start and end) compared line by line; Myers needs about
    /// the square of this in memory, so 2,000 keeps it to tens of megabytes.
    static let maxMyersLines = 2_000

    /// - Parameters:
    ///   - old: the text before; nil when the file didn't exist (shown as `/dev/null`).
    ///   - new: the text after; nil when the file was deleted.
    public static func make(old: String?, new: String?, path: String, context: Int = 3) -> AgentUnifiedDiff {
        let a = lines(old), b = lines(new)
        // Lines shared at the start and end are matched directly. The middle goes through Myers, whose time and memory
        // grow with the square of the edit distance, only when it is small enough; a bigger middle (a file rewritten
        // throughout) is shown as one removed block and one added block.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let oldMiddle = prefix..<(a.count - suffix), newMiddle = prefix..<(b.count - suffix)
        var removedAt = Set<Int>(), insertedAt = Set<Int>()
        if oldMiddle.count + newMiddle.count <= maxMyersLines {
            for change in Array(b[newMiddle]).difference(from: Array(a[oldMiddle])) {
                switch change {
                case .remove(let offset, _, _): removedAt.insert(prefix + offset)
                case .insert(let offset, _, _): insertedAt.insert(prefix + offset)
                }
            }
        } else {
            removedAt = Set(oldMiddle)
            insertedAt = Set(newMiddle)
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removedAt.contains(i) {
                ops.append(.removed(a[i])); i += 1
            } else if j < b.count, insertedAt.contains(j) {
                ops.append(.added(b[j])); j += 1
            } else if i < a.count, j < b.count {
                ops.append(.same(a[i])); i += 1; j += 1
            } else if i < a.count {
                ops.append(.removed(a[i])); i += 1
            } else {
                ops.append(.added(b[j])); j += 1
            }
        }
        let display = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var out = "--- \(old == nil ? "/dev/null" : "a/" + display)\n+++ \(new == nil ? "/dev/null" : "b/" + display)\n"
        var added = 0, removed = 0
        // Hunks: runs of changes with up to `context` unchanged lines around them (and merged when closer than that).
        let changed = ops.indices.filter { if case .same = ops[$0] { false } else { true } }
        var hunks: [ClosedRange<Int>] = []
        for index in changed {
            let low = max(0, index - context), high = min(ops.count - 1, index + context)
            if let last = hunks.last, low <= last.upperBound + 1 {
                hunks[hunks.count - 1] = last.lowerBound...max(last.upperBound, high)
            } else {
                hunks.append(low...high)
            }
        }
        // Line numbers (1-based) of the next old and new line at each op.
        var oldLine = [Int](repeating: 0, count: ops.count + 1), newLine = [Int](repeating: 0, count: ops.count + 1)
        var o = 1, n = 1
        for (index, op) in ops.enumerated() {
            oldLine[index] = o
            newLine[index] = n
            switch op {
            case .same: o += 1; n += 1
            case .removed: o += 1
            case .added: n += 1
            }
        }
        for hunk in hunks {
            var oldCount = 0, newCount = 0
            var body = ""
            for index in hunk {
                let (prefix, line): (String, Line)
                switch ops[index] {
                case .same(let l): prefix = " "; line = l; oldCount += 1; newCount += 1
                case .removed(let l): prefix = "-"; line = l; oldCount += 1; removed += 1
                case .added(let l): prefix = "+"; line = l; newCount += 1; added += 1
                }
                body += prefix + line.text + "\n"
                if !line.terminated { body += "\\ No newline at end of file\n" }
            }
            let oldStart = oldCount == 0 ? oldLine[hunk.lowerBound] - 1 : oldLine[hunk.lowerBound]
            let newStart = newCount == 0 ? newLine[hunk.lowerBound] - 1 : newLine[hunk.lowerBound]
            out += "@@ -\(range(oldStart, oldCount)) +\(range(newStart, newCount)) @@\n" + body
        }
        return AgentUnifiedDiff(text: out, added: added, removed: removed)
    }

    private static func range(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
}
