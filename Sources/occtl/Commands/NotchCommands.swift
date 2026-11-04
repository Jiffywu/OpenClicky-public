import AppKit
import Foundation
import OpenClickyKit

/// `occtl notch`: the interactive notch without the app. `simulate` plays a scripted session through the real presenter
/// and event sources; `system-ui` reads the live window list and says whether the notch would step aside or hide for
/// a full-screen app right now; `meeting` asks the calendar for the countdown (never prompting for access); `sound`
/// reads whether the default output is muted.
enum NotchCommands {
    static let usage = """
        Usage:
          occtl notch simulate <script.json> [--out log.txt]
              Plays a scripted session (docs/examples/notch-script.json): pointer, clicks, keys, calendar, jobs, dictation,
              a denied document, a muted reply and window lists on a virtual clock. Prints every surface and effect.
          occtl notch system-ui [--watch SECONDS] [--json]
              Reads the on-screen window list (no permission needed) and prints the system UI the notch would step aside
              for, the displays with a full-screen app, and each display's notch geometry.
          occtl notch meeting [--lead MINUTES]
              The next meeting the countdown would show, with its buttons. Never asks for Calendar access.
          occtl notch sound
              Whether the default output is muted or at zero volume (read only).
        """

    static let command = OcctlCommand(name: "notch", usage: "notch simulate|system-ui|meeting|sound   the interactive notch, headless") { args in
        switch args.first {
        case "simulate": try await simulate(Array(args.dropFirst()))
        case "system-ui": try await systemUI(Array(args.dropFirst()))
        case "meeting": try await meeting(Array(args.dropFirst()))
        case "sound": sound()
        default: fail(usage)
        }
    }

    static func simulate(_ args: [String]) async throws {
        guard let path = args.first else { fail(usage) }
        var out: URL?
        var iterator = args.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--out":
                guard let value = iterator.next() else { fail(usage) }
                out = URL(fileURLWithPath: value)
            default: fail(usage)
            }
        }
        let script = try JSONDecoder().decode(NotchScript.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let result = await NotchSimulator.run(script)
        var lines = result.log
        lines.append("")
        lines.append("surfaces: " + result.surfaces.map(\.surface.name).joined(separator: " → "))
        lines.append("folder notice shown \(result.folderNoticeShowCount) time(s)\(result.folderNoticeSuppressed ? ", then turned off" : "")")
        if let clipboard = result.clipboard { lines.append("clipboard: \(clipboard)") }
        let text = lines.joined(separator: "\n")
        print(text)
        if let out { try (text + "\n").write(to: out, atomically: true, encoding: .utf8) }
    }

    static func systemUI(_ args: [String]) async throws {
        var watch: Double?
        var json = false
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--watch":
                guard let value = iterator.next(), let seconds = Double(value), seconds > 0 else { fail("--watch wants seconds") }
                watch = seconds
            case "--json": json = true
            default: fail(usage)
            }
        }
        let deadline = Date().addingTimeInterval(watch ?? 0)
        var coordinator = NotchYieldCoordinator()
        var last = ""
        repeat {
            let report = await MainActor.run { () -> Report in
                let layout = DesktopLayout.current()
                let windows = SystemWindowList.snapshot()
                let displays = SystemWindowList.displayBounds(layout)
                let detected = SystemUIDetector().reasons(in: windows, displays: displays.map(\.bounds))
                let front = NSWorkspace.shared.frontmostApplication
                let insets = displays.map { display in
                    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id }?
                        .safeAreaInsets.top ?? 0
                }
                let fullscreen = FullscreenDetector.fullscreenDisplays(windows: windows, displays: displays.map(\.bounds),
                                                                       frontPID: front?.processIdentifier, housingInsets: insets)
                let screens = NSScreen.screens.map { screen -> String in
                    let geometry = NotchGeometry(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                                 auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea)
                    let notch = geometry.notchRect.map { "notch \(Int($0.width))×\(String(format: "%.1f", $0.height)) pt at x \(Int($0.minX))" }
                        ?? "no notch (top-edge sliver)"
                    return "\(Int(screen.frame.width))×\(Int(screen.frame.height)) at (\(Int(screen.frame.minX)), \(Int(screen.frame.minY))): \(notch); "
                        + "panel \(Int(geometry.panelFrame.minX)),\(Int(geometry.panelFrame.minY)) \(Int(geometry.panelFrame.width))×\(Int(geometry.panelFrame.height))"
                }
                return Report(windowCount: windows.count, front: front?.bundleIdentifier, detected: detected,
                              fullscreen: fullscreen.sorted().map { displays[$0].id }, screens: screens,
                              owners: Array(Set(windows.map(\.ownerName))).sorted())
            }
            let active = coordinator.update(report.detected, now: Date())
            let line: String
            if json {
                let object: [String: Any] = [
                    "time": ISO8601DateFormatter().string(from: Date()), "windows": report.windowCount, "front": report.front ?? NSNull(),
                    "systemUI": report.detected.sorted().map(\.rawValue), "obeyed": active.sorted().map(\.rawValue),
                    "fullscreenDisplays": report.fullscreen, "owners": report.owners,
                ]
                line = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            } else {
                var parts = ["\(report.windowCount) on-screen windows", "front app \(report.front ?? "unknown")"]
                parts.append("system UI: " + (report.detected.isEmpty ? "none" : report.detected.sorted().map(\.rawValue).joined(separator: ", ")))
                parts.append("notch would " + (active.isEmpty && report.fullscreen.isEmpty ? "show" : "step aside"))
                parts.append("overlays would " + (active.contains(where: \.hidesOverlays) ? "hide" : "stay"))
                parts.append("full screen on displays: " + (report.fullscreen.isEmpty ? "none" : report.fullscreen.map(String.init).joined(separator: ", ")))
                line = parts.joined(separator: " · ")
            }
            if line != last || watch == nil {
                if last.isEmpty, !json { report.screens.forEach { print("display \($0)") } }
                print(line)
                last = line
            }
            if watch != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
        } while Date() < deadline
    }

    private struct Report: Sendable {
        var windowCount: Int
        var front: String?
        var detected: Set<NotchYieldReason>
        var fullscreen: [UInt32]
        var screens: [String]
        var owners: [String]
    }

    static func meeting(_ args: [String]) async throws {
        var lead = NotchSettings.load().meetingLeadMinutes
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--lead":
                guard let value = iterator.next(), let minutes = Int(value), minutes > 0 else { fail("--lead wants minutes") }
                lead = minutes
            default: fail(usage)
            }
        }
        let service = CalendarService(store: EventKitCalendarStore(canAskForAccess: false))
        let state = await service.upcomingMeeting(withinMinutes: lead)
        switch state {
        case .noAccess(let authorization):
            print("calendar access: \(authorization.rawValue); the countdown stays hidden (it never asks)")
        case .nothingSoon:
            print("no meeting in the next \(lead) min")
        case .upcoming:
            guard let event = MeetingCountdownPolicy(leadMinutes: lead).event(for: state, dismissed: [], now: Date()) else {
                print("no countdown")
                return
            }
            print("\(event.title) · \(event.subtitle(now: Date()) ?? "")")
            for action in event.actions { print("  [\(action.isPrimary ? "*" : " ")] \(action.title)\(Self.target(action))") }
        }
    }

    static func sound() {
        let state = OutputSoundProbe.defaultOutput()
        let muted = state.isMuted.map { $0 ? "muted" : "not muted" } ?? "no mute control"
        let volume = state.volume.map { String(format: "volume %.2f", $0) } ?? "no volume control"
        print("\(state.deviceName ?? "no default output"): \(muted), \(volume) → a spoken reply would \(state.isSilent ? "be copied to the clipboard" : "be heard")")
    }

    /// `occtl turn` writes this next to its other reports: the live output state and what the notch would copy.
    static func mutedReplyReport(_ record: TurnRecord, speaksTypedAnswers: Bool) -> String {
        let sound = OutputSoundProbe.defaultOutput()
        let lines = record.history?.spokenLines ?? []
        var report = ["output: \(sound.deviceName ?? "none"), muted \(sound.isMuted.map { $0 ? "yes" : "no" } ?? "n/a"), "
            + "volume \(sound.volume.map { String(format: "%.2f", $0) } ?? "n/a")"]
        if let text = MutedReplyPolicy.textToCopy(kind: record.kind, spokenLines: lines, speaksTypedAnswers: speaksTypedAnswers, output: sound,
                                                  outcome: record.outcome) {
            let event = MutedReplyPolicy.event(copied: text, lineCount: lines.count, now: Date())
            report.append("notch: \(event.title) · \(event.subtitle(now: Date()) ?? "")")
            report.append("would copy (\(lines.count) line(s)): \(text)")
        } else {
            let why = !sound.isSilent ? "the reply was heard" : record.outcome != .completed ? "the answer didn't finish" : "nothing was meant to be heard"
            report.append("notch: nothing to copy (\(why))")
        }
        return report.joined(separator: "\n") + "\n"
    }

    private static func target(_ action: NotchAction) -> String {
        switch action.kind {
        case .openURL(let url): " → \(url.absoluteString)"
        case .openJob(let id): " → job \(id)"
        case .revealFile(let file): " → \(file)"
        case .suppress, .dismiss: ""
        case .stop(let target): " → stop \(target.rawValue)"
        case .openSettings(let page): " → Settings → \(page)"
        }
    }
}
