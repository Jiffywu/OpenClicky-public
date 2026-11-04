import Foundation

/// How the notch behaves, saved at `~/Library/Application Support/OpenClicky/notch.json`. Missing keys take their
/// defaults.
public struct NotchSettings: Codable, Sendable, Hashable {
    /// The interactive notch panel. Off, OpenClicky goes back to the click-through pill in the overlay.
    public var interactive: Bool
    /// Resting the pointer on the notch opens it (a click always does).
    public var hoverOpens: Bool
    /// Count down to the next meeting (needs Calendar access; the notch never asks for it).
    public var meetingCountdown: Bool
    /// Show the countdown from this many minutes before a meeting.
    public var meetingLeadMinutes: Int
    /// Show background jobs starting, needing the user and finishing.
    public var jobEvents: Bool
    /// When the Mac's sound is off, put a spoken reply on the clipboard and say so.
    public var copiesReplyWhenMuted: Bool

    public init(interactive: Bool = true, hoverOpens: Bool = true, meetingCountdown: Bool = true, meetingLeadMinutes: Int = 5,
                jobEvents: Bool = true, copiesReplyWhenMuted: Bool = true) {
        self.interactive = interactive
        self.hoverOpens = hoverOpens
        self.meetingCountdown = meetingCountdown
        self.meetingLeadMinutes = meetingLeadMinutes
        self.jobEvents = jobEvents
        self.copiesReplyWhenMuted = copiesReplyWhenMuted
    }

    public static var defaultURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("notch.json")
    }

    private enum CodingKeys: String, CodingKey {
        case interactive, hoverOpens, meetingCountdown, meetingLeadMinutes, jobEvents, copiesReplyWhenMuted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotchSettings()
        interactive = try c.decodeIfPresent(Bool.self, forKey: .interactive) ?? d.interactive
        hoverOpens = try c.decodeIfPresent(Bool.self, forKey: .hoverOpens) ?? d.hoverOpens
        meetingCountdown = try c.decodeIfPresent(Bool.self, forKey: .meetingCountdown) ?? d.meetingCountdown
        meetingLeadMinutes = max(1, min(60, try c.decodeIfPresent(Int.self, forKey: .meetingLeadMinutes) ?? d.meetingLeadMinutes))
        jobEvents = try c.decodeIfPresent(Bool.self, forKey: .jobEvents) ?? d.jobEvents
        copiesReplyWhenMuted = try c.decodeIfPresent(Bool.self, forKey: .copiesReplyWhenMuted) ?? d.copiesReplyWhenMuted
    }

    public static func load(from url: URL = defaultURL) -> NotchSettings {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(NotchSettings.self, from: data) else {
            return NotchSettings()
        }
        return settings
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
