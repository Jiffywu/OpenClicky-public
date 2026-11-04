import CoreGraphics
import CoreText
import Foundation
import QuartzCore
import Testing
@testable import OpenClickyKit

// The breadth of the 2D drawing language (docs/dsl.md): actions, notes, button actions and links, the edits restyle,
// scale and startOver, paths and polygons, the extra pieces, pause and resume, spoken word counts, continuing a turn,
// sound recipes and the debug beats.

private func host(_ clock: VirtualClock = VirtualClock()) throws -> DrawingEngineHost {
    try DrawingEngineHost(clock: { clock.now })
}

@discardableResult
private func begin(_ h: DrawingEngineHost, pace: DrawingBeginOptions.Pace = .now, keep: Bool = false) -> [DrawingEvent] {
    h.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: pace, keep: keep)))
}

private func feed(_ h: DrawingEngineHost, _ program: String, end: Bool = true) -> [DrawingEvent] {
    var events = h.perform(.append(program + "\n"))
    if end { events += h.perform(.end) }
    events += h.perform(.drain)
    return events
}

private func marks(_ events: [DrawingEvent]) -> [DrawingMark] {
    events.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
}
private func actions(_ events: [DrawingEvent]) -> [DrawingAction] {
    events.compactMap { if case .action(let a) = $0 { a } else { nil } }
}
private func warnings(_ events: [DrawingEvent]) -> [String] {
    events.compactMap { if case .warning(let m) = $0 { m } else { nil } }
}
private func errors(_ events: [DrawingEvent]) -> [String] {
    events.compactMap { if case .error(let m, _) = $0 { m } else { nil } }
}

// MARK: Actions

@Test func actionsHappenWhenTheirLineIsHeard() throws {
    let clock = VirtualClock()
    let h = try host(clock)
    begin(h, pace: .speech)
    var events = feed(h, """
    step(1)
    say("First line.")
    dot(10, 10)
    step(2)
    say("Now I'll type and copy.")
    typeText(400, 300, "hello\\nworld")
    copyText("copied words")
    openPage("https://example.com/page")
    openPage("https://example.com/second")
    openPage("file:///etc/passwd")
    handOff({task: "Summarise the article", label: "Summary"})
    sfx("tada")
    sfx("airhorn")
    """)
    #expect(errors(events).isEmpty, "\(errors(events))")
    #expect(actions(events).isEmpty, "nothing acts before its line")
    events += h.perform(.lineStarted(0, 1))
    clock.now += 1.2
    events += h.perform(.drain)
    #expect(actions(events).isEmpty, "the actions belong to the second line")
    events += h.perform(.lineStarted(1, 2))
    clock.now += 2
    events += h.perform(.drain)
    let done = actions(events)
    #expect(done.map(\.role) == [.type, .copy, .open, .handoff, .sfx])
    #expect(done[0].text == "hello\nworld")
    #expect(done[0].point == CGPoint(x: 400, y: 300))
    #expect(done[1].text == "copied words")
    #expect(done[2].url?.absoluteString == "https://example.com/page")
    #expect(done[3].text == "Summarise the article" && done[3].label == "Summary")
    #expect(done[4].text == "tada")
    #expect(done.allSatisfy { !$0.fromClick })
    let said = warnings(events).joined(separator: " | ")
    #expect(said.contains("one openPage() per answer"))
    #expect(said.contains("opens web pages only"))
    #expect(said.contains("sfx() plays one of"))
    // Actions draw nothing.
    #expect(marks(events).allSatisfy { $0.kind != "action" })
}

@Test func buttonsCanOpenCopyHandOffOrAsk() throws {
    let h = try host()
    begin(h)
    let events = feed(h, """
    button(100, 100, "Ask me", "What else?")
    button(100, 200, "Open it", {open: "https://example.com"})
    button(100, 300, "Copy it", {copy: "the words"})
    button(100, 400, "Do it for me", {handoff: "Rename the files"})
    button(100, 500, "A card", {card: "Show the timeline"})
    const photo = {x: 600, y: 100, w: 300, h: 200}
    button(photo, "Buy", {open: "https://example.com/buy"})
    """)
    let buttons = marks(events).filter { $0.kind == "button" }
    #expect(buttons.count == 6)
    var clicked: [DrawingEvent] = []
    for button in buttons { clicked += h.perform(.click(button.id)) }
    let asks = clicked.compactMap { if case .ask(let text) = $0 { text } else { nil } }
    #expect(asks == ["What else?", "Show the timeline"])
    let done = actions(clicked)
    #expect(done.map(\.role) == [.open, .copy, .handoff, .open])
    #expect(done.allSatisfy { $0.fromClick })
    #expect(done[1].text == "the words")
    #expect(done[2].text == "Rename the files" && done[2].label == "Do it for me")
    // The anchored button hangs from the bottom edge of what it belongs to, centred.
    let buy = try #require(buttons.last)
    let at = buy.json["at"]?.arrayValue?.compactMap(\.doubleValue) ?? []
    let w = buy.json["w"]?.doubleValue ?? 0, hgt = buy.json["h"]?.doubleValue ?? 0
    let centre = CGPoint(x: at[0] + w / 2, y: at[1] + hgt / 2)
    #expect(abs(centre.x - 750) < 1)
    #expect(abs(centre.y - 300) < 1)
}

@Test func linkedWordsShowTheirLabelAndOpenWhenClicked() throws {
    let h = try host()
    begin(h)
    let events = feed(h, """
    text(100, 100, "See [the docs](https://example.com/docs/guide) for more")
    text(100, 200, "Source: https://www.example.org/a/very/long/path/to/an/article?id=12345")
    """)
    let texts = marks(events).filter { $0.kind == "text" }
    #expect(texts[0].json["text"]?.stringValue == "See the docs for more")
    #expect(texts[0].json["link"]?.stringValue == "https://example.com/docs/guide")
    #expect(texts[1].json["text"]?.stringValue == "Source: example.org/…")
    let clicked = actions(h.perform(.click(texts[0].id)))
    #expect(clicked.first?.role == .open && clicked.first?.url?.host == "example.com" && clicked.first?.fromClick == true)
}

// MARK: Notes

@Test func seenNotedPlanAndLessonTitleDrawNothingAndReachTheHost() throws {
    let h = try host()
    begin(h)
    let events = feed(h, """
    lessonTitle("Making a pivot table")
    seen("The user has a spreadsheet of sales open")
    noted("Works in finance")
    plan("A grid with arrows from rows to the pivot")
    box(10, 10, 100, 60)
    """)
    let notes = events.compactMap { if case .note(let kind, let text) = $0 { "\(kind): \(text)" } else { nil } }
    #expect(notes == ["lesson: Making a pivot table", "seen: The user has a spreadsheet of sales open", "noted: Works in finance"])
    #expect(marks(events).map(\.kind) == ["box"])
    let summary = h.summary()
    #expect(summary["lessonTitle"]?.stringValue == "Making a pivot table")
    #expect(summary["notes"]?.arrayValue?.count == 4)
}

// MARK: Edits

@Test func restyleScaleAndUndo() throws {
    let h = try host()
    begin(h)
    var events = feed(h, """
    text(100, 100, "Big idea", {size: 18, name: "idea"})
    box(300, 300, 200, 100, {name: "frame"})
    """, end: false)
    events += feed(h, """
    restyle("idea", {size: 36, style: "bold"})
    restyle("frame", {dash: true, size: 6})
    scale("frame", 2)
    var settle = 1
    """, end: false)
    let changed = marks(events).filter { $0.json["edit"] != nil }
    let text = try #require(changed.last { $0.kind == "text" })
    #expect(text.json["size"]?.doubleValue == 36)
    #expect(text.json["style"]?.stringValue == "bold")
    #expect(text.json["edit"]?.stringValue == "restyle")
    let box = try #require(changed.last { $0.kind == "box" })
    let xf = box.json["xf"]?.arrayValue?.compactMap(\.doubleValue) ?? []
    #expect(xf.first == 2)
    // Scaled about its centre (400, 350): x' = 2x + tx keeps 400 → 400.
    #expect(abs(2 * 400 + xf[1] - 400) < 0.5 && abs(2 * 350 + xf[2] - 350) < 0.5)
    #expect(box.json["dash"] != nil)
    events = feed(h, "undo()\n")
    let restored = try #require(marks(events).last { $0.kind == "box" })
    #expect(restored.json["xf"] == nil || restored.json["xf"]?.arrayValue?.first?.doubleValue == 1)
}

@Test func startOverErasesWhatWasDrawnAndCarriesOn() throws {
    let clock = VirtualClock()
    let h = try host(clock)
    begin(h)
    var events = feed(h, "box(10, 10, 100, 60)\ntext(10, 100, \"old\")\nstartOver()\ncircle(500, 400, 50)\n")
    let old = Set(marks(events).filter { $0.kind != "circle" }.map(\.id))
    #expect(old.count == 2)
    clock.now += 5
    events += h.perform(.drain)
    let removed = Set(events.flatMap { event -> [String] in if case .remove(let ids) = event { ids } else { [] } })
    #expect(removed == old)
    #expect(marks(events).contains { $0.kind == "circle" })
    #expect(events.contains { if case .sound(let r) = $0 { r.accents.contains { $0.id == "page-clear" } } else { false } })
}

// MARK: Paths and pieces

@Test func pathsAndPolygonsDraw() throws {
    let h = try host()
    begin(h)
    let events = feed(h, """
    path("M 10 10 L 110 10 Q 160 60 110 110 A 50 50 0 0 1 10 110 Z", {fill: "sky"})
    path("M 300 300 h 50 v 50 M 400 300 c 20 0 40 20 40 40")
    poly([[600, 100], [700, 120], [680, 200]], {fill: "yellow", label: "zone"})
    path("not a path")
    """)
    let lines = marks(events).filter { $0.kind == "line" }
    #expect(lines.count == 3)
    let closed = lines[0]
    #expect(closed.json["closed"]?.boolValue == true && closed.json["fill"] != nil)
    let pts = closed.json["pts"]?.arrayValue ?? []
    #expect(pts.count > 20, "curves are flattened")
    #expect(pts.first == pts.last, "a closed path returns to its start")
    #expect(lines[1].json["segs"]?.arrayValue?.count == 2)
    #expect(marks(events).contains { $0.kind == "text" && $0.json["text"]?.stringValue == "zone" })
    #expect(warnings(events).contains { $0.contains("found no lines") })
}

@Test func theExtraPiecesDraw() throws {
    let h = try host()
    begin(h)
    let events = feed(h, """
    spotlight(400, 300, 200, 100)
    sticky(900, 80, "Remember the milk", "mint")
    const r = receipt(80, 80, "Steps", ["Open the file", "Pick a column", "Press sort"])
    clipping(80, 400, 360, "News", "A short body of words from the article.", "example.com")
    legend(600, 700, [["red", "hot"], ["blue", "cold"]])
    sources(600, 760, [["nasa.gov", "NASA"], ["esa.int", "ESA"], ["nasa.gov", "NASA"]])
    text(600, 500, "A row of words")
    tie([620, 510], {x: 1000, y: 450, w: 160, h: 120})
    ring(500, 600, 120, 30, "this field")
    frame(700, 560, 200, 100, "area")
    trace([[1000, 600], [1100, 620], [1080, 700], [990, 690]], {fill: true, label: "blob"})
    connect({x: 100, y: 700, w: 60, h: 40}, {x: 300, y: 720, w: 60, h: 40}, {label: "to"})
    strike(100, 790, 80)
    scroll(1200, 400, "down")
    cheer(1100, 200, "yay")
    cheer(1100, 260, "again")
    num(50, 50, 3)
    molecule("CCO", 10, 10, 100, 100)
    """)
    #expect(errors(events).isEmpty, "\(errors(events))")
    let kinds = Set(marks(events).map(\.kind))
    for kind in ["spotlight", "sticky", "paper", "text", "dot", "arrow", "box", "region", "line", "pill", "badge"] {
        #expect(kinds.contains(kind), "missing \(kind)")
    }
    let all = marks(events)
    let sticky = try #require(all.first { $0.kind == "sticky" })
    #expect((sticky.json["lines"]?.arrayValue?.count ?? 0) >= 1)
    let sources = try #require(all.first { $0.json["text"]?.stringValue?.hasPrefix("Sources:") == true })
    #expect(sources.json["text"]?.stringValue == "Sources: NASA · ESA")
    // The tie starts just past the end of the row's words, not where the program said.
    let words = try #require(all.first { $0.json["text"]?.stringValue == "A row of words" })
    let tie = try #require(all.first { $0.json["role"]?.stringValue == "tie" })
    let start = tie.json["pts"]?.arrayValue?.first?.arrayValue?.compactMap(\.doubleValue) ?? []
    let wordsEnd = (words.json["at"]?.arrayValue?.first?.doubleValue ?? 0) + (words.json["w"]?.doubleValue ?? 0)
    #expect(start.first.map { $0 > wordsEnd && $0 < wordsEnd + 20 } == true, "tie starts at \(start), words end at \(wordsEnd)")
    #expect(warnings(events).contains { $0.contains("one cheer()") })
    #expect(warnings(events).contains { $0.contains("molecule() is not available") })
}

// MARK: Pacing: pause, resume and spoken word counts

@Test func pauseHoldsThePenAndResumeCarriesOnWhereItStopped() throws {
    let clock = VirtualClock()
    let h = try host(clock)
    begin(h, pace: .speech)
    var events = feed(h, "step(1)\nsay(\"One.\")\ndot(10, 10)\nstep(2)\nsay(\"Two.\")\ndot(20, 20)\ncopyText(\"x\")\n")
    events += h.perform(.lineStarted(0, 1))
    clock.now += 1
    events += h.perform(.lineFinished(0))
    events += h.perform(.pause)
    let pausedAt = clock.now
    // The voice starts line 1 while the drawing is held: nothing more is drawn or done.
    events += h.perform(.lineStarted(1, 1))
    clock.now += 5
    let held = h.perform(.drain)
    #expect(marks(held).isEmpty && actions(held).isEmpty)
    var after = h.perform(.resume)
    clock.now += 1.5
    after += h.perform(.drain)
    let dot = try #require(marks(after).first)
    // The line's marks are timed on the drawing's clock, which ran 5 s behind the host clock.
    let base = dot.json["base"]?.doubleValue ?? 0
    #expect(abs(base - pausedAt) < 0.01, "base \(base) vs \(pausedAt)")
    #expect(actions(after).map(\.role) == [.copy])
}

@MainActor
@Test func thePainterFreezesWhilePaused() throws {
    let clock = VirtualClock(CACurrentMediaTime() + 100_000)
    let painter = DrawingPainter(canvas: .init(width: 200, height: 200), clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    #expect(painter.now() == clock.now)
    painter.pause()
    clock.now += 3
    #expect(painter.now() == clock.now - 3)
    #expect(painter.layer.speed == 0)
    painter.resume()
    clock.now += 1
    #expect(abs(painter.now() - (clock.now - 3)) < 1e-9)
    #expect(painter.pausedTotal == 3)
    #expect(painter.layer.speed == 1)
}

@Test func aRunningWordCountStartsAndFinishesLines() throws {
    let clock = VirtualClock()
    let h = try host(clock)
    begin(h, pace: .speech)
    var events = feed(h, "say(\"One two three.\")\ndot(1, 1)\nsay(\"Four five.\")\ndot(2, 2)\n")
    #expect(marks(events).isEmpty)
    events = h.perform(.spoken(1))
    #expect(marks(events).count == 1, "line 0 started with its first word")
    clock.now += 1
    events = h.perform(.spoken(3))
    #expect(marks(events).isEmpty)
    clock.now += 0.3
    events = h.perform(.spoken(4))
    #expect(marks(events).count == 1, "line 1 started at word four")
}

// MARK: Continuing a turn

@Test func continuingATurnDropsWhatWasNeverDrawnAndReplaysTheSame() throws {
    let clock = VirtualClock()
    let h = try host(clock)
    begin(h, pace: .speech)
    let program = "step(1)\nsay(\"One.\")\nbox(10, 10, 100, 50)\nstep(2)\nsay(\"Two.\")\ncircle(400, 400, 40)\n"
    var events = feed(h, program)
    events += h.perform(.lineStarted(0, 1))
    clock.now += 1.5
    events += h.perform(.drain)
    // The user cut in before line 1: keep the card.
    let kept = try #require(h.continueTurn())
    let code = try #require(kept["code"]?.stringValue)
    #expect(code.contains("__turn(2, "))
    #expect(kept["dropped"]?.intValue == 1)
    // A follow-up turn edits the kept card.
    events += h.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now, keep: true)))
    events += feed(h, "recolor(\"p1\", \"red\")\n")
    #expect(marks(events).contains { $0.kind == "box" && $0.json["edit"]?.stringValue == "restyle" })
    #expect(!marks(events).contains { $0.kind == "circle" })

    // Replaying the kept code whole draws the same card: the box, and not the circle that was never drawn.
    let replay = try host()
    begin(replay)
    let again = marks(feed(replay, code + "\n"))
    let removed = Set(feed(replay, "").flatMap { event -> [String] in if case .remove(let ids) = event { ids } else { [] } })
    let shown = again.filter { !removed.contains($0.id) }
    #expect(shown.contains { $0.kind == "box" })
}

// MARK: Sounds

@Test func marksCarrySoundRecipes() throws {
    let h = try host()
    begin(h)
    let events = feed(h, """
    line(10, 10, 300, 10)
    const card = paper(400, 100, 400, 300, {title: "Card"})
    line(card.x, card.y + 20, card.x + 200, card.y + 20)
    text(10, 400, "Words")
    pill(10, 500, "Name")
    erase("p1")
    """)
    let sounds = events.compactMap { if case .sound(let r) = $0 { r } else { nil } }
    let textures = sounds.compactMap(\.texture)
    #expect(textures.contains("felt"))
    #expect(textures.contains("pencil"))
    #expect(textures.contains("writing"))
    #expect(textures.contains("eraser"))
    #expect(sounds.contains { $0.accents.contains { $0.id == "gel-pop" } })
    #expect(sounds.contains { $0.accents.contains { $0.id == "paper" } })
    // Synthesized, deterministic and not silent.
    let felt = try #require(sounds.first { $0.texture == "felt" })
    let a = DrawingSounds.samples(for: felt, sampleRate: 24_000), b = DrawingSounds.samples(for: felt, sampleRate: 24_000)
    #expect(a == b)
    #expect((a.map { abs($0) }.max() ?? 0) > 0.02)
    for id in DrawingSounds.accents { #expect(!DrawingSounds.accent(id, sampleRate: 24_000).isEmpty, "\(id) is silent") }
    let track = DrawingSounds.mix(sounds, from: sounds.map(\.at).min() ?? 0, duration: 4, sampleRate: 24_000)
    #expect(track.count == 96_000 && (track.map { abs($0) }.max() ?? 2) < 1)
}

// MARK: The sound player

/// A sound player on fake outputs: (player, its texture output, its accent output).
@MainActor
private func soundPlayer() -> (DrawingSoundPlayer, textures: FakeSpeechPlaybackBackend, accents: FakeSpeechPlaybackBackend) {
    let textures = FakeSpeechPlaybackBackend(), accents = FakeSpeechPlaybackBackend()
    let player = DrawingSoundPlayer(player: SpeechPlayer(backend: textures, pollInterval: nil, idleTimeout: 3600),
                                    accentPlayer: SpeechPlayer(backend: accents, pollInterval: nil, idleTimeout: 3600), volume: 1)
    return (player, textures, accents)
}

private func accentFrames(_ ids: String...) -> Int { ids.reduce(0) { $0 + DrawingSounds.accent($1, sampleRate: 24_000).count } }

/// Review fix: an accent due while a long texture plays sounds beside it, not queued until the texture ends.
@MainActor
@Test func anAccentDueDuringATexturePlaysBesideIt() async throws {
    let (sounds, textures, accents) = soundPlayer()
    sounds.schedule(DrawingSoundRecipe(at: 10, duration: 2, texture: "writing", accents: [], mark: "words"), now: 10)
    sounds.schedule(DrawingSoundRecipe(at: 10.5, duration: 0.3, texture: nil, accents: [.init(id: "gel-pop", at: 0)], mark: "pill"),
                    now: 10.5)
    #expect(await waitUntil { textures.scheduledFrames > 0 && accents.scheduledFrames > 0 })
    #expect(textures.scheduledFrames == 48_000, "the texture's output plays only the texture")
    #expect(accents.scheduledFrames == accentFrames("gel-pop"))
}

/// Review fix: accents are thinned by how far apart they are, not by the order their recipes arrive in.
@MainActor
@Test func accentThinningKeepsAnEarlierAccentThatArrivesLate() async throws {
    let (sounds, _, accents) = soundPlayer()
    // Line 0's last mark (laid out to a guessed length), then line 1's first, which the voice reached sooner.
    sounds.schedule(DrawingSoundRecipe(at: 2.3, duration: 0.3, texture: nil, accents: [.init(id: "button-appear", at: 0)], mark: "a"), now: 3)
    sounds.schedule(DrawingSoundRecipe(at: 2.08, duration: 0.3, texture: nil, accents: [.init(id: "gel-pop", at: 0)], mark: "b"), now: 3)
    // Within 50 ms of one already scheduled: thinned.
    sounds.schedule(DrawingSoundRecipe(at: 2.32, duration: 0.3, texture: nil, accents: [.init(id: "tap", at: 0)], mark: "c"), now: 3)
    let expected = accentFrames("button-appear", "gel-pop")
    #expect(await waitUntil { accents.scheduledFrames >= expected })
    #expect(accents.scheduledFrames == expected)
}

/// Review fix: stopAll() silences every sound still waiting, however many were scheduled.
@MainActor
@Test func stopAllSilencesMoreThanSixtyFourWaitingSounds() async throws {
    let (sounds, textures, accents) = soundPlayer()
    for i in 0..<100 {
        sounds.schedule(DrawingSoundRecipe(at: 0.2 + Double(i) * 0.051, duration: 0.3, texture: nil,
                                           accents: [.init(id: "tap", at: 0)], mark: "m\(i)"), now: 0)
    }
    sounds.stopAll()
    try await Task.sleep(for: .milliseconds(600))
    #expect(accents.scheduledFrames == 0 && textures.scheduledFrames == 0)
    // Sounds scheduled after the stop still play.
    sounds.schedule(DrawingSoundRecipe(at: 5, duration: 0.3, texture: nil, accents: [.init(id: "ding", at: 0)], mark: "next"), now: 5)
    #expect(await waitUntil { accents.scheduledFrames == accentFrames("ding") })
}

// MARK: Beats

@Test func beatsTellWhichStatementsOfTheLineAreDrawn() throws {
    let clock = VirtualClock()
    let h = try host(clock)
    begin(h, pace: .speech)
    _ = feed(h, "step(1)\nsay(\"Look at these two.\")\nbox(10, 10, 100, 60, {label: \"First\"})\ncircle(400, 300, 50)\n")
    #expect(h.beats() == nil)
    _ = h.perform(.lineStarted(0, 3))
    clock.now += 0.2
    _ = h.perform(.drain)
    let early = try #require(h.beats())
    #expect(early.line == 0 && early.text == "Look at these two.")
    #expect(early.chips.map(\.label) == ["box \"First\"", "circle"])
    #expect(early.chips.contains { $0.state != .done })
    clock.now += 4
    _ = h.perform(.drain)
    let late = try #require(h.beats())
    #expect(late.chips.allSatisfy { $0.state == .done })
    #expect(late.header.hasPrefix("beat 1 of 1"))
}

// MARK: The action performer

@MainActor
@Test func theActionPerformerTypesCopiesOpensAndHandsOff() async throws {
    var copied: [String] = [], opened: [URL] = [], typed: [String] = [], handed: [String] = [], played: [String] = []
    let performer = DrawingActionPerformer(
        copy: { copied.append($0); return true },
        open: { opened.append($0); return true },
        type: { typed.append($0); return false },
        playSound: { played.append($0) },
        handOff: { task, _ in handed.append(task); return true })
    // Typing never presses Return, and falls back to the clipboard when nothing took the words.
    let typing = await performer.perform(DrawingAction(role: .type, text: "line one\nline two"))
    #expect(typed == ["line one line two"] && copied == ["line one line two"] && typing.result == "copied instead")
    let page = URL(string: "https://example.com")!
    #expect(await performer.perform(DrawingAction(role: .open, url: page)).succeeded)
    #expect(!(await performer.perform(DrawingAction(role: .open, url: page)).succeeded), "one page per spoken answer")
    #expect(await performer.perform(DrawingAction(role: .open, url: page, fromClick: true)).succeeded, "a click may always open")
    performer.newAnswer()
    #expect(await performer.perform(DrawingAction(role: .open, url: page)).succeeded)
    #expect(!(await performer.perform(DrawingAction(role: .open, url: URL(string: "ftp://example.com")!, fromClick: true)).succeeded))
    #expect(await performer.perform(DrawingAction(role: .handoff, text: "Do the thing")).succeeded)
    #expect(await performer.perform(DrawingAction(role: .sfx, text: "ding")).succeeded)
    #expect(!(await performer.perform(DrawingAction(role: .sfx, text: "airhorn")).succeeded))
    #expect(opened.count == 3 && handed == ["Do the thing"] && played == ["ding"])
}

/// Review fix: two actions due together (typeText then copyText under one line) run one after the other, so the
/// second can't write the clipboard while the first is still pasting from it.
@MainActor
@Test func actionsDueTogetherRunOneAtATimeInOrder() async throws {
    var log: [String] = []
    let performer = DrawingActionPerformer(
        copy: { log.append("copy \($0)"); return true },
        open: { _ in true },
        type: { words in
            log.append("type \(words) start")
            // Typing suspends while it pastes and waits to put the clipboard back.
            try? await Task.sleep(for: .milliseconds(50))
            log.append("type \(words) end")
            return true
        })
    let first = Task { await performer.perform(DrawingAction(role: .type, text: "Hello")) }
    let second = Task { await performer.perform(DrawingAction(role: .type, text: "world")) }
    let third = Task { await performer.perform(DrawingAction(role: .copy, text: "kept")) }
    #expect(await first.value.result == "typed")
    #expect(await second.value.result == "typed")
    #expect(await third.value.result == "copied")
    #expect(log == ["type Hello start", "type Hello end", "type world start", "type world end", "copy kept"])
    #expect(performer.history.map { $0.action.text } == ["Hello", "world", "kept"])
}

// MARK: The painter

@MainActor
@Test func spotlightsStickyNotesAndLinksArePainted() throws {
    let clock = VirtualClock(CACurrentMediaTime() + 100_000)
    let h = try host(clock)
    begin(h)
    let events = feed(h, """
    spotlight(400, 300, 200, 100)
    sticky(900, 80, "Remember", "butter")
    text(100, 600, "Read [this](https://example.com)", {size: 24})
    """)
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832), clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    painter.apply(events)
    let image = try DrawingSnapshot.render(painter.layer, size: CGSize(width: 1280, height: 832), at: clock.now + 10,
                                           background: CGColor(gray: 1, alpha: 1))
    let inside = DrawingSnapshot.pixel(image, x: 500, y: 350), outside = DrawingSnapshot.pixel(image, x: 100, y: 100)
    #expect(inside.r > 240, "the spotlight's hole stays clear: \(inside)")
    #expect(outside.r < 160, "the rest of the screen is dimmed: \(outside)")
    let link = try #require(marks(events).first { $0.kind == "text" })
    let box = CGRect(x: link.json["at"]?.arrayValue?[0].doubleValue ?? 0, y: link.json["at"]?.arrayValue?[1].doubleValue ?? 0,
                     width: link.json["w"]?.doubleValue ?? 0, height: link.json["h"]?.doubleValue ?? 0)
    clock.now += 10
    #expect(painter.clickableID(at: CGPoint(x: box.midX, y: box.midY)) == link.id)
    #expect(painter.layer(forMark: link.id)?.sublayers?.first?.sublayers?.contains { $0.name == "link" } == true)
}

// MARK: The look: fonts, felt pen, washes, highlighter

@Test func theBundledHandAndSansFontsLoad() throws {
    #expect(DrawingFonts.bundled(.patrickHand) != nil)
    #expect(DrawingFonts.bundled(.barlowSemiBold) != nil)
    let hand = DrawingFonts.font(.hand, size: 20), sans = DrawingFonts.font(.sans, size: 20)
    #expect((CTFontCopyPostScriptName(hand) as String).hasPrefix("PatrickHand"))
    #expect((CTFontCopyPostScriptName(sans) as String).hasPrefix("Barlow"))
    #expect(DrawingFonts.syntheticBoldWidth(.title, size: 24) > 0 && DrawingFonts.syntheticBoldWidth(.hand, size: 24) == 0)
    #expect(DrawingFonts.width(of: "Hello", size: 24, style: .hand) > 10)
}

@MainActor
@Test func paperStrokesTaperAndFillsWashWhileScreenInkStaysEven() throws {
    let clock = VirtualClock(CACurrentMediaTime() + 100_000)
    let h = try host(clock)
    begin(h)
    let events = feed(h, """
    const card = paper(60, 60, 600, 400, {title: "Card"})
    line(card.x, card.y + 20, card.x + 300, card.y + 60)
    box(card.x, card.y + 120, 140, 80, {fill: "sky"})
    line(800, 100, 1100, 160)
    box(700, 300, 500, 400, {fill: "mint"})
    """)
    let all = marks(events)
    let paperLine = try #require(all.first { $0.kind == "line" && $0.json["on"] != nil })
    let screenLine = try #require(all.first { $0.kind == "line" && $0.json["on"] == nil })
    #expect(paperLine.json["taper"]?.doubleValue == 1)
    #expect(screenLine.json["taper"] == nil)
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832), clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    painter.apply(events)
    let felt = try #require(painter.layer(forMark: paperLine.id)?.sublayers?.first as? CAShapeLayer)
    #expect(felt.mask != nil && felt.fillColor != nil && felt.strokeColor == nil, "a felt-tip stroke is a filled outline revealed by a mask")
    let even = try #require(painter.layer(forMark: screenLine.id)?.sublayers?.first as? CAShapeLayer)
    #expect(even.mask == nil && even.strokeColor != nil)
    let boxes = all.filter { $0.kind == "box" }
    let smallFill = try #require(painter.layer(forMark: boxes[0].id)?.sublayers?.first { $0.name == "fill" })
    #expect(smallFill.contents != nil, "a small fill is a watercolour wash")
    let bigFill = try #require(painter.layer(forMark: boxes[1].id)?.sublayers?.first { $0.name == "fill" })
    #expect(bigFill is CAShapeLayer && bigFill.contents == nil, "a large fill stays crisp")
}

@MainActor
@Test func highlightsMultiplyOnLightScreensSoTheWordsStayDark() throws {
    // A light page with a black word, as the screenshot under the overlay.
    let backdrop = try #require(DrawingRehearsal.paint(size: CGSize(width: 400, height: 200)) { context, rect in
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(rect)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // A word in the top half of where the band goes (drawing coordinates are bottom-up: y 105…115 is 85…95 down).
        context.fill(CGRect(x: 100, y: 105, width: 120, height: 10))
    })
    var options = DrawingRehearsal.Options()
    options.width = 400
    options.height = 200
    options.backdrop = .image(backdrop)
    let result = try DrawingRehearsal.run(program: "highlight(80, 80, 200, 40)\n", options: options)
    let band = try #require(marks(result.events).first { $0.kind == "highlight" })
    #expect(band.json["blend"]?.stringValue == "multiply")
    let onWord = DrawingSnapshot.pixel(result.image, x: 150, y: 90), onPage = DrawingSnapshot.pixel(result.image, x: 150, y: 110)
    #expect(onWord.r < 40 && onWord.g < 40, "the word under the band stays dark: \(onWord)")
    #expect(onPage.b < onPage.r - 40 && onPage.r > 200, "the page under the band turns yellow: \(onPage)")
    // On a dark screen a multiplied band would vanish: it is a plain translucent band there.
    let darkBackdrop = try #require(DrawingRehearsal.paint(size: CGSize(width: 400, height: 200)) { context, rect in
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(rect)
    })
    options.backdrop = .image(darkBackdrop)
    let onDark = try DrawingRehearsal.run(program: "highlight(80, 80, 200, 40)\n", options: options)
    #expect(marks(onDark.events).first { $0.kind == "highlight" }?.json["blend"] == nil)
}
