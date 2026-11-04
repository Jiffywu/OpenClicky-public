# Data handling in OpenClicky

These notes describe the development app's data handling. The models, providers, agent harnesses and connected apps you configure determine which external services receive your requests.

## Data sent to services

Depending on the enabled feature, requests can include microphone audio, transcribed or typed questions, screenshots, selected app or browser content, conversation context, memory, files and connected-app results. Background jobs can receive screen attachments and use the connected services offered to them. Review the provider and harness configuration before working with private content.

Bring-your-own-key operation does not make a cloud provider local. Each external service applies its own terms and retention rules. OpenClicky cannot guarantee that a provider or connected app deletes data sent to it.

## Local data

The default data directory is `~/Library/Application Support/OpenClicky/`. Feature stores can keep configuration, conversation history, brain sessions, screenshots and drawing lessons, memory, job state and transcripts, dictation history, usage and connector settings. Agent job files may also live in the folders selected for those jobs. Environment overrides and CLI options can select other locations.

Provider credentials are stored in macOS Keychain. Development environment variables can override those saved credentials. Config files normally refer to credentials by name; custom provider headers and endpoints can themselves contain private values, so treat your real configuration as private.

Use the app's history and memory controls for the data they manage. Clearing one store does not imply that every other store, job folder, diagnostic export, backup or provider copy has been erased. Review each location before sharing or deleting it. Do not remove a running job's files as a privacy-cleanup shortcut.

## Diagnostics and repository files

Diagnostic exports redact common credential formats, provider headers and selected transcript content. Redaction is not a substitute for reviewing the actual export before sharing it. Do not publish raw captures, recordings, transcripts or account data.

This public repository was created from a cleaned source snapshot with new Git history. It does not include the original archive's branches, commits, PR records or evidence files. The original archive stays private.

Generated evidence is ignored under `docs/evidence/` and other local output paths. The committed [test fixtures](Tests/Fixtures/README.md) use reviewed, non-private inputs. Review new exports before sharing them. A normal deletion commit cannot erase an accidental disclosure from older commits, clones or GitHub caches, so report any such disclosure privately.
