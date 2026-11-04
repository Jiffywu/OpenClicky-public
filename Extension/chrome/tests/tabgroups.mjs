// Lists the browser's tab groups and the tabs in each, through the DevTools protocol and an extension page (which
// can call chrome.tabGroups), so e2e.sh can check that a job's tabs went into a group named for the job.
//   node tabgroups.mjs <user-data-dir> <extension-id>
// Prints one line per group: group "<title>" (<color>): tabs <id>, <id>
import { readFileSync } from "node:fs";

const [dir, extensionId] = process.argv.slice(2);
if (!dir || !extensionId) throw new Error("usage: tabgroups.mjs <user-data-dir> <extension-id>");
const port = readFileSync(`${dir}/DevToolsActivePort`, "utf8").split("\n")[0].trim();
const base = `http://127.0.0.1:${port}`;

const target = await (await fetch(`${base}/json/new?chrome-extension://${extensionId}/popup.html`, { method: "PUT" })).json();
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.onopen = resolve;
  socket.onerror = reject;
});
let nextId = 1;
const waiting = new Map();
socket.onmessage = (event) => {
  const message = JSON.parse(event.data);
  waiting.get(message.id)?.(message);
  waiting.delete(message.id);
};
async function evaluate(expression) {
  const id = nextId++;
  const reply = await new Promise((resolve) => {
    waiting.set(id, resolve);
    socket.send(JSON.stringify({ id, method: "Runtime.evaluate", params: { expression, awaitPromise: true, returnByValue: true } }));
  });
  if (reply.result?.exceptionDetails) throw new Error(reply.result.exceptionDetails.exception?.description ?? "evaluation failed");
  return reply.result?.result?.value;
}

try {
  const groups = await evaluate(`(async () => {
    if (!chrome.tabGroups) return null;
    const groups = await chrome.tabGroups.query({});
    const tabs = await chrome.tabs.query({});
    return groups.map((g) => ({ title: g.title, color: g.color, tabs: tabs.filter((t) => t.groupId === g.id).map((t) => t.id) }));
  })()`);
  if (groups === null) throw new Error("chrome.tabGroups is unavailable: the extension lacks the tabGroups permission");
  if (groups.length === 0) console.log("no tab groups");
  for (const group of groups) console.log(`group "${group.title}" (${group.color}): tabs ${group.tabs.join(", ")}`);
} finally {
  socket.close();
  await fetch(`${base}/json/close/${target.id}`).catch(() => {});
}
