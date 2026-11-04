import Foundation
import OpenClickyKit

/// `occtl url <link> [--open]`: how the app's URL router reads an `openclicky://` (or in-app `openclicky:`) link,
/// without the app; `--open` then hands it to OpenClicky through Launch Services, as the browser host does.
enum URLCommands {
    static let help = """
    Usage:
      occtl url <link> [--open]
          Parse a link the way OpenClicky does and print where it goes (or why it is refused). --open sends it to the app.
          Examples: openclicky://settings/browser · openclicky:job/<id> · openclicky://home/agents · openclicky://routine/<id>
      occtl url --list
          Every Settings page a link can open.
    """

    static let url = OcctlCommand(name: "url", usage: "url <openclicky://…> [--open]  check (and open) an OpenClicky link") { args in
        if args.contains("--list") {
            for page in SettingsPageID.allCases {
                print("openclicky://settings/\(page.rawValue)")
            }
            return
        }
        guard let link = args.first(where: { !$0.hasPrefix("--") }) else { fail(help) }
        let parse = OpenClickyURLRouter.parse(link)
        print(parse.logLine)
        guard let route = parse.route else { exit(2) }
        if let canonical = OpenClickyURLRouter.link(for: route) { print("canonical: \(canonical.absoluteString)") }
        guard args.contains("--open") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [link]
        try process.run()
        process.waitUntilExit()
        print(process.terminationStatus == 0 ? "sent to OpenClicky" : "open failed with status \(process.terminationStatus)")
        if process.terminationStatus != 0 { exit(1) }
    }
}
