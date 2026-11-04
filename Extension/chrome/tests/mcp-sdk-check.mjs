// Conformance check: the official MCP TypeScript SDK client against OpenClicky's browser MCP server.
//   (cd some-dir && npm install @modelcontextprotocol/sdk)
//   MCP_SDK_DIR=some-dir node Extension/chrome/tests/mcp-sdk-check.mjs <bridge folder>/mcp.json
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
const sdkDir = process.env.MCP_SDK_DIR ?? process.cwd();
const require = createRequire(`${sdkDir}/package.json`);
const { Client } = require("@modelcontextprotocol/sdk/client/index.js");
const { StreamableHTTPClientTransport } = require("@modelcontextprotocol/sdk/client/streamableHttp.js");

const endpoint = JSON.parse(readFileSync(process.argv[2], "utf8"));
const sdkVersion = JSON.parse(readFileSync(`${sdkDir}/node_modules/@modelcontextprotocol/sdk/package.json`, "utf8")).version;
console.log(`@modelcontextprotocol/sdk ${sdkVersion}`);

const transport = new StreamableHTTPClientTransport(new URL(endpoint.url), {
  requestInit: { headers: { Authorization: `Bearer ${endpoint.token}` } },
});
const client = new Client({ name: "sdk-conformance-check", version: "1.0.0" });
await client.connect(transport);
console.log("server:", JSON.stringify(client.getServerVersion()), "protocol:", transport.protocolVersion ?? "(negotiated)");
const { tools } = await client.listTools();
console.log("tools:", tools.map((t) => `${t.name} (${t.inputSchema.properties.operation.enum.length} operations)`).join(", "));
const status = await client.callTool({ name: "browser", arguments: { operation: "status" } });
console.log("status:", JSON.stringify(status));
const missing = await client.callTool({ name: "browser", arguments: { operation: "read" } });
console.log("read without a browser -> isError:", missing.isError, "|", missing.content[0].text.slice(0, 80) + "…");
try {
  await client.callTool({ name: "nope", arguments: {} });
} catch (error) {
  console.log("unknown tool ->", error.message);
}
const unauthorized = await fetch(endpoint.url, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
console.log("no token -> HTTP", unauthorized.status);
const badVersion = await fetch(endpoint.url, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
    Authorization: `Bearer ${endpoint.token}`,
    "MCP-Protocol-Version": "1999-01-01",
  },
  body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }),
});
console.log("unsupported MCP-Protocol-Version -> HTTP", badVersion.status);
await client.close();
