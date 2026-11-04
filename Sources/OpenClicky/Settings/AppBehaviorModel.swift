import AppKit
import OpenClickyKit
import os

/// Settings → General's behaviour: launch at login, Show in Dock, Show in screen recordings, where the app is
/// installed, and Reset local data. The app delegate calls `applyOnLaunch()` once at startup.
@MainActor
@Observable
final class AppBehaviorModel {
    private(set) var preferences: AppPreferences
    private(set) var loginStatus: LoginItemStatus
    let location: InstallLocation
    var message: String?
    /// What Reset would delete (shown in the confirmation), made when the user asks.
    private(set) var resetPlan: LocalDataResetPlan?

    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let loginItem: any LoginItemControlling
    @ObservationIgnored private let capturePolicy: OwnWindowCapturePolicy
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let log = Logger(subsystem: "app.openclicky", category: "behavior")
    /// False in fixtures: never changes the activation policy or touches the login item.
    @ObservationIgnored private let isLive: Bool

    init(url: URL?, loginItem: any LoginItemControlling, location: InstallLocation, capturePolicy: OwnWindowCapturePolicy,
         credentials: any CredentialStore, isLive: Bool) {
        self.url = url
        self.loginItem = loginItem
        self.location = location
        self.capturePolicy = capturePolicy
        self.credentials = credentials
        self.isLive = isLive
        preferences = url.map { AppPreferences.load(from: $0) } ?? AppPreferences()
        loginStatus = loginItem.status
        capturePolicy.showInScreenRecordings = preferences.showInScreenRecordings
    }

    /// Activation policy, the first-launch login item, and a note about the install location.
    func applyOnLaunch() {
        applyActivationPolicy()
        guard isLive else { return }
        let (updated, line) = LoginItemPolicy.applyOnLaunch(preferences: preferences, location: location, service: loginItem)
        log.info("\(line, privacy: .public)")
        if updated != preferences {
            preferences = updated
            save()
        }
        loginStatus = loginItem.status
        log.info("install location: \(self.location.kind.rawValue, privacy: .public) \(self.location.bundlePath, privacy: .public)")
    }

    /// The install-location warning for this copy, unless the user dismissed it.
    var installWarning: String? {
        guard preferences.dismissedInstallWarningPath != location.bundlePath else { return nil }
        return location.advice
    }

    /// A translocated or disk-image copy loses its permissions and login item on the next launch: say so once, at
    /// launch, with the way out. Other locations only get the note on Settings → General.
    func presentInstallAlertIfNeeded() {
        guard isLive, location.kind == .translocated || location.kind == .diskImage, let advice = installWarning else { return }
        let alert = NSAlert()
        alert.messageText = "Move OpenClicky to Applications"
        alert.informativeText = advice
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Don't Show Again")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { dismissInstallWarning() }
    }

    func dismissInstallWarning() {
        preferences.dismissedInstallWarningPath = location.bundlePath
        save()
    }

    // MARK: Launch at login

    var launchesAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    func setLaunchAtLogin(_ on: Bool) {
        guard isLive else { return }
        do {
            if on { try loginItem.register() } else { try loginItem.unregister() }
            message = nil
        } catch {
            message = "macOS didn't change the login item: \(error.localizedDescription)"
        }
        loginStatus = loginItem.status
        if loginStatus == .requiresApproval {
            message = "Switch OpenClicky on in System Settings → General → Login Items to finish."
        }
        log.info("login item set \(on ? "on" : "off", privacy: .public): \(self.loginStatus.rawValue, privacy: .public)")
    }

    func refreshLoginStatus() { loginStatus = loginItem.status }

    func openLoginItemsSettings() { MainAppLoginItem.openSystemSettings() }

    // MARK: Dock and recordings

    func setShowInDock(_ on: Bool) {
        preferences.showInDock = on
        save()
        applyActivationPolicy()
    }

    private func applyActivationPolicy() {
        guard isLive else { return }
        // Regular gives a Dock icon and an app menu; accessory keeps OpenClicky in the menu bar only and never steals
        // focus from the app the user is asking about.
        NSApp.setActivationPolicy(preferences.showInDock ? .regular : .accessory)
    }

    func setShowInScreenRecordings(_ on: Bool) {
        preferences.showInScreenRecordings = on
        capturePolicy.showInScreenRecordings = on
        save()
    }

    // MARK: Reset

    func prepareReset(keep: [URL]) {
        resetPlan = LocalDataReset.plan(credentials: (credentials as? any CredentialListing) ?? EmptyListing(), keep: keep)
    }

    /// Deletes everything in the plan. The caller quits the app afterwards.
    func performReset() -> LocalDataResetReport? {
        guard isLive, let plan = resetPlan else { return nil }
        let report = LocalDataReset.perform(plan, credentials: credentials)
        if let bundleID = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundleID) }
        _ = NativeHostInstaller.uninstall()
        log.info("reset local data: \(report.removedItems.count) items, \(report.removedCredentials.count) keys, \(report.failures.count) failures")
        resetPlan = nil
        return report
    }

    /// A fixture's reset confirmation (evidence renders).
    func showResetPlan(_ plan: LocalDataResetPlan) { resetPlan = plan }

    private func save() {
        guard let url else { return }
        // The permission request log is written by PermissionsCenter straight to the file; keep what is there.
        preferences.permissionRequests = AppPreferences.load(from: url).permissionRequests
        do { try preferences.save(to: url) } catch { message = "Couldn't save: \(error.localizedDescription)" }
    }

    private struct EmptyListing: CredentialListing {
        func storedNames() throws -> [String] { [] }
    }
}

/// A login item that only reports a status (fixtures and evidence renders).
struct FixedLoginItem: LoginItemControlling {
    var status: LoginItemStatus
    func register() throws {}
    func unregister() throws {}
}

/// Gives every OpenClicky window its capture role as it appears (`OwnWindowCapturePolicy.register` with the role from
/// `WindowCaptureRoles`), so the "Show in screen recordings" switch reaches the overlay, the HUDs and the panels, and
/// OpenClicky's own screenshots leave its chrome out.
@MainActor
final class WindowCaptureRegistrar {
    private let policy: OwnWindowCapturePolicy
    private var registered = Set<ObjectIdentifier>()
    private let log = Logger(subsystem: "app.openclicky", category: "capture-policy")
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init(policy: OwnWindowCapturePolicy) { self.policy = policy }

    func start() {
        sweep()
        let center = NotificationCenter.default
        // didUpdate comes once per pass of the event loop; a sweep is a set lookup per window, so it stays cheap and
        // catches windows that appear without becoming key (a Settings window opened by a link while another app is
        // in front).
        for name in [NSApplication.didUpdateNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sweep() }
            })
        }
        // Panels that never become key or change occlusion (an overlay made while hidden) are caught by a slow sweep.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        timer?.invalidate()
        timer = nil
    }

    /// Registers windows not seen before (and forgets closed ones).
    func sweep() {
        let windows = NSApp.windows
        guard windows.contains(where: { !registered.contains(ObjectIdentifier($0)) }) || registered.count > windows.count else { return }
        for window in windows where !registered.contains(ObjectIdentifier(window)) {
            let traits = WindowTraits(className: String(describing: type(of: window)), isTitled: window.styleMask.contains(.titled),
                                      ignoresMouseEvents: window.ignoresMouseEvents)
            // Seen once either way; system windows (the menu bar item, menus) are skipped for good.
            registered.insert(ObjectIdentifier(window))
            guard let role = WindowCaptureRoles.role(for: traits) else { continue }
            policy.register(window, role: role)
            log.info("window \(window.windowNumber) (\(traits.className, privacy: .public)) registered as \(String(describing: role), privacy: .public), sharing \(window.sharingType.rawValue)")
        }
        let alive = Set(windows.map(ObjectIdentifier.init))
        registered = registered.intersection(alive)
    }
}
