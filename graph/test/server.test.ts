// The viewer's server against a copy of the fixture vault: who it answers,
// what it serves, and that nothing in a note becomes markup.

import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { request } from "node:http";
import { cp, mkdtemp, rename, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { start, type Running } from "../src/server.ts";

const fixture = join(import.meta.dirname, "../../test/fixtures/vault/vault");
const web = join(import.meta.dirname, "../dist/web");
const TOKEN = "test-token-0123456789";

let running: Running;
let vault: string;

const HOSTILE = `---
kind: "site"
key: "evil.example"
title: "evil.example"
trust: "observed"
---

# evil.example

<img src=x onerror="alert(1)"> <script>alert(2)</script>

[click me](javascript:alert(3)) ![pixel](http://evil.example/p.png) [fine](https://evil.example/about)

A label: \\<b\\>bold\\</b\\> and [[nowhere 12345678|a missing note]].
`;

before(async () => {
  vault = await mkdtemp(join(tmpdir(), "vault-"));
  await cp(fixture, vault, { recursive: true });
  await writeFile(join(vault, "Sites/evil.example.md"), HOSTILE);
  running = await start({ vault, web, port: 0, token: TOKEN });
});

after(() => running.close());

interface Reply {
  status: number;
  headers: Record<string, string | string[] | undefined>;
  body: string;
}

function get(path: string, { cookie = true, host = `127.0.0.1:${running.port}`, method = "GET" } = {}): Promise<Reply> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = { Host: host };
    if (cookie) headers.Cookie = `tiny_axe_graph_${running.port}=${TOKEN}`;
    const req = request({ host: "127.0.0.1", port: running.port, path, method, headers }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => resolve({ status: res.statusCode!, headers: res.headers, body }));
    });
    req.on("error", reject);
    req.end();
  });
}

const api = async (path: string) => {
  const reply = await get(path);
  assert.equal(reply.status, 200, reply.body);
  return JSON.parse(reply.body);
};

test("the printed address carries the token, on 127.0.0.1", () => {
  assert.equal(running.url, `http://127.0.0.1:${running.port}/?t=${TOKEN}`);
});

test("without the token, nothing is served", async () => {
  for (const path of ["/", "/api/vault", "/api/note?id=shop.example", "/static/app.js", "/?t=wrong"]) {
    const reply = await get(path, { cookie: false });
    assert.equal(reply.status, 401, path);
    assert.doesNotMatch(reply.body, /shop\.example/);
  }
});

test("opening the address swaps the token for a cookie", async () => {
  const reply = await get(`/note/shop.example?t=${TOKEN}`, { cookie: false });
  assert.equal(reply.status, 302);
  assert.equal(reply.headers.location, "/note/shop.example");
  assert.deepEqual(reply.headers["set-cookie"], [
    `tiny_axe_graph_${running.port}=${TOKEN}; HttpOnly; SameSite=Strict; Path=/`,
  ]);
});

test("a request for another host name is refused, even with the cookie", async () => {
  for (const host of [`evil.example:${running.port}`, "127.0.0.1:1", "127.0.0.1"]) {
    assert.equal((await get("/api/vault", { host })).status, 403, host);
  }
  assert.equal((await get("/api/vault", { host: `localhost:${running.port}` })).status, 200);
});

test("it's read-only", async () => {
  assert.equal((await get("/api/vault", { method: "POST" })).status, 405);
  assert.equal((await get("/api/vault", { method: "DELETE" })).status, 405);
});

test("the page is served with a strict content policy", async () => {
  for (const path of ["/", "/overview", "/?focus=shop.example", "/note/shop.example"]) {
    const reply = await get(path);
    assert.equal(reply.status, 200);
    assert.match(reply.body, /<script type="module" src="\/static\/app.js">/);
    assert.match(String(reply.headers["content-security-policy"]), /script-src 'self'/);
    assert.equal(reply.headers["x-content-type-options"], "nosniff");
  }
  assert.equal((await get("/static/style.css")).headers["content-type"], "text/css; charset=utf-8");
  // The layout's worker comes from the page's own folder, which the policy allows.
  assert.equal((await get("/static/layout.js")).headers["content-type"], "text/javascript; charset=utf-8");
});

test("nothing outside the page's folder is served", async () => {
  for (const path of ["/static/%2e%2e/server.js", "/static/..%2fserver.js", "/static/../../package.json", "/etc/passwd"]) {
    assert.equal((await get(path)).status, 404, path);
  }
});

test("the overview counts notes and lists folders", async () => {
  const vault = await api("/api/vault");
  assert.deepEqual(vault.summary, { sites: 3, pages: 5, controls: 5, paths: 9, blocked: 2, tools: 5, tasks: 2 });
  assert.deepEqual(
    vault.folders.map((f: { name: string }) => f.name),
    ["Sites", "Pages", "Controls", "Paths", "Tools", "Tasks"],
  );
  const paths = vault.folders.find((f: { name: string }) => f.name === "Paths").notes;
  assert.equal(paths.find((n: { title: string }) => n.title === 'click "Add to Cart" → ran').gate, "ran");
});

test("a note comes with its HTML, properties and backlinks", async () => {
  const note = await api(`/api/note?id=${encodeURIComponent("click-Add-to-Cart-ran 694659fe")}`);
  assert.equal(note.kind, "path");
  assert.match(
    note.html,
    /<a class="wikilink kind-control" href="\/note\/Add-to-Cart-button%200ec1c8ea">Add to Cart \(button\)<\/a>/,
  );
  assert.match(note.html, /<td>spends<\/td>\s*<td>no<\/td>/);
  assert.deepEqual(note.refs["20261001-100000-1"], { id: "20261001-100000-1", title: "20261001-100000-1", kind: "task" });
  assert.deepEqual(note.refs["browser__browser_click"].title, "browser_click (browser)");
  assert.deepEqual(
    note.backlinks.map((g: { folder: string; notes: { id: string }[] }) => [g.folder, g.notes.map((n) => n.id)]),
    [["Tasks", ["20261001-100000-1", "20261002-110000-2"]]],
  );
});

test("a site lists what links to it", async () => {
  const note = await api("/api/note?id=shop.example");
  assert.deepEqual(
    note.backlinks.map((g: { folder: string; notes: unknown[] }) => [g.folder, g.notes.length]),
    [["Pages", 4]],
  );
});

test("nothing in a note becomes markup or loads anything", async () => {
  const { html } = await api("/api/note?id=evil.example");
  assert.doesNotMatch(html, /<img|<script|<b>|javascript:|onerror="/);
  assert.match(html, /&lt;img src=x onerror=&quot;alert\(1\)&quot;&gt;/);
  assert.match(html, /&lt;script&gt;alert\(2\)&lt;\/script&gt;/);
  assert.match(html, /click me/);
  assert.match(html, /pixel/);
  assert.match(html, /<a class="external" href="https:\/\/evil.example\/about" rel="noopener noreferrer" target="_blank">fine<\/a>/);
  assert.match(html, /&lt;b&gt;bold&lt;\/b&gt;/);
  assert.match(html, /<span class="wikilink missing" title="No such note">a missing note<\/span>/);
});

test("the graph's lines are the notes' links, and the reverse", async () => {
  const graph = await api("/api/graph");
  const lines = new Set(graph.links.map(([a, b]: [number, number]) => `${graph.nodes[a].id} → ${graph.nodes[b].id}`));
  const links = new Set<string>();
  for (const { id } of graph.nodes) {
    for (const target of (await api(`/api/note?id=${encodeURIComponent(id)}`)).links) links.add(`${id} → ${target}`);
  }
  assert.deepEqual(lines, links);
  assert.equal(graph.nodes.length, 29);
});

test("an unknown note is a 404", async () => {
  assert.equal((await get("/api/note?id=nope")).status, 404);
});

test("search finds titles first, then bodies", async () => {
  const { results } = await api("/api/search?q=checkout");
  const titles = results.map((r: { title: string }) => r.title);
  assert.deepEqual(titles.slice(0, 2).sort(), ['click "Proceed to checkout" → refused', "Proceed to checkout (button)"].sort());
  const task = (await api("/api/search?q=cart")).results.find((r: { id: string }) => r.id === "20261002-110000-2");
  assert.equal(task.snippet, 
    "…Request add the other book to my cart, then leave a comment on the news story Steps navigate shop.example/:slug/dp/:id →…",
  );
  assert.deepEqual((await api("/api/search?q=")).results, []);
  assert.deepEqual((await api("/api/search?q=zzzz-nothing")).results, []);
});

test("a note written to the vault is pushed to open pages, by id", async () => {
  const events = await new Promise<import("node:http").IncomingMessage>((resolve, reject) => {
    request(
      {
        host: "127.0.0.1",
        port: running.port,
        path: "/api/events",
        headers: { Host: `127.0.0.1:${running.port}`, Cookie: `tiny_axe_graph_${running.port}=${TOKEN}` },
      },
      resolve,
    )
      .on("error", reject)
      .end();
  });
  assert.equal(events.headers["content-type"], "text/event-stream");

  const pushed = new Promise<string>((resolve) => {
    events.setEncoding("utf8");
    events.on("data", (chunk: string) => chunk.includes("event: vault") && resolve(chunk));
  });

  // Written the way the writer writes: a temporary name, then renamed.
  await writeFile(join(vault, "Sites/.new.example.md.1.tmp"), HOSTILE.replaceAll("evil.example", "new.example"));
  await rename(join(vault, "Sites/.new.example.md.1.tmp"), join(vault, "Sites/new.example.md"));
  const event = await pushed;
  events.destroy();
  assert.deepEqual(JSON.parse(event.split("data: ")[1]), { changed: ["new.example"] });

  assert.equal((await api("/api/vault")).summary.sites, 4);
  assert.ok((await api("/api/graph")).nodes.some((n: { id: string }) => n.id === "new.example"));
});
