// node --test Extension/chrome/tests/background.test.mjs
//
// The service worker against a fake `chrome`: tab ownership, Stop, the turn-end tidy-up and the reconnect sweep.
// Each test loads a fresh copy of background.js (a new module instance) with its own fake browser.
import { test } from "node:test";
import assert from "node:assert/strict";

let loads = 0;

/** A fake browser with tabs 1 (the user's, focused) and 2 (the user's); new tabs are 500, 501 … */
function fakeChrome({ loadingForever = false } = {}) {
  const events = () => {
    const set = new Set();
    return { set, addListener: (f) => set.add(f), removeListener: (f) => set.delete(f) };
  };
  const bag = (store) => ({
    get: async (keys) => {
      const out = {};
      for (const key of typeof keys === "string" ? [keys] : keys) if (key in store) out[key] = structuredClone(store[key]);
      return out;
    },
    set: async (values) => {
      Object.assign(store, structuredClone(values));
    },
  });
  const session = {};
  const tabs = new Map([
    [1, { id: 1, windowId: 1, index: 0, url: "https://mail.example.com/", title: "Mail", status: "complete", active: true, incognito: false }],
    [2, { id: 2, windowId: 1, index: 1, url: "https://shop.example.com/cart", title: "Cart", status: "complete", active: false, incognito: false }],
  ]);
  let nextTab = 500;
  const gets = [];
  const port = { posted: [], onMessage: events(), onDisconnect: events(), postMessage: (m) => port.posted.push(m) };
  const popup = events();
  const chrome = {
    runtime: {
      id: "ext",
      getManifest: () => ({ version: "0.0.0-test" }),
      connectNative: () => port,
      onMessage: popup,
      onStartup: events(),
      onInstalled: events(),
    },
    storage: { local: bag({}), session: bag(session) },
    alarms: { onAlarm: events(), get: async () => ({ name: "openclicky-reconnect" }), create() {} },
    action: { setBadgeText: async () => {}, setBadgeBackgroundColor: async () => {}, setTitle: async () => {} },
    tabs: {
      onUpdated: events(),
      async query(filter = {}) {
        return [...tabs.values()].filter((t) => !filter.active || t.active).map((t) => ({ ...t }));
      },
      async get(id) {
        gets.push(Number(id));
        const tab = tabs.get(Number(id));
        if (!tab) throw new Error(`No tab with id: ${id}.`);
        return { ...tab };
      },
      async create({ url, windowId, index }) {
        const tab = { id: nextTab++, windowId: windowId ?? 1, index: index ?? 0, url, title: "New", active: false, incognito: false };
        tab.status = loadingForever ? "loading" : "complete";
        tabs.set(tab.id, tab);
        return { ...tab };
      },
      async remove(id) {
        tabs.delete(Number(id));
      },
      async update(id, props) {
        Object.assign(tabs.get(Number(id)), props);
      },
    },
    scripting: { executeScript: async () => [{ result: { result: { found: false, elements: [] } } }] },
  };
  return { chrome, port, tabs, session, gets, popup };
}

async function until(check, what) {
  for (let i = 0; i < 400; i++) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** Loads a fresh service worker on `fake` and returns helpers to drive it as the app and the popup would. */
async function load(fake) {
  globalThis.chrome = fake.chrome;
  loads += 1;
  await import(`../background.js?load=${loads}`);
  await until(() => fake.port.onMessage.set.size > 0, "the native port");
  let nextID = 0;
  const command = async (operation, args = {}, task = "") => {
    const id = `c${++nextID}`;
    for (const listener of fake.port.onMessage.set) listener({ type: "command", id, operation, args, task, groupTitle: "Job" });
    await until(() => fake.port.posted.some((m) => m.id === id), `the answer to ${operation}`);
    return fake.port.posted.find((m) => m.id === id);
  };
  const popup = (kind) =>
    new Promise((resolve) => {
      for (const listener of fake.popup.set) listener({ kind }, { id: "ext" }, resolve);
    });
  return { command, popup };
}

test("an agent's close only closes a tab its job opened, whatever else it sends", async () => {
  const fake = fakeChrome();
  const { command } = await load(fake);
  const opened = await command("open", { url: "https://example.com/a" }, "job-1");
  assert.equal(opened.ok, true);
  const tab = opened.result.tabId;

  // tabIds (the tidy-up's list) is ignored without tidy, so the user's tabs can't ride along with an owned one.
  const smuggled = await command("close", { tabId: tab, tabIds: [1, 2] }, "job-1");
  assert.deepEqual(smuggled.result.closed, [tab]);
  assert.ok(fake.tabs.has(1) && fake.tabs.has(2), "the user's tabs are still open");

  const user = await command("close", { tabId: 2 }, "job-1");
  assert.equal(user.ok, false);
  assert.match(user.error, /isn't one this job opened/);
  // An unbound call (no task) can't close the user's tab either.
  assert.equal((await command("close", { tabId: 2 }, "")).ok, false);
  assert.ok(fake.tabs.has(2));

  // Keeping the user's tab doesn't make it a job's.
  assert.equal((await command("keep", { tabId: 2, why: "result" }, "job-1")).ok, true);
  assert.equal((await command("close", { tabId: 2 }, "job-1")).ok, false);
  assert.ok(fake.tabs.has(2));
});

test("the turn-end tidy-up skips tabs its job doesn't own instead of closing them", async () => {
  const fake = fakeChrome();
  const { command } = await load(fake);
  const mine = (await command("open", { url: "https://example.com/a" }, "job-1")).result.tabId;
  const other = (await command("open", { url: "https://example.com/b" }, "job-2")).result.tabId;
  const tidy = await command("close", { tabIds: [mine, other, 2], tidy: true }, "job-1");
  assert.equal(tidy.ok, true);
  assert.deepEqual(tidy.result.closed, [mine]);
  assert.deepEqual(tidy.result.skipped, [other, 2]);
  assert.ok(fake.tabs.has(other) && fake.tabs.has(2));
});

test("after Stop a job's tabs are the user's: neither the tidy-up nor a reconnect sweep closes them", async () => {
  const fake = fakeChrome();
  const { command, popup } = await load(fake);
  const tab = (await command("open", { url: "https://shop.example.com/checkout" }, "job-1")).result.tabId;

  // Stop between calls: the app hears it at once, and a call while paused says why it was refused.
  await popup("stop");
  assert.ok(fake.port.posted.some((m) => m.type === "stop"));
  const refused = await command("tabs", {}, "job-1");
  assert.equal(refused.ok, false);
  assert.equal(refused.code, "paused");
  await popup("resume");

  const tidy = await command("close", { tabIds: [tab], tidy: true }, "job-1");
  assert.deepEqual(tidy.result.closed, []);
  assert.deepEqual(tidy.result.skipped, [tab]);
  const sweep = await command("sweep", { running: [] });
  assert.deepEqual(sweep.result.closed, []);
  assert.ok(fake.tabs.has(tab), "the tab the user took over is still open");
});

test("a reconnect sweep still closes the unkept tabs of jobs that ended", async () => {
  const fake = fakeChrome();
  const { command } = await load(fake);
  const ended = (await command("open", { url: "https://example.com/a" }, "job-1")).result.tabId;
  const kept = (await command("open", { url: "https://example.com/b" }, "job-1")).result.tabId;
  await command("keep", { tabId: kept, why: "result" }, "job-1");
  const running = (await command("open", { url: "https://example.com/c" }, "job-2")).result.tabId;
  const sweep = await command("sweep", { running: ["job-2"] });
  assert.deepEqual(sweep.result.closed, [ended]);
  assert.ok(fake.tabs.has(kept) && fake.tabs.has(running));
});

test("an open whose page never finishes loading still answers with its tab", async () => {
  const fake = fakeChrome({ loadingForever: true });
  const { command } = await load(fake);
  const realNow = Date.now;
  try {
    const answer = command("open", { url: "https://slow.example.com/" }, "job-1");
    // Once the load wait has started on the new tab, jump past its 45 s deadline.
    await until(() => fake.gets.includes(500), "the load wait");
    Date.now = () => realNow() + 46_000;
    const opened = await answer;
    assert.equal(opened.ok, true);
    assert.equal(opened.result.tabId, 500);
    assert.equal(opened.result.loaded, false);
    assert.match(opened.result.note, /didn't finish loading/);
  } finally {
    Date.now = realNow;
  }
  // The job owns it, so its own close works.
  assert.equal((await command("close", { tabId: 500 }, "job-1")).ok, true);
});
