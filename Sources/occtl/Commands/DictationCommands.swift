import Foundation
import OpenClickyKit

/// `occtl dictation …`: try the talk-to-type pieces from the command line.
enum DictationCommands {
    /// Builds real cleanup clients from the provider adapters. Without a stored credential for the cleanup provider
    /// (or with `--fake`) cleanup runs on `FakeCleanupModel` and nothing leaves the Mac.
    static let modelFactory: any DictationModelClientFactory = AdapterModelClientFactory()

    static let help = """
    Usage:
      occtl dictation cleanup <text> [--single-line] [--app NAME] [--bundle ID] [--site HOST]
                                     [--before TEXT] [--after TEXT] [--vocab A,B] [--show-prompt] [--fake]
                                     [--config PATH] [--settings PATH]
          Clean up a transcript the way dictation would before typing it. Uses the brain-fast slot (or the brain
          slot) when its provider's credential is stored; otherwise, or with --fake, a local fake model.
      occtl dictation run <audio file> [--fast] [--warm] [--fake] [--json] [--language xx] [--config PATH] [--settings PATH]
          One whole dictation from a file: the stt slot's ears, the cleanup pass, then typing into a pretend
          TextEdit field. Prints the time of each step.
      occtl dictation focus [--json] [--redact] [--no-enable] [--wait SECONDS]
          Show what dictation sees in the focused field (needs Accessibility for this terminal).
      occtl dictation plan <bundle-id> [--role AXTextField|AXTextArea] [--subrole ROLE] [--site HOST]
          Show the insertion strategies dictation would try in an app.
      occtl dictation vocab [list|keyterms|add <word>|rm <word>] [--file PATH]
      occtl dictation archive [YYYY-MM-DD] [--dir PATH]
    """

    static let dictation = OcctlCommand(name: "dictation", usage: "dictation <cleanup|run|focus|plan|vocab|archive> talk-to-type tools") { args in
        guard let sub = args.first else { fail(help) }
        let options = Options(Array(args.dropFirst()))
        switch sub {
        case "cleanup": try await cleanup(options)
        case "run": try await run(options)
        case "focus": try await focus(options)
        case "plan": plan(options)
        case "vocab": try await vocab(options)
        case "archive": try await archive(options)
        default: fail(help)
        }
    }

    // MARK: cleanup

    static func cleanup(_ options: Options) async throws {
        let text = options.positional.joined(separator: " ")
        guard !text.isEmpty else { fail(help) }
        let settings = DictationSettings.load(from: options.value("settings").map { URL(fileURLWithPath: $0) } ?? DictationSettings.defaultURL)
        let config: OpenClickyConfig
        if let path = options.value("config") {
            do { config = try OpenClickyConfig.load(from: URL(fileURLWithPath: path)) } catch { fail("Can't read \(path): \(error)") }
        } else {
            config = (try? OpenClickyConfig.load()) ?? .heyClickyLike
        }
        let choice = DictationCleanupModelChoice.resolve(config: config, cleanup: settings.cleanup, catalog: try? ModelCatalog.builtIn())

        let context = cleanupContext(options)
        let resolution: DictationCleanupClientResolver.Resolution = options.flag("fake")
            ? .fake(reason: "--fake")
            : DictationCleanupClientResolver.resolve(choice: choice, factory: modelFactory, credentials: KeychainCredentialStore())
        let client: any LanguageModelClient
        let fake = FakeCleanupModel()
        switch resolution {
        case .real(let real, let choice):
            client = real
            note("cleanup model: \(choice.provider.id)/\(choice.model)\(choice.reasoningEffort.map { " (effort \($0))" } ?? "")")
        case .fake(let reason):
            client = fake
            let configured = (try? choice.get()).map { "\($0.provider.id)/\($0.model)" } ?? "none"
            note("cleanup model: FAKE (configured: \(configured); \(reason))")
        }

        let cleanupOptions = (try? choice.get())?.options(settings.cleanup)
            ?? DictationCleanupOptions(model: "fake", minimumWords: settings.cleanup.minimumWords, timeout: settings.cleanup.timeoutSeconds)
        let vocabulary: [String]
        if let list = options.value("vocab") {
            vocabulary = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            vocabulary = await DictationVocabularyStore().load().keyterms(seeds: ["OpenClicky"])
        }

        if options.flag("show-prompt") {
            let request = DictationCleanupPrompt.request(transcript: text, context: context, vocabulary: vocabulary, options: cleanupOptions)
            print("── system ──")
            print(request.messages[0].text)
            print("── user ──")
            print(request.messages[1].text)
            print("── request ── model=\(request.model) effort=\(request.reasoningEffort ?? "default") max_output_tokens=\(request.maxOutputTokens ?? 0)")
            print("── result ──")
        }

        let cleaner = DictationCleaner(client: client, options: cleanupOptions)
        let result = await cleaner.clean(text, context: context, vocabulary: vocabulary)
        print(result.text)
        note("source: \(describe(result.source)), \(result.milliseconds) ms, model calls: \(resolution.isReal ? "real" : String(fake.requests.count))")
        let typed = InsertionText.prepare(result.text, before: context.beforeText, after: context.afterText, singleLine: context.isSingleLine)
        note("would type: «\(typed)»")
    }

    static func cleanupContext(_ options: Options) -> FocusContext {
        let bundleID = options.value("bundle")
        let site = options.value("site")
        let singleLine = options.flag("single-line")
        let role = singleLine ? "AXTextField" : "AXTextArea"
        let surface = AppTraits.surface(bundleID: bundleID, siteHost: site, role: role, subrole: nil)
        let before = options.value("before")
        let after = options.value("after")
        return FocusContext(appName: options.value("app"), bundleID: bundleID, siteHost: site, role: role,
                            beforeText: before ?? "", afterText: after ?? "",
                            isSingleLine: singleLine || surface == .terminal || surface == .search,
                            isValueReadable: before != nil || after != nil, surface: surface)
    }

    static func describe(_ source: DictationCleanupResult.Source) -> String {
        switch source {
        case .model: "model"
        case .skippedShort: "skipped (short utterance, local tidy only)"
        case .skippedDisabled: "skipped (no cleanup model)"
        case .fallback(let why): "fallback to local tidy (\(why))"
        }
    }

    // MARK: focus

    static func focus(_ options: Options) async throws {
        guard AccessibilityFocusReader.isTrusted else {
            let host = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "the app running occtl"
            FileHandle.standardError.write(Data("""
            Accessibility access is off for \(host). Dictation reads the focused field through Accessibility.
            Turn it on in System Settings → Privacy & Security → Accessibility, then run this again.

            """.utf8))
            exit(2)
        }
        if let wait = options.value("wait").flatMap(Double.init), wait > 0 {
            note("Reading the focused field in \(wait) s; click into a text field now.")
            try await Task.sleep(for: .seconds(wait))
        }
        let reader = AccessibilityFocusReader(options: .init(enableWebAccessibility: !options.flag("no-enable")))
        let captured: CapturedFocus
        switch reader.captureFocus() {
        case .success(let value): captured = value
        case .failure(let error): fail("Error: \(error)")
        }
        var context = captured.context
        if options.flag("redact") {
            context.beforeText = redacted(context.beforeText)
            context.selectedText = redacted(context.selectedText)
            context.afterText = redacted(context.afterText)
        }
        let system = SystemTextInsertion(reader: reader)
        let isElectron = system.isElectron(processID: context.processID)
        let strategies = DictationSettings.load().strategyTable.strategies(for: captured.context, isElectron: isElectron)
        let secureInput = system.isSecureEventInputEnabled()

        if options.flag("json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(context), as: UTF8.self))
            return
        }
        print("app:          \(context.appName ?? "?") (\(context.bundleID ?? "no bundle id"), pid \(context.processID))\(isElectron ? " [Electron]" : "")")
        if let site = context.siteHost { print("site:         \(site)") }
        print("element:      \(context.role ?? "?")\(context.subrole.map { " / \($0)" } ?? "")")
        if let frame = context.frame { print("frame:        x=\(Int(frame.x)) y=\(Int(frame.y)) w=\(Int(frame.width)) h=\(Int(frame.height))") }
        print("kind:         \(context.isSecure ? "SECURE, " : "")\(context.isSingleLine ? "single line" : "multi-line"), \(context.surface.rawValue), \(context.isEditable ? "editable" : "not editable")")
        print("value:        \(context.isValueReadable ? "readable" : "not readable")\(context.characterCount.map { ", \($0) UTF-16 units" } ?? "")")
        if let selection = context.selection { print("selection:    location \(selection.location), length \(selection.length)") }
        print("before caret: \(show(context.beforeText))")
        print("selected:     \(show(context.selectedText))")
        print("after caret:  \(show(context.afterText))")
        print("secure input: \(secureInput ? "ON (dictation would refuse)" : "off")")
        let plan = context.isSecure ? "refused (password field)"
            : secureInput ? "refused while Secure Event Input is on (would be: \(strategies.map(\.rawValue).joined(separator: " → ")))"
            : strategies.map(\.rawValue).joined(separator: " → ") + " → clipboard"
        print("insertion:    \(plan)")
    }

    static func redacted(_ text: String) -> String { text.isEmpty ? "" : "‹\(text.count) characters›" }

    static func show(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count > 120 ? "\"…\(flat.suffix(117))\"" : "\"\(flat)\""
    }

    // MARK: plan

    static func plan(_ options: Options) {
        guard let bundleID = options.positional.first else { fail(help) }
        let role = options.value("role") ?? "AXTextArea"
        let snapshot = FocusSnapshot(bundleID: bundleID, role: role, subrole: options.value("subrole"),
                                     isValueSettable: true, isSelectedTextSettable: true,
                                     url: options.value("site").flatMap { URL(string: "https://\($0)/") })
        var context = FocusContext(snapshot: snapshot)
        context.isValueReadable = true
        let table = DictationSettings.load().strategyTable
        print("\(bundleID) \(role)\(options.value("subrole").map { "/\($0)" } ?? ""): surface \(context.surface.rawValue), \(context.isSingleLine ? "single line" : "multi-line")")
        if context.isSecure {
            print("  refused: password field")
        } else {
            print("  strategies: \(table.strategies(for: context).map(\.rawValue).joined(separator: " → ")) → clipboard")
        }
    }

    // MARK: vocab

    static func vocab(_ options: Options) async throws {
        let store = DictationVocabularyStore(url: options.value("file").map { URL(fileURLWithPath: $0) } ?? DictationVocabularyStore.defaultURL)
        let action = options.positional.first ?? "list"
        let word = options.positional.dropFirst().joined(separator: " ")
        switch action {
        case "list":
            let vocabulary = await store.load()
            print("words (\(vocabulary.words.count)/\(DictationVocabulary.maxWords)):")
            vocabulary.words.forEach { print("  \($0)") }
            print("learned corrections:")
            vocabulary.corrections.forEach { print("  \($0.original) → \($0.corrected)  ×\($0.count)") }
        case "keyterms":
            await store.load().keyterms(seeds: ["OpenClicky"]).forEach { print($0) }
        case "add":
            guard !word.isEmpty else { fail(help) }
            let added = try await store.update { $0.add(word) }
            print(added ? "Added \"\(word)\"." : "Not added (blank, already there, too long, or the dictionary is full).")
        case "rm":
            guard !word.isEmpty else { fail(help) }
            let removed = try await store.update { $0.remove(word) }
            print(removed ? "Removed \"\(word)\"." : "\"\(word)\" was not in the dictionary.")
        default:
            fail(help)
        }
    }

    // MARK: archive

    static func archive(_ options: Options) async throws {
        let directory = options.value("dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? DictationTranscriptArchive.defaultDirectory
        let archive = DictationTranscriptArchive(directory: directory)
        var day = Date()
        if let text = options.positional.first {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            guard let parsed = formatter.date(from: text) else { fail("Dates look like 2026-10-30.") }
            day = parsed
        }
        let entries = try await archive.entries(on: day)
        note(archive.fileURL(for: day).path)
        for entry in entries {
            print(try DictationTranscriptArchive.line(for: entry))
        }
        if entries.isEmpty { note("(no dictations that day)") }
    }

    // MARK: helpers

    /// Diagnostics go to stderr so stdout stays just the result; flush stdout first so a combined log reads in order.
    static func note(_ text: String) {
        fflush(stdout)
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// `--flag`, `--key value` and positional arguments.
    struct Options {
        var positional: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        static let valued: Set<String> = ["app", "bundle", "site", "before", "after", "vocab", "wait", "role", "subrole", "file",
                                          "dir", "config", "settings", "language"]

        init(_ args: [String]) {
            var index = 0
            while index < args.count {
                let arg = args[index]
                if arg.hasPrefix("--") {
                    let name = String(arg.dropFirst(2))
                    if Self.valued.contains(name), index + 1 < args.count {
                        values[name] = args[index + 1]
                        index += 1
                    } else {
                        flags.insert(name)
                    }
                } else {
                    positional.append(arg)
                }
                index += 1
            }
        }

        func flag(_ name: String) -> Bool { flags.contains(name) }
        func value(_ name: String) -> String? { values[name] }
    }
}
