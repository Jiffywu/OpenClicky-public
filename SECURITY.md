# Security

OpenClicky is under development. There are no supported stable release branches yet. Report the commit or app build you tested so a finding can be checked against the same version.

## Reporting a vulnerability

Use GitHub's private vulnerability-reporting form on this repository's Security tab when available. If no private form is offered, open an issue asking for a private contact channel without including exploit details, credentials or private data. Do not attach raw diagnostic bundles, screenshots, audio or transcripts to public issues.

Include the affected version, required permissions, steps to reproduce, observed impact and a minimal example using synthetic data. Redact account details and secrets before sharing any evidence.

## Trust and permissions

OpenClicky can use the microphone, capture the screen, control apps, and act in signed-in browser tabs when those capabilities are enabled. Connected MCP servers and agent skills are code and services you choose to trust. Only connect sources you intend to give those capabilities to.

Agent jobs default to Ask mode. Full access disables the harness's normal permission prompts and gives jobs broad access to the Mac. Shell approval settings do not provide a separate confirmation step for every browser or connected-app operation.

Browser changes require a fresh approval before dispatch, including opening or closing a tab, navigation, typing, clicks and batches. In the app, the job's user controls show the operation, target page and arguments with Allow this action and Don't allow. There is no Always allow option for browser changes, and the model's `sessions_answer_request` tool cannot approve them. Reads remain available without a change approval. Declined or cancelled changes are not dispatched, and a changed target URL or turn expires the approval.

The standalone `occtl browser mcp-serve` server refuses changes by default. `--confirm-writes` requires an interactive terminal and a unique typed confirmation for each operation or batch. Full access in the agent harness does not bypass the browser approval gate. Treat website text as untrusted, supervise consequential work, and use the extension's Stop control to suspend browser access.

Provider keys belong in macOS Keychain. Committed configs should contain credential names and public example endpoints. Never force-add ignored evidence or local secrets. See [data handling](PRIVACY.md) and [the fixture policy](docs/testing.md#private-evidence-and-test-fixtures).
