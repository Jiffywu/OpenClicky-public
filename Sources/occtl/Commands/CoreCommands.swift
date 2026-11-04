import Foundation
import OpenClickyKit

enum CoreCommands {
    static let store = KeychainCredentialStore()

    static let initConfig = OcctlCommand(name: "init", usage: "init                      write a HeyClicky-like config if none exists") { _ in
        let url = OpenClickyConfig.defaultURL
        if FileManager.default.fileExists(atPath: url.path) { fail("A config already exists at \(url.path).") }
        try OpenClickyConfig.heyClickyLike.save(to: url)
        print("Wrote \(url.path)")
    }

    static let validate = OcctlCommand(name: "validate", usage: "validate [config.json]    check every slot; exit 1 on errors") { args in
        let url = args.first.map { URL(fileURLWithPath: $0) } ?? OpenClickyConfig.defaultURL
        let config = try OpenClickyConfig.load(from: url)
        let issues = ConfigValidator(catalog: try .builtIn(), credentials: store).validate(config)
        if issues.isEmpty { print("OK: every slot is valid.") }
        issues.forEach { print($0) }
        if issues.contains(where: { $0.severity == .error }) { exit(1) }
    }

    static let models = OcctlCommand(name: "models", usage: "models <slot> [dialect]   list models a slot accepts") { args in
        guard let first = args.first, let slot = SlotID(rawValue: first) else {
            fail("Usage: occtl models <\(SlotID.allCases.map(\.rawValue).joined(separator: "|"))> [dialect]")
        }
        let catalog = try ModelCatalog.builtIn()
        var dialects = ProviderDialect.allCases
        if args.count > 1 {
            guard let dialect = ProviderDialect(rawValue: args[1]) else { fail("Unknown dialect \(args[1])") }
            dialects = [dialect]
        }
        for dialect in dialects {
            let models = catalog.candidates(for: slot, dialect: dialect)
            guard !models.isEmpty else { continue }
            print("\(dialect.rawValue):")
            for model in models {
                print("  \(model.id)\(model.displayName.map { "  (\($0))" } ?? "")  [\(model.capabilities.sorted().map(\.rawValue).joined(separator: ", "))]")
            }
        }
    }

    static let key = OcctlCommand(name: "key", usage: "key <set|check|rm> <name> manage Keychain credentials (set reads stdin)") { args in
        guard args.count == 2 else { fail("Usage: occtl key <set|check|rm> <name>") }
        let name = args[1]
        switch args[0] {
        case "set":
            let secret = readSecretFromStdin()
            guard !secret.isEmpty else { fail("Empty secret; nothing stored.") }
            try store.setSecret(secret, named: name)
            print("Stored credential \"\(name)\" in the Keychain.")
        case "check":
            print(try store.secret(named: name) == nil ? "missing" : "present")
        case "rm":
            try store.removeSecret(named: name)
            print("Removed credential \"\(name)\".")
        default:
            fail("Usage: occtl key <set|check|rm> <name>")
        }
    }

    static func readSecretFromStdin() -> String {
        if isatty(STDIN_FILENO) != 0 {
            guard let typed = getpass("Secret (input hidden): ") else { fail("No input.") }
            return String(cString: typed)
        }
        return (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
