import Foundation
import OpenClickyKit

/// `occtl voices …`: the voice picker's list and preview clips, without playing anything.
enum VoicesCommands {
    static let usageText = """
        Usage:
          occtl voices list [--config c.json]                      voices the voice slot's model offers
          occtl voices preview [--config c.json] [--voice v] [--no-cache] --out f.wav [text]
                                                                   render a preview clip through the voice slot
        Previews are cached in \(VoicePreviewRenderer.defaultCacheDirectory.path); --out copies the clip;
        --no-cache renders fresh and leaves the cache alone.
        """

    static let voices = OcctlCommand(name: "voices", usage: "voices <list|preview>  the voice picker: voices and preview clips") { args in
        guard let verb = args.first else { fail(usageText) }
        var configPath: String?
        var voice: String?
        var outPath: String?
        var noCache = false
        var words: [String] = []
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--config":
                index += 1
                guard index < args.count else { fail("--config needs a value") }
                configPath = args[index]
            case "--voice":
                index += 1
                guard index < args.count else { fail("--voice needs a value") }
                voice = args[index]
            case "--out":
                index += 1
                guard index < args.count else { fail("--out needs a value") }
                outPath = args[index]
            case "--no-cache": noCache = true
            default: words.append(args[index])
            }
            index += 1
        }
        let config = try EngineCommands.loadConfig(configPath, fallback: .heyClickyLike)
        let catalog = try ModelCatalog.builtIn().merging(config.models)
        let factory = EngineFactory(config: config, catalog: catalog, credentials: CoreCommands.store)
        let resolution = try factory.resolve(.voice)
        guard let provider = resolution.provider else { fail("The voice slot has no provider.") }

        switch verb {
        case "list", "ls":
            let model = catalog.model(resolution.selection.model, servedBy: provider.dialect)
            var options: [VoiceOption]
            if let fixed = VoiceCatalog.fixedOptions(for: model) {
                options = fixed
            } else if provider.dialect == .appleSpeechSynthesis {
                options = VoiceCatalog.installedVoices()
            } else if provider.dialect == .elevenLabsSpeech {
                let key = try provider.credential.flatMap { try CoreCommands.store.secret(named: $0) }
                options = try await VoiceCatalog.elevenLabsVoices(context: ProviderContext(provider: provider, apiKey: key))
            } else {
                options = []
            }
            print("\(provider.id) · \(resolution.selection.model): \(options.count) voice\(options.count == 1 ? "" : "s")")
            for option in options {
                let chosen = option.id == resolution.selection.voice ? "*" : " "
                print("\(chosen) \(option.name)  \(option.id == option.name ? "" : "[\(option.id)]")  \(option.detail ?? "")")
            }
        case "preview":
            guard let outPath else { fail("Usage: occtl voices preview [--config c.json] [--voice v] --out f.wav [text]") }
            // --no-cache neither reads nor writes the preview cache.
            let renderer = try VoicePreviewRenderer.forVoiceSlot(factory, cacheDirectory: noCache ? nil : VoicePreviewRenderer.defaultCacheDirectory)
            let text = words.isEmpty ? VoicePreviewRenderer.sampleLine : words.joined(separator: " ")
            let started = Date()
            let preview = try await renderer.render(voice: voice ?? resolution.selection.voice, text: text, useCache: !noCache)
            let out = URL(fileURLWithPath: outPath)
            try preview.wavData.write(to: out)
            let source = preview.fromCache ? "from the cache" :
                String(format: "first audio after %.2f s, done in %.2f s", preview.firstAudioSeconds ?? 0, Date().timeIntervalSince(started))
            print(String(format: "Wrote %.1f s at %d Hz to %@ (%@; voice %@).", preview.duration, preview.format.sampleRate, outPath, source,
                         preview.voice ?? "default"))
        default:
            fail(usageText)
        }
    }
}
