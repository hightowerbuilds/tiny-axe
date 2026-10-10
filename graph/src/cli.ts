// `tiny-axe graph`: serves the know-how vault on 127.0.0.1 and prints the
// address. It doesn't open a browser; the user does.

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { start } from "./server.ts";

const USAGE = `usage: tiny-axe graph [--port PORT] [--vault FOLDER]

Serves what tiny-axe knows about the web on http://127.0.0.1:PORT
(default 4747) and prints the address to open. ctrl+c stops it.`;

const DEFAULT_PORT = 4747;

function defaultVault(): string {
  const data = process.env.XDG_DATA_HOME || join(homedir(), ".local", "share");
  return join(data, "tiny-axe", "vault");
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
if (!Number.isInteger(port) || port < 1 || port > 65535) fail(`--port needs a number from 1 to 65535, not ${args.port}`);

const vault = args.vault ?? defaultVault();
if (!existsSync(join(vault, ".tiny-axe", "vault.json"))) {
  fail(
    `there's no vault at ${vault} yet. tiny-axe writes it as tasks finish; ` +
      `use --vault FOLDER to open another one.`,
    1,
  );
}

try {
  const running = await start({ vault, web: webDir(), port });
  console.log(`tiny-axe graph: open ${running.url}`);
  console.log(`Serving ${vault} on this computer only. ctrl+c stops it.`);

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
