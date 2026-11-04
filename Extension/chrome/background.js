// OpenClicky extension service worker.
//
// Keeps a native-messaging port open to the OpenClicky host (com.openclicky.browser), which relays to the app.
// The app sends {type:"command", id, operation, args}; we run the operation against tabs and pages and answer
// {type:"result", id, ok, result | error}. An open native port keeps an MV3 service worker alive; when the port
// drops (host missing, app quit and host exited, browser update) we retry with backoff, and an alarm restarts the
// loop if Chrome has unloaded the worker in between.
//
// Tabs a job opens are its own: they go into a tab group titled for the job (when the browser can group tabs), only
// they can be closed through the tool, and the app closes the ones not kept when the job's turn ends (`close` with
// tabIds) or when the browser reconnects after the job is gone (`sweep`). Ownership is kept in
// chrome.storage.session, so it survives the worker being unloaded but not the browser restarting.
//
// Stop in the toolbar menu pauses agent control of this browser profile until the user presses Resume: the app is
// told at once (in-flight calls fail), and every command that arrives while paused is refused. The pause is kept in
// chrome.storage.local, so it survives the worker being unloaded and the browser restarting. Stop also hands every
// tab a job opened to the user: no tidy-up or later sweep closes them.

import { checkOpenURL, isScriptableURL, PAUSED_MESSAGE } from "./policy.js";

const HOST_NAME = "com.openclicky.browser";
const PROTOCOL = 1;
const VERSION = chrome.runtime.getManifest().version;
const ALARM = "openclicky-reconnect";
const MIN_RETRY_MS = 1000;
const MAX_RETRY_MS = 30000;
const MAX_SCREENSHOT_BASE64 = 12_000_000;

const state = {
  port: null,
  connecting: false,
  hostConnected: false,
  appConnected: false,
  lastError: "",
  retryMs: MIN_RETRY_MS,
  retryTimer: null,
  commandsRun: 0,
  lastCommand: "",
  paused: false,
  problemReported: false,
};

// ---- Tab ownership ----------------------------------------------------------------------------------------

async function loadOwnership() {
  const stored = await chrome.storage.session.get(["owned", "groups"]).catch(() => ({}));
  return { owned: stored.owned ?? {}, groups: stored.groups ?? {} };
}

async function saveOwnership(ownership) {
  await chrome.storage.session.set({ owned: ownership.owned, groups: ownership.groups }).catch(() => {});
}

/** Throws when another job owns the tab. */
async function checkNotForeign(tabId, task) {
  if (!task) return;
  const { owned } = await loadOwnership();
  const owner = owned[tabId]?.task;
  if (owner && owner !== task) throw new Error(`Tab ${tabId} belongs to another OpenClicky job; leave it alone.`);
}

/** Puts a tab into the job's group, creating the group the first time. False when this browser can't group it. */
async function groupForTask(tab, task, title) {
  if (!task || !chrome.tabGroups || !chrome.tabs.group) return false;
  const ownership = await loadOwnership();
  let groupId = ownership.groups[task];
  try {
    if (groupId !== undefined) {
      const group = await chrome.tabGroups.get(groupId).catch(() => null);
      if (!group || group.windowId !== tab.windowId) groupId = undefined;
    }
    if (groupId === undefined) {
      groupId = await chrome.tabs.group({ tabIds: [tab.id], createProperties: { windowId: tab.windowId } });
      await chrome.tabGroups.update(groupId, { title: String(title || "OpenClicky").slice(0, 60), color: "blue", collapsed: false });
    } else {
      await chrome.tabs.group({ tabIds: [tab.id], groupId });
    }
    ownership.groups[task] = groupId;
    await saveOwnership(ownership);
    return true;
  } catch {
    return false;
  }
}

/** An older copy of the extension loaded before the tab-groups permission existed: tell the app once. */
function reportProblems() {
  if (state.problemReported || !state.appConnected) return;
  if (!chrome.tabGroups) {
    state.problemReported = true;
    send({
      type: "event",
      name: "problem",
      reason: "The loaded OpenClicky extension is an older copy without the tab-groups permission. Reload it on the browser's extensions page.",
    });
  }
}

// Commands wait for this, so a worker woken by a command never runs it before the saved pause is known.
const pauseLoaded = chrome.storage.local
  .get("paused")
  .then((stored) => {
    state.paused = Boolean(stored.paused);
  })
  .catch(() => {})
  .finally(() => updateBadge());

async function setPaused(paused) {
  state.paused = paused;
  updateBadge();
  await chrome.storage.local.set({ paused }).catch(() => {});
}

function refuseIfPaused() {
  if (!state.paused) return;
  const error = new Error(PAUSED_MESSAGE);
  error.code = "paused";
  throw error;
}

/** After Stop the tabs jobs opened are the user's: forget who owned them, so nothing closes them later. */
async function releaseOwnedTabs() {
  const ownership = await loadOwnership();
  ownership.owned = {};
  await saveOwnership(ownership);
}

// ---- Connection -------------------------------------------------------------------------------------------

async function profileId() {
  const stored = await chrome.storage.local.get("profileId");
  if (stored.profileId) return stored.profileId;
  const id = crypto.randomUUID();
  await chrome.storage.local.set({ profileId: id });
  return id;
}

async function connect() {
  if (state.port || state.connecting) return;
  state.connecting = true;
  clearTimeout(state.retryTimer);
  state.retryTimer = null;
  try {
    const profile = await profileId();
    const port = chrome.runtime.connectNative(HOST_NAME);
    state.port = port;
    port.onMessage.addListener((message) => onHostMessage(port, message));
    port.onDisconnect.addListener(() => {
      const reason = chrome.runtime.lastError?.message || "The OpenClicky host stopped.";
      if (state.port !== port) return;
      state.port = null;
      state.hostConnected = false;
      state.appConnected = false;
      state.lastError = reason;
      updateBadge();
      scheduleReconnect();
    });
    port.postMessage({ type: "hello", protocol: PROTOCOL, profileId: profile, version: VERSION });
    state.hostConnected = true;
    updateBadge();
  } catch (error) {
    state.port = null;
    state.lastError = String(error?.message ?? error);
    scheduleReconnect();
  } finally {
    state.connecting = false;
  }
}

function scheduleReconnect() {
  if (state.retryTimer) return;
  const delay = state.retryMs;
  state.retryMs = Math.min(state.retryMs * 2, MAX_RETRY_MS);
  state.retryTimer = setTimeout(() => {
    state.retryTimer = null;
    connect();
  }, delay);
}

function send(message) {
  try {
    state.port?.postMessage(message);
  } catch (error) {
    state.lastError = String(error?.message ?? error);
  }
}

function onHostMessage(port, message) {
  if (port !== state.port || !message || typeof message !== "object") return;
  switch (message.type) {
    case "ready":
      state.appConnected = Boolean(message.app);
      if (state.appConnected) {
        state.retryMs = MIN_RETRY_MS;
        state.lastError = "";
      }
      updateBadge();
      reportProblems();
      break;
    case "ping":
      send({ type: "pong" });
      break;
    case "command":
      runCommand(message);
      break;
  }
}

async function runCommand(message) {
  const { id, operation, args = {} } = message;
  const context = { task: typeof message.task === "string" ? message.task : "", groupTitle: message.groupTitle };
  try {
    await pauseLoaded;
    refuseIfPaused();
    state.commandsRun += 1;
    state.lastCommand = operation;
    const handler = OPERATIONS[operation];
    if (!handler) throw new Error(`The extension doesn't support "${operation}".`);
    const result = await handler(args, context);
    send({ type: "result", id, ok: true, result });
  } catch (error) {
    // The app tells a refusal while paused (the user's Stop) apart from an ordinary failure by its code.
    send({ type: "result", id, ok: false, error: String(error?.message ?? error), ...(error?.code ? { code: error.code } : {}) });
  }
}

function updateBadge() {
  let text = "";
  let color = "#2f6fed";
  let title = "OpenClicky: connected";
  if (state.paused) {
    text = "stop";
    color = "#c62828";
    title = "OpenClicky: stopped. Agents can't use this browser until you press Resume in this menu.";
  } else if (!state.hostConnected) {
    text = "off";
    color = "#8a8a8a";
    title = `OpenClicky: not connected (${state.lastError || "host not found"})`;
  } else if (!state.appConnected) {
    text = "…";
    color = "#d98a00";
    title = "OpenClicky: waiting for the OpenClicky app";
  }
  chrome.action.setBadgeText({ text }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ color }).catch(() => {});
  chrome.action.setTitle({ title }).catch(() => {});
}

// ---- Tabs and pages ---------------------------------------------------------------------------------------

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function focusedTab() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (tab) return tab;
  const [any] = await chrome.tabs.query({ active: true });
  return any;
}

async function resolveTab(tabId) {
  let tab;
  if (tabId !== undefined && tabId !== null) {
    tab = await chrome.tabs.get(Number(tabId)).catch(() => null);
    if (!tab) throw new Error(`There is no tab ${tabId}. Use tabs to list them.`);
  } else {
    tab = await focusedTab();
    if (!tab) throw new Error("No tab is focused; pass a tabId from tabs.");
  }
  if (tab.incognito) throw new Error("OpenClicky doesn't work in private windows.");
  return tab;
}

function scriptable(tab) {
  const url = tab.url ?? "";
  if (!isScriptableURL(url)) {
    throw new Error(`OpenClicky can't work inside ${url.split(":")[0] || "this"} pages; only http(s) pages.`);
  }
}

/** Watches a tab for the start of a navigation (a load or a URL change). */
function watchNavigation(tabId) {
  const watch = { happened: false };
  const listener = (id, info) => {
    if (id === tabId && (info.status === "loading" || info.url)) watch.happened = true;
  };
  chrome.tabs.onUpdated.addListener(listener);
  watch.stop = () => chrome.tabs.onUpdated.removeListener(listener);
  return watch;
}

/** Resolves when the tab's status is "complete". With `navigation`, first waits briefly for the load to begin. */
async function waitForLoad(tabId, timeoutMs, navigation = null) {
  const deadline = Date.now() + timeoutMs;
  if (navigation) {
    const startBy = Date.now() + 1500;
    while (!navigation.happened && Date.now() < startBy) await sleep(50);
  }
  while (Date.now() < deadline) {
    const tab = await chrome.tabs.get(tabId);
    if (tab.status === "complete") return tab;
    await new Promise((resolve) => {
      const finish = () => {
        chrome.tabs.onUpdated.removeListener(listener);
        clearTimeout(timer);
        resolve();
      };
      const listener = (id, info) => {
        if (id === tabId && info.status === "complete") finish();
      };
      const timer = setTimeout(finish, Math.max(50, Math.min(500, deadline - Date.now())));
      chrome.tabs.onUpdated.addListener(listener);
    });
  }
  throw new Error(`The page didn't finish loading within ${Math.round(timeoutMs / 1000)} s.`);
}

/** Runs one page-agent operation in the tab's top frame, injecting page-agent.js on first use. */
async function inPage(tabId, operation, args = {}) {
  const tab = await chrome.tabs.get(tabId);
  scriptable(tab);
  const call = () =>
    chrome.scripting.executeScript({
      target: { tabId },
      func: (op, a) => (globalThis.__openclickyAgent ? globalThis.__openclickyAgent.run(op, a) : { missing: true }),
      args: [operation, args],
    });
  let frame;
  try {
    [frame] = await call();
    if (frame?.result?.missing) {
      await chrome.scripting.executeScript({ target: { tabId }, files: ["page-agent.js"] });
      [frame] = await call();
    }
  } catch (error) {
    const text = String(error?.message ?? error);
    if (/error page/i.test(text)) throw new Error("The page didn't load; the browser is showing an error page for it.");
    throw error;
  }
  const value = frame?.result;
  if (!value) throw new Error("The page didn't answer.");
  if (value.error) throw new Error(value.error);
  return value.result;
}

/** After a load: notes when the browser shows its own error page instead of the site. */
async function loadNote(tabId, note) {
  try {
    await inPage(tabId, "hasText", { text: "" });
    return note;
  } catch (error) {
    return /error page/i.test(String(error?.message)) ? `${note} The browser shows an error page: the site didn't load.` : note;
  }
}

async function describe(tabId, extra = {}) {
  const tab = await chrome.tabs.get(tabId);
  return { tabId, title: tab.title ?? "", url: tab.url ?? "", ...extra };
}

/** A page action: run it, then wait for any navigation it caused or for the DOM to settle, and report what changed. */
async function act(args, operation, context = {}) {
  const tab = await resolveTab(args.tabId);
  await checkNotForeign(tab.id, context.task);
  const navigation = watchNavigation(tab.id);
  try {
    let result;
    try {
      result = await inPage(tab.id, operation, args);
    } catch (error) {
      // A click that navigates can unload the page before the script reports back.
      if (!navigation.happened) throw error;
      result = { note: `${operation} done.` };
    }
    await sleep(120);
    let changes;
    if (navigation.happened) {
      await waitForLoad(tab.id, 30000).catch(() => {});
    } else {
      await inPage(tab.id, "settle", {}).catch(() => {});
      if (!args.noDiff) changes = await inPage(tab.id, "changes", {}).then((r) => r.changes ?? undefined).catch(() => undefined);
    }
    return describe(tab.id, { ...result, navigated: navigation.happened, ...(changes ? { changes } : {}) });
  } finally {
    navigation.stop();
  }
}

/** Runs a batch's steps in order in one tab, stopping at the first failure, and answers with one set of changes. */
async function runBatch(args, context) {
  const steps = Array.isArray(args.steps) ? args.steps.slice(0, 20) : [];
  const deadline = Date.now() + Math.max(1000, Number(args.deadlineMs) || 60000);
  let tabId = args.tabId ?? null;
  const done = [];
  const opened = [];
  let navigated = false;
  let failed;
  for (const [index, step] of steps.entries()) {
    if (Date.now() > deadline) {
      failed = index + 1;
      done.push({ operation: step.operation, ok: false, error: "The batch ran out of time before this step." });
      break;
    }
    try {
      refuseIfPaused();
      const handler = BATCH_STEPS[step.operation];
      if (!handler) throw new Error(`${step.operation} can't be a batch step.`);
      const stepArgs = { ...step, tabId: tabId ?? undefined, noDiff: true, noSnapshot: true };
      const result = await handler(stepArgs, context);
      if (step.operation === "open" && result.tabId !== undefined) {
        tabId = result.tabId;
        opened.push(result.tabId);
      } else if (tabId === null && result.tabId !== undefined) {
        tabId = result.tabId;
      }
      if (result.navigated) navigated = true;
      done.push({ operation: step.operation, ok: true, note: result.note ?? "done." });
    } catch (error) {
      failed = index + 1;
      done.push({ operation: step.operation, ok: false, error: String(error?.message ?? error) });
      break;
    }
  }
  const tab = tabId !== null ? await chrome.tabs.get(Number(tabId)).catch(() => null) : await focusedTab();
  let changes;
  if (tab && !navigated) changes = await inPage(tab.id, "changes", {}).then((r) => r.changes ?? undefined).catch(() => undefined);
  return {
    tabId: tab?.id,
    title: tab?.title ?? "",
    url: tab?.url ?? "",
    steps: done,
    total: steps.length,
    ...(failed ? { failed } : {}),
    opened,
    navigated,
    ...(changes ? { changes } : {}),
  };
}

/**
 * Closes tabs this job (or, with no task, the unbound calls) opened. Any other tab is refused; the app's turn-end
 * tidy-up (`tidy`) skips it instead, since it may be a tab the user took over with Stop or one in another browser.
 */
async function closeTabs(ids, context, tidy = false) {
  const ownership = await loadOwnership();
  const closed = [];
  const missing = [];
  const skipped = [];
  for (const raw of ids) {
    const tabId = Number(raw);
    const entry = ownership.owned[tabId];
    if (!entry || entry.task !== (context.task ?? "")) {
      if (tidy) {
        skipped.push(tabId);
        continue;
      }
      throw new Error(
        entry ? `Tab ${tabId} belongs to another OpenClicky job.` : `Tab ${tabId} isn't one this job opened; leave the user's tabs open.`,
      );
    }
    const tab = await chrome.tabs.get(tabId).catch(() => null);
    if (!tab) {
      missing.push(tabId);
    } else {
      await chrome.tabs.remove(tabId);
      closed.push(tabId);
    }
    delete ownership.owned[tabId];
  }
  await saveOwnership(ownership);
  return { closed, missing, ...(tidy ? { skipped } : {}) };
}

const OPERATIONS = {
  async tabs(_args, context = {}) {
    const [all, focused, { owned }] = await Promise.all([chrome.tabs.query({}), focusedTab(), loadOwnership()]);
    return {
      tabs: all
        .filter((tab) => !tab.incognito)
        .map((tab) => ({
          id: tab.id,
          windowId: tab.windowId,
          title: tab.title ?? "",
          url: tab.url ?? "",
          active: tab.active,
          focused: tab.id === focused?.id,
          status: tab.status,
          ...(context.task && owned[tab.id]?.task === context.task ? { mine: true } : {}),
        })),
    };
  },

  async open({ url, noSnapshot }, context = {}) {
    checkOpenURL(url);
    const base = await focusedTab();
    const created = await chrome.tabs.create({
      url,
      active: false,
      ...(base && !base.incognito ? { windowId: base.windowId, index: base.index + 1 } : {}),
    });
    const ownership = await loadOwnership();
    // A Stop pressed while the tab was being created already handed it to the user.
    if (!state.paused) {
      ownership.owned[created.id] = { task: context.task ?? "", kept: false };
      await saveOwnership(ownership);
    }
    const grouped = await groupForTask(created, context.task, context.groupTitle);
    // A slow page still answers with its tab, so the app knows the job owns it and closes it with the turn.
    const loaded = await waitForLoad(created.id, 45000).then(
      () => true,
      () => false,
    );
    const opened = loaded
      ? await loadNote(created.id, `Opened tab ${created.id}.`)
      : `Opened tab ${created.id}, but the page didn't finish loading within 45 s.`;
    const extra = { note: opened, ...(loaded ? {} : { loaded: false }), ...(context.task ? { grouped } : {}) };
    if (loaded && !noSnapshot) {
      const page = await inPage(created.id, "snapshot", {}).catch(() => null);
      if (page) Object.assign(extra, { elements: page.elements, elementsOmitted: page.elementsOmitted });
    }
    return describe(created.id, extra);
  },

  async navigate({ tabId, url }, context = {}) {
    checkOpenURL(url);
    const tab = await resolveTab(tabId);
    await checkNotForeign(tab.id, context.task);
    const navigation = watchNavigation(tab.id);
    try {
      await chrome.tabs.update(tab.id, { url });
      await waitForLoad(tab.id, 45000, navigation);
    } finally {
      navigation.stop();
    }
    return describe(tab.id, { note: await loadNote(tab.id, `Loaded ${url}.`), navigated: true });
  },

  async back({ tabId }, context = {}) {
    const tab = await resolveTab(tabId);
    await checkNotForeign(tab.id, context.task);
    const navigation = watchNavigation(tab.id);
    try {
      try {
        await chrome.tabs.goBack(tab.id);
      } catch (error) {
        // Chrome's back button skips entries a page created without a real user gesture, which includes pages
        // left through an agent's synthetic click. The page's own history.back() still reaches them.
        await inPage(tab.id, "historyBack", {});
        await waitForLoad(tab.id, 30000, navigation);
        if (!navigation.happened) throw new Error("There is no earlier page in this tab's history.");
      }
      await waitForLoad(tab.id, 30000, navigation);
    } finally {
      navigation.stop();
    }
    return describe(tab.id, { note: "Went back.", navigated: true });
  },

  async read(args) {
    const tab = await resolveTab(args.tabId);
    const page = await inPage(tab.id, "read", { query: args.query, maxChars: args.maxChars });
    return { tabId: tab.id, ...page };
  },

  async snapshot(args) {
    const tab = await resolveTab(args.tabId);
    const page = await inPage(tab.id, "snapshot", { query: args.query });
    return { tabId: tab.id, ...page };
  },

  async extract(args) {
    const tab = await resolveTab(args.tabId);
    const page = await inPage(tab.id, "extract", { maxChars: args.maxChars });
    return { tabId: tab.id, ...page };
  },

  click: (args, context) => act(args, "click", context),
  type: (args, context) => act(args, "type", context),
  fill: (args, context) => act(args, "fill", context),
  select: (args, context) => act(args, "select", context),
  scroll: (args, context) => act(args, "scroll", context),
  press: (args, context) => act(args, "press", context),

  batch: (args, context) => runBatch(args, context),

  async close(args, context = {}) {
    // Only the app's turn-end tidy-up sends a list (`tabIds` with `tidy`); an agent's close names one tab.
    const tidy = args.tidy === true && Array.isArray(args.tabIds);
    const ids = tidy ? args.tabIds : [args.tabId];
    return closeTabs(ids.filter((id) => id !== undefined && id !== null), context, tidy);
  },

  async keep(args, context = {}) {
    const tab = await chrome.tabs.get(Number(args.tabId)).catch(() => null);
    if (!tab) throw new Error(`There is no tab ${args.tabId}. Use tabs to list them.`);
    const ownership = await loadOwnership();
    const owner = ownership.owned[tab.id]?.task;
    if (context.task && owner && owner !== context.task) throw new Error(`Tab ${tab.id} belongs to another OpenClicky job.`);
    // A tab no job opened is the user's already: keeping it must not make it a job's (and so closable).
    if (owner !== undefined) {
      ownership.owned[tab.id] = { task: owner, kept: true };
      await saveOwnership(ownership);
    }
    return { tabId: tab.id, title: tab.title ?? "", url: tab.url ?? "", why: args.why ?? "result", kept: true };
  },

  /** Closes tabs of jobs that are no longer running (kept ones become the user's), after a reconnect. */
  async sweep(args) {
    const running = new Set(Array.isArray(args.running) ? args.running : []);
    const ownership = await loadOwnership();
    const stale = Object.entries(ownership.owned).filter(([, entry]) => entry.task && !running.has(entry.task));
    const closed = [];
    for (const [id, entry] of stale) {
      delete ownership.owned[id];
      if (entry.kept) continue;
      const tab = await chrome.tabs.get(Number(id)).catch(() => null);
      if (tab) {
        await chrome.tabs.remove(tab.id).catch(() => {});
        closed.push(tab.id);
      }
    }
    for (const task of Object.keys(ownership.groups)) if (!running.has(task)) delete ownership.groups[task];
    await saveOwnership(ownership);
    return { closed };
  },

  async wait_for(args) {
    const tab = await resolveTab(args.tabId);
    const timeoutMs = Math.min(Math.max(Number(args.timeout ?? 15), 1), 120) * 1000;
    const started = Date.now();
    if (!args.text && !args.url) {
      await waitForLoad(tab.id, timeoutMs);
      await inPage(tab.id, "settle", {}).catch(() => {});
      return describe(tab.id, { note: "The page has finished loading." });
    }
    const target = args.url ? `URL containing "${args.url}"` : `"${args.text}"`;
    while (Date.now() - started < timeoutMs) {
      refuseIfPaused();
      const current = await chrome.tabs.get(tab.id);
      let found = false;
      if (args.url) {
        found = (current.url ?? "").includes(args.url);
      } else {
        found = await inPage(tab.id, "hasText", { text: args.text })
          .then((r) => r.found)
          .catch(() => false);
      }
      if (args.gone ? !found : found) {
        const waited = Math.round((Date.now() - started) / 100) / 10;
        return describe(tab.id, { note: `${args.gone ? "Gone" : "Found"}: ${target} after ${waited} s.`, waited });
      }
      await sleep(400);
    }
    throw new Error(`Waited ${timeoutMs / 1000} s; ${target} ${args.gone ? "is still there" : "never appeared"}.`);
  },

  async screenshot(args) {
    let tab = await resolveTab(args.tabId);
    if (!tab.active) {
      await chrome.tabs.update(tab.id, { active: true });
      await sleep(300);
    }
    let quality = Math.min(Math.max(Number(args.quality ?? 70), 10), 95);
    let dataURL = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "jpeg", quality });
    while (dataURL.length > MAX_SCREENSHOT_BASE64 / 2 && quality > 20) {
      quality = Math.max(20, quality - 25);
      await sleep(550); // captureVisibleTab allows two calls per second
      dataURL = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "jpeg", quality });
    }
    const data = dataURL.slice(dataURL.indexOf(",") + 1);
    if (data.length > MAX_SCREENSHOT_BASE64) throw new Error("The screenshot is too large to send. Use read instead.");
    tab = await chrome.tabs.get(tab.id);
    return { tabId: tab.id, mimeType: "image/jpeg", quality, data, title: tab.title ?? "", url: tab.url ?? "" };
  },
};

// The operations a batch step may be.
const BATCH_STEPS = {
  open: OPERATIONS.open,
  navigate: OPERATIONS.navigate,
  back: OPERATIONS.back,
  click: OPERATIONS.click,
  type: OPERATIONS.type,
  fill: OPERATIONS.fill,
  select: OPERATIONS.select,
  scroll: OPERATIONS.scroll,
  press: OPERATIONS.press,
  wait_for: OPERATIONS.wait_for,
};

// ---- Popup ------------------------------------------------------------------------------------------------

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== chrome.runtime.id) return false;
  switch (message?.kind) {
    case "status":
      Promise.all([profileId(), pauseLoaded]).then(([profile]) =>
        reply({
          paused: state.paused,
          hostConnected: state.hostConnected,
          appConnected: state.appConnected,
          lastError: state.lastError,
          profileId: profile,
          extensionId: chrome.runtime.id,
          version: VERSION,
          commandsRun: state.commandsRun,
          lastCommand: state.lastCommand,
        }),
      );
      return true;
    case "reconnect":
      state.retryMs = MIN_RETRY_MS;
      if (!state.port) connect();
      reply({ ok: true });
      return false;
    case "stop":
      // Paused first, so nothing that arrives after this point runs; then the app fails what is in flight. The
      // jobs' tabs become the user's.
      setPaused(true)
        .then(releaseOwnedTabs)
        .then(() => reply({ ok: true }));
      send({ type: "stop" });
      return true;
    case "resume":
      setPaused(false).then(() => reply({ ok: true }));
      return true;
    case "openApp":
      send({ type: "openApp" });
      reply({ ok: Boolean(state.port) });
      return false;
  }
  return false;
});

// ---- Lifecycle --------------------------------------------------------------------------------------------
// Listeners are registered synchronously at the top level so a restarted worker receives the event that woke it.

chrome.runtime.onStartup.addListener(() => connect());
chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create(ALARM, { periodInMinutes: 0.5 });
  connect();
});
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM && !state.port) {
    state.retryMs = MIN_RETRY_MS;
    connect();
  }
});

chrome.alarms.get(ALARM).then((existing) => {
  if (!existing) chrome.alarms.create(ALARM, { periodInMinutes: 0.5 });
});
updateBadge();
connect();
