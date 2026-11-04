// node --test Extension/chrome/tests/policy.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkOpenURL, isScriptableURL, PAUSED_MESSAGE } from "../policy.js";

test("only http(s) pages are scriptable", () => {
  assert.equal(isScriptableURL("https://example.com/a"), true);
  assert.equal(isScriptableURL("HTTP://127.0.0.1:8765/page.html"), true);
  // A local file open in a tab must not be readable by an agent, even with "Allow access to file URLs" on.
  assert.equal(isScriptableURL("file:///Users/someone/.ssh/id_ed25519.pub"), false);
  assert.equal(isScriptableURL("chrome://settings"), false);
  assert.equal(isScriptableURL("chrome-extension://emfgfcpifjoglbdkhjnnmokbagmgmlem/popup.html"), false);
  assert.equal(isScriptableURL("data:text/html,<p>x</p>"), false);
  assert.equal(isScriptableURL("about:blank"), false);
  assert.equal(isScriptableURL(""), false);
  assert.equal(isScriptableURL(undefined), false);
});

test("open and navigate accept http(s) without credentials, and about:blank", () => {
  assert.doesNotThrow(() => checkOpenURL("https://example.com"));
  assert.doesNotThrow(() => checkOpenURL("about:blank"));
  assert.throws(() => checkOpenURL("file:///etc/hosts"), /Only http\(s\)/);
  assert.throws(() => checkOpenURL("javascript:alert(1)"), /Only http\(s\)/);
  assert.throws(() => checkOpenURL("https://user:pw@example.com"), /embedded credentials/);
  assert.throws(() => checkOpenURL("not a url"), /not a valid URL/);
});

test("the paused message tells the agent not to retry", () => {
  assert.match(PAUSED_MESSAGE, /Resume/);
  assert.match(PAUSED_MESSAGE, /Don't retry/);
});
