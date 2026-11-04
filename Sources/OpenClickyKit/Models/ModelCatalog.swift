import Foundation

/// Every model OpenClicky knows the kind and capabilities of: the built-in catalog plus models the user
/// declares in config (local servers, new releases, OpenRouter slugs). A slot can only be filled by a
/// model found here, which is what keeps a speech model out of the brain slot.
public struct ModelCatalog: Sendable {
    public private(set) var models: [ModelDescriptor]

    public init(models: [ModelDescriptor]) { self.models = models }

    /// The catalog shipped inside OpenClickyKit.
    public static func builtIn() throws -> ModelCatalog {
        guard let url = resourceURL("model-catalog", "json") else { throw CocoaError(.fileNoSuchFile) }
        struct File: Decodable { var models: [ModelDescriptor] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return ModelCatalog(models: file.models)
    }

    /// User-declared models win over built-in entries with the same id, so a user can correct a capability.
    public func merging(_ declared: [ModelDescriptor]) -> ModelCatalog {
        let ids = Set(declared.map(\.id))
        return ModelCatalog(models: declared + models.filter { !ids.contains($0.id) })
    }

    /// The descriptor for `id` that the given dialect can serve, if any.
    public func model(_ id: String, servedBy dialect: ProviderDialect) -> ModelDescriptor? {
        let candidates = models.filter { $0.id == id }
        return candidates.first { $0.dialects.isEmpty ? dialect.servableKinds.contains($0.kind) : $0.dialects.contains(dialect) }
    }

    public func models(named id: String) -> [ModelDescriptor] { models.filter { $0.id == id } }

    /// Models a slot would accept from a given dialect, for pickers. Empty when OpenClicky has no adapter for the
    /// dialect in that slot (Gemini Live serves realtime speech models, but only the realtime-voice slot can use them).
    public func candidates(for slot: SlotID, dialect: ProviderDialect) -> [ModelDescriptor] {
        let requirement = slot.requirement
        guard dialect.canFill(slot) else { return [] }
        return models.filter { model in
            (model.dialects.isEmpty || model.dialects.contains(dialect))
                && dialect.servableKinds.contains(model.kind)
                && requirement.kinds.contains(model.kind)
                && requirement.required.isSubset(of: model.capabilities)
        }
    }

    /// Finds a file from OpenClickyKit's resource bundle. Inside OpenClicky.app the bundle is copied to
    /// Contents/Resources (codesign rejects files at the .app root, where SwiftPM's `Bundle.module` looks first and
    /// crashes when it is missing), so look there before falling back to `Bundle.module` for `swift run`/tests.
    public static func resourceURL(_ name: String, _ ext: String) -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "OpenClicky_OpenClickyKit", withExtension: "bundle"),
           let url = Bundle(url: bundleURL)?.url(forResource: name, withExtension: ext) {
            return url
        }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }
}
