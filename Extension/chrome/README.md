# OpenClicky browser extension

Chrome (MV3) extension that lets OpenClicky's agents act in pages you're signed into. It talks to OpenClicky through
the native-messaging host `OpenClickyBrowserHost` (host name `com.openclicky.browser`). How the pieces fit, the wire
protocols and the agent-facing `browser` tool are described in [docs/browser-bridge.md](../../docs/browser-bridge.md).

Extension ID: `emfgfcpifjoglbdkhjnnmokbagmgmlem`, fixed by the public key in `manifest.json` (`key`). The private key
is not in the repository; loading unpacked needs only the public key.

## Try it

```sh
swift build
.build/debug/occtl browser install-host   # host manifest for each installed Chromium browser
.build/debug/occtl browser mcp-serve      # the bridge and MCP server (or run OpenClicky)
```

Then open `chrome://extensions` (or `arc://extensions`, `brave://extensions`, `edge://extensions`), turn on Developer
mode, choose **Load unpacked** and pick this folder. The toolbar badge shows `off` while the host can't be reached,
`…` while OpenClicky isn't running, `stop` while you have paused agents with Stop, and nothing once connected. `occtl browser status` lists connected browsers;
`occtl browser call tabs` and `occtl browser call read` go through the same MCP tool agents use.

## Files

- `manifest.json`: permissions `nativeMessaging`, `tabs`, `scripting`, `storage`, `alarms`, host access to all URLs.
- `background.js`: service worker: native port with reconnect, command dispatcher, tab operations.
- `page-agent.js`: injected into pages on demand: reading, element refs, click/type/select/scroll/press.
- `policy.js`: URL rules shared by the worker (only http(s) pages; no credentials in URLs) and the paused message.
- `popup.html`, `popup.js`: status, Stop / Resume, Open OpenClicky, Reconnect. Stop pauses agent control of this
  browser profile until Resume, and the pause survives restarts.
- `tests/`: end-to-end script, its test pages, node unit tests (`policy.test.mjs`, `background.test.mjs` with a fake `chrome`) and an MCP SDK conformance check. Not used by the extension; leave the
  folder out when packaging for a store.
