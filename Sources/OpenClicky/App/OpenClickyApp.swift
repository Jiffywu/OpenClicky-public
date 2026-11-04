import AppKit
import OpenClickyKit
import SwiftUI

/// Starts the app, or with `--render-snapshots <folder>` renders every Home, Settings and onboarding page offscreen
/// from fixtures and exits (evidence for reviews; never touches the user's settings, Keychain or permissions).
/// `--render-voice-snapshots <folder> [--backdrop image]` does the same for the voice loop's overlay and panel.
@main
enum OpenClickyMain {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render-snapshots") {
            let folder = index + 1 < arguments.count ? arguments[index + 1] : "snapshots"
            MainActor.assumeIsolated {
                exit(EvidenceSnapshots.run(into: URL(fileURLWithPath: folder, isDirectory: true)))
            }
        }
        if let index = arguments.firstIndex(of: "--render-notch-snapshots") {
            let folder = index + 1 < arguments.count ? arguments[index + 1] : "notch-snapshots"
            MainActor.assumeIsolated {
                exit(NotchSnapshots.run(into: URL(fileURLWithPath: folder, isDirectory: true)))
            }
        }
        if let index = arguments.firstIndex(of: "--render-audio-notices") {
            let folder = index + 1 < arguments.count ? arguments[index + 1] : "audio-notices"
            MainActor.assumeIsolated {
                exit(AudioNoticeSnapshots.run(into: URL(fileURLWithPath: folder, isDirectory: true)))
            }
        }
        if let index = arguments.firstIndex(of: "--render-preview-snapshots") {
            let folder = index + 1 < arguments.count ? arguments[index + 1] : "preview-snapshots"
            MainActor.assumeIsolated { exit(PreviewSnapshots.run(into: URL(fileURLWithPath: folder, isDirectory: true))) }
        }
        if let index = arguments.firstIndex(of: "--render-onboarding-snapshots") {
            let folder = index + 1 < arguments.count ? arguments[index + 1] : "onboarding-snapshots"
            MainActor.assumeIsolated { exit(OnboardingStepSnapshots.run(into: URL(fileURLWithPath: folder, isDirectory: true))) }
        }
        if let index = arguments.firstIndex(of: "--render-agent-snapshots") {
            let folder = index + 1 < arguments.count ? arguments[index + 1] : "agent-snapshots"
            MainActor.assumeIsolated {
                exit(AgentSnapshots.run(into: URL(fileURLWithPath: folder, isDirectory: true)))
            }
        }
        if let index = arguments.firstIndex(of: "--render-latency-hud") {
            let folder = index + 1 < arguments.count ? arguments[index + 1] : "latency-hud"
            MainActor.assumeIsolated {
                exit(LatencyHUDSnapshots.run(into: URL(fileURLWithPath: folder, isDirectory: true)))
            }
        }
        if let index = arguments.firstIndex(of: "--render-connected-apps-snapshots") {
            let folder = index + 1 < arguments.count ? arguments[index + 1] : "connected-apps-snapshots"
            MainActor.assumeIsolated {
                exit(ConnectedAppsSnapshots.run(into: URL(fileURLWithPath: folder, isDirectory: true)))
            }
        }
        if let index = arguments.firstIndex(of: "--render-voice-snapshots") {
            let folder = index + 1 < arguments.count ? arguments[index + 1] : "voice-snapshots"
            MainActor.assumeIsolated {
                exit(VoiceOverlaySnapshots.run(into: URL(fileURLWithPath: folder, isDirectory: true)))
            }
        }
        OpenClickyApp.main()
    }
}

struct OpenClickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("OpenClicky", systemImage: "cursorarrow.rays") {
            MenuContent()
                .environment(delegate.model)
                .environment(delegate.home)
        }
        .commands {
            // With Show in Dock on, the app menu's Settings… (⌘,) opens OpenClicky's own Settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.home.openSettings(delegate.home.settingsPage) }
                    .keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    /// The voice loop's brain, shared with Home's typed chat and always-on voice.
    let brain = BrainRelay()
    lazy var home = HomeServices(model: model, brain: brain)
    private var voiceLoop: VoiceLoopController?
    /// The interactive notch and its live events.
    private var notch: NotchController?
    private var windowRegistrar: WindowCaptureRegistrar?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One handler for every openclicky:// link (the browser host's "open browser settings", `open`, other apps).
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc nonisolated func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue
        MainActor.assumeIsolated {
            guard let text, let url = URL(string: text) else {
                home.router.open(URL(string: "openclicky://invalid")!, source: "URL event (unreadable)")
                return
            }
            home.router.open(url, source: "URL event")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar accessory by default (no Dock icon, never steals focus from the app the user is asking about), or a
        // regular app with Show in Dock; the login item on the first launch from Applications.
        home.behavior.applyOnLaunch()
        model.start()
        home.start()
        let registrar = WindowCaptureRegistrar(policy: model.capturePolicy)
        registrar.start()
        windowRegistrar = registrar
        // Browser host manifests point at this copy of the app (refused outside a real .app bundle).
        BrowserSettingsModel.refreshManifestsAtLaunch()
        // Talk keys, the turn loop, dictation's chord, the text panel and job report turns.
        let voiceLoop = VoiceLoopController(model: model, home: home, brain: brain)
        voiceLoop.start()
        self.voiceLoop = voiceLoop
        model.voiceLoop = voiceLoop
        let notch = NotchController(app: model, home: home, voiceLoop: voiceLoop)
        notch.start()
        self.notch = notch
        if home.needsOnboarding {
            // Not in the middle of a call or a Focus: then it opens once that's over.
            let home = self.home
            voiceLoop.offerOnboarding { home.openOnboarding() }
        } else if !model.permissions.allRequiredGranted || model.hasErrors {
            openSettings()
        }
        home.router.becomeReady()
        home.behavior.presentInstallAlertIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        notch?.stop()
        voiceLoop?.stop()
        FigureAvailability.shared.appWillTerminate()
    }

    /// Stops background jobs' harness processes before quitting (at most a few seconds).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard home.agents != nil else { return .terminateNow }
        let once = ReplyOnce()
        Task { @MainActor in
            await self.home.stop()
            once.reply()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            once.reply()
        }
        return .terminateLater
    }

    func openSettings() {
        home.openSettings(home.settingsPage)
    }
}

/// Answers a deferred quit exactly once, whichever finishes first: the jobs stopping or the deadline.
@MainActor
private final class ReplyOnce {
    private var replied = false

    func reply() {
        guard !replied else { return }
        replied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

private struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(HomeServices.self) private var home

    var body: some View {
        Text("\(home.talkKeys.settings.voice.phrase) and talk")
        if model.turn.phase.isBusy {
            Button("Stop") { model.voiceLoop?.stopTurn() }
        }
        if let voiceLoop = model.voiceLoop {
            Toggle("Type a Question…", isOn: Binding(
                get: { voiceLoop.isTypedPanelVisible },
                set: { voiceLoop.setTypedPanelVisible($0) }))
        }
        Toggle("Always-On Voice", isOn: Binding(
            get: { model.alwaysOn.isActive },
            set: { enabled in
                if enabled != model.alwaysOn.isActive { model.voiceLoop?.toggleAlwaysOn() }
            }))
        if let hud = home.agents?.panel {
            Toggle("Background Jobs", isOn: Binding(get: { hud.isVisible }, set: { hud.setVisible($0) }))
        }
        if let status = model.pointing.status {
            Divider()
            Text("\(status.task ?? "Walkthrough"): step \(status.step) · \(status.caption)")
            Button("Stop walkthrough") {
                // Through the voice loop, so a next step still being prepared is cut off too.
                if let loop = model.voiceLoop { loop.stopWalkthrough() } else { model.pointing.stopWalkthrough() }
            }
        }
        Divider()
        Button("Open Home…") { home.openHome() }
            .keyboardShortcut("h", modifiers: [.command, .shift])
        if home.needsOnboarding {
            Button("Finish Setting Up…") { home.openOnboarding() }
        }
        Divider()
        ForEach(SlotID.allCases, id: \.self) { slot in
            let selection = model.config.slots[slot]
            let broken = model.issues(for: slot).contains { $0.severity == .error }
            Text("\(broken ? "⚠︎ " : "")\(slot.rawValue): \(selection?.model ?? "not set")")
        }
        if let warning = home.infra.warning {
            Button("⚠︎ \(warning)") { home.openSettings(.usage) }
        }
        if home.skills.activeCount > 0 {
            Text("Skills on: \(home.skills.skills.filter(\.isEnabled).map(\.name).joined(separator: ", "))")
        }
        Divider()
        Button("Settings…") { home.openSettings(home.settingsPage) }
        .keyboardShortcut(",")
        Button("Quit OpenClicky") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
