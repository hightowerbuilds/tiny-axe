// `--mcp`: the built server as an MCP server on stdio, the way tiny-axe runs
// it. Only JSON-RPC on stdout, the web server only once graph_open asks.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { cp, mkdtemp } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

const fixture = join(import.meta.dirname, "../../test/fixtures/vault/vault");
const server = join(import.meta.dirname, "../dist/server.js");

interface Client {
  call(method: string, params?: object): Promise<any>;
  notify(method: string): void;
  tool(name: string, args?: object): Promise<{ text: string; isError?: boolean }>;
  /** Closes stdin and waits for the exit code. */
  end(): Promise<number | null>;
  stdout: string[];
  stderr: () => string;
}

function client(vault: string, port = "0"): Client {
  const child: ChildProcessWithoutNullStreams = spawn(process.execPath, [server, "--mcp", "--vault", vault, "--port", port]);
  const stdout: string[] = [];
  let stderr = "";
  child.stderr.on("data", (chunk) => (stderr += chunk));
  const waiting = new Map<number, (msg: any) => void>();
  createInterface({ input: child.stdout }).on("line", (line) => {
    stdout.push(line);
    const msg = JSON.parse(line);
    waiting.get(msg.id)?.(msg);
  });
  const exited = new Promise<number | null>((resolve) => child.on("exit", resolve));

  let next = 1;
  const call = (method: string, params?: object) =>
    new Promise<any>((resolve) => {
      const id = next++;
      waiting.set(id, resolve);
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });

  return {
    call,
    notify: (method) => child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method }) + "\n"),
    async tool(name, args = {}) {
      const { result } = await call("tools/call", { name, arguments: args });
      assert.equal(result.content.length, 1);
      assert.equal(result.content[0].type, "text");
      return { text: result.content[0].text, isError: result.isError };
    },
    end() {
      child.stdin.end();
      return exited;
    },
    stdout,
    stderr: () => stderr,
  };
}

async function copyVault() {
  const vault = await mkdtemp(join(tmpdir(), "vault-"));
  await cp(fixture, vault, { recursive: true });
  return vault;
}

const URL_LINE = /^http:\/\/127\.0\.0\.1:(\d+)\/\?(?:focus=[^&]+&)?t=([\w-]+)$/;

test("graph_open hands back a working link, reused until graph_close", async () => {
  const mcp = client(await copyVault());

  const init = await mcp.call("initialize", { protocolVersion: "2025-03-26", capabilities: {} });
  assert.equal(init.result.protocolVersion, "2025-03-26");
  assert.deepEqual(init.result.capabilities, { tools: {} });
  assert.equal(init.result.serverInfo.name, "tiny-axe-graph");
  // A notification gets no reply.
  mcp.notify("notifications/initialized");
  const { tools } = (await mcp.call("tools/list")).result;
  assert.equal(mcp.stdout.length, 2);
  assert.deepEqual(tools.map((t: { name: string }) => t.name), ["graph_open", "graph_close"]);
  for (const t of tools) assert.deepEqual(t.annotations, { readOnlyHint: true, openWorldHint: false });
  assert.deepEqual(tools[0].inputSchema.properties, {
    focus: { type: "string" },
    page: { type: "string", enum: ["graph", "chats"] },
  });
  assert.match(tools[0].description, /never opens a browser/);

  const opened = await mcp.tool("graph_open", { focus: "shop.example" });
  assert.equal(opened.isError, undefined);
  const [url, human] = opened.text.split("\n");
  const [, port, token] = url.match(URL_LINE)!;
  assert.equal(url, `http://127.0.0.1:${port}/?focus=shop.example&t=${token}`);
  assert.match(human, /on this computer only/);

  // The chats page, on the same server and key.
  const chats = await mcp.tool("graph_open", { page: "chats" });
  assert.equal(chats.text.split("\n")[0], `http://127.0.0.1:${port}/chats?t=${token}`);
  const toChats = await fetch(chats.text.split("\n")[0], { redirect: "manual" });
  assert.equal(toChats.headers.get("location"), "/chats");

  // The token becomes a cookie and the focus stays in the address.
  const swap = await fetch(url, { redirect: "manual" });
  assert.equal(swap.status, 302);
  assert.equal(swap.headers.get("location"), "/?focus=shop.example");
  const cookie = swap.headers.getSetCookie()[0].split(";")[0];
  assert.equal(cookie, `tiny_axe_graph_${port}=${token}`);
  const page = await fetch(`http://127.0.0.1:${port}/?focus=shop.example`, { headers: { cookie } });
  assert.equal(page.status, 200);
  assert.match(await page.text(), /\/static\/app.js/);

  // A note id that needs escaping is escaped.
  const odd = await mcp.tool("graph_open", { focus: "click-Add-to-Cart-ran 694659fe" });
  assert.equal(odd.text.split("\n")[0], `http://127.0.0.1:${port}/?focus=click-Add-to-Cart-ran%20694659fe&t=${token}`);

  assert.equal((await mcp.tool("graph_open", { focus: "shop.example" })).text.split("\n")[0], url);
  assert.equal((await mcp.tool("graph_open")).text.split("\n")[0], `http://127.0.0.1:${port}/?t=${token}`);

  assert.match((await mcp.tool("graph_close")).text, /Stopped/);
  await assert.rejects(fetch(url, { redirect: "manual" }), (e: any) => e.cause?.code === "ECONNREFUSED");
  assert.match((await mcp.tool("graph_close")).text, /wasn't being served/);

  const unknown = await mcp.tool("graph_nope");
  assert.equal(unknown.isError, true);
  assert.deepEqual((await mcp.call("ping")).result, {});
  assert.deepEqual((await mcp.call("resources/list")).error, { code: -32601, message: "method not found" });

  assert.equal(await mcp.end(), 0);
  for (const line of mcp.stdout) assert.equal(JSON.parse(line).jsonrpc, "2.0");
  assert.doesNotMatch(mcp.stderr(), new RegExp(token));
});

test("without a vault graph_open says so, and works once there is one", async () => {
  const vault = await mkdtemp(join(tmpdir(), "vault-"));
  const mcp = client(vault);
  await mcp.call("initialize", {});

  const missing = await mcp.tool("graph_open");
  assert.equal(missing.isError, true);
  assert.match(missing.text, /no know-how vault .* writes it as tasks finish/);

  await cp(fixture, vault, { recursive: true });
  const opened = await mcp.tool("graph_open");
  assert.equal(opened.isError, undefined);
  const url = opened.text.split("\n")[0];
  assert.match(url, URL_LINE);
  assert.equal((await fetch(url, { redirect: "manual" })).status, 302);

  // Closing stdin closes the web server too.
  assert.equal(await mcp.end(), 0);
  await assert.rejects(fetch(url, { redirect: "manual" }));
});

test("a port in use moves graph_open to the next one", async () => {
  const taken = createServer();
  await new Promise<void>((resolve) => taken.listen(0, "127.0.0.1", resolve));
  const port = (taken.address() as { port: number }).port;

  const mcp = client(await copyVault(), String(port));
  await mcp.call("initialize", {});
  const [, got] = (await mcp.tool("graph_open")).text.match(/127\.0\.0\.1:(\d+)/)!;
  assert.ok(Number(got) > port && Number(got) <= port + 10, got);

  assert.equal(await mcp.end(), 0);
  taken.close();
});
