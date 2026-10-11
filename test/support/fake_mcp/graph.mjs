// A stand-in for the know-how graph viewer's MCP mode (graph/ `server.js
// --mcp`), for tests of TinyAxe.Graph and /graph. Run with node, like the real
// one; it opens no port.
//
//   graph_open   {focus?}: the link on the first line, or isError when the
//                --vault folder doesn't exist
//   graph_close  {}
import { existsSync } from "node:fs";
import { createInterface } from "node:readline";

const arg = (name) => {
  const i = process.argv.indexOf(name);
  return i === -1 ? undefined : process.argv[i + 1];
};

const vault = arg("--vault");
const port = arg("--port") ?? "4747";
const tools = ["graph_open", "graph_close"].map((name) => ({
  name,
  description: `The ${name} tool.`,
  inputSchema: { type: "object", properties: name === "graph_open" ? { focus: { type: "string" } } : {} },
}));

const emit = (msg) => process.stdout.write(JSON.stringify(msg) + "\n");
const text = (id, t, isError = false) =>
  emit({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: t }], isError } });

createInterface({ input: process.stdin }).on("line", (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  if (msg.id === undefined) return;

  if (msg.method === "initialize") {
    emit({
      jsonrpc: "2.0",
      id: msg.id,
      result: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "fake-graph", version: "0" } },
    });
  } else if (msg.method === "tools/list") {
    emit({ jsonrpc: "2.0", id: msg.id, result: { tools } });
  } else if (msg.method === "tools/call" && msg.params.name === "graph_open") {
    const focus = msg.params.arguments?.focus;
    if (vault && !existsSync(vault)) {
      text(msg.id, `there's no vault at ${vault} yet. tiny-axe writes it as tasks finish.`, true);
    } else {
      const query = focus ? `focus=${encodeURIComponent(focus)}&` : "";
      text(msg.id, `http://127.0.0.1:${port}/?${query}t=tok_3x-Q*9\nServing the vault on this computer only.`);
    }
  } else if (msg.method === "tools/call" && msg.params.name === "graph_close") {
    text(msg.id, "Stopped the graph page.");
  } else {
    emit({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "method not found" } });
  }
});
