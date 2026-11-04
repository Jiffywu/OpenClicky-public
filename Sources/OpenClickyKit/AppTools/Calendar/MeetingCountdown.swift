import Foundation

/// Finds video-call links in an event's URL, location and notes.
public enum MeetingLinkDetector {
    /// Hosts of common meeting services. A link matches the host or any subdomain of it.
    public static let meetingHosts: [String] = [
        "zoom.us", "zoomgov.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
        "whereby.com", "gotomeeting.com", "meet.goto.com", "app.chime.aws", "bluejeans.com", "meet.jit.si",
        "facetime.apple.com", "around.co", "meet.around.co", "hangouts.google.com",
    ]

    public static func isMeetingLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The first meeting link in the event: its URL field first, then the location, then the notes.
    public static func meetingURL(in event: CalendarEventRecord) -> URL? {
        if let url = event.url, isMeetingLink(url) { return url }
        for text in [event.location, event.notes].compactMap({ $0 }) {
            if let url = links(in: text).first(where: isMeetingLink) { return url }
        }
        return nil
    }

    /// Every http(s) link in free text, in order.
    public static func links(in text: String) -> [URL] {
        let pattern = /https?:\/\/[^\s<>"'()\[\]{}]+/
        return text.matches(of: pattern.ignoresCase()).compactMap { match in
            var candidate = String(match.output)
            while let last = candidate.last, ".,;:!?".contains(last) { candidate.removeLast() }
            return URL(string: candidate)
        }
    }
}

/// What the countdown's main button does.
public enum MeetingAction: Sendable, Hashable {
    /// Open the video call.
    case join(URL)
    /// Directions to a physical place, in Maps.
    case directions(URL)
    /// Open the event's own link.
    case open(URL)

    public var kind: String {
        switch self {
        case .join: "join"
        case .directions: "directions"
        case .open: "open"
        }
    }

    public var url: URL {
        switch self {
        case .join(let url), .directions(let url), .open(let url): url
        }
    }
}

/// The next meeting for the notch countdown.
public struct UpcomingMeeting: Sendable, Hashable {
    public var event: CalendarEventRecord
    /// Seconds until the start; negative once it has begun.
    public var secondsUntilStart: TimeInterval
    public var action: MeetingAction?

    public var hasStarted: Bool { secondsUntilStart <= 0 }
    /// Whole minutes until the start, rounded up ("in 3 minutes" until it is under 2); 0 once it has begun.
    public var minutesUntilStart: Int { secondsUntilStart <= 0 ? 0 : Int((secondsUntilStart / 60).rounded(.up)) }
}

/// What the countdown should show.
public enum MeetingCountdownState: Sendable, Hashable {
    /// Calendar access is not granted; the countdown stays hidden (it never asks for permission itself).
    case noAccess(CalendarAuthorization)
    case nothingSoon
    case upcoming(UpcomingMeeting)
}

public enum MeetingCountdown {
    /// The meeting to count down to: the earliest timed event starting within `withinMinutes` from `now`, or one
    /// that started less than `inProgressGrace` ago (so "Join" stays up for latecomers). All-day, cancelled and
    /// declined events are skipped. When two start together, the one with a call link wins.
    public static func next(in events: [CalendarEventRecord], now: Date, withinMinutes: Int,
                            inProgressGrace: TimeInterval = 5 * 60) -> UpcomingMeeting? {
        let horizon = now.addingTimeInterval(TimeInterval(withinMinutes) * 60)
        let candidates = events.filter { event in
            !event.isAllDay && !event.isCancelled && !event.declinedByMe && event.end > now
                && event.start <= horizon && event.start > now.addingTimeInterval(-inProgressGrace)
        }
        let best = candidates.min { a, b in
            if a.start != b.start { return a.start < b.start }
            let aLink = MeetingLinkDetector.meetingURL(in: a) != nil
            let bLink = MeetingLinkDetector.meetingURL(in: b) != nil
            if aLink != bLink { return aLink }
            return a.title < b.title
        }
        return best.map { UpcomingMeeting(event: $0, secondsUntilStart: $0.start.timeIntervalSince(now), action: primaryAction(for: $0)) }
    }

    /// Join a call when there is a link, else directions to a real place, else the event's own web link.
    public static func primaryAction(for event: CalendarEventRecord) -> MeetingAction? {
        if let link = MeetingLinkDetector.meetingURL(in: event) { return .join(link) }
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), isPlace(location),
           let directions = directionsURL(to: location) {
            return .directions(directions)
        }
        if let url = event.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" { return .open(url) }
        return nil
    }

    /// A location that names somewhere to go, not a link or a call ("Zoom", "Teams Meeting").
    static func isPlace(_ location: String) -> Bool {
        guard !location.isEmpty, MeetingLinkDetector.links(in: location).isEmpty else { return false }
        let lower = location.lowercased()
        let virtual = ["zoom", "google meet", "microsoft teams", "teams meeting", "webex", "facetime", "online", "virtual", "phone call"]
        return !virtual.contains { lower.contains($0) }
    }

    /// Apple Maps directions to a free-text place.
    public static func directionsURL(to place: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let encoded = place.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://maps.apple.com/?daddr=\(encoded)")
    }
}
