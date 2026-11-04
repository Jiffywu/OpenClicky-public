import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import IOKit.hid
import OpenClickyKit
import ScreenCaptureKit
import Speech

/// The macOS permissions OpenClicky needs, with their current state and a way to ask for each.
/// Mirrors the usage strings HeyClicky declares: microphone, screen recording, speech recognition, plus
/// Accessibility for the push-to-talk keys and for reading on-screen UI, and Input Monitoring for the talk keys when
/// the event tap only listens.
///
/// States come from `PermissionStateMapping`: a permission still off after OpenClicky asked for it shows as denied
/// (the request log lives in app-preferences.json), and a Screen Recording grant this process can't see yet shows as
/// restart-required with a Quit & Reopen button.
@MainActor
@Observable
final class PermissionsCenter {
    typealias Permission = PermissionKind
    typealias State = PermissionState

    private(set) var states: [Permission: State] = [:]
    /// Fixed states never ask macOS (fixtures and evidence renders).
    private let isFixed: Bool
    @ObservationIgnored private let probes: PermissionProbes
    @ObservationIgnored private let requestLogURL: URL?
    @ObservationIgnored private var requestLog: PermissionRequestLog
    /// The last live Screen Recording check (nil until one ran).
    @ObservationIgnored private(set) var screenRecordingLive: Bool?
    @ObservationIgnored private var liveCheck: Task<Void, Never>?
    @ObservationIgnored private var lastLiveCheck: Date?
    /// Seconds between live Screen Recording checks while it reads as off (onboarding polls every second).
    @ObservationIgnored var liveCheckInterval: TimeInterval = 3

    init(probes: PermissionProbes = .system, requestLogURL: URL? = AppPreferences.defaultURL) {
        isFixed = false
        self.probes = probes
        self.requestLogURL = requestLogURL
        requestLog = requestLogURL.map { PermissionRequestLog.load(from: $0) } ?? PermissionRequestLog()
        refresh()
    }

    init(fixed: [Permission: State], reach: AgentReach? = nil) {
        isFixed = true
        probes = .system
        requestLogURL = nil
        requestLog = PermissionRequestLog()
        states = fixed
        agentReach = reach
    }

    /// What agents can reach (Automation per scripted browser, guarded folders read before); made when Settings →
    /// Permissions opens, since the Automation check asks each installed browser.
    private(set) var agentReach: AgentReach?

    func refreshAgentReach() {
        guard !isFixed else { return }
        agentReach = probes.agentReach()
    }

    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var activationCenter: NotificationCenter?

    /// Settings → Permissions opened: check every state now, and again each time OpenClicky comes back to the front
    /// while it stays open (the user turns a switch on in System Settings and returns), so a row shows the grant, or
    /// Quit & Reopen, without "Check again".
    func pageAppeared(notifications: NotificationCenter = .default) {
        refresh()
        refreshAgentReach()
        guard !isFixed, activationObserver == nil else { return }
        activationCenter = notifications
        activationObserver = notifications.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                       queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Settings → Permissions closed: stop checking on activation.
    func pageDisappeared() {
        if let activationObserver { activationCenter?.removeObserver(activationObserver) }
        activationObserver = nil
        activationCenter = nil
    }

    func refresh() {
        guard !isFixed else { return }
        for permission in Permission.allCases { states[permission] = currentState(permission) }
        scheduleLiveScreenRecordingCheck()
    }

    var allRequiredGranted: Bool {
        [.microphone, .screenRecording, .accessibility].allSatisfy { states[$0] == .granted }
    }

    /// Some permission was allowed in System Settings but needs OpenClicky to quit and open again.
    var needsRestart: Bool { states.values.contains(.restartRequired) }

    func request(_ permission: Permission) async {
        guard !isFixed else { return }
        // Logged first: if the user says no (or never flips the switch), the next check shows "denied".
        if let requestLogURL {
            requestLog = PermissionRequestLog.record(permission, in: requestLogURL)
        } else {
            requestLog.requestedAt[permission] = Date()
        }
        await probes.request(permission)
        refresh()
    }

    /// Runs the live Screen Recording check now and updates the states (tests call it directly).
    func checkScreenRecordingLive() async {
        guard !isFixed else { return }
        lastLiveCheck = Date()
        screenRecordingLive = await probes.screenRecordingLive()
        states[.screenRecording] = currentState(.screenRecording)
    }

    /// Quits and opens OpenClicky again, so a Screen Recording grant takes effect.
    func quitAndReopen() {
        probes.relaunch()
    }

    /// The live check only runs after OpenClicky asked (so it can't show a first prompt of its own), only while the
    /// process's own check reads "off", and at most every `liveCheckInterval` seconds.
    private func scheduleLiveScreenRecordingCheck() {
        guard requestLog.askedBefore(.screenRecording), probes.read(.screenRecording) != .granted, liveCheck == nil else { return }
        if let lastLiveCheck, Date().timeIntervalSince(lastLiveCheck) < liveCheckInterval { return }
        liveCheck = Task { [weak self] in
            await self?.checkScreenRecordingLive()
            self?.liveCheck = nil
        }
    }

    private func currentState(_ permission: Permission) -> State {
        PermissionStateMapping.state(probes.read(permission), askedBefore: requestLog.askedBefore(permission),
                                     grantedLive: permission == .screenRecording ? screenRecordingLive : nil)
    }
}

extension PermissionKind {
    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .speechRecognition: "Speech Recognition"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var why: String {
        switch self {
        case .microphone: "So you can talk to OpenClicky."
        case .screenRecording: "So OpenClicky can see your screen when you ask about it."
        case .accessibility: "For the push-to-talk keys and to find buttons it points at."
        case .speechRecognition: "Only for the on-device Apple Speech option."
        case .inputMonitoring: "Optional: lets the talk keys work when Accessibility is off (they can then only listen)."
        }
    }

    /// The System Settings pane for this permission.
    var settingsURL: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .speechRecognition: "Privacy_SpeechRecognition"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// How PermissionsCenter reads and asks for permissions; tests and fixtures pass fakes.
struct PermissionProbes {
    /// What the process's own check reads now.
    var read: @MainActor (PermissionKind) -> PermissionReading
    /// A second Screen Recording check that sees a grant made in System Settings after launch.
    var screenRecordingLive: @MainActor () async -> Bool
    /// Shows the system prompt, or opens System Settings when macOS won't prompt again.
    var request: @MainActor (PermissionKind) async -> Void
    /// Quits and opens the app again.
    var relaunch: @MainActor () -> Void
    /// Automation per installed browser and the guarded folders read before, checked without prompting.
    var agentReach: @MainActor () -> AgentReach = {
        AgentReach.check(ledger: GuardedFolderLedger()) { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil }
    }

    static var system: PermissionProbes {
        PermissionProbes(read: systemRead, screenRecordingLive: systemScreenRecordingLive, request: systemRequest,
                         relaunch: AppRelauncher.relaunch)
    }

    private static func systemRead(_ permission: PermissionKind) -> PermissionReading {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .notGranted
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: .granted
            case kIOHIDAccessTypeDenied: .denied
            default: .notDetermined
            }
        }
    }

    /// ScreenCaptureKit asks the system service each time, so it sees a grant `CGPreflightScreenCaptureAccess` (which
    /// answers for the life of the process) doesn't.
    private static func systemScreenRecordingLive() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    private static func systemRequest(_ permission: PermissionKind) async {
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .screenRecording:
            // Shows the system prompt once; afterwards the user must flip the switch in System Settings.
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(permission.settingsURL) }
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { NSWorkspace.shared.open(permission.settingsURL) }
        case .speechRecognition:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        case .inputMonitoring:
            if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) { NSWorkspace.shared.open(permission.settingsURL) }
        }
    }
}

/// Quits and opens the running bundle again. A small shell waits for this process to exit before `open` runs, so two
/// copies (two event taps, two overlays) never run at once.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app",
              let command = RelaunchCommand.make(pid: ProcessInfo.processInfo.processIdentifier, bundlePath: bundle.path) else {
            // A development build (`swift run`) has no bundle to open again: just quit.
            NSApp.terminate(nil)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            NSWorkspace.shared.open(PermissionKind.screenRecording.settingsURL)
        }
    }
}
