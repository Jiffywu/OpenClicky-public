import AppKit
import OpenClickyKit
import os
import SwiftUI

/// Settings → Browser: whether the Chrome extension is connected, which connected profile agents use, the native-host
/// manifests in each browser, and how to load the extension. The browser host's "Open OpenClicky" button lands here
/// (`openclicky://settings/browser`).
@MainActor
@Observable
final class BrowserSettingsModel {
    struct InstalledBrowser: Identifiable, Equatable {
        var browser: ChromiumBrowser
        var profiles: [ChromiumProfile]
        var manifest: NativeHostInstaller.Inspection?
        var id: String { browser.id }
    }

    private(set) var state: BrowserConnectionState = .bridgeNotRunning("not checked yet")
    private(set) var preferences: BrowserBridgePreferences
    private(set) var installed: [InstalledBrowser] = []
    private(set) var stagedFolder: URL?
    private(set) var stagedVersion: String?
    /// Why a browser last failed to connect, from the bridge (cleared when one connects).
    private(set) var failure: BrowserSetupFailure?
    /// OpenClicky's own setup step that failed on this page (writing the browser helpers).
    private(set) var setupError: String?
    var message: String?

    /// Off, Waiting, Setup failed (with its reason) or Connected, plus a problem to show beside Connected.
    var badge: (badge: BrowserSetupBadge, attention: String?) {
        BrowserSetupBadge.make(state: state, failure: failure, setupError: setupError)
    }

    /// Shown for a while after the first browser ever connected on this Mac.
    var firstConnectionNotice: String? { preferences.firstConnectionNotice() }

    @ObservationIgnored private let paths: BrowserBridgePaths
    @ObservationIgnored private let applicationSupport: URL
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var pinned = false
    @ObservationIgnored private static let log = Logger(subsystem: "app.openclicky", category: "browser-setup")

    init(paths: BrowserBridgePaths, applicationSupport: URL = NativeHostInstaller.defaultApplicationSupport) {
        self.paths = paths
        self.applicationSupport = applicationSupport
        preferences = BrowserBridgePreferences.load(from: paths)
    }

    /// Refreshes `com.openclicky.browser.json` in every installed Chromium browser from this app bundle (HeyClicky
    /// does this at each launch). Refused outside a real .app bundle; logged either way.
    @discardableResult
    static func refreshManifestsAtLaunch(bundleURL: URL = Bundle.main.bundleURL) -> String {
        let line: String
        switch BundledHostInstall.refresh(bundleURL: bundleURL, extensionIDs: ChromeExtensionIdentity.allowedIDs()) {
        case .success(let outcomes): line = "browser host manifests: " + BundledHostInstall.summary(outcomes)
        case .failure(let refusal): line = "browser host manifests not written: \(refusal)"
        }
        log.info("\(line, privacy: .public)")
        return line
    }

    // MARK: Page lifecycle

    func appear() {
        guard !pinned else { return }
        rescan()
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probe()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func disappear() {
        poller?.cancel()
        poller = nil
    }

    /// Browsers, profiles and manifests on disk.
    func rescan() {
        let inspections = NativeHostInstaller.inspect(applicationSupport: applicationSupport)
        installed = ChromiumProfileDiscovery.installed(applicationSupport: applicationSupport).map { entry in
            InstalledBrowser(browser: entry.browser, profiles: entry.profiles,
                             manifest: inspections.first { $0.browser == entry.browser })
        }
        let staged = BrowserExtensionFolder.defaultStaged
        stagedFolder = FileManager.default.fileExists(atPath: staged.appendingPathComponent("manifest.json").path) ? staged : nil
        stagedVersion = stagedFolder.flatMap(BrowserExtensionFolder.version(at:))
    }

    private func probe() async {
        let paths = self.paths
        let result = await Task.detached { () -> Result<BrowserBridgeProbe.Status, Error> in
            Result { try BrowserBridgeProbe.status(paths: paths) }
        }.value
        let newState = BrowserConnectionState.from(probe: result)
        if newState != state { state = newState }
        let newFailure = try? result.get().failure
        if newFailure != failure { failure = newFailure }
        if case .connected(let peers) = newState {
            var updated = preferences
            let first = updated.noteConnected(peers)
            if first || updated.knownProfiles.map(\.id) != preferences.knownProfiles.map(\.id) {
                preferences = updated
                try? updated.save(to: paths)
            } else if !preferences.hasEverConnected {
                // The app recorded the first connection already; pick it up for the notice.
                preferences = BrowserBridgePreferences.load(from: paths)
            }
        }
    }

    // MARK: Actions

    var connectedPeers: [BrowserPeer] { if case .connected(let peers) = state { peers } else { [] } }

    func choose(_ profileID: String?) {
        preferences.choose(profileID)
        do {
            try preferences.save(to: paths)
            message = "Agents use \(profileID == nil ? "the most recently connected profile" : "that profile") from the next time the bridge starts."
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func refreshManifests() {
        let line = Self.refreshManifestsAtLaunch()
        message = line
        setupError = Self.setupError(fromRefresh: line)
        rescan()
    }

    /// A refresh that wrote nothing, or failed for some browser, is a setup failure worth a badge.
    static func setupError(fromRefresh line: String) -> String? {
        if line.contains("not written") || line.contains("failed (") { return line }
        return nil
    }

    /// Copies the extension out of the app to a folder that survives app updates, and shows it in Finder.
    func prepareExtensionFolder() {
        let source = BrowserExtensionFolder.bundled(in: Bundle.main.bundleURL)
        do {
            let folder = try BrowserExtensionFolder.stage(from: source)
            message = "The extension is ready in \(folder.path). Choose this folder in Load unpacked."
            rescan()
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            message = "\(error)"
        }
    }

    func openExtensionsPage(_ browser: ChromiumBrowser) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID),
              let page = URL(string: BrowserSetupGuide.extensionsPage(for: browser)) else {
            message = "\(browser.displayName) isn't installed."
            return
        }
        NSWorkspace.shared.open([page], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.message = "Couldn't open \(browser.displayName): \(error.localizedDescription)" }
        }
    }

    /// Fixture state (evidence renders): browsers and manifests come from `rescan()` over the fixture's folders.
    func show(state: BrowserConnectionState, preferences: BrowserBridgePreferences, staged: URL?, failure: BrowserSetupFailure? = nil) {
        rescan()
        pinned = true
        self.failure = failure
        self.state = state
        self.preferences = preferences
        stagedFolder = staged
        stagedVersion = staged.flatMap(BrowserExtensionFolder.version(at:))
    }
}

struct BrowserSettingsPage: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        let browser = services.browser
        Form {
            Section {
                let badge = browser.badge
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: browser.state.isConnected ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.title2).foregroundStyle(browser.state.isConnected ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(browser.state.title).font(.headline)
                            badgeView(badge.badge)
                        }
                        Text(browser.state.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let reason = badge.badge.reason ?? badge.attention {
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                }
                if let notice = browser.firstConnectionNotice {
                    Label(notice, systemImage: "party.popper").font(.callout)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Works with Chrome, Arc, Brave, Edge, Vivaldi and other Chromium browsers. Agents use it to act in sites you're signed in to.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !browser.connectedPeers.isEmpty || !browser.preferences.knownProfiles.isEmpty {
                Section {
                    Picker("Agents work in", selection: Binding(get: { browser.preferences.preferredProfileID }, set: { browser.choose($0) })) {
                        Text("The most recently connected profile").tag(String?.none)
                        ForEach(profileOptions(browser), id: \.id) { option in
                            Text(option.label).tag(Optional(option.id))
                        }
                    }
                } header: {
                    Text("Profile")
                } footer: {
                    Text("The profile OpenClicky's agents use when the extension is connected in more than one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                if browser.installed.isEmpty {
                    Text("No Chromium browser found on this Mac.").foregroundStyle(.secondary)
                }
                ForEach(browser.installed) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.browser.displayName).frame(width: 110, alignment: .leading)
                        manifestLabel(entry.manifest)
                        Spacer()
                        Text(profilesLine(entry.profiles)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Button("Install or Refresh Browser Helpers") { browser.refreshManifests() }
            } header: {
                Text("Browser helpers")
            } footer: {
                Text("Each browser finds OpenClicky through a small helper file in its NativeMessagingHosts folder. OpenClicky refreshes them every time it starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                let target = browser.installed.first?.browser ?? NativeHostInstaller.browsers[0]
                let folder = browser.stagedFolder ?? BrowserExtensionFolder.defaultStaged
                ForEach(Array(BrowserSetupGuide.loadUnpackedSteps(browser: target, folder: folder).enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Text(step).font(.callout).textSelection(.enabled)
                    }
                }
                HStack {
                    Button(browser.stagedFolder == nil ? "Prepare the Extension Folder" : "Show the Extension Folder") { browser.prepareExtensionFolder() }
                    Button("Open \(target.displayName)'s Extensions Page") { browser.openExtensionsPage(target) }
                    Spacer()
                }
                if let version = browser.stagedVersion {
                    Text("Extension \(version) in \(folder.path)").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Load the extension")
            }
            if let message = browser.message {
                Section { Label(message, systemImage: "info.circle").font(.callout).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .onAppear { browser.appear() }
        .onDisappear { browser.disappear() }
    }

    private func badgeView(_ badge: BrowserSetupBadge) -> some View {
        let color: Color = switch badge {
        case .connected: .green
        case .setupFailed: .orange
        case .waiting: .yellow
        case .off: .secondary
        }
        return Text(badge.title).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }

    private struct ProfileOption { var id: String; var label: String }

    private func profileOptions(_ browser: BrowserSettingsModel) -> [ProfileOption] {
        var options: [ProfileOption] = browser.connectedPeers.map {
            ProfileOption(id: $0.profileId, label: "\($0.browserName), profile \($0.profileId.prefix(8)) (connected)")
        }
        for known in browser.preferences.knownProfiles where !options.contains(where: { $0.id == known.id }) {
            options.append(ProfileOption(id: known.id, label: "\(known.browserName), profile \(known.id.prefix(8))"))
        }
        if let chosen = browser.preferences.preferredProfileID, !options.contains(where: { $0.id == chosen }) {
            options.append(ProfileOption(id: chosen, label: "Profile \(chosen.prefix(8)) (not seen recently)"))
        }
        return options
    }

    @ViewBuilder private func manifestLabel(_ inspection: NativeHostInstaller.Inspection?) -> some View {
        if let inspection, inspection.manifestPresent {
            if inspection.hostExecutable && inspection.allowsOpenClickyExtension {
                Label("Helper installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            } else {
                Label(inspection.hostExecutable ? "Helper doesn't allow the extension" : "Helper points at a missing app",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            }
        } else {
            Label("No helper yet", systemImage: "circle").foregroundStyle(.secondary).font(.caption)
        }
    }

    private func profilesLine(_ profiles: [ChromiumProfile]) -> String {
        switch profiles.count {
        case 0: return "no profiles found"
        case 1: return "profile: \(profiles[0].name)"
        default: return "\(profiles.count) profiles, latest \(profiles[0].name)"
        }
    }
}
