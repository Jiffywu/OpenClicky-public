import AppKit
import OpenClickyKit
import UserNotifications

/// What AgentNotifier needs from the notification center, so tests run without the app bundle (the real
/// `UNUserNotificationCenter` traps without one).
@MainActor
protocol AgentNotificationCentering: AnyObject {
    func requestAuthorization() async -> Bool
    func add(_ request: UNNotificationRequest) async throws
    /// Delivered notifications as (request id, thread id).
    func delivered() async -> [(id: String, thread: String)]
    func removeDelivered(_ ids: [String])
}

/// The system's notification center.
@MainActor
final class SystemAgentNotificationCenter: AgentNotificationCentering {
    let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) { self.center = center }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }

    func delivered() async -> [(id: String, thread: String)] {
        await center.deliveredNotifications().map { ($0.request.identifier, $0.request.content.threadIdentifier) }
    }

    func removeDelivered(_ ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }
}

/// Posts a macOS notification when a background job finishes or needs the user, and reports which job a clicked
/// notification belongs to. Notifications need the app bundle (UNUserNotificationCenter traps without one), so
/// under `swift run` this quietly does nothing.
@MainActor
final class AgentNotifier: NSObject {
    nonisolated static let jobIDKey = "openclicky.jobID"
    static let categoryNeedsYou = "openclicky.agent.needs-you"
    static let categoryFinished = "openclicky.agent.finished"

    /// A notification for this job was clicked.
    var onOpen: ((String) -> Void)?
    /// Post even while OpenClicky is frontmost (the HUD already shows it, so off by default).
    var showWhileActive = false
    /// During a call or a Focus notifications arrive without sound and don't interrupt.
    var isQuiet: () -> Bool = { false }

    private let center: (any AgentNotificationCentering)?
    private var authorized: Bool?

    override init() {
        let system = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        center = system.map { SystemAgentNotificationCenter(center: $0) }
        super.init()
        system?.delegate = self
    }

    /// A notifier on another center (tests); nil behaves like a build without the app bundle.
    init(center: (any AgentNotificationCentering)?) {
        self.center = center
        super.init()
    }

    var isAvailable: Bool { center != nil }

    /// Asks for permission once (the system shows its prompt the first time only).
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        if let authorized { return authorized }
        let granted = await center.requestAuthorization()
        authorized = granted
        return granted
    }

    func post(_ notice: AgentNotice) async {
        guard let center, await requestAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.threadIdentifier = notice.jobID
        content.categoryIdentifier = notice.needsAttention ? Self.categoryNeedsYou : Self.categoryFinished
        content.userInfo = [Self.jobIDKey: notice.jobID]
        let quiet = isQuiet()
        if notice.needsAttention && !quiet { content.sound = .default }
        if quiet { content.interruptionLevel = .passive }
        // One notification per run: a later run of the same job replaces nothing, a repeat of the same run does.
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
        try? await center.add(request)
    }

    /// A spending limit was crossed (once per period and level; see `UsageLimitAlerter`).
    func post(_ alert: UsageLimitAlert) async {
        guard let center, await requestAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.threadIdentifier = "openclicky.usage"
        if alert.kind == .stopped && !isQuiet() { content.sound = .default }
        if isQuiet() { content.interruptionLevel = .passive }
        try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }

    /// Clears the delivered notifications for a job (it was opened in the HUD).
    func clear(jobID: String) async {
        guard let center else { return }
        let ids = await center.delivered().filter { $0.thread == jobID }.map(\.id)
        if !ids.isEmpty { center.removeDelivered(ids) }
    }

    /// A clicked notification: tells `onOpen` which job it was for (nothing for notifications without one).
    func opened(userInfo: [AnyHashable: Any]) {
        guard let jobID = userInfo[Self.jobIDKey] as? String else { return }
        onOpen?(jobID)
    }
}

extension AgentNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let show = await MainActor.run { self.showWhileActive }
        return show ? [.banner, .list, .sound] : [.list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let jobID = response.notification.request.content.userInfo[Self.jobIDKey] as? String else { return }
        await MainActor.run { self.opened(userInfo: [Self.jobIDKey: jobID]) }
    }
}
