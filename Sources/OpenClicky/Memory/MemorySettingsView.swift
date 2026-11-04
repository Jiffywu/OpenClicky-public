import OpenClickyKit
import SwiftUI

/// Settings → Memory: see, edit and forget what OpenClicky remembers about the user.
///
/// Add it to the Settings window as a tab:
/// `MemorySettingsView().tabItem { Label("Memory", systemImage: "brain.head.profile") }`
struct MemorySettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case profile = "Profile"
        case memories = "Memories"
        case standing = "Standing context"
        case howTos = "How-tos"
        var id: Self { self }
    }

    @ViewState private var model: MemorySettingsModel
    @ViewState private var page: Page
    @ViewState private var confirmingForgetAll = false

    init(store: MemoryStore = MemoryStore(), page: Page = .profile) {
        _model = ViewState(wrappedValue: MemorySettingsModel(store: store))
        _page = ViewState(wrappedValue: page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Show", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch page {
                case .profile: MemoryProfilePage(model: model)
                case .memories: MemoryListPage(model: model)
                case .standing: StandingContextPage(model: model)
                case .howTos: HowToPage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let message = model.message {
                Label(message, systemImage: model.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(model.messageIsError ? Color.orange : Color.secondary)
                    .lineLimit(2)
            }

            Divider()
            HStack {
                Label("Kept only on this Mac, in plain files you can edit.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reload") { model.reload() }
                Button("Show in Finder") { model.revealFolder() }
                Button("Forget everything…", role: .destructive) { confirmingForgetAll = true }
            }
        }
        .padding(20)
        .onAppear { model.loadIfNeeded() }
        .confirmationDialog("Forget everything OpenClicky remembers about you?", isPresented: $confirmingForgetAll) {
            Button("Forget everything", role: .destructive) { model.forgetEverything() }
        } message: {
            Text("This deletes your profile, standing context, how-tos and every memory. It can't be undone.")
        }
    }
}

// MARK: - Profile

private struct MemoryProfilePage: View {
    @Bindable var model: MemorySettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What OpenClicky knows about you, from about-the-user.md. \"## \" starts a section and \"- \" starts an item. Delete a line and it's forgotten. Items under \"# Right now\" are trimmed first when the profile grows.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $model.profileDraft)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Text("\(model.snapshot.profile.bullets.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open in Editor") { model.open(model.store.profileURL) }
                Button("Revert") { model.revertProfile() }
                    .disabled(!model.profileIsDirty)
                Button("Save") { model.saveProfile() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.profileIsDirty)
            }
        }
    }
}

// MARK: - Memories

private struct MemoryListPage: View {
    let model: MemorySettingsModel
    @ViewState private var query = ""

    var body: some View {
        let entries = model.memories(matching: query)
        VStack(alignment: .leading, spacing: 8) {
            MemoryAddField(model: model, kinds: [.fact, .preference, .event], placeholder: "Remember something about you…")
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search memories", text: $query)
                    .textFieldStyle(.roundedBorder)
            }
            if entries.isEmpty {
                MemoryEmptyNote(text: query.isEmpty
                    ? "No memories yet. OpenClicky saves one when you ask it to remember something, and writes a short note after each conversation."
                    : "Nothing remembered matches that.")
            } else {
                List(entries) { entry in
                    MemoryEntryRow(entry: entry, detail: detail(entry)) { model.forget(entry) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private func detail(_ entry: MemoryEntry) -> String {
        var parts: [String] = []
        if let date = entry.date { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if case .memory(.session) = entry.place { parts.append("conversation note") } else { parts.append(entry.place.label) }
        parts.append(entry.id)
        return parts.joined(separator: " · ")
    }
}

// MARK: - Standing context

private struct StandingContextPage: View {
    let model: MemorySettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Requests OpenClicky follows in every conversation, like \"answer in British English\".")
                .font(.callout)
                .foregroundStyle(.secondary)
            MemoryAddField(model: model, kinds: [.standing], placeholder: "Always…")
            if model.snapshot.standingEntries.isEmpty {
                MemoryEmptyNote(text: "No standing requests. Tell OpenClicky \"from now on…\" or add one here.")
            } else {
                List(model.snapshot.standingEntries) { entry in
                    MemoryEntryRow(entry: entry, detail: entry.id) { model.forget(entry) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            HStack {
                Spacer()
                Button("Open in Editor") { model.open(model.store.standingURL) }
            }
        }
    }
}

// MARK: - How-tos

private struct HowToPage: View {
    let model: MemorySettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steps OpenClicky worked out for tasks you're likely to ask for again.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.snapshot.howTos.isEmpty {
                MemoryEmptyNote(text: "No how-tos yet. They're written at the end of a conversation where OpenClicky figured out how to do something for you.")
            } else {
                List(model.snapshot.howTos) { howTo in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(howTo.title).font(.headline)
                            if !howTo.steps.isEmpty {
                                Text(howTo.steps).font(.callout).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        MemoryForgetButton {
                            model.forget(MemoryEntry(id: howTo.id, text: howTo.title, place: .howTo))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
            HStack {
                Spacer()
                Button("Open in Editor") { model.open(model.store.howTosURL) }
            }
        }
    }
}

// MARK: - Pieces

private struct MemoryAddField: View {
    let model: MemorySettingsModel
    let kinds: [MemorySettingsModel.AddKind]
    let placeholder: String
    @ViewState private var draft = ""
    @ViewState private var kind: MemorySettingsModel.AddKind?

    var body: some View {
        HStack {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            if kinds.count > 1 {
                Picker("Kind", selection: Binding(get: { kind ?? kinds[0] }, set: { kind = $0 })) {
                    ForEach(kinds) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Button("Add", action: add)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func add() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.add(draft, as: kind ?? kinds[0]) { draft = "" }
    }
}

private struct MemoryEntryRow: View {
    let entry: MemoryEntry
    let detail: String
    let forget: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text).textSelection(.enabled)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MemoryForgetButton(action: forget)
        }
        .padding(.vertical, 2)
    }
}

private struct MemoryForgetButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Forget this")
        .accessibilityLabel("Forget")
    }
}

private struct MemoryEmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.vertical, 40)
    }
}
