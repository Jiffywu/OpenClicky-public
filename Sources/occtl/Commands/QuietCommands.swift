import Foundation
import OpenClickyKit

/// `occtl quiet …`: quiet contexts (calls and Focus) from a terminal (docs/audio-robustness.md). `status` and `watch`
/// read this Mac (no permission prompts; the Focus database needs Full Disk Access and says so); `simulate` drives the
/// same QuietHold the app uses through a scripted call and Focus.
enum QuietCommands {
    static let usage = """
        Usage:
          occtl quiet status
              Is now a quiet moment? Who records from the mic, the Focus sources, and the verdict.
          occtl quiet watch [seconds]
              Print every change for a while (default 60 s). Start a call or turn on a Focus to see it.
          occtl quiet simulate
              A scripted timeline through QuietHold: a job report and a routine during a call, a meeting countdown, a
              Focus that outlasts the call, and what comes back when.
        """

    static let command = OcctlCommand(name: "quiet", usage: "quiet <status|watch|simulate>  calls, Focus and what waits for them (--help)") { args in
        guard let sub = args.first, !["--help", "-h"].contains(sub) else { print(usage); return }
        switch sub {
        case "status": await status()
        case "watch": try await watch(seconds: Double(args.dropFirst().first ?? "") ?? 60)
        case "simulate": try await simulate()
        default: fail(usage)
        }
    }

    @MainActor
    static func status() {
        let users = CoreAudioInputUsage().inputUsers()
        print("Recording from the mic now: " + (users.isEmpty ? "nobody" : users.map { user in
            [user.name, user.bundleID].compactMap { $0 }.joined(separator: " ") + (user.isRegularApp ? "" : " (helper)")
        }.joined(separator: ", ")))
        let monitor = QuietContextMonitor()
        let context = monitor.refresh()
        for note in monitor.notes { print("Focus source — \(note)") }
        print("Quiet: \(context.isQuiet ? "yes, " + context.summary : "no")")
    }

    @MainActor
    static func watch(seconds: Double) async throws {
        let monitor = QuietContextMonitor(interval: 1)
        let started = Date()
        func stamp() -> String { String(format: "%6.1fs  ", Date().timeIntervalSince(started)) }
        monitor.onChange = { print(stamp() + "quiet context: \($0.summary)") }
        monitor.start()
        print(stamp() + "watching for \(Int(seconds)) s; now: \(monitor.context.summary)")
        try await Task.sleep(for: .seconds(seconds))
        monitor.stop()
    }

    @MainActor
    static func simulate() async throws {
        let usage = FixedInputUsage()
        let focus = FixedFocusStatus()
        let clock = SimClock()
        let monitor = QuietContextMonitor(sources: .init(focus: focus, calls: CallPresenceDetector(usage: usage, ownBundleIDs: [], ownPIDs: [])),
                                          now: { clock.now })
        let hold = QuietHold(monitor: monitor, now: { clock.now })
        func say(_ text: String) { print(String(format: "t+%3.0f min  ", clock.minutes) + text) }
        hold.onLog = { say("  log: \($0)") }
        hold.onRelease = { items in for item in items { say("  → SHOW NOW: \(item.kind.rawValue) \"\(item.title)\"") } }
        hold.onDrop = { items in for item in items { say("  → dropped (stale): \(item.kind.rawValue) \"\(item.title)\"") } }
        hold.start()
        func offer(_ kind: ProactiveKind, _ title: String, expiresIn minutes: Double? = nil) {
            let item = ProactiveItem(id: title, kind: kind, title: title, payload: "[Jobs came back] \(title)", createdAt: clock.now,
                                     expiresAt: minutes.map { clock.now.addingTimeInterval($0 * 60) })
            let decision = hold.offer(item)
            say("offer \(kind.rawValue) \"\(title)\": \(decision)")
        }
        say("not quiet")
        offer(.jobReport, "Summarize the PDF")
        clock.advance(minutes: 2)
        say("Zoom starts recording from the mic (a call)")
        usage.set([AudioInputUser(pid: 4242, bundleID: "us.zoom.xos", name: "zoom.us")])
        hold.refresh()
        offer(.jobReport, "Draft the release notes")
        offer(.meetingCountdown, "Design review in 5 minutes", expiresIn: 10)
        clock.advance(minutes: 3)
        offer(.routineNotice, "Inbox digest (routine run #4)")
        say("Do Not Disturb turned on by hand during the call")
        focus.set(.manuallyEnabled(mode: "Do Not Disturb"))
        hold.refresh()
        if let summary = hold.gate.heldSummary { say("held: \(summary)") }
        clock.advance(minutes: 20)
        say("the call ends (Zoom stops recording); the Focus is still on")
        usage.set([])
        hold.refresh()
        offer(.meetingCountdown, "1:1 in 5 minutes", expiresIn: 10)
        offer(.onboardingPrompt, "Finish setting up OpenClicky")
        clock.advance(minutes: 15)
        say("Do Not Disturb turned off")
        focus.set(nil)
        hold.refresh()
        say("held now: \(hold.held.count)")
    }

    final class SimClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_793_600_000)
        private let start = Date(timeIntervalSince1970: 1_793_600_000)
        var now: Date { lock.withLock { date } }
        var minutes: Double { now.timeIntervalSince(start) / 60 }
        func advance(minutes: Double) { lock.withLock { date = date.addingTimeInterval(minutes * 60) } }
    }
}
