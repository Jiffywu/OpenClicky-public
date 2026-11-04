import AppKit
import OpenClickyKit
import SwiftUI

/// App-wide state: the configuration and its validation, permissions, and what the buddy is doing right now.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case error(String)
    }

    var config: OpenClickyConfig
    private(set) var issues: [ConfigIssue] = []
    private(set) var catalog: ModelCatalog
    /// Settings-level errors (a save that failed).
    var phase: Phase = .idle
    /// The current voice turn as the notch, captions and the cursor bubble show it (from the turn orchestrator).
    var turn = TurnDisplay()
    /// Always-on voice as the notch shows it (from the voice loop's `AlwaysOnVoiceLoop`).
    var alwaysOn = AlwaysOnDisplay()
    /// How to turn always-on off ("Triple-tap Control"), nil when the text key has no triple tap.
    var alwaysOnKeyPhrase: String?
    /// The last finished turn's step timings.
    var lastTimings: TurnTimings?
    var voiceLoopSettings = VoiceLoopSettings()
    /// The mic's level 0…1 while listening, for the notch waveform.
    @ObservationIgnored var micLevel: () -> Float = { 0 }
    /// The interactive notch panel is up (`NotchController`); the overlay then leaves the pill to it.
    var notchPanelActive = false
    /// Where the voice is in the line it is playing (seconds of audio played), for word-by-word captions.
    @ObservationIgnored var speechPosition: () -> SpeechPlayer.Position? = { nil }

    let permissions: PermissionsCenter
    let credentials: any CredentialStore
    /// The talk keys anywhere on the Mac (a CGEventTap); the voice loop handles what they do.
    let talkKeyMonitor = TalkKeyMonitor()
    /// The buddy pointer, drawn in every overlay.
    let pointer = BuddyPointerController()
    /// The drawing canvases in the overlays.
    let drawings = OverlayDrawingSurfaces()
    /// Draw-to-ask ink and guided walkthrough targets (docs/guided.md). The voice loop's orchestrator drives it through
    /// `TurnGuiding`: talk key down, up and cancel, the highlight on the next turn, and the walkthrough's own turns.
    let pointing = PointingOverlayModel()
    /// OpenClicky's own windows and their capture roles (who may record them, which its screenshots leave out); the
    /// app delegate's `WindowCaptureRegistrar` registers each window as it appears.
    let capturePolicy = OwnWindowCapturePolicy()
    /// Set by the app delegate once the voice loop is running.
    @ObservationIgnored weak var voiceLoop: VoiceLoopController?
    private var overlay: OverlayController?
    /// Where `save()` writes; nil keeps changes in memory (fixtures and evidence renders).
    private let configURL: URL?

    init() {
        let catalog = (try? ModelCatalog.builtIn()) ?? ModelCatalog(models: [])
        self.catalog = catalog
        permissions = PermissionsCenter()
        credentials = KeychainCredentialStore()
        configURL = OpenClickyConfig.defaultURL
        // Retries, plain provider explanations and the usage ledger for every engine the app builds (docs/infra.md).
        ProviderResilience.install(.standard(client: "app"))
        if let loaded = try? OpenClickyConfig.load() {
            config = loaded
        } else {
            config = .heyClickyLike
            try? config.save()
        }
        revalidate()
    }

    /// A model over a given config and stores that never touches config.json (fixtures, evidence renders).
    init(config: OpenClickyConfig, credentials: any CredentialStore, permissions: PermissionsCenter) {
        catalog = (try? ModelCatalog.builtIn()) ?? ModelCatalog(models: [])
        self.config = config
        self.credentials = credentials
        self.permissions = permissions
        configURL = nil
        revalidate()
    }

    func start() {
        pointing.attach(pointer: pointer)
        overlay = OverlayController { [weak self] screen in
            AnyView(OverlayRootView(screen: screen).environment(self))
        }
        overlay?.start()
    }

    /// The overlay panels and the drawing handles over buttons, figures and cards, so screen capture leaves them out.
    var overlayWindowNumbers: [Int] { (overlay?.windowNumbers ?? []) + drawings.handleWindowNumbers }

    /// Hides the overlays while system UI is up that they would get in the way of (the screenshot UI, a window
    /// picker, Mission Control).
    func setOverlayHidden(_ hidden: Bool) {
        overlay?.setHidden(hidden)
        // The drawing handles go too: hidden handles would take clicks meant for that UI.
        drawings.handles.isHidden = hidden
    }

    func revalidate() {
        issues = ConfigValidator(catalog: catalog, credentials: credentials).validate(config)
    }

    func save() {
        do {
            if let configURL { try config.save(to: configURL) }
        } catch {
            phase = .error("Couldn't save settings: \(error.localizedDescription)")
        }
        revalidate()
    }

    func issues(for slot: SlotID) -> [ConfigIssue] { issues.filter { $0.slot == slot } }
    var globalIssues: [ConfigIssue] { issues.filter { $0.slot == nil } }
    var hasErrors: Bool { issues.contains { $0.severity == .error } }

    var mergedCatalog: ModelCatalog { catalog.merging(config.models) }
}
