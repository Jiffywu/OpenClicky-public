# Working on OpenClicky

OpenClicky is a clean-room rebuild of HeyClicky. Read `docs/parity.md` for the subsystem inventory and `docs/re/` for the reverse-engineering notes each feature is built from.

## Clean-room rule
Describe and reimplement behavior. Never paste HeyClicky prompts, JavaScript, shader code, sounds, icons or any passage longer than a short identifier from the HeyClicky bundle. Write prompts and code fresh.

## Building (Command Line Tools only, no Xcode)
- `swift build`, `swift test` (swift-testing: `import Testing`, `@Test`, `#expect`).
- `scripts/build-app.sh [debug|release]` assembles and signs `dist/OpenClicky.app`. Run `scripts/make-signing-identity.sh` once so builds use a stable local identity (keeps macOS permissions across rebuilds without Keychain prompts).
- SwiftUI's `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode. Use `@ViewState` (`Sources/OpenClicky/Support/ViewState.swift`) instead. Avoid `#Preview`, `@Entry` and `@Previewable` for the same reason. `@Observable` works.
- SwiftPM resource bundles are copied to `Contents/Resources`; load resources through `ModelCatalog.resourceURL`-style lookups, never `Bundle.module` alone, or the app crashes outside `swift run`.

## Model slots
Only the parts where HeyClicky gets a model from its server are swappable (`stt`, `voice`, `brain`, `agent`; see `Sources/OpenClickyKit/Models/Slot.swift`). Each slot accepts only the model kinds that fit it. Credentials live in the Keychain; config files only name them.

## Private evidence
Keep generated screenshots, recordings, transcripts, diagnostic bundles and run logs in ignored `docs/evidence/` or `.build/evidence/`. Never force-add them. Tests must use reviewed, non-private inputs in `Tests/Fixtures/`, not a developer's evidence archive. Keep provider keys in Keychain and use credential names in committed example configs. See `docs/testing.md` for the fixture policy.
