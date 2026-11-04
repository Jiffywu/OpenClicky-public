import AppKit
import OpenClickyKit
import os
import SwiftUI

/// The one place `openclicky://` links (the browser host's "open browser settings", `open`, other apps) and in-app
/// `openclicky:` links (in Markdown and cards) are handled. Every link is parsed and validated by
/// `OpenClickyURLRouter` and logged (subsystem `app.openclicky`, category `url`) before anything happens.
@MainActor
final class AppURLRouter {
    /// The last few log lines, newest last (shown nowhere yet; kept for debugging and tests of the app).
    private(set) var recent: [String] = []
    /// Links that arrived before the app finished launching run once it has.
    private var pending: [(URL, String)] = []
    private var ready = false
    private unowned let home: HomeServices
    private let log = Logger(subsystem: "app.openclicky", category: "url")

    init(home: HomeServices) { self.home = home }

    /// Called once launching is done; runs links that came in earlier.
    func becomeReady() {
        ready = true
        let queued = pending
        pending.removeAll()
        for (url, source) in queued { open(url, source: source) }
    }

    /// Handles a link. False when it was refused.
    @discardableResult
    func open(_ url: URL, source: String) -> Bool {
        guard ready else {
            pending.append((url, source))
            return true
        }
        let parse = OpenClickyURLRouter.parse(url)
        note("\(source): \(parse.logLine)", refused: parse.route == nil)
        guard let route = parse.route else { return false }
        return perform(route)
    }

    private func perform(_ route: OpenClickyRoute) -> Bool {
        switch route {
        case .settings(let page):
            home.openSettings(page.flatMap(HomeServices.SettingsPage.init) ?? home.settingsPage)
        case .home(let section):
            home.openHome(section: section.flatMap(HomeSection.init(rawValue:)))
        case .job:
            home.openHome(section: .agents)
            home.agents?.panel.show()
        case .routine(let id):
            home.routines.selectedID = id
            home.openSettings(.routines)
        case .onboarding:
            home.openOnboarding()
        case .revealFile(let path):
            let roots = [home.agentSettings.activePaths.projects, AgentPaths.default.projects]
            guard OpenClickyURLRouter.isInside(path, roots: roots), FileManager.default.fileExists(atPath: path) else {
                note("file link refused: outside the agent folders or missing", refused: true)
                return false
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        return true
    }

    /// For SwiftUI views: `openclicky:` links route here; anything else goes to the system as usual.
    var openURLAction: OpenURLAction {
        OpenURLAction { [weak self] url in
            guard url.scheme?.lowercased() == OpenClickyURLRouter.scheme else { return .systemAction }
            MainActor.assumeIsolated { _ = self?.open(url, source: "in-app link") }
            return .handled
        }
    }

    private func note(_ line: String, refused: Bool) {
        if refused { log.error("\(line, privacy: .public)") } else { log.info("\(line, privacy: .public)") }
        recent.append(line)
        if recent.count > 20 { recent.removeFirst(recent.count - 20) }
    }
}
