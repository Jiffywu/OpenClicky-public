// Presses the toolbar popup's Stop / Resume button through the DevTools protocol (headless Chrome has no toolbar).
//   node popup.mjs <user-data-dir> <extension-id> stop|resume
// Chrome must have been started with --remote-debugging-port=0; it writes the port to <user-data-dir>/DevToolsActivePort.
import { readFileSync } from "node:fs";

const [dir, extensionId, action] = process.argv.slice(2);
if (!["stop", "resume"].includes(action)) throw new Error("usage: popup.mjs <user-data-dir> <extension-id> stop|resume");
const port = readFileSync(`${dir}/DevToolsActivePort`, "utf8").split("\n")[0].trim();
const base = `http://127.0.0.1:${port}`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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
  return reply.result?.result?.value;
}
const text = (id) => evaluate(`document.getElementById(${JSON.stringify(id)})?.textContent ?? ""`);

try {
  // The popup shows "…" until its first status answer arrives.
  for (let i = 0; i < 50 && ["", "…"].includes(await text("access")); i++) await sleep(100);
  const expected = action === "stop" ? "Stop agent" : "Resume";
  const before = await text("stop");
  if (before !== expected) throw new Error(`the button reads "${before}", expected "${expected}"`);
  await evaluate(`document.getElementById("stop").click()`);
  let after = before;
  for (let i = 0; i < 30 && after === before; i++) {
    await sleep(100);
    after = await text("stop");
  }
  const access = await text("access");
  console.log(`popup: pressed "${before}"; the button now reads "${after}" and agent access is ${access}`);
  if (after === before) throw new Error("the popup didn't change state");
} finally {
  socket.close();
  await fetch(`${base}/json/close/${target.id}`).catch(() => {});
}
