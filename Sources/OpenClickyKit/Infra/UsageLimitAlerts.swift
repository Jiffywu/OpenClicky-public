import Foundation

// Spending that crosses a limit is said once, where the user will see it: a macOS notification and a notch event
// (docs/infra.md). Before this, a warning showed only in the menu and on Settings → Usage.

/// One alert about a spending limit.
public struct UsageLimitAlert: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// Spending reached the warning share of a limit.
        case warned
        /// Spending reached a limit that stops paid calls.
        case stopped
        /// Spending went past a limit that only warns.
        case passed
    }

    /// One per period, level and day or month ("usage:day:2026-11-03:warned"), so it is said once.
    public var id: String
    public var kind: Kind
    public var status: UsageLimitStatus

    public init(id: String, kind: Kind, status: UsageLimitStatus) {
        self.id = id
        self.kind = kind
        self.status = status
    }

    public var title: String {
        let when = status.period == .month ? "this month" : "today"
        switch kind {
        case .warned: return "Nearing your spending limit \(when)"
        case .stopped: return "Spending limit reached \(when)"
        case .passed: return "Past your spending limit \(when)"
        }
    }

    /// The status's own sentence.
    public var body: String { status.message ?? title }
}

/// Decides when a status is worth an alert: the first time each level is reached in a day or month. Seed it with the
/// status at launch so a limit crossed before OpenClicky started isn't announced again.
public struct UsageLimitAlerter: Sendable {
    private var announced: Set<String> = []
    private let calendar: Calendar

    public init(calendar: Calendar = .current) { self.calendar = calendar }

    /// Marks the current status as already known (nothing is alerted for it).
    public mutating func seed(_ status: UsageLimitStatus, now: Date) {
        if let alert = alert(for: status, now: now) { announced.insert(alert.id) }
        // A limit already reached also covers its warning.
        if status.level == .reached, let warning = alert(for: UsageLimitStatus(level: .warning, period: status.period, spentUSD: status.spentUSD,
                                                                                limitUSD: status.limitUSD, stops: status.stops), now: now) {
            announced.insert(warning.id)
        }
    }

    /// The alert to show for `status`, or nil when there is nothing new to say.
    public mutating func observe(_ status: UsageLimitStatus, now: Date) -> UsageLimitAlert? {
        guard let alert = alert(for: status, now: now), !announced.contains(alert.id) else { return nil }
        announced.insert(alert.id)
        // Once the limit is reached, the warning for the same period has nothing left to add.
        if alert.kind != .warned { announced.insert(alert.id.replacingOccurrences(of: ":\(alert.kind.rawValue)", with: ":warned")) }
        return alert
    }

    private func alert(for status: UsageLimitStatus, now: Date) -> UsageLimitAlert? {
        guard let period = status.period, status.limitUSD != nil else { return nil }
        let kind: UsageLimitAlert.Kind
        switch status.level {
        case .ok: return nil
        case .warning: kind = .warned
        case .reached: kind = status.stops ? .stopped : .passed
        }
        let key = period == .day ? UsageFormat.day(now, calendar: calendar) : UsageFormat.month(now, calendar: calendar)
        return UsageLimitAlert(id: "usage:\(period.rawValue):\(key):\(kind.rawValue)", kind: kind, status: status)
    }
}
