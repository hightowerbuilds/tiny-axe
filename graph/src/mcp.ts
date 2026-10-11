// `tiny-axe graph --mcp`: the viewer as an MCP server on stdio, so the model
// can hand the user a link to the graph. Same protocol as the browser sidecar
// (priv/browser/server.mjs): one JSON message per line. Only JSON-RPC goes to
// stdout; anything else goes to stderr. The web server starts on the first
// graph_open, not before, and never opens a browser.

import { existsSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { start, type Running } from "./server.ts";

export interface McpOptions {
  vault: string;
  web: string;
  /** Where to try first; 0 takes any free port. */
  port: number;
}

// How many ports past the first to try when it's taken.
const MORE_PORTS = 10;

class UserError extends Error {}

type Result = { content: { type: "text"; text: string }[]; isError?: boolean };
type Tool = {
  description: string;
  inputSchema: object;
  annotations: object;
  run(args: Record<string, unknown>): Promise<Result>;
};

const ANNOTATIONS = { readOnlyHint: true, openWorldHint: false };

function text(t: string): Result {
  return { content: [{ type: "text", text: t }] };
}

function send(msg: object) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

export function serveMcp(options: McpOptions) {
  let running: Running | undefined;

  // Tries the port, then the next ones up, until one is free.
  async function listen(): Promise<Running> {
    const last = options.port === 0 ? 0 : Math.min(65535, options.port + MORE_PORTS);
    for (let port = options.port; port <= last; port++) {
      try {
        return await start({ vault: options.vault, web: options.web, port });
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EADDRINUSE") throw error;
      }
    }
    throw new UserError(`ports ${options.port} to ${last} are all in use; start tiny-axe graph with another --port`);
  }

  const TOOLS: Record<string, Tool> = {
    graph_open: {
      description:
        "Get a link to tiny-axe's know-how graph (what it has learned about sites, pages, controls and tasks) " +
        "to give the user. It never opens a browser: tell the user the link and they open it. " +
        "The page is served on this computer only (127.0.0.1). Give `focus` (a note id) to center the graph on one note.",
      inputSchema: { type: "object", properties: { focus: { type: "string" } }, required: [] },
      annotations: ANNOTATIONS,
      async run({ focus }) {
        if (!existsSync(join(options.vault, ".tiny-axe", "vault.json"))) {
          throw new UserError(
            `there's no know-how vault at ${options.vault} yet. tiny-axe writes it as tasks finish; try again after one has.`,
          );
        }
        running ??= await listen();
        const query = typeof focus === "string" && focus !== "" ? `focus=${encodeURIComponent(focus)}&` : "";
        const url = `http://127.0.0.1:${running.port}/?${query}t=${running.token}`;
        return text(`${url}\nThe know-how graph is at that address on this computer only. Open it in your browser.`);
      },
    },
    graph_close: {
      description: "Stop serving the know-how graph that graph_open started. The link it gave stops working.",
      inputSchema: { type: "object", properties: {}, required: [] },
      annotations: ANNOTATIONS,
      async run() {
        if (!running) return text("The know-how graph wasn't being served.");
        const closing = running;
        running = undefined;
        await closing.close();
        return text("Stopped serving the know-how graph.");
      },
    },
  };

  // One tool call at a time, so two graph_opens can't start two servers.
  let queue: Promise<unknown> = Promise.resolve();
  function serial<T>(fn: () => Promise<T>): Promise<T> {
    const run = queue.then(fn, fn);
    queue = run.catch(() => {});
    return run;
  }

  async function handle(msg: { id?: unknown; method?: string; params?: any }) {
    const { id, method, params } = msg;
    if (id === undefined) return; // a notification
    try {
      if (method === "initialize") {
        return send({
          jsonrpc: "2.0",
          id,
          result: {
            protocolVersion: params?.protocolVersion || "2025-06-18",
            capabilities: { tools: {} },
            serverInfo: { name: "tiny-axe-graph", version: "0.1" },
          },
        });
      }
      if (method === "tools/list") {
        const tools = Object.entries(TOOLS).map(([name, t]) => ({
          name,
          description: t.description,
          inputSchema: t.inputSchema,
          annotations: t.annotations,
        }));
        return send({ jsonrpc: "2.0", id, result: { tools } });
      }
      if (method === "tools/call") {
        const tool = TOOLS[params?.name];
        if (!tool) {
          return send({ jsonrpc: "2.0", id, result: { isError: true, content: [{ type: "text", text: `no tool ${params?.name}` }] } });
        }
        try {
          return send({ jsonrpc: "2.0", id, result: await serial(() => tool.run(params.arguments || {})) });
        } catch (e) {
          const why = e instanceof UserError ? e.message : `the graph couldn't do that: ${(e as Error).message.split("\n")[0]}`;
          return send({ jsonrpc: "2.0", id, result: { isError: true, content: [{ type: "text", text: why }] } });
        }
      }
      if (method === "ping") return send({ jsonrpc: "2.0", id, result: {} });
      send({ jsonrpc: "2.0", id, error: { code: -32601, message: "method not found" } });
    } catch (e) {
      send({ jsonrpc: "2.0", id, error: { code: -32603, message: (e as Error).message } });
    }
  }

  async function stop() {
    await running?.close().catch(() => {});
    process.exit(0);
  }

  const rl = createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    if (!line.trim()) return;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return console.error("tiny-axe graph: ignoring a line that isn't JSON");
    }
    handle(msg);
  });
  rl.on("close", stop);
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}
