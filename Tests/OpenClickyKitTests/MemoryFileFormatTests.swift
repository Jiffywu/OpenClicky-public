import Foundation
import Testing
@testable import OpenClickyKit

/// The memory folder's files: each format survives a parse/render round trip, and hand edits are kept.
@Suite struct MemoryFileFormatTests {
    // MARK: - about-the-user.md

    @Test func handEditedProfileRoundTripsByteForByte() {
        let text = """
            # About the user

            Some intro the user rewrote.

            ## Basics
            - Name: Sam
            * Lives in Porto
              + Indented item with   odd spacing
            A free-text line the user typed.

            ### A sub-heading the user added
            <!-- a comment -->

            ## Custom section they invented
            - Plays the cello

            # Right now
            ## Recent asks
            - Asked about train times to Lisbon

            """
        let profile = MemoryProfile(text: text)
        #expect(profile.text == text)
        #expect(MemoryProfile(text: profile.text) == profile)
        #expect(profile.sections.map(\.title) == ["Basics", "Custom section they invented", "Recent asks"])
        #expect(profile.bullets.map(\.text) == ["Name: Sam", "Lives in Porto", "Indented item with   odd spacing", "Plays the cello",
                                                "Asked about train times to Lisbon"])
        let basics = profile.section(named: "basics")!
        #expect(profile.content(of: basics) == ["Name: Sam", "Lives in Porto", "Indented item with   odd spacing",
                                                "A free-text line the user typed.", "### A sub-heading the user added"])
        #expect(profile.isVolatile(profile.section(named: "Recent asks")!))
        #expect(!profile.isVolatile(basics))
    }

    @Test func crlfAndMissingTrailingNewlineNormalize() {
        let profile = MemoryProfile(text: "## Basics\r\n- One\r\n- Two")
        #expect(profile.text == "## Basics\n- One\n- Two\n")
        #expect(profile.bullets.map(\.text) == ["One", "Two"])
    }

    @Test func templateHasTheDefaultLayoutAndNoItems() {
        let template = MemoryProfile.template
        let expected = MemoryProfile.defaultLayout.flatMap(\.sections)
        #expect(template.sections.map(\.title) == expected)
        #expect(template.bullets.isEmpty)
        #expect(MemoryProfile(text: template.text) == template)
    }

    @Test func addingItemsKeepsTheDocumentReadable() {
        var profile = MemoryProfile.template
        let first = profile.add("Works as a product designer", to: "Work and background")
        let loose = profile.add("Designs in Figma all day", to: "work & background")
        let duplicate = profile.add("works as a product designer.", to: "Work and background")
        let volatile = profile.add("Asked how to export a PDF", to: "Recent asks")
        let created = profile.add("Keeps bees", to: "Hobbies")
        #expect(first)
        #expect(loose, "section names match loosely")
        #expect(!duplicate, "a duplicate is refused")
        #expect(volatile)
        #expect(created, "a missing section is created")

        let reparsed = MemoryProfile(text: profile.text)
        #expect(reparsed == profile)
        #expect(reparsed.bullets.map(\.section) == ["Work and background", "Work and background", "Hobbies", "Recent asks"])
        // The new section sits at the end of the first group, before "# Right now".
        let hobbies = reparsed.section(named: "Hobbies")!
        #expect(hobbies.group == "About the user")
        // Every heading is preceded by a blank line (or starts the file).
        for (index, line) in reparsed.lines.enumerated() where line.hasPrefix("#") && index > 0 {
            #expect(reparsed.lines[index - 1].isEmpty, "line \(index): \(line)")
        }
        #expect(profile.text.contains("## Work and background\n- Works as a product designer\n- Designs in Figma all day\n\n## Goals"))
    }

    @Test func removingItemsByIdAndByText() {
        var profile = MemoryProfile.template
        profile.add("Lives in Berlin", to: "Basics")
        profile.add("Has a dog called Pixel", to: "Basics")
        let berlin = profile.bullets.first { $0.text == "Lives in Berlin" }!
        #expect(berlin.id == MemoryID.profile(section: "Basics", text: "lives in berlin"))
        #expect(profile.removeBullet(id: berlin.id)?.text == "Lives in Berlin")
        #expect(profile.removeBullet(id: berlin.id) == nil)
        #expect(profile.removeBullet(matching: "has a dog, Pixel", in: "Basics")?.text == "Has a dog called Pixel")
        #expect(profile.bullets.isEmpty)
    }

    // MARK: - standing-context.md and how-tos.md

    @Test func standingContextRoundTrips() {
        let lines = ["Answer in British English", "Keep spoken answers under three sentences"]
        let text = MemoryFileFormat.renderStanding(lines)
        #expect(MemoryFileFormat.parseStanding(text) == lines)
        #expect(MemoryFileFormat.renderStanding(MemoryFileFormat.parseStanding(text)) == text)
        // Hand edits: other text is ignored, any bullet marker counts.
        #expect(MemoryFileFormat.parseStanding("# Mine\nnote\n* one\n+ two\n- \n-three") == ["one", "two"])
        #expect(MemoryFileFormat.parseStanding(MemoryFileFormat.renderStanding([])) == [])
    }

    @Test func howTosRoundTrip() {
        let howTos = [
            MemoryHowTo(title: "Export the weekly report", steps: "1. Open Numbers\n2. File > Export To > PDF\n\n3. Save to ~/Reports"),
            MemoryHowTo(title: "Join the standup", steps: ""),
        ]
        let text = MemoryFileFormat.renderHowTos(howTos)
        #expect(MemoryFileFormat.parseHowTos(text) == howTos)
        #expect(MemoryFileFormat.renderHowTos(MemoryFileFormat.parseHowTos(text)) == text)
        #expect(howTos[0].id == MemoryHowTo(title: "export the weekly report.", steps: "other").id, "ids follow the title")
    }

    // MARK: - memories.jsonl

    @Test func memoriesRoundTripThroughJSONL() throws {
        let records = [
            MemoryRecord(id: "m-00000001", text: "Sister Ana lives in Lisbon", kind: .fact, createdAt: MemoryFixtures.daysAgo(10), source: .voice),
            MemoryRecord(id: "m-00000002", text: "Talked through the Q4 budget deck; slide 7 unfinished", kind: .session,
                         createdAt: MemoryFixtures.daysAgo(1), updatedAt: MemoryFixtures.now, source: .session,
                         tags: ["work", "budget"], sessionID: "4C1E2B4A-0000-4000-8000-000000000001"),
            MemoryRecord(id: "m-00000003", text: "Quote \"marks\", emoji 🐝, slash / and\nnewline", kind: .preference,
                         createdAt: MemoryFixtures.now, source: .cli),
        ]
        let file = MemoryFileFormat.MemoriesFile(records: records)
        let text = MemoryFileFormat.renderMemories(file)
        #expect(text.split(separator: "\n").count == 3, "one record per line")
        #expect(text.contains(#""created_at":"2026-10-29T12:00:00Z""#))
        #expect(text.contains(#""session":"4C1E2B4A-0000-4000-8000-000000000001""#))
        #expect(MemoryFileFormat.parseMemories(text) == file)
        #expect(MemoryFileFormat.renderMemories(MemoryFileFormat.parseMemories(text)) == text)
    }

    @Test func memoriesReaderIsForgivingAndKeepsUnreadableLines() {
        let text = """
            {"id":"m-1","text":"fractional seconds","kind":"fact","source":"user","created_at":"2026-10-01T08:30:00.250Z"}
            {"id":"m-2","text":"a plain date and a future kind","kind":"hunch","source":"telepathy","created_at":"2026-09-15"}
            this line was mangled by hand

            {"id":"m-3","text":"no date"}
            """
        let file = MemoryFileFormat.parseMemories(text)
        #expect(file.records.map(\.id) == ["m-1", "m-2"])
        #expect(file.records[1].kind == .fact)
        #expect(file.records[1].source == .user)
        #expect(file.unreadableLines == ["this line was mangled by hand", #"{"id":"m-3","text":"no date"}"#])
        let rendered = MemoryFileFormat.renderMemories(file)
        #expect(rendered.hasSuffix("this line was mangled by hand\n{\"id\":\"m-3\",\"text\":\"no date\"}\n"))
    }

    // MARK: - Through the store

    @Test func storeWritesFilesAPersonCanReadAndReadsTheirEdits() throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store()
        _ = try store.save("Sister Ana lives in Lisbon", source: .user)
        _ = try store.addStanding("Answer in British English")
        _ = try store.saveHowTo(title: "Export the weekly report", steps: "1. Open Numbers\n2. Export as PDF")
        _ = try store.addToProfile("Product designer at a small studio", section: "Work and background")

        let profileText = try String(contentsOf: store.profileURL, encoding: .utf8)
        #expect(profileText.contains("## Work and background\n- Product designer at a small studio\n"))
        #expect(try String(contentsOf: store.standingURL, encoding: .utf8).contains("- Answer in British English\n"))
        #expect(try String(contentsOf: store.howTosURL, encoding: .utf8).contains("## Export the weekly report\n1. Open Numbers\n2. Export as PDF\n"))

        // The user edits the profile and standing context by hand; the store sees it at once.
        try (profileText + "\n## Pets\n- A cat called Miso\n").write(to: store.profileURL, atomically: true, encoding: .utf8)
        try "- Use metric units\n".write(to: store.standingURL, atomically: true, encoding: .utf8)
        let snapshot = try store.snapshot()
        #expect(snapshot.profile.bullets.map(\.text).contains("A cat called Miso"))
        #expect(snapshot.standing == ["Use metric units"])
        #expect(snapshot.memories.map(\.text) == ["Sister Ana lives in Lisbon"])
        #expect(snapshot.howTos.map(\.title) == ["Export the weekly report"])

        // Files are private to the user.
        let attributes = try FileManager.default.attributesOfItem(atPath: store.memoriesURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func emptyFolderReadsAsTheTemplate() throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store()
        let snapshot = try store.snapshot()
        #expect(snapshot.isEmpty)
        #expect(snapshot.profile == .template)
        #expect(try store.profileText() == MemoryProfile.template.text)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path), "reading creates nothing")
    }
}
