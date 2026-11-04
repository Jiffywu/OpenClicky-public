import Foundation
import Testing
import OpenClickyKit
@testable import OpenClicky

/// Home → Drawings' inline replay (`LessonReplayModel`): switching drawings and restarting a replay.
@Suite @MainActor struct LessonReplayModelTests {
    static func drawing(_ id: String, title: String) -> HistoryDrawing {
        let program = """
        step(1)
        say("Here is the \(title) panel.")
        box(200, 200, 600, 300, { tone: "#E5484D" })
        step(2)
        say("And its title, which takes a little while to say.")
        text(240, 260, "\(title)", {size: 40})
        """
        let turn = HistoryTurn(id: id, sessionID: "s-replay", startedAt: Date(timeIntervalSince1970: 1_793_437_200), source: .voice,
                               words: "What is the \(title) panel?",
                               spokenLines: ["Here is the \(title) panel.", "And its title, which takes a little while to say."],
                               program: program, canvas: HistoryCanvas(width: 640, height: 416))
        return HistoryDrawing(turn: turn)
    }

    static func wait(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func choosingAnotherDrawingDropsTheLastReplayFrame() async {
        let replay = LessonReplayModel()
        replay.play(Self.drawing("turn-a", title: "Settings"))
        #expect(await Self.wait { replay.frame != nil })
        replay.stop()
        // Stopping keeps the frame on screen for the same drawing.
        #expect(replay.frame != nil)
        // The detail's onChange(of: drawing.id): the next drawing shows its own thumbnail, not A's frame.
        replay.reset()
        #expect(replay.frame == nil && replay.problem == nil && replay.caption == nil && !replay.isPlaying)
    }

    @Test func restartingAReplayKeepsTheNewOnePlaying() async {
        let replay = LessonReplayModel()
        replay.play(Self.drawing("turn-a", title: "Settings"))
        #expect(await Self.wait { replay.frame != nil })
        // Replay B right away: A's task winds down after B has started and must not mark B as stopped.
        replay.play(Self.drawing("turn-b", title: "General"))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(replay.isPlaying)
        replay.stop()
        #expect(!replay.isPlaying)
    }
}
