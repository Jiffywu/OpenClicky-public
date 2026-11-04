import Foundation

/// What OpenClicky knows about common Mac apps and sites, by bundle identifier and host. Used to pick the cleanup
/// style for a field and the order of insertion strategies. Lists are OpenClicky's own and easy to extend.
public enum AppTraits {
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp", "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
        "co.zeit.hyper", "org.tabby",
    ]

    /// Chromium-based browsers. Their web content only shows up in Accessibility once a client asks for it.
    public static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta", "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    public static let otherBrowsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly", "app.zen-browser.zen",
    ]

    /// Electron apps seen often enough to list; others are detected from their bundle contents.
    public static let knownElectronApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.notion.id", "md.obsidian", "com.figma.Desktop",
        "com.anthropic.claudefordesktop", "com.linear", "com.superhuman.electron", "org.whispersystems.signal-desktop",
        "com.spotify.client",
    ]

    /// Apps whose text views ignore or mishandle Accessibility writes, so paste comes first. Terminals, browsers
    /// and Electron apps are added to this automatically.
    public static let pasteFirstApps: Set<String> = [
        "com.sublimetext.4", "com.sublimetext.3", "com.tencent.xinWeChat", "com.tencent.WeWorkMac",
        "com.microsoft.teams2", "com.microsoft.teams", "com.openai.chat", "com.openai.codex", "com.microsoft.Word",
        "com.microsoft.Outlook", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.bytedance.doubao",
        "ru.keepcoder.Telegram",
    ]

    public static let codeEditors: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.sublimetext.4", "com.sublimetext.3",
        "com.panic.Nova", "com.barebones.bbedit",
    ]

    public static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram", "com.microsoft.teams2", "com.microsoft.teams", "com.tencent.xinWeChat",
        "com.tencent.WeWorkMac", "com.facebook.archon", "org.whispersystems.signal-desktop", "com.openai.chat",
        "com.anthropic.claudefordesktop", "com.bytedance.doubao",
    ]

    public static let emailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
        "com.mimestream.Mimestream", "com.freron.MailMate", "com.airmailapp.airmail2",
    ]

    public static let documentApps: Set<String> = [
        "com.apple.Notes", "com.apple.iWork.Pages", "com.apple.TextEdit", "com.microsoft.Word", "com.notion.id",
        "md.obsidian", "net.shinyfrog.bear", "com.ulyssesapp.mac", "com.apple.iWork.Keynote",
    ]

    public static let chatSites: Set<String> = [
        "app.slack.com", "discord.com", "web.whatsapp.com", "www.messenger.com", "messenger.com", "teams.microsoft.com",
        "teams.live.com", "chatgpt.com", "claude.ai", "gemini.google.com", "web.telegram.org", "x.com", "twitter.com",
    ]

    public static let emailSites: Set<String> = [
        "mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "app.fastmail.com",
        "mail.proton.me", "mail.yahoo.com", "app.hey.com",
    ]

    public static let documentSites: Set<String> = [
        "docs.google.com", "www.notion.so", "notion.so", "quip.com", "dropbox.com", "paper.dropbox.com",
    ]

    public static let codeSites: Set<String> = ["vscode.dev", "github.dev", "codepen.io", "replit.com", "codesandbox.io"]

    public static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return chromiumBrowsers.contains(bundleID) || otherBrowsers.contains(bundleID)
    }

    public static func isTerminal(_ bundleID: String?) -> Bool { bundleID.map(terminals.contains) ?? false }

    public static func isJetBrains(_ bundleID: String?) -> Bool { bundleID?.hasPrefix("com.jetbrains.") ?? false }

    /// True when the app is built on Electron: listed, or its bundle ships the Electron framework.
    public static func isElectron(bundleID: String?, bundleURL: URL?) -> Bool {
        if let bundleID, knownElectronApps.contains(bundleID) { return true }
        guard let bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    /// Chromium and Electron apps build their Accessibility tree only when an assistive client asks for it.
    public static func needsManualAccessibility(bundleID: String?, bundleURL: URL?) -> Bool {
        if let bundleID, chromiumBrowsers.contains(bundleID) { return true }
        return isElectron(bundleID: bundleID, bundleURL: bundleURL)
    }

    /// Whether paste should be tried before Accessibility writes in this app.
    public static func prefersPaste(bundleID: String?, isElectron: Bool = false) -> Bool {
        guard let bundleID else { return isElectron }
        return isElectron || terminals.contains(bundleID) || isBrowser(bundleID) || pasteFirstApps.contains(bundleID)
            || knownElectronApps.contains(bundleID) || isJetBrains(bundleID)
    }

    /// The kind of writing a field is for, from the app, the site and the element's role.
    public static func surface(bundleID: String?, siteHost: String?, role: String?, subrole: String?) -> TextSurface {
        if let bundleID, terminals.contains(bundleID) { return .terminal }
        if subrole == "AXSearchField" || role == "AXSearchField" { return .search }
        if let host = siteHost.map(normalizedHost) {
            if emailSites.contains(host) { return .email }
            if chatSites.contains(host) { return .chat }
            if documentSites.contains(host) { return .document }
            if codeSites.contains(host) { return .code }
        }
        guard let bundleID else { return .general }
        if codeEditors.contains(bundleID) || isJetBrains(bundleID) { return .code }
        if emailApps.contains(bundleID) { return .email }
        if chatApps.contains(bundleID) { return .chat }
        if documentApps.contains(bundleID) { return .document }
        return .general
    }

    static func normalizedHost(_ host: String) -> String {
        let lower = host.lowercased()
        if lower.hasPrefix("www."), !documentSites.contains(lower), !chatSites.contains(lower) {
            return String(lower.dropFirst(4))
        }
        return lower
    }
}
