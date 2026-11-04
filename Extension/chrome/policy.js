// Pure rules the service worker applies before touching a tab. No chrome.* here, so node can test it
// (Extension/chrome/tests/policy.test.mjs).

/** Pages the agent may read and act in: ordinary web pages only (no file://, chrome://, extension or data pages). */
export function isScriptableURL(url) {
  try {
    return ["http:", "https:"].includes(new URL(String(url ?? "")).protocol);
  } catch {
    return false;
  }
}

/** Throws unless `url` may be opened or navigated to: http(s) without embedded credentials, or about:blank. */
export function checkOpenURL(url) {
  if (url === "about:blank") return;
  let parsed;
  try {
    parsed = new URL(String(url ?? ""));
  } catch {
    throw new Error(`"${url}" is not a valid URL.`);
  }
  if (!["http:", "https:"].includes(parsed.protocol)) throw new Error("Only http(s) pages can be opened.");
  if (parsed.username || parsed.password) throw new Error("URLs with embedded credentials aren't allowed.");
}

/** What an agent's call gets back while the user has paused OpenClicky in this browser. */
export const PAUSED_MESSAGE =
  "The user pressed Stop in the OpenClicky extension, so agents can't use this browser until they press Resume " +
  "in its toolbar menu. Don't retry; tell the user what you still need to do here.";
