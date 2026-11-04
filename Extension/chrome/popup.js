// Toolbar popup: shows the bridge state and offers Stop (or Resume) / Open OpenClicky / Reconnect.

let paused = false;

function show(id, text, good) {
  const element = document.getElementById(id);
  element.textContent = text;
  if (good !== undefined) element.className = good ? "ok" : "bad";
}

async function refresh() {
  const status = await chrome.runtime.sendMessage({ kind: "status" });
  if (!status) return;
  show("host", status.hostConnected ? "connected" : "not connected", status.hostConnected);
  show("app", status.appConnected ? "connected" : "not reachable", status.appConnected);
  paused = Boolean(status.paused);
  show("access", paused ? "stopped" : "allowed", !paused);
  document.getElementById("stop").textContent = paused ? "Resume" : "Stop agent";
  document.getElementById("stop").title = paused
    ? "Let agents use this browser again"
    : "Stop agents from using this browser until you resume";
  show("count", String(status.commandsRun));
  show("error", status.lastError && !status.appConnected ? status.lastError : "");
  show("ids", `Extension ${status.extensionId} · v${status.version} · profile ${status.profileId.slice(0, 8)}`);
}

document.getElementById("stop").addEventListener("click", () =>
  chrome.runtime.sendMessage({ kind: paused ? "resume" : "stop" }).then(refresh),
);
document.getElementById("open").addEventListener("click", () => chrome.runtime.sendMessage({ kind: "openApp" }));
document.getElementById("reconnect").addEventListener("click", () =>
  chrome.runtime.sendMessage({ kind: "reconnect" }).then(() => setTimeout(refresh, 800)),
);

refresh();
setInterval(refresh, 1500);
