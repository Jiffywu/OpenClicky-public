import Foundation

/// One finding from validating a config. Errors stop OpenClicky from starting that slot; warnings say what the
/// user loses with their choice.
public struct ConfigIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var slot: SlotID?
    public var message: String

    public var description: String {
        "\(severity.rawValue)\(slot.map { " [\($0.rawValue)]" } ?? ""): \(message)"
    }
}

/// Checks that every slot holds a model of the right kind, served by a configured provider whose dialect can
/// serve it, with the capabilities the slot requires, and that the credentials it names exist.
public struct ConfigValidator: Sendable {
    public var catalog: ModelCatalog
    public var credentials: (any CredentialStore)?

    public init(catalog: ModelCatalog, credentials: (any CredentialStore)? = nil) {
        self.catalog = catalog
        self.credentials = credentials
    }

    public func validate(_ config: OpenClickyConfig) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        let catalog = self.catalog.merging(config.models)

        let duplicateIDs = Dictionary(grouping: config.providers, by: \.id).filter { $0.value.count > 1 }.keys
        for id in duplicateIDs.sorted() {
            issues.append(.init(severity: .error, slot: nil, message: "Provider id \"\(id)\" is defined more than once."))
        }
        var checkedCredentials = Set<String>()
        for provider in config.providers {
            issues += validate(provider, skipCredential: provider.credential.map { !checkedCredentials.insert($0).inserted } ?? true)
        }

        for slot in SlotID.allCases {
            guard let selection = config.slots[slot] else {
                if !slot.isOptional {
                    issues.append(.init(severity: .error, slot: slot, message: "No model chosen for this slot."))
                }
                continue
            }
            issues += validate(selection, for: slot, in: config, catalog: catalog)
        }
        return issues
    }

    private func validate(_ provider: ProviderConfig, skipCredential: Bool) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        if provider.dialect == .harnessLogin {
            // The harness signs in by itself; OpenClicky never sends a key or picks an endpoint for it.
            if provider.credential != nil {
                issues.append(.init(severity: .warning, slot: nil,
                    message: "Provider \"\(provider.id)\" uses the harness's own sign-in; its credential is ignored."))
            }
            return issues
        }
        if provider.dialect.needsBaseURL {
            guard let url = provider.baseURL, let scheme = url.scheme?.lowercased() else {
                return [.init(severity: .error, slot: nil, message: "Provider \"\(provider.id)\" needs a baseURL.")]
            }
            let isLocal = ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
            let insecure = scheme == "http" || scheme == "ws"
            if insecure && !isLocal {
                issues.append(.init(severity: .error, slot: nil,
                    message: "Provider \"\(provider.id)\" sends credentials over unencrypted \(scheme)://. Use https/wss, or a localhost server."))
            }
        }
        if !skipCredential, let name = provider.credential, let store = credentials {
            do {
                if try store.secret(named: name) == nil {
                    issues.append(.init(severity: .error, slot: nil, message: CredentialError.missing(name).description))
                }
            } catch {
                issues.append(.init(severity: .error, slot: nil, message: "Could not read credential \"\(name)\": \(error)"))
            }
        }
        return issues
    }

    private func validate(_ selection: SlotSelection, for slot: SlotID, in config: OpenClickyConfig, catalog: ModelCatalog) -> [ConfigIssue] {
        func error(_ message: String) -> ConfigIssue { .init(severity: .error, slot: slot, message: message) }
        func warning(_ message: String) -> ConfigIssue { .init(severity: .warning, slot: slot, message: message) }

        guard let provider = config.provider(selection.provider) else {
            return [error("Provider \"\(selection.provider)\" is not configured.")]
        }
        let requirement = slot.requirement
        let dialect = provider.dialect

        if dialect == .harnessLogin {
            return validateHarnessLogin(selection, for: slot, catalog: catalog)
        }

        // A dialect that can't produce the slot's kind is wrong before we even look at the model.
        guard !dialect.servableKinds.isDisjoint(with: requirement.kinds) else {
            let wanted = requirement.kinds.map(\.phrase).sorted().joined(separator: " or ")
            return [error("Provider \"\(provider.id)\" speaks \(dialect.rawValue), which can't serve a \(wanted).")]
        }
        guard dialect.canFill(slot) else {
            return [error("Provider \"\(provider.id)\" speaks \(dialect.rawValue), which OpenClicky can't use for the \(slot.rawValue) slot.")]
        }

        guard let model = catalog.model(selection.model, servedBy: dialect) else {
            let known = catalog.models(named: selection.model)
            if let other = known.first {
                if !requirement.kinds.contains(other.kind) {
                    return [error("\"\(other.id)\" is a \(other.kind.phrase); the \(slot.rawValue) slot needs a \(requirement.kinds.map(\.phrase).sorted().joined(separator: " or ")).")]
                }
                return [error("\"\(other.id)\" is not served by \(dialect.rawValue) providers (it is served by \(other.dialects.map(\.rawValue).sorted().joined(separator: ", "))).")]
            }
            return [error("Unknown model \"\(selection.model)\". Declare it under \"models\" with its kind and capabilities.")]
        }

        var issues: [ConfigIssue] = []
        if !requirement.kinds.contains(model.kind) {
            issues.append(error("\"\(model.id)\" is a \(model.kind.phrase); the \(slot.rawValue) slot needs a \(requirement.kinds.map(\.phrase).sorted().joined(separator: " or "))."))
            return issues
        }
        let missing = requirement.required.subtracting(model.capabilities)
        if !missing.isEmpty {
            issues.append(error("\"\(model.id)\" lacks \(missing.sorted().map(\.rawValue).joined(separator: ", ")), which the \(slot.rawValue) slot requires."))
        }
        for (capability, loss) in requirement.preferred.sorted(by: { $0.key < $1.key }) where !model.has(capability) {
            issues.append(warning("\"\(model.id)\" has no \(capability.rawValue): \(loss)."))
        }

        switch slot {
        case .agent:
            guard let harness = selection.harness else {
                issues.append(error("The agent slot needs a harness (\(HarnessKind.allCases.map(\.rawValue).joined(separator: " or ")))."))
                break
            }
            if !harness.supportedDialects.contains(dialect) {
                issues.append(error("The \(harness.rawValue) harness can't use \(dialect.rawValue) providers; it needs \(harness.supportedDialects.map(\.rawValue).sorted().joined(separator: " or "))."))
            }
        case .voice:
            if selection.harness != nil { issues.append(warning("A harness only applies to the agent slot; ignored here.")) }
            if let voice = selection.voice, let voices = model.voices, !voices.contains(voice) {
                issues.append(error("\"\(model.id)\" has no voice \"\(voice)\" (it has \(voices.joined(separator: ", ")))."))
            }
        default:
            if selection.harness != nil { issues.append(warning("A harness only applies to the agent slot; ignored here.")) }
        }
        return issues
    }

    /// The harness's own login: only the agent slot, always with a harness. The model may be "default" (the
    /// harness picks) or any name the harness accepts; a model the catalog knows must still fit the slot.
    private func validateHarnessLogin(_ selection: SlotSelection, for slot: SlotID, catalog: ModelCatalog) -> [ConfigIssue] {
        func error(_ message: String) -> ConfigIssue { .init(severity: .error, slot: slot, message: message) }
        guard slot == .agent else {
            return [error("\(ProviderDialect.harnessLogin.rawValue) is an agent harness's own sign-in and only fills the agent slot.")]
        }
        guard selection.harness != nil else {
            return [error("The agent slot needs a harness (\(HarnessKind.allCases.map(\.rawValue).joined(separator: " or "))).")]
        }
        let id = selection.model.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id != "default", let known = catalog.models(named: id).first else { return [] }
        let requirement = slot.requirement
        guard requirement.kinds.contains(known.kind) else {
            return [error("\"\(known.id)\" is a \(known.kind.phrase); the \(slot.rawValue) slot needs a \(requirement.kinds.map(\.phrase).sorted().joined(separator: " or ")).")]
        }
        let missing = requirement.required.subtracting(known.capabilities)
        if !missing.isEmpty {
            return [error("\"\(known.id)\" lacks \(missing.sorted().map(\.rawValue).joined(separator: ", ")), which the \(slot.rawValue) slot requires.")]
        }
        return []
    }
}
