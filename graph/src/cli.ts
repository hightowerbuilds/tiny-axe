// `tiny-axe graph`: serves the know-how vault and the chat history on
// 127.0.0.1 and prints the address. It doesn't open a browser; the user
// does. With --mcp it's an MCP server on stdio instead, serving them only
// when a tool asks (mcp.ts).

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { start } from "./server.ts";
import { serveMcp } from "./mcp.ts";

const USAGE = `usage: tiny-axe graph [--port PORT] [--vault FOLDER] [--history FOLDER]
       tiny-axe graph --mcp [--port PORT] [--vault FOLDER] [--history FOLDER]

Serves what tiny-axe knows about the web, and the history of your chats
with it, on http://127.0.0.1:PORT (default 4747) and prints the address
to open. ctrl+c stops it.

--vault defaults to \${XDG_DATA_HOME:-~/.local/share}/tiny-axe/vault and
--history to \${XDG_STATE_HOME:-~/.local/state}/tiny-axe/history.

With --mcp it's an MCP server on stdin/stdout instead (graph_open,
graph_close): the address is served only once graph_open asks, on PORT
or the next free port up to PORT+10 (0 takes any free port).`;

const DEFAULT_PORT = 4747;

function defaultVault(): string {
  const data = process.env.XDG_DATA_HOME || join(homedir(), ".local", "share");
  return join(data, "tiny-axe", "vault");
}

// Where tiny-axe keeps its chats (TinyAxe.History.dir/0).
function defaultHistory(): string {
  const state = process.env.XDG_STATE_HOME || join(homedir(), ".local", "state");
  return join(state, "tiny-axe", "history");
}

// Built, the page sits beside this file (dist/web); from source, in dist/web.
function webDir(): string {
  const beside = join(import.meta.dirname, "web");
  return existsSync(beside) ? beside : join(import.meta.dirname, "..", "dist", "web");
}

function fail(message: string, code = 2): never {
  console.error(`tiny-axe graph: ${message}`);
  process.exit(code);
}

let args;
try {
  args = parseArgs({
    options: {
      port: { type: "string" },
      vault: { type: "string" },
      history: { type: "string" },
      mcp: { type: "boolean" },
      help: { type: "boolean", short: "h" },
    },
  }).values;
} catch (error) {
  fail(`${(error as Error).message}\n\n${USAGE}`);
}

if (args.help) {
  console.log(USAGE);
  process.exit(0);
}

const port = args.port === undefined ? DEFAULT_PORT : Number(args.port);
const lowest = args.mcp ? 0 : 1;
if (!Number.isInteger(port) || port < lowest || port > 65535) {
  fail(`--port needs a number from ${lowest} to 65535, not ${args.port}`);
}

const vault = args.vault ?? defaultVault();
// The history may not exist yet either: then there are no chats to show.
const history = args.history ?? defaultHistory();

// The vault may not exist yet: graph_open checks on each call.
if (args.mcp) {
  serveMcp({ vault, history, web: webDir(), port });
} else {
  await serve();
}

async function serve() {
  if (!existsSync(join(vault, ".tiny-axe", "vault.json"))) {
    fail(
      `there's no vault at ${vault} yet. tiny-axe writes it as tasks finish; ` +
        `use --vault FOLDER to open another one.`,
      1,
    );
  }

  try {
    const running = await start({ vault, history, web: webDir(), port });
    console.log(`tiny-axe graph: open ${running.url}`);
    console.log(`Serving ${vault} and the chats in ${history} on this computer only. ctrl+c stops it.`);

    const stop = () => {
      running.close().then(() => process.exit(0));
    };
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
  } catch (error) {
    const e = error as NodeJS.ErrnoException;
    if (e.code === "EADDRINUSE") fail(`port ${port} is in use; try --port ${port + 1}`);
    fail(e.message, 1);
  }
}
