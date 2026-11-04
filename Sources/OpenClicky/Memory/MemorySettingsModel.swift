import AppKit
import Observation
import OpenClickyKit

/// State behind Settings → Memory. Reads the memory folder fresh on every reload, so edits made in a text editor or
/// with `occtl memory` show up when the pane is opened or reloaded.
@MainActor
@Observable
final class MemorySettingsModel {
    enum AddKind: String, CaseIterable, Identifiable {
        case fact, preference, event, standing
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    let store: MemoryStore
    private(set) var snapshot = MemorySnapshot()
    /// The profile as typed in the editor.
    var profileDraft = ""
    /// The profile as it is on disk.
    private(set) var savedProfile = ""
    /// The last thing that happened, shown under the pane ("Forgot …", "Saved.").
    private(set) var message: String?
    private(set) var messageIsError = false
    private var loaded = false

    init(store: MemoryStore = MemoryStore()) {
        self.store = store
    }

    var profileIsDirty: Bool { profileDraft != savedProfile }

    /// Loads once; later calls do nothing. The pane calls it when it appears.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    /// Reads the folder again. An unsaved profile draft is kept.
    func reload() {
        do {
            snapshot = try store.snapshot()
            let text = snapshot.profile.text
            if !profileIsDirty { profileDraft = text }
            savedProfile = text
        } catch {
            report("Couldn't read memory: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Profile

    func saveProfile() {
        do {
            let redactions = try store.replaceProfile(with: profileDraft)
            profileDraft = try store.profileText()
            reload()
            report(redactions == 0 ? "Profile saved."
                   : "Profile saved. \(redactions) thing\(redactions == 1 ? "" : "s") that looked like a password or key \(redactions == 1 ? "was" : "were") removed.")
        } catch {
            report("Couldn't save the profile: \(error.localizedDescription)", isError: true)
        }
    }

    func revertProfile() {
        profileDraft = savedProfile
        message = nil
    }

    // MARK: - Items

    /// Memories newest first, or the best matches for `query`.
    func memories(matching query: String) -> [MemoryEntry] {
        guard !MemoryRanker.terms(query).isEmpty else { return snapshot.memoryEntries }
        return MemoryRanker().rank(snapshot.memoryEntries, query: query, now: Date()).map(\.entry)
    }

    /// Returns true when the text was kept (so the field can be cleared).
    @discardableResult
    func add(_ text: String, as kind: AddKind) -> Bool {
        do {
            let outcome = switch kind {
            case .standing: try store.addStanding(text)
            case .fact: try store.save(text, kind: .fact, source: .user)
            case .preference: try store.save(text, kind: .preference, source: .user)
            case .event: try store.save(text, kind: .event, source: .user)
            }
            reload()
            switch outcome {
            case .saved(let entry):
                report("Remembered: \(entry.text)")
                return true
            case .alreadyKnown(let entry):
                report("Already remembered: \(entry.text)")
                return true
            case .refused(let reason):
                report("Not saved: \(reason).", isError: true)
                return false
            }
        } catch {
            report("Couldn't save: \(error.localizedDescription)", isError: true)
            return false
        }
    }

    func forget(_ entry: MemoryEntry) {
        do {
            if try store.forget(id: entry.id) != nil {
                report("Forgot: \(entry.text)")
            } else {
                report("That was already gone.")
            }
            reload()
        } catch {
            report("Couldn't forget it: \(error.localizedDescription)", isError: true)
        }
    }

    func forgetEverything() {
        do {
            try store.forgetEverything()
            profileDraft = MemoryProfile.template.text
            reload()
            report("OpenClicky forgot everything it knew about you.")
        } catch {
            report("Couldn't delete the memory files: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Files

    /// Opens a memory file in the user's editor for markdown (creating it from the current contents first).
    func open(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            // Writing the profile through the store creates the folder with private permissions.
            if url == store.profileURL { _ = try? store.replaceProfile(with: savedProfile) }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            revealFolder()
        }
    }

    func revealFolder() {
        let directory = store.directory
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            report("Nothing is saved yet, so there is no folder to show.")
        }
    }

    private func report(_ text: String, isError: Bool = false) {
        message = text
        messageIsError = isError
    }
}
