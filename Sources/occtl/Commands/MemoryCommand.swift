import Foundation
import OpenClickyKit

/// `occtl memory …`: look at and change what OpenClicky remembers, from the terminal.
enum MemoryCommand {
    static let usageText = """
        Usage:
          occtl memory list [query]          everything remembered (or the best matches for query), with ids
          occtl memory add [--kind K] <text> remember a line; K is fact (default), preference, event or standing
          occtl memory forget <id>           forget one item by id
          occtl memory forget --all          forget everything, as Settings → Memory does (recall then leaves out
                                             earlier chats from before now)
          occtl memory profile               print about-the-user.md
          occtl memory prompt [query]        the memory block the brain would get for query
        Files live in \(MemoryStore.defaultDirectory.path)
        (set OPENCLICKY_MEMORY_DIR to use another folder).
        """

    static let memory = OcctlCommand(name: "memory", usage: "memory <list|add|forget|profile|prompt> what OpenClicky remembers about you") { args in
        let store = MemoryStore(directory: directory)
        guard let verb = args.first else { fail(usageText) }
        let rest = Array(args.dropFirst())
        switch verb {
        case "list", "ls":
            try list(store, query: rest.joined(separator: " "))
        case "add":
            try add(store, rest)
        case "forget", "rm":
            guard rest.count == 1 else { fail("Usage: occtl memory forget <id> | --all") }
            if rest[0] == "--all" {
                try store.forgetEverything()
                print("Forgot everything in \(store.directory.path)")
                return
            }
            guard let entry = try store.forget(id: rest[0]) else { fail("Nothing remembered has the id \(rest[0]).") }
            print("Forgot \(entry.id) (\(entry.place.label)): \(entry.text)")
        case "profile":
            print(try store.profileText(), terminator: "")
            FileHandle.standardError.write(Data("(\(store.profileURL.path))\n".utf8))
        case "prompt":
            let section = MemoryPromptBuilder().build(from: try store.snapshot(), query: rest.joined(separator: " "))
            if section.text.isEmpty { print("(nothing remembered fits the prompt)") } else { print(section.text) }
            FileHandle.standardError.write(Data("~\(section.estimatedTokens) tokens, \(section.includedIDs.count) items, \(section.omitted) left out\n".utf8))
        default:
            fail(usageText)
        }
    }

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["OPENCLICKY_MEMORY_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return MemoryStore.defaultDirectory
    }

    private static func list(_ store: MemoryStore, query: String) throws {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let matches = try store.recall(query, limit: 20)
            if matches.isEmpty { print("Nothing remembered matches \"\(query)\".") }
            for match in matches { print(line(match.entry) + String(format: "  (score %.2f)", match.score)) }
            return
        }
        let snapshot = try store.snapshot()
        if snapshot.isEmpty {
            print("OpenClicky doesn't remember anything yet.")
            return
        }
        let groups: [(String, [MemoryEntry])] = [
            ("Standing context", snapshot.standingEntries),
            ("Profile (about-the-user.md)", snapshot.profileEntries),
            ("How-tos", snapshot.howToEntries),
            ("Memories, newest first", snapshot.memoryEntries),
        ]
        for (title, entries) in groups where !entries.isEmpty {
            print("\(title):")
            for entry in entries { print("  " + line(entry)) }
        }
    }

    private static func line(_ entry: MemoryEntry) -> String {
        var parts = [entry.id]
        if let date = entry.date { parts.append(day(date)) }
        parts.append(entry.place.label)
        return "\(parts.joined(separator: "  "))  \(entry.text.replacingOccurrences(of: "\n", with: " "))"
    }

    private static func add(_ store: MemoryStore, _ args: [String]) throws {
        var words = args
        var kind = "fact"
        if let flag = words.firstIndex(of: "--kind") {
            guard flag + 1 < words.count else { fail("--kind needs a value: fact, preference, event or standing") }
            kind = words[flag + 1]
            words.removeSubrange(flag...(flag + 1))
        }
        let text = words.joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { fail("Usage: occtl memory add [--kind K] <text>") }
        let outcome: MemorySaveOutcome
        switch kind {
        case "standing": outcome = try store.addStanding(text)
        case "fact", "preference", "event": outcome = try store.save(text, kind: MemoryKind(rawValue: kind)!, source: .cli)
        default: fail("Unknown kind \(kind); use fact, preference, event or standing.")
        }
        switch outcome {
        case .saved(let entry): print("Remembered \(entry.id) (\(entry.place.label)): \(entry.text)")
        case .alreadyKnown(let entry): print("Already remembered as \(entry.id): \(entry.text)")
        case .refused(let reason): fail("Not saved: \(reason).")
        }
    }

    private static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
